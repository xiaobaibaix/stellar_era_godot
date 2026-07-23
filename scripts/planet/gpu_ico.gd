# gdlint: disable=variable-name, max-line-length
## 正二十面体几何真源(GPU 驱动 LOD 专用)。
##
## 12 顶点 + 20 面索引与 scripts/planet/planet.gd::_build_roots【逐位一致】(同黄金比、同归一化、
## 同面绕序)——烘焙(heightmap_baker)、GPU 遍历(lod_traverse)、跨面接缝焊接 都必须用本表,
## 否则跨面边对不齐、裂缝。唯一几何真源, 杜绝多份抄写漂移。
##
## 边邻接(30 边): icosahedron 20 面 × 3 边 = 60 个有向面边, 每条无向边被 2 个面共享 → 30 条唯一边。
## build_adjacency() 给出 adj[face][edge] = {neighbor_face, neighbor_edge, flipped}, 供 Phase 4.5
## 跨面焊接查邻居 LOD。Phase 0 先做面内焊接, 跨面表先备好。
##
## 面内边编号约定(与 qnode._split 的 A/B/C 一致):
##   edge 0 = AB = (V[v0], V[v1])
##   edge 1 = BC = (V[v1], V[v2])
##   edge 2 = CA = (V[v2], V[v0])
class_name GpuIco
extends RefCounted

const T: float = (1.0 + sqrt(5.0)) / 2.0   # 黄金比 φ

# 12 顶点(未归一化的 raw, 与 planet.gd 同序); 用 verts() 取归一化结果。
const RAW_VERTS: Array = [
	Vector3(-1, T, 0), Vector3(1, T, 0), Vector3(-1, -T, 0), Vector3(1, -T, 0),
	Vector3(0, -1, T), Vector3(0, 1, T), Vector3(0, -1, -T), Vector3(0, 1, -T),
	Vector3(T, 0, -1), Vector3(T, 0, 1), Vector3(-T, 0, -1), Vector3(-T, 0, 1),
]

# 20 面(顶点索引三元组, 绕序与 planet.gd::_faces 完全一致)。
const FACES: Array = [
	[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
	[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
	[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
	[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]

const FACE_COUNT: int = 20
const EDGE_PER_FACE: int = 3


# 归一化后的 12 顶点(单位球)。
static func verts() -> Array:
	var out: Array = []
	out.resize(RAW_VERTS.size())
	for i in range(RAW_VERTS.size()):
		out[i] = (RAW_VERTS[i] as Vector3).normalized()
	return out


# 第 fi 个面的 3 个单位角点 [A, B, C]。
static func face_corners(fi: int) -> Array:
	var vs := verts()
	var f: Array = FACES[fi]
	return [vs[f[0]], vs[f[1]], vs[f[2]]]


# 面内边 ei 的两端顶点索引(有序, 沿面绕序): ei=0→(v0,v1) AB, 1→(v1,v2) BC, 2→(v2,v0) CA。
static func face_edge_vertices(fi: int, ei: int) -> Vector2i:
	var f: Array = FACES[fi]
	var a: int = f[ei]
	var b: int = f[(ei + 1) % EDGE_PER_FACE]
	return Vector2i(a, b)


# 30 边邻接表。返回 adj[fi][ei] = {neighbor_face, neighbor_edge, flipped}。
# flipped: 邻居面边方向是否与 (a→b) 同向。规范流形下恒 false(共享边两对面绕序相反);
# 任一 flipped=true 即绕序不一致 → verify() 会报错。
static func build_adjacency() -> Array:
	# key "min_max" → Array[[fi,ei], ...]
	var dict: Dictionary = {}
	for fi in range(FACE_COUNT):
		for ei in range(EDGE_PER_FACE):
			var e := face_edge_vertices(fi, ei)
			var key := "%d_%d" % [min(e.x, e.y), max(e.x, e.y)]
			if not dict.has(key):
				dict[key] = []
			(dict[key] as Array).append([fi, ei])
	# 填 adj
	var adj: Array = []
	adj.resize(FACE_COUNT)
	for fi in range(FACE_COUNT):
		adj[fi] = [{}, {}, {}]
		for ei in range(EDGE_PER_FACE):
			var e := face_edge_vertices(fi, ei)
			var key := "%d_%d" % [min(e.x, e.y), max(e.x, e.y)]
			var pairs: Array = dict[key]
			# 找另一个 (fi2,ei2) != (fi,ei)
			var nf: int = -1
			var nej: int = -1
			for p in pairs:
				if p[0] != fi or p[1] != ei:
					nf = p[0]
					nej = p[1]
					break
			var flipped: bool = false
			if nf >= 0:
				var ne := face_edge_vertices(nf, nej)
				# 邻居边 (na,nb); 与本面 (a,b) 同向 = flipped true
				flipped = (ne.x == e.x and ne.y == e.y)
			adj[fi][ei] = {"neighbor_face": nf, "neighbor_edge": nej, "flipped": flipped}
	return adj


# 完整性自检(Phase 0 用; 返回报告行数组, 首行 PASS/FAIL)。
static func verify() -> PackedStringArray:
	var rep: PackedStringArray = []
	var ok := true
	rep.append("== GpuIco icosahedron verify ==")
	rep.append("verts=%d faces=%d" % [RAW_VERTS.size(), FACES.size()])
	# 1) 顶点单位化
	var vs := verts()
	var bad_v := 0
	for v in vs:
		if absf((v as Vector3).length() - 1.0) > 1e-5:
			bad_v += 1
	if bad_v > 0:
		ok = false
	rep.append("  [verts unit] non-unit=%d  %s" % [bad_v, "PASS" if bad_v == 0 else "FAIL"])
	# 2) 面索引范围
	var bad_idx := 0
	for f in FACES:
		for vi in f:
			if vi < 0 or vi >= RAW_VERTS.size():
				bad_idx += 1
	if bad_idx > 0:
		ok = false
	rep.append("  [face idx] out-of-range=%d  %s" % [bad_idx, "PASS" if bad_idx == 0 else "FAIL"])
	# 3) 每条无向边恰被 2 面共享
	var dict: Dictionary = {}
	for fi in range(FACE_COUNT):
		for ei in range(EDGE_PER_FACE):
			var e := face_edge_vertices(fi, ei)
			var key := "%d_%d" % [min(e.x, e.y), max(e.x, e.y)]
			if not dict.has(key):
				dict[key] = 0
			dict[key] = int(dict[key]) + 1
	var edge_count: int = dict.size()
	var not_two: int = 0
	for k in dict:
		if int(dict[k]) != 2:
			not_two += 1
	# icosahedron 唯一边 = 30
	if edge_count != 30 or not_two > 0:
		ok = false
	rep.append("  [edges] unique=%d (expect 30)  shared!=2: %d  %s" % [edge_count, not_two, "PASS" if edge_count == 30 and not_two == 0 else "FAIL"])
	# 4) 流形: 邻居边方向相反(flipped 全 false)
	var adj := build_adjacency()
	var no_neighbor: int = 0
	var flipped_count: int = 0
	for fi in range(FACE_COUNT):
		for ei in range(EDGE_PER_FACE):
			var a: Dictionary = adj[fi][ei]
			if a["neighbor_face"] < 0:
				no_neighbor += 1
			if a["flipped"]:
				flipped_count += 1
	if no_neighbor > 0 or flipped_count > 0:
		ok = false
	rep.append("  [manifold] no_neighbor=%d  flipped=%d (expect 0/0)  %s" % [no_neighbor, flipped_count, "PASS" if no_neighbor == 0 and flipped_count == 0 else "FAIL"])
	# 5) 每面 3 顶点不重合 + 面积>0
	var degenerate: int = 0
	for fi in range(FACE_COUNT):
		var c := face_corners(fi)
		var a: Vector3 = c[0]
		var b: Vector3 = c[1]
		var cc: Vector3 = c[2]
		var n := (b - a).cross(cc - a)
		if n.length() < 1e-6:
			degenerate += 1
	if degenerate > 0:
		ok = false
	rep.append("  [face area] degenerate=%d  %s" % [degenerate, "PASS" if degenerate == 0 else "FAIL"])
	rep.append("OVERALL: %s" % ("PASS ✓" if ok else "FAIL ✗"))
	return rep
