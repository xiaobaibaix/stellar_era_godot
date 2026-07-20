# gdlint: disable=variable-name, max-line-length, private-access
## 四叉树 LOD 节点(纯数据, RefCounted)。mesh 即单元架构: 不再持有 MeshInstance3D,
## 全场只有一个 _terrain_mesh(挂在 Planet 的 BodyMesh 下); 本节点只缓存几何(_surfaces)
## + 渲染状态(render_state), Planet._rebuild_merged_mesh 收集所有「自身渲染 + mesh 就绪」
## 的节点, 把它们的 _surfaces 拼成单个 ArrayMesh。
##
## render_state: 0=不渲染(被剔除/隐藏), 1=渲染自身 mesh(叶 或 子未就绪时的 fallback),
##               2=渲染子(递归)。状态翻转 → planet._mesh_dirty → 帧末统一重建合并 mesh,
##               把「每个 split/merge/完成事件立即 set_mesh」的尖刺摊到一帧一次。
##
## LOD 选择(移植 web 版):
##   1) 地平线剔除: 被行星本体挡在背面的 chunk 直接跳过。
##   2) 视锥剔除(近处 nearRadius 内不剔)。
##   3) 分裂/合并距离滞回 + 每帧分裂预算。
## 地形位移在顶点 shader 做 + 裙边盖缝 → 缝合步长恒 [1,1,1], 不需要 target_level_at。
class_name QNode
extends RefCounted

var planet  # Planet(弱类型避免循环声明顺序问题)
var A: Vector3
var B: Vector3
var C: Vector3
var level: int

var children: Variant = null  # null=叶, Array[4]=已分裂
var render_state: int = 0     # 0/1/2 见上; 替代旧 mesh_inst.visible
var mesh_ready: bool = false  # _patch_data/_surfaces 已就绪
var pending: bool = false
var cancelled: bool = false
var built_key: String = ""
var req_key: String = ""
var _patch_data: Dictionary = {}  # 缓存 patch 几何(verts/norms/cols/indices/tris)
var _surfaces: Array = []         # 缓存 surface 列表:[{prim, arrays, tris}, ...](非 wire 1 个, wire 2 个)
var tri_count: int = 0

var center_dir: Vector3
var center_world: Vector3
var edge_len: float
var bsphere_radius: float
# 地平线剔除: chunk 在球面上的角半径(三顶点方向到 center_dir 的最小 cos = 最大张角)
var horizon_cos_alpha: float = 1.0
var horizon_sin_alpha: float = 0.0


# 由 Planet 调用: 配置几何 + 预计算剔除数据(纯数据, 无节点操作)。
func setup(p, a: Vector3, b: Vector3, c: Vector3, lvl: int) -> void:
	planet = p
	A = a
	B = b
	C = c
	level = lvl
	var R: float = planet.params.radius
	center_dir = (A + B + C).normalized()
	center_world = center_dir * R
	edge_len = A.distance_to(B) * R
	# 包围球: 单位球角点*R + 地形高度 + 裙边
	var wa := A * R
	var wb := B * R
	var wc := C * R
	var spread: float = maxf(center_world.distance_to(wa), maxf(center_world.distance_to(wb), center_world.distance_to(wc)))
	var chord: float = A.distance_to(B)
	var skirt: float = minf(chord * R * 0.6 + chord * chord * R * 3.0, R * 0.4)
	bsphere_radius = spread + planet.params.maxHeight * 2.0 + skirt + 1.0
	# 地平线剔除角半径(移植 planet.js QNode 构造): 三顶点方向到 center_dir 的最小点积 = 最大张角
	var min_cos: float = minf(center_dir.dot(A), minf(center_dir.dot(B), center_dir.dot(C)))
	horizon_cos_alpha = min_cos
	horizon_sin_alpha = sqrt(maxf(0.0, 1.0 - min_cos * min_cos))


# 渲染状态翻转 → 置 planet._mesh_dirty(帧末统一重建合并 mesh)。
func _set_state(s: int) -> void:
	if render_state != s:
		render_state = s
		planet._mesh_dirty = true


# 存 Planet._gen_surface_list 生成好的 surface 列表(重建合并 mesh 时复用, 避免重算)。
func set_surfaces(surfs: Array, tris: int) -> void:
	_surfaces = surfs
	tri_count = tris
	mesh_ready = true


# 缝合步长: 地形位移进 shader + 裙边盖缝 → 恒 [1,1,1]。
func compute_strides() -> Array:
	return [1, 1, 1]


# cam_pos: LOD 细分距离用的聚焦目标(角色/lod_target)位置; cull_pos: 可见性剔除用的【真实渲染相机】位置;
# frustum: 世界系 Plane[]; cam_moved: 是否移动; _now: 未用。
# cull: 是否做剔除(地平线+视锥)。编辑器由 Planet.update 传 false → 只跑距离 LOD 细分, 不隐藏任何 chunk。
# 移植 planet.js QNode.selectLOD: 地平线剔除 → 视锥剔除 → 分裂/合并滞回(带预算) → 定 render_state。
func select_lod(cam_pos: Vector3, cull_pos: Vector3, frustum: Array, cam_moved: bool, _now: float, cull: bool = true) -> void:
	var p: PlanetParams = planet.params
	# 1) 地平线剔除(用渲染相机 cull_pos): 行星本体背面的 chunk 直接跳过(整棵子树不渲染)
	if cull and p.horizonCulling and _is_below_horizon(cull_pos):
		_set_state(0)
		return
	var d: float = cam_pos.distance_to(center_world)
	# 2) 视锥剔除(近处不剔, 避免环视时背后补细分)
	if cull and d >= p.nearRadius:
		var r := bsphere_radius + d * p.frustumMargin
		if not _sphere_in_frustum(frustum, center_world + planet.global_position, r):
			_set_state(0)
			return
	# 3) 分裂/合并【距离滞回】
	var split_t: float = edge_len * p.splitFactor
	var want_split: bool = level < p.maxLevel and d < split_t
	var want_merge: bool = d > split_t * p.mergeHysteresis
	if want_split and children == null:
		# 每帧分裂预算: 配额用完则本帧退化为叶(父层暂显), 下帧再试
		if not planet.split_budget_ok():
			_render_leaf()
			return
		_split()
	elif want_merge and children != null:
		_merge()
	# 死区(既不分裂也不合并): 维持现状

	if children != null:
		_render_interior(cam_pos, cull_pos, frustum, cam_moved, cull)
	else:
		_render_leaf()


# 渲染为叶节点(自身 mesh); mesh 未就绪则请求(异步生成)。strides 恒 [1,1,1] → 移动时无需重请求。
func _render_leaf() -> void:
	_set_state(1)
	if not mesh_ready and not pending:
		planet.request_mesh(self, [1, 1, 1], "1,1,1")


# 渲染为内部节点: 4 子全就绪 → render_state=2(递归子); 否则请求缺失子 + 自身兜底(state=1)消除 pop-in。
func _render_interior(cam_pos: Vector3, cull_pos: Vector3, frustum: Array, cam_moved: bool, cull: bool = true) -> void:
	var all_ready: bool = (
		children[0].mesh_ready
		and children[1].mesh_ready
		and children[2].mesh_ready
		and children[3].mesh_ready
	)
	if all_ready:
		_set_state(2)  # 自身不渲染, 由收集时递归子
		for c in children:
			c.select_lod(cam_pos, cull_pos, frustum, cam_moved, 0.0, cull)
		return
	# 子未就绪: 请求缺失子 patch, 隐藏子, 自身兜底渲染
	for c in children:
		if not c.mesh_ready and not c.pending:
			planet.request_mesh(c, [1, 1, 1], "1,1,1")
		c._set_state(0)
	_set_state(1)
	if not mesh_ready and not pending:
		planet.request_mesh(self, [1, 1, 1], "1,1,1")


# 地平线剔除(移植 planet.js QNode._isBelowHorizon): chunk 是否在行星本体背面被完全遮挡。
func _is_below_horizon(cam_pos: Vector3) -> bool:
	var R: float = planet.params.radius
	var H: float = planet.params.maxHeight
	var cam_dist: float = cam_pos.length()
	if cam_dist <= R:
		return false  # 相机在行星内部 → 全可见
	var cos_cam_chunk: float = cam_pos.dot(center_dir) / cam_dist
	if cos_cam_chunk >= horizon_cos_alpha:
		return false  # 相机在 chunk 角范围内 → 可见
	# 总地平线 = 相机地平线 + 地形抬升(cos(a+b) = cos a cos b - sin a sin b)
	var cos_cam_hor: float = R / cam_dist
	var sin_cam_hor: float = sqrt(maxf(0.0, 1.0 - cos_cam_hor * cos_cam_hor))
	var cos_ter: float = R / (R + H)
	var sin_ter: float = sqrt(maxf(0.0, 1.0 - cos_ter * cos_ter))
	var cos_tot_hor: float = cos_cam_hor * cos_ter - sin_cam_hor * sin_ter
	# chunk 最近边(cos(a-b) = cos a cos b + sin a sin b)
	var sin_ang: float = sqrt(maxf(0.0, 1.0 - cos_cam_chunk * cos_cam_chunk))
	var cos_near: float = cos_cam_chunk * horizon_cos_alpha + sin_ang * horizon_sin_alpha
	return cos_near <= cos_tot_hor


func _split() -> void:
	var ab := (A + B).normalized()
	var bc := (B + C).normalized()
	var ca := (C + A).normalized()
	var tris := [[A, ab, ca], [ab, B, bc], [ca, bc, C], [ab, bc, ca]]
	children = []
	for i in range(4):
		var child := QNode.new()
		child.setup(planet, tris[i][0], tris[i][1], tris[i][2], level + 1)
		children.append(child)
	planet._tree_changed = true   # 通知 Planet 本 pass 发生结构变化 → 保持 select_lod 继续跑到稳定
	planet._mesh_dirty = true


# 合并(移植 planet.js QNode._merge): 置空 children(RefCounted 自动释放)。滞回死区保证不会立刻再分裂 → 无 churn。
func _merge() -> void:
	for c in children:
		c.dispose()
	children = null
	planet._tree_changed = true   # 通知 Planet 本 pass 发生结构变化 → 保持 select_lod 继续跑到稳定
	planet._mesh_dirty = true


# 销毁前清理: 取消 pending + 递归子树(RefCounted 引用释放即自动回收, 无需 queue_free)。
func dispose() -> void:
	render_state = 0
	if pending:
		cancelled = true
		pending = false
	if children != null:
		for c in children:
			c.dispose()
		children = null


static func _key(ds: Array) -> String:
	return "%d,%d,%d" % [int(ds[0]), int(ds[1]), int(ds[2])]


# Godot get_frustum() 的 Plane 法线指向 frustum 外侧; distance_to(center) > 0 表示点在该面外侧。
# 球完全在某面外侧(被剔除) = distance > radius。所有面都不剔除 → 球与视锥相交。
static func _sphere_in_frustum(planes: Array, center: Vector3, radius: float) -> bool:
	for plane in planes:
		if plane.distance_to(center) > radius:
			return false
	return true
