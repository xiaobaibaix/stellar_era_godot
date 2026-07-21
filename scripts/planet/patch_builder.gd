# gdlint: disable=variable-name, max-line-length, unused_parameter
## patch 几何构建(Phase 1+ : GPU 位移版)。
## 铺【理想球面网格】(d·R, 未位移) + 【裙边】(同方向、alpha=0 标记); 地形位移/法线/配色全在 shaders/terrain.gdshader。
##
## 裙边盖 LOD 裂缝: 相邻不同层级 patch 的边顶点不嵌套时, 细 patch 边缘挂一圈径向内缩的裙,
## 遮住高低层级间的缝。shader 里 COLOR.a<0.5 的顶点 = 裙边, 径向内缩 u_skirt_depth。
## → strides 恒 [1,1,1], 不再需要 compute_strides/target_level_at(主线程热点)。
class_name PatchBuilder
extends RefCounted


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


# A,B,C: 单位向量。strides 现恒 [1,1,1](裙边缝合), max_h/terrain 保留签名兼容(已不用)。
static func build_patch_arrays(A: Vector3, B: Vector3, C: Vector3, N: int, R: float, _max_h: float, _terrain, _strides: Array = [1, 1, 1]) -> Dictionary:
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

	# ---- 主网格: 理想球面位置 d·R(平)。nor=d 占位, col=1(alpha=1=面)。----
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
			var idx: int = _row_index(i, j, N)
			var k3: int = idx * 3
			pos[k3] = d.x * R
			pos[k3 + 1] = d.y * R
			pos[k3 + 2] = d.z * R
			nor[k3] = d.x
			nor[k3 + 1] = d.y
			nor[k3 + 2] = d.z
			col[k3] = 1.0
			col[k3 + 1] = 1.0
			col[k3 + 2] = 1.0

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

	# ---- 裙边: 每条边复制一份顶点(同位置 d·R, alpha=0), shader 径向内缩 u_skirt_depth ----
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
			col[dst] = 1.0
			col[dst + 1] = 1.0
			col[dst + 2] = 0.0      # alpha=0 → shader 判为裙边
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
