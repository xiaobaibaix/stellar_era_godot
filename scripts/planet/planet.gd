# gdlint: disable=variable-name, max-line-length
## 行星: 正二十面体 + 三角形四叉树 LOD + fBm 噪声位移(移植 src/planet.js)。
## patch 网格在 WorkerThreadPool 异步生成; skirt 仅作加载过渡兜底。
## 渲染架构: 20 个稳定 MeshInstance3D(每个 icosahedron 根面一个, 挂 BodyMesh 下, 永不销毁);
## QNode=RefCounted 纯数据, 每根独立 dirty → 帧末只重建 churn 的根, 每叶一个 surface(本地索引)。
## @tool: 让编辑器 3D 视口也能渲染, 并跟随编辑器相机做 LOD 细分。
@tool
class_name Planet
extends Node3D

@export var params: PlanetParams
## 显式指定驱动 LOD 的相机(场景里把 Camera3D 拖给 Planet)。
## @tool 下 get_viewport().get_camera_3d() 在编辑器不可靠, 用显式引用统一编辑器/运行时。
@export var camera: Camera3D
## LOD 距离判定的聚焦目标(用它的位置算细分距离); 留空则用 camera。
## 跟随角色模式下设为 Player, 让细分围绕角色而非相机; 视锥剔除仍用渲染相机。
@export var lod_target: Node3D
## 太阳光(可选, 单太阳遗留接口; 推荐用 sun_lights 数组):
## - DirectionalLight3D: _update_sun 把它的 -Z 对齐 sun_dir(平行光跟随大气太阳方向)。
## - OmniLight3D: _update_sun 从它的位置反推 sun_dir(点光源位置驱动大气/海洋太阳方向);
##   编辑器里拖动光源, 大气/海洋高光实时跟随(每帧检测位置变化)。
## 两种都让地形光照方向与大气/海洋的 u_sun_dir 一致。
## 注: 若 sun_lights 为空, 此字段会被自动包进 sun_lights[0]; 二者并存时以 sun_lights 为准。
@export var sun_light: Light3D
## 多太阳(可同时挂多个 DirectionalLight3D / OmniLight3D)。大气/海洋/晨昏线对每个太阳各算一次并累加。
## 性能代价: 大气 raymarch 内层 × 太阳数, 4 个太阳 ≈ 4× 单太阳开销。最多 4 个(MAX_SUNS=4)。
@export var sun_lights: Array[Light3D] = []
var terrain: Terrain
var roots: Array = []  # Array[QNode]
var _V: Array = []  # 12 个单位顶点(Vector3)
var _faces: Array = []  # 20 个 [i,j,k]
var material: ShaderMaterial
var _wire_fill_mat: ShaderMaterial  # 线框模式实心遮挡面材质(terrain shader + u_wire_mode=1, 共用位移)
var _wire_line_mat: ShaderMaterial  # 线框模式亮线段材质(terrain shader + u_wire_mode=2)
var stats: Dictionary = {"patches": 0, "triangles": 0, "inflight": 0}
var _tla_cache: Dictionary = {}       # target_level_at 缓存: 量化方向(Vector3i) -> level
var _tla_cache_gen: int = -1          # 缓存所属 generation; _gen 变(rebuild)时清空
# Phase 2 大气壳 + 海洋(球壳 spatial shader)。建为 Planet 子节点(BodyMesh 兄弟)。
var _ocean_mesh: MeshInstance3D
var _ocean_mat: ShaderMaterial
var _ocean_shader: Shader
# CompositorEffect 全屏后处理大气(移植 web 多 pass)。挂到场景 WorldEnvironment.compositor。
# M1: 占位染色 pass 证明管线; M2 起换成真大气/合成/godray compute。
var _atmo_compositor: AtmosphereCompositor
var _atmo_comp_res: Compositor
# 大气球壳(罩住整个行星): 半径 = R*atmoScale 的球壳, 挂 Planet 下随节点移动, 【不】跟随相机。
# 这样编辑器视口相机(不在场景 Camera3D 位置)也能看到大气。depth_test_disabled 下壳覆盖的像素都积分;
# shader 用 depth_texture 处理遮挡 → 相机在壳外(太空)/壳内(地表)都正确(raySphere 算 tNear/tFar,
# 相机在内 tNear=0)。物理大气顶 u_ratmo = R*atmoScale = 壳半径。
var _sun_dir: Vector3 = Vector3(0.739, 0.443, 0.515)   # normalize(1,0.6,0.8) 默认(主太阳; 海洋/地形用)
# 多太阳快照: 每帧 _update_sun 填充, _push_compositor_frame 推给大气 compositor。
# 与 MAX_SUNS=4 对齐(atmosphere_compute.glsl / atmosphere_compositor.gd)。
var _sun_dirs: Array[Vector3] = []
var _sun_positions: Array[Vector3] = []   # 近场点光源: 真实世界位置; 方向光: 任意(不会用)
var _sun_is_locals: Array[float] = []     # 1.0=近场(用 position 反推方向), 0.0=无穷远(用 dir)
var _sun_ranges: Array[float] = []        # OmniLight3D.omni_range; 方向光填 1e9(等价不衰减)
var _sun_attens: Array[float] = []        # OmniLight3D.omni_attenuation; 方向光填 0.0
var _sun_count: int = 0
const MAX_SUNS: int = 4
const ROOT_COUNT: int = 20  # icosahedron 根面数(固定); 每根一个稳定 MeshInstance3D

var _gen: int = 0
var _pool: PatchWorkerPool
var _pending: int = 0
var _tree_changed: bool = false   # 本 select_lod pass 是否发生 split/merge(结构变化); 用来在相机静止时仍驱动细分到稳定
var _jobs: Dictionary = {}  # job_id -> QNode: worker 回调据此找回节点(节点可能已被 queue_free)
var _next_job: int = 0
var _cam_pos: Vector3 = Vector3(1e9, 1e9, 1e9)
var _cam_moved: bool = true
var _wire: bool = false
var _body_mesh: Node3D  # 地形渲染节点的父容器(BodyMesh)
# 20 个稳定 MeshInstance3D(每个 icosahedron 根面一个, _ready 建一次永不销毁 → 节点层零 churn)。
# 每根独立 ArrayMesh + 独立 dirty → 飞行时只重建 churn 的那几个根, 其余可见根零成本。
var _root_meshes: Array = []      # Array[MeshInstance3D], 长度 = ROOT_COUNT = 20
var _root_dirty: PackedInt32Array  # 每根 dirty 标志(0/1); 帧末只对 ==1 的根调 _rebuild_root_mesh
var _root_patches: PackedInt32Array  # 每根可见 patch 数(stats 聚合用)
var _root_tris: PackedInt32Array     # 每根三角数(stats 聚合用)
var _last_params_hash: int = 0  # 参数指纹(轮询检测变化触发 rebuild, 绕过 @tool 信号不可靠)
var _last_visual_hash: int = 0  # 视觉指纹(atmo*/sun*/show*): 变化只推 shader uniform, 不重建地形
var _last_lod_hash: int = 0     # LOD 细分指纹(split*/maxLevel/...): 变化重跑 select_lod, 不重建地形
var _param_tick: int = 0
# 预取节流: 预取请求每帧上限 + 总 inflight 上限。超过则跳过预取 → 让位给"显示必需"的前景请求。
const PREFETCH_PER_FRAME := 8
const PREFETCH_INFLIGHT_CAP := 16
const FOREGROUND_INFLIGHT_CAP := 24  # 前景(显示必需)job 总上限; 防靠近/高细分时一次堆上百 job
const LOD_TICK_EVERY := 3   # select_lod 每 N 帧跑一次(遍历整棵四叉树是主线程热点); ≈20Hz 够 LOD 用
const STRIDE_BUDGET := 24   # 每 LOD pass 最多 compute_strides 次数(每次=3 target_level_at); 封顶 → 与移动速度解耦
# 影响 LOD 细分但不重建地形的参数: 改了只需重跑 select_lod(相机静止也立即刷新)。
const LOD_DIRTY_KEYS := ["maxLevel", "splitFactor", "prefetchFactor", "frustumMargin", "nearRadius", "horizonCulling", "mergeHysteresis", "splitBudget", "sseThresholdPixels", "geometricErrorScale"]
var _prefetch_this_frame: int = 0
var _lod_tick: int = 0
var _stride_used: int = 0
var _remaining_splits: int = 0  # 本 LOD pass 剩余分裂预算(移植 web splitBudget)
var _lod_dirty: int = 3         # >0 需跑 select_lod; 移动/相机变换/有在途 job 时置 3, 空闲逐拍递减到 0 后短路
var _last_cam_xform: Transform3D = Transform3D()  # 上次渲染相机变换(检测原地转视角 → 更新视锥剔除)
var _last_sun_light_pos: Vector3 = Vector3(INF, INF, INF)  # 上次 OmniLight3D 位置(检测拖动 → 重算 sun_dir)
var _last_sun_lights_key: Array = []   # 上次 sun_lights 集合(检测增删光源 → 重算)
var _last_omni_positions: Dictionary = {}   # instance_id -> Vector3(多 OmniLight3D 各自位置追踪)


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
	if _body_mesh == null:
		# 优先用场景里手动建的 BodyMesh(编辑器可见); 没有则代码建一个(internal)
		_body_mesh = get_node_or_null("BodyMesh")
		if _body_mesh == null:
			_body_mesh = Node3D.new()
			_body_mesh.name = "BodyMesh"
			add_child(_body_mesh, false, Node.INTERNAL_MODE_BACK)
	_ensure_root_meshes()  # 20 个根面 MeshInstance3D(每根一个, 稳定不销毁)
	if material == null:
		var tsh := load("res://shaders/terrain.gdshader")
		material = ShaderMaterial.new()
		material.shader = tsh
		material.resource_local_to_scene = false   # 共享一份; uniform 推一次全 patch 生效
		# render_mode cull_back 已在 shader 里声明(封闭球壳); 此处不再设 StandardMaterial3D 选项。
	if _wire_fill_mat == null:
		# 线框模式的"实心遮挡面": 复用 terrain shader 拿到顶点位移(否则网格是平滑球),
		# 通过 u_wire_mode=1 让 fragment 输出深色, 深度照常写(挡背面线段)。
		_wire_fill_mat = material.duplicate()
		_wire_fill_mat.set_shader_parameter("u_wire_mode", 1.0)
	if _wire_line_mat == null:
		# 线框模式的"亮线段": 同样复用 terrain shader 拿位移, u_wire_mode=2 输出亮色。
		# 线段(PrimitiveMesh LINE)不受 cull_mode 影响 → shader 的 cull_back 不会剔掉线段。
		_wire_line_mat = material.duplicate()
		_wire_line_mat.set_shader_parameter("u_wire_mode", 2.0)
	_build_effects()  # 大气壳 + 海洋 mesh + shader(Phase 2)
	_build_compositor()  # CompositorEffect 全屏后处理大气(挂 WorldEnvironment)
	if roots.is_empty():
		_build_noise()
		_build_roots()
	_apply_terrain_uniforms()
	_last_params_hash = _compute_params_hash()
	_last_lod_hash = _compute_lod_hash()
	_log_ready()


func _process(_delta: float) -> void:
	# 信号连接保险(运行时用)
	if params != null and params.has_signal("param_changed") and not params.is_connected("param_changed", _on_param_changed):
		params.connect("param_changed", _on_param_changed)
	# 多太阳位置变化检测: 任一 OmniLight3D 拖动 / sun_lights 增删 → 重算所有 sun dir/pos。
	# DirectionalLight3D 不需要(方向由 params 通过 look_at 强制对齐)。
	if _sun_lights_changed() or _any_omni_moved():
		_update_sun()
	# 参数指纹轮询(编辑器+运行时统一): 每 15 帧检测参数变化 → rebuild。
	# @tool 下 local_to_scene 副本的 param_changed 信号不可靠, 改用轮询(参照 planet_node.gd)。
	_param_tick += 1
	if _param_tick % 15 == 0:
		var h: int = _compute_params_hash()
		if h != _last_params_hash:
			_last_params_hash = h
			rebuild()
			return
		# 视觉参数(atmo*/sun*/show*)变化 → 只推 shader uniform + 缩放 + 可见性, 不重建地形。
		var vh: int = _compute_visual_hash()
		if vh != _last_visual_hash:
			_last_visual_hash = vh
			_apply_visual_changes()
		# LOD 细分参数(splitFactor/maxLevel/...)变化 → 标记脏, 相机静止也重跑 select_lod(编辑器轮询路径)。
		var lh: int = _compute_lod_hash()
		if lh != _last_lod_hash:
			_last_lod_hash = lh
			_mark_lod_dirty()
	# 推本帧场景参数给大气 CompositorEffect(sun_dir/planet_center/散射/云...)。
	# 相机矩阵由 Compositor 从 render_data 自己取。
	_push_compositor_frame()
	# autoSun: 按 sunSpeed 进方位角(改 params.sunAzimuth → 触发 _on_param_changed → _update_sun)
	if params != null and params.autoSun:
		params.sunAzimuth = fmod(params.sunAzimuth + params.sunSpeed * _delta, 360.0)
	# 编辑器用 3D 视口相机驱动 LOD; 运行时优先 @export 相机, 回退视口活动相机。
	var cam: Camera3D = null
	if Engine.is_editor_hint():
		var ev := get_viewport()
		cam = ev.get_camera_3d() if ev != null else null
	else:
		cam = camera
		if cam == null:
			var rv := get_viewport()
			cam = rv.get_camera_3d() if rv != null else null
	if cam != null:
		# 大气壳挂 Planet 下(随节点移动), 不再跟随相机 → 编辑器视口相机也能看到(不依赖 snap)。
		update(cam)
	# mesh 即单元(每根独立): 任何 worker 完成/渲染状态翻转/split/merge 都置【对应根】dirty →
	# 帧末只重建 dirty 的根, 不动其它可见根(飞行时 churn 只在镜头附近 2~4 个根, 其余零成本)。
	# 与 LOD tick(每 3 帧)解耦: 本帧没跑 select_lod 时, 有 patch 就绪也立即合并显示。
	var rc := mini(roots.size(), _root_dirty.size())
	for i in range(rc):
		if _root_dirty[i] == 1:
			_rebuild_root_mesh(i)
			_root_dirty[i] = 0
	# 聚合 stats(ROOT_COUNT 次加法, 可忽略)。每根的 patches/tris 在 _rebuild_root_mesh 里更新。
	var tp := 0
	var tt := 0
	for i in range(_root_patches.size()):
		tp += _root_patches[i]
		tt += _root_tris[i]
	stats.patches = tp
	stats.triangles = tt


# 参数指纹: 任一关键参数变化 → 哈希变 → _process 轮询到就 rebuild。绕过信号不可靠。
func _compute_params_hash() -> int:
	var p: PlanetParams = params
	if p == null:
		return 0
	var h: int = hash(p.radius)
	h = (h * 31 + hash(p.maxHeight)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.patchResolution)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.continentSeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.continentFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.continentOctaves)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.continentGain)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.continentLacunarity)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.mountainSeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.mountainFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.mountainOctaves)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.mountainStrength)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.warpSeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.warpStrength)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.warpFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.plateSeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.plateFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.plateStrength)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.moistureSeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.moistureFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.useClimate)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.climateAltRange)) & 0x7FFFFFFF
	return h


# 视觉参数指纹(含 atmo*/sun*/show*/seaLevel): 任一变化 → 哈希变 → _process 轮询到就 _apply_visual_changes。
# 与 _compute_params_hash 分离: 这些参数改了只推 shader uniform/缩放, 不触发地形 rebuild。
# seaLevel 在此: 改海平面只 resize 海洋球 + 推 terrain u_sea(水线/滩涂), 地形几何不动 → 不 rebuild。
func _compute_visual_hash() -> int:
	var p: PlanetParams = params
	if p == null:
		return 0
	var h: int = hash(p.seaLevel)
	h = (h * 31 + hash(p.atmoScale)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoRayleigh)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoMie)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoMieG)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoDensityFalloff)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoMieFalloff)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoSunIntensity)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoExposure)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoSteps)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoLightSteps)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoShadowSoftness)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoTwilight)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoDither)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.atmoOzone)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.sunElevation)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.sunAzimuth)) & 0x7FFFFFFF
	h = (h * 31 + hash(int(p.showOcean))) & 0x7FFFFFFF
	h = (h * 31 + hash(int(p.showAtmosphere))) & 0x7FFFFFFF
	h = (h * 31 + hash(int(p.showClouds))) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudBottom)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudTop)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudCoverage)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudDensity)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudFreq)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudWarp)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudWindSpeed)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudSteps)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudLightSteps)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudAbsorb)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudSilver)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudPowder)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.cloudShadow)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.oceanDeep)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.oceanShallow)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.oceanAmbient)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.oceanSpecPower)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.oceanSpecStrength)) & 0x7FFFFFFF
	return h


# LOD 细分参数指纹(splitFactor/maxLevel/nearRadius/...): 任一变化 → 细分阈值变 → 需重跑 select_lod。
# 与 _compute_params_hash / _compute_visual_hash 分离: 这些参数既不重建地形, 也不进 shader uniform,
# 只影响 select_lod 的距离判定 → 单独指纹供编辑器轮询(运行时由 _on_param_changed 直接标记脏)。
func _compute_lod_hash() -> int:
	var p: PlanetParams = params
	if p == null:
		return 0
	var h: int = hash(p.maxLevel)
	h = (h * 31 + hash(p.splitFactor)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.prefetchFactor)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.frustumMargin)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.nearRadius)) & 0x7FFFFFFF
	h = (h * 31 + hash(int(p.horizonCulling))) & 0x7FFFFFFF
	h = (h * 31 + hash(p.mergeHysteresis)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.splitBudget)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.sseThresholdPixels)) & 0x7FFFFFFF
	h = (h * 31 + hash(p.geometricErrorScale)) & 0x7FFFFFFF
	return h


# 把 LOD 标记为脏: 置 _lod_dirty=3 → 接下来几拍 select_lod 必跑(即使相机静止)。
# 用于参数变更(split*/maxLevel/...)时立即刷新细分, 取代"必须动一下相机才生效"。
func _mark_lod_dirty() -> void:
	_lod_dirty = 3


# 视觉参数变化的轻量应用(不重建地形): 缩放/壳半径 + 大气散射 uniform + 太阳方向 + 壳可见性。
func _apply_visual_changes() -> void:
	if params == null:
		return
	_resize_effects()        # seaLevel/radius → 海平面(海洋球)缩放
	# seaLevel 是视觉参数(不重建地形): 推 terrain u_sea → 水线/滩涂着色随海平面更新。
	if material != null:
		material.set_shader_parameter("u_sea", params.seaLevel)
	_apply_ocean_uniforms()  # ocean* 海洋参数 → 海洋 shader uniform
	_update_sun()            # sunElevation/sunAzimuth → u_sun_dir + sun_light 朝向
	if _ocean_mesh != null:
		_ocean_mesh.visible = params.showOcean
	# atmo*/cloud* 散射参数由 _push_compositor_frame 每帧推给 Compositor(无需在此处理)。


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
			f.store_line("r0 ready=%s state=%d" % [r0.mesh_ready, r0.render_state])
		f.close()


func _on_param_changed(key: String) -> void:
	match key:
		"wireframe":
			set_wireframe(params.wireframe)
		"showOcean":
			if _ocean_mesh != null:
				_ocean_mesh.visible = params.showOcean
		"sunElevation", "sunAzimuth":
			_update_sun()
		_:
			# ocean* → 推海洋 uniform; atmo*/cloud*/showAtmosphere/showClouds 由 _push_compositor_frame 每帧推。
			if key.begins_with("ocean"):
				_apply_ocean_uniforms()
	if params.requires_rebuild(key):
		rebuild()
	elif key in LOD_DIRTY_KEYS:
		_mark_lod_dirty()


func _build_noise() -> void:
	terrain = Terrain.from_params(params)


# 把地形参数/种子偏移推到 terrain.gdshader uniform(与 terrain.gd height_at 同源 → GPU 视觉=CPU 碰撞)。
# 同时推给 wire 材质: 它们复用 terrain shader 拿位移, 必须同步噪声/半径等参数, 否则线框贴合不到地形。
func _apply_terrain_uniforms() -> void:
	if material == null or params == null:
		return
	var p := params
	var mats: Array = [material]
	if _wire_fill_mat != null:
		mats.append(_wire_fill_mat)
	if _wire_line_mat != null:
		mats.append(_wire_line_mat)
	for mat in mats:
		mat.set_shader_parameter("u_radius", p.radius)
		mat.set_shader_parameter("u_max_height", p.maxHeight)
		mat.set_shader_parameter("u_skirt_depth", p.maxHeight * 2.5)   # 裙边径向内缩, 盖 LOD 裂缝
		mat.set_shader_parameter("u_sea", p.seaLevel)
		mat.set_shader_parameter("u_warp", p.warpStrength)
		mat.set_shader_parameter("u_warp_freq", p.warpFreq)
		mat.set_shader_parameter("u_cont_freq", p.continentFreq)
		mat.set_shader_parameter("u_cont_oct", p.continentOctaves)
		mat.set_shader_parameter("u_cont_gain", p.continentGain)
		mat.set_shader_parameter("u_cont_lac", p.continentLacunarity)
		mat.set_shader_parameter("u_mtn_freq", p.mountainFreq)
		mat.set_shader_parameter("u_mtn_oct", p.mountainOctaves)
		mat.set_shader_parameter("u_mtn_strength", p.mountainStrength)
		mat.set_shader_parameter("u_plate", p.plateStrength)
		mat.set_shader_parameter("u_plate_freq", p.plateFreq)
		mat.set_shader_parameter("u_moist_freq", p.moistureFreq)
		mat.set_shader_parameter("u_alt_range", p.climateAltRange)
		mat.set_shader_parameter("u_use_climate", 1 if p.useClimate else 0)
		mat.set_shader_parameter("u_off_warp", Terrain.off(p.warpSeed))
		mat.set_shader_parameter("u_off_cont", Terrain.off(p.continentSeed))
		mat.set_shader_parameter("u_off_mtn", Terrain.off(p.mountainSeed))
		mat.set_shader_parameter("u_off_plate", Terrain.off(p.plateSeed))
		mat.set_shader_parameter("u_off_moist", Terrain.off(p.moistureSeed))
		mat.set_shader_parameter("u_sun_dir", _sun_dir)


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
	for fi in range(_faces.size()):
		var f: Array = _faces[fi]
		var r := QNode.new()
		r.setup(self, _V[f[0]], _V[f[1]], _V[f[2]], 0)
		r.root_index = fi   # 记所属根面 → dirty/重建精确到根
		var data := PatchBuilder.build_patch_arrays(
			r.A, r.B, r.C, params.patchResolution, params.radius,
			params.maxHeight, terrain, [1, 1, 1])
		r._patch_data = data
		r.set_surfaces(_gen_surface_list(data, _wire), int(data.tris))
		r.render_state = 1  # 根默认可见(基础球壳), 首帧即可合并显示; select_lod 运行后接管细分/剔除
		r.built_key = "1,1,1"
		roots.append(r)
	_mark_all_roots_dirty()  # 首帧每根都重建出基础球壳


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
	# 缓存: target_level_at 是纯几何(给定 p, 结果依赖当前 _cam_pos)。按量化方向做 key 跨帧复用 ——
	# 相机缓慢移动时, 稳定可见 patch 的边采样点几乎不变 → 高命中; level 随相机位置分段常数,
	# 1 帧 staleness 只在跨阈值瞬间差 1 层(自纠正)。rebuild(_gen 变)时清缓存。
	if _tla_cache == null:
		_tla_cache = {}   # @tool 重载后已存在的实例不会重跑默认初始化器 → 懒初始化
	if _tla_cache_gen != _gen:
		_tla_cache.clear()
		_tla_cache_gen = _gen
	var key := Vector3i(int(p.x * 10000.0), int(p.y * 10000.0), int(p.z * 10000.0))
	var cached: Variant = _tla_cache.get(key, null)
	if cached != null:
		return int(cached)
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
	_tla_cache[key] = level
	return level


# ---- 网格 ----
# 由 _patch_data 生成 surface 列表(缓存到 QNode._surfaces, 合并重建时复用, 避免每次重算)。
# 非 wire: 1 个三角面 surface; wire: 2 个(实心遮挡面 + 亮线段)。每项 = {prim, arrays, tris}。
func _gen_surface_list(data: Dictionary, wire: bool) -> Array:
	var verts: PackedVector3Array = data.verts
	var norms: PackedVector3Array = data.norms
	var cols: PackedColorArray = data.cols
	var indices: PackedInt32Array = data.indices
	var tris: int = data.tris
	var out: Array = []
	if wire:
		# 线框双 surface: 实心遮挡面(深色 CULL_BACK 写深度, 略内缩避免 z-fight) + 亮线段(只测深度)。
		var verts_fill := PackedVector3Array()
		verts_fill.resize(verts.size())
		for i in range(verts.size()):
			verts_fill[i] = verts[i] * 0.99998
		var surf_f := []
		surf_f.resize(Mesh.ARRAY_MAX)
		surf_f[Mesh.ARRAY_VERTEX] = verts_fill
		surf_f[Mesh.ARRAY_INDEX] = indices
		out.append({"prim": Mesh.PRIMITIVE_TRIANGLES, "arrays": surf_f, "tris": tris})
		# 线段索引由三角索引 (a,b,c)→(a,b,b,c,c,a) 展开
		var line_idx := PackedInt32Array()
		for t in range(tris):
			var a: int = indices[t * 3]
			var b: int = indices[t * 3 + 1]
			var c: int = indices[t * 3 + 2]
			line_idx.append(a); line_idx.append(b)
			line_idx.append(b); line_idx.append(c)
			line_idx.append(c); line_idx.append(a)
		var surf_l := []
		surf_l.resize(Mesh.ARRAY_MAX)
		surf_l[Mesh.ARRAY_VERTEX] = verts
		surf_l[Mesh.ARRAY_INDEX] = line_idx
		out.append({"prim": Mesh.PRIMITIVE_LINES, "arrays": surf_l, "tris": tris})
	else:
		# 索引三角面: ARRAY_INDEX 复用共享顶点(顶点数约为非索引的 1/5)
		var surf := []
		surf.resize(Mesh.ARRAY_MAX)
		surf[Mesh.ARRAY_VERTEX] = verts
		surf[Mesh.ARRAY_NORMAL] = norms
		surf[Mesh.ARRAY_COLOR] = cols
		surf[Mesh.ARRAY_INDEX] = indices
		out.append({"prim": Mesh.PRIMITIVE_TRIANGLES, "arrays": surf, "tris": tris})
	return out


# 20 个根面 MeshInstance3D: 每个 icosahedron 根面一个, _ready 建一次永不销毁(节点层零 churn)。
# 挂 BodyMesh 下, 不写回 .tscn(set_owner null + INTERNAL)。位移/裙边在顶点 shader → AABB 不含 →
# 给足 extra_cull_margin 防整壳被误剔(可见性由 select_lod 手动剔除兜底)。
func _ensure_root_meshes() -> void:
	if _body_mesh == null:
		return
	# 复用已存在的 RootMesh0..N(防 @tool 重载重复建); 不够 ROOT_COUNT 则补齐。
	while _root_meshes.size() < ROOT_COUNT:
		var i := _root_meshes.size()
		var mi := MeshInstance3D.new()
		mi.name = "RootMesh%d" % i
		_body_mesh.add_child(mi, false, Node.INTERNAL_MODE_BACK)
		mi.set_owner(null)  # 防 @tool 编辑器把运行时节点写进场景文件
		mi.extra_cull_margin = params.radius * 4.0 + params.maxHeight * 3.0 + 1.0
		_root_meshes.append(mi)
	# dirty/统计数组对齐 ROOT_COUNT; 新建/扩容 → 全标脏, 首帧全重建
	if _root_dirty.size() != ROOT_COUNT:
		_root_dirty.resize(ROOT_COUNT)
		_root_dirty.fill(1)
	if _root_patches.size() != ROOT_COUNT:
		_root_patches.resize(ROOT_COUNT)
	if _root_tris.size() != ROOT_COUNT:
		_root_tris.resize(ROOT_COUNT)


# 收集 render_state==1 且 mesh_ready 的节点(叶 或 兜底内部节点); state==2 递归子; state==0 跳过整子树。
func _collect_visible_leaves(node: QNode, out: Array) -> void:
	if node.render_state == 0:
		return
	if node.render_state == 1:
		if node.mesh_ready:
			out.append(node)
		return  # 自身渲染模式: 不递归(子被隐藏)
	if node.children != null:
		for c in node.children:
			_collect_visible_leaves(c, out)


# 标记单个根 dirty(状态翻转/split/merge/worker 完成时调)。帧末只重建 dirty 根。
func _mark_root_dirty(idx: int) -> void:
	if idx >= 0 and idx < _root_dirty.size():
		_root_dirty[idx] = 1


# 标记所有根 dirty(首帧 / wireframe 切换 / rebuild 后)。
func _mark_all_roots_dirty() -> void:
	for i in range(_root_dirty.size()):
		_root_dirty[i] = 1


# 把多个 surface arrays 合并成单个 arrays[](顶点/法线/颜色 append_array + 索引按累积顶点偏移)。
# 用于每根内部合并 → 恒 1 surface/根: 绕开 ArrayMesh MAX_MESH_SURFACES(256)上限 + draw call 降到 20。
# channels 由各 arr 实际填充决定(非 wire 三角面: v/n/c/i; wire 实心面/线段: v/i)。同一次合并内各 arr 通道一致。
func _merge_surface_arrays(src_list: Array) -> Array:
	var big_v := PackedVector3Array()
	var big_n := PackedVector3Array()
	var big_c := PackedColorArray()
	var has_n := false
	var has_c := false
	var total_idx := 0
	for arr in src_list:
		big_v.append_array(arr[Mesh.ARRAY_VERTEX])
		var n: Variant = arr[Mesh.ARRAY_NORMAL]
		if n != null and n.size() > 0:
			big_n.append_array(n)
			has_n = true
		var c: Variant = arr[Mesh.ARRAY_COLOR]
		if c != null and c.size() > 0:
			big_c.append_array(c)
			has_c = true
		total_idx += arr[Mesh.ARRAY_INDEX].size()
	# 索引按累积顶点数偏移: 一次性 resize 后逐元素写入(避免 append 多次重分配)。
	var big_i := PackedInt32Array()
	big_i.resize(total_idx)
	var w := 0
	var voff := 0
	for arr in src_list:
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var cnt := idx.size()
		for j in range(cnt):
			big_i[w] = idx[j] + voff
			w += 1
		voff += v.size()
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = big_v
	if has_n:
		out[Mesh.ARRAY_NORMAL] = big_n
	if has_c:
		out[Mesh.ARRAY_COLOR] = big_c
	out[Mesh.ARRAY_INDEX] = big_i
	return out


# 重建【单个根】的 ArrayMesh: 该根所有可见叶合并成【单 surface】(非 wire)或【fill+line 两 surface】(wire)。
# 恒 ≤2 surface/根 → 永不触 MAX_MESH_SURFACES(256)。只在 _root_dirty[i]==1 时调 → 只 churn 根花成本。
func _rebuild_root_mesh(i: int) -> void:
	if i < 0 or i >= _root_meshes.size():
		_root_patches[i] = 0
		_root_tris[i] = 0
		return
	var mi: MeshInstance3D = _root_meshes[i]
	if mi == null or not is_instance_valid(mi):
		return
	var leaves: Array = []
	if i < roots.size():
		_collect_visible_leaves(roots[i], leaves)
	var am := ArrayMesh.new()
	var rp := 0
	var rt := 0
	if _wire:
		# 线框: 所有叶的实心遮挡面合并成 1 surface, 所有亮线段合并成 1 surface(共 2 surface/根)。
		var fill_arr := []
		var line_arr := []
		for q in leaves:
			if q._surfaces.size() >= 1:
				fill_arr.append((q._surfaces[0] as Dictionary).arrays)
				rp += 1
				rt += q.tri_count
			if q._surfaces.size() >= 2:
				line_arr.append((q._surfaces[1] as Dictionary).arrays)
		if not fill_arr.is_empty():
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _merge_surface_arrays(fill_arr))
		if not line_arr.is_empty():
			am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, _merge_surface_arrays(line_arr))
		mi.mesh = am
		mi.material_override = null
		for s in range(am.get_surface_count()):
			mi.set_surface_override_material(s, _wire_fill_mat if s == 0 else _wire_line_mat)
	else:
		# 非 wire: 该根所有可见叶合并成【单个】 TRIANGLES surface → 恒 1 surface/根。
		var tri_arr := []
		for q in leaves:
			if q._surfaces.size() >= 1:
				tri_arr.append((q._surfaces[0] as Dictionary).arrays)
				rp += 1
				rt += q.tri_count
		if not tri_arr.is_empty():
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _merge_surface_arrays(tri_arr))
		mi.mesh = am
		mi.material_override = material
		for s in range(am.get_surface_count()):
			mi.set_surface_override_material(s, null)
	_root_patches[i] = rp
	_root_tris[i] = rt


# ---- Worker 请求调度 ----
func request_mesh(node: QNode, strides: Array, key: String, is_prefetch: bool = false) -> void:
	if node.pending:
		return
	if node.mesh_ready and node.built_key == key:
		return
	# inflight 上限: 防止靠近/高细分时一次堆上百个 job → 完成回调挤爆主线程造成卡顿。
	# 前景(显示必需)上限高(24)、优先; 预取上限低(8)。超限就让位, 下个 select_lod 再补。
	var cap: int = FOREGROUND_INFLIGHT_CAP if not is_prefetch else PREFETCH_INFLIGHT_CAP
	if _pending >= cap:
		return
	if is_prefetch:
		if _prefetch_this_frame >= PREFETCH_PER_FRAME:
			return
		_prefetch_this_frame += 1
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
	# RefCounted 节点: _jobs 持引用使其在 merge 后仍存活(但被 dispose → cancelled=true)。
	# 用 Variant 接住再校验, 避开 freed 实例赋值报错。
	var raw: Variant = _jobs.get(job_id, null)
	_jobs.erase(job_id)
	_pending -= 1
	if raw == null or not is_instance_valid(raw):
		return
	var node: QNode = raw
	node.pending = false
	if not node.cancelled and int(data.gen) == _gen:
		node._patch_data = data
		node.set_surfaces(_gen_surface_list(data, _wire), int(data.tris))
		node.built_key = node.req_key
		_mark_root_dirty(node.root_index)  # 帧末只重建该根(不再 per-event set_mesh → 消尖刺)
		_mark_lod_dirty()         # 让 select_lod 尽快重评(子就绪 → fallback 切递归子)


# 每 LOD pass 的 compute_strides 配额: 超过 STRIDE_BUDGET 次返回 false → 调用方跳过(等下个 pass)。
# 把"新 patch 首次缝合"的主线程成本封顶, 与相机移动速度解耦。满了的 patch 父层暂显(merge 兜底)。
func stride_budget_ok() -> bool:
	if _stride_used < STRIDE_BUDGET:
		_stride_used += 1
		return true
	return false


# 每帧分裂预算(移植 web splitBudget): 单个 LOD pass 最多新分裂 params.splitBudget 个 chunk。
# 限制靠近时 worker 队列瞬时暴涨, 把生成峰值摊到多帧; 预算用完的 chunk 本帧退化为叶。
func split_budget_ok() -> bool:
	if _remaining_splits > 0:
		_remaining_splits -= 1
		return true
	return false


func update(cam: Camera3D) -> void:
	# LOD 细分距离用 lod_target(角色)位置 cp; 地平线剔除/视锥用【真实渲染相机】(见下方 cull_pos/frustum)。
	var focus: Node3D = lod_target if lod_target != null else cam
	var cp: Vector3 = focus.global_position - global_position
	# moved: 相对【上次真正跑 select_lod 时】的位置是否移动(_cam_pos 仅在真正跑时更新)。
	var moved: bool = cp.distance_squared_to(_cam_pos) > 1e-6
	# 相机变换变化(角色模式原地转视角也要重算视锥剔除): 上一版把这个删了 → 转视角时视锥停在旧朝向,
	# 连脚下/当前视野方向的地形都被旧视锥误剔(截图里角色脚下地面消失)。必须保留。
	var cam_xform: Transform3D = cam.global_transform
	var cam_changed: bool = not cam_xform.is_equal_approx(_last_cam_xform)
	# 静止短路(移植 web 版 !camMoved && inflight==0): lod_target 移动 / 转视角 / 有在途 job → 标记需再跑几拍;
	# 空闲后逐拍递减到 0 才短路(多跑几拍保证最后完成的 mesh 被 select_lod 显示出来)。
	if moved or cam_changed or _pending > 0:
		_lod_dirty = 3
	if _lod_dirty <= 0:
		stats.inflight = _pending
		return
	# 节流: select_lod 遍历整棵四叉树是主线程热点。每 LOD_TICK_EVERY 帧才完整跑一次(≈20Hz)。
	_lod_tick += 1
	if _lod_tick % LOD_TICK_EVERY != 0:
		return
	_lod_dirty -= 1
	_cam_moved = moved
	_cam_pos = cp
	_last_cam_xform = cam_xform
	cam.force_update_transform()   # 对齐 web camera.updateMatrixWorld(): 确保 get_frustum() 用本帧最新相机变换, 不滞后
	var frustum: Array = cam.get_frustum()
	var now: float = Time.get_ticks_msec() / 1000.0
	# SSE 系数(屏幕空间误差公式里的 K): vp_h / (2 × tan(fov_y/2))。一次性算好传给每个 QNode,
	# 让 select_lod 按 d < g_err × K / T 判定细分, 取代旧的 d < edge × splitFactor。
	# 编辑器视口相机也可能没设 fov(默认 75); 安全起见用 max(vp_h, 1.0) 防 0。
	var fov_y_rad: float = deg_to_rad(cam.fov if cam.fov > 0.0 else 75.0)
	var vp_h: float = 1080.0
	var vp := cam.get_viewport()
	if vp != null:
		vp_h = maxf(vp.get_visible_rect().size.y, 1.0)
	var sse_k: float = vp_h / (2.0 * tan(fov_y_rad * 0.5))
	# 编辑器不做剔除(地平线+视锥): 只跑距离 LOD 细分, chunk 不因「相机看不到」而被隐藏;
	# 运行时照常剔除。cull 经 select_lod/_render_interior 递归传到整棵四叉树。
	var cull: bool = not Engine.is_editor_hint()
	_prefetch_this_frame = 0
	_stride_used = 0
	_remaining_splits = params.splitBudget  # 每 LOD pass 重置分裂预算(移植 web splitBudget)
	_tree_changed = false   # 本 pass 结构变化标记(select_lod 内 split/merge 置 true)
	# 地平线剔除(可见性)用真实渲染相机位置 cull_pos; LOD 细分距离仍用 lod_target(cp)。
	# 角色贴地时地平线极近, 但第三人称相机抬高/后拉看得更远 → 用相机位判可见, 消除中远景三角空洞。
	var cull_pos: Vector3 = cam.global_position - global_position
	for r in roots:
		r.select_lod(cp, cull_pos, frustum, sse_k, _cam_moved, now, cull)
	# 结构仍在变(分裂/合并级联) 或 有在途 mesh → 保持 _lod_dirty, 让 select_lod 继续跑到稳定。
	# 这样改参数后即便相机静止, 也会按当前 lod 相机位置重新细分(不再停在最低细分等相机移动)。
	if _tree_changed or _pending > 0:
		_lod_dirty = 3
	stats.inflight = _pending


func rebuild() -> void:
	_gen += 1
	_pending = 0
	_jobs.clear()  # 丢弃所有 pending job(回调时 is_instance_valid 也会拦)
	for r in roots:
		r.dispose()
	roots.clear()  # RefCounted: 引用释放即自动回收, 无需 queue_free
	_cam_moved = true
	_cam_pos = Vector3(1e9, 1e9, 1e9)
	_lod_dirty = 3   # 重建后强制下几拍 select_lod 必跑 → 立即按相机距离重新细分(取代旧的间接 moved 触发)
	_build_noise()
	_build_roots()
	_apply_terrain_uniforms()
	_resize_effects()      # 海平面随 radius 重算
	_apply_ocean_uniforms() # 重新推海洋 uniform
	if _wire:
		set_wireframe(true)


# ---- Phase 2: 大气壳 + 海洋 + 太阳 ----
# 建两个单位球 mesh(挂 Planet 下、BodyMesh 兄弟), 各配 ShaderMaterial; 缩放/参数后续按 params 推。
func _build_effects() -> void:
	if _ocean_shader == null:
		_ocean_shader = load("res://shaders/ocean.gdshader")
	# 海洋球壳(spatial, 渲进场景 color, 供 Compositor 后处理采样)。大气已移到 CompositorEffect 全屏后处理。
	_ocean_mesh = _ensure_effect_shell("Ocean", "OceanShell")
	_ocean_mat = _ensure_shader_mat(_ocean_mesh, _ocean_shader)
	_resize_effects()
	_apply_ocean_uniforms()
	if _ocean_mesh != null:
		_ocean_mesh.visible = params.showOcean
	_update_sun()


# 建 CompositorEffect 全屏后处理大气并挂到场景 WorldEnvironment 节点的 compositor 属性。
# (compositor 在 WorldEnvironment 节点上, 不在 Environment 资源上。)
# 场景里没有 WorldEnvironment(如单独编辑 planet.tscn)→ 跳过(大气只在主场景 main.tscn 里生效)。
func _build_compositor() -> void:
	if _atmo_compositor != null:
		return
	var we: WorldEnvironment = get_node_or_null("../WorldEnvironment")
	if we == null:
		return
	_atmo_compositor = AtmosphereCompositor.new()
	_atmo_comp_res = Compositor.new()
	_atmo_comp_res.compositor_effects = [_atmo_compositor]
	we.compositor = _atmo_comp_res


func _make_effect_sphere(n: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	mi.mesh = sm
	return mi


# 取/建容器(container_name: 场景手建的 Node3D, 对齐 BodyMesh 模式); 其下复用或新建单位球壳。
# 容器不存在 → internal 建一个(向后兼容)。shell 用 INTERNAL_MODE_BACK 挂载 → 不写回 .tscn。
func _ensure_effect_shell(container_name: String, shell_name: String) -> MeshInstance3D:
	var cont: Node3D = get_node_or_null(container_name)
	if cont == null:
		cont = Node3D.new()
		cont.name = container_name
		add_child(cont, false, Node.INTERNAL_MODE_BACK)
	var existing: MeshInstance3D = cont.get_node_or_null(shell_name)
	if existing != null:
		return existing
	var mi := _make_effect_sphere(shell_name)
	cont.add_child(mi, false, Node.INTERNAL_MODE_BACK)
	return mi


# 复用现有 ShaderMaterial(场景里手建的)或新建一个; 返回该材质供后续 set_shader_parameter。
func _ensure_shader_mat(mi: MeshInstance3D, sh: Shader) -> ShaderMaterial:
	if mi == null:
		return null
	var mat: ShaderMaterial = mi.material_override
	if mat == null and sh != null:
		mat = ShaderMaterial.new()
		mat.shader = sh
		mi.material_override = mat
	return mat


# 海平面半径 = radius + seaLevel*maxHeight。大气半径(ratmo/cbottom/ctop)由 _push_compositor_frame 每帧推。
func _resize_effects() -> void:
	if params == null:
		return
	var R: float = params.radius
	var ground_r: float = R + params.seaLevel * params.maxHeight
	if _ocean_mesh != null:
		_ocean_mesh.scale = Vector3.ONE * ground_r


# 每帧把场景参数推给大气 CompositorEffect(主线程 → 渲染线程经 Mutex)。相机矩阵(invViewProj/camPos)
# 由 Compositor 自己从 render_data 取(编辑器/运行时相机都自动正确)。
# 云频率 cfreq 按 radius 归一(对齐 web main.js: cloudFreq/radius*100)→ M4 在此完成。
func _push_compositor_frame() -> void:
	if _atmo_compositor == null or params == null:
		return
	var p := params
	var R: float = p.radius
	var ray_ratio := Vector3(0.1066, 0.3245, 0.6830)
	var ozo_ratio := Vector3(0.35, 1.0, 0.045)
	var ground_r: float = R + p.seaLevel * p.maxHeight
	_atmo_compositor.enabled = p.showAtmosphere   # 关 = 跳过整条后处理(含云)
	# sun_pos / sun_is_local: 点光源近场时, 大气晨昏线按真实球冠几何(angular radius = acos(R/d))收缩;
	# 方向光/无光源 → 推到无穷远, sun_dir 视为常数方向(等价于原本“半边亮”的行为)。
	# 多太阳支持: 推 sun_dirs/sun_positions/sun_is_locals 数组 + sun_count(最多 MAX_SUNS=4 个)。
	# 兼容: 仍保留 sun_dir/sun_pos/sun_is_local(单太阳旧字段), 让旧 compositor 路径也能取到 [0]。
	var default_pos: Vector3 = global_position + _sun_dir * 1.0e9
	var first_pos: Vector3 = default_pos
	var first_local: float = 0.0
	if _sun_count > 0:
		first_pos = _sun_positions[0]
		first_local = _sun_is_locals[0]
	_atmo_compositor.set_frame_data({
		"time": Time.get_ticks_msec() / 1000.0,
		"sun_dir": _sun_dir,
		"sun_pos": first_pos,
		"sun_is_local": first_local,
		"sun_dirs": _sun_dirs.duplicate(),
		"sun_positions": _sun_positions.duplicate(),
		"sun_is_locals": _sun_is_locals.duplicate(),
		"sun_ranges": _sun_ranges.duplicate(),
		"sun_attens": _sun_attens.duplicate(),
		"sun_count": _sun_count,
		"planet_center": global_position,
		"rground": ground_r,
		"ratmo": R * p.atmoScale,
		"cbottom": R * p.cloudBottom,
		"ctop": R * p.cloudTop,
		"scatter_r": ray_ratio * p.atmoRayleigh,
		"scatter_m": p.atmoMie,
		"mie_g": p.atmoMieG,
		"ozone": ozo_ratio * p.atmoOzone,
		"density_falloff": p.atmoDensityFalloff,
		"mie_falloff": p.atmoMieFalloff,
		"sun_intensity": p.atmoSunIntensity,
		"exposure": p.atmoExposure,
		"steps": p.atmoSteps,
		"cloud_steps": p.cloudSteps,
		"light_steps": p.atmoLightSteps,
		"cloud_light_steps": p.cloudLightSteps,
		"dither": p.atmoDither,
		"shadow_softness": p.atmoShadowSoftness,
		"twilight": p.atmoTwilight,
		"clouds_on": 1.0 if p.showClouds else 0.0,
		"coverage": p.cloudCoverage,
		"cdensity": p.cloudDensity,
		"cfreq": p.cloudFreq / R * 100.0,   # 按半径归一(对齐 web; M4)
		"cwarp": p.cloudWarp,
		"cwindspeed": p.cloudWindSpeed,
		"absorb": p.cloudAbsorb,
		"silver": p.cloudSilver,
		"powder": p.cloudPowder,
		"cshadow": p.cloudShadow,
		"cterminator": p.cloudTerminatorShift,
		# 体积光 God rays(移植 web createGodrayPass)。decay/weight web 里是固定值, 这里也用常量。
		"godrays_on": 1.0 if p.showGodrays else 0.0,
		"godray_strength": p.godrayStrength,
		"godray_density": p.godrayDensity,
		"godray_samples": p.godraySamples,
		"godray_threshold": p.godrayThreshold,
		"godray_decay": 0.96,
		"godray_weight": 0.6,
	})


# ocean* 海洋参数 → 海洋 shader uniform(深/浅水色 + 夜侧亮度 + 高光锐度/强度)。
func _apply_ocean_uniforms() -> void:
	if _ocean_mat == null or params == null:
		return
	var p := params
	_ocean_mat.set_shader_parameter("u_deep", Vector3(p.oceanDeep.r, p.oceanDeep.g, p.oceanDeep.b))
	_ocean_mat.set_shader_parameter("u_shallow", Vector3(p.oceanShallow.r, p.oceanShallow.g, p.oceanShallow.b))
	_ocean_mat.set_shader_parameter("u_ambient", p.oceanAmbient)
	_ocean_mat.set_shader_parameter("u_spec_power", p.oceanSpecPower)
	_ocean_mat.set_shader_parameter("u_spec_strength", p.oceanSpecStrength)


# 返回"有效太阳列表": sun_lights 数组(若非空), 否则 [sun_light](遗留单太阳字段)。
func _effective_sun_lights() -> Array[Light3D]:
	var arr: Array[Light3D] = []
	for l in sun_lights:
		if l is Light3D:
			arr.append(l)
	if arr.is_empty() and sun_light is Light3D:
		arr.append(sun_light)
	return arr


# sun_lights 集合是否变化(增删光源 → 重算所有 sun dir/pos)。比较对象引用集合(忽略顺序)。
func _sun_lights_changed() -> bool:
	var cur: Array = _effective_sun_lights()
	if cur.size() != _last_sun_lights_key.size():
		_last_sun_lights_key = cur.duplicate()
		return true
	for l in cur:
		if not _last_sun_lights_key.has(l):
			_last_sun_lights_key = cur.duplicate()
			return true
	return false


# 任一 OmniLight3D 是否被拖动(位置变化)。多太阳场景下每个 OmniLight3D 各自追踪位置(instance_id 索引)。
func _any_omni_moved() -> bool:
	var moved: bool = false
	var cur_ids: Array = []
	var first_omni_pos: Variant = null   # 用于同步遗留变量 _last_sun_light_pos
	for l in _effective_sun_lights():
		if not (l is OmniLight3D):
			continue
		var id: int = l.get_instance_id()
		cur_ids.append(id)
		var p: Vector3 = l.global_position
		if first_omni_pos == null:
			first_omni_pos = p
		var prev: Variant = _last_omni_positions.get(id, null)
		if prev == null or not (prev as Vector3).is_equal_approx(p):
			moved = true
		_last_omni_positions[id] = p
	# 清理已删除光源的残留记录
	for k in _last_omni_positions.keys():
		if not cur_ids.has(k):
			_last_omni_positions.erase(k)
	# 同步遗留变量(单太阳旧代码用): 保存第一个 OmniLight3D 的当前位置
	if first_omni_pos != null:
		_last_sun_light_pos = first_omni_pos
	return moved


# sun_dir 来源(每太阳独立):
# - OmniLight3D: 从光源位置反推(点光源驱动, 用户拖光源 → 大气/海洋跟随), is_local=1。
# - DirectionalLight3D: 用其 -Z 朝向(planet-local, 与 look_at 对齐), is_local=0。
#   (DirectionalLight3D 自己被 look_at(-Z = -sun_dir) 强制对齐 params.sunElevation/Azimuth 算出的方向)
# - 无光源: 从 params.sunElevation/sunAzimuth 算 planet-local sun_dir(单太阳遗留行为)。
# 数组长度对齐 MAX_SUNS=4; _sun_count 为有效太阳数。然后 push 给海洋 shader(主太阳 [0])。
func _update_sun() -> void:
	if params == null:
		return
	var lights: Array[Light3D] = _effective_sun_lights()
	# 预过滤: 不可见 / omni_range<=0 的 OmniLight3D 不计。
	# 【不再按"够不到行星"踢出】— Layer 2 把逐像素衰减推进了 shader (sun_atten_for), 边缘会自然渐暗。
	# 仅当 omni_range=0(Godot 视为关闭)或 visible=false 时直接踢, 节省 GPU 算力。
	var filtered: Array[Light3D] = []
	for l in lights:
		if not (l is Light3D) or not l.visible:
			continue
		if l is OmniLight3D and l.omni_range <= 1e-4:
			continue   # omni_range=0 = 关掉
		filtered.append(l)
	var cnt: int = mini(filtered.size(), MAX_SUNS)
	# 没有挂光源 → 大气进入"无太阳"态: _sun_count=0, shader 里 sun_active() 全 false → 只有消光没有散射,
	# 大气壳呈暗色(背景被 T 压暗), 不再有晨昏线/蓝色辉光。用户加任意 Light3D 才会重新亮。
	# (旧版曾用 params.sunElevation/Azimuth 注入"虚构太阳"做向后兼容, 但这让"删光所有光源后大气还亮"
	# 这个直观期望失败 → 移除。如果确实想要"无 Light3D 也有太阳", 挂一个 DirectionalLight3D 即可。)
	if cnt == 0:
		_sun_dirs.clear()
		_sun_positions.clear()
		_sun_is_locals.clear()
		_sun_ranges.clear()
		_sun_attens.clear()
		_sun_count = 0
	else:
		_sun_dirs.clear()
		_sun_positions.clear()
		_sun_is_locals.clear()
		_sun_ranges.clear()
		_sun_attens.clear()
		# 找第一个 DirectionalLight3D(若存在), 用 params.sunElevation/Azimuth 锁定它;
		# 这样加任意点光源都不会让"主方向光"突然漂移(修 #1: cnt==1 切换的隐藏行为)。
		var first_dir_idx: int = -1
		for i in range(cnt):
			if filtered[i] is DirectionalLight3D:
				first_dir_idx = i
				break
		var el_param: float = deg_to_rad(params.sunElevation)
		var az_param: float = deg_to_rad(params.sunAzimuth)
		var wanted_dir: Vector3 = Vector3(cos(el_param) * cos(az_param), sin(el_param), cos(el_param) * sin(az_param)).normalized()
		for i in range(cnt):
			var l: Light3D = filtered[i]
			if l is OmniLight3D:
				var offset: Vector3 = l.global_position - global_position
				if offset.length_squared() > 1e-8:
					var d: Vector3 = offset.normalized()
					_sun_dirs.append(d)
					_sun_positions.append(l.global_position)
					_sun_is_locals.append(1.0)
					_sun_ranges.append(l.omni_range)
					_sun_attens.append(l.omni_attenuation)
					if i == 0:
						_sun_dir = d   # 主太阳方向(海洋/地形用)
				else:
					# 光源恰好在 planet_center(罕见) → 跳过(不计入有效太阳)
					pass
			elif l is DirectionalLight3D:
				# 第一个 DirectionalLight3D 永远跟 params 对齐(遗留行为); 多 DirectionalLight3D 时, 其它的尊重编辑器朝向。
				var d: Vector3
				if i == first_dir_idx:
					l.look_at(l.global_position - wanted_dir, Vector3.UP)
					d = wanted_dir
				else:
					d = (-l.global_basis.z).normalized()
				_sun_dirs.append(d)
				_sun_positions.append(global_position + d * 1.0e9)   # 无穷远占位
				_sun_is_locals.append(0.0)
				_sun_ranges.append(1.0e9)   # 方向光不衰减
				_sun_attens.append(0.0)
				if i == 0:
					_sun_dir = d
			else:
				# SpotLight3D 等其它 Light3D: 按 DirectionalLight3D 处理(用其 -Z 朝向)
				var d3: Vector3 = (-l.global_basis.z).normalized()
				_sun_dirs.append(d3)
				_sun_positions.append(global_position + d3 * 1.0e9)
				_sun_is_locals.append(0.0)
				_sun_ranges.append(1.0e9)
				_sun_attens.append(0.0)
				if i == 0:
					_sun_dir = d3
		_sun_count = _sun_dirs.size()
	# 推主太阳给地形(虽然 terrain.gdshader 当前未用 u_sun_dir, 但保留以兼容) + 海洋 shader
	if material != null:
		material.set_shader_parameter("u_sun_dir", _sun_dir)
	if _ocean_mat != null:
		# 主太阳 [0]: u_sun_dir/u_sun_pos/u_sun_is_local + u_sun_range/u_sun_atten + u_sun_count
		_ocean_mat.set_shader_parameter("u_sun_dir", _sun_dir)
		if _sun_count > 0:
			_ocean_mat.set_shader_parameter("u_sun_pos", _sun_positions[0])
			_ocean_mat.set_shader_parameter("u_sun_is_local", _sun_is_locals[0])
			_ocean_mat.set_shader_parameter("u_sun_range", _sun_ranges[0])
			_ocean_mat.set_shader_parameter("u_sun_atten", _sun_attens[0])
		_ocean_mat.set_shader_parameter("u_sun_count", _sun_count)
		# 额外槽位 1..N-1 → 数组(对齐 ocean shader 的 u_sun_dirs_add[3] 等)
		# Godot 4 的 Shader 类没有 has_param; ocean.gdshader 已声明这些 uniform, 直接推即可。
		if _ocean_mat.shader != null:
			var extras_dirs: PackedVector3Array = PackedVector3Array()
			var extras_pos: PackedVector3Array = PackedVector3Array()
			var extras_loc: PackedFloat32Array = PackedFloat32Array()
			var extras_rng: PackedFloat32Array = PackedFloat32Array()
			var extras_att: PackedFloat32Array = PackedFloat32Array()
			for i in range(1, _sun_count):
				extras_dirs.append(_sun_dirs[i])
				extras_pos.append(_sun_positions[i])
				extras_loc.append(_sun_is_locals[i])
				extras_rng.append(_sun_ranges[i])
				extras_att.append(_sun_attens[i])
			_ocean_mat.set_shader_parameter("u_sun_dirs_add", extras_dirs)
			_ocean_mat.set_shader_parameter("u_sun_positions_add", extras_pos)
			_ocean_mat.set_shader_parameter("u_sun_is_locals_add", extras_loc)
			_ocean_mat.set_shader_parameter("u_sun_ranges_add", extras_rng)
			_ocean_mat.set_shader_parameter("u_sun_attens_add", extras_att)


func set_wireframe(on: bool) -> void:
	_wire = on
	# 线框模式: 每个 patch 用"深色实心面(写深度, 挡背面)+ 亮线段(只测深度)"双 surface(见 _gen_surface_list)。
	# → 背面/远侧线被前方实心面的深度剔除, 只看到朝向相机的可见线。
	# 每根重建时按 surface 索引配 _wire_fill_mat / _wire_line_mat(见 _rebuild_root_mesh)。
	_refresh_all_surfaces()
	_mark_all_roots_dirty()  # wire 切换 → 所有根重刷 surface 配色


# 切换 wireframe 时, 用缓存的 _patch_data 重算所有节点的 _surfaces(新 _wire); 帧末合并重建时生效。
func _refresh_all_surfaces() -> void:
	for r in roots:
		_refresh_subtree_surfaces(r)


func _refresh_subtree_surfaces(node: QNode) -> void:
	if node.mesh_ready and not node._patch_data.is_empty():
		node._surfaces = _gen_surface_list(node._patch_data, _wire)
	if node.children != null:
		for c in node.children:
			_refresh_subtree_surfaces(c)


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
