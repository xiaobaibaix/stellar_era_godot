# gdlint: disable=variable-name, max-line-length
## 烘焙好的 MinMax 高度金字塔(可序列化 .res)。
##
## 存每面 mip0(方形 (BAKE_RES+1)², R=min/G=max 交错的 PackedFloat32Array), 运行时 build_pyramid()
## 现算全 mip(2×2 min/max 归约, 哨兵自动剔除)。Phase 2 把金字塔上传成 RD Texture2DArray(20 层带 mip)
## 供 lod_traverse / lod_build_patches 采样 patch 包围盒。
##
## 坐标系: texel (i,j), u=i/BAKE_RES, v=j/BAKE_RES, 有效区 u+v≤1(i+j≤BAKE_RES);
## 无效区(i+j>BAKE_RES)存哨兵 MIN_SENTINEL/MAX_SENTINEL, 归约时跳过。
##
## 数值单位: 世界单位(= height_at × maxHeight), 与 radius 同量纲 → min/max 直接给径向包围盒。
class_name GpuMinMaxData
extends Resource

const MIN_SENTINEL: float = 1.0e30
const MAX_SENTINEL: float = -1.0e30

@export var bake_res: int = 1024
@export var radius: float = 100.0
@export var max_height: float = 8.0
@export var seed_hash: int = 0
# 每面 mip0: PackedFloat32Array, 长度 = (bake_res+1)² × 2, [min,max,min,max,...]
@export var face_mip0: Array = []

var _pyramid: Array = []   # 缓存: [face][mip] = PackedFloat32Array; 懒建


# 立方体边数必须 2 的幂(保证逐级对半归约到 1)。
static func is_valid_res(res: int) -> bool:
	return res >= 2 and (res & (res - 1)) == 0


# mip0 texel 索引(线性, ×2 取 min/max 对)。
func _idx(i: int, j: int) -> int:
	var s: int = bake_res + 1
	return (j * s + i) * 2


# 取面 fi 的 mip0(必要时建空)。
func get_face_mip0(fi: int) -> PackedFloat32Array:
	if fi >= face_mip0.size():
		face_mip0.resize(GpuIco.FACE_COUNT)
	var arr: Variant = face_mip0[fi]
	if arr == null:
		var s: int = bake_res + 1
		arr = PackedFloat32Array()
		(arr as PackedFloat32Array).resize(s * s * 2)
		face_mip0[fi] = arr
	return arr


# 设面 fi 的 mip0(烘焙器写入用)。
func set_face_mip0(fi: int, arr: PackedFloat32Array) -> void:
	if face_mip0.size() < GpuIco.FACE_COUNT:
		face_mip0.resize(GpuIco.FACE_COUNT)
	face_mip0[fi] = arr
	_pyramid = []   # 数据变 → 金字塔失效


# texel (i,j) 是否在有效三角区内。
func _is_valid(i: int, j: int) -> bool:
	return i + j <= bake_res


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


# 单面金字塔: [0]=mip0(传入), [k]=对 mip k-1 做对半 scatter 归约。
func _build_face_pyramid(mip0: PackedFloat32Array) -> Array:
	var mips: Array = [mip0]
	var prev: PackedFloat32Array = mip0
	while true:
		var prev_edge: int = bake_res >> (mips.size() - 1)
		if prev_edge <= 1:
			break   # 已到最粗(1)
		var cur_edge: int = prev_edge >> 1
		var cur: PackedFloat32Array = PackedFloat32Array()
		cur.resize((cur_edge + 1) * (cur_edge + 1) * 2)
		# 初始化 cur 全哨兵
		for k in range(cur.size()):
			cur[k] = MIN_SENTINEL if (k & 1) == 0 else MAX_SENTINEL
		# scatter: prev 每个 texel 累计进 cur 的父 texel (i>>1, j>>1)
		for j in range(prev_edge + 1):
			for i in range(prev_edge + 1):
				if i + j > prev_edge:
					continue   # 无效区跳过
				var src: int = (j * (prev_edge + 1) + i) * 2
				var pmn: float = prev[src]
				var pmx: float = prev[src + 1]
				if pmn >= MIN_SENTINEL * 0.5:   # 哨兵 min → 跳过(本层 mip0 不会, 但归约中可能)
					continue
				var pi: int = i >> 1
				var pj: int = j >> 1
				var dst: int = (pj * (cur_edge + 1) + pi) * 2
				if pmn < cur[dst]:
					cur[dst] = pmn
				if pmx > cur[dst + 1]:
					cur[dst + 1] = pmx
		mips.append(cur)
		prev = cur
	return mips


# 最近邻采样面 fi 指定 mip 的 (u,v) 的 (min,max)。u,v∈[0,1], u+v≤1。调试/自检用。
func sample_nearest(fi: int, mip: int, u: float, v: float) -> Vector2:
	var pyr: Array = build_pyramid()
	var fmips: Array = pyr[fi]
	mip = clampi(mip, 0, fmips.size() - 1)
	var edge: int = bake_res >> mip
	var i: int = clampi(int(round(u * float(edge))), 0, edge)
	var j: int = clampi(int(round(v * float(edge))), 0, edge)
	var arr: PackedFloat32Array = fmips[mip]
	var idx: int = (j * (edge + 1) + i) * 2
	return Vector2(arr[idx], arr[idx + 1])
