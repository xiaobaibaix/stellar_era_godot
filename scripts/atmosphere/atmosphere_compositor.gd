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

const _SHADER_PATH := "res://shaders/atmosphere/atmosphere_compute.glsl"
const _COMPOSITE_PATH := "res://shaders/atmosphere/composite.glsl"
const _GODRAY_COPY_PATH := "res://shaders/atmosphere/godray_copy.glsl"
const _GODRAY_PATH := "res://shaders/atmosphere/godray_compute.glsl"
const _LUT_PATH := "res://shaders/atmosphere/transmittance_lut_compute.glsl"
const _LUT_W := 256
const _LUT_H := 64

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _depth_sampler: RID
var _mutex := Mutex.new()
var _shader_dirty := true
var _frame: Dictionary = {}

# 半分辨率大气/云: atmosphere pass 在缩放尺寸下算 L/T/cshadow → 两张 rgba16f 场纹理;
# composite pass 全分辨率上采样合成回 color。scale=1.0 时场纹理即全分辨率(结果与旧就地合成等价)。
var _comp_shader: RID
var _comp_pipeline: RID
var _comp_tried := false
var _scat_tex: RID          # rgb=内散射 L, a=地面云影 cshadow
var _trans_tex: RID         # rgb=逐通道透射率 T
var _field_size := Vector2i.ZERO
var _field_sampler: RID     # 线性 clamp, 供 composite 上采样场纹理

# 体积光 God rays: copy(color→lit 快照) + godray(lit→color 径向累积)。lit = rgba16f 临时 storage 纹理。
var _copy_shader: RID
var _copy_pipeline: RID
var _godray_shader: RID
var _godray_pipeline: RID
var _godray_tried := false
var _godray_ready := false
var _lit_tex: RID
var _lit_size := Vector2i.ZERO

# 透射率 LUT(M3): 256(mu)×64(r) rgba16f(rgb=向太阳光学深度)。大气参数变则重烘; 烘后下一帧起查表。
var _lut_shader: RID
var _lut_pipeline: RID
var _lut_tried := false
var _lut_tex: RID
var _lut_sampler: RID
var _lut_dirty := true
var _lut_baking := false            # 本帧刚烘 → 本帧仍回退 march(避免同帧 storage→sampler 竞态), 下帧起查表
var _lut_rground := NAN
var _lut_ratmo := NAN
var _lut_df := NAN
var _lut_mf := NAN


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
		if _copy_shader.is_valid():
			_rd.free_rid(_copy_shader)
			_copy_shader = RID()
			_copy_pipeline = RID()
		if _godray_shader.is_valid():
			_rd.free_rid(_godray_shader)
			_godray_shader = RID()
			_godray_pipeline = RID()
		if _lit_tex.is_valid():
			_rd.free_rid(_lit_tex)
			_lit_tex = RID()
		if _comp_shader.is_valid():
			_rd.free_rid(_comp_shader)
			_comp_shader = RID()
			_comp_pipeline = RID()
		if _scat_tex.is_valid():
			_rd.free_rid(_scat_tex)
			_scat_tex = RID()
		if _trans_tex.is_valid():
			_rd.free_rid(_trans_tex)
			_trans_tex = RID()
		if _field_sampler.is_valid():
			_rd.free_rid(_field_sampler)
			_field_sampler = RID()
		if _lut_shader.is_valid():
			_rd.free_rid(_lut_shader)
			_lut_shader = RID()
			_lut_pipeline = RID()
		if _lut_sampler.is_valid():
			_rd.free_rid(_lut_sampler)
			_lut_sampler = RID()
		if _lut_tex.is_valid():
			_rd.free_rid(_lut_tex)
			_lut_tex = RID()


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


# 编译一个 compute .glsl → [shader, pipeline]; 失败返回 [RID(), RID()] 并 push_error。
func _compile_pipeline(path: String) -> Array:
	var sf := load(path) as RDShaderFile
	if sf == null:
		push_error("[AtmosphereCompositor] load RDShaderFile 失败: " + path)
		return [RID(), RID()]
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[AtmosphereCompositor] compute 编译错误(" + path + "): " + (spirv.compile_error_compute if spirv != null else "null spirv"))
		return [RID(), RID()]
	var sh := _rd.shader_create_from_spirv(spirv)
	if not sh.is_valid():
		return [RID(), RID()]
	return [sh, _rd.compute_pipeline_create(sh)]


# 懒建 godray 的 copy + 径向两条 pipeline(只试一次); 都成功才返回 true。
func _ensure_godray() -> bool:
	if _godray_tried:
		return _godray_ready
	_godray_tried = true
	var a := _compile_pipeline(_GODRAY_COPY_PATH)
	_copy_shader = a[0]
	_copy_pipeline = a[1]
	var b := _compile_pipeline(_GODRAY_PATH)
	_godray_shader = b[0]
	_godray_pipeline = b[1]
	_godray_ready = _copy_pipeline.is_valid() and _godray_pipeline.is_valid()
	return _godray_ready


# 取/建 rgba16f 临时快照纹理(与颜色缓冲同尺寸; 尺寸变则重建)。仅作 storage image(imageLoad/Store)。
func _ensure_lit_tex(size: Vector2i) -> RID:
	if _lit_tex.is_valid() and _lit_size == size:
		return _lit_tex
	if _lit_tex.is_valid():
		_rd.free_rid(_lit_tex)
		_lit_tex = RID()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_lit_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_lit_size = size
	return _lit_tex


# 懒建全分辨率 composite pipeline(只试一次)。
func _ensure_composite() -> bool:
	if _comp_tried:
		return _comp_pipeline.is_valid()
	_comp_tried = true
	var a := _compile_pipeline(_COMPOSITE_PATH)
	_comp_shader = a[0]
	_comp_pipeline = a[1]
	return _comp_pipeline.is_valid()


# 取/建 两张 rgba16f 场纹理(scat=L+cshadow, trans=T), storage(写)+sampling(上采样读)。尺寸变则重建。
func _ensure_field_tex(size: Vector2i) -> bool:
	if _scat_tex.is_valid() and _trans_tex.is_valid() and _field_size == size:
		return true
	if _scat_tex.is_valid():
		_rd.free_rid(_scat_tex)
		_scat_tex = RID()
	if _trans_tex.is_valid():
		_rd.free_rid(_trans_tex)
		_trans_tex = RID()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_scat_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_trans_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_field_size = size
	return _scat_tex.is_valid() and _trans_tex.is_valid()


func _ensure_field_sampler() -> RID:
	if _field_sampler.is_valid():
		return _field_sampler
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	st.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	st.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_field_sampler = _rd.sampler_create(st)
	return _field_sampler


# 始终建好 256×64 rgba16f LUT 纹理(storage+sample); 保证大气 pass 的 set 3 可绑(未烘时 lut_on=0 不采样)。
func _ensure_lut_tex() -> RID:
	if _lut_tex.is_valid():
		return _lut_tex
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = _LUT_W
	fmt.height = _LUT_H
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_lut_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	return _lut_tex


# 懒建 LUT 烘焙 pipeline(只试一次)。
func _ensure_lut_pipeline() -> bool:
	if _lut_tried:
		return _lut_pipeline.is_valid()
	_lut_tried = true
	var c := _compile_pipeline(_LUT_PATH)
	_lut_shader = c[0]
	_lut_pipeline = c[1]
	return _lut_pipeline.is_valid()


func _ensure_lut_sampler() -> RID:
	if _lut_sampler.is_valid():
		return _lut_sampler
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	st.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	st.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_lut_sampler = _rd.sampler_create(st)
	return _lut_sampler


# 烘焙透射率 LUT: 大气参数变时调一次。(rground,ratmo,densityFalloff,mieFalloff) 经 push constant 传入。
func _dispatch_lut_bake(f: Dictionary) -> void:
	var rground: float = f.get("rground", 100.0)
	var ratmo: float = f.get("ratmo", 115.0)
	var df: float = f.get("density_falloff", 6.0)
	var mf: float = f.get("mie_falloff", 16.0)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(_lut_tex)
	var set0 := UniformSetCacheRD.get_cache(_lut_shader, 0, [u])
	var pc := PackedFloat32Array([rground, ratmo, df, mf])
	@warning_ignore("integer_division")
	var xg: int = (_LUT_W - 1) / 8 + 1
	@warning_ignore("integer_division")
	var yg: int = (_LUT_H - 1) / 8 + 1
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _lut_pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
	_rd.compute_list_dispatch(cl, xg, yg, 1)
	_rd.compute_list_end()
	_lut_rground = rground
	_lut_ratmo = ratmo
	_lut_df = df
	_lut_mf = mf


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
	# 多太阳: sun_dirs[4](xyz=方向, w=is_local) + sun_poss[4](xyz=位置, w=is_active) + sun_range_atten[4](x=range, y=atten) + sun_metas(x=count)
	# 单太阳旧接口兼容: 若没传 sun_dirs 数组, 就把 sun_dir/sun_pos/sun_is_local 当成 [0]。
	var default_dir: Vector3 = f.get("sun_dir", Vector3(0.739, 0.443, 0.515))
	var dirs_arr: Array = f.get("sun_dirs", [default_dir])
	var poss_arr: Array = f.get("sun_positions", [Vector3.ZERO])
	var locs_arr: Array = f.get("sun_is_locals", [float(f.get("sun_is_local", 0.0))])
	var ranges_arr: Array = f.get("sun_ranges", [1.0e9])      # 方向光默认无穷大 range → 不衰减
	var attens_arr: Array = f.get("sun_attens", [0.0])
	var sun_count: int = int(f.get("sun_count", dirs_arr.size()))
	sun_count = clampi(sun_count, 0, 4)
	for i in range(4):
		var d: Vector3 = dirs_arr[i] if i < dirs_arr.size() else Vector3(0.739, 0.443, 0.515)
		var lc: float = float(locs_arr[i]) if i < locs_arr.size() else 0.0
		b.append(d.x); b.append(d.y); b.append(d.z); b.append(lc)
	for i in range(4):
		var p: Vector3 = poss_arr[i] if i < poss_arr.size() else Vector3.ZERO
		var ac: float = 1.0 if i < sun_count else 0.0
		b.append(p.x); b.append(p.y); b.append(p.z); b.append(ac)
	for i in range(4):
		var rg: float = float(ranges_arr[i]) if i < ranges_arr.size() else 1.0e9
		var at: float = float(attens_arr[i]) if i < attens_arr.size() else 0.0
		b.append(rg); b.append(at); b.append(0.0); b.append(0.0)
	# sun_metas: x=count
	b.append(float(sun_count)); b.append(0.0); b.append(0.0); b.append(0.0)
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
	# cloud_c: cshadow, cterminator(云晨昏线位移), 0, 0
	b.append(f.get("cshadow", 0.7)); b.append(f.get("cterminator", 0.0)); b.append(0.0); b.append(0.0)
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

	# 透射率 LUT(M3): 大气参数变 → 重烘。本帧刚烘则 lut_on=0(回退 march), 下帧起查表(避免同帧 storage→sampler 竞态)。
	_ensure_lut_tex()   # 始终建好, 保证 set 3 可绑
	var lut_on := 0.0
	var lut_rg: float = f.get("rground", 100.0)
	var lut_ra: float = f.get("ratmo", 115.0)
	var lut_df: float = f.get("density_falloff", 6.0)
	var lut_mf: float = f.get("mie_falloff", 16.0)
	if (_lut_dirty or lut_rg != _lut_rground or lut_ra != _lut_ratmo
			or lut_df != _lut_df or lut_mf != _lut_mf) and _ensure_lut_pipeline():
		_lut_dirty = false
		_dispatch_lut_bake(f)
		_lut_baking = true
	if not _lut_baking and _lut_pipeline.is_valid():
		lut_on = 1.0
	_lut_baking = false

	var rsd := render_data.get_render_scene_data()
	var view_count: int = rsb.get_view_count()
	for view in range(view_count):
		var color_image: RID = rsb.get_color_layer(view)
		var depth_image: RID = rsb.get_depth_layer(view)
		# get_cam_transform() 返回【相机世界变换 camera→world】(= 逆视图矩阵), 其 origin 即相机世界位。
		# shader 里 farW = cam_xform * (inv_proj·ndc) 是把视图空间点变换到世界, 需要的正是 camera→world 本身,
		# 【不能】再取逆(取逆会把相机镜像到行星背面 → 大气/散射错位成横切盘面的亮带)。
		var cam_xform: Transform3D = rsd.get_cam_transform()
		var cam_pos: Vector3 = cam_xform.origin
		var inv_proj: Projection = rsd.get_cam_projection().inverse()

		# 全分辨率线程组数(composite + godray 用)
		@warning_ignore("integer_division")
		var xg: int = (size.x - 1) / 8 + 1
		@warning_ignore("integer_division")
		var yg: int = (size.y - 1) / 8 + 1

		# 分辨率比例 → 大气/云 pass 的缩放尺寸(clamp 到 [0.25, 1.0]; 至少 1px)
		var scale: float = clampf(f.get("render_scale", 0.5), 0.25, 1.0)
		var asize := Vector2i(maxi(int(round(size.x * scale)), 1), maxi(int(round(size.y * scale)), 1))
		@warning_ignore("integer_division")
		var axg: int = (asize.x - 1) / 8 + 1
		@warning_ignore("integer_division")
		var ayg: int = (asize.y - 1) / 8 + 1

		# 需要 composite pipeline + 两张场纹理; 任一不可用则本视图跳过(不写脏数据)。
		if not _ensure_composite() or not _ensure_field_tex(asize):
			continue

		var ubo_rid: RID = _build_frame_ubo(f, cam_pos, inv_proj, cam_xform)

		# ===== Pass 1: 大气/体积云 (缩放分辨率) → 写 L/T/cshadow 场纹理 =====
		# set 0: UBO
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u0.binding = 0
		u0.add_id(ubo_rid)
		# set 1: 两张输出场纹理(binding 0 = scat[L+cshadow], binding 1 = trans[T])
		var u1a := RDUniform.new()
		u1a.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u1a.binding = 0
		u1a.add_id(_scat_tex)
		var u1b := RDUniform.new()
		u1b.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u1b.binding = 1
		u1b.add_id(_trans_tex)
		# set 2: depth(sampler + texture, 全分辨率场景深度)
		var u2 := RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u2.binding = 0
		u2.add_id(_ensure_depth_sampler())
		u2.add_id(depth_image)
		# set 3: 透射率 LUT(sampler + texture)
		var u3 := RDUniform.new()
		u3.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u3.binding = 0
		u3.add_id(_ensure_lut_sampler())
		u3.add_id(_lut_tex)

		var set0 := UniformSetCacheRD.get_cache(_shader, 0, [u0])
		var set1 := UniformSetCacheRD.get_cache(_shader, 1, [u1a, u1b])
		var set2 := UniformSetCacheRD.get_cache(_shader, 2, [u2])
		var set3 := UniformSetCacheRD.get_cache(_shader, 3, [u3])

		var pc := PackedFloat32Array([float(asize.x), float(asize.y), lut_on, 0.0])

		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, set0, 0)
		_rd.compute_list_bind_uniform_set(cl, set1, 1)
		_rd.compute_list_bind_uniform_set(cl, set2, 2)
		_rd.compute_list_bind_uniform_set(cl, set3, 3)
		_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
		_rd.compute_list_dispatch(cl, axg, ayg, 1)
		_rd.compute_list_end()

		_rd.free_rid(ubo_rid)   # GPU 用完再释放(渲染设备延迟释放)

		# ===== Pass 2: 全分辨率合成(上采样 L/T/cshadow, 与全分辨率场景色合成)=====
		var exposure: float = f.get("exposure", 1.0)
		var c0 := RDUniform.new()
		c0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		c0.binding = 0
		c0.add_id(color_image)
		var c1 := RDUniform.new()
		c1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		c1.binding = 0
		c1.add_id(_ensure_field_sampler())
		c1.add_id(_scat_tex)
		var c2 := RDUniform.new()
		c2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		c2.binding = 0
		c2.add_id(_ensure_field_sampler())
		c2.add_id(_trans_tex)
		var cset0 := UniformSetCacheRD.get_cache(_comp_shader, 0, [c0])
		var cset1 := UniformSetCacheRD.get_cache(_comp_shader, 1, [c1])
		var cset2 := UniformSetCacheRD.get_cache(_comp_shader, 2, [c2])
		var cpc := PackedFloat32Array([float(size.x), float(size.y), exposure, 0.0])
		var clc := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clc, _comp_pipeline)
		_rd.compute_list_bind_uniform_set(clc, cset0, 0)
		_rd.compute_list_bind_uniform_set(clc, cset1, 1)
		_rd.compute_list_bind_uniform_set(clc, cset2, 2)
		_rd.compute_list_set_push_constant(clc, cpc.to_byte_array(), cpc.size() * 4)
		_rd.compute_list_dispatch(clc, xg, yg, 1)
		_rd.compute_list_end()

		# —— 体积光 God rays(移植 web createGodrayPass): 大气合成后, 从太阳屏幕位置径向累积亮束 ——
		if f.get("godrays_on", 0.0) > 0.5 and _ensure_godray():
			_dispatch_godray(f, rsd, cam_xform, cam_pos, color_image, size, xg, yg)


# 体积光两步: 1) copy color→lit 快照; 2) godray lit→color 径向累积。
# sun_uv: 太阳投影到屏幕的 uv; sun_vis: 相机朝向·太阳方向的 smoothstep(太阳在背后=0)。
# 多太阳时: 选第一个有效太阳做 godray(主光), 其余太阳的径向束暂不复刻(避免 godray 重复绘制过曝)。
# 近场点光源: 用真实世界位置投影; 无穷远平行光: 用 cam_pos + sun_dir*1e7(模拟极远点)。
func _dispatch_godray(f: Dictionary, rsd, cam_xform: Transform3D, cam_pos: Vector3, color_image: RID, size: Vector2i, xg: int, yg: int) -> void:
	var default_dir: Vector3 = f.get("sun_dir", Vector3(0.739, 0.443, 0.515))
	var dirs_arr: Array = f.get("sun_dirs", [default_dir])
	var poss_arr: Array = f.get("sun_positions", [Vector3.ZERO])
	var locs_arr: Array = f.get("sun_is_locals", [float(f.get("sun_is_local", 0.0))])
	var sun_count: int = clampi(int(f.get("sun_count", dirs_arr.size())), 0, 4)
	if sun_count == 0:
		return
	# 选第一个有效槽位当 godray 源
	var sd: Vector3 = dirs_arr[0] if not dirs_arr.is_empty() else default_dir
	var is_local: float = float(locs_arr[0]) if not locs_arr.is_empty() else 0.0
	var sp: Vector3 = poss_arr[0] if not poss_arr.is_empty() else Vector3.ZERO
	# world→clip = proj * view; cam_xform 是 camera→world → 视图矩阵 view(world→camera) = 其逆。
	var view_t: Transform3D = cam_xform.affine_inverse()
	var proj: Projection = rsd.get_cam_projection()
	var world_to_clip: Projection = proj * Projection(view_t)
	var sun_world: Vector3 = cam_pos + sd * 1.0e7   # 默认: 无穷远平行光
	if is_local >= 0.5:
		sun_world = sp   # 近场: 真实位置
	var clip: Vector4 = world_to_clip * Vector4(sun_world.x, sun_world.y, sun_world.z, 1.0)
	var sun_uv := Vector2(0.5, 0.5)
	if absf(clip.w) > 1e-6:
		sun_uv = Vector2(clip.x / clip.w * 0.5 + 0.5, clip.y / clip.w * 0.5 + 0.5)
	# 太阳离屏过远 → 跳过 godray(径向采样跨度会过大, 在屏幕边缘产生"一环环无尽延伸"的涂抹伪影)
	if sun_uv.x < -0.5 or sun_uv.x > 1.5 or sun_uv.y < -0.5 or sun_uv.y > 1.5:
		return
	# 太阳可见度: 相机朝向(-Z 世界)·太阳方向, smoothstep(0, 0.35)
	var cam_fwd: Vector3 = -cam_xform.basis.z
	var sv: float = clampf(cam_fwd.dot(sd) / 0.35, 0.0, 1.0)
	sv = sv * sv * (3.0 - 2.0 * sv)
	if sv <= 0.001:
		return
	var lit: RID = _ensure_lit_tex(size)

	# 1) copy color → lit(快照, 供 godray 径向读取)
	var cs0 := RDUniform.new()
	cs0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	cs0.binding = 0
	cs0.add_id(color_image)
	var cs1 := RDUniform.new()
	cs1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	cs1.binding = 0
	cs1.add_id(lit)
	var cset0 := UniformSetCacheRD.get_cache(_copy_shader, 0, [cs0])
	var cset1 := UniformSetCacheRD.get_cache(_copy_shader, 1, [cs1])
	var cpush := PackedFloat32Array([float(size.x), float(size.y), 0.0, 0.0])
	var clc := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clc, _copy_pipeline)
	_rd.compute_list_bind_uniform_set(clc, cset0, 0)
	_rd.compute_list_bind_uniform_set(clc, cset1, 1)
	_rd.compute_list_set_push_constant(clc, cpush.to_byte_array(), cpush.size() * 4)
	_rd.compute_list_dispatch(clc, xg, yg, 1)
	_rd.compute_list_end()

	# 2) godray lit → color(径向累积亮束, 叠加到 base)
	var gs0 := RDUniform.new()
	gs0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	gs0.binding = 0
	gs0.add_id(color_image)
	var gs1 := RDUniform.new()
	gs1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	gs1.binding = 0
	gs1.add_id(lit)
	var gset0 := UniformSetCacheRD.get_cache(_godray_shader, 0, [gs0])
	var gset1 := UniformSetCacheRD.get_cache(_godray_shader, 1, [gs1])
	var gpush := PackedFloat32Array()
	gpush.append(float(size.x))
	gpush.append(float(size.y))
	gpush.append(sun_uv.x)
	gpush.append(sun_uv.y)
	gpush.append(sv)
	gpush.append(f.get("godray_strength", 0.6))
	gpush.append(f.get("godray_density", 0.7))
	gpush.append(f.get("godray_decay", 0.96))
	gpush.append(f.get("godray_weight", 0.6))
	gpush.append(f.get("godray_threshold", 0.45))
	gpush.append(float(f.get("godray_samples", 48)))
	gpush.append(0.0)
	var clg := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clg, _godray_pipeline)
	_rd.compute_list_bind_uniform_set(clg, gset0, 0)
	_rd.compute_list_bind_uniform_set(clg, gset1, 1)
	_rd.compute_list_set_push_constant(clg, gpush.to_byte_array(), gpush.size() * 4)
	_rd.compute_list_dispatch(clg, xg, yg, 1)
	_rd.compute_list_end()
