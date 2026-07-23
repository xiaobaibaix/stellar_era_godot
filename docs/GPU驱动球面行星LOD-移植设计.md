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

> ⚠️ **Phase 2 实现偏离**：实际未用 ping-pong，改用**单遍距离壳测试**（数学等价、绕开 Godot 无 indirect-dispatch-count 的坑）。见 §17.1。本节原文保留为设计意图，供 Phase 6 优化回 ping-pong 时参考。

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

> ⚠️ **Phase 3 v2 实现偏离**：从 vertex 网格 `(BAKE_RES+1)²` 改为 cell 网格 `BAKE_RES²`，标准 2×2 gather 归约，能与 Godot RD Texture2DArray 自动 mip 链对齐。详见 §18.2。
- 一张**方形**纹理覆盖 (u,v)∈[0,1]²，有效区为下三角 u+v≤1；上三角(u+v>1)存哨兵（min=+∞/max=-∞）使归约不污染。
- 边分辨率 `BAKE_RES`（默认 1024，质量档 2048）。Phase 3 v2 cell 布局：纹理 BAKE_RES²（cell 中心采样, `BAKER_VERSION=2`）。
- **混合路**只烘 MinMax，可降到 512（仅供 LOD/裁剪用，不需高频）。Phase 3 实际用 `GpuLodCompositor.BAKE_RES = 512`。
- **纯烘焙路**烘 Height（位移用）需 ≥1024，最好 2048。

### 6.3 MinMax mip（不对称归约，照搬 Unity MinMaxHeights.compute）

> ⚠️ **Phase 3 v2 实现**：标准 2×2 gather 归约（取代 v1 vertex 网格的 scatter）；mip 选取用 `mip = bake_res_log2 - level`（§18.5）。
- mip0：cell 中心采样, R=G=height（单点采样）。
- 逐级：parent cell 从 4 个 child cell gather 取 min/max，共 log2(BAKE_RES)+1 级。
- 哨兵区(u+v>1)在归约中被跳过（`GpuMinMaxData._build_face_pyramid`）。
- 可 CPU 烘（GDScript，慢但一次）或 GPU 烘（`heightmap_minmax.glsl`，快）。Phase 3 用 CPU 烘 + `.res` 缓存（`HeightmapBaker.bake_or_load`）。

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

> ⚠️ **Phase 2 实现偏离**：① 不用 ping-pong A/B，改单遍距离壳（§17.1）。② icosahedron 角点硬编码进 shader 常量，不走 uniform/纹理常量（§17.3）。③ 紧凑发射 patch 与遍历合并成同一 kernel，无独立 build_patches（§17.5）。本节原文保留为设计意图。
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

> ⚠️ **Phase 2 实现偏离**：本 kernel 当前不存在，紧凑发射直接合进 `lod_traverse.glsl`（§17.5）。
> ⚠️ **Phase 3 实现偏离**：裁剪走**新起 `lod_cull.glsl`** 而非扩展 lod_traverse；双阶段架构 trav_tex → cull_tex、各自 counter；视锥平面走 UBO（§18.1、§18.3）。本节原文保留为后续 Phase 的参考蓝图。
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

> ⚠️ **Phase 2 实现偏离**：① 实际 `maxLevel=6`（`gpu_planet.gd::MAX_GPU_LEVEL`），非 8（§17.2）。② patch 纹理高度 = `MAX_PATCHES + 1`，末行（`META_ROW`）存 count，**不是独立 storage buffer**（§17.4）。
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

> ⚠️ **Phase 3 实现状态**：视锥裁剪已完成（lod_cull.glsl + GpuLodCompositor 双阶段 + GpuPlanet 推 6 视锥平面 UBO，详见 §18）；Hi-Z 与地平线裁剪留 Phase 5/6。

- **视锥**（**✅ Phase 3 已完成**）：AABB × 6 平面，照搬 Unity 的 P-vertex 测试逻辑。Godot `Camera3D.get_frustum()` 在主线程算 6 平面（Plane, **外向法线** —— 与 Unity 相反），推给 GpuLodCompositor，`_update_frame_ubo` 打包时翻 N 成内向 (`vec4(-N, +d)`) 喂给 shader，每帧 `buffer_update` 到 FrameData UBO（§18.3 / §18.8）。
- **Hi-Z**（Phase 5）：上一帧深度金字塔，reverse-Z 取 min。Godot Forward+ 默认 reverse-Z。
- **地平线**（可选，Phase 3.5/6）：移植 `_is_below_horizon`，球面角半径公式直接搬，GPU 版无难度。近地行走时砍掉约一半背面 patch，收益大。Phase 3 暂未做（§18.6）。

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
  lod_traverse.glsl          遍历+评价+发射+face-bary（Phase 2 单遍距离壳, Phase 3 加 bary 输出）
  lod_cull.glsl              视锥裁剪（Phase 3 新增; 读 trav_tex, 采样 MinMax, frustum 测试, 写 cull_tex）
  lod_build_patches.glsl     (未实现; 原计划紧凑化+包围盒+lodTrans+裁剪 → 由 traverse + cull 双阶段取代)
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
| **2** | `lod_traverse.glsl` GPU 遍历 + SSE 评价 → patch 纹理 | 近处细分、远处粗，patch 数随距离变化；编辑器/运行时一致。**✅ 已完成**（实现偏离见 §17：单遍距离壳取代 ping-pong、maxLevel=6、硬编码 ico、patch 纹理末行存 count、无独立 build_patches）|
| **3** | 视锥裁剪（+ 地平线可选） | 视锥外/背面 patch 不渲染；旋转无大面积 pop。**✅ 视锥部分已完成**（cell 布局 baker 重构 + MinMax Texture2DArray 上传 + lod_cull.glsl + GpuLodCompositor 双阶段(traverse+cull) + GpuPlanet 推 6 视锥平面; 实现偏离见 §18; 地平线裁剪留 Phase 3.5/Phase 6）|
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

## 16. 待你拍板的两个决策（已拍板）

1. **位移来源** → **已选混合路**（实时噪声位移 + 烘焙 MinMax）。
   - 落地证据：`shaders/planet_gpu/terrain_gpu.gdshader:199` 顶点 shader 跑 `terrain_height(d)` 实时噪声；`scripts/planet/gpu/heightmap_baker.gd:5` 注释明确"混合路：位移仍走实时噪声，MinMax 只供 GPU LOD/裁剪"。
   - 后续若要切纯烘焙路：把 vertex 的 `terrain_height(d)` 换成 `textureLod(u_heightmap, vec3(Uf,Vf,face), lod)` + 加载 `planet_height_<seedhash>.res`。架构不变。

2. **接缝** → **已选焊接**（分期：Phase 4 面内先做，Phase 4.5 跨面后做）。
   - 落地证据：`gpu_ico.gd::build_adjacency()` 已预建 30 边邻接表（adj[fi][ei] = {neighbor_face, neighbor_edge, flipped}）+ 流形自检（flipped 恒 false）供 Phase 4.5 用。

---

## 17. Phase 2 实现决策（与原设计的偏离）

Phase 2 实现时做了 5 处重要偏离，本节固定下来，避免 Phase 3+ 漂移。**后续 Phase 的实现一律以本节为准**；§5、§7 原文保留为"最初设计意图"。

### 17.1 单遍距离壳测试（取代 ping-pong 6 遍遍历）★ 最大偏离

**原文**（§5.3、§7.1）：照搬 Unity，ping-pong A/B 缓冲，每层一次 dispatch 共 6 次，层间靠 `CopyCounterValue` 在 GPU 内链式传 count。

**实际实现**（`lod_traverse.glsl`）：**单遍、无 ping-pong**。每个候选节点 `(face, level, idx)` 独立用距离壳判定是不是叶：

```
split_d(L) = C_const / 2^L     // C_const = maxHeight · K/T, K=vp_h/(2·tan(fov/2)), T=sseThresholdPixels
level==0:              dist >= split_d(0)             → 叶（根不细分）；否则根细分往下找
level>0, <maxLevel:    split_d(L) <= dist < 2·split_d(L) → 叶（父细分了、自己不细分）
level==maxLevel:       dist < 2·split_d(L)            → 叶（最深，父细分了）
```

**为什么成立**：`split_d(L)` 随 L 单调降 → `dist < 2·split_d(L) = split_d(L-1)` 蕴含 `dist < split_d(L-2) < ... < split_d(0)`，即所有祖先都细分 → 本节点存在；再加 `dist >= split_d(L)` → 自己不细分 → 是叶。数学证明见 `lod_traverse.glsl:7-13` 注释。

**收益**：
- 绕过 §5.3 的 Godot 妥协点（无 indirect dispatch count）—— 整个问题不存在了。
- 少 5 次 dispatch + 5 次 barrier。
- 节点寄存器内中点递推（MSB 先），无任何跨 invocation 状态。

**代价**：
- 总 invocation 数 = `Σ 20·4^L` (L=0..maxLevel)。L=6 时 = `(20·4^7-1)/3 - 1 ≈ 273k`，远多于实际"选中叶"数（几百～2k），多出来的 invocation 早 return（距离壳不满足）。算力冗余可接受。
- Phase 6 想优化时再回 ping-pong（但当前看没必要）。

**对其他 Phase 的影响**：
- Phase 3 裁剪：直接在距离壳通过后加 AABB×6 平面测试，不影响架构。
- Phase 4 焊接：**需要加一轮单独的紧凑化 dispatch**（仍无需 ping-pong）算 lodTrans，因为单遍测试里每个节点不知道邻居 LOD。lodTrans 走 edgeKey→lod 哈希（§9.3）。

### 17.2 maxLevel 暂定 6（不是 8）

**原文**（§5.2、§7.3、§13）：maxLevel=8，`MAX_PATCHES=4096`，"maxLevel=8 实测可见 patch 量级几百~2k"。

**实际实现**（`gpu_planet.gd::MAX_GPU_LEVEL = 6`）：硬限到 6。原因：单遍遍历下 L=8 总 invocation = `(20·4^9-1)/3 ≈ 4.4M`，太重；4^6=4096 节点/面已足够近地细节。

**待解**：L=8 需要 ping-pong（§5.3 原方案）或更激进的剪枝（距离壳在根/低层就 reject 整子树）。Phase 6 再权衡。

### 17.3 icosahedron 硬编码到 shader 常量（取代 uniform/纹理常量）

**原文**（§5.1）：20 面的 3 个单位角点作为常量数组/纹理常量。

**实际实现**（`lod_traverse.glsl:37-49`）：`const float PHI`、`const vec3 RAW[12]`、`const int FACES[60]` 直接硬编码到 GLSL，与 `gpu_ico.gd::RAW_VERTS/FACES` 逐位一致。

**收益**：消除 uniform buffer 绑定，少一个 set。

**风险**：两份硬编码（gd 一份、glsl 一份）必须同步。`gpu_ico.gd::verify()` 已加完整性自检（顶点单位化、面索引范围、30 边流形），但**没跨 gd/glsl 一致性自检**——Phase 0 的 minmax_selftest 可顺带加一条：跑 `lod_traverse.glsl` 输出每面 A 角点，与 `gpu_ico.face_corners` 比对。

### 17.4 patch 纹理末行存 count（取代独立 storage buffer）

**原文**（§7.3）："count 单独存一个 u32 storage buffer。"

**实际实现**（`lod_traverse.glsl:51`、`terrain_gpu.gdshader:22`）：count 写进 patch 纹理第 `MAX_PATCHES` 行（`META_ROW = MAX_PATCHES = 4096`），即 `patch_tex` 高度 = `MAX_PATCHES + 1`。Phase 2 末由单线程 mode（`level=-2`）`imageStore(patch_tex, ivec2(0, META_ROW), count)` 完成。vertex shader `texelFetch(u_patchTex, ivec2(0, META_ROW), 0).x` 读 count 做坍缩守卫。

**收益**：少一个 SSBO 绑定；vertex shader 读 count 不依赖额外 uniform。

**代价**：patch 纹理多一行（4097 行）。可忽略。

### 17.5 `lod_build_patches` 合并进 `lod_traverse`（不分两遍）

**原文**（§7.2）：单独的 `lod_build_patches.glsl` kernel 做紧凑化 + 包围盒 + lodTrans + 裁剪，遍历完 finalLeaves 后跑。

**实际实现**：`lod_traverse.glsl` 自己 atomicAdd 计数 + imageStore 6 texel 紧凑发射到 patch 纹理前部。**没有独立的 build_patches kernel**。

**收益**：少一次 dispatch、少一个中间 buffer（finalLeaves）。

**代价**：
- 当前只写 texel 0..2（A/B/C/face/lod），texel 3..5（bary/lodTrans/minmax）恒 0。
- Phase 3（裁剪）需要 MinMax 包围盒 → 这时 lod_traverse 需要采样 MinMax 纹理写 texel 5，或者**重起一个 build_patches kernel 专门填包围盒 + 裁剪**（设计原方案）。建议 Phase 3 走后者：lod_traverse 保持"只选叶+紧凑发射 A/B/C"轻量化，新起 `lod_cull.glsl` 读 MinMax、构 AABB、6 平面裁剪、重写紧凑 patch 纹理（in-place 或 ping-pong）。

### 17.6 Phase 2 未做的子系统（给后续 Phase 留接口）

| 子系统 | 当前状态 | 后续 Phase 怎么接 |
|--------|---------|-----------------|
| MinMax 纹理上传 GPU | **✅ Phase 3 已完成**：`GpuLodCompositor.set_minmax(data)` 把 `GpuMinMaxData.build_pyramid()` 上传成 20 层带 mip 的 RD Texture2DArray（`gpu_lod_compositor.gd:222-249`）| 已绑进 `lod_cull.glsl` set 2 sampler2DArray |
| lodTrans（texel 4.zw）| 恒 0 | Phase 4 起填 |
| MinMax（texel 5）| **✅ Phase 3 起填**：`lod_cull.glsl` 通过的 patch 写 `(minH, maxH, 0, 0)` 到 cull_tex texel 5 | Phase 6 内容自适应 LOD 也可用 |
| `gpu_hiz_compositor.gd` | 不存在 | Phase 5 |
| 跨面邻接表使用 | `gpu_ico.build_adjacency()` 已就绪但未使用 | Phase 4.5 |

---

## 18. Phase 3 实现决策（与原设计的偏离）

Phase 3 实现时做了若干偏离，本节固定下来，避免 Phase 4+ 漂移。**后续 Phase 的实现一律以本节为准**。

### 18.1 双阶段架构: traverse 输出 → cull 输入（取代 in-place 紧凑化）

**原文**（§7.2、§17.5 建议项）：`lod_build_patches.glsl` 单遍紧凑化(in-place 或 ping-pong)，遍历完 finalLeaves 后跑。

**实际实现**：双阶段、双纹理、双 counter。
- `_trav_tex[2]` (intermediate)：`lod_traverse.glsl` 选中的叶原子紧凑发射到此。
- `_cull_tex[2]` (final)：`lod_cull.glsl` 读 `_trav_tex`、构 AABB、6 平面裁剪、原子紧凑发射到此。
- 各自独立 counter；vertex 读 `_cull_tex`(`get_read_texture` 返回 `_tex2drd`，包 `_cull_tex`)。

**为什么成立**：原子紧凑不能 in-place(同纹理 race)；双纹理 + barrier 隔离是 Vulkan/GL 标准 storage image 模式。

**收益**：traverse 和 cull 独立调试、可单独禁用(cull 不就绪时 vertex 读全 0 → 坍缩无渲染，不崩)；内存代价 = 4 张 6×4097 RGBA32F = ~1.5MB，可忽略。

**对其他 Phase 影响**：Phase 4 焊接可以在 cull 之后再加 `lod_weld.glsl` 第三阶段(trav → cull → weld)，或在 cull 内顺带做(看是否需要邻居 LOD)。

### 18.2 cell 布局 baker（取代 vertex 网格，BAKER_VERSION=2）

**原文**（§6.1）：bake_res² cells per face，cell center 在 `(i+0.5)/bake_res, (j+0.5)/bake_res`，`i+j < bake_res` 时 cell 在三角形内。

**Phase 0 v1 实际实现**：vertex 网格 `(bake_res+1)²`，每顶点存 (min, max)；scatter 归约产出 `(bake_res/2+1)²` 一级。

**Phase 3 v2 实际实现**（`gpu_minmax_data.gd::BAKER_VERSION = 2`、`heightmap_baker.gd`）：回到 cell 布局 `bake_res²`，标准 2×2 gather 归约。这样 mip 链 `bake_res → bake_res/2 → ... → 1` 与 Godot RD Texture2DArray 自动 mip 链对齐（Godot 对 mip0=W×H 推导 `mip_k = max(1, floor(W/2^k))`）；旧 vertex 布局 mip1=`floor((bake_res+1)/2)²`=(bake_res/2)² 与 scatter 产出 (bake_res/2+1)² 不匹配 → 无法用 Texture2DArray 自动 mip。

**为什么成立**：Godot RD `Texture2DArray` 只接受标准 2×2 gather mip 链。cell 布局是唯一能与 Godot 自动 mip 对齐的选择。

**收益**：能用 Godot Texture2DArray 自动 mip 链，texture_create + texture_update 一对一映射 pyramid 层级。

**代价**：cell 单点采样不能严格包夹 cell 内峰值（理论上比 vertex 4 角点 min/max 稍宽），minmax_selftest 已加近似刻画测试（C 节）。

**数据迁移**：`BAKER_VERSION` 进 `seed_hash`，旧缓存自动失效；首次重烘后 `.res` 自动更新。

### 18.3 视锥平面走 UBO（取代 push constant）

**原文**（§10）："6 平面推给 compute"（未指明通道）。

**实际实现**（`lod_cull.glsl:29-34`、`gpu_lod_compositor.gd::_update_frame_ubo`）：6 视锥平面走 `std140 uniform FrameData` UBO，每帧 `buffer_update`。

**为什么不用 push constant**：6 平面 = 96 字节 + cam/planet/consts 48 字节 = 144 字节，超过 Vulkan 最小 push constant 上限（128 字节）。UBO 是 std140，每帧 `buffer_update` 性能可接受（~微秒级）。

**约定**（法线方向）：`Camera3D.get_frustum()` 返回**外向法线**（指向视锥外，与 Unity 相反，详见 §18.8）。`_update_frame_ubo` pack 时翻 N 成内向：`vec4(-n.x, -n.y, -n.z, +d)`，shader 测试 `dot(plane.xyz, p_vert) + plane.w < 0` 表示 P-vertex 在平面外侧 → 整个 AABB 在此平面外 → cull。

### 18.4 face-bary 在 traverse 递推中同步算（取代 build_patches 阶段重算）

**原文**（§7.1、§17.5）：traverse 只写 A/B/C/face/lod 到 texel 0..2，bary/lodTrans/minmax 在 build_patches 阶段填。

**实际实现**（`lod_traverse.glsl:85-122`）：face-bary 与方向同步递推——初始 `A=(0,0), B=(1,0), C=(0,1)`，子节点角点 bary = 父对应角点 bary 或父两角点 bary 中点。写 texel 3 `(ua,va,ub,vb)`、texel 4 `(uc,vc,_,_)`。

**为什么成立**：traverse 的中点递推算法天然知道每个角点的 face-bary（每步只需 1 次加法 + 1 次除 2）；cull 不需要重新从 (A,B,C) 世界方向反推 bary（那需要在球面上解方程）。

**收益**：cull 直接读 texel 3/4 拿到 bary_center，O(1) 采样 MinMax。

**代价**：traverse shader 多 3 个 vec2 寄存器（ua/va, ub/vb, uc/vc + 临时中点），可忽略。

### 18.5 MinMax mip 选取: `mip = bake_res_log2 - level`

**原文**（§6.3）：未明确。

**实际实现**（`lod_cull.glsl:87-90`）：`mip = clamp(bake_res_log2 - level, 0, bake_res_log2)`，对应 cell footprint 与 patch footprint size-matched：
- `bake_res=512, level 0`: mip=9 (single cell for whole face) ✓
- `bake_res=512, level 6`: mip=3 (64 cells per side; cell_footprint=1/64 of face ≈ patch_footprint) ✓

**为什么 size-matched**：cell footprint = `(2^mip / bake_res)²`，patch footprint = `(1/2^level)²`。两者相等 → `2^mip / bake_res = 1/2^level → mip = log2(bake_res) - level`。

**采样点**：patch bary_center `((ua+ub+uc)/3, (va+vb+vc)/3)`，nearest filter → 落到包含 bary_center 的那个 cell。

**保守性**：cell_footprint ≈ patch_footprint → 单 cell 的 min/max 基本包住整个 patch（边界相邻 cell 的极值可能漏，但因 cell 与 patch 同尺寸，遗漏概率低）。若 Phase 6 需更保守的包络，可在 patch footprint 内取 4 个角点 + 中心共 5 个 cell 的 min/max 聚合（5 次 textureLod）。

### 18.6 暂不做地平线裁剪（留 Phase 3.5 或 Phase 6）

**原文**（§10）："地平线（可选）：移植 `_is_below_horizon`，球面角半径公式直接搬，GPU 版无难度。"

**实际实现**：Phase 3 仅做视锥裁剪。地平线裁剪暂留，原因：
- 视锥裁剪已能砍掉背面行星的大部分 patch（远端 + 相机外侧）。
- 地平线裁剪主要收益在近地行走时砍背面行星（约一半），目前测试场景以轨道视角为主。
- 实现简单（球面角半径公式直接搬），Phase 6 内容自适应 LOD 一并做更合适。

**对 Phase 4+ 影响**：无。地平线裁剪可作为 cull shader 内多一个测试条件，或独立第三阶段 `lod_horizon_cull.glsl`。

### 18.7 MinMax texel5 字段复用

**原文**（§7.3 终极布局）：texel5 = (minH, maxH, _, _)。

**实际实现**（`lod_cull.glsl:137`）：通过裁剪的 patch 写 `vec4(minH, maxH, 0.0, 0.0)` 到 cull_tex texel 5。

**未来扩展**：texel5.zw 留给 Phase 6 内容自适应 LOD（如根据实际 min/max 调整 patch 分辨率，或写入"几何复杂度"度量）。

### 18.8 Phase 3 自检与 frustum 打包符号约定

**自检**：`scripts/planet/gpu/cull_selftest.gd` + `scenes/cull_selftest.tscn`（F6 运行，纯 CPU，不需 RenderingDevice）。验证三项：
- (A) Frustum 平面打包约定：合成**内向法线**平面，验证 shader `dot(N,P)+plane.w<0` 判外侧公式。涵盖 d=0（left/right/top/bottom）和 d≠0（near/far）两类平面。
- (B) P-vertex AABB 测试：合成 box-frustum `[-1,1]³` + 8 案例（中心/穿过/越界/角接触），验证 lod_cull.glsl P-vertex 选取公式。
- (C) dispatch 组数数学：level 0..6 节点数与 ceil(nodes/64) 对应。

**关键事实：Godot `Camera3D.get_frustum()` 返回外向法线**（指向视锥外，与 Unity 习惯相反）。运行时 dump 验证：相机在视锥内时，对 far 平面 `distance_to(cam)` 是巨大负数（如 −199729），对 left/top/right/bottom 是 0（这 4 平面过相机原点），只有 near 是小的正数 —— 若法线内向应全部为正。外向法线下：视锥内 `dot(N,P) < d`，视锥外 `dot(N,P) > d`。

**打包：翻 N 让 shader 看到内向法线**：lod_cull.glsl 的 P-vertex 测试（选 max-dot 方向角点 + `dot+plane.w<0` 判外侧）是按内向法线设计的。Godot 喂的是外向 → 打包时把 N 翻成内向：`vec4(-N.x, -N.y, -N.z, +d)`。同一几何平面，内向 N' = −N 时 d' = −d，shader 期望的 `plane.w = -d' = +d`。shader 与 cull_selftest 均不需要改。

**走过的弯路**：一度假设 Godot get_frustum 返回内向（误把 Unity 习惯套到 Godot），运行时 frustum dump 当场证伪 —— trav_count=242 全被 cull 掉。教训：跨引擎移植几何约定（法线方向、平面方程符号）必须运行时打印验证，文档/经验不能直接照搬。


---

## 19. Phase 4 实现决策（面内接缝焊接）

Phase 4 完成**面内**（同一 ico face 内相邻 LOD patch）的 T-junction 裂缝焊接。**跨面**（ico 30 边）留 Phase 4.5。视觉上：面内无裂缝，跨面边可能仍有裂缝（用户截图确认）。

### 19.1 LOD lookup texture（lodtex）布局

`lodtex: Texture2DArray 20 layer × 64×64 R8UI`。每 cell 1 byte 存"覆盖该 cell 中心的叶节点的 level"。`LODTEX_RES = 64 = 2^MAX_GPU_LEVEL`，cell (i,j) 中心 = `((i+0.5)/64, (j+0.5)/64)`。

距离壳保证同 face 内叶 face-bary 三角形不相交 → 每 cell 唯一 owner → 无需原子。

### 19.2 cell 归属约定

cell (i,j) 归"cell 中心 face-bary 落在的叶"。由 `lod_lodtex.glsl` rasterize 模式 per-leaf 光栅化三角形（AABB 加速 + barycentric inside-test，winding-agnostic）。

### 19.3 边中点 + 整 cell eps 外推 query（cull 端）

cull 对每个通过 frustum 的叶，3 条边各 sample 一次：
- `mid = (corner_bary + corner_bary) * 0.5`
- `outward = mid - 对角 bary`
- `query_uv = mid + (1.0/64) * normalize(outward + vec2(1e-8))`

**eps = 1.0/64（整 cell 宽）**，不是 0.5/64（半 cell）。原计划 0.5/64 在 mid 不在精确 cell 中心时仍可能落在原 cell 内（lodtex_selftest (B) 踩过）。

OOB query（u<0 || v<0 || u+v>1）→ 返回 0 = "无邻居"。Phase 4.5 才补跨面表。

### 19.4 lodDelta 符号约定

`lodDelta = max(0, self_lod - neighbor_lod)`。**自己更精细（lod 大）时才 slide**。neighbor 更粗 → 自己边多余的顶点 slide 到邻居 chord 上；自己更粗或同级 → 不 slide（neighbor 那侧 slide 或无需操作）。

### 19.5 lodTrans 字段重用（texel slot）

patch texture 共 6 texel × 4 chan = 24 chan，Phase 3 用了大部分。Phase 4 用预留字段存 3 边 lodDelta：

| 边 | slot | 注释 |
|---|---|---|
| AB | texel4.z | 原本 0 |
| BC | texel4.w | 原本 0 |
| CA | texel2.w | 原本 0（C.xyz 占 xyz） |

cull（写）和 vertex（读）必须用同一映射，lodtex_selftest (C) 锁定。

### 19.6 边参数化（关键 R4）

| 边 | UV 条件 | 参数 t | start → end |
|---|---|---|---|
| AB | v≈0 | t = u | A → B |
| BC | u+v≈1 | t = v | B → C |
| CA | u≈0 | t = v | A → C（注意：名字 "CA" 但参数化按 A→C，t=v） |

边检测 tol = `0.5 / u_patch_res`（半顶点宽，排除角点）。

### 19.7 Slide：世界坐标 chord 插值（关键反直觉）

Unity `FixLODConnectSeam` 移植版用**世界坐标直线 chord**插值，不是球面 slerp + terrain_height 重算。

理由：邻居（coarser）边渲染为世界直线 polyline（三角形光栅化是直线的）。自己（finer）边多余的顶点必须落在该 polyline 的对应段上才能消 T-junction。球面 slerp 让顶点留在球面上，与世界直线 chord 仍有 gap。

实现：找顶点所在 chord 段两端 k_start = `floor(k/seg)*seg`，k_end = k_start + seg（seg = 2^lodDelta）：
```
dir_s = normalize(mix(start_dir, end_dir, k_start/patch_res))
dir_e = normalize(mix(start_dir, end_dir, k_end/patch_res))
w_s = dir_s * (radius + terrain_height(dir_s) * max_height)
w_e = dir_e * (radius + terrain_height(dir_e) * max_height)
displaced = mix(w_s, w_e, km/seg)  // km = k mod seg
```

**走过的弯路**：plan agent 推荐球面 slerp + reeval，理由"chord 会陷下去"。实测 slerp 不消除裂缝（顶点留球面，邻居 chord 仍在外）。chord 陷下去的量（弧-弦差）对 lodDelta=1 + level≥3 patch < 0.001 单位，肉眼不可见。改 chord 后裂缝消失。

### 19.8 每帧 lodtex reset 必要性

每帧 rasterize 前必须 reset lodtex（`lod_lodtex.glsl` mode=-1，1280 workgroup 并行清零 81920 cells）。否则上帧选中的叶若本帧被取消选择（移出视野等），它的 cell 不会被新叶覆盖，留下陈旧 lod → cull sample 到错的 neighbor lod → 错 lodDelta → 裂缝/Z-fighting。

### 19.9 跨面边行为（Phase 4.5）

跨面边（ico 30 边，被 2 个 face 共享）的 cull query 落到 face 外（u+v>1 或负）→ `_sample_lodtex_safe` 返回 0 → lodDelta = self - 0 = self > 0 → 所有跨面边都误判为"邻居更粗" → slide。

但实际跨面边两侧叶可能同级（lodDelta=0），slide 多余 → visual artifact。

**Phase 4 当前缓解**：跨面边的 slide 是"对齐到自身 chord 0 端点"（km = self_lod，seg=2^self_lod 大于 self_patch_res 时永远 km>0.5 → slide 到 corner）。视觉上跨面边出现规律性"拉扯"。

**Phase 4.5 修法**：用 `gpu_ico.build_adjacency()` 的 30 边表，cull 对跨面边 sample 邻居 face 的 lodtex（需在 GPU 端存 30 边邻接 + 翻转标记）。

### 19.10 Phase 4 dispatch 序列（每帧）

```
reset trav_counter
per level 0..maxLevel: traverse
trav metadata (count → META_ROW)
reset lodtex (并行清零)
rasterize lodtex (per trav slot 1 thread)
reset cull_counter
cull dispatch (sample lodtex + MinMax + frustum → cull_tex)
cull metadata (count → META_ROW)
```

新增 2 个 dispatch（reset + rasterize lodtex），各 1280 / 64 workgroup。性能影响 < 5%。
