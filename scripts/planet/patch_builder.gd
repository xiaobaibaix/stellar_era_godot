# gdlint: disable=variable-name, max-line-length
## patch 几何构建(移植 src/patchgeom.js)。
## 纯几何 + 高度场采样, 无场景树依赖 → 线程安全, 在 WorkerThreadPool 里跑。
##
## 消除 T 型接缝的关键(dyadic + 抽稀吸附):
## 1) 边顶点用递归中点细分生成, 相邻不同层级 patch 的边顶点严格嵌套;
## 2) strides[edge] 表示该边相对粗邻居的抽稀倍率, 把非保留顶点吸附到保留顶点之间
##    的直线上 → 两侧边完全重合, 缝消失。
## 法线用有限差分(反映真实斜率, 同一位置结果一致 → 无着色接缝)。
class_name PatchBuilder
extends RefCounted


@warning_ignore("integer_division")
static func _row_index(i: int, j: int, N: int) -> int:
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


# 把边上"非保留"顶点吸附到保留顶点之间的直线(粗邻居的边线)上
static func snap_edge(gi: PackedInt32Array, stride: int, pos: PackedFloat32Array, nor: PackedFloat32Array, col: PackedFloat32Array, N: int) -> void:
	if stride <= 1:
		return
	for k in range(1, N):
		if k % stride == 0:
			continue
		@warning_ignore("integer_division")
		var lo: int = (k / stride) * stride
		var hi: int = lo + stride
		var t: float = float(k - lo) / float(stride)
		var a: int = gi[k] * 3
		var l: int = gi[lo] * 3
		var h: int = gi[hi] * 3
		var mt: float = 1.0 - t
		for c in range(3):
			pos[a + c] = pos[l + c] * mt + pos[h + c] * t
			col[a + c] = col[l + c] * mt + col[h + c] * t
		var nx: float = nor[l] * mt + nor[h] * t
		var ny: float = nor[l + 1] * mt + nor[h + 1] * t
		var nz: float = nor[l + 2] * mt + nor[h + 2] * t
		var len_sq: float = nx * nx + ny * ny + nz * nz
		var nl: float = 1.0 / sqrt(len_sq) if len_sq > 1e-24 else 1.0
		nor[a] = nx * nl
		nor[a + 1] = ny * nl
		nor[a + 2] = nz * nl


# A,B,C: 单位向量。strides: [sAB, sAC, sBC](默认 [1,1,1])。
static func build_patch_arrays(A: Vector3, B: Vector3, C: Vector3, N: int, R: float, max_h: float, terrain, strides: Array = [1, 1, 1]) -> Dictionary:
	var s_ab: int = int(strides[0])
	var s_ac: int = int(strides[1])
	var s_bc: int = int(strides[2])

	var main_count: int = ((N + 1) * (N + 2)) / 2

	var edge_ab := dyadic_edge(A, B, N)
	var edge_ac := dyadic_edge(A, C, N)
	var edge_bc := dyadic_edge(B, C, N)

	var pos := PackedFloat32Array()
	pos.resize(main_count * 3)
	var nor := PackedFloat32Array()
	nor.resize(main_count * 3)
	var col := PackedFloat32Array()
	col.resize(main_count * 3)

	var EPS: float = 1e-3
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

			var h: float = terrain.height_at(d.x, d.y, d.z)
			var rr: float = R + h * max_h
			pos[k3] = d.x * rr
			pos[k3 + 1] = d.y * rr
			pos[k3 + 2] = d.z * rr
			var cc: Color = terrain.color_for(h, d.x, d.y, d.z)
			col[k3] = cc.r
			col[k3 + 1] = cc.g
			col[k3 + 2] = cc.b

			# 有限差分法线
			var up: Vector3 = Vector3(1.0, 0.0, 0.0) if absf(d.x) <= 0.9 else Vector3(0.0, 1.0, 0.0)
			var t1: Vector3 = d.cross(up).normalized()
			var t2: Vector3 = d.cross(t1).normalized()
			var d1: Vector3 = (d + t1 * EPS).normalized()
			var rr1: float = R + terrain.height_at(d1.x, d1.y, d1.z) * max_h
			var d2: Vector3 = (d + t2 * EPS).normalized()
			var rr2: float = R + terrain.height_at(d2.x, d2.y, d2.z) * max_h
			var ax: float = d1.x * rr1 - pos[k3]
			var ay: float = d1.y * rr1 - pos[k3 + 1]
			var az: float = d1.z * rr1 - pos[k3 + 2]
			var bx: float = d2.x * rr2 - pos[k3]
			var by: float = d2.y * rr2 - pos[k3 + 1]
			var bz: float = d2.z * rr2 - pos[k3 + 2]
			var nx: float = ay * bz - az * by
			var ny: float = az * bx - ax * bz
			var nz: float = ax * by - ay * bx
			var len_sq: float = nx * nx + ny * ny + nz * nz
			var nl: float = 1.0 / sqrt(len_sq) if len_sq > 1e-24 else 1.0
			nx *= nl
			ny *= nl
			nz *= nl
			if nx * d.x + ny * d.y + nz * d.z < 0.0:
				nx = -nx
				ny = -ny
				nz = -nz
			nor[k3] = nx
			nor[k3 + 1] = ny
			nor[k3 + 2] = nz

	# 三条边的顶点索引
	var gi_ab := PackedInt32Array()
	var gi_ac := PackedInt32Array()
	var gi_bc := PackedInt32Array()
	for i in range(N + 1):
		gi_ab.append(_row_index(i, 0, N))   # A->B
	for j in range(N + 1):
		gi_ac.append(_row_index(0, j, N))   # A->C
	for p in range(N + 1):
		gi_bc.append(_row_index(N - p, p, N))  # B->C

	# 缝合
	snap_edge(gi_ab, s_ab, pos, nor, col, N)
	snap_edge(gi_ac, s_ac, pos, nor, col, N)
	snap_edge(gi_bc, s_bc, pos, nor, col, N)

	# 主三角索引(绕序翻转: 从 three.js 迁移过来的原始绕序在 Godot 里被判为 back-facing,
	# 配合 CULL_BACK 会剔除球壳外侧、只显示内壁。反转每个三角形顶点顺序 → 外侧变 front)
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

	# 纯主网格: snap_edge 缝合已消除稳态裂缝; 异步加载过渡由 QNode.select_lod 的
	# "父级兜底"保证(子 patch 未全部就绪前父 patch 始终 visible, 永不露洞) → 无需 skirt。
	# (旧 skirt 沿径向向内深陷最深 R*0.4, 双面渲染下在球内互相穿插成"凸起薄片",
	#  且其法线沿用球面顶点法线而非墙面法线 → 球体内部凹凸不平。Web 端同源故同样缺陷。)
	return {
		"positions": pos,
		"normals": nor,
		"colors": col,
		"indices": indices,
	}
