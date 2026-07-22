# gdlint: disable=variable-name, max-line-length
## GPU 驱动行星(Phase 2)。@tool Node3D。
##
## Phase 1: MultiMesh + patch 纹理 + face-bary 位移(固定全 LOD)。
## Phase 2: LOD 四叉树遍历挪到 GPU compute(lod_traverse.glsl, 经 GpuLodCompositor PRE_OPAQUE 跑),
##          每帧 compute 选叶写 patch 纹理, vertex shader 读(1-帧延迟)→ 近处细分、远处粗。
##          vertex shader 不变(Phase 1 的回报): 仍 texelFetch 面角点 → face-bary 位移。
##
## 数据流:
##   GpuPlanet._process(主线程) → 算 C_const(=maxHeight·vp_h/(2·tan(fov/2))/sseThreshold) + cam_pos →
##     GpuLodCompositor.set_frame_data →
##   compositor PRE_OPAQUE(渲染线程) → lod_traverse.glsl 写 patch 纹理(tex[write]) + 末行 count →
##     绑 material.u_patchTex = tex[read](上一帧) →
##   terrain_gpu.gdshader vertex → texelFetch 面角点 → 位移; id≥count 坍缩。
##
## 与旧 scripts/planet/planet.gd 零耦合: 新文件、新节点, 不 import/不修改旧实现。位移噪声与
## terrain.gdshader / terrain.gd::height_at 逐位一致。
@tool
class_name GpuPlanet
extends Node3D

const PATCH_TEX_SLOTS := 6           # 每 patch 6 texel(设计文档 §8.3 终极布局)
const MAX_PATCHES := 4096            # 与 lod_traverse.glsl / terrain_gpu.gdshader META_ROW 一致
const PATCH_TEX_H := MAX_PATCHES + 1 # patch 纹理高(末行存 count)
const DEFAULT_PATCH_RES := 32        # Phase 2 单叶分辨率/边(四叉树下够用; 越大越平滑越费)
const MM_NODE_NAME := "GpuPatchMM"
const MAX_GPU_LEVEL := 6             # 单遍遍历层数上限(4^6=82k 节点/帧, 可测; level 8=1.75M 太重, 留 Phase 6 ping-pong)
# 用 preload + GDScript.new() 取代 GpuLodCompositor.new() —— 绕开 class_name 注册时序
# (@tool 脚本热重载时偶发 "Nonexistent function 'new' in base 'GDScript'", preload 总能用)。
const _GpuLodCompositor_script := preload("res://scripts/planet/gpu/gpu_lod_compositor.gd")

@export var params: PlanetParams:
	set(v):
		if params != null and params.is_connected("param_changed", _on_param_changed):
			params.disconnect("param_changed", _on_param_changed)
		params = v
		if params != null:
			params.param_changed.connect(_on_param_changed)
		_schedule_rebuild()

## 驱动 LOD 的相机(@tool 编辑器 get_viewport 相机不可靠, 用显式引用)。Phase 2 必填。
@export var camera: Camera3D

## 每叶三角形 patch 边分辨率。
@export_range(8, 64, 1) var patch_resolution: int = DEFAULT_PATCH_RES:
	set(v):
		patch_resolution = v
		_schedule_rebuild()

var _mm: MultiMesh
var _mminst: MultiMeshInstance3D
var _mat: ShaderMaterial
var _patch_tex_fallback: ImageTexture   # 初始绑定 + 无 compositor 时的 fallback(20 面, Phase1 风格)
var _patch_mesh: ArrayMesh
var _mesh_res: int = -1
var _default_params: PlanetParams
var _dirty := false
var _lod_comp: GpuLodCompositor
var _frame: int = 0   # 双缓冲帧计数(GpuPlanet 主线程拥有; 决定 compositor 写哪块、绑哪块)


func _ready() -> void:
	_build_all()
	_push_params()
	_setup_lod_compositor()
	_bake_and_push_minmax()


func _exit_tree() -> void:
	# 摘掉 compositor(避免旧 WorldEnvironment 残留 effect 空跑)
	if _lod_comp != null:
		var we := _find_world_environment()
		if we != null and we.compositor != null:
			we.compositor.compositor_effects.erase(_lod_comp)
		_lod_comp = null


func _process(_delta: float) -> void:
	# 每帧: 推 LOD 帧数据(含 write_idx + 6 视锥平面)给 compositor + 主线程绑定上一帧写好的纹理。
	if _lod_comp == null or not is_instance_valid(camera) or _mat == null:
		return
	var p: PlanetParams = _effective_params()
	var write_idx: int = _frame & 1
	var vp := camera.get_viewport()
	var vp_h: float = float(vp.size.y) if vp != null else 1080.0
	var fov_rad: float = deg_to_rad(camera.fov)
	var k: float = vp_h / (2.0 * tan(fov_rad * 0.5))
	var c_const: float = p.maxHeight * k / max(p.sseThresholdPixels, 0.001)
	# 6 视锥平面(world-space, Godot 内向法线约定)。Camera3D.get_frustum 返回顺序:
	# near, far, left, top, right, bottom(本项不依赖顺序, shader 全 6 平面测一遍)。
	var frustum: Array = camera.get_frustum() if camera.is_inside_tree() else []
	_lod_comp.set_frame_data({
		"cam_pos": camera.global_position,
		"planet_center": global_position,
		"radius": p.radius,
		"maxHeight": p.maxHeight,
		"C_const": c_const,
		"maxLevel": min(p.maxLevel, MAX_GPU_LEVEL),
		"write_idx": write_idx,
		"frustum": frustum,
	})
	# minmax 未就绪时 cull 被跳过 → cull_tex 全 0 → vertex 坍缩无渲染(灰屏);
	# 此时保持绑 fallback(20 面 Phase-1 风格), 让用户看到东西而不是空屏。
	# 一旦 set_minmax 成功(下帧起), cull 写出有效 count, 切到 cull_tex 真正的 GPU LOD。
	if _lod_comp.is_minmax_ready():
		_mat.set_shader_parameter("u_patchTex", _lod_comp.get_read_texture(write_idx))
		if _frame == 1:
			print("[GpuPlanet] minmax ready → bind cull_tex (GPU LOD active)")
	else:
		_mat.set_shader_parameter("u_patchTex", _patch_tex_fallback)
		if _frame == 1:
			print("[GpuPlanet] minmax NOT ready → bind fallback (20 面). 检查 set_minmax 是否失败")
	_frame += 1


# 烘 MinMax(首次 + param 变时)→ compositor.set_minmax。
func _bake_and_push_minmax() -> void:
	if _lod_comp == null:
		print("[GpuPlanet] _bake_and_push_minmax: _lod_comp is null(set_minmax 跳过)")
		return
	var p: PlanetParams = _effective_params()
	var data: GpuMinMaxData = HeightmapBaker.bake_or_load(p, GpuLodCompositor.BAKE_RES)
	print("[GpuPlanet] bake 完成: bake_res=%d face_count=%d" % [data.bake_res, GpuIco.FACE_COUNT])
	if not _lod_comp.set_minmax(data):
		push_warning("[GpuPlanet] MinMax 上传失败(占位 fallback; LOD 不裁剪)")
		print("[GpuPlanet] set_minmax FAILED → cull 不会跑, 会用 fallback 渲染")
	else:
		print("[GpuPlanet] set_minmax OK → 下帧起 cull 跑, GPU LOD 激活")


func _on_param_changed(_key: String) -> void:
	_push_params()
	# 影响高度的参数变 → 重烘 MinMax(种子/频率/振幅类; 半径/海平面等不影响 MinMax, 但 bake_or_load
	# 走 seed_hash 缓存命中, 重复烘很快, 为简化统一触发)。
	_bake_and_push_minmax()


func _schedule_rebuild() -> void:
	if _dirty:
		return
	_dirty = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_dirty = false
	_build_all()
	_push_params()


func _build_all() -> void:
	if _patch_tex_fallback == null:
		_patch_tex_fallback = _build_patch_tex_fallback()
	if _patch_mesh == null or _mesh_res != patch_resolution:
		_patch_mesh = _build_patch_mesh(patch_resolution)
		_mesh_res = patch_resolution
		if _mm != null:
			_mm.mesh = _patch_mesh
	if _mminst != null and not is_instance_valid(_mminst):
		_mminst = null
	if _mminst == null:
		_mminst = get_node_or_null(MM_NODE_NAME)
	if _mminst == null:
		_mminst = MultiMeshInstance3D.new()
		_mminst.name = MM_NODE_NAME
		add_child(_mminst)
		_mminst.owner = null
	if _mm == null:
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.mesh = _patch_mesh
		_mm.instance_count = MAX_PATCHES   # 方案 A: 固定上限, shader 坍缩 id≥count
		for i in range(MAX_PATCHES):
			_mm.set_instance_transform(i, Transform3D.IDENTITY)
		_mminst.multimesh = _mm
	if _mat == null:
		var sh: Shader = load("res://shaders/planet_gpu/terrain_gpu.gdshader")
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mminst.material_override = _mat


func _push_params() -> void:
	if _mat == null:
		return
	var p: PlanetParams = _effective_params()
	_mat.set_shader_parameter("u_radius", p.radius)
	_mat.set_shader_parameter("u_max_height", p.maxHeight)
	_mat.set_shader_parameter("u_sea", p.seaLevel)
	_mat.set_shader_parameter("u_warp", p.warpStrength)
	_mat.set_shader_parameter("u_warp_freq", p.warpFreq)
	_mat.set_shader_parameter("u_cont_freq", p.continentFreq)
	_mat.set_shader_parameter("u_cont_oct", p.continentOctaves)
	_mat.set_shader_parameter("u_cont_gain", p.continentGain)
	_mat.set_shader_parameter("u_cont_lac", p.continentLacunarity)
	_mat.set_shader_parameter("u_mtn_freq", p.mountainFreq)
	_mat.set_shader_parameter("u_mtn_oct", p.mountainOctaves)
	_mat.set_shader_parameter("u_mtn_strength", p.mountainStrength)
	_mat.set_shader_parameter("u_plate", p.plateStrength)
	_mat.set_shader_parameter("u_plate_freq", p.plateFreq)
	_mat.set_shader_parameter("u_moist_freq", p.moistureFreq)
	_mat.set_shader_parameter("u_alt_range", p.climateAltRange)
	_mat.set_shader_parameter("u_use_climate", 1.0 if p.useClimate else 0.0)
	_mat.set_shader_parameter("u_off_warp", Terrain.off(p.warpSeed))
	_mat.set_shader_parameter("u_off_cont", Terrain.off(p.continentSeed))
	_mat.set_shader_parameter("u_off_mtn", Terrain.off(p.mountainSeed))
	_mat.set_shader_parameter("u_off_plate", Terrain.off(p.plateSeed))
	_mat.set_shader_parameter("u_off_moist", Terrain.off(p.moistureSeed))
	# 初始/fallback 绑定; compositor 运行后每帧覆盖 u_patchTex 为 GPU 写的纹理。
	_mat.set_shader_parameter("u_patchTex", _patch_tex_fallback)
	var r_extent: float = p.radius + p.maxHeight * 1.2 + 1.0
	_mminst.custom_aabb = AABB(Vector3(-r_extent, -r_extent, -r_extent), Vector3(2.0 * r_extent, 2.0 * r_extent, 2.0 * r_extent))


func _effective_params() -> PlanetParams:
	if params != null:
		return params
	if _default_params == null:
		_default_params = PlanetParams.new()
	return _default_params


# ---- LOD compositor 接线: 找场景 WorldEnvironment, 建 GpuLodCompositor 挂其 compositor.effects ----
func _setup_lod_compositor() -> void:
	if _lod_comp != null:
		return
	if _mat == null:
		return
	var we: WorldEnvironment = _find_world_environment()
	if we == null:
		push_warning("[GpuPlanet] 场景无 WorldEnvironment, GPU LOD 不生效(用 fallback 20 面渲染)")
		return
	var comp: Compositor = we.compositor
	if comp == null:
		comp = Compositor.new()
		we.compositor = comp
	_lod_comp = (_GpuLodCompositor_script as GDScript).new() as GpuLodCompositor
	if not _lod_comp.setup(_mat.get_rid()):
		push_error("[GpuPlanet] GpuLodCompositor.setup 失败(compute shader 编译错误?)")
		_lod_comp = null
		return
	# 重新赋值整个数组(而非 in-place append)→ 触发 Compositor 属性 setter → 重新注册 effects 到渲染服务器。
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	effs.append(_lod_comp)
	comp.compositor_effects = effs


func _find_world_environment() -> WorldEnvironment:
	var root := get_tree().root if is_inside_tree() else null
	if root == null:
		return null
	return _scan_world_environment(root)


func _scan_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r: WorldEnvironment = _scan_world_environment(c)
		if r != null:
			return r
	return null


# ---- fallback patch 纹理: 6×(MAX_PATCHES+1), 前 20 行填面角点, 末行 count=20 ----
# 用途: ① 首帧/compositor 未跑时绑定(避免 u_patchTex 空); ② 无 camera/compositor 时 Phase1 风格渲染。
static func _build_patch_tex_fallback() -> ImageTexture:
	var W: int = PATCH_TEX_SLOTS
	var H: int = PATCH_TEX_H
	var floats := PackedFloat32Array()
	floats.resize(W * H * 4)
	floats.fill(0.0)
	for fi in range(GpuIco.FACE_COUNT):
		var corners: Array = GpuIco.face_corners(fi)
		var A: Vector3 = corners[0]
		var B: Vector3 = corners[1]
		var C: Vector3 = corners[2]
		var b: int = fi * W * 4
		floats[b + 0] = A.x; floats[b + 1] = A.y; floats[b + 2] = A.z; floats[b + 3] = float(fi)
		floats[b + 4] = B.x; floats[b + 5] = B.y; floats[b + 6] = B.z; floats[b + 7] = 0.0
		floats[b + 8] = C.x; floats[b + 9] = C.y; floats[b + 10] = C.z; floats[b + 11] = 0.0
	# 末行 metadata: count = 20(渲染前 20 个 instance = 20 面)
	var mb: int = MAX_PATCHES * W * 4
	floats[mb + 0] = float(GpuIco.FACE_COUNT)
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBAF, floats.to_byte_array())
	return ImageTexture.create_from_image(img)


# ---- 共享三角形 patch 网格: n 细分, 顶点 (i,j) i+j<=n, uv=(i/n, j/n) ----
static func _build_patch_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var idmap: Dictionary = {}
	for j in range(n + 1):
		for i in range(n + 1):
			if i + j <= n:
				idmap[Vector2i(i, j)] = verts.size()
				var u: float = float(i) / float(n)
				var v: float = float(j) / float(n)
				verts.append(Vector3(u, v, 0.0))
				uvs.append(Vector2(u, v))
	for j in range(n):
		for i in range(n):
			if i + j <= n - 1:
				idx.append(idmap[Vector2i(i, j)])
				idx.append(idmap[Vector2i(i + 1, j)])
				idx.append(idmap[Vector2i(i, j + 1)])
				if i + j <= n - 2:
					idx.append(idmap[Vector2i(i + 1, j)])
					idx.append(idmap[Vector2i(i + 1, j + 1)])
					idx.append(idmap[Vector2i(i, j + 1)])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
