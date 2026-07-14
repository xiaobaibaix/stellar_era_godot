# gdlint: disable=variable-name, max-line-length
## 大气/体积云 全屏后处理(移植 web src/effects.js 的多 pass 管线)。
##
## 用 Godot 4 的 CompositorEffect 在渲染管线里挂 compute pass:
##   POST_TRANSPARENT(透明 pass 之后、内置 tonemap/glow 之前)→ 读场景 color+depth →
##   全分辨率大气积分+精确合成 scene·T+L → (M5 起)屏幕空间 godrays。
## 输出线性 HDR 写回 color layer, 让 WorldEnvironment(tonemap_mode=4 = AgX + glow)做全帧唯一一次色调映射。
##
## 相机矩阵(invViewProj/camPos)直接从 render_data.get_render_scene_data() 取
## → 编辑器视口相机/运行时相机都自动正确(不依赖 planet.gd 传相机)。
## 场景参数(sun_dir/planet_center/半径/散射/云...)由 planet.gd 主线程经 set_frame_data + Mutex 推快照。
##
## M2(当前): 单个融合 compute(atmosphere_compute.glsl)做 atmo+云+精确合成, 全分辨率。
## M3 加透射率 LUT; M5 加 godray; M6 拆半分辨率 atmo + 全分辨率 composite。
@tool
class_name AtmosphereCompositor
extends CompositorEffect

const _SHADER_PATH := "res://shaders/compute/atmosphere_compute.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _depth_sampler: RID
var _mutex := Mutex.new()
var _shader_dirty := true
var _frame: Dictionary = {}


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	enabled = true
	_rd = RenderingServer.get_rendering_device()
	_shader_dirty = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _shader.is_valid():
			_rd.free_rid(_shader)   # 连带释放 pipeline(渲染设备做依赖追踪)
			_shader = RID()
			_pipeline = RID()
		if _depth_sampler.is_valid():
			_rd.free_rid(_depth_sampler)
			_depth_sampler = RID()


# 主线程调用: 推入本帧场景参数快照(planet.gd 每帧调)。Mutex 保护跨线程读写。
func set_frame_data(data: Dictionary) -> void:
	_mutex.lock()
	_frame = data
	_mutex.unlock()


# 标记需重编(暂未用: .glsl 改动后可外部调; 现在靠重启重载)。
func mark_shader_dirty() -> void:
	_mutex.lock()
	_shader_dirty = true
	_mutex.unlock()


func _ensure_shader() -> bool:
	if _rd == null:
		return false
	_mutex.lock()
	var dirty := _shader_dirty
	_shader_dirty = false
	_mutex.unlock()
	if not dirty:
		return _pipeline.is_valid()
	# .glsl 带 #[compute] 头, Godot 导入为 RDShaderFile(可预编译/缓存, 编译错误在导入时报)。
	var sf := load(_SHADER_PATH) as RDShaderFile
	if sf == null:
		push_error("[AtmosphereCompositor] load RDShaderFile 失败: " + _SHADER_PATH)
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[AtmosphereCompositor] compute 编译错误: " + (spirv.compile_error_compute if spirv != null else "null spirv"))
		return false
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


func _ensure_depth_sampler() -> RID:
	if _depth_sampler.is_valid():
		return _depth_sampler
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	# depth 用 nearest(场景深度逐像素精确, 不做双线性模糊)
	_depth_sampler = _rd.sampler_create(st)
	return _depth_sampler


# 把帧参数快照 + 相机矩阵打包成 std140 FrameData 字节缓冲(布局须与 atmosphere_compute.glsl UBO 完全一致)。
# 相机: inv_proj(NDC→视图空间) + cam_xform(视图→世界)。单视图下 get_view_projection 返回投影而非 vp, 故拆两步。
func _build_frame_ubo(f: Dictionary, cam_pos: Vector3, inv_proj: Projection, cam_xform: Transform3D) -> RID:
	var b := PackedFloat32Array()
	# mat4 inv_proj: 4 列 × xyzw(列主序)
	for c in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		b.append(c.x); b.append(c.y); b.append(c.z); b.append(c.w)
	# mat4 cam_xform: 列 = basis.x(w=0), basis.y(w=0), basis.z(w=0), origin(w=1)
	var bb := cam_xform.basis
	var bo := cam_xform.origin
	b.append(bb.x.x); b.append(bb.x.y); b.append(bb.x.z); b.append(0.0)
	b.append(bb.y.x); b.append(bb.y.y); b.append(bb.y.z); b.append(0.0)
	b.append(bb.z.x); b.append(bb.z.y); b.append(bb.z.z); b.append(0.0)
	b.append(bo.x); b.append(bo.y); b.append(bo.z); b.append(1.0)
	# cam_pos_time
	b.append(cam_pos.x); b.append(cam_pos.y); b.append(cam_pos.z); b.append(f.get("time", 0.0))
	# sun_dir
	var sd: Vector3 = f.get("sun_dir", Vector3(0.739, 0.443, 0.515))
	b.append(sd.x); b.append(sd.y); b.append(sd.z); b.append(0.0)
	# planet_center
	var pc: Vector3 = f.get("planet_center", Vector3.ZERO)
	b.append(pc.x); b.append(pc.y); b.append(pc.z); b.append(0.0)
	# radii: rground, ratmo, cbottom, ctop
	b.append(f.get("rground", 100.0)); b.append(f.get("ratmo", 115.0))
	b.append(f.get("cbottom", 101.0)); b.append(f.get("ctop", 106.0))
	# scatter_r_m: rgb=scatterR, a=scatterM
	var sr: Vector3 = f.get("scatter_r", Vector3(0.0085, 0.026, 0.055))
	b.append(sr.x); b.append(sr.y); b.append(sr.z); b.append(f.get("scatter_m", 0.03))
	# ozone_dither: rgb=ozone, a=dither
	var oz: Vector3 = f.get("ozone", Vector3(0.007, 0.02, 0.0009))
	b.append(oz.x); b.append(oz.y); b.append(oz.z); b.append(f.get("dither", 0.5))
	# mie_params: mieG, densityFalloff, mieFalloff, shadowSoftness
	b.append(f.get("mie_g", 0.76)); b.append(f.get("density_falloff", 6.0))
	b.append(f.get("mie_falloff", 16.0)); b.append(f.get("shadow_softness", 0.6))
	# sun_exp_twilight: sunIntensity, exposure, twilight, steps
	b.append(f.get("sun_intensity", 22.0)); b.append(f.get("exposure", 1.0))
	b.append(f.get("twilight", 0.3)); b.append(float(f.get("steps", 24)))
	# counts: cloudSteps, lightSteps, cloudLightSteps, clouds_on
	b.append(float(f.get("cloud_steps", 24))); b.append(float(f.get("light_steps", 8)))
	b.append(float(f.get("cloud_light_steps", 6))); b.append(f.get("clouds_on", 0.0))
	# cloud_a: coverage, cdensity, cfreq, cwarp
	b.append(f.get("coverage", 0.5)); b.append(f.get("cdensity", 1.2))
	b.append(f.get("cfreq", 0.06)); b.append(f.get("cwarp", 0.5))
	# cloud_b: cwindspeed, absorb, silver, powder
	b.append(f.get("cwindspeed", 0.6)); b.append(f.get("absorb", 1.0))
	b.append(f.get("silver", 1.0)); b.append(f.get("powder", 0.6))
	# cloud_c: cshadow, 0, 0, 0
	b.append(f.get("cshadow", 0.7)); b.append(0.0); b.append(0.0); b.append(0.0)
	return _rd.uniform_buffer_create(b.size() * 4, b.to_byte_array())


func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	if _rd == null:
		return
	if _effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	if not _ensure_shader():
		return
	var rsb = render_data.get_render_scene_buffers()
	if rsb == null:
		return
	var size: Vector2i = rsb.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_mutex.lock()
	var f: Dictionary = _frame
	_mutex.unlock()
	if f.is_empty():
		return   # planet.gd 还没推参数(首帧)→ 跳过, 下帧再跑

	var rsd := render_data.get_render_scene_data()
	var view_count: int = rsb.get_view_count()
	for view in range(view_count):
		var color_image: RID = rsb.get_color_layer(view)
		var depth_image: RID = rsb.get_depth_layer(view)
		# get_cam_transform() 返回【视图矩阵 V】(世界→相机); 其逆 = 相机世界变换 V⁻¹(视图→世界)。
		# (若不取逆, 视线方向反向 → 太空看不到大气、地表大气与地平线相反。)
		var cam_xform: Transform3D = rsd.get_cam_transform().affine_inverse()
		var cam_pos: Vector3 = cam_xform.origin
		var inv_proj: Projection = rsd.get_cam_projection().inverse()

		var ubo_rid: RID = _build_frame_ubo(f, cam_pos, inv_proj, cam_xform)

		# set 0: UBO
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u0.binding = 0
		u0.add_id(ubo_rid)
		# set 1: color image(读+写)
		var u1 := RDUniform.new()
		u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u1.binding = 0
		u1.add_id(color_image)
		# set 2: depth(sampler + texture)
		var u2 := RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u2.binding = 0
		u2.add_id(_ensure_depth_sampler())
		u2.add_id(depth_image)

		var set0 := UniformSetCacheRD.get_cache(_shader, 0, [u0])
		var set1 := UniformSetCacheRD.get_cache(_shader, 1, [u1])
		var set2 := UniformSetCacheRD.get_cache(_shader, 2, [u2])

		@warning_ignore("integer_division")
		var xg: int = (size.x - 1) / 8 + 1
		@warning_ignore("integer_division")
		var yg: int = (size.y - 1) / 8 + 1
		var pc := PackedFloat32Array([float(size.x), float(size.y), 0.0, 0.0])

		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, set0, 0)
		_rd.compute_list_bind_uniform_set(cl, set1, 1)
		_rd.compute_list_bind_uniform_set(cl, set2, 2)
		_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
		_rd.compute_list_dispatch(cl, xg, yg, 1)
		_rd.compute_list_end()

		_rd.free_rid(ubo_rid)   # GPU 用完再释放(渲染设备延迟释放)
