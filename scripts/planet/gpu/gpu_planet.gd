# gdlint: disable=variable-name, max-line-length
## GPU 驱动行星 Phase 1: @tool Node3D。
##
## 渲染一颗被噪声位移的球面行星, 用 MultiMesh(20 instance, 每 icosahedron 根面一个) +
## 共享三角形 patch 网格 + patch 纹理(per-instance 面角点)。**固定全 LOD**: 无 compute 遍历、
## 无裁剪、无焊接 —— 先跑通 instance + 位移(设计文档 §13 Phase 1 验收)。
##
## 架构(前向兼容 Phase 2):
##   - patch 网格只取决于 patch_resolution(三角形 (u,v) 参数域), 与 radius/噪声无关 → 仅 res 变才重建。
##   - patch 纹理存 20 面角点(icosahedron 固定, 与参数无关) → 只建一次。
##   - 半径/高度/噪声全部走 shader uniform → 参数变更只重推 uniform(便宜)。
##   - Phase 2 起: patch 纹理由 compute 写入(可变叶数 + lodTrans + minmax), 本脚本 vertex shader 不变。
##
## 与旧 scripts/planet/planet.gd 零耦合: 新文件、新节点, 不 import/不修改旧实现。位移噪声与
## terrain.gdshader / terrain.gd::height_at 逐位一致(terrain_gpu.gdshader 复制了噪声块)。
@tool
class_name GpuPlanet
extends Node3D

const PATCH_TEX_SLOTS := 6           # 每 instance 6 texel(设计文档 §8.3 终极布局)
const DEFAULT_PATCH_RES := 64        # Phase 1 单 LOD 分辨率/边(越大越平滑越费)
const MM_NODE_NAME := "GpuPatchMM"

@export var params: PlanetParams:
	set(v):
		if params != null and params.is_connected("param_changed", _on_param_changed):
			params.disconnect("param_changed", _on_param_changed)
		params = v
		if params != null:
			params.param_changed.connect(_on_param_changed)
		_schedule_rebuild()

## 每根面的三角形 patch 边分辨率(单 LOD)。Phase 2 四叉树后改用 params.patchResolution/叶。
@export_range(8, 128, 1) var patch_resolution: int = DEFAULT_PATCH_RES:
	set(v):
		patch_resolution = v
		_schedule_rebuild()

var _mm: MultiMesh
var _mminst: MultiMeshInstance3D
var _mat: ShaderMaterial
var _patch_tex: ImageTexture
var _patch_mesh: ArrayMesh
var _mesh_res: int = -1
var _default_params: PlanetParams
var _dirty := false


func _ready() -> void:
	_build_all()
	_push_params()


func _on_param_changed(_key: String) -> void:
	# 参数变更只重推 uniform + 包围盒(patch 网格/纹理与参数无关)。便宜, 每帧多次也扛得住。
	_push_params()


func _schedule_rebuild() -> void:
	if _dirty:
		return
	_dirty = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_dirty = false
	_build_all()
	_push_params()


# 建全: patch 纹理(一次) + patch 网格(res 变才重建) + MultiMesh + 节点 + 材质(一次)。
func _build_all() -> void:
	if _patch_tex == null:
		_patch_tex = _build_patch_tex()
	if _patch_mesh == null or _mesh_res != patch_resolution:
		_patch_mesh = _build_patch_mesh(patch_resolution)
		_mesh_res = patch_resolution
		if _mm != null:
			_mm.mesh = _patch_mesh
	# 复用编辑器里已存在的运行时子节点(script 重载后成员变量清零但节点还在)。
	if _mminst != null and not is_instance_valid(_mminst):
		_mminst = null
	if _mminst == null:
		_mminst = get_node_or_null(MM_NODE_NAME)
	if _mminst == null:
		_mminst = MultiMeshInstance3D.new()
		_mminst.name = MM_NODE_NAME
		add_child(_mminst)
		_mminst.owner = null   # 运行时生成 → 不存盘、不显示在场景树持久层, 但编辑器视口照渲染
	if _mm == null:
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.mesh = _patch_mesh
		_mm.instance_count = GpuIco.FACE_COUNT
		for i in range(GpuIco.FACE_COUNT):
			_mm.set_instance_transform(i, Transform3D.IDENTITY)   # 位置全在 shader 算, transform 单位
		_mminst.multimesh = _mm
	if _mat == null:
		var sh: Shader = load("res://shaders/planet_gpu/terrain_gpu.gdshader")
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mminst.material_override = _mat


# 推全部 uniform(镜像 planet.gd _apply_params; 颜色用 shader 默认, 不推) + 包围盒 + patch 纹理。
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
	_mat.set_shader_parameter("u_patchTex", _patch_tex)
	# MultiMesh AABB = patch 网格小 AABB → 必须手动覆盖到行星包围盒, 否则被剔除看不见。
	var r_extent: float = p.radius + p.maxHeight * 1.2 + 1.0
	_mminst.custom_aabb = AABB(Vector3(-r_extent, -r_extent, -r_extent), Vector3(2.0 * r_extent, 2.0 * r_extent, 2.0 * r_extent))


func _effective_params() -> PlanetParams:
	if params != null:
		return params
	if _default_params == null:
		_default_params = PlanetParams.new()
	return _default_params


# ---- patch 纹理: 6 × FACE_COUNT RGBA32F, CPU 填 20 面角点(与参数无关, 一次) ----
static func _build_patch_tex() -> ImageTexture:
	var W: int = PATCH_TEX_SLOTS
	var H: int = GpuIco.FACE_COUNT
	var floats := PackedFloat32Array()
	floats.resize(W * H * 4)
	for fi in range(H):
		var corners: Array = GpuIco.face_corners(fi)
		var A: Vector3 = corners[0]
		var B: Vector3 = corners[1]
		var C: Vector3 = corners[2]
		var b: int = fi * W * 4
		# texel0: (A.xyz, face)  texel1: (B.xyz, lod=0)  texel2: (C.xyz, _)
		floats[b + 0] = A.x; floats[b + 1] = A.y; floats[b + 2] = A.z; floats[b + 3] = float(fi)
		floats[b + 4] = B.x; floats[b + 5] = B.y; floats[b + 6] = B.z; floats[b + 7] = 0.0
		floats[b + 8] = C.x; floats[b + 9] = C.y; floats[b + 10] = C.z; floats[b + 11] = 0.0
		# texel3: (ua=0,va=0,ub=1,vb=0)  level0 占满整面下三角
		floats[b + 12] = 0.0; floats[b + 13] = 0.0; floats[b + 14] = 1.0; floats[b + 15] = 0.0
		# texel4: (uc=0,vc=1,lodTransAB=0,lodTransBC=0)
		floats[b + 16] = 0.0; floats[b + 17] = 1.0; floats[b + 18] = 0.0; floats[b + 19] = 0.0
		# texel5: (minH,maxH,_,_)  Phase1 不用(无裁剪/LOD), 留 Phase2
		floats[b + 20] = 0.0; floats[b + 21] = 0.0; floats[b + 22] = 0.0; floats[b + 23] = 0.0
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBAF, floats.to_byte_array())
	return ImageTexture.create_from_image(img)


# ---- 共享三角形 patch 网格: n 细分, 顶点 (i,j) i+j<=n, uv=(i/n, j/n) ----
# 上三角 (i,j),(i+1,j),(i,j+1) 需 i+j<=n-1; 下三角 (i+1,j),(i+1,j+1),(i,j+1) 需 i+j<=n-2。
# 合计 n² 三角(与 qnode._split 同构)。绕序: patch-local CCW 映射到面 (A,B,C) 即外向(cull_back 可见)。
static func _build_patch_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var idmap: Dictionary = {}   # Vector2i -> int
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
