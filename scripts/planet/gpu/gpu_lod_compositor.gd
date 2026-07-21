# gdlint: disable=variable-name, max-line-length
## GPU LOD 遍历 compositor(Phase 2)。CompositorEffect 挂 PRE_OPAQUE, 每帧跑 lod_traverse.glsl。
##
## 拥有: shader/pipeline、双缓冲 patch 纹理(RD, STORAGE|SAMPLING)、双 counter(storage buffer)、
## Texture2DRD 包装(绑给 material)、frame 数据(cam_pos/planet_center/C_const/radius/maxHeight/maxLevel)。
##
## 1-帧延迟(消除同帧 storage→sampler 竞态, 沿用项目 LUT 模式): 本帧 compute 写 tex[write_idx],
## vertex shader 读 tex[read_idx](上一帧的)。帧末绑 material.u_patchTex = tex2drd[read_idx]。首帧空(count=0 坍缩)。
##
## 每帧 dispatch 序列(一个 compute_list, barrier 分隔 storage 依赖):
##   reset(level=-1, 1线程) → barrier → [per level 0..maxLevel: dispatch(ceil(20·4^L/64)) → barrier] → metadata(level=-2, 1线程)。
##
## 相机矩阵/位置由 GpuPlanet._process 主线程算好后 set_frame_data 推(不像大气 compositor 自己取 render_data 相机,
## 因为 LOD 需要显式 camera 引用以兼容 @tool 编辑器)。只在渲染线程 _render_callback 里读写 RID, 不碰主线程节点。
@tool
class_name GpuLodCompositor
extends CompositorEffect

const SHADER_PATH := "res://shaders/compute/lod_traverse.glsl"
const MAX_PATCHES := 4096          # 与 lod_traverse.glsl MAX_PATCHES 一致
const PATCH_TEX_W := 6             # 每 patch 6 texel
const PATCH_TEX_H := MAX_PATCHES + 1   # 末行存 count metadata
const WG := 64                     # workgroup size(与 glsl local_size_x 一致)

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _material_rid: RID

# 双缓冲(1-帧延迟): idx = _frame & 1 写, 1-idx 读。
var _patch_tex: Array = [RID(), RID()]      # RD 纹理(storage+sampling)
var _counter: Array = [RID(), RID()]        # storage buffer(uint count)
var _tex2drd: Array = [null, null]          # Texture2DRD 包装(暴露给 GpuPlanet 主线程 set_shader_parameter 绑定)
var _uniform_set: Array = [null, null]      # 缓存的 uniform set [set0_image, set1_counter] per write idx
var _frame: int = 0
var _cb_count: int = 0   # 调试: _render_callback 被调用次数(>0 说明回调已注册)
var _mutex := Mutex.new()
var _frame_data: Dictionary = {}
var _ready := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	enabled = true
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_res(_shader)
		_shader = RID()
		_pipeline = RID()
		for i in range(2):
			_free_res(_patch_tex[i]); _patch_tex[i] = RID()
			_free_res(_counter[i]); _counter[i] = RID()
		_ready = false


static func _free_res(rid: RID) -> void:
	if rid.is_valid():
		RenderingServer.get_rendering_device().free_rid(rid)


# GpuPlanet._ready 调: 编 shader + 建双缓冲纹理/counter/包装。
func setup(material_rid: RID) -> bool:
	_material_rid = material_rid
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[GpuLodCompositor] 无 RenderingDevice")
		return false
	if not _compile_shader():
		return false
	for i in range(2):
		if not _patch_tex[i].is_valid():
			_patch_tex[i] = _create_patch_tex()
			_counter[i] = _create_counter()
			var t := Texture2DRD.new()
			t.texture_rd_rid = _patch_tex[i]   # 正确属性名 texture_rd_rid(非 texture_rd)
			_tex2drd[i] = t
			_uniform_set[i] = null   # 首次 _render_callback 经 UniformSetCacheRD 按 RID 缓存
	_ready = true
	return true


# GpuPlanet._process(主线程)调: 取上一帧写好的纹理(Texture2DRD)绑给 material。write_idx=本帧要写的。
func get_read_texture(write_idx: int) -> Texture2DRD:
	return _tex2drd[1 - write_idx]


func _compile_shader() -> bool:
	if _pipeline.is_valid():
		return true
	var sf := load(SHADER_PATH) as RDShaderFile
	if sf == null:
		push_error("[GpuLodCompositor] load RDShaderFile 失败: " + SHADER_PATH)
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[GpuLodCompositor] compute 编译错误: " + (spirv.compile_error_compute if spirv != null else "null"))
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


# 6 × (MAX_PATCHES+1) RGBA32F, STORAGE|SAMPLING。零填充(末行 count=0 → 首帧坍缩无渲染, 安全)。
func _create_patch_tex() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = PATCH_TEX_W
	fmt.height = PATCH_TEX_H
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var bytes := PackedByteArray()
	bytes.resize(PATCH_TEX_W * PATCH_TEX_H * 16)   # 全 0
	# texture_create 第3参类型是 Array[PackedByteArray](每层一个), 非 bare PackedByteArray。
	# 零填充必需: 1-帧延迟下首帧读 read_idx 未写过 → META_ROW count=0 → 坍缩守卫生效(否则读显存垃圾绕过守卫渲染 NaN)。
	var layers: Array = [bytes]
	return _rd.texture_create(fmt, RDTextureView.new(), layers)


func _create_counter() -> RID:
	var bytes := PackedByteArray()
	bytes.resize(4)   # uint32 = 0
	return _rd.storage_buffer_create(4, bytes)


# 主线程(GpuPlanet._process)每帧调: 推相机/参数快照。
func set_frame_data(d: Dictionary) -> void:
	_mutex.lock()
	_frame_data = d
	_mutex.unlock()


func _render_callback(_effect_callback_type: int, _render_data: RenderData) -> void:
	_cb_count += 1   # 调试: 确认回调被调用
	if not _ready or not _pipeline.is_valid():
		return
	if _effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
		return
	_mutex.lock()
	var fd: Dictionary = _frame_data
	_mutex.unlock()
	if not fd.has("cam_pos"):
		return   # GpuPlanet 还没推(首帧)→ 跳过

	var write_idx: int = int(fd.get("write_idx", 0))   # GpuPlanet 主线程决定双缓冲写哪块

	# uniform sets(按 RID 经 UniformSetCacheRD 缓存; RID 稳定 → 首帧后命中缓存)
	if _uniform_set[write_idx] == null:
		var u_img := RDUniform.new()
		u_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_img.binding = 0
		u_img.add_id(_patch_tex[write_idx])
		var u_ctr := RDUniform.new()
		u_ctr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u_ctr.binding = 0
		u_ctr.add_id(_counter[write_idx])
		var s0 := UniformSetCacheRD.get_cache(_shader, 0, [u_img])
		var s1 := UniformSetCacheRD.get_cache(_shader, 1, [u_ctr])
		_uniform_set[write_idx] = [s0, s1]
	var sets: Array = _uniform_set[write_idx]

	# push constant 基底(level 字段[10] 每次 dispatch 覆盖)
	var max_level: int = int(fd["maxLevel"])
	var cam: Vector3 = fd["cam_pos"]
	var pcn: Vector3 = fd["planet_center"]
	var pc_base := PackedFloat32Array([
		cam.x, cam.y, cam.z, float(fd["radius"]),
		pcn.x, pcn.y, pcn.z, float(fd["maxHeight"]),
		float(fd["C_const"]), float(max_level), 0.0, float(MAX_PATCHES),
	])

	# 每个 dispatch 独立 compute_list(照搬 atmosphere_compositor 惯例): compute_list_end 提交时
	# 插屏障 → storage 写(counter 原子、imageStore)对下一个 list 可见。比 intra-list add_barrier 稳。
	_dispatch_one(sets, pc_base, -1.0, 1)                       # reset counter
	for lvl in range(max_level + 1):                            # per-level 遍历
		_dispatch_one(sets, pc_base, float(lvl), _groups_for_level(lvl))
	_dispatch_one(sets, pc_base, -2.0, 1)                       # metadata: count → patch 纹理末行
	# 纹理绑定由 GpuPlanet._process(主线程 set_shader_parameter)做, 这里只写。


func _dispatch_one(sets: Array, pc_base: PackedFloat32Array, level: float, groups: int) -> void:
	pc_base[10] = level   # consts.z = level
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, sets[0], 0)
	_rd.compute_list_bind_uniform_set(cl, sets[1], 1)
	_rd.compute_list_set_push_constant(cl, pc_base.to_byte_array(), pc_base.size() * 4)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()


static func _groups_for_level(level: int) -> int:
	var nodes := 20
	for i in range(level):
		nodes *= 4
	@warning_ignore("integer_division")
	return (nodes - 1) / WG + 1
