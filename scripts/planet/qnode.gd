# gdlint: disable=variable-name, max-line-length, private-access
## 四叉树 LOD 节点(移植 src/planet.js 的 QNode), 容器架构版。
## Qnode(Node3D 容器) 下挂一个 MeshInstance3D(本层 mesh); 细分时隐藏本层 mesh_inst、
## 显示 4 个子 Qnode; 合并反向。mesh_inst 与子 Qnode 是兄弟 → 隐藏 mesh_inst 不影响
## 子 Qnode 可见性, 绕过 Godot 的 visible 继承陷阱。
## 生命周期: Planet 用 qnode.tscn.instantiate() 创建, setup() 配置几何, queue_free() 销毁;
## mesh 更新只换 mesh_inst.mesh 资源(复用节点)。
##
## 合并宽限(merge cache): 不再细分时不立即删子树, 而是隐藏后暂存 MERGE_HOLD_SEC 秒;
## 期间若再次细分就原地复用(命中 → 跳过重新生成 patch), 避免在细分边界抖动时反复触发
## worker 任务(行走卡顿的主要来源之一)。超时未复用才真正释放。
@tool
class_name QNode
extends Node3D

const MERGE_HOLD_SEC := 1.0   # 合并宽限期(秒): 只需覆盖细分边界的亚秒级抖动。
# 过长(如 3s)会让持续移动时暂存(_retired)子树大量堆积, 每 LOD tick 的 _hide_subtree 递归
# 遍历这些暂存节点 → 遍历节点数膨胀、拖慢主线程。1s 既保留抗抖动, 又快速回收行走途中的暂存。

var planet  # Planet(弱类型避免循环声明顺序问题)
var A: Vector3
var B: Vector3
var C: Vector3
var level: int

var children: Variant = null  # null=叶, Array[4]=已分裂
var _retired: Variant = null  # null=无; 否则为暂存(隐藏未删)的子树 Array[4]
var _retire_expire: float = 0.0  # 暂存子树的过期时刻(秒, Time.get_ticks_msec/1000)
var mesh_inst: MeshInstance3D  # 本层 mesh(qnode.tscn 预设的子 MeshInstance3D)
var pending: bool = false
var cancelled: bool = false
var built_key: String = ""
var req_key: String = ""
var _patch_data: Dictionary = {}  # 缓存 patch 几何数据, 供 wireframe 切换时主线程在线/面间重建 ArrayMesh

var center_dir: Vector3
var center_world: Vector3
var edge_len: float
var bsphere_radius: float

var _qnode_scene: PackedScene  # _split 时实例化子用


# instantiate() 后由 Planet 调用: 配置几何 + 缓存预制体 + 绑定材质。
func setup(p, a: Vector3, b: Vector3, c: Vector3, lvl: int, qnode_scene: PackedScene) -> void:
	planet = p
	A = a
	B = b
	C = c
	level = lvl
	_qnode_scene = qnode_scene
	mesh_inst = get_node("MeshInstance3D")
	mesh_inst.name = "Mesh"
	mesh_inst.material_override = planet.material
	mesh_inst.visible = false
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


# 用生成好的 ArrayMesh 填充本层 mesh_inst(复用节点, 只换资源)。
func set_mesh(am: ArrayMesh, tri_count: int) -> void:
	mesh_inst.mesh = am
	mesh_inst.set_meta("triangles", tri_count)


# 三条边(AB, AC, BC)的缝合步长。Phase 1+ : 地形位移进 shader + 裙边盖缝 → strides 恒 [1,1,1],
# 不再需要 target_level_at(原主线程热点: 每 patch 3 次递归四叉树)。snap_edge 见 stride<=1 直接返回。
func compute_strides() -> Array:
	return [1, 1, 1]


# cam_pos: 行星本地系相机位置; frustum: 世界系 Plane[]; cam_moved: 相机是否移动; now: 当前秒
func select_lod(cam_pos: Vector3, frustum: Array, cam_moved: bool, now: float) -> void:
	var p: PlanetParams = planet.params
	var d: float = cam_pos.distance_to(center_world)
	if d >= p.nearRadius:
		var r := bsphere_radius + d * p.frustumMargin
		if not _sphere_in_frustum(frustum, center_world + planet.global_position, r):
			_hide_subtree()
			return

	# 预取环(want_prefetch, 外圈): 进入即后台生成子 patch, 但父层继续显示;
	# 显示环(want_show, 内圈): 子全就绪后才隐藏父、显示子。两环分离 → 子提前就绪, 消除 pop-in,
	# 并把生成峰值摊到"靠近过程"。环带同时充当合并迟滞: 在环内不退缓存。
	var want_prefetch: bool = level < p.maxLevel and d < edge_len * p.splitFactor * p.prefetchFactor
	if want_prefetch:
		_expire_retired(now)
		if children == null:
			if _retired != null:
				# 命中合并缓存: 原地复用暂存子树, 跳过重新生成 patch
				children = _retired
				_retired = null
			else:
				_split()
		var want_show: bool = d < edge_len * p.splitFactor
		var all_ready: bool = children[0].mesh_inst.mesh != null and children[1].mesh_inst.mesh != null and children[2].mesh_inst.mesh != null and children[3].mesh_inst.mesh != null
		if want_show and all_ready:
			mesh_inst.visible = false  # 隐藏本层 mesh(子 Qnode 是兄弟, 不受影响)
			for c in children:
				c.select_lod(cam_pos, frustum, cam_moved, now)
		else:
			# 预热(在预取环内, 或显示环但子未就绪): 提交缺失子 patch, 父保持显示、子隐藏。
			# 显示环内未就绪 → 前台请求(不节流, 显示必需); 仅预取环 → 预取请求(节流)。
			var req_is_prefetch: bool = not want_show
			for c in children:
				# 前景子(want_show 内, 显示必需)永不限流; 仅预取子(req_is_prefetch)走预算, 不抢前景。
				if c.mesh_inst.mesh == null and not c.pending and (not req_is_prefetch or planet.stride_budget_ok()):
					var ds: Array = c.compute_strides()
					planet.request_mesh(c, ds, _key(ds), req_is_prefetch)
			# level+2 预取(仅预取环): 对已就绪的子预生成它的子(孙辈), 全隐藏。
			# 相机进入子的 show 环时孙已就绪 → 不再按需生成 → 消除移动卡顿(= 你的"预取球提前算最高细分"思路)。
			# 仍受 stride 预算约束, 不会抢前景; 满了等下个 pass。
			if req_is_prefetch:
				for c in children:
					if c.mesh_inst.mesh != null and c.children == null and c.level < p.maxLevel:
						c._split()
					if c.children != null:
						for gc in c.children:
							if gc.mesh_inst.mesh == null and not gc.pending and planet.stride_budget_ok():
								var gds: Array = gc.compute_strides()
								planet.request_mesh(gc, gds, _key(gds), true)
			for c in children:
				c._hide_subtree()
			if mesh_inst.mesh == null and not pending:
				planet.request_mesh(self, [1, 1, 1], "1,1,1")
			if mesh_inst.mesh:
				mesh_inst.visible = true
				planet.count_node(self)
	else:
		# 远离: 子树退入合并缓存(隐藏暂存, 不立即删), 到期未复用才释放
		if children != null:
			_retire_children(now)
		_expire_retired(now)
		if mesh_inst.mesh == null:
			if not pending:
				var ds := compute_strides()
				planet.request_mesh(self, ds, _key(ds))
		elif cam_moved and not pending:
			var ds := compute_strides()
			var key := _key(ds)
			if built_key != key:
				planet.request_mesh(self, ds, key)
		if mesh_inst.mesh:
			mesh_inst.visible = true
			planet.count_node(self)


func _split() -> void:
	var ab := (A + B).normalized()
	var bc := (B + C).normalized()
	var ca := (C + A).normalized()
	var L := level + 1
	var tris := [[A, ab, ca], [ab, B, bc], [ca, bc, C], [ab, bc, ca]]
	children = []
	for i in range(4):
		var child: QNode = _qnode_scene.instantiate()
		child.name = "Qnode%d" % (i + 1)  # 子: Qnode1..Qnode4(相对父, 递归)
		add_child(child)  # 子 Qnode 挂父 Qnode 下(场景树=四叉树)
		child.set_owner(null)
		child.setup(planet, tris[i][0], tris[i][1], tris[i][2], L, _qnode_scene)
		children.append(child)


# 合并宽限: 隐藏子树并暂存(不释放、不取消 pending), 记过期时刻。
func _retire_children(now: float) -> void:
	for c in children:
		c._hide_subtree()
	_retired = children
	_retire_expire = now + MERGE_HOLD_SEC
	children = null


# 暂存子树到期且仍未再细分 → 真正释放(子树仍在场景树下, queue_free 连同其后代一并回收)。
func _expire_retired(now: float) -> void:
	if _retired != null and now >= _retire_expire:
		for c in _retired:
			c.dispose()
			c.queue_free()
		_retired = null


func _hide_subtree() -> void:
	if mesh_inst and mesh_inst.mesh:
		mesh_inst.visible = false
	if children != null:
		for c in children:
			c._hide_subtree()
	if _retired != null:
		for c in _retired:
			c._hide_subtree()


# 销毁前清理: 立即隐藏 + 取消 pending + 递归子树(含暂存)。节点本身由调用方 queue_free。
func dispose() -> void:
	_hide_subtree()
	if pending:
		cancelled = true
		pending = false
	if children != null:
		for c in children:
			c.dispose()
		children = null
	if _retired != null:
		for c in _retired:
			c.dispose()
		_retired = null


static func _key(ds: Array) -> String:
	return "%d,%d,%d" % [int(ds[0]), int(ds[1]), int(ds[2])]


# Godot get_frustum() 的 Plane 法线指向 frustum 外侧; distance_to(center) > 0 表示点在该面外侧。
# 球完全在某面外侧(被剔除) = distance > radius。所有面都不剔除 → 球与视锥相交。
static func _sphere_in_frustum(planes: Array, center: Vector3, radius: float) -> bool:
	for plane in planes:
		if plane.distance_to(center) > radius:
			return false
	return true
