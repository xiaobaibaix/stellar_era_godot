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
const MAX_PATCHES := 12288           # 与 lod_traverse.glsl / terrain_gpu.gdshader META_ROW 一致(PATCH_TEX_H=12289, 留 Metal 单边 16384 上限余量)
const PATCH_TEX_H := MAX_PATCHES + 1 # patch 纹理高(末行存 count)
const DEFAULT_PATCH_RES := 32        # Phase 2 单叶分辨率/边(四叉树下够用; 越大越平滑越费)
const MM_NODE_NAME := "GpuPatchMM"
const MAX_GPU_LEVEL := 6             # 单遍遍历层数上限(4^6=82k 节点/帧, 可测; level 8=1.75M 太重, 留 Phase 6 ping-pong)
# 用 preload + GDScript.new() 取代 GpuLodCompositor.new() —— 绕开 class_name 注册时序
# (@tool 脚本热重载时偶发 "Nonexistent function 'new' in base 'GDScript'", preload 总能用)。
const _GpuLodCompositor_script := preload("res://scripts/planet/gpu_lod_compositor.gd")
const _GpuHizCompositor_script := preload("res://scripts/planet/gpu_hiz_compositor.gd")

@export var params: PlanetParams:
	set(v):
		if params == v:
			return
		# 用 Object 的字符串版 has_signal/connect/disconnect, 避开 params.param_changed 属性访问。
		# 加载 / @tool 热重载瞬间, PlanetParams 脚本的信号表可能尚未就绪, 直接点 .param_changed
		# 属性会抛 "Invalid access to property or key 'param_changed'"; 字符串版走 Object 接口, 安全。
		if params != null and params.has_signal("param_changed") and params.is_connected("param_changed", _on_param_changed):
			params.disconnect("param_changed", _on_param_changed)
		params = v
		_connect_params_signal()
		_schedule_rebuild()


# 连接 params.param_changed → _on_param_changed(幂等; setter 与 _ready 兜底共用)。
# 用字符串版接口 + has_signal 门槛, 规避加载瞬间信号表未就绪的属性访问崩溃。
func _connect_params_signal() -> void:
	if params != null and params.has_signal("param_changed") and not params.is_connected("param_changed", _on_param_changed):
		params.connect("param_changed", _on_param_changed)

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
var _hiz_comp: GpuHizCompositor   # Phase 5: 遮挡剔除深度金字塔(POST_OPAQUE)
# Phase 5: 地平线剔除 occluder 球半径 = radius + 全局最小位移(保证内含实心行星, 安全不误剔)。
# minmax 就绪前用保守下界 radius - maxHeight; 就绪后由 _apply_minmax 更新为更紧的值。
var _occluder_radius: float = 0.0
var _frame: int = 0   # 双缓冲帧计数(GpuPlanet 主线程拥有; 决定 compositor 写哪块、绑哪块)
# 后台烘焙: 20×BAKE_RES² 噪声采样太重(~260 万次 height_at), 放主线程 _ready 会卡死编辑器/运行。
# 改为 WorkerThreadPool 后台跑, 期间 minmax 未就绪 → _process 绑 fallback(20 面)先渲染, 完成后切 GPU LOD。
var _bake_task_id: int = -1
var _bake_result: GpuMinMaxData
var _bake_save_path: String = ""
# LOD 冻结(调试用): 冻结后 _process 用快照的相机位置/参数驱动 LOD, 不再读实时相机。
# 配合旁观相机(planet_lod_debug.gd)绕看冻结后的地形。视锥用空 → cull 全通过 → 整球可见。
var _lod_frozen := false
var _frozen_cam_pos: Vector3
var _frozen_c_const: float = 0.0
var _frozen_frustum: Array = []


func _ready() -> void:
	_connect_params_signal()   # 兜底: 若 setter 在加载瞬间因信号表未就绪跳过了连接, 这里补上
	_build_all()
	_push_params()
	_setup_lod_compositor()
	_bake_and_push_minmax()


func _exit_tree() -> void:
	# 等后台烘焙结束, 避免 worker 线程写入已释放的对象。
	if _bake_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_bake_task_id)
		_bake_task_id = -1
		_bake_result = null
	# 摘掉 compositor(避免旧 WorldEnvironment 残留 effect 空跑)
	if _lod_comp != null or _hiz_comp != null:
		var we := _find_world_environment()
		if we != null and we.compositor != null:
			var effs: Array[CompositorEffect] = we.compositor.compositor_effects.duplicate()
			if _lod_comp != null:
				effs.erase(_lod_comp)
			if _hiz_comp != null:
				effs.erase(_hiz_comp)
			we.compositor.compositor_effects = effs
		_lod_comp = null
		_hiz_comp = null


func _process(_delta: float) -> void:
	# 每帧: 轮询后台烘焙是否完成 → 推 LOD 帧数据 + 绑上一帧写好的纹理。
	_poll_async_bake()
	if _lod_comp == null or not is_instance_valid(camera) or _mat == null:
		return
	var p: PlanetParams = _effective_params()
	var write_idx: int = _frame & 1
	var cam_pos: Vector3
	var c_const: float
	var k_sse: float = 0.0
	var frustum: Array
	# Phase 5 剔除开关: 冻结调试时全关(cull 全通过 → 整球可见, 旁观相机绕看不缺面)。
	var horizon_on: bool = false
	var small_tri_px: float = 0.0
	var occlusion_on: bool = false
	if _lod_frozen:
		# 冻结: 用快照的相机位置/参数; 视锥用空(cull 全通过)→ 整球可见, 旁观相机绕看不缺面。
		cam_pos = _frozen_cam_pos
		c_const = _frozen_c_const
		frustum = _frozen_frustum
	else:
		var vp := camera.get_viewport()
		var vp_h: float = float(vp.size.y) if vp != null else 1080.0
		var fov_rad: float = deg_to_rad(camera.fov)
		k_sse = vp_h / (2.0 * tan(fov_rad * 0.5))
		c_const = p.maxHeight * k_sse / max(p.sseThresholdPixels, 0.001)
		cam_pos = camera.global_position
		# 6 视锥平面(world-space, Godot 内向法线约定)。Camera3D.get_frustum 返回顺序:
		# near, far, left, top, right, bottom(本项不依赖顺序, shader 全 6 平面测一遍)。
		frustum = camera.get_frustum() if camera.is_inside_tree() else []
		horizon_on = p.horizonCulling
		small_tri_px = p.smallTriPixels
		occlusion_on = p.occlusionCulling
	# occluder 半径: minmax 就绪后是 radius+全局最小位移(_apply_minmax 设); 否则保守下界 radius-maxHeight。
	var occluder_r: float = _occluder_radius if _occluder_radius > 0.0 else max(p.radius - p.maxHeight, 1.0)
	_lod_comp.set_frame_data({
		"cam_pos": cam_pos,
		"planet_center": global_position,
		"radius": p.radius,
		"maxHeight": p.maxHeight,
		"C_const": c_const,
		"K": k_sse,
		"maxLevel": min(p.maxLevel, MAX_GPU_LEVEL),
		"write_idx": write_idx,
		"frustum": frustum,
		"horizonCulling": horizon_on,
		"horizonOccluderRadius": occluder_r,
		"smallTriPixels": small_tri_px,
		"occlusionCulling": occlusion_on,
	})
	# Phase 5: 驱动 Hi-Z compositor(遮挡关 / 冻结时不建金字塔, 零开销)。
	if _hiz_comp != null:
		_hiz_comp.set_active(occlusion_on)
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


# ---- LOD 冻结接口(供 planet_lod_debug.gd 调; 调试用) ----
# 冻结: 快照当前相机位置/C_const, 之后 _process 用快照驱动 LOD; 视锥置空 → cull 全通过 →
# 整球在冻结后仍全部渲染, 旁观相机可绕到任意角度看清 patch 结构, 不会因旧视锥裁剪而缺面。
func freeze_lod() -> void:
	if not is_instance_valid(camera):
		return
	var p: PlanetParams = _effective_params()
	var vp := camera.get_viewport()
	var vp_h: float = float(vp.size.y) if vp != null else 1080.0
	var fov_rad: float = deg_to_rad(camera.fov)
	var k: float = vp_h / (2.0 * tan(fov_rad * 0.5))
	_frozen_c_const = p.maxHeight * k / max(p.sseThresholdPixels, 0.001)
	_frozen_cam_pos = camera.global_position
	_frozen_frustum = []   # 空视锥 → 不裁剪 → 整球可见
	_lod_frozen = true


func unfreeze_lod() -> void:
	_lod_frozen = false


func is_lod_frozen() -> bool:
	return _lod_frozen


# 切换单遍着色器线框(F1 用)。不走 DEBUG_DRAW_WIREFRAME(那会额外 line pass, 12288 instance 爆帧)。
func set_wireframe(on: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter("u_wireframe", on)


# 烘 MinMax(首次 + param 变时)。命中缓存 → 主线程直接 load; 未命中 → 后台线程烘焙, 不阻塞。
func _bake_and_push_minmax() -> void:
	if _lod_comp == null:
		return
	var p: PlanetParams = _effective_params()
	var sh: int = HeightmapBaker.compute_seed_hash(p)
	var path: String = HeightmapBaker.default_path(sh, GpuLodCompositor.BAKE_RES)
	# 命中缓存 → 主线程直接 load(快, 无需烘焙), 立即应用。
	if ResourceLoader.exists(path):
		var cached: Resource = load(path)
		if cached is GpuMinMaxData:
			print("[GpuPlanet] MinMax 缓存命中 → 直接加载, GPU LOD 立即激活")
			_apply_minmax(cached as GpuMinMaxData)
			return
	# 未命中 → 后台线程烘焙(避免主线程/编辑器卡死); 期间用 fallback 20 面渲染。
	if _bake_task_id != -1:
		return   # 已有烘焙在跑, 不重复提交
	_bake_save_path = path
	_bake_result = null
	_bake_task_id = WorkerThreadPool.add_task(_bake_task.bind(p), false, "planet minmax bake")
	print("[GpuPlanet] MinMax 缓存未命中 → 后台烘焙中(先用 20 面 fallback, 烘完自动切 GPU LOD)")


# 后台线程体: 纯 CPU 噪声采样, 不碰 RenderingDevice / 场景树。结果由主线程 _poll_async_bake 取走。
func _bake_task(p: PlanetParams) -> void:
	_bake_result = HeightmapBaker.bake(p, GpuLodCompositor.BAKE_RES)


# 主线程每帧轮询: 后台烘焙完成 → 存盘缓存(下次秒开) + 上传 GPU。
func _poll_async_bake() -> void:
	if _bake_task_id == -1 or not WorkerThreadPool.is_task_completed(_bake_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_bake_task_id)   # 已完成, 立即返回; 提供内存屏障
	var data: GpuMinMaxData = _bake_result
	_bake_task_id = -1
	_bake_result = null
	if data == null:
		return
	# 存盘: 下次启动 _bake_and_push_minmax 命中缓存, 直接 load 跳过烘焙。
	if _bake_save_path != "":
		var dir_path: String = _bake_save_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir_path):
			DirAccess.make_dir_recursive_absolute(dir_path)
		var err: Error = ResourceSaver.save(data, _bake_save_path)
		if err != OK:
			push_warning("[GpuPlanet] MinMax 缓存存盘失败 %s: %d" % [_bake_save_path, err])
	print("[GpuPlanet] 后台烘焙完成: bake_res=%d → 上传 GPU" % data.bake_res)
	_apply_minmax(data)


# 上传烘焙数据到 compositor(缓存命中 / 后台烘焙完成 共用)。
func _apply_minmax(data: GpuMinMaxData) -> void:
	if _lod_comp == null:
		return
	# Phase 5: 用烘焙的全局最小位移算地平线 occluder 球半径(内含实心行星 → 安全)。
	var p: PlanetParams = _effective_params()
	_occluder_radius = p.radius + data.global_min_disp()
	if not _lod_comp.set_minmax(data):
		push_warning("[GpuPlanet] MinMax 上传失败(占位 fallback; LOD 不裁剪)")
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
		var sh: Shader = load("res://shaders/planet/terrain_gpu.gdshader")
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mminst.material_override = _mat


func _push_params() -> void:
	if _mat == null:
		return
	var p: PlanetParams = _effective_params()
	_mat.set_shader_parameter("u_radius", p.radius)
	_mat.set_shader_parameter("u_max_height", p.maxHeight)
	_mat.set_shader_parameter("u_patch_res", float(patch_resolution))   # Phase 4: 边检测 tol 用
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
	# Phase 5: Hi-Z 遮挡剔除 compositor(POST_OPAQUE 建深度金字塔)。接线给 lod_comp 供 PRE_OPAQUE 读。
	# 编译失败不致命 —— 降级到无遮挡剔除(lod_comp 读不到金字塔 → hiz_ready=0 → 跳过遮挡测试)。
	_hiz_comp = (_GpuHizCompositor_script as GDScript).new() as GpuHizCompositor
	_lod_comp.set_hiz_provider(_hiz_comp)
	# 重新赋值整个数组(而非 in-place append)→ 触发 Compositor 属性 setter → 重新注册 effects 到渲染服务器。
	# 顺序: lod_comp(PRE_OPAQUE) 在前, hiz_comp(POST_OPAQUE) 在后 —— 回调按 pass 时机触发, 顺序无碍。
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	effs.append(_lod_comp)
	effs.append(_hiz_comp)
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
		# texel3/4: 根面的 face-bary(A=(0,0), B=(1,0), C=(0,1))。shader 改用 face_dir_from_bary 后,
		# fallback 也必须带 bary, 否则 fb 全 0 → 所有顶点坍到 V0 → 20 面退化。
		floats[b + 12] = 0.0; floats[b + 13] = 0.0; floats[b + 14] = 1.0; floats[b + 15] = 0.0
		floats[b + 16] = 0.0; floats[b + 17] = 1.0; floats[b + 18] = 0.0; floats[b + 19] = 0.0
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
