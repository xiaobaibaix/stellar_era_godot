# GPUDrivenTerrainLearn —— GPU 驱动地形 LOD 实现深度分析

> 分析对象：`F:\workspace\godot\github\GPUDrivenTerrainLearn`
> 参考来源：育碧 GDC 演讲《Terrain Rendering in Far Cry 5》
> 引擎：**Unity 2021 + URP（注意：这是 Unity 项目，不是 Godot 项目）**
> 核心特征：**LOD 选择、裁剪、Patch 生成全部在 GPU 完成，无任何 CPU 回读；整个地形用一次 `DrawMeshInstancedIndirect` 绘制。**

---

## 0. 一句话总览

用一张 16×16 网格的小 Plane Mesh，配合 **运行时在 GPU 上构建的四叉树 LOD**，把一个 10240m × 10240m 的大世界地形，从理论上的 1,638,400 个网格块，压缩到几百～几千个 Patch，用一个 DrawCall 渲染出来。整个流程包括：**LOD 四叉树分割 → 视锥裁剪 → Hi-Z 遮挡裁剪 → LOD 接缝缝合**。

---

## 1. 核心概念与尺寸约定

理解这套实现的第一步是吃透它的一套"尺寸词汇表"。所有 Shader 与 C# 的常量都围绕它们展开（见 `CommonInput.hlsl` 与 `TerrainAsset.cs`）。

| 概念 | 含义 | 常量 / 取值 |
|------|------|------------|
| **World** | 整个世界大小 | `worldSize = (10240, 2048, 10240)`，xz 是范围，y 是最大高度 |
| **Patch Mesh** | 唯一的那张基础网格 | 16×16 格，边长 8m，每格 0.5m（`PATCH_MESH_GRID_COUNT=16`, `PATCH_MESH_SIZE=8`, `PATCH_MESH_GRID_SIZE=0.5`）|
| **Node** | 四叉树的一个节点 | 不同 LOD 下边长不同 |
| **QuadTree** | LOD 四叉树 | 共 6 层，`MAX_TERRAIN_LOD = 5`，从上到下 LOD5 → LOD0 |
| **Sector** | LOD0 级 Node 的大小 | 64m × 64m，`SECTOR_COUNT_WORLD = 160`（即世界被切成 160×160 个 Sector）|
| **Patch** | 最小渲染单位 | 1 个 Node 拆成 8×8 = 64 个 Patch（`PATCH_COUNT_PER_NODE = 8`）|

### 1.1 LOD 与尺寸对应表

四叉树顶（LOD5）有 5×5 个节点，每往下一层节点数 ×2、边长 ×½：

| LOD | Node 边长 | Node 数量 | 对应 MinMaxHeight 的 mip | mip 尺寸 |
|-----|----------|-----------|------------------------|----------|
| 5 | 2048m | 5 × 5 | mip **8** | 5 × 5 |
| 4 | 1024m | 10 × 10 | mip 7 | 10 × 10 |
| 3 | 512m | 20 × 20 | mip 6 | 20 × 20 |
| 2 | 256m | 40 × 40 | mip 5 | 40 × 40 |
| 1 | 128m | 80 × 80 | mip 4 | 80 × 80 |
| 0 | 64m | 160 × 160 | mip **3** | 160 × 160 |

> **节点总数** = 5²+10²+20²+40²+80²+160² = **34125**，故 `MAX_NODE_ID = 34124`。
>
> **为什么不铺满？** 如果整世界都用 LOD0 分辨率（0.5m/格）：10240/8 = 1280 个 Patch/边 → 1280² = **1,638,400** 块，机器直接爆炸。LOD 让远处用低精度（放大 Patch）。

### 1.2 LOD 缩放逻辑

LOD 越低（LOD0）网格越密，LOD 越高（LOD5）网格越稀。同一个 16×16 的 Patch Mesh：

- LOD0：`scale = 2^0 = 1`，Patch 覆盖 8m，每格 0.5m
- LOD5：`scale = 2^5 = 32`，Patch 覆盖 8×32 = 256m，每格 16m

在顶点着色器里就是一句 `inVertex.xz *= pow(2, lod)`（见 §10）。

---

## 2. 总体架构与文件职责

### 2.1 文件地图

```
Assets/GPUDrivenTerrain/
├── Scripts/
│   ├── Scripts/                       # 运行时
│   │   ├── GPUTerrain.cs              # MonoBehaviour 入口：每帧 Dispatch + DrawMeshInstancedIndirect
│   │   ├── TerrainBuilder.cs          # 核心：组装 CommandBuffer，驱动整条 GPU 管线
│   │   ├── TerrainAsset.cs            # ScriptableObject：世界参数、贴图、Compute、Mesh 资源
│   │   ├── MeshUtility.cs             # 程序化生成 Patch Plane Mesh / Cube
│   │   └── TextureUtility.cs          # RenderTexture 工具（mip 贴图合并 / LODMap）
│   └── Editor/                        # 离线预处理（编辑器菜单）
│       ├── MinMaxHeightMapEditorGenerator.cs  # 从 HeightMap 生成 9 级 MinMaxHeight mip
│       ├── QuadTreeMapEditorBuilder.cs        # 预烘焙 nodeId 查找贴图（注：运行时未实际使用）
│       └── TerrainEditorUtil.cs               # 法线图生成 + GPU 异步回读工具
├── Shader/
│   ├── CommonInput.hlsl               # 共享常量与结构体（RenderPatch / Bounds / NodeDescriptor）
│   ├── TerrainBuildCompute.compute    # ★ 主 compute：四叉树遍历 / LODMap / Patch 生成与裁剪
│   ├── MinMaxHeights.compute          # 离线：生成 MinMaxHeight mip
│   ├── QuadTreeMipMapGen.compute      # 离线：生成 QuadTreeMap（nodeId 查找表）
│   ├── HeightToNormal.compute         # 离线：高度图 → 法线图
│   ├── Terrain.shader                 # 地形渲染（高度位移 + 法线光照 + 接缝缝合）
│   └── BoundsDebug.shader             # Patch 包围盒可视化
└── Assets/HizMapFeature/              # Hi-Z 遮挡裁剪（URP RenderFeature）
    ├── Runtime/Scripts/HizMapRenderFeature.cs  # ScriptableRendererFeature / Pass
    ├── Runtime/Scripts/HizMap.cs               # Hi-Z 贴图生成逻辑
    └── Runtime/Shader/HizMap.compute           # 深度图 Blit + 分层 mip（取最远）
```

### 2.2 运行时职责分工

| 组件 | 职责 |
|------|------|
| `GPUTerrain` | 挂在场景上的入口；持有 `TerrainAsset`；每帧调 `_traverse.Dispatch()`，再 `DrawMeshInstancedIndirect`；暴露调试开关（裁剪/接缝/Debug）|
| `TerrainBuilder` | **管线核心**。创建所有 ComputeBuffer、RenderTexture；在 `Dispatch()` 里把整条 GPU 流程录进一个 `CommandBuffer` 并 `Graphics.ExecuteCommandBuffer` |
| `TerrainAsset` | 数据容器。懒加载 `quadTreeMap`/`minMaxHeightMap`（把多张离线 mip 合成一张带 mip 的 RenderTexture）、`patchMesh`（16×16 plane）、`unitCubeMesh`（包围盒 debug）|

---

## 3. 离线预处理（编辑器一次性烘焙）

运行时零 CPU 回读的前提，是把"地形高度统计信息"提前烘焙好。

### 3.1 HeightMap

- `HeightMap.png`：1281×1281，R16。整世界共用一张，每像素对应 **8m × 8m**（精度很低，Demo 够用）。
- 顶点着色器里采样：
  ```hlsl
  float2 heightUV = (inVertex.xz + (_WorldSize.xz * 0.5) + 0.5) / (_WorldSize.xz + 1);
  float height = tex2Dlod(_HeightMap, float4(heightUV,0,0)).r;
  inVertex.y = height * _WorldSize.y;
  ```
  `+0.5` / `+1` 是为了把"像素中心采样"对齐到 1281 像素 / 1280 格的网格。

### 3.2 MinMaxHeightMaps（★ LOD 正确性的关键）

**问题**：平面上的 LOD 只看 xz 距离就行；一旦地形有高度起伏，节点中心高度必须先估算出来，否则节点评价会算错（README 里的"LOD 到 4 就不往下"bug 就是这个）。

**做法**：烘焙一张 **存 min/max 高度的分层 mip 贴图**（`RG32`，R=min，G=max），用它构造每个节点的 AABB。

`MinMaxHeights.compute` 两个 kernel：

```hlsl
// Kernel 0: PatchMinMaxHeight —— 从 HeightMap 生成 mip0
// 采样相邻 4 个顶点高度，求 min/max → 一个像素代表 8m×8m 的高度范围
[numthreads(8,8,1)]
void PatchMinMaxHeight(uint3 id){
    float h1 = HeightTex[id.xy].r;
    float h2 = HeightTex[id.xy + uint2(1,0)].r;
    float h3 = HeightTex[id.xy + uint2(0,1)].r;
    float h4 = HeightTex[id.xy + uint2(1,1)].r;
    float hmin = min(min(h1,h2),min(h3,h4));
    float hmax = max(max(h1,h2),max(h3,h4));
    PatchMinMaxHeightTex[id.xy].rgba = float4(hmin,hmax,0,1);   // mip0 = 1280×1280
}

// Kernel 1: PatchMinMaxHeightMapMip —— 2×2 归约生成下一级 mip
// R 取 min，G 取 max（注意：min 与 max 是不对称的，不是普通 mip）
[numthreads(5,5,1)]
void PatchMinMaxHeightMapMip(uint3 id){
    uint2 inLoc = id.xy * 2;
    float2 h1 = InTex[inLoc].rg;
    float2 h2 = InTex[inLoc + uint2(1,0)].rg;
    float2 h3 = InTex[inLoc + uint2(0,1)].rg;
    float2 h4 = InTex[inLoc + uint2(1,1)].rg;
    float hmin = min(min(h1.r,h2.r),min(h3.r,h4.r));
    float hmax = max(max(h1.g,h2.g),max(h3.g,h4.g));
    ReduceTex[id.xy] = float4(hmin,hmax,0,1);
}
```

C# 侧 `MinMaxHeightMapEditorGenerator` 串起来：mip0 (1280) → mip1 (640) → … → mip8 (5)，**共 9 级**。

> **关键对应关系**：`GetNodePositionWS()` 用 `MinMaxHeightTexture.mips[lod + 3]` 取节点高度。因为 mip3 = 160×160 = LOD0（每像素 64m），mip8 = 5×5 = LOD5。所以 **LOD N ↔ mip(N+3)**（见 §1.1 表）。

### 3.3 QuadTreeMap（预烘焙 nodeId 查找表 —— 实际未启用）

`QuadTreeMipMapGen.compute` 把 `nodeId / 65535` 烘焙进 R16 贴图，意图是让 GPU 通过采样得到 `(nodeLoc, lod) → nodeId` 映射。但 **运行时的 `TerrainBuildCompute.compute` 根本没声明 `QuadTreeTexture` 变量**，`TerrainBuilder.BindComputeShader` 虽然绑定了它却无人读取——实际 nodeId 是用 `NodeIDOffsetOfLOD` 数组算出来的（见 §6.3）。这是项目里一处遗留代码，分析时需留意。

### 3.4 NormalMap

`HeightToNormal.compute`：对每个像素取上下左右 4 条边的差分，叉积求法线，4 个法线平均后归一化，存成 `RG32`（R=x，G=z，y 由 `sqrt(1-x²-z²)` 还原）。渲染时再用 `_WorldToNormalMapMatrix`（= `Scale(worldSize).inverse`）把"法线图空间"转回世界空间。

---

## 4. 运行时 GPU 管线总览（每帧 `TerrainBuilder.Dispatch()`）

整条管线录进一个 `CommandBuffer`，一次性 `ExecuteCommandBuffer`。**全程无 CPU 回读**——节点数量、Patch 数量都通过 `CopyCounterValue` 在 GPU 内传递给 Indirect 参数。

```
每帧 Dispatch() 流程：
┌─────────────────────────────────────────────────────────────┐
│ 0. ClearBufferCounter()：所有 Append buffer 计数清零          │
│ 1. UpdateCameraFrustumPlanes()：Plane[6] → Vector4[6] 上传    │
│ 2. 上传 _CameraPositionWS / _WorldSize / _NodeEvaluationC     │
│                                                              │
│ 3.【四叉树分割】 LOD5 → LOD0，共 6 次 Dispatch                │
│    每次：CopyCounter(consume→indirectArgs)                    │
│         DispatchCompute(TraverseQuadTree, indirectArgs)       │
│         CopyCounter(append→indirectArgs)  // 给下一层用       │
│         交换 consume/append 双缓冲                            │
│                                                              │
│ 4.【生成 LODMap】 DispatchCompute(BuildLodMap, 20,20,1)        │
│                                                              │
│ 5.【生成 Patch + 裁剪】                                        │
│    CopyCounter(FinalNodeList → indirectArgs)                  │
│    DispatchCompute(BuildPatches, indirectArgs)  // 每Node一组 │
│    CopyCounter(CulledPatchList → patchIndirectArgs[4])        │
│                                                              │
│ 6. Graphics.ExecuteCommandBuffer(_commandBuffer)              │
└─────────────────────────────────────────────────────────────┘
        ↓ （GPUTerrain.Update）
Graphics.DrawMeshInstancedIndirect(patchMesh, patchIndirectArgs)  // 单次 DrawCall
```

### 4.1 关键设计：AppendBuffer 双缓冲 + Indirect 链式派发

- `nodeListA` / `nodeListB` 是两个 `AppendStructuredBuffer`，每层 LOD **交换 consume/append 角色**（ping-pong），避免分配新缓冲。
- 每层的线程组数 = 上一层 append 出来的节点数，通过 `CopyCounterValue(appendBuf, indirectArgs, 0)` 在 GPU 内传递，`DispatchCompute(..., indirectArgs, 0)` 用它做 indirect dispatch。**节点数完全在 GPU 端流动，CPU 不知道也不需要知道。**

---

## 5. 数据结构（`CommonInput.hlsl`）

```hlsl
struct NodeDescriptor { uint branch; };     // branch=1 表示该节点被分割
struct RenderPatch {                          // 每个 Patch 的渲染数据（PatchStripSize = 9*4 = 36 字节）
    float2 position;     // 世界坐标 xz
    float2 minMaxHeight; // 该 Patch 的高度 min/max（用于构造包围盒）
    uint   lod;          // 决定 scale = 2^lod
    uint4  lodTrans;     // 4 个方向的 LOD 梯度（+x,-x,+z,-z），用于接缝缝合
};
struct Bounds { float3 minPosition; float3 maxPosition; };
struct BoundsDebug { Bounds bounds; float4 color; };
```

### 5.1 运行时 Buffer 一览

| Buffer | 类型 | 元素 | stride | 用途 |
|--------|------|------|--------|------|
| `_maxLODNodeList` | Append | 25 | 8 (uint2) | LOD5 的 25 个初始节点索引（启动时填好）|
| `_nodeListA` / `_nodeListB` | Append | 50 | 8 | 四叉树遍历的 ping-pong 中间缓冲 |
| `_finalNodeListBuffer` | Append | 200 | 12 (uint3) | 选中的叶子节点（xy=索引, z=lod）|
| `_nodeDescriptors` | RW | 34125 | 4 | 每个节点的 branch 标志 |
| `_culledPatchBuffer` | Append | 200×64 | 36 | 裁剪后提交渲染的 Patch 列表 |
| `_patchIndirectArgs` | Indirect | 5 | 4 | DrawMeshInstancedIndirect 参数 |
| `_patchBoundsBuffer` | Append | 200×64 | 40 | 仅 BOUNDS_DEBUG 用 |
| `_indirectArgsBuffer` | Indirect | 3 | 4 | 各次 Compute Dispatch 的组数中转 |

> 缓冲大小（200、50）是按"最坏分割情况"预估的，比实际需要略大。

---

## 6. LOD 四叉树分割详解（`TraverseQuadTree` kernel）

### 6.1 Kernel 本体

```hlsl
[numthreads(1,1,1)]   // ★ 每个线程处理一个节点
void TraverseQuadTree(uint3 id : SV_DispatchThreadID)
{
    uint2 nodeLoc = ConsumeNodeList.Consume();
    uint  nodeId  = GetNodeId(nodeLoc, PassLOD);
    NodeDescriptor desc = NodeDescriptors[nodeId];

    if (PassLOD > 0 && EvaluateNode(nodeLoc, PassLOD)) {
        // 分割：把 4 个子节点 append 给下一层
        AppendNodeList.Append(nodeLoc * 2);
        AppendNodeList.Append(nodeLoc * 2 + uint2(1,0));
        AppendNodeList.Append(nodeLoc * 2 + uint2(0,1));
        AppendNodeList.Append(nodeLoc * 2 + uint2(1,1));
        desc.branch = 1;
    } else {
        // 不分割：收入最终节点列表
        AppendFinalNodeList.Append(uint3(nodeLoc, PassLOD));
        desc.branch = 0;
    }
    NodeDescriptors[nodeId] = desc;
}
```

**要点**：
- `[numthreads(1,1,1)]` + indirect dispatch —— 线程组数 = 节点数，1 对 1。
- 用 `Consume`/`Append` 语义的 StructuredBuffer，GPU 原子地进出节点。
- 分割出的子节点索引 = `nodeLoc*2 + {0, (1,0), (0,1), (1,1)}`（标准四叉树子块寻址）。
- **branch 标志**写入 `NodeDescriptors`，后续 `BuildLodMap` 要用它反查每个 Sector 的 LOD。

### 6.2 节点评价函数（`EvaluateNode`）

```hlsl
bool EvaluateNode(uint2 nodeLoc, uint lod){
    float3 positionWS = GetNodePositionWS(nodeLoc, lod);   // 节点中心，y 取自 MinMax mip 的 (min+max)/2
    float dis = distance(_CameraPositionWS, positionWS);
    float nodeSize = GetNodeSize(lod);
    float f = dis / (nodeSize * _NodeEvaluationC.x);        // f = d / (n*c)
    return f < 1;                                            // f<1 就分割
}
```

**公式 `f = d / (n·c)`**：
- `d` = 摄像机到节点中心距离（含高度，所以需要 MinMax mip 估出节点中心 y）
- `n` = 节点边长
- `c` = 用户系数（`distanceEvaluation`，默认 1.2）

`c` 越大，`f` 越容易 < 1，**节点越容易被分割**（分割越多 = 细节越多）。`PassLOD > 0` 才评价，LOD0 不再分割。

> 实际项目里 `EvaluateNode` 还应考虑"高度变化剧烈程度"等因素，这里 Demo 只用距离。

### 6.3 nodeId 映射（`uint3 → uint`）

GPU 没有 Map 结构，得把 `(x, y, lod)` 映射成线性下标去索引 `NodeDescriptors`。C# `InitWorldParams()` 预算好每层的起始偏移：

```csharp
// 累加每层 nodeCount² 得到偏移
for (int lod = MAX_LOD; lod >= 0; lod--) {
    nodeIDOffsetLOD[lod*4] = nodeIdOffset;
    nodeIdOffset += nodeCount²;
}
// 结果：offset[5]=0, offset[4]=25, offset[3]=125, offset[2]=525, offset[1]=2125, offset[0]=8525
```

```hlsl
uint GetNodeId(uint3 nodeLoc){
    return NodeIDOffsetOfLOD[nodeLoc.z] + nodeLoc.y * GetNodeCount(nodeLoc.z) + nodeLoc.x;
}
```

---

## 7. LODMap 生成（`BuildLodMap`）

四叉树分割完成后，得到的是"哪些节点被选中"。但接缝缝合需要一张 **按 Sector（64m 格）查 LOD 的贴图**。于是单独一个 Pass：

```hlsl
[numthreads(8,8,1)]   // 20×20 组 = 160×160 线程，每线程一个 Sector
void BuildLodMap(uint3 id){
    uint2 sectorLoc = id.xy;
    [unroll]
    for (uint lod = MAX_TERRAIN_LOD; lod >= 0; lod--) {
        uint sectorCount = GetSectorCountPerNode(lod);        // 该 LOD 下一个 Node 含几个 Sector
        uint2 nodeLoc = sectorLoc / sectorCount;              // 这个 Sector 属于哪个 Node
        uint nodeId = GetNodeId(nodeLoc, lod);
        if (NodeDescriptors[nodeId].branch == 0) {            // 找到第一个"未分割"的祖先
            _LodMap[sectorLoc] = lod * 1.0 / MAX_TERRAIN_LOD; // 归一化到 [0,1]，R8 贴图
            return;
        }
    }
    _LodMap[sectorLoc] = 0;
}
```

**算法**：对每个 Sector，从 LOD5 往下找，第一个 `branch==0`（未被继续分割）的祖先节点，它的 LOD 就是该 Sector 的 LOD。`_LodMap` 是 160×160 的 R8 RenderTexture（point 采样）。

**时序**：位于四叉树分割之后、Patch 生成之前——因为 Patch 生成阶段要采样 `_LodMap` 算接缝梯度。

---

## 8. Patch 生成与裁剪（`BuildPatches` kernel）

### 8.1 派发方式

```csharp
_commandBuffer.CopyCounterValue(_finalNodeListBuffer, _indirectArgsBuffer, 0);  // 组数 = 选中节点数
_commandBuffer.DispatchCompute(_computeShader, _kernelOfBuildPatches, _indirectArgsBuffer, 0);
```

```hlsl
[numthreads(8,8,1)]   // 每个 Node 一组，64 线程 = 64 个 Patch
void BuildPatches(uint3 id, uint3 groupId, uint3 groupThreadId){
    uint3 nodeLoc = FinalNodeList[groupId.x];        // 这个 group 处理哪个 Node
    uint2 patchOffset = groupThreadId.xy;            // Patch 在 Node 内的局部 8×8 索引

    RenderPatch patch = CreatePatch(nodeLoc, patchOffset);   // 算世界坐标 + minMaxHeight
    Bounds bounds = GetPatchBounds(patch);                   // 构造 AABB
    if (Cull(bounds)) return;                                // 视锥 + Hi-Z 裁剪
    SetLodTrans(patch, nodeLoc, patchOffset);                // 算 4 方向 LOD 梯度
    CulledPatchList.Append(patch);                           // 通过裁剪 → 入渲染列表
    #if BOUNDS_DEBUG
    PatchBoundsList.Append(...);                             // 可视化包围盒
    #endif
}
```

### 8.2 `CreatePatch` —— 算 Patch 世界坐标

```hlsl
RenderPatch CreatePatch(uint3 nodeLoc, uint2 patchOffset){
    uint lod = nodeLoc.z;
    float nodeMeterSize = GetNodeSize(lod);                  // 节点边长
    float patchMeterSize = nodeMeterSize / 8;                // 每个 Patch 边长 = 节点/8
    float2 nodePositionWS = GetNodePositionWS2(nodeLoc.xy, lod);  // 节点中心 xz
    uint2 patchLoc = nodeLoc.xy * 8 + patchOffset;
    float2 minMaxHeight = MinMaxHeightTexture.mips[lod][patchLoc].rg * _WorldSize.y
                          + float2(-_BoundsHeightRedundance, +_BoundsHeightRedundance);  // 高度冗余
    RenderPatch patch;
    patch.position = nodePositionWS + (patchOffset - 3.5) * patchMeterSize;  // Patch 中心 xz
    patch.minMaxHeight = minMaxHeight;
    patch.lod = lod;
    patch.lodTrans = 0;
    return patch;
}
```

> 注意 `mips[lod][patchLoc]`：这里 Patch 用的是 `mip[lod]`（不是 `lod+3`）。因为 `patchLoc = nodeLoc.xy * 8 + offset`，node 在 mip(lod) 上是 8×8 像素一块，正好对应 8×8 个 Patch。例如 LOD0 的 node（160×160 mip3 中的一个像素）→ 8×8 Patch 对应 mip0 的 8×8 像素……（此处作者实际用 `mips[lod]`，分析见 §13 注意事项）。

### 8.3 视锥裁剪（`FrustumCull`）

经典 6 平面 × 8 顶点 AABB 测试：

```hlsl
bool IsOutSidePlane(float4 plane, float3 p){ return dot(plane.xyz, p) + plane.w < 0; }
// 一个 AABB 在平面外侧 ⟺ 8 个顶点全在外侧
bool IsAABBOutSidePlane(float4 plane, float3 mn, float3 mx){ /* 测 8 角点 */ }
bool FrustumCull(float4 planes[6], Bounds b){
    return IsBoundsOutSidePlane(planes[0],b) || ... || IsBoundsOutSidePlane(planes[5],b);
}
```

C# 端 `GeometryUtility.CalculateFrustumPlanes(camera)` 得到 `Plane[6]`，转成 `Vector4(normal, distance)`（即平面方程 Ax+By+Cz+D=0）上传。

### 8.4 包围盒高度冗余

`_BoundsHeightRedundance`（默认 5m）把 Patch 包围盒的 top/bottom 各向外扩一点，弥补 `MinMaxHeightTexture` 的精度不足（否则 LOD0 时包围盒包不住 Patch，Hi-Z 会误剔除）。README 的 BoundsDebug 截图里那些"露出来的灰点"就是冗余不够时的现象。

---

## 9. Hi-Z 遮挡裁剪（`HizMapFeature`）

这是整套实现里最巧妙、工程坑最多的一块。原理：用 **上一帧的深度图** 生成"取最远值"的分层 mip，再对 Patch 包围盒做屏幕空间深度测试。

### 9.1 Hi-Z 贴图生成（`HizMap.cs` + `HizMap.compute`）

`HizMapRenderFeature`（URP ScriptableRendererFeature）在 `BeforeRenderingTransparents` 插入 `HizMapPass`：

1. **尺寸**：`GetHiZMapSize = NextPowerOfTwo(max(pixelW, pixelH))`，取屏幕长边的下一个 2 的幂，方便做 mip。
2. **Blit**：把 `_CameraDepthTexture` 拷到 Hi-Z 贴图的 mip0（屏幕通常非 2 的幂，自定义 Blit kernel 做缩放拷贝）。
3. **分层 mip**：逐级 2×2 归约，**取 4 个里最远的那个**（reverse-Z 下 = `min(4)`）：

```hlsl
[numthreads(8,8,1)]
void CSMain(uint3 id){
    if (id.x < _DstTexSize.x && id.y < _DstTexSize.y){
        uint2 coord = 2 * id.xy;
        float d1 = InTex[coord].r;
        float d2 = InTex[coord + uint2(1,0)].r;
        float d3 = InTex[coord + uint2(0,1)].r;
        float d4 = InTex[coord + uint2(1,1)].r;
        #if _REVERSE_Z
        float d = min(min(d1,d2),min(d3,d4));   // reverse-Z: 小=远 → 存最远
        #else
        float d = max(max(d1,d2),max(d3,d4));
        #endif
        MipTex[id.xy] = d;
    }
}
```

> **取最远**的意义：每个 mip 像素代表"该区域内最远的遮挡物深度"，这样测试时只要物体比它还远，就一定被挡——保守且安全。

4. **写入全局**：`_HizMap`、`_HizCameraMatrixVP`、`_HizMapSize`、`_HizCameraPositionWS`，供地形 compute 读取。

#### Windows 平台坑：PingPong

```csharp
#if UNITY_EDITOR_WIN || UNITY_STANDALONE_WIN
#define PING_PONG_COPY   // Win 上不能把同一张贴图同时作为输入和输出
#endif
```

Mac/Metal 支持同一张贴图的不同 mip 同时读写（`InTex.mips[_Mip-1]` 读、`MipTex` 写同一张），但 **Windows/DX 不支持**。所以 Win 下用两张 RT ping-pong 交替生成 mip。这是项目踩过的真坑（README §6.2）。

### 9.2 包围盒遮挡测试（`HizOcclusionCull`）

```hlsl
bool HizOcclusionCull(Bounds bounds){
    // 1. 深度偏置：把包围盒沿视线方向往内收一点，减少快速转动时的误剔除（闪现）
    bounds.minPosition -= normalize(bounds.minPosition - _HizCameraPositionWS) * _HizDepthBias;
    bounds.maxPosition -= normalize(bounds.maxPosition - _HizCameraPositionWS) * _HizDepthBias;

    // 2. 包围盒 8 角点 → UVD（屏幕 uv + 深度）空间，重算 UVD 下的 AABB
    Bounds boundsUVD = GetBoundsUVD(bounds);

    // 3. 选合适的 mip：让屏幕矩形在该 mip 下 ~1 像素
    uint mip = GetHizMip(boundsUVD);

    // 4. 采样矩形 4 角的深度，与包围盒最近深度比较
    float3 minP = boundsUVD.minPosition, maxP = boundsUVD.maxPosition;
    float d1 = SampleHiz(minP.xy, mip, mipTexSize);
    float d2 = SampleHiz(maxP.xy, mip, mipTexSize);
    float d3 = SampleHiz(float2(minP.x,maxP.y), mip, mipTexSize);
    float d4 = SampleHiz(float2(maxP.x,minP.y), mip, mipSize);

    #if _REVERSE_Z
    float depth = maxP.z;                       // 包围盒最近点（reverse-Z: 大=近）
    return d1 > depth && d2 > depth && d3 > depth && d4 > depth;  // 4 角都比它近 → 被挡
    #else
    float depth = minP.z;
    return d1 < depth && d2 < depth && d3 < depth && d4 < depth;
    #endif
}
```

**mip 选择 `GetHizMip`**：
```hlsl
uint GetHizMip(Bounds boundsUVD){
    float2 size = (maxP.xy - minP.xy) * _HizMapSize.x;   // 屏幕矩形像素尺寸
    uint2 mip2 = ceil(log2(size));
    return clamp(max(mip2.x, mip2.y), 1, _HizMapSize.z - 1);
}
```

逻辑：屏幕矩形越大，选越粗的 mip，使得矩形在该 mip 下"恰好跨相邻像素"——既不过粗（漏判）也不过细（采样开销 + 颗粒感）。

### 9.3 一帧延迟（重要局限）

地形 `Dispatch()` 在 `Update()`（CPU 时间，渲染前）执行，而 `_HizMap` 是 **本帧渲染管线** 在 `BeforeRenderingTransparents` 才生成的——所以本帧用到的其实是 **上一帧的深度**。快速转镜头时会出现物体闪现（上一帧没被挡、本帧被挡）。README §5 明确指出了这点。

---

## 10. LOD 接缝处理（消除 T-junction 缝隙）

不同 LOD 地块交界处，网格密度不同，顶点对不齐，产生缝隙。**而缝隙会破坏 Hi-Z 裁剪**（包围盒漏出一条缝，导致该剔除的没剔除），所以必须缝合。

### 10.1 思路：把多余顶点"焊"到邻居

高精度侧多出来的边缘顶点，沿边缘滑到能与低精度侧对齐的位置（README 的 SeamFix 图）。LOD 相差 ≥1 级都用同策略。

### 10.2 计算 4 方向 LOD 梯度（`SetLodTrans`）

Patch 在 Node 内的 8×8 局部索引决定了它是否在 Node 边缘。只有边缘 Patch 才需要查邻居：

```hlsl
void SetLodTrans(inout RenderPatch patch, uint3 nodeLoc, uint2 patchOffset){
    uint lod = nodeLoc.z;
    uint4 sectorBounds = GetSectorBounds(nodeLoc);  // 该 Node 覆盖的 Sector 范围
    int4 lodTrans = 0;
    if (patchOffset.x == 0) lodTrans.x = GetLod(sectorBounds.xy + int2(-1,0)) - lod;  // 左
    if (patchOffset.y == 0) lodTrans.y = GetLod(sectorBounds.xy + int2(0,-1)) - lod;  // 下
    if (patchOffset.x == 7) lodTrans.z = GetLod(sectorBounds.zw + int2(1,0))  - lod;  // 右
    if (patchOffset.y == 7) lodTrans.w = GetLod(sectorBounds.zw + int2(0,1))  - lod;  // 上
    patch.lodTrans = max(0, lodTrans);   // ★ 只处理 LOD 上升（邻居更粗）的情况
}
```

`GetLod` 采样 `_LodMap` 得邻居 Sector 的 LOD，减去自身 LOD。**只保留正值**（邻居比自自己粗才需要焊；自己更粗时由邻居侧焊）。

### 10.3 顶点缝合（`Terrain.shader :: FixLODConnectSeam`）

在顶点着色器里，对每个边缘顶点按 4 方向检查：

```hlsl
void FixLODConnectSeam(inout float4 vertex, inout float2 uv, RenderPatch patch){
    uint4 lodTrans = patch.lodTrans;
    uint2 vertexIndex = floor((vertex.xz + 4.0 + 0.01) / 0.5);  // 顶点在 Patch 16×16 网格里的索引
    float uvStrip = 1.0 / 16;

    // 以 +x 方向（lodTrans.x，左边缘）为例：
    uint lodDelta = lodTrans.x;
    if (lodDelta > 0 && vertexIndex.x == 0){            // 左边缘顶点 且 左邻居更粗
        uint gridStripCount = pow(2, lodDelta);          // 邻居每 gridStripCount 个格才有一个顶点
        uint modIndex = vertexIndex.y % gridStripCount;
        if (modIndex != 0){                              // 这个顶点是"多余"的
            vertex.z -= 0.5 * modIndex;                  // 沿边缘滑到对齐位置
            uv.y    -= uvStrip * modIndex;
            return;
        }
    }
    // ... 其余 3 个方向对称处理（注意 + 方向是 +，- 方向是 (gridStripCount - modIndex)）
}
```

**本质**：邻居 LOD 高 `lodDelta` 级 → 它的边缘顶点间隔是自己的 `2^lodDelta` 倍。自己边缘上 `vertexIndex % 2^lodDelta != 0` 的顶点都是"多余的"，把它们沿边缘移到最近的、能与邻居对齐的位置，T-junction 就消失了。UV 同步偏移保证纹理不撕裂。

---

## 11. 渲染（`Terrain.shader`）

```hlsl
v2f vert(appdata v){
    float4 inVertex = v.vertex;
    float2 uv = v.uv;
    RenderPatch patch = PatchList[v.instanceID];   // ★ 用 InstanceID 索引 Patch 列表

    #if ENABLE_LOD_SEAMLESS
    FixLODConnectSeam(inVertex, uv, patch);        // 接缝缝合
    #endif

    float scale = pow(2, patch.lod);
    inVertex.xz *= scale;                          // LOD 缩放
    inVertex.xz += patch.position;                 // 平移到世界位置

    // 高度位移
    float2 heightUV = (inVertex.xz + _WorldSize.xz*0.5 + 0.5) / (_WorldSize.xz + 1);
    inVertex.y = tex2Dlod(_HeightMap, float4(heightUV,0,0)).r * _WorldSize.y;

    // 法线 + Lambert
    float3 normal = SampleNormal(heightUV);
    o.color = max(0.05, dot(GetMainLight().direction, normal));

    o.vertex = TransformObjectToHClip(inVertex.xyz);
    o.uv = uv * scale * 8;   // 纹理按 8m 一格平铺，与 LOD 无关
    return o;
}
```

**关键点**：
- `StructuredBuffer<RenderPatch> PatchList` + `SV_InstanceID` → 每个 instance 取自己的 Patch 数据。
- `scale = 2^lod` 同时作用于位置缩放和 UV（`uv * scale * 8`），让 albedo 在世界空间按固定密度平铺。
- 4 个 Debug 开关（`ENABLE_MIP_DEBUG` / `PATCH_DEBUG` / `NODE_DEBUG` / `LOD_SEAMLESS`）用 `shader_feature` 切换。

---

## 12. 调试体系

| 开关（GPUTerrain） | 效果 |
|-------------------|------|
| `patchDebug` | Patch 间留缝（`inVertex.xz *= 0.9`）+ 接缝区颜色混合 |
| `nodeDebug` | Node 间留缝（`ApplyNodeDebug` 把顶点往 Node 中心收 5%）|
| `mipDebug` | 按 LOD + lodTrans 上色（6 色 debug 调色板）|
| `patchBoundsDebug` | 用 `BoundsDebug.shader` 把每个 Patch 的 AABB 画成彩色立方体 |
| `seamLess` | 总开关：是否执行 `FixLODConnectSeam` |
| `isFrustumCullEnabled` / `isHizOcclusionCullingEnabled` | 两种裁剪开关 |
| `hizDepthBias` / `boundsHeightRedundance` / `distanceEvaluation` | Hi-Z 偏置 / 包围盒冗余 / LOD 评价系数 |

`BoundsDebug.shader` 把单位 Cube 缩放到 AABB 尺寸并位移到中心，是验证"包围盒是否真的包住了 Patch"的利器。

---

## 13. 关键实现技巧与值得注意的点

1. **零 CPU 回读**：节点数、Patch 数全靠 `CopyCounterValue` 在 GPU 内串联到 indirect 参数。这是"GPU-Driven"的精髓——CPU 完全不知道场景细节。
2. **单 DrawCall 渲染整个地形**：`Graphics.DrawMeshInstancedIndirect` 配合 `StructuredBuffer<RenderPatch>`，一次提交所有 Patch。
3. **AppendBuffer ping-pong**：两个 buffer 交换角色完成逐层四叉树遍历，无需动态分配。
4. **MinMaxHeight mip 不对称归约**（R 取 min、G 取 max）——这是构造节点 AABB 的核心，也是 LOD 评价正确的前提。
5. **NodeId 用累加偏移做 `uint3→uint` 映射**，替代 GPU 不存在的 Map。
6. **branch 标志 + LODMap 解耦**：四叉树分割结果先落盘到 `NodeDescriptors`，再由独立的 `BuildLodMap` Pass 反查，职责清晰。
7. **Hi-Z 取最远 mip + mip 自适应选择**：保守且高效。
8. **深度偏置 `_HizDepthBias`**：缓解一帧延迟带来的闪现。
9. **`SampleLevel` 失效问题**：compute 里作者注释说 `SampleLevel` 的 mip 参数不生效，改用手动 `_HizMap.mips[mip][coord]` 采样（`SampleHiz` 函数）——这是 HLSL compute 采样器的真实坑。
10. **遗留代码**：`QuadTreeMap` 纹理被绑定但 compute 中未声明/未读取（见 §3.3）；`mips[lod]` 与 `mips[lod+3]` 的层级对应在 `CreatePatch` 与 `GetNodePositionWS` 之间需仔细核对（作者用 patchLoc=nodeLoc*8+offset 来索引 mip[lod]，依赖 mip[lod] 在该 LOD 下每像素恰好代表一个 Patch 的尺寸约定）。

---

## 14. 已知局限与改进方向

| 局限 | 说明 | 改进 |
|------|------|------|
| **Hi-Z 一帧延迟** | 用上一帧深度，快转镜头会闪现 | 双缓冲 / 外扩视锥保守补偿 / 本帧重建 |
| **无材质/纹理流送** | Demo 全用同一张低精度高度/法线图 | 按 LOD 分区加载高度图（Far Cry 5 的做法）|
| **GPU Struct 未压缩** | `RenderPatch` 36 字节，`lodTrans` 用 uint4 存小整数 | 位压缩 |
| **节点评价只看距离** | 忽略高度剧烈程度 | 加入 height variance 项 |
| **无 Back-face cull** | Far Cry 5 有三种裁剪，本 Demo 只做两种 | 可补 |
| **ComputeBufferType 坑** | `Append | Counter` 在 Win 崩溃，直接用 `Append`（README §6.1）| — |
| **同一贴图读写坑** | Win 不支持同贴图读写，Hi-Z 必须 ping-pong（README §6.2）| — |

---

## 15. 对自有项目（StellarEra 行星 LOD）的参考启示

本项目与我当前行星 LOD（每面独立 MeshInstance3D、飞行重建）思路差异较大，但有几个可直接借鉴的核心思想：

1. **MinMaxHeight mip 的不对称归约**：行星地形若有起伏，节点评价同样需要"高度包围"信息。可离线烘焙类似的 min/max 层级贴图（球面化），避免 LOD 选择在山地处出错。
2. **AppendBuffer + Indirect 链式派发**：若 StellarEra 未来要做更细粒度的 GPU-driven 剔除（视锥/遮挡），这套"计数器在 GPU 内流动"的模式是范本。Godot 4.x 的 RenderingDevice + compute list 可实现等价流程。
3. **Hi-Z 遮挡剔除**：对于有大起伏（高山背面）的行星表面，Hi-Z 能显著减少远处冗余 mesh。Godot 中可用 depth texture + compute shader 自建分层 mip。
4. **LOD 接缝的"边缘顶点焊接"**：行星各面/各 chunk 之间 LOD 不一时，`FixLODConnectSeam` 的 `vertexIndex % 2^lodDelta` 思路可直接复用——把高精度侧的多余边缘顶点滑到对齐位置，比加 skirt（裙边）省顶点且无视觉突起。
5. **调试体系**：`BoundsDebug`（画 AABB 验证剔除正确性）+ mip/node/patch 分色 Debug，是排查 LOD 问题的标配手段，值得在行星项目里复刻。

> ⚠️ 移植注意：本项目的"四叉树"是 **平面 xz** 的；行星是 **球面/立方体面**。四叉树分割、邻居查找、MinMax mip 的坐标映射都需要做球面适配，不能直接照搬。但其"GPU 内完成 LOD 选择 + 裁剪 + 接缝"的**架构与数据流**是完全通用的。

---

## 附录 A：每帧时序（含渲染管线）

```
[CPU Update]
  GPUTerrain.Update()
    └─ TerrainBuilder.Dispatch()                    ← 录 CommandBuffer
         ├─ ClearBufferCounter / 上传相机参数
         ├─ 6× TraverseQuadTree  (LOD5→LOD0)
         ├─ BuildLodMap
         ├─ BuildPatches (+ 视锥/Hi-Z 裁剪)
         └─ Graphics.ExecuteCommandBuffer            ← 真正提交 GPU
    └─ Graphics.DrawMeshInstancedIndirect(patchMesh) ← 单次地形 DrawCall

[GPU Render Pipeline (URP), 本帧]
  ... Opaque pass (含地形) ...
  BeforeRenderingTransparents:
    └─ HizMapPass                                    ← 生成本帧 _HizMap（供"下一帧"使用）
  ... Transparent ...
```

## 附录 B：核心文件行号速查

| 内容 | 位置 |
|------|------|
| 管线组装 | `TerrainBuilder.cs:261 Dispatch()` |
| 四叉树遍历 | `TerrainBuildCompute.compute:122 TraverseQuadTree` |
| 节点评价 | `TerrainBuildCompute.compute:103 EvaluateNode` |
| nodeId 映射 | `TerrainBuildCompute.compute:113 GetNodeId` |
| LODMap 生成 | `TerrainBuildCompute.compute:144 BuildLodMap` |
| Patch 生成+裁剪 | `TerrainBuildCompute.compute:382 BuildPatches` |
| Hi-Z 测试 | `TerrainBuildCompute.compute:274 HizOcclusionCull` |
| 接缝缝合 | `Terrain.shader:76 FixLODConnectSeam` |
| MinMax 烘焙 | `MinMaxHeights.compute` |
| Hi-Z 贴图生成 | `HizMap.cs:76 Update()` / `HizMap.compute` |
| 结构体定义 | `CommonInput.hlsl` |
| 单 DrawCall 入口 | `GPUTerrain.cs:129 DrawMeshInstancedIndirect` |
