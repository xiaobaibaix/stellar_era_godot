# gdlint: disable=variable-name, max-line-length
## 烘焙好的 MinMax 高度金字塔(可序列化 .res), cell 布局。
##
## Phase 3 重构: 从 vertex grid (bake_res+1)² 改为 cell grid (bake_res)², 标准 2×2 gather 归约。
## 这样 mip 链 bake_res → bake_res/2 → ... → 1 与 Godot RD Texture2DArray 自动 mip 链对齐
## (Godot 对 mip0 = W×H 推导: mip_k = max(1, floor(W/2^k))×max(1, floor(H/2^k)))。
## 旧 vertex-grid 布局 mip0=(bake_res+1)², mip1=(floor((bake_res+1)/2))²=bake_res/2², 与我们的
## scatter 归约产出 (bake_res/2+1)² 对不上 → 无法用 Texture2DArray 自动 mip。
##
## 数据布局(每面):
##   mip0: bake_res × bake_res cells, 行主序, interleaved [min0, max0, min1, max1, ...] (float32 pairs)
##   mip k: (bake_res >> k) × (bake_res >> k) cells, 同布局
##   cell (i, j) 在 mip k 的字节偏移 = (j * edge_k + i) * 2, 其中 edge_k = bake_res >> k
##
## 坐标系: cell (i, j) 中心位于 face-bary (u, v) = ((i+0.5)/bake_res, (j+0.5)/bake_res)。
## 有效性: cell 中心在三角形内 ⟺ u + v ≤ 1 ⟺ i + j ≤ bake_res - 1 ⟺ i + j < bake_res。
## 无效 cell 存哨兵(MIN_SENTINEL, MAX_SENTINEL), 归约时跳过。
##
## 数值单位: 世界单位(= height_at × maxHeight), 与 radius 同量纲 → min/max 直接给径向包围盒。
class_name GpuMinMaxData
extends Resource

const MIN_SENTINEL: float = 1.0e30
const MAX_SENTINEL: float = -1.0e30

## Baker 版本: 进入 seed_hash, 改 baker 算法时 +1 使旧缓存失效。
const BAKER_VERSION: int = 2   # v2 = cell 布局 + gather 归约(取代 v1 vertex 布局 + scatter)

@export var bake_res: int = 1024
@export var radius: float = 100.0
@export var max_height: float = 8.0
@export var seed_hash: int = 0
# 每面 mip0: PackedFloat32Array, 长度 = bake_res² × 2, [min,max,min,max,...]
@export var face_mip0: Array = []

var _pyramid: Array = []   # 缓存: [face][mip] = PackedFloat32Array; 懒建


# bake_res 必须 2 的幂(保证逐级对半归约到 1)。
static func is_valid_res(res: int) -> bool:
	return res >= 2 and (res & (res - 1)) == 0


# 设面 fi 的 mip0(烘焙器写入用)。
func set_face_mip0(fi: int, arr: PackedFloat32Array) -> void:
	if face_mip0.size() < GpuIco.FACE_COUNT:
		face_mip0.resize(GpuIco.FACE_COUNT)
	face_mip0[fi] = arr
	_pyramid = []   # 数据变 → 金字塔失效


# 取面 fi 的 mip0(必要时建空)。
func get_face_mip0(fi: int) -> PackedFloat32Array:
	if fi >= face_mip0.size():
		face_mip0.resize(GpuIco.FACE_COUNT)
	var arr: Variant = face_mip0[fi]
	if arr == null:
		arr = PackedFloat32Array()
		(arr as PackedFloat32Array).resize(bake_res * bake_res * 2)
		face_mip0[fi] = arr
	return arr


# 构建并缓存全金字塔。返回 [face][mip] = PackedFloat32Array(mip 级数据, 同 min/max 交错布局)。
func build_pyramid() -> Array:
	if not _pyramid.is_empty():
		return _pyramid
	var result: Array = []
	result.resize(GpuIco.FACE_COUNT)
	for fi in range(GpuIco.FACE_COUNT):
		result[fi] = _build_face_pyramid(face_mip0[fi] as PackedFloat32Array)
	_pyramid = result
	return result


# 单面金字塔: [0]=mip0(传入), [k]=对 mip k-1 做 2×2 gather 归约。
# 标准 gather: parent(i', j') 从 4 个 children(2i'+d, 2j'+d) for d∈{0,1}² 累计 min/max。
# 全 sentinel 的 parent 留 sentinel(代表该区域整块在三角形外)。
func _build_face_pyramid(mip0: PackedFloat32Array) -> Array:
	var mips: Array = [mip0]
	var prev: PackedFloat32Array = mip0
	var prev_edge: int = bake_res
	while prev_edge > 1:
		var cur_edge: int = prev_edge >> 1
		var cur: PackedFloat32Array = PackedFloat32Array()
		cur.resize(cur_edge * cur_edge * 2)
		# 初始化全哨兵
		for k in range(cur.size()):
			cur[k] = MIN_SENTINEL if (k & 1) == 0 else MAX_SENTINEL
		# gather 归约: 每 parent cell 累计 4 个 children
		for jp in range(cur_edge):
			for ip in range(cur_edge):
				var pmn: float = MIN_SENTINEL
				var pmx: float = MAX_SENTINEL
				var any_valid: bool = false
				for dj in range(2):
					for di in range(2):
						var ci: int = ip * 2 + di
						var cj: int = jp * 2 + dj
						var src: int = (cj * prev_edge + ci) * 2
						var cmn: float = prev[src]
						if cmn >= MIN_SENTINEL * 0.5:
							continue   # child 是 sentinel, 跳过
						any_valid = true
						pmn = min(pmn, cmn)
						pmx = max(pmx, prev[src + 1])
				if any_valid:
					var dst: int = (jp * cur_edge + ip) * 2
					cur[dst] = pmn
					cur[dst + 1] = pmx
		mips.append(cur)
		prev = cur
		prev_edge = cur_edge
	return mips


# 最近邻采样面 fi 指定 mip 的 (u, v) 的 (min, max)。u, v∈[0,1]。
# 找包含 (u, v) 的 cell: i = floor(u * edge_k), j = floor(v * edge_k)。
# 返回 (min, max); 若 cell 是哨兵(u, v 落到三角形外), 返回哨兵对。
func sample_nearest(fi: int, mip: int, u: float, v: float) -> Vector2:
	var pyr: Array = build_pyramid()
	var fmips: Array = pyr[fi]
	mip = clampi(mip, 0, fmips.size() - 1)
	var edge: int = bake_res >> mip
	var i: int = clampi(int(floor(u * float(edge))), 0, edge - 1)
	var j: int = clampi(int(floor(v * float(edge))), 0, edge - 1)
	var arr: PackedFloat32Array = fmips[mip]
	var idx: int = (j * edge + i) * 2
	return Vector2(arr[idx], arr[idx + 1])
