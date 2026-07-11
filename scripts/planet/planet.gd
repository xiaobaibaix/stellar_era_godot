# gdlint: disable=variable-name, max-line-length
## 行星: 正二十面体 + 三角形四叉树 LOD + fBm 噪声位移(移植 src/planet.js)。
## patch 网格在 WorkerThreadPool 异步生成; skirt 仅作加载过渡兜底。
## 容器架构: 每片 patch = 一个 qnode.tscn 实例(Qnode 容器 + 子 MeshInstance3D),
## 代码只填充子 MeshInstance3D 的 mesh 资源; 所有 Qnode 挂 BodyMesh 下。
## @tool: 让编辑器 3D 视口也能渲染, 并跟随编辑器相机做 LOD 细分。
@tool
class_name Planet
extends Node3D

@export var params: PlanetParams
## 显式指定驱动 LOD 的相机(场景里把 Camera3D 拖给 Planet)。
## @tool 下 get_viewport().get_camera_3d() 在编辑器不可靠, 用显式引用统一编辑器/运行时。
@export var camera: Camera3D
var terrain: Terrain
var roots: Array = []  # Array[QNode]
var _V: Array = []  # 12 个单位顶点(Vector3)
var _faces: Array = []  # 20 个 [i,j,k]
var material: StandardMaterial3D
var stats: Dictionary = {"patches": 0, "triangles": 0, "inflight": 0}

var _gen: int = 0
var _pool: PatchWorkerPool
var _pending: int = 0
var _jobs: Dictionary = {}  # job_id -> QNode: worker 回调据此找回节点(节点可能已被 queue_free)
var _next_job: int = 0
var _cam_pos: Vector3 = Vector3(1e9, 1e9, 1e9)
var _cam_moved: bool = true
var _wire: bool = false
var _body_mesh: Node3D  # 所有 Qnode 的容器节点(BodyMesh)
var _qnode_scene: PackedScene  # qnode.tscn 预制体


# 作为预制体节点: 进树即自动构建; _process 自动取场景活动相机驱动 LOD。
# 相机/灯/环境由外部场景(如 main)提供, 本节点只负责行星本身。
func _ready() -> void:
	_diag_start()
	if params == null:
		params = PlanetParams.new()
	# @tool 下场景内嵌的 params(planet.tscn 里 type=Resource + script 子资源)脚本绑定不稳定:
	# 直接属性式访问 params.param_changed 会抛 "Invalid access to property 'param_changed'",
	# 中断 _ready -> 不建根 -> 编辑器视口无球。先 has_signal 探测: 无信号则换成有效实例;
	# 有信号改用字符串名 connect(避开属性式 Signal 访问的 @tool 时序问题)。
	if not params.has_signal("param_changed"):
		params = PlanetParams.new()
	if not params.is_connected("param_changed", _on_param_changed):
		params.connect("param_changed", _on_param_changed)
	if _pool == null:
		_pool = PatchWorkerPool.instance()
	if _qnode_scene == null:
		_qnode_scene = load("res://scenes/qnode.tscn")
	if _body_mesh == null:
		# 优先用场景里手动建的 BodyMesh(编辑器可见); 没有则代码建一个(internal)
		_body_mesh = get_node_or_null("BodyMesh")
		if _body_mesh == null:
			_body_mesh = Node3D.new()
			_body_mesh.name = "BodyMesh"
			add_child(_body_mesh, false, Node.INTERNAL_MODE_BACK)
	if material == null:
		material = StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.albedo_color = Color.WHITE
		material.roughness = 0.9
		material.cull_mode = BaseMaterial3D.CULL_BACK  # 封闭球壳剔除背面(对齐 web three.js FrontSide)。勿用 CULL_DISABLED: 双面渲染下 Godot 对 back-facing 三角形翻转法线做光照, 绕序被判背面时外侧亮区会反转。
	if roots.is_empty():
		_build_noise()
		_build_roots()
	_log_ready()


func _process(_delta: float) -> void:
	# 优先用 @export 指定的相机(场景里拖给 Planet, 编辑器/运行时统一);
	# 未指定则回退到视口活动相机。
	var cam: Camera3D = camera
	if cam == null:
		var vp := get_viewport()
		cam = vp.get_camera_3d() if vp != null else null
	if cam != null:
		update(cam)


func _diag_start() -> void:
	var f := FileAccess.open("user://planet_ready.txt", FileAccess.WRITE)
	if f:
		f.store_line("start editor=%s" % Engine.is_editor_hint())
		f.close()


func _log_ready() -> void:
	var f := FileAccess.open("user://planet_ready.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://planet_ready.txt", FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line("roots=%d body=%s mat=%s" % [roots.size(), _body_mesh != null, material != null])
		if not roots.is_empty():
			var r0 = roots[0]
			f.store_line("r0 mesh=%s vis=%s" % [r0.mesh_inst.mesh != null, r0.mesh_inst.visible])
		f.close()


func _on_param_changed(key: String) -> void:
	match key:
		"wireframe":
			set_wireframe(params.wireframe)
	if params.requires_rebuild(key):
		rebuild()


func _build_noise() -> void:
	terrain = Terrain.from_params(params)


func height_at(x: float, y: float, z: float) -> float:
	return terrain.height_at(x, y, z)


# ---- 正二十面体根 ----
func _build_roots() -> void:
	var t: float = (1.0 + sqrt(5.0)) / 2.0
	var raw := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	_V = []
	for v in raw:
		_V.append(v.normalized())
	_faces = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	roots = []
	var ri := 0
	for f in _faces:
		var r: QNode = _qnode_scene.instantiate()
		r.name = "Qnode%d" % (ri + 1)  # 根: Qnode1..Qnode20
		_body_mesh.add_child(r)  # 普通 add_child: 场景树显示原名(不带 @)
		r.set_owner(null)  # 防 @tool 编辑器把运行时节点写进场景文件
		r.setup(self, _V[f[0]], _V[f[1]], _V[f[2]], 0, _qnode_scene)
		var data := PatchBuilder.build_patch_arrays(
			r.A, r.B, r.C, params.patchResolution, params.radius,
			params.maxHeight, terrain, [1, 1, 1])
		r.set_mesh(_gen_array_mesh(data), int(data.indices.size() / 3))
		r.mesh_inst.visible = true  # 根 patch 默认可见(基础球壳); select_lod 运行后接管细分/剔除
		r.built_key = "1,1,1"
		roots.append(r)
		ri += 1


func _root_containing(p: Vector3) -> Array:
	for f in _faces:
		var a: Vector3 = _V[f[0]]
		var b: Vector3 = _V[f[1]]
		var c: Vector3 = _V[f[2]]
		if point_in_tri(p, a, b, c):
			return [a, b, c]
	var f0: Array = _faces[0]
	return [_V[f0[0]], _V[f0[1]], _V[f0[2]]]


# 邻居目标层级查询(纯几何, 与四叉树分裂规则一致)
func target_level_at(p: Vector3) -> int:
	var R: float = params.radius
	var sf: float = params.splitFactor
	var max_l: int = params.maxLevel
	var cam: Vector3 = _cam_pos
	var tri := _root_containing(p)
	var A: Vector3 = tri[0]
	var B: Vector3 = tri[1]
	var C: Vector3 = tri[2]
	var level: int = 0
	while level < max_l:
		var center := (A + B + C).normalized()
		var cw: Vector3 = center * R
		var edge_len: float = A.distance_to(B) * R
		var dcam: float = cam.distance_to(cw)
		if dcam < edge_len * sf:
			var ab := (A + B).normalized()
			var bc := (B + C).normalized()
			var ca := (C + A).normalized()
			var ch := [[A, ab, ca], [ab, B, bc], [ca, bc, C], [ab, bc, ca]]
			var nxt: Array = ch[3]
			for tt in ch:
				if point_in_tri(p, tt[0], tt[1], tt[2]):
					nxt = tt
					break
			A = nxt[0]
			B = nxt[1]
			C = nxt[2]
			level += 1
		else:
			break
	return level


# ---- 网格 ----
# worker 输出扁平 PackedFloat32Array(xyz 交错, 与 three.js BufferGeometry 对齐);
# Godot 的 ArrayMesh 需要 PackedVector3Array / PackedColorArray, 主线程转换
# (patch 顶点 ~160, 开销可忽略)。只生成 ArrayMesh 资源, 由 QNode.set_mesh 填进去。
func _gen_array_mesh(data: Dictionary) -> ArrayMesh:
	var positions: PackedFloat32Array = data.positions
	var normals: PackedFloat32Array = data.normals
	var colors: PackedFloat32Array = data.colors
	var indices: PackedInt32Array = data.indices
	var vcount: int = positions.size() / 3
	var verts := PackedVector3Array()
	verts.resize(vcount)
	var norms := PackedVector3Array()
	norms.resize(vcount)
	var cols := PackedColorArray()
	cols.resize(vcount)
	for i in range(vcount):
		var j: int = i * 3
		verts[i] = Vector3(positions[j], positions[j + 1], positions[j + 2])
		norms[i] = Vector3(normals[j], normals[j + 1], normals[j + 2])
		cols[i] = Color(colors[j], colors[j + 1], colors[j + 2])
	var am := ArrayMesh.new()
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = verts
	surf[Mesh.ARRAY_NORMAL] = norms
	surf[Mesh.ARRAY_COLOR] = cols
	surf[Mesh.ARRAY_INDEX] = indices
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)
	return am


# ---- Worker 请求调度 ----
func request_mesh(node: QNode, strides: Array, key: String) -> void:
	if node.pending:
		return
	if node.mesh_inst.mesh != null and node.built_key == key:
		return
	node.pending = true
	node.cancelled = false
	node.req_key = key
	_pending += 1
	_next_job += 1
	var job_id := _next_job
	_jobs[job_id] = node  # 回调时据此找回节点
	var msg := {
		"A": node.A, "B": node.B, "C": node.C,
		"N": params.patchResolution, "R": params.radius,
		"maxHeight": params.maxHeight,
		"strides": strides, "terrain": _terrain_dict(),
	}
	var gen := _gen
	_pool.submit(msg, func(result: Dictionary) -> void: _on_mesh_job(job_id, result), gen)


func _on_mesh_job(job_id: int, data: Dictionary) -> void:
	# 先取 Variant 再校验: 直接赋给 typed var 时, 若 _jobs 里是已 queue_free 的节点,
	# Godot 在赋值阶段就报 "assign invalid previously freed instance"(is_instance_valid 没机会跑)。
	var raw: Variant = _jobs.get(job_id, null)
	_jobs.erase(job_id)
	_pending -= 1
	if raw == null or not is_instance_valid(raw):
		return
	var node: QNode = raw
	node.pending = false
	if not node.cancelled and int(data.gen) == _gen:
		var was_visible := node.mesh_inst.visible
		node.set_mesh(_gen_array_mesh(data), int(data.indices.size() / 3))
		node.mesh_inst.visible = was_visible
		node.built_key = node.req_key


func count_node(node: QNode) -> void:
	stats.patches += 1
	if node.mesh_inst.mesh != null:
		stats.triangles += int(node.mesh_inst.get_meta("triangles", 0))


func update(cam: Camera3D) -> void:
	var cp: Vector3 = cam.global_position - global_position
	_cam_moved = cp.distance_squared_to(_cam_pos) > 1e-6
	_cam_pos = cp
	var frustum: Array = cam.get_frustum()
	stats.patches = 0
	stats.triangles = 0
	for r in roots:
		r.select_lod(cp, frustum, _cam_moved)
	stats.inflight = _pending


func rebuild() -> void:
	_gen += 1
	_pending = 0
	_jobs.clear()  # 丢弃所有 pending job(回调时 is_instance_valid 也会拦)
	for r in roots:
		r.dispose()
		r.queue_free()
	roots.clear()
	_cam_moved = true
	_cam_pos = Vector3(1e9, 1e9, 1e9)
	_build_noise()
	_build_roots()
	if _wire:
		set_wireframe(true)


func set_wireframe(on: bool) -> void:
	_wire = on
	material.wireframe = on


# 地形参数快照(传给 worker 线程, 避免跨线程读 PlanetParams)
func _terrain_dict() -> Dictionary:
	var p := params
	return {
		"seaLevel": p.seaLevel,
		"continentSeed": p.continentSeed, "continentFreq": p.continentFreq,
		"continentOctaves": p.continentOctaves, "continentGain": p.continentGain,
		"continentLacunarity": p.continentLacunarity,
		"mountainSeed": p.mountainSeed, "mountainFreq": p.mountainFreq,
		"mountainOctaves": p.mountainOctaves, "mountainStrength": p.mountainStrength,
		"warpSeed": p.warpSeed, "warpStrength": p.warpStrength, "warpFreq": p.warpFreq,
		"plateSeed": p.plateSeed, "plateFreq": p.plateFreq, "plateStrength": p.plateStrength,
		"moistureSeed": p.moistureSeed, "moistureFreq": p.moistureFreq,
		"useClimate": p.useClimate, "climateAltRange": p.climateAltRange,
	}


# ---- 球面几何辅助(移植 planet.js) ----
static func point_in_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var n_ab := a.cross(b)
	if p.dot(n_ab) * c.dot(n_ab) < -1e-7:
		return false
	var n_bc := b.cross(c)
	if p.dot(n_bc) * a.dot(n_bc) < -1e-7:
		return false
	var n_ca := c.cross(a)
	if p.dot(n_ca) * b.dot(n_ca) < -1e-7:
		return false
	return true
