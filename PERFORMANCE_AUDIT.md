# StellarEra 性能审查报告

## 问题现象

靠近行星表面时帧率从 60+ 暴跌到 ~21 甚至更低，移动时尤为严重。

## 运行时参数 (main.tscn)

| 参数 | 值 | 影响 |
|------|-----|------|
| radius | 500 | 根面 edge_len ≈ 525 |
| patchResolution | 16 | 每 patch 153 索引顶点 → 展开后 768 顶点 |
| maxLevel | 8 | 四叉树最深 8 层，靠近时全展开 |
| splitFactor | 2.5 | 细分触发距离 |
| prefetchFactor | 1.4 | 预取环倍率 |
| nearRadius | 50 | 近距强制细分半径 |

---

## 瓶颈 1 (P0): target_level_at 嵌套调用 — 靠近时的头号杀手

### 调用链

```
Planet.update()                          # planet.gd:452
  └─ QNode.select_lod() × 20 根          # planet.gd:471
       └─ compute_strides()              # qnode.gd:75
            └─ target_level_at() × 3 边  # qnode.gd:87
                 └─ _root_containing()   # planet.gd:248  遍历 20 根面
                 └─ 逐层下降 × maxLevel  # planet.gd:270  每层 4 次 point_in_tri
```

### 代码位置

**planet.gd:260-291** `target_level_at`:
```gdscript
func target_level_at(p: Vector3) -> int:
    var tri := _root_containing(p)       # 先遍历 20 个根面找包含点
    # ...逐层下降, 每层 4 次 point_in_tri
    while level < max_l:                 # max_l = 8
        for tt in ch:                    # 最多 4 次
            if point_in_tri(...)         # planet.gd:554
```

**qnode.gd:75-93** `compute_strides`:
```gdscript
func compute_strides() -> Array:
    for e in range(3):                   # 3 条边, 每条调 1 次
        var nb: int = planet.target_level_at(sample)  # qnode.gd:87
```

### 量级估算 (靠近时)

| 指标 | 计算 | 结果 |
|------|------|------|
| 可见叶子节点 | FpsLabel 显示 | ~386 |
| 单次 target_level_at 的 point_in_tri | 20 根面 + 4×8 层 | ~52 |
| 每节点 compute_strides 调用 | 3 边 × 52 | ~156 |
| 每帧 (LOD tick) 总计 | 386 × 156 | **~60,000 次** |

每次 `point_in_tri` 做 3 次叉乘 + 3 次点积比较（planet.gd:554-564），纯 GDScript 调用，无法被编译器内联。

### 根因

`target_level_at` 是**纯几何函数**——给定一个方向，从根开始下降到该方向的最终层级。它不依赖任何动态状态，只依赖 `_cam_pos` 和四叉树拓扑。但当前每帧对每个节点的每条边都从头算一遍，即使方向几乎没变。

---

## 瓶颈 2 (P0): _do_merge 每帧全量重建合并 mesh

### 代码位置

**planet.gd:407-449** `_do_merge`:
```gdscript
func _do_merge() -> void:
    # 签名检测: 可见集合不变则跳过
    if sig == _last_merge_sig:
        return
    # 变了 → 全量重建
    for n in _visible_leaves:            # ~386 个
        mv.append_array(pv)              # 拼接顶点
        mn.append_array(pn)              # 拼接法线
        mc.append_array(pc)              # 拼接颜色
    am.add_surface_from_arrays(...)      # 创建新 ArrayMesh
```

### 量级估算

| 指标 | 计算 | 结果 |
|------|------|------|
| 单 patch 非索引顶点 | N=16 → 三角形 ~256 × 3 | ~768 顶点 |
| 合并顶点总量 | 386 × 768 | **~296,000 顶点** |
| 每帧操作 | append_array × 3 + ArrayMesh 创建 | 全量拷贝 |

### 为什么靠近时更严重

远距离时可见 patch 少（~30 个）、相机不动时签名不变→跳过。靠近+行走时：
- 视角移动导致可见集合每帧变化 → 签名不同 → 每帧重建
- patch 数从 ~30 暴增到 ~386 → 数据量 10 倍以上

### 顶点膨胀根因

**patch_builder.gd:176-187** 把索引网格展开成非索引：
```gdscript
for t in range(nidx):                    # nidx = 三角形数 × 3
    verts[t] = Vector3(pos[s], pos[s+1], pos[s+2])
    vnorms[t] = Vector3(nor[s], nor[s+1], nor[s+2])
    vcols[t] = Color(col[s], col[s+1], col[s+2])
```

N=16 时：索引网格 153 顶点 → 非索引 768 顶点（**5 倍膨胀**）。合并渲染时这 5 倍数据全部参与 append_array。

---

## 瓶颈 3 (P1): worker 回调在主线程密集创建 ArrayMesh

### 代码位置

**planet.gd:377-393** `_on_mesh_job`:
```gdscript
func _on_mesh_job(job_id: int, data: Dictionary) -> void:
    node.set_mesh(_gen_array_mesh(data), int(data.tris))  # 主线程创建 ArrayMesh
    _apply_node_materials(node)
```

**planet.gd:298-342** `_gen_array_mesh`:
```gdscript
func _gen_array_mesh(data: Dictionary) -> ArrayMesh:
    var am := ArrayMesh.new()
    am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)  # C++ 但有调用开销
    return am
```

### 为什么靠近时严重

靠近时大量子节点首次创建 → 大量 worker 任务提交 → 完成时回调密集爆发到主线程。每个回调都要 `ArrayMesh.new()` + `add_surface_from_arrays` + `_apply_node_materials`。虽然单个开销不大，但几十个同时回来就会挤占帧时间。

FOREGROUND_INFLIGHT_CAP = 24 意味着最多 24 个同时 in-flight，但完成时机集中。

---

## 瓶颈 4 (P1): 四叉树递归遍历 + 合并宽限子树

### 代码位置

**qnode.gd:97-156** `select_lod` 递归遍历整棵树。除了活跃子树，还遍历 `_retired`（合并宽限暂存）子树：

```gdscript
# qnode.gd:193-201
func _hide_subtree() -> void:
    if children != null:
        for c in children:
            c._hide_subtree()
    if _retired != null:                 # 3 秒宽限内的暂存子树也遍历
        for c in _retired:
            c._hide_subtree()
```

MERGE_HOLD_SEC = 3.0 秒内，暂存子树仍参与每帧递归遍历。行走时大量节点在合并/分裂边界抖动 → retired 子树堆积 → 递归节点数膨胀。

---

## 瓶颈 5 (P2): player._physics_process 每帧调 height_at

### 代码位置

**player.gd:99-101**:
```gdscript
func _ground_radius(up: Vector3) -> float:
    var h: float = planet.height_at(up.x, up.y, up.z)  # 每帧 1 次
```

**terrain.gd:115-139** `height_at`:
```gdscript
func height_at(x, y, z) -> float:
    if warp > 0.0:
        noise_w.get_noise_3d(...) × 3    # 3 次域扭曲采样
    noise_c.get_noise_3d(...)            # 大陆
    noise_m.get_noise_3d(...)            # 山脉
    noise_plate.get_noise_3d(...)        # 板块
```

单次约 6 次 `get_noise_3d`（C++ 但有 GDScript 调用开销）。每帧 1 次，不是主要瓶颈，但行走时如果 `_reground` 触发更多采样则放大。

---

## 瓶颈 6 (P2): DirectionalLight3D 阴影配置不当

### 代码位置

**main.tscn:86-89**:
```
shadow_enabled = true
directional_shadow_max_distance = 200.0
```

行星半径 500，但阴影最大距离只有 200。角色靠近表面时，阴影覆盖范围远小于可见区域，且阴影渲染本身有开销。对程序化行星而言，阴影带来的视觉收益远小于性能代价。

---

## 瓶颈 7 (P2): @tool 模式额外开销

**planet.gd:7** `@tool` + **main.gd:7** `@tool`：编辑器中也会跑 `_process`。虽然不是运行时问题，但编辑器里操作场景时也会卡。

---

## 修复建议

### P0-1: 缓存 target_level_at 结果

```gdscript
# planet.gd 新增
var _tla_cache: Dictionary = {}  # direction_quantized -> level
var _tla_cache_gen: int = -1

func target_level_at(p: Vector3) -> int:
    # generation 变化时清缓存
    if _tla_cache_gen != _gen:
        _tla_cache.clear()
        _tla_cache_gen = _gen
    # 量化方向作为 key (精度 1e-4 够用)
    var key := "%.4f,%.4f,%.4f" % [p.x, p.y, p.z]
    if _tla_cache.has(key):
        return _tla_cache[key]
    # ...原逻辑...
    _tla_cache[key] = level
    return level
```

**预计效果**：相机不动时 100% 命中；缓慢移动时大部分命中。消除 80%+ 的 point_in_tri 调用。

### P0-2: 合并 mesh 增量更新

```gdscript
# 不全量重建, 只 diff
var _merged_set: Dictionary = {}  # instance_id -> true

func _do_merge() -> void:
    # 检查增删
    var new_set: Dictionary = {}
    for n in _visible_leaves:
        new_set[n.get_instance_id()] = true
    # 如果只是子集关系变化, 用 RenderingServer 增量更新
    # 而非全量 append_array
```

或者更简单的方案：**静止时跳过合并**（已有签名检测），移动时降频合并（每 2-3 帧合并一次，中间帧沿用旧 mesh）。

### P1-1: 保留索引网格，合并时用索引偏移

修改 `PatchBuilder.build_patch_arrays` 返回索引网格，合并时累加顶点偏移量。顶点从 768 降到 153（**5 倍减少**）。

### P1-2: worker 回调用 RenderingServer

```gdscript
# 绕过 ArrayMesh, 直接用 RenderingServer
var rid := RenderingServer.mesh_create()
RenderingServer.mesh_add_surface_from_arrays(rid, Mesh.PRIMITIVE_TRIANGLES, surf)
```

### P2-1: 降低 LOD 参数

在 main.tscn 的 PlanetParams 里：
- `maxLevel`: 8 → 6（四叉树节点数降 16 倍）
- `patchResolution`: 16 → 8（单 patch 顶点降 4 倍）

### P2-2: 关闭 DirectionalLight 阴影

```
shadow_enabled = false
```

或大幅增加 `directional_shadow_max_distance`。

---

## 快速验证方法

1. 运行项目，观察 FpsLabel 变化
2. 用 F1 打开线框模式，靠近表面观察 patch 数量
3. 临时在 `target_level_at` 开头加 `push_error("tla called")`，观察输出频率
4. 临时在 `_do_merge` 的 `am.add_surface_from_arrays` 前加计时，测量合并耗时
