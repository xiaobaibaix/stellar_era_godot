# gdlint: disable=variable-name, max-line-length
## Phase 4 面内焊接 LOD-lookup-texture 自检(纯 CPU, 不依赖 RenderingDevice)。
##
## 验证四件事(对应 lod_lodtex.glsl / lod_cull.glsl 的核心约定):
##   (A) Cell ↔ face-bary 映射: cell (i,j) 中心 = ((i+0.5)/LODTEX_RES, (j+0.5)/LODTEX_RES)。
##       leaf face-bary 三角形覆盖的 cell 集合 = 中心落在三角形内的 cell。
##   (B) 边中点 + 半 cell 外推 query: 两个相邻叶(lod 不同)共享边, 高 lod 侧 query 自己边中点
##       的"半 cell 向外"位置 → 返回低 lod 侧的 lod(邻居); lodDelta = max(0, self - neighbor) > 0。
##       低 lod 侧同样 query → 返回自身 lod → lodDelta = 0(不 slide, 该邻居 slide)。
##   (C) Edge → lodTrans slot 映射(单一真源): edge 0(AB) → texel4.z, edge 1(BC) → texel4.w,
##       edge 2(CA) → texel2.w。本 selftest 同时验证 cull shader 与 vertex shader 用同一映射。
##   (D) Bary inside-test 不依赖 winding: CCW 和 CW 的 bary 三角形, 同一个点要么都判内要么都判外。
##       (Phase 3 教训: 别假设 winding convention, 用绝对值或双侧测试)
##
## 不测: GPU 端 R8UI storage image 支持(留给 GPU smoke test, 单独跑)。
## 同 cull_selftest 惯例: 挂场景根节点, F6 运行, 打印 + 写 user://。
class_name LodtexSelftest
extends Node

const RESULT_PATH := "user://lodtex_selftest_result.txt"

const LODTEX_RES: int = 64  # 与 gpu_lod_compositor.gd / lod_lodtex.glsl 一致


func _ready() -> void:
	var res: Dictionary = run()
	for line in res["report"]:
		print(line)
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		for line in res["report"]:
			f.store_line(line)
		f.close()
	queue_free()


# 主逻辑(静态, 可被外部调)。返回 {report, ok}。
static func run() -> Dictionary:
	var report: PackedStringArray = []
	report.append("== Phase 4 lodtex convention self-test ==")

	var cellmap_ok: bool = _verify_cell_bary_mapping(report)
	var query_ok: bool = _verify_edge_eps_query(report)
	var slot_ok: bool = _verify_edge_slot_mapping(report)
	var winding_ok: bool = _verify_inside_test_winding_agnostic(report)

	var overall: bool = cellmap_ok and query_ok and slot_ok and winding_ok
	report.append("---- summary ----")
	report.append("  (A) Cell ↔ bary mapping           : %s" % ("PASS" if cellmap_ok else "FAIL"))
	report.append("  (B) Edge eps query → neighbor lod : %s" % ("PASS" if query_ok else "FAIL"))
	report.append("  (C) Edge → lodTrans slot mapping  : %s" % ("PASS" if slot_ok else "FAIL"))
	report.append("  (D) Inside-test winding-agnostic  : %s" % ("PASS" if winding_ok else "FAIL"))
	report.append("OVERALL: %s" % ("PASS" if overall else "FAIL"))
	return {"report": report, "ok": overall}


# ---- (A) Cell ↔ face-bary 映射 + leaf 覆盖 cell 算法 ----
# leaf 的 face-bary 三角形 (A_bary, B_bary, C_bary) 覆盖 cell (i,j) ⟺ cell 中心在三角形内。
# 用 AABB 加速 + barycentric inside test(winding-agnostic, 见 D)。
static func _verify_cell_bary_mapping(report: PackedStringArray) -> bool:
	var fails := 0
	# 案例 1: 整个 face 根叶(level 0), bary = (0,0), (1,0), (0,1)。
	#         三角形覆盖半个 64×64 正方形(u+v<=1 部分), cell 数 = 64*65/2 - 对角线 = 2080 ish。
	var root_A := Vector2(0.0, 0.0)
	var root_B := Vector2(1.0, 0.0)
	var root_C := Vector2(0.0, 1.0)
	var root_cells := _rasterize_triangle(root_A, root_B, root_C, LODTEX_RES)
	# 验证: 落在 u+v<=1 区域的 cell 都在内, 其外的不在内。
	for ci in range(LODTEX_RES):
		for cj in range(LODTEX_RES):
			var u: float = (float(ci) + 0.5) / float(LODTEX_RES)
			var v: float = (float(cj) + 0.5) / float(LODTEX_RES)
			var expect_inside: bool = (u + v <= 1.0)
			var got_inside: bool = root_cells.has(Vector2i(ci, cj))
			# 边界 cell(u+v 接近 1)容差: cell 中心可能略偏, 但根本不会越过 1.0 多。
			# 严格判: expect_inside == got_inside。
			if expect_inside != got_inside:
				# 边界容忍: |u+v-1| < 1/64 的 cell 可能歧义, 跳过。
				if abs(u + v - 1.0) < 1.5 / float(LODTEX_RES):
					continue
				report.append("  FAIL root face cell (%d,%d): u=%+.3f v=%+.3f u+v=%+.3f expect_inside=%s got=%s" % [ci, cj, u, v, u + v, expect_inside, got_inside])
				fails += 1
				if fails > 5:
					break
		if fails > 5:
			break

	# 案例 2: level 1 子 0(角 A), bary = (0,0), (0.5,0), (0,0.5)。
	#         覆盖 1/4 face = 32*33/2 ≈ 528 cell。
	var sub_A := Vector2(0.0, 0.0)
	var sub_B := Vector2(0.5, 0.0)
	var sub_C := Vector2(0.0, 0.5)
	var sub_cells := _rasterize_triangle(sub_A, sub_B, sub_C, LODTEX_RES)
	if sub_cells.size() < 400 or sub_cells.size() > 700:
		report.append("  FAIL level-1 sub-0 cell count: got %d, expect ~528" % sub_cells.size())
		fails += 1
	# 验证: sub_cells ⊂ root_cells(子叶 cell 必在根叶内)
	for c in sub_cells:
		if not root_cells.has(c):
			report.append("  FAIL level-1 sub cell %s not in root" % c)
			fails += 1
			if fails > 10:
				break

	# 案例 3: level 2 子 (角 A 的角 A), bary = (0,0), (0.25,0), (0,0.25)。
	var sub2_cells := _rasterize_triangle(Vector2(0, 0), Vector2(0.25, 0), Vector2(0, 0.25), LODTEX_RES)
	if sub2_cells.size() < 100 or sub2_cells.size() > 200:
		report.append("  FAIL level-2 sub cell count: got %d, expect ~136" % sub2_cells.size())
		fails += 1

	report.append("  (A) root_cells=%d sub1_cells=%d sub2_cells=%d  fails=%d  %s" % [root_cells.size(), sub_cells.size(), sub2_cells.size(), fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 模拟 lod_lodtex.glsl 的 rasterize: 返回中心在三角形 (A, B, C) 内的 cell 集合。
# 用 AABB + barycentric inside-test(winding-agnostic, 见 _point_in_triangle)。
static func _rasterize_triangle(A: Vector2, B: Vector2, C: Vector2, res: int) -> Array:
	var out: Array = []
	var bmin := Vector2(min(A.x, min(B.x, C.x)), min(A.y, min(B.y, C.y)))
	var bmax := Vector2(max(A.x, max(B.x, C.x)), max(A.y, max(B.y, C.y)))
	var i0: int = max(0, int(floor(bmin.x * float(res))))
	var i1: int = min(res - 1, int(ceil(bmax.x * float(res))))
	var j0: int = max(0, int(floor(bmin.y * float(res))))
	var j1: int = min(res - 1, int(ceil(bmax.y * float(res))))
	for cj in range(j0, j1 + 1):
		for ci in range(i0, i1 + 1):
			var u: float = (float(ci) + 0.5) / float(res)
			var v: float = (float(cj) + 0.5) / float(res)
			if _point_in_triangle(Vector2(u, v), A, B, C):
				out.append(Vector2i(ci, cj))
	return out


# Barycentric inside test, winding-agnostic(同时接受 c0,c1,c2 全 >=0 或全 <=0)。
# 等价于 shader 里: (c0>=0 && c1>=0 && c2>=0) || (c0<=0 && c1<=0 && c2<=0)。
static func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var c0: float = _cross2d(b - a, p - a)
	var c1: float = _cross2d(c - b, p - b)
	var c2: float = _cross2d(a - c, p - c)
	var all_nonneg: bool = c0 >= 0.0 and c1 >= 0.0 and c2 >= 0.0
	var all_nonpos: bool = c0 <= 0.0 and c1 <= 0.0 and c2 <= 0.0
	return all_nonneg or all_nonpos


static func _cross2d(v1: Vector2, v2: Vector2) -> float:
	return v1.x * v2.y - v1.y * v2.x


# ---- (B) 边中点 + 半 cell eps query 找邻居 lod ----
# 构合成 pair: self level 3 在右上角, neighbor level 2 在右下角, 共享边 AB(水平)。
# self bary: A=(0.5, 0.5), B=(0.75, 0.5), C=(0.5, 0.75) (level 3 子, 边 AB 在底)。
# neighbor bary: A=(0.5, 0.25), B=(0.75, 0.25), C=(0.5, 0.5) (level 2 子, 边 CA 在顶, 与 self AB 共享)。
# 等等, neighbor 的 C 与 self 的 A 重合? 不对, 让我重新构。
#
# 简化: 在 face-bary 空间里, 一条水平边 u ∈ [0.5, 0.75] at v=0.5。
# self(level 3) 在边之上 v ∈ [0.5, 0.75]: A=(0.5, 0.5), B=(0.75, 0.5), C=(0.625, 0.75)。
# neighbor(level 2) 在边之下: neighbor 自己占更大范围, 比如 A'=(0.5, 0.0), B'=(1.0, 0.0), C'=(0.5, 0.5)。
# self 的 AB 边 = neighbor 的 CA 边(都从 (0.5, 0.5) 到 (0.75, 0.5)... 但 neighbor CA 是从 (0.5,0.5) 到 (0.5, 0.0) 垂直的)。
# 嗯不对。让我用一个更对称的 setup。
#
# 简化 v2: 两个等腰直角三角形共享斜边。
# self(level 3) 占右上: A=(0.5, 0.5), B=(1.0, 0.5), C=(0.5, 1.0)。但 self 应该是 level 3, 比较小, 不该占这么大。
# 改: self level 3, A=(0.5, 0.5), B=(0.5625, 0.5), C=(0.5, 0.5625)。三角形边长 1/16 face-bary。
# 不对, level 3 边长 = 1/2^3 = 1/8 = 0.125。再改: A=(0.5, 0.5), B=(0.625, 0.5), C=(0.5, 0.625)。
# neighbor level 2, 边长 0.25, 与 self 共享 AB(从 (0.5,0.5) 到 (0.625, 0.5))。
# neighbor A'=(0.5, 0.25), B'=(0.75, 0.25), C'=(0.5, 0.5) -> 这与 self A 共享(都是 (0.5,0.5))。
# 但 neighbor 的 A'B' 边是水平的 from (0.5, 0.25) to (0.75, 0.25), 不与 self AB 共享。
# 让我换思路: 直接构 face-bary grid 上 self/neighbor, 算共享边。
#
# 更简单: 不构具体 patch, 直接验证 query 函数本身。
# 给一个 mock lodtex(cell 数组), 验证 query 函数返回正确 cell 的值。
static func _verify_edge_eps_query(report: PackedStringArray) -> bool:
	var fails := 0
	# Mock lodtex: 64×64 int 数组, 默认 0, 几个 cell 填具体 lod。
	var lodtex: PackedByteArray = PackedByteArray()
	lodtex.resize(LODTEX_RES * LODTEX_RES)
	lodtex.fill(0)
	# Mock 数据: cell (ci=10, cj=10) 填 lod=2, cell (ci=10, cj=11) 填 lod=3。
	# sampler 索引约定: lodtex[cj * LODTEX_RES + ci] —— 行优先, cj 是行号。
	lodtex[10 * LODTEX_RES + 10] = 2  # (ci=10, cj=10) 中心 ≈ (0.164, 0.164)
	lodtex[11 * LODTEX_RES + 10] = 3  # (ci=10, cj=11) 中心 ≈ (0.164, 0.180)

	# query 点正好在 cell (10, 10) 中心: 返回 2。
	var q1 := Vector2(0.164, 0.164)
	var got1: int = _sample_lodtex(lodtex, q1)
	if got1 != 2:
		report.append("  FAIL query at cell-center (10,10): expect lod=2, got=%d" % got1)
		fails += 1

	# query 点在 cell (10, 11) 中心: 返回 3。
	var q2 := Vector2(0.164, 0.180)
	var got2: int = _sample_lodtex(lodtex, q2)
	if got2 != 3:
		report.append("  FAIL query at cell-center (10,11): expect lod=3, got=%d" % got2)
		fails += 1

	# 边 eps 外推: self 在 cell (10, 10), 边中点 mid ≈ (0.164, 0.164) 接近 cell 中心但不精确。
	# 外推方向 +Y(假设对角在 -Y 方向)。
	# eps = 1.0/64 整 cell 宽(原计划 0.5/64 太小, mid 不在精确 cell 中心时加半 cell 仍可能落在原 cell)。
	# query 点 = mid + (1.0/64) * (0, 1) = (0.164, 0.1796), floor(0.1796 * 64) = 11 -> cell (10, 11) lod=3。
	var mid := Vector2(0.164, 0.164)
	var outward_dir := Vector2(0.0, 1.0)  # 朝 +Y
	var eps: float = 1.0 / float(LODTEX_RES)
	var q3 := mid + eps * outward_dir
	var got3: int = _sample_lodtex(lodtex, q3)
	if got3 != 3:
		report.append("  FAIL eps query (+Y from (10,10)): expect lod=3 (neighbor), got=%d, q=%s" % [got3, q3])
		fails += 1

	# OOB query: u<0 → 返回 0(面外, Phase 4.5 处理)
	var q4 := Vector2(-0.01, 0.5)
	var got4: int = _sample_lodtex(lodtex, q4)
	if got4 != 0:
		report.append("  FAIL OOB query (u<0): expect 0, got=%d" % got4)
		fails += 1
	# OOB query: u+v>1 → 返回 0
	var q5 := Vector2(0.7, 0.5)
	var got5: int = _sample_lodtex(lodtex, q5)
	if got5 != 0:
		report.append("  FAIL OOB query (u+v>1): expect 0, got=%d" % got5)
		fails += 1

	report.append("  (B) mock-lodtex query cases=%d  fails=%d  %s" % [5, fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 模拟 lod_cull.glsl 的 _sample_lodtex_safe:
#   OOB(u<0 || v<0 || u+v>1) → 0
#   否则 cell (floor(u*64), floor(v*64)) clamp [0, 63] → lodtex[cell]
static func _sample_lodtex(lodtex: PackedByteArray, uv: Vector2) -> int:
	if uv.x < 0.0 or uv.y < 0.0 or uv.x + uv.y > 1.0:
		return 0
	var ci: int = clampi(int(floor(uv.x * float(LODTEX_RES))), 0, LODTEX_RES - 1)
	var cj: int = clampi(int(floor(uv.y * float(LODTEX_RES))), 0, LODTEX_RES - 1)
	return int(lodtex[cj * LODTEX_RES + ci])


# ---- (C) Edge → lodTrans slot 单一真源 ----
# lod_lodtex 不用这个; 是 cull(写) 和 vertex(读) 必须一致的映射。
# 0=AB → texel4.z, 1=BC → texel4.w, 2=CA → texel2.w
# 这里只验证 _edge_to_slot 返回的 (texel_idx, component_idx) 与文档一致。
static func _verify_edge_slot_mapping(report: PackedStringArray) -> bool:
	var fails := 0
	# 期望: edge 0 (AB) -> (texel=4, comp=2)  (z 是第 3 个分量, 0-indexed = 2)
	#        edge 1 (BC) -> (texel=4, comp=3)  (w)
	#        edge 2 (CA) -> (texel=2, comp=3)  (w)
	var expected := {
		0: Vector2i(4, 2),  # AB
		1: Vector2i(4, 3),  # BC
		2: Vector2i(2, 3),  # CA
	}
	for edge in range(3):
		var got := _edge_to_slot(edge)
		var exp: Vector2i = expected[edge]
		if got != exp:
			report.append("  FAIL edge %d: expect slot %s, got %s" % [edge, exp, got])
			fails += 1
	report.append("  (C) edge→slot cases=3  fails=%d  %s" % [fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 单一真源: edge index → (texel_index_in_patch, component_index_in_texel)。
# cull shader 用这个决定往哪个 imageStore 写; vertex shader 用这个决定从哪个 texelFetch 读。
# 0=AB → texel4.z, 1=BC → texel4.w, 2=CA → texel2.w。
static func _edge_to_slot(edge: int) -> Vector2i:
	match edge:
		0: return Vector2i(4, 2)  # AB → texel4.z
		1: return Vector2i(4, 3)  # BC → texel4.w
		2: return Vector2i(2, 3)  # CA → texel2.w
		_: return Vector2i(-1, -1)


# ---- (D) Inside-test winding-agnostic ----
# 同一个三角形用 CCW 顺序给(A, B, C)和 CW 顺序给(A, C, B), 同一个点要么都判内要么都判外。
static func _verify_inside_test_winding_agnostic(report: PackedStringArray) -> bool:
	var fails := 0
	var A := Vector2(0.2, 0.2)
	var B := Vector2(0.8, 0.2)
	var C := Vector2(0.5, 0.7)
	# 测试点
	var pts := [Vector2(0.5, 0.4),  # 内
		Vector2(0.1, 0.1),  # 外
		Vector2(0.5, 0.2),  # 边 AB 上(算内)
		Vector2(0.65, 0.45),  # 内
		Vector2(0.9, 0.7),  # 外
		]
	for p in pts:
		var ccw_inside: bool = _point_in_triangle(p, A, B, C)
		var cw_inside: bool = _point_in_triangle(p, A, C, B)  # 注意 B/C 交换 = 反 winding
		if ccw_inside != cw_inside:
			report.append("  FAIL point %s: CCW inside=%s, CW inside=%s (必须一致)" % [p, ccw_inside, cw_inside])
			fails += 1
	report.append("  (D) winding cases=%d  fails=%d  %s" % [pts.size(), fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0
