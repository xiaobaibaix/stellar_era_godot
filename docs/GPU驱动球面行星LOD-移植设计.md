# GPU 驱动球面行星 LOD —— 移植设计文档

> 目标：把 `GPUDrivenTerrainLearn`（Unity，平面方形四叉树、全 GPU 驱动、单 DrawCall）的思路**完整移植**到 StellarEra，但拓扑保持**正二十面体(icosahedron)20 面三角形四叉树**，地形高度来自**烘焙当前调好的程序化地形**。
>
> 硬约束：**不删除、不修改**现有 `scripts/planet/`、`shaders/terrain.gdshader` 等实现；新实现全部放新文件、挂新节点，与现有 Planet 可并存、可切换。

---

## 0. 本文档的范围

本文只做**设计与可行性论证**，不写实现代码。读完应能回答：

1. Unity 那套 GPU 驱动管线，在 Godot 4.7 / Forward+ / D3D12 上哪些能 1:1 复刻、哪些必须妥协、怎么妥协。
2. 把"平面方形四叉树"换成"球面三角形四叉树"后，每个子系统（寻址、烘焙、遍历、裁剪、接缝、提交）怎么改。
3. 高度图怎么从现有 `Terrain.height_at` 烘焙出来、烘焙到什么分辨率、用什么格式。
4. 新代码的文件清单、挂在哪、怎么和现有 Planet / 大气 / 碰撞 共存。
5. 分几期做、每期验收什么、有哪些已知风险。

配套阅读：`docs/GPUDrivenTerrainLearn-LOD实现分析.md`（Unity 原版逐 kernel 详解，本文直接引用其结论）。

---

## 1. 设计目标与非目标

### 目标
- **GPU 驱动**：LOD 选择（四叉树遍历）+ 裁剪 + patch 数据生成全部在 compute shader 里跑，CPU 每帧只录 command、几乎零逐 patch 计算。
- **instance 化渲染**：一张共享 patch 网格 + MultiMesh，patch 数据走 GPU buffer/纹理，CPU 不逐 patch 上传。
- **球面三角形拓扑**：保留 icosahedron 20 根面 + 三角形中点细分（与现有 `qnode.gd::_split` 同构）。
- **烘焙高度图**：从现有调好的 `Terrain.height_at` 离线生成 per-face 高度图 + MinMax mip，供 GPU 位移与裁剪使用。
- **接缝焊接**：移植 Unity `FixLODConnectSeam` 的顶点焊接思路（非裙边）。

### 非目标（本期不做）
- 不替换物理/碰撞：`planet_walker`、角色贴地继续用 CPU `Terrain.height_at`（实时噪声），GPU LOD 纯视觉。
- 不动大气 / 海洋 / 云：它们读 Planet 的 uniform，新实现照推即可。
- 不删除旧 Planet：旧实现作为 fallback / 对比基线保留。

---

## 2. 与 Unity 原版的核心差异（映射表）

| 维度 | Unity 原版（平面） | 本设计（球面三角形） | 改动要点 |
|------|------------------|------------------|---------|
| 拓扑 | xz 平面方形四叉树，2×2 切块 | icosahedron 20 根面 × 三角形中点四分 | 根从 1 个变 20 个；子节点由边中点归一化得到 |
| 节点几何 | nodeId + NodeIDOffset 表 + 从高度图 mip 反算位置 | 遍历时用父节点 3 角点**寄存器内**中点递推，无需预存全树几何 | 省掉 ~10² 级别的大缓冲；与 `qnode._split` 同构 |
| 高度来源 | 离线 HeightMap(R16) + MinMaxHeight(RG32 不对称归约) | 同：per-face 高度图(Texture2DArray,20 层) + MinMax mip | 采样坐标从世界 xz 改为 face-barycentric (u,v) + faceId |
| LOD 评价 | 纯距离 `f=d/(n·c)` | **SSE** `g_err·K/T`（沿用现 `qnode.select_lod` 已验证公式），g_err 用 MinMax 实际高差（比 maxHeight/2^L 更紧）| 内容自适应：平坦区更晚细分 |
| 裁剪 | 视锥(6 面×8 角 AABB) + Hi-Z 遮挡 | 同；AABB 由 face-bary 区域 × MinMax 高差构造；可选加**地平线剔除**（球面特有，移植现 `_is_below_horizon`）| 球面版 AABB 角点 = 3 角点 + 3 边中点 + 中心，各 ±(minH,maxH) |
| 接缝 | `FixLODConnectSeam`：方形网格边缘顶点按 `%2^lodDelta` 滑动焊接 | 三角形版：3 条边各做同样的"高精度侧多余边缘顶点向低精度侧对齐"焊接；需 LODMap 提供**每边邻居 LOD** | 邻居关系复杂化（见 §9）：面内易、跨面需 icosahedron 30 边邻接表 |
| 提交 | `DrawMeshInstancedIndirect` 单 DrawCall，共享 16² 方形 PatchMesh | MultiMesh + 共享**三角形** patch 网格；patch 数据存纹理（Godot 限制，见 §3）| Godot 无 indirect-draw-with-GPU-count；用纹理传 patch 数据 |
| 更新 | 每帧 6 次 dispatch 全量重算 | 同（PRE_OPAQUE compositor 内 dispatch）| 复用项目已有 CompositorEffect 机制 |

**一句话**：管线结构（traverse→lodmap→buildpatches→cull→instance 渲染）1:1 照搬；凡是"方形/xz/世界坐标"的地方都换成"三角形/face-barycentric/球面方向"；提交层因 Godot 能力差异从 indirect-draw 改为 MultiMass+纹理。

---

## 3. Godot 平台约束与关键决策（最重要的一节）

这一节解释"为什么这样设计"——它决定了架构形态。每条都给出依据。

### 3.1 compute 基础设施：完全现成，照搬大气后处理

项目已有 `scripts/render/atmosphere_compositor.gd` + `shaders/compute/*.glsl`，证明以下链路可用：

- `RenderingServer.get_rendering_device()` 拿到共享 RD。
- `load("*.glsl") as RDShaderFile` → `get_spirv()` → `shader_create_from_spirv` → `compute_pipeline_create`。
- `RDUniform` + `UniformSetCacheRD.get_cache(shader, set, [uniforms])` 绑定。
- `compute_list_begin / bind_pipeline / bind_uniform_set / set_push_constant / dispatch / end`。
- `RDTextureFormat`：`STORAGE_BIT | SAMPLING_BIT` 双用纹理（LUT 就是这么做的）。
- push constant 经 `PackedFloat32Array.to_byte_array()`。

**决策**：LOD compute 跑在一个新的 `CompositorEffect`（PRE_OPAQUE 回调）里，和大气后处理同一个渲染线程、同一套机制。相机矩阵直接从 `render_data.get_render_scene_data()` 取（编辑器/运行时都正确），行星参数经 `set_frame_data` + Mutex 推快照——**完全是大气 compositor 的复刻**。

### 3.2 Godot 没有"GPU 端计数 indirect draw"

Unity 用 `CopyCounterValue` 把可见 patch 数写进 indirect draw args，做到零 CPU 回读。Godot 的 `RenderingDevice.draw_list_draw(list, use_indices, instances)` 的 `instances` 是 CPU 直接传入的 uint，**不接受 GPU 端计数缓冲**。

**决策**：渲染提交用 MultiMesh，可见 patch 数有两种交付方式：
- **方案 A（推荐 v1，零回读）**：MultiMesh 固定 `visible_instance_count = MAX_PATCHES`；compute 把可见 patch 紧凑写到纹理前部并写 count；顶点 shader 对 `INSTANCE_ID >= count` 的实例直接输出退化位置（坍缩，光栅器丢弃）。代价：多跑若干空顶点 shader（实测 patch 量级下可忽略，见 §13 算量）。
- **方案 B（v2 优化）**：compute 写 count 到小缓冲，CPU 回读 1 个 uint（1 帧延迟）→ 设 `visible_instance_count`。消除空顶点开销。

### 3.3 gdshader spatial 不能按 instance 读 SSBO，但能读纹理

Godot 高级着色语言（`.gdshader`）的 spatial shader **不支持** storage buffer 绑定（SSBO 仅 compute `.glsl` 可用）。所以"compute 写 SSBO、顶点 shader 按 InstanceId 取"这条路在 gdshader 里走不通。

但 spatial shader **支持**：`INSTANCE_ID` 内建、`textureLod()`、`texelFetch()` 在 vertex 阶段采样纹理。

**决策**：patch 数据放进一张**纹理**（RGBA32F/16F），compute 以 storage image 写、顶点 shader 以 sampler + `texelFetch(u_patchTex, ivec2(slot, instance_id), 0)` 读。纹理用 `STORAGE_BIT | SAMPLING_BIT` 双用（项目 LUT 先例）。

### 3.4 同帧 storage→sampler 竞态：沿用项目既有的"1 帧延迟"模式

一张纹理同帧先被 compute 写（storage）、后被顶点 shader 读（sampler），需要 pipeline barrier。Godot 高层不自动插。项目大气 LUT **已经踩过这个坑并形成惯例**：本帧刚烘的 LUT 本帧不采样（`lut_on=0` 回退 march），下帧起查表。

**决策**：patch 纹理同样采用 **LOD 1 帧延迟**——本帧 compute 写入的 patch 集合，下一帧渲染才读。LOD 滞后 1 帧肉眼不可见，且天然消除竞态。Hi-Z 同理（Hi-Z 本来就用上一帧深度，天然 1 帧延迟）。

### 3.5 位移来源：烘焙高度图 vs 实时噪声（一个重要岔路，需你拍板）

你提的"烘焙高度图"能同时解决 GPU 驱动需要的两件事：① MinMax 包围盒（裁剪/LOD）② 位移采样。但**位移具体取自哪里**有两种选择：

| | 烘焙高度图位移（纯 Unity 路） | 实时噪声位移 + 烘焙 MinMax（混合路，推荐） |
|---|---|---|
| 位移来源 | 顶点 shader `textureLod(heightmap, uv, lod)` | 顶点 shader 跑 `terrain_height(d)`（与现 shader 同款噪声）|
| 与 CPU 碰撞一致性 | ❌ 烘焙量化 → 极近处视觉与碰撞有微小偏差 | ✅ 逐位一致（现有 terrain.gdshader 已验证）|
| 细节量 | 受烘焙分辨率上限 | ∞ 无限细节 |
| 显存 | 高度图大（1024³级）| 仅 MinMax（可低分辨率）|
| 是否"Unity 原汁原味" | ✅ 是 | ⚠️ 偏离（但结构仍是 GPU 驱动）|

**推荐混合路**：MinMax 仍烘焙（裁剪/LOD 必需，低分辨率即可），位移用实时噪声。这样既拿到 GPU 驱动的全部基础设施，又保住现有"视觉=碰撞"的核心优势、省掉大块显存。若你坚持纯 Unity 路，把顶点 shader 的位移函数换成高度图采样即可，其余架构不变。

> **本文余下章节默认按"混合路"描述（位移=实时噪声，MinMax=烘焙）**，并在涉及处标注"纯烘焙路"的差异。两者切换只影响顶点 shader 一个函数 + 是否加载高度图纹理，不影响整体架构。

---

## 4. 总体架构与数据流

```
                 ┌─────────────────────────── 一次性（参数/种子变更时）───────────────────────────┐
                 │  heightmap_baker.gd : Terrain.height_at  ──►  MinMax Texture2DArray(20层,RG32F,手动mip)  │
                 │  （混合路：只烘 MinMax；纯烘焙路：再烘 Height Texture2DArray(20层,RF,自动mip)）        │
                 └──────────────────────────────────────┬──────────────────────────────────────────┘
                                                        │ RID 注册到 GpuPlanet
   ┌────────────────────────── 每帧（渲染线程）───────────────────────────────────┐
   │                                                                                │
   │  Camera(render_data) ──┐                                                       │
   │  Planet 参数(set_frame_data) ┤                                                 │
   │                        ▼                                                       │
   │  gpu_lod_compositor.gd (CompositorEffect, PRE_OPAQUE)                          │
   │     ├─ lod_traverse.glsl     ping-pong 遍历 20 根 × maxLevel 层 → 活跃叶列表     │
   │     ├─ lod_build_patches.glsl 紧凑化 → patch 纹理(写) + count + lodTrans + AABB │
   │     └─ lod_cull.glsl(并入 build) 视锥 + (可选)Hi-Z + (可选)地平线               │
   │                          │ (storage 写)                                        │
   │                          ▼  ← 1 帧延迟（消除 storage→sampler 竞态）            │
   │  gpu_terrain.gdshader (MultiMass material, 读 patch 纹理)                      │
   │     INSTANCE_ID → texelFetch patch(A,B,C,face,uva..,lod,lodTrans)              │
   │     → bary 插值方向 d → 位移(实时噪声/高度图) → 焊接(FixLODConnectSeam) → 世界   │
   └────────────────────────────────────────────────────────────────────────────────┘
   ┌────────────── 每帧（渲染线程，PRE_OPAQUE 之后/深度可用后）─────────────────────┐
   │  gpu_hiz_compositor.gd (CompositorEffect) : 上一帧深度 ──min归约──► Hi-Z 金字塔  │
   └─────────────────────────────────────────────────────────────────────────────────┘
```

**线程归属**：
- `GpuPlanet`（Node3D，@tool）：主线程。拥有 MultiMesh + 材质 + 所有纹理/缓冲 RID；烘焙；把 RID + 参数推给 compositor。
- `gpu_lod_compositor` / `gpu_hiz_compositor`：渲染线程（`_render_callback`）。只读写 RID，不碰主线程节点。

---

## 5. 数据组织：20 面三角形四叉树寻址

### 5.1 根面定义（必须与现有实现一致）

复用 `planet.gd::_build_roots`：黄金比 `t=(1+√5)/2`，12 顶点归一化，20 面（含绕序）。GPU 端把这 20 面的 3 个单位角点 `A_f, B_f, C_f (f=0..19)` 作为常量数组/纹理常量。**烘焙、遍历、邻接表必须用同一张 20 面表（同样的绕序）**，否则跨面接缝会错位。

> 实现注意：把 `planet.gd::_build_roots` 的顶点/面表抽到一个共享 `gpu_ico.gd`（static），新旧实现共用，杜绝不一致。

### 5.2 节点 = (face, level, 三角点)

不预存全树（L=8 时 20×87381≈175 万节点，预存几何要 ~100MB）。改为**遍历时寄存器内递推**：

- 一个活跃节点在 ping-pong 缓冲里携带：`face(u32) level(u32) A,B,C(vec3×3) ua,va,ub,vb,uc,vc(face-bary ×6) lodTrans(u32×3, 继承自父)`
- 分裂时（与 `qnode._split` 同构）：
  ```
  ab = normalize(A+B); bc = normalize(B+C); ca = normalize(C+A)
  子0=[A,ab,ca]  子1=[ab,B,bc]  子2=[ca,bc,C]  子3=[ab,bc,ca]
  ```
  face-bary 中点同理取平均（ua 等）。
- 叶节点 → 发射为 patch。

### 5.3 ping-pong 遍历（照搬 Unity TerrainBuildCompute）

- 缓冲 A/B，各 `MAX_ACTIVE_NODES`（uint，包节点结构体）。
- 6 次 dispatch（maxLevel=8 可调），每次：`ConsumeBuffer(A)` → EvaluateNode → split 则 `AppendBuffer(B)` 4 子，否则 `AppendFinalNodeList`。
- `CopyCounterValue` 把 B 的计数转成下一次 dispatch 的 indirect args（Godot：用 `draw_list`/`compute_list` 不支持 indirect dispatch 计数 → 见 §7 妥协：固定上限 + 提前 break，或用 `buffer_get_data` 回读计数做下一次 dispatch 的 group 数）。

> **Godot 妥协点**：Unity 用 `CopyCounterValue` + indirect dispatch 做链式派发（计数驱动下一轮 group 数）。Godot RD compute 的 dispatch group 数是 CPU 传入的。两种处理：
> - **(i) 固定上限 dispatch**：每轮按 `MAX_ACTIVE_NODES` 上限 dispatch，kernel 内越界直接 return。简单、略浪费线程。
> - **(ii) 回读计数驱动**：每轮后 `buffer_get_data` 读计数算下一轮 group 数——但回读会 stall，不可取。
> - 推荐 **(i)**，配合紧凑化让活跃节点聚在前部。

---

## 6. 高度图与 MinMax 烘焙子系统

### 6.1 参数化

每个 face f 用 **face-barycentric (u,v)**，`u,v ∈ [0,1], u+v ≤ 1`：
```
dir(u,v) = normalize( A_f·(1-u-v) + B_f·u + C_f·v )
h(u,v)   = Terrain.height_at(dir)          // [-≈1, ≈1+]，现 height_at 返回值
world_r  = radius + h · maxHeight          // 与现 shader 一致
```

### 6.2 烘焙范围与分辨率

- 一张**方形**纹理覆盖 (u,v)∈[0,1]²，有效区为下三角 u+v≤1；上三角(u+v>1)存哨兵（min=+∞/max=-∞）使归约不污染。
- 边分辨率 `BAKE_RES`（默认 1024，质量档 2048）。纹理 (BAKE_RES+1)²。
- **混合路**只烘 MinMax，可降到 512（仅供 LOD/裁剪用，不需高频）。
- **纯烘焙路**烘 Height（位移用）需 ≥1024，最好 2048。

### 6.3 MinMax mip（不对称归约，照搬 Unity MinMaxHeights.compute）

- mip0：2×2 patch 归约，R=min G=max（RG32F）。
- 逐级：R←min(4 邻), G←max(4 邻)，共 log2(BAKE_RES)+1 级。
- 哨兵区(u+v>1)在归约中被忽略（min 取有效值、max 取有效值）。
- 可 CPU 烘（GDScript，慢但一次）或 GPU 烘（`heightmap_minmax.glsl`，快）。推荐 GPU 烘并缓存 `.res`。

### 6.4 存储格式

- `Texture2DArray`，20 层 = 20 face。
- MinMax：`DATA_FORMAT_R16G16_SFLOAT`（够用）或 RG32F。带 `STORAGE_BIT | SAMPLING_BIT`（GPU 烘用 storage、shader 采样用 sampler）。
- 导出 `.res`（`ResourceSaver`），文件名带种子 hash：`data/planet_minmap_<seedhash>.res`。种子/参数变 → 重烘（hash 比对，同 `REBUILD_KEYS` 思路）。

### 6.5 烘焙触发

- `GpuPlanet._ready` 或参数变更时：算 `(seed..., radius, maxHeight, BAKE_RES)` hash → 命中缓存 `.res` 直接 load，否则调 `heightmap_baker` 烘 + 存。
- 烘焙可放 `WorkerThreadPool`（现 `worker_pool.gd` 先例），避免卡主线程。

---

## 7. GPU 运行时管线（compute）

> 全部在新文件 `shaders/compute/lod_*.glsl`，`#[compute]` 头，照搬项目 compute 风格（push constant + UniformSetCacheRD）。

### 7.1 lod_traverse.glsl（遍历 + 评价 + 发射）
- 输入：20 根（常量）、camera pos（push constant）、MinMax 纹理（sampler）、参数（push constant/UBO）。
- ping-pong A/B 活跃节点缓冲（storage）。
- `EvaluateNode`（球面 + SSE）：
  ```
  d = distance(camPos, center_world)        // center_world = normalize(A+B+C)·(radius+midH·maxHeight)
  heightSpan = (maxH - minH) at MinMax.mip[level]   // 内容自适应几何误差
  g_err = heightSpan / 2^level              // 或保守上界 maxHeight/2^L
  split_d = g_err · sse_k / sseThresholdPixels       // sse_k = vp_h/(2·tan(fov/2))
  want_split = level < maxLevel and d < split_d
  ```
  > 注：Unity 用 `f=d/(n·c)` 纯距离；这里用项目已验证的 SSE，并用 MinMax 实际高差替代全局 maxHeight 上界 → 平坦区更省。
- split → append 4 子（中点递推）；否则 → append 到 `finalLeaves` 缓冲。

### 7.2 lod_build_patches.glsl（紧凑化 + 包围盒 + lodTrans + 裁剪）
- 遍历 `finalLeaves`，每叶生成一个 patch 写入 **patch 纹理**前部（atomicAdd 计数器）。
- 每个 patch 打包（6 个 RGBA texel）：
  - texel0: A.xyz + face
  - texel1: B.xyz + lod
  - texel2: C.xyz + pad
  - texel3: (ua,va,ub,vb)  face-bary 角
  - texel4: (uc,vc, lodTrans_AB, lodTrans_BC)   // 第三边 lodTrans 放 pad
  - texel5: (minH, maxH, pad, pad)              // 来自 MinMax mip
- **包围盒**：8 角点（3 角点 + 3 边中点 + 中心，各拉伸 ±minH/±maxH 沿径向）→ 世界 AABB。
- **视锥裁剪**：6 平面 × AABB（照搬 Unity FrustumCull）。
- **Hi-Z 遮挡裁剪**（Phase 5）：AABB 8 角投影 → UVD → 取对应 mip → reverse-Z 比较（Godot Forward+ 用 reverse-Z → 取 min）。
- **地平线裁剪**（可选，球面移植 `_is_below_horizon`）：现 CPU 版用球面三角；GPU 版等价公式，可显著降背面 patch。

### 7.3 patch 纹理布局
- 尺寸 `(6, MAX_PATCHES)`，`MAX_PATCHES` 默认 4096（maxLevel=8 实测可见 patch 量级几百~2k，留余量）。
- RGBA32F（精度优先）或 RGBA16F（省一半）。混合路位移走实时噪声、patch 纹理只存几何，16F 够。
- count 单独存一个 `u32` storage buffer。

### 7.4 hiz_reduce.glsl（Phase 5）
- 完全照搬 Unity `HizMap.compute`：Blit 深度→mip0，逐级 `min`（reverse-Z）。
- Godot 版注意：用 `CompositorEffect` 取 `render_data.get_render_scene_buffers().get_depth_layer(view)`，与大气 compositor 取深度同款。
- Win/D3D12 下 Godot 的 mips 可同贴图读写（不像 Unity Win 要 ping-pong）→ 直接 `.mips[i]`，省 ping-pong。

---

## 8. 渲染提交（MultiMesh + 顶点 shader）

### 8.1 共享 patch 网格（三角形网格，一次性建）
- `patchResolution = N`（默认 16，复用现参数）。
- 三角形网格顶点：`(i,j)` 遍历 `i,j≥0, i+j≤N`，barycentric `w=1-(i+j)/N, u=i/N, v=j/N`，UV 存 (u,v)。
- 顶点数 `(N+1)(N+2)/2`（N=16 → 153），三角形数 N²（→256）。
- 存为 ArrayMesh，给 MultiMesh 当 mesh。

### 8.2 MultiMesh
- `instance_count = MAX_PATCHES`，`visible_instance_count = MAX_PATCHES`（方案 A 坍缩）或回读值（方案 B）。
- transform 用单位（位置在 shader 里算），per-instance custom 不用——所有 patch 数据走纹理。
- 挂在 `GpuPlanet` 下一个 MeshInstance3D（`MultiMeshInstance3D`），`extra_cull_margin` 给足（位移后 AABB 变大，同现 `_ensure_root_meshes` 的处理）。

### 8.3 顶点 shader（新 `shaders/planet_gpu/terrain_gpu.gdshader`）
伪码：
```glsl
// vertex
int id = INSTANCE_ID;
if (id >= u_patchCount) { VERTEX = vec3(0.0); return; }   // 方案 A 坍缩
vec4 t0 = texelFetch(u_patchTex, ivec2(0,id), 0);   // A.xyz, face
vec4 t1 = texelFetch(u_patchTex, ivec2(1,id), 0);   // B.xyz, lod
vec4 t2 = texelFetch(u_patchTex, ivec2(2,id), 0);   // C.xyz, _
vec4 t3 = texelFetch(u_patchTex, ivec2(3,id), 0);   // ua,va,ub,vb
vec4 t4 = texelFetch(u_patchTex, ivec2(4,id), 0);   // uc,vc,lodTransAB,lodTransBC
vec4 t5 = texelFetch(u_patchTex, ivec2(5,id), 0);   // minH,maxH,_,_
vec3 A=t0.xyz, B=t1.xyz, C=t2.xyz; int lod=int(t1.w);
float u=UV.x, v=UV.y, w=1.0-u-v;
// patch 顶点在 face-bary：
float Uf = t3.x*w + t3.z*u + t4.x*v;   // ua·w+ub·u+uc·v
float Vf = t3.y*w + t3.w*u + t4.y*v;
vec3 dir = normalize(A*w + B*u + C*v);
float h = terrain_height(dir);          // 混合路：实时噪声；纯烘焙路：textureLod(u_heightmap, vec3(Uf,Vf,face), lod)
dir = FixLODConnectSeam(dir, u, v, w, lod, lodTrans...);   // §9 焊接
VERTEX = dir * (u_radius + h*u_maxHeight);   // 局部坐标（GpuPlanet 原点=行星中心）
// 法向：有限差分（同现 terrain.gdshader）
```
- fragment：复用现 `terrain_color` 逻辑（可 include 共享 .glsl 片段，或复制）。

### 8.4 uniform
- `u_patchTex`（sampler2D，patch 数据）、`u_patchCount`（int，或也放纹理/UBO）。
- 混合路：噪声 uniform（同现 terrain.gdshader）。
- 纯烘焙路：`u_heightmap`（sampler2DArray）、`u_minmax`（sampler2DArray）。

---

## 9. 接缝处理：三角形焊接 + 跨面邻接（最大风险点）

### 9.1 焊接原理（移植 FixLODConnectSeam）
沿一条共享边，高精度侧（lod 大）有 `2^lodDelta` 倍的边缘顶点；把这些多余顶点沿边滑动到低精度侧的对应位置，消除 T-junction。方形网格用 `vertexIndex % 2^lodDelta`；三角形网格同理，只是边方向是球面测地。

### 9.2 需要每边邻居 LOD
patch 有 3 条边（AB、BC、CA），每边需知道邻居 patch 的 lod → `lodDelta = max(0, neighborLod - selfLod)`。这就是 patch 数据里 `lodTrans_AB/BC/CA` 的来源。

### 9.3 邻居 LOD 怎么来（LODMap 构造）
- **面内邻居**：同一 face 的相邻叶 patch，靠 face-bary 边中点匹配。遍历时建立 `edgeKey → lod` 哈希（edgeKey = 两端 face-bary 中点对的量化键），build_patches 阶段查。
- **跨面邻居**：icosahedron 30 条边，每边被 2 个 face 共享。预计算 `gpu_ico_adjacency` 表：对每条 face 边，给出"对面 face + 对面边的编号 + 绕序方向"。查表后同样用边中点匹配。

> 这一步是整个移植**最复杂、最容易出 bug** 的地方。建议分期：Phase 4 先做**面内焊接**（覆盖绝大多数接缝，跨面的 30 条边暂时用裙边或留小缝），Phase 4.5 再补**跨面邻接**。

### 9.4 fallback：裙边
若焊接在球面上调试代价过高，patch 网格可临时挂裙边（复用现 `patch_builder.gd` 思路）盖缝——但这背离"完全移植 Unity 焊接"的目标，仅作兜底。

---

## 10. 裁剪

- **视锥**：AABB × 6 平面，照搬 Unity（Godot `Camera3D.get_frustum()` 可在 CPU 构造平面推给 compute，或在 compute 内从 VP 矩阵构造）。
- **Hi-Z**（Phase 5）：上一帧深度金字塔，reverse-Z 取 min。Godot Forward+ 默认 reverse-Z。
- **地平线**（可选）：移植 `_is_below_horizon`，球面角半径公式直接搬，GPU 版无难度。近地行走时砍掉约一半背面 patch，收益大。

---

## 11. 节点脚本与场景挂载（不碰现有实现）

### 11.1 新文件清单
```
scripts/planet/gpu/
  gpu_planet.gd              @tool Node3D  拥有 MultiMesh+纹理+材质；烘焙调度；推 RID/参数给 compositor
  gpu_lod_compositor.gd      CompositorEffect(PRE_OPAQUE)  dispatch lod_traverse + lod_build_patches
  gpu_hiz_compositor.gd      CompositorEffect(深度后)      dispatch hiz_reduce（Phase 5）
  heightmap_baker.gd         @tool RefCounted  从 Terrain.height_at 烘 MinMax(±Height) Texture2DArray → .res
  gpu_ico.gd                 static  20 面 + 30 边邻接表（新旧实现共享，杜绝不一致）
scenes/
  gpu_planet.tscn            新场景：GpuPlanet 节点（独立可实例化，与现 Planet 并存）
shaders/planet_gpu/
  terrain_gpu.gdshader       spatial：INSTANCE_ID→patch 纹理→bary→位移→焊接
  patch_mesh.gd              (或 gd 内联) 建共享三角形 patch 网格
shaders/compute/
  lod_traverse.glsl          遍历+评价+发射（ping-pong）
  lod_build_patches.glsl     紧凑化+包围盒+lodTrans+裁剪 → patch 纹理+count
  hiz_reduce.glsl            深度金字塔（Phase 5）
  heightmap_minmax.glsl      MinMax 归约（可选 GPU 烘）
data/   (生成物，git 可忽略或纳入)
  planet_minmax_<seedhash>.res
  planet_height_<seedhash>.res   (纯烘焙路)
```

### 11.2 挂载与切换
- 新场景 `gpu_planet.tscn` 独立实例化；`test_planet.tscn` 或新 `test_gpu_planet.tscn` 里**二选一**启用：
  - 测 GPU 版：旧 `Planet` 节点 `visible=false` + `process_mode=DISABLED`；加 `GpuPlanet`。
  - 测旧版：反之。
- 两个新 CompositorEffect 加到 `WorldEnvironment.compositor.compositor_effects`（与现 atmosphere 同列）。`gpu_lod_compositor` 默认 `enabled=false`，仅当 GpuPlanet 激活时由 GpuPlanet 置 `enabled=true`（避免旧版运行时空跑 compute）。
- 参数：新建一份 `PlanetParams` 子资源给 GpuPlanet（或复用现有 params 实例——它只读不写，安全）。

### 11.3 与现有实现零耦合的保证
- 新代码只**读** `Terrain.height_at`（烘焙时）、`PlanetParams`（参数）、`gpu_ico.gd`（共享静态表）。
- 不 import / 不修改 `planet.gd / qnode.gd / patch_builder.gd / worker_pool.gd / terrain.gdshader`。
- 唯一共享写点是 `gpu_ico.gd`（新文件，旧实现如要共用需小改 import——但**不必**，旧实现已有内联 icosahedron；新表独立即可，只要数值一致）。

---

## 12. 与现有系统的关系

| 现有子系统 | 影响 | 说明 |
|-----------|------|------|
| 碰撞/planet_walker | **无** | 继续用 CPU `Terrain.height_at` 实时噪声。GPU LOD 纯视觉。混合路下视觉=碰撞逐位一致。 |
| 大气/海/云 | **无** | 它们读 Planet uniform；GpuPlanet 照推同样 uniform（或共用同一 PlanetParams）。Hi-Z compositor 与大气 compositor 并列，互不干扰。 |
| 旧 Planet LOD | **无** | 保留作 fallback。两者不并存运行（二选一）。 |
| camera_focus/player | **无** | 相机/角色不关心行星实现；GpuPlanet 同样提供行星中心位（供 camera_focus 贴焦）。 |

---

## 13. 实施分期（建议顺序，每期可独立验证）

| Phase | 内容 | 验收 |
|-------|------|------|
| **0** | `gpu_ico.gd`（20 面+30 边表）、`heightmap_baker` 烘 MinMax（CPU 版先）→ `.res` | 烘出的 minmax 与 `Terrain.height_at` 抽样比对误差 ≤ 量化精度；可视化 minmax 纹理正确 |
| **1** | `GpuPlanet` + 共享 patch 网格 + MultiMesh + 顶点 shader（**固定全 LOD**：所有叶=level 0，不细分，先跑通 instance + 位移） | 能看到一颗位移正确的球面行星，MultiMesh 渲染，无 compute LOD |
| **2** | `lod_traverse.glsl` GPU 遍历 + SSE 评价 → patch 纹理 | 近处细分、远处粗，patch 数随距离变化；编辑器/运行时一致 |
| **3** | 视锥裁剪（+ 地平线可选） | 视锥外/背面 patch 不渲染；旋转无大面积 pop |
| **4** | 面内接缝焊接（lodTrans + FixLODConnectSeam 三角形版） | 面内不同 LOD 交界无裂缝 |
| **4.5** | 跨面邻接（30 边表）焊接 | 全球无裂缝 |
| **5** | Hi-Z compositor + 遮挡裁剪 | 山后/地平线后地形被遮挡剔除；快转无闪烁（1 帧延迟可接受）|
| **6** | 优化：方案 B 回读 count、MinMax 内容自适应 LOD 调参、显存/算量 profiling | 达到或优于旧版帧时（旧版近地瓶颈在 physics，GPU 版 LOD 部分应明显更轻）|

**算量预估（方案 A，MAX=4096）**：坍缩空实例 ≈ (4096−可见)×153 顶点 ≈ 最坏 ~60 万空顶点/帧，现代 GPU 可忽略；可见 patch × 256 三角 ≈ 几十万三角，远低于旧版合并 mesh。LOD compute 每帧 6 dispatch × 固定上限 group，总量级与大气 compute 相当。

---

## 14. 风险与未决问题

1. **跨面焊接（§9.3）**：30 边邻接表 + 球面测地边方向，是最大不确定性。缓解：分期，先用裙边兜底跨面，面内先焊。
2. **Godot compute 无 indirect dispatch 计数（§5.3）**：用固定上限 dispatch + 越界 return。浪费可量化、可接受。
3. **gdshader 内建名确认**：`INSTANCE_ID` / `texelFetch`(vertex) / `textureLod` 在目标 Godot 4.7 的确切写法，实现首日先写最小用例验证（项目 `noise_test.gdshader` 可作模板）。
4. **烘焙分辨率 vs 显存**：纯烘焙路 20×2049² RF + mip ≈ 200MB+；混合路只 MinMax ≈ 几十 MB。倾向混合路。
5. **storage→sampler 1 帧延迟**：LOD 滞后 1 帧，快速机动时 patch 集合晚 1 帧更新——肉眼基本不可见，极端快转可能瞬间略粗。可接受。
6. **编辑器 @tool 下 compositor 行为**：大气 compositor 在编辑器视口已验证可用（取 render_data 相机）；LOD compositor 同理，但 PRE_OPAQUE 回调在编辑器是否触发需实测。
7. **MultiMesh instance 上限 / patch 纹理尺寸**：MAX_PATCHES 取 4096 应够 maxLevel=8；若调更高 maxLevel 需相应放大并重估坍缩开销。
8. **位移一致性的边界**（混合路）：实时噪声 ∞ 细节，但 MinMax 烘焙分辨率决定 LOD/裁剪精度——平坦区 MinMax 可能低估局部起伏导致晚细分；可加保守系数。

---

## 15. 验收标准（整体）

- 全球任意距离/视角：无裂缝（Phase 4.5 后）、无明显 pop-in（SSE + 1 帧延迟）、无穿模（视觉与碰撞一致，混合路）。
- 帧时：LOD + 渲染部分 ≤ 旧版（旧版主线程 select_lod + ArrayMesh 合并是热点；GPU 版把这部分搬走，预期更稳）。
- 切换：`gpu_planet.tscn` 与旧 `planet.tscn` 可在场景里切换启用，互不污染。
- 零侵入：`git diff` 不触碰 `scripts/planet/planet.gd`、`qnode.gd`、`patch_builder.gd`、`terrain.gdshader`。

---

## 16. 待你拍板的两个决策

1. **位移来源**：混合路（实时噪声位移 + 烘焙 MinMax，**推荐**）vs 纯烘焙路（位移也走高度图，最 Unity）。→ 决定顶点 shader 一个函数 + 是否加载高度图纹理 + 烘焙分辨率/显存。
2. **接缝**：坚持焊接（分期，跨面有风险）vs 临时裙边兜底（稳但非 Unity 原汁原味）。

确认后即可进入 Phase 0 实现。
