# gdlint: disable=variable-name, max-line-length, unused_parameter
## patch 几何构建(Phase 3a: 预烘焙位移+法线版)。
## 铺【已位移网格】(d·(R+h·maxH), 顶点位置直接 = 模型空间最终位置) + 【裙边】(同位置, alpha=0 标记)。
## 法线用与旧 shader 完全相同的有限差分算好, 塞进 ARRAY_NORMAL。
## height h 塞进 COLOR.r(shader 用 v_h 给配色 + 雪线判定), COLOR.a 仍是裙边标志位。
##
## 取代旧版"铺理想球面 + shader 每帧 terrain_height 3 次/顶点"的方案:
## worker 算一次缓存 → shader 只读取属性, GPU 顶点着色器从 ~120 noise/顶点 降到 1 noise/顶点(只 moisture)。
class_name PatchBuilder
extends RefCounted

# 与 shader u_normal_eps 同值(法线有限差分步长, 方向空间)。worker 用同值 → 视觉与原 shader 完全一致。
const NORMAL_EPS: float = 0.001


static func _row_index(i: int, j: int, N: int) -> int:
	@warning_ignore("integer_division")
	return i * (N + 1) - (i * (i - 1)) / 2 + j


# 递归中点细分一条边(P->Q), N 必须是 2 的幂, 返回 N+1 个单位向量
static func dyadic_edge(P: Vector3, Q: Vector3, N: int) -> Array:
	var pts: Array = [P, Q]
	while pts.size() - 1 < N:
		var nxt: Array = []
		for i in range(pts.size() - 1):
			nxt.append(pts[i])
			nxt.append(((pts[i] + pts[i + 1]) * 0.5).normalized())
		nxt.append(pts[pts.size() - 1])
		pts = nxt
	return pts


# 有限差分法线(与 terrain.gdshader vertex() 里的算法逐位一致)。
# d: 中心方向(单位向量); h0: 中心高度(已算, 避免重算); R/max_h: 行星半径/高度比例。
# 返回: 朝外的单位法线。
static func _finite_diff_normal(terrain, d: Vector3, h0: float, R: float, max_h: float) -> Vector3:
	var up_n: Vector3 = Vector3(1.0, 0.0, 0.0) if absf(d.x) <= 0.9 else Vector3(0.0, 1.0, 0.0)
	var t1: Vector3 = d.cross(up_n).normalized()
	var t2: Vector3 = d.cross(t1).normalized()
	var d1: Vector3 = (d + t1 * NORMAL_EPS).normalized()
	var d2: Vector3 = (d + t2 * NORMAL_EPS).normalized()
	var r0: float = R + h0 * max_h
	var r1: float = R + terrain.height_at(d1.x, d1.y, d1.z) * max_h
	var r2: float = R + terrain.height_at(d2.x, d2.y, d2.z) * max_h
	var p0: Vector3 = d * r0
	var p1: Vector3 = d1 * r1
	var p2: Vector3 = d2 * r2
	var n: Vector3 = (p1 - p0).cross(p2 - p0).normalized()
	if n.dot(d) < 0.0:
		n = -n
	return n


# A,B,C: 单位向量。strides 恒 [1,1,1](裙边缝合), max_h/terrain 现在真正用来算位移+法线。
static func build_patch_arrays(A: Vector3, B: Vector3, C: Vector3, N: int, R: float, max_h: float, terrain, _strides: Array = [1, 1, 1]) -> Dictionary:
	@warning_ignore("integer_division")
	var main_count: int = ((N + 1) * (N + 2)) / 2
	var skirt_per_edge: int = N + 1
	var total_count: int = main_count + 3 * skirt_per_edge   # 主网格 + 3 条边的裙顶点

	var edge_ab := dyadic_edge(A, B, N)
	var edge_ac := dyadic_edge(A, C, N)
	var edge_bc := dyadic_edge(B, C, N)

	var pos := PackedFloat32Array()
	pos.resize(total_count * 3)
	var nor := PackedFloat32Array()
	nor.resize(total_count * 3)
	var col := PackedFloat32Array()
	col.resize(total_count * 3)

	# ---- 主网格: 已位移位置 d·(R+h·maxH) + 有限差分法线 + h 塞 COLOR.r ----
	for i in range(N + 1):
		for j in range(N + 1 - i):
			var d: Vector3
			if j == 0:
				d = edge_ab[i]
			elif i == 0:
				d = edge_ac[j]
			elif i + j == N:
				d = edge_bc[N - i]
			else:
				var w0: float = float(N - i - j) / N
				var w1: float = float(i) / N
				var w2: float = float(j) / N
				d = (A * w0 + B * w1 + C * w2).normalized()
			var h: float = terrain.height_at(d.x, d.y, d.z)
			var r: float = R + h * max_h
			var n: Vector3 = _finite_diff_normal(terrain, d, h, R, max_h)
			var idx: int = _row_index(i, j, N)
			var k3: int = idx * 3
			pos[k3] = d.x * r
			pos[k3 + 1] = d.y * r
			pos[k3 + 2] = d.z * r
			nor[k3] = n.x
			nor[k3 + 1] = n.y
			nor[k3 + 2] = n.z
			col[k3] = h               # COLOR.r = h (shader 配色/雪线用)
			col[k3 + 1] = 0.0
			col[k3 + 2] = 0.0

	# 三条边的顶点索引(A->B / A->C / B->C)
	var gi_ab := PackedInt32Array()
	var gi_ac := PackedInt32Array()
	var gi_bc := PackedInt32Array()
	for i in range(N + 1):
		gi_ab.append(_row_index(i, 0, N))
	for j in range(N + 1):
		gi_ac.append(_row_index(0, j, N))
	for p in range(N + 1):
		gi_bc.append(_row_index(N - p, p, N))

	# ---- 主三角索引(绕序翻转: 外侧 front, 配合 CULL_BACK)----
	var indices := PackedInt32Array()
	for i in range(N):
		for j in range(N - i):
			var a0 := _row_index(i, j, N)
			var b0 := _row_index(i + 1, j, N)
			var c0 := _row_index(i, j + 1, N)
			indices.append(a0)
			indices.append(c0)
			indices.append(b0)
			if j < N - i - 1:
				var d0 := _row_index(i + 1, j + 1, N)
				indices.append(b0)
				indices.append(c0)
				indices.append(d0)

	# ---- 裙边: 每条边复制一份顶点(同已位移位置/法线/h, alpha=0), shader 径向内缩 u_skirt_depth ----
	# 裙顶点索引: main_count + edge_id*(N+1) + i, edge_id: 0=AB 1=AC 2=BC
	var edges_gi := [gi_ab, gi_ac, gi_bc]
	for e in range(3):
		var base: int = main_count + e * skirt_per_edge
		var gi: PackedInt32Array = edges_gi[e]
		for i in range(skirt_per_edge):
			var src: int = gi[i] * 3
			var dst: int = (base + i) * 3
			pos[dst] = pos[src]
			pos[dst + 1] = pos[src + 1]
			pos[dst + 2] = pos[src + 2]
			nor[dst] = nor[src]
			nor[dst + 1] = nor[src + 1]
			nor[dst + 2] = nor[src + 2]
			col[dst] = col[src]      # 继承 h(裙边的 h 不用, 但保持一致无害)
			col[dst + 1] = 0.0
			col[dst + 2] = 0.0
		# 裙四边形: 面边顶点 e0,e1 + 裙顶点 s0,s1, 两个三角(与主面同绕序, 外侧 front)
		for i in range(N):
			var e0: int = gi[i]
			var e1: int = gi[i + 1]
			var s0: int = base + i
			var s1: int = base + i + 1
			indices.append(e0)
			indices.append(e1)
			indices.append(s1)
			indices.append(e0)
			indices.append(s1)
			indices.append(s0)

	# 索引网格输出
	var verts := PackedVector3Array()
	verts.resize(total_count)
	var vnorms := PackedVector3Array()
	vnorms.resize(total_count)
	var vcols := PackedColorArray()
	vcols.resize(total_count)
	for v in range(total_count):
		var s: int = v * 3
		verts[v] = Vector3(pos[s], pos[s + 1], pos[s + 2])
		vnorms[v] = Vector3(nor[s], nor[s + 1], nor[s + 2])
		vcols[v] = Color(col[s], col[s + 1], col[s + 2], 1.0 if v < main_count else 0.0)
	@warning_ignore("integer_division")
	return {
		"verts": verts,
		"norms": vnorms,
		"cols": vcols,
		"indices": indices,
		"tris": indices.size() / 3,
	}
