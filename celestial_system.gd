## 递归天体系统节点。
##
## 多顶层: 多个恒星系并列挂 Main 下(各自独立 sim)。第一个顶层 = main_top 管全局协调
##       (浮动原点 / 相机 / HUD / 跨顶层聚焦 / SOI / 轨道预测 / 尾迹 / 属性面板)。
## 操作: TAB 聚焦 / [/] 调速 / F2 SOI / F3 轨迹预测 / F4 尾迹 / 左键点击 / 滚轮缩放。
## SOI: 引力作用范围(F2 线框, discard 背面)。子系统=Hill球 r=a·(m/(3M))^(1/3); 顶层=系统边界。
## 轨迹预测(F3): 从天体当前 位置/速度/受力(leapfrog 积分副本)预测未来轨迹;
##       闭合(回到起点)就画整圈, 否则画一段。定期重算 + 改 mass 重算。
## 尾迹(F4): 天体走过的真实路径, 每帧追加, 动态反映真实运动。
class_name CelestialSystem
extends Node3D

const _SOI_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;
uniform vec4 line_color;
void fragment() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	vec3 radial = normalize(VERTEX - center);
	if (dot(radial, normalize(-VERTEX)) < 0.0) discard;
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a;
}
"""

static var main_top: CelestialSystem = null
static var global_ox: float = 0.0
static var global_oy: float = 0.0
static var global_oz: float = 0.0

@export_group("物理(本层)")
@export var G: float = 1.0
@export var softening: float = 10.0
@export_range(0.0, 2.0, 0.01) var dt_fixed: float = 0.5
@export_range(1, 8, 1) var substeps: int = 2
@export_range(0.0, 10.0, 0.1) var sim_speed: float = 1.0

@export_group("仅顶层")
@export var orbit_camera: OrbitCamera
## 轨迹预测线(F3)重算间隔(帧)。解析椭圆(每条仅 192 次三角运算)极廉价 → 默认 1(每帧)
## = 零滞后最丝滑。天体很多时可调大省 CPU。
@export_range(1, 60, 1) var orbit_predict_interval: int = 1
## SOI 等势面 mesh 重建间隔(帧)。每顶点要步长扫描+二分求 η=1 半径, 比解析椭圆贵 → 默认 2。
## 天体多/卡顿可调大; 1 = 每帧重建(最丝滑)。
@export_range(1, 30, 1) var soi_rebuild_interval: int = 3
## 远处天体在屏幕上只剩几个像素点不到 → 点击半径随相机距离动态扩大,
## 保证碰撞球在屏幕上至少占 pick_min_pixels 像素(相机越远, 世界半径越大)。
@export_range(2, 64, 1) var pick_min_pixels: int = 12

var sim: NBodySystem
var members: Array[Celestial] = []
var dominant: Celestial = null
var child_systems: Array[CelestialSystem] = []
var child_proxy: Dictionary = {}
var _lights: Array[OmniLight3D] = []

var parent_system: CelestialSystem = null
var _is_main_top: bool = false

var _hill_radius: float = 0.0

var _bcx: float = 0.0
var _bcy: float = 0.0
var _bcz: float = 0.0

# 基座速度(世界 double): 子系统基座在父系统中的速度, 沿链累加。
# 顶层基座不动(_bcx 取自 global_position 固定) → _bvx=0。用于动态 SOI 移交时换算局部速度。
var _bvx: float = 0.0
var _bvy: float = 0.0
var _bvz: float = 0.0

# 动态 SOI 边界 hysteresis: 进入需 <IN×Hill, 逃出需 >OUT×Hill; 中间死区防抖动。
const _SOI_HYSTERESIS_IN: float = 0.9
const _SOI_HYSTERESIS_OUT: float = 1.1

# 解析轨道椭圆的采样段数(移植 web ORBIT_SEG)。越大越圆滑, 192 已目测完美闭合。
const _ORBIT_SEG: int = 192

var _hud: Label = null
var focus_idx: int = 0
var _last_focus_idx: int = -1
var _focus_list: Array = []

var _show_soi: bool = false
var _soi_spheres: Array[MeshInstance3D] = []
var _soi_targets: Array[CelestialSystem] = []
var _soi_visual: MeshInstance3D = null     # 本系统自带的 SOI 节点(预制体)
var _soi_rebuild_counter: int = 9999       # 等势面 mesh 限频计数器(初值大→首帧强制重建一次)
var _trails_container: Node3D = null       # 预制体 Trails 容器(代码生成的拖尾节点挂此, 和天体并列)
var _orbits_container: Node3D = null       # 预制体 Orbits 容器(代码生成的轨道节点挂此, 和天体并列)

# 轨迹预测(数值积分, F3): 每个非 dominant 天体一条预测线, 动态更新
var _show_orbit: bool = true
var _orbit_rings: Array[MeshInstance3D] = []
var _orbit_targets: Array[Celestial] = []        # 每条预测线对应的天体
var _predict_data: Dictionary = {}               # Celestial -> PackedVector3Array(世界预测轨迹)
var _predict_counter: int = 0

# 尾迹(F4): 天体走过的真实路径
var _show_trail: bool = true
var _trail_mesh: MeshInstance3D = null

var _editor_title: Label = null
var _mass_spin: SpinBox = null
var _radius_spin: SpinBox = null
var _color_pick: ColorPickerButton = null
var _editor_syncing: bool = false

var _clicking: bool = false
var _click_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	sim = NBodySystem.new(G, softening)
	parent_system = get_parent() as CelestialSystem
	_collect()
	# 预制体 SOI 节点: 设单位球 mesh + 材质(运行时只更新 scale/位置)。
	_soi_visual = get_node_or_null("SOI") as MeshInstance3D
	if _soi_visual != null:
		_soi_visual.mesh = _make_wireframe_sphere(1.0, 24, 12)
		_soi_visual.material_override = _make_soi_material(self)
	# 预制体容器: 代码生成的 trail/orbit 节点挂此(和天体并列, 进出系统时增删)。
	_trails_container = get_node_or_null("Trails")
	_orbits_container = get_node_or_null("Orbits")
	_init_physics()
	if parent_system == null:
		var gp: Vector3 = global_position
		_bcx = gp.x
		_bcy = gp.y
		_bcz = gp.z
		if main_top == null or not is_instance_valid(main_top):
			main_top = self
		if main_top == self:
			_is_main_top = true
			# main_top(容器) 若未指定 orbit_camera, 自动找场景里的 OrbitCamera(TAB 聚焦/相机跟随需要)。
			if orbit_camera == null and get_parent() != null:
				for c in get_parent().get_children():
					var oc := c as OrbitCamera
					if oc != null:
						orbit_camera = oc
						break
			_acquire_ui()
			call_deferred("_resolve_initial_ownership_all")
			call_deferred("_collect_focus_all")
			call_deferred("_build_soi_visuals_all")
			call_deferred("_build_celestial_visuals_all")
			call_deferred("_build_orbit_visuals_all")


# 获取 main.tscn 的 UI 节点引用(HUD/编辑器, 全局只一份, 非 CelestialSystem 预制体子节点)。
# UI 结构在编辑器搭好, 运行时只更新内容(Label.text / SpinBox.value / ColorPicker.color)。
func _acquire_ui() -> void:
	var ui_root: Node = get_parent()
	if ui_root == null:
		return
	_hud = ui_root.get_node_or_null("HUDLayer/HUD") as Label
	var editor: PanelContainer = ui_root.get_node_or_null("EditorLayer/Editor") as PanelContainer
	if editor == null:
		return
	_editor_title = editor.get_node_or_null("Margin/VBox/Title") as Label
	_mass_spin = editor.get_node_or_null("Margin/VBox/MassRow/SpinBox") as SpinBox
	_radius_spin = editor.get_node_or_null("Margin/VBox/RadiusRow/SpinBox") as SpinBox
	_color_pick = editor.get_node_or_null("Margin/VBox/ColorRow/ColorPicker") as ColorPickerButton
	if _mass_spin != null:
		_mass_spin.value_changed.connect(_on_mass_changed)
	if _radius_spin != null:
		_radius_spin.value_changed.connect(_on_radius_changed)
	if _color_pick != null:
		_color_pick.color_changed.connect(_on_color_changed)
	_sync_editor_from_focus()


func _collect() -> void:
	for c in get_children():
		if c is Celestial:
			members.append(c)
			if c.is_dominant and dominant == null:
				dominant = c
		elif c is CelestialSystem:
			child_systems.append(c)
		elif c is OmniLight3D:
			_lights.append(c)


func _init_physics() -> void:
	if dominant == null and not members.is_empty():
		dominant = members[0]
	if dominant != null:
		var db := Body.new(dominant.name, dominant.mass)
		db.type = dominant.type
		db.radius = dominant.radius
		db.color = dominant.color
		db.set_pos(0.0, 0.0, 0.0)
		sim.add(db)
		dominant.body = db
		dominant.owner_system = self
		var idx := 0
		for c in members:
			if c == dominant:
				continue
			var rel := c.position - dominant.position
			var dist: float = rel.length()
			if dist < 1.0:
				dist = 2000.0 + float(idx) * 1000.0
			var phase: float = atan2(rel.z, rel.x)
			var b: Body = sim.add_orbiting(db, {
				"mass": c.mass, "dist": dist, "phase": phase,
				"inclination": 0.25 if c.type == "moon" else 0.0,
				"name": c.name, "type": c.type,
			})
			b.radius = c.radius
			b.color = c.color
			c.body = b
			c.owner_system = self
			idx += 1
		var sidx := 0
		for sub in child_systems:
			var srel := sub.position - dominant.position
			var sdist: float = srel.length()
			if sdist < 1.0:
				sdist = 5000.0 + float(sidx) * 4000.0
			var sphase: float = atan2(srel.z, srel.x)
			var proxy: Body = sim.add_orbiting(db, {
				"mass": float(sub.get_total_mass()), "dist": sdist,
				"phase": sphase, "name": sub.name, "type": "system",
			})
			child_proxy[sub] = proxy
			var msub: float = float(sub.get_total_mass())
			sub._hill_radius = sdist * pow(msub / (3.0 * dominant.mass), 1.0 / 3.0)
			sidx += 1
	elif not child_systems.is_empty():
		# 顶层"星系群": 无 dominant, 各 child_system 作质点 N 体互绕(互相制约; 双星 = N=2 特例)。
		_init_cluster_physics()
	if parent_system == null:
		sim.zero_momentum()
		_hill_radius = _compute_top_boundary()


## 顶层星系群初始化(无 dominant): 各 child_system 作质点放入本层 sim, 两两引力互绕。
## 每个质点绕群质心给切向速度 → 互相束缚。双星(N=2)用精确二体圆速度; 多体取质心圆速度 0.6 倍(略偏心)。
func _init_cluster_physics() -> void:
	var total_mass := 0.0
	var bx := 0.0
	var by := 0.0
	var bz := 0.0
	for sub in child_systems:
		var ms: float = float(sub.get_total_mass())
		bx += sub.position.x * ms
		by += sub.position.y * ms
		bz += sub.position.z * ms
		total_mass += ms
	if total_mass <= 0.0:
		return
	bx /= total_mass
	by /= total_mass
	bz /= total_mass
	var is_binary: bool = child_systems.size() == 2
	for sub in child_systems:
		var ms: float = float(sub.get_total_mass())
		var rx: float = sub.position.x - bx
		var ry: float = sub.position.y - by
		var rz: float = sub.position.z - bz
		var ri: float = sqrt(rx * rx + ry * ry + rz * rz)
		if ri < 1.0:
			rx = 5000.0
			ri = 5000.0
		var speed: float
		if is_binary:
			# 精确二体圆速度: v_i = √(G·m_other² / (M·d)), d = 2·ri(质心对称)
			var m_other: float = total_mass - ms
			var d: float = ri * 2.0
			speed = sqrt(G * m_other * m_other / (total_mass * d))
		else:
			speed = sqrt(G * total_mass / ri) * 0.6
		# xz 平面切向方向 (-rz, 0, rx) 归一化
		var tx: float = -rz
		var tz: float = rx
		var tl: float = sqrt(tx * tx + tz * tz)
		if tl < 1e-9:
			tx = 0.0
			tz = 1.0
			tl = 1.0
		var proxy := Body.new(sub.name, ms)
		proxy.type = "system"
		proxy.set_pos(rx, ry, rz)
		proxy.set_vel(tx / tl * speed, 0.0, tz / tl * speed)
		sim.add(proxy)
		child_proxy[sub] = proxy
		# 子系统在群里的 Hill: a·(m/(3·M_total))^(1/3)
		sub._hill_radius = ri * pow(ms / (3.0 * total_mass), 1.0 / 3.0)


## 顶层边界(画群 SOI / 判逃逸用): 有 dominant → 最远成员到 dominant ×1.5;
## 无 dominant(星系群) → 最远质点到群质心 ×1.5。
func _compute_top_boundary() -> float:
	var max_d: float = 0.0
	if dominant != null:
		for c in members:
			if c == dominant:
				continue
			max_d = max(max_d, float((c.position - dominant.position).length()))
		for sub in child_systems:
			max_d = max(max_d, float((sub.position - dominant.position).length()))
	else:
		var tm := 0.0
		var bx := 0.0
		var by := 0.0
		var bz := 0.0
		for sub in child_systems:
			var ms: float = float(sub.get_total_mass())
			bx += sub.position.x * ms
			by += sub.position.y * ms
			bz += sub.position.z * ms
			tm += ms
		if tm > 0.0:
			bx /= tm
			by /= tm
			bz /= tm
		for sub in child_systems:
			var dx: float = sub.position.x - bx
			var dy: float = sub.position.y - by
			var dz: float = sub.position.z - bz
			max_d = max(max_d, sqrt(dx * dx + dy * dy + dz * dz))
	return max_d * 1.5


func get_total_mass() -> float:
	var m := 0.0
	for c in members:
		m += c.mass
	for sub in child_systems:
		m += sub.get_total_mass()
	return m


func _get_all_tops() -> Array[CelestialSystem]:
	var tops: Array[CelestialSystem] = []
	var p: Node = get_parent()
	if p != null:
		for c in p.get_children():
			if c is CelestialSystem:
				var cs: CelestialSystem = c
				if cs.parent_system == null:
					tops.append(cs)
	return tops


func _physics_process(_delta: float) -> void:
	if not _is_main_top:
		return
	_frame()


func _frame() -> void:
	var tops: Array[CelestialSystem] = _get_all_tops()
	for t in tops:
		t._step_recursive()
	# 每帧重算 Hill: SOI 随轨道位置动态变化(圆轨道不变; 椭圆/多体/rogue 子系统随 sdist 变)。
	_recompute_hill_all()
	if not _focus_list.is_empty():
		var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
		global_ox = fc._wx
		global_oy = fc._wy
		global_oz = fc._wz
	# 动态 SOI(Step3): 按当前 Hill 球归属跨系统移交天体(逃出→提升到父, 进入→被捕获)。
	# 在渲染前完成, 使本帧渲染直接用新归属。世界坐标驱动, 不依赖浮动原点。
	_update_dynamic_soi()
	for t in tops:
		t._render_recursive(global_ox, global_oy, global_oz)
		t._update_soi(global_ox, global_oy, global_oz)
	# 轨迹预测: 每 30 帧重算一次(积分开销), 每帧用缓存画
	_predict_counter += 1
	if _predict_counter >= orbit_predict_interval or _predict_data.is_empty():
		_predict_counter = 0
		_compute_predictions()
	_update_orbit(global_ox, global_oy, global_oz)
	_update_trail_mesh(global_ox, global_oy, global_oz)
	_update_camera_and_hud()


func _step_recursive() -> void:
	var dt := dt_fixed * sim_speed
	var nsub: int = max(substeps, 1)
	for _i in range(nsub):
		sim.step(dt / float(nsub))
	for c in members:
		if c.body == null:
			continue
		c._wx = _bcx + c.body.px
		c._wy = _bcy + c.body.py
		c._wz = _bcz + c.body.pz
		c._wvx = _bvx + c.body.vx
		c._wvy = _bvy + c.body.vy
		c._wvz = _bvz + c.body.vz
		# 拖尾存相对父级(dominant)的局部位置 → 显示绕中心的轨道形状, 非全局螺旋。
		var ref_c: Celestial = _trail_reference(c)
		var trx := 0.0
		var tr_y := 0.0
		var tr_z := 0.0
		if ref_c != null:
			trx = ref_c._wx
			tr_y = ref_c._wy
			tr_z = ref_c._wz
		var rel := Vector3(c._wx - trx, c._wy - tr_y, c._wz - tr_z)
		if c._trail.is_empty() or (c._trail.back() as Vector3).distance_to(rel) > max(c.radius * 0.3, 5.0):
			c._trail.append(rel)
			if c._trail.size() > 400:
				c._trail.remove_at(0)
	for sub in child_systems:
		var pb: Body = child_proxy[sub]
		sub._bcx = _bcx + pb.px
		sub._bcy = _bcy + pb.py
		sub._bcz = _bcz + pb.pz
		sub._bvx = _bvx + pb.vx
		sub._bvy = _bvy + pb.vy
		sub._bvz = _bvz + pb.vz
		sub._step_recursive()


func _render_recursive(ox: float, oy: float, oz: float) -> void:
	if dominant != null and not _lights.is_empty():
		var lx: float = dominant._wx - ox
		var ly: float = dominant._wy - oy
		var lz: float = dominant._wz - oz
		for l in _lights:
			(l as Node3D).global_position = Vector3(lx, ly, lz)
	for c in members:
		if c.body == null:
			continue
		(c as Node3D).global_position = Vector3(c._wx - ox, c._wy - oy, c._wz - oz)
	for sub in child_systems:
		sub._render_recursive(ox, oy, oz)


func _update_soi(ox: float, oy: float, oz: float) -> void:
	if not _show_soi:
		return
	for i in range(_soi_spheres.size()):
		_soi_spheres[i].visible = true
		_soi_spheres[i].global_position = Vector3.ZERO
	_soi_rebuild_counter += 1
	if _soi_rebuild_counter >= soi_rebuild_interval:
		_soi_rebuild_counter = 0
		_rebuild_soi_meshes_now()


# 立即重建所有 SOI 的等势面 mesh(限频计数器到点 / reparent 后强制刷新 共用)。
# 顶点已烤渲染坐标(T 世界位 - 浮动原点), 节点 global_position 保持 ZERO 抵消容器场景位。
func _rebuild_soi_meshes_now() -> void:
	for i in range(_soi_spheres.size()):
		var sph: MeshInstance3D = _soi_spheres[i]
		var tgt: CelestialSystem = _soi_targets[i]
		if not is_instance_valid(sph) or tgt == null or tgt.dominant == null:
			continue
		var sources: Array[Celestial] = []
		_collect_perturbers(tgt, sources)
		sph.global_position = Vector3.ZERO
		sph.mesh = _make_potential_surface_mesh(tgt.dominant, sources,
			global_ox, global_oy, global_oz, 8, 4, tgt._hill_radius)


# ===================== 动态 SOI(Step3) =====================
# 天体从属关系由运行时 Hill 球归属决定, 不再固定于编辑器层级。
# 每帧扫描每个非主导叶子天体: 逃出当前系统 Hill(×OUT)→提升到父系统;
# 落入某子系统 Hill(×IN)→被该子系统捕获。两侧 hysteresis 之间为死区, 防边界抖动。
# 移交 = 在 members/sim/场景树之间搬天体, 用世界位速换算到新系统局部坐标。
func _update_dynamic_soi() -> void:
	var changed := false
	for t in _get_all_tops():
		if _scan_system_soi(t):
			changed = true
	if changed:
		_after_reparent()


func _scan_system_soi(sys: CelestialSystem) -> bool:
	var changed := false
	var snap: Array[Celestial] = []
	snap.assign(sys.members)
	for c in snap:
		if c == sys.dominant or c.body == null:
			continue
		var desired: CelestialSystem = _resolve_desired_owner(c)
		if desired != null and desired != c.owner_system:
			_reparent_celestial(c, c.owner_system, desired)
			changed = true
	# 子系统(child_system)动态归属: rogue 子系统进某星 Hill → 被捕获回行星系; 飞出父 Hill → 上抛。
	# 与 member 移交同构, 操作 child_proxy(_reparent_subsystem)。实现 S-type⇄P-type 运行时切换。
	var sub_snap: Array[CelestialSystem] = []
	sub_snap.assign(sys.child_systems)
	for sub in sub_snap:
		var desired_sub: CelestialSystem = _resolve_desired_owner_sub(sub)
		if desired_sub != null and desired_sub != sub.parent_system:
			_reparent_subsystem(sub, sub.parent_system, desired_sub)
			changed = true
	# 递归用快照(上面子系统移交可能改了 sys.child_systems, 不能直接迭代)。
	var rec_snap: Array[CelestialSystem] = []
	rec_snap.assign(sys.child_systems)
	for sub in rec_snap:
		if _scan_system_soi(sub):
			changed = true
	return changed


# 决定子系统 sub 应属哪个系统(与 _resolve_desired_owner 对应, 对象是 child_system):
#  - 逃出: sub 到当前父 dominant 距离 > 父 Hill×OUT → 上抛到祖父。
#  - 捕获: 否则从当前父起向下找更深包含者(rogue 子系统进某星 Hill → 被捕获为该星行星系)。
# 顶层群(无 dominant)的子系统只做捕获判定(群无 Hill; rogue 在群里受多源引力)。
func _resolve_desired_owner_sub(sub: CelestialSystem) -> CelestialSystem:
	var cur: CelestialSystem = sub.parent_system
	if cur == null or not cur.child_proxy.has(sub):
		return null
	var pb: Body = cur.child_proxy[sub]
	var px: float = cur._bcx + pb.px
	var py: float = cur._bcy + pb.py
	var pz: float = cur._bcz + pb.pz
	# 上抛/捕获统一等势面 η + IN/OUT 迟滞 + NaN 防御(见 _resolve_desired_owner 注释)。
	if cur.dominant != null and cur.parent_system != null and cur._hill_radius > 0.0:
		if _escaped_from(cur, px, py, pz):
			return _capture_descend(cur.parent_system, px, py, pz, sub)
	return _capture_descend(cur, px, py, pz, sub)


# 决定天体 c 应属哪个系统(同一顶层内), 两侧 hysteresis:
#  - 逃出: c 到当前主导距离 > 当前 Hill×OUT → 离开当前系统, 从父起向下找捕获目标。
#  - 捕获: 否则从当前系统起向下找更深的包含者(顶层成员可被行星 Hill 捕获)。
func _resolve_desired_owner(c: Celestial) -> CelestialSystem:
	var cur: CelestialSystem = c.owner_system
	var px: float = c._wx
	var py: float = c._wy
	var pz: float = c._wz
	# 上抛/捕获统一等势面 η + IN/OUT 迟滞(死区 η∈[0.9,1.1] 不翻转, 防 reparent 震荡闪烁)。
	# _escaped_from 含 NaN 防御: 物理发散时不上抛, 斩断 NaN→翻转恶性循环。
	if cur.parent_system != null and cur.dominant != null and cur._hill_radius > 0.0:
		if _escaped_from(cur, px, py, pz):
			return _capture_descend(cur.parent_system, px, py, pz)
	return _capture_descend(cur, px, py, pz)


# 从 start 向下找包含点 (px,py,pz) 的最深子系统(含 start 自身)。
# 仅当到子系统主导距离 < 子系统 Hill×IN 才下钻(捕获阈值)。
func _capture_descend(start: CelestialSystem, px: float, py: float, pz: float, exclude: CelestialSystem = null) -> CelestialSystem:
	# 椭球 Roche lobe 判定: sub 在 dominant 的椭球作用区内才下钻(朝群质心=伴星方向收尖,
	# 随相位转; 单恒星系退化为球)。动力学正确(L1/L2 稳定区), 区别于瞬时引力比(对双星成员错)。
	# exclude: 子系统归属判定时跳过自身(其 dominant 恰在自身位 → 距离0 误判自我捕获)。
	var s: CelestialSystem = start
	while true:
		var nxt: CelestialSystem = null
		for sub in s.child_systems:
			if sub == exclude or sub.dominant == null or sub._hill_radius <= 0.0:
				continue
			if _inside_potential_surface(sub, px, py, pz, _SOI_HYSTERESIS_IN):
				nxt = sub
				break
		if nxt == null:
			return s
		s = nxt
	return s   # 不可达; 满足 GDScript 全路径返回检查


# 把天体 c 从 from 系统移交给 to 系统: 摘旧 Body, 用世界位速在 to 里建新 Body(局部坐标)。
func _reparent_celestial(c: Celestial, from: CelestialSystem, to: CelestialSystem) -> void:
	# 1) 世界位/速(本帧 _step_recursive 已写)
	var wx: float = c._wx
	var wy: float = c._wy
	var wz: float = c._wz
	var vx: float = c._wvx
	var vy: float = c._wvy
	var vz: float = c._wvz
	# 2) 从 from 摘除(members + sim body + 场景树节点)
	from.members.erase(c)
	_trail_container_for(c)._remove_visuals_for(c)
	if c.body != null:
		from.sim.bodies.erase(c.body)
	if c.get_parent() == from:
		from.remove_child(c)
	# 3) 在 to 里用局部坐标(世界 − to 基座位/速)建新 Body
	var nb := Body.new(c.name, c.mass)
	nb.type = c.type
	nb.radius = c.radius
	nb.color = c.color
	nb.set_pos(wx - to._bcx, wy - to._bcy, wz - to._bcz)
	nb.set_vel(vx - to._bvx, vy - to._bvy, vz - to._bvz)
	if to.dominant != null and to.dominant.body != null:
		nb.primary = to.dominant.body
	to.sim.add(nb)
	to.members.append(c)
	c.body = nb
	c.owner_system = to
	_trail_container_for(c)._ensure_visuals_for(c)
	# 4) 节点挂到 to(视觉位置每帧由物理驱动, 此处只为层级一致)
	if c.get_parent() == from:
		from.remove_child(c)
	if c.get_parent() == null:
		to.add_child(c)
	c._trail.clear()   # 参考体随 owner 变, 清空避免错位
	print("[SOI] %s: %s -> %s" % [c.name, from.name, to.name])


# 移交后刷新: Hill(顶层边界随成员变化)/SOI 球/轨道预测。
func _after_reparent() -> void:
	_recompute_hill_all()
	_rebuild_soi_spheres()
	_compute_predictions()


# ===================== 初始化归属分流 =====================
# 所有 _init_physics 完成后(子节点先 _ready → child_proxy/_hill_radius 已建), 按 Hill 归属
# 把"在父 dominant 的 Hill 外"的子系统上抛到父 sim。上抛后该子系统在父 sim 里受多源引力
# (双星 → P-type 绕双星整体 / 混沌 / 临时捕获), 而非错误地只绕原 dominant。
# 解决"编辑器里是孩子但运行时 SOI 外 → 该受合力"的物理正确性(一次性, 仅初始化)。
func _resolve_initial_ownership_all() -> void:
	for t in _get_all_tops():
		_propagate_bases(t)
	var moves: Array = []
	for t in _get_all_tops():
		_collect_initial_moves(t, moves)
	for m in moves:
		var sub: CelestialSystem = m["sub"]
		var from_sys: CelestialSystem = m["from"]
		var to_sys: CelestialSystem = m["to"]
		_reparent_subsystem(sub, from_sys, to_sys)
	if not moves.is_empty():
		_recompute_hill_all()
		_rebuild_soi_spheres()
		_compute_predictions()


# 收集需上抛的子系统(不修改树, 避免迭代中改 child_systems)。
# 判定: 有 dominant 且非顶层的系统, 其子系统到 dominant 距离 > 本系统 Hill → 上抛到父。
func _collect_initial_moves(sys: CelestialSystem, moves: Array) -> void:
	if sys.dominant != null and sys.parent_system != null and sys._hill_radius > 0.0 and sys.dominant.body != null:
		# 与 _escaped_from 一致: 逃逸目标是单成员空群(无 dominant, sys.hill≈0 无意义) → 不上抛。
		var par := sys.parent_system
		if not (par.dominant == null and par.child_systems.size() <= 1):
			for sub in sys.child_systems:
				if not sys.child_proxy.has(sub):
					continue
				var pb: Body = sys.child_proxy[sub]
				var db: Body = sys.dominant.body
				var dx: float = pb.px - db.px
				var dy: float = pb.py - db.py
				var dz: float = pb.pz - db.pz
				var sdist: float = sqrt(dx * dx + dy * dy + dz * dz)
				if sdist > sys._hill_radius:
					moves.append({"sub": sub, "from": sys, "to": sys.parent_system})
	for sub in sys.child_systems:
		_collect_initial_moves(sub, moves)


# 初始化时(第一帧 _step_recursive 之前)沿链传播基座位/速一次, 使上抛换算世界位速可用。
func _propagate_bases(sys: CelestialSystem) -> void:
	for sub in sys.child_systems:
		if not sys.child_proxy.has(sub):
			continue
		var pb: Body = sys.child_proxy[sub]
		sub._bcx = sys._bcx + pb.px
		sub._bcy = sys._bcy + pb.py
		sub._bcz = sys._bcz + pb.pz
		sub._bvx = sys._bvx + pb.vx
		sub._bvy = sys._bvy + pb.vy
		sub._bvz = sys._bvz + pb.vz
		_propagate_bases(sub)


# 把子系统 sub 从 from 移交到 to: 摘旧 proxy(世界位速保存), 在 to 用局部坐标建新 proxy。
# 与 _reparent_celestial(叶子天体) 对应, 区别是操作 child_systems/child_proxy。子系统内部
# (dominant/卫星)作为子树原样跟随 —— sub._bcx 由 to._step_recursive 传播, 内部相对不变。
func _reparent_subsystem(sub: CelestialSystem, from: CelestialSystem, to: CelestialSystem) -> void:
	if not from.child_proxy.has(sub):
		return
	var old_proxy: Body = from.child_proxy[sub]
	# 1) 世界位/速(from._bcx/_bvx 已由 _propagate_bases 传播)
	var wx: float = from._bcx + old_proxy.px
	var wy: float = from._bcy + old_proxy.py
	var wz: float = from._bcz + old_proxy.pz
	var vx: float = from._bvx + old_proxy.vx
	var vy: float = from._bvy + old_proxy.vy
	var vz: float = from._bvz + old_proxy.vz
	# 2) 从 from 摘除(child_proxy + sim body + child_systems + 场景树)
	from.child_proxy.erase(sub)
	from.sim.bodies.erase(old_proxy)
	from.child_systems.erase(sub)
	if sub.get_parent() == from:
		from.remove_child(sub)
	# 3) 在 to 里用局部坐标(世界 − to 基座位/速)建新 proxy
	#    防重名: 仅当 to 已有同名子系统时加来源后缀(避免 Godot 自动改 @Node3D@N; 运行时反复移交不累积)。
	var has_dup := false
	for c in to.get_children():
		if c is CelestialSystem and c.name == sub.name:
			has_dup = true
			break
	if has_dup:
		sub.name = sub.name + "_" + from.name
	var nb := Body.new(sub.name, float(sub.get_total_mass()))
	nb.type = "system"
	nb.set_pos(wx - to._bcx, wy - to._bcy, wz - to._bcz)
	nb.set_vel(vx - to._bvx, vy - to._bvy, vz - to._bvz)
	to.sim.add(nb)
	to.child_proxy[sub] = nb
	to.child_systems.append(sub)
	sub.parent_system = to
	# 4) 节点挂到 to(视觉位置每帧由物理驱动, 此处只为层级一致)
	if sub.get_parent() == null:
		to.add_child(sub)
	_clear_trails_in(sub)   # sub 父链变 → 内部天体参考体变, 清空避免错位
	print("[SOI-init] %s: %s -> %s (上抛到父, 受多源引力)" % [sub.name, from.name, to.name])


func _dist3(ax: float, ay: float, az: float, bx: float, by: float, bz: float) -> float:
	var dx: float = ax - bx
	var dy: float = ay - by
	var dz: float = az - bz
	return sqrt(dx * dx + dy * dy + dz * dz)


# 点 (px,py,pz) 是否在 sub 的 Roche lobe 椭球作用区内(朝顶层群质心=伴星方向收尖)。
# 群内子系统: 椭球(radial=Hill×0.8 朝质心, perp=Hill 垂直); 单恒星系顶层/无群: 退化为球(Hill)。
# 几何上即"L1/L2 稳定区"的椭球近似(随相位转), 动力学正确 —— 区别于瞬时引力比(对双星成员错)。
# 多体摄动比: P 点处 max_S |tidal_S(P)| / g_T(P)。判定与视觉共用, 保证形状与归属一致。
# tidal_S(P) = a_S(P) - a_S(T) (在 T 共动系里 S 的潮汐摄动); g_T = G·M_T / |P-T|²。
# sources 空 → 0(退化球)。二体 → Roche lobe; 多体 → 扭曲面; q=M_S/M_T 天然进入。
func _max_perturbation_ratio(T: Celestial, sources: Array[Celestial],
		px: float, py: float, pz: float) -> float:
	if sources.is_empty():
		return 0.0
	var rx: float = px - T._wx
	var ry: float = py - T._wy
	var rz: float = pz - T._wz
	var r2: float = rx * rx + ry * ry + rz * rz
	if r2 < 1e-6:
		return 0.0
	var g_t: float = G * T.mass / r2
	if g_t <= 0.0:
		return 0.0
	var max_eta: float = 0.0
	for S in sources:
		# a_S(P): G·M_S·(S-P)/|S-P|³
		var vpx: float = S._wx - px
		var vpy: float = S._wy - py
		var vpz: float = S._wz - pz
		var dp2: float = vpx * vpx + vpy * vpy + vpz * vpz
		if dp2 < 1e-6:
			continue
		var kp: float = G * S.mass / (dp2 * sqrt(dp2))
		# a_S(T): G·M_S·(S-T)/|S-T|³
		var vtx: float = S._wx - T._wx
		var vty: float = S._wy - T._wy
		var vtz: float = S._wz - T._wz
		var dt2: float = vtx * vtx + vty * vty + vtz * vtz
		if dt2 < 1e-6:
			continue
		var kt: float = G * S.mass / (dt2 * sqrt(dt2))
		# tidal = a_S(P) - a_S(T)
		var tax: float = kp * vpx - kt * vtx
		var tay: float = kp * vpy - kt * vty
		var taz: float = kp * vpz - kt * vtz
		var eta: float = sqrt(tax * tax + tay * tay + taz * taz) / g_t
		if eta > max_eta:
			max_eta = eta
	return max_eta


# 收集 sub 的多体摄动源: 沿祖先链取同层兄弟 + 祖辈 dominant(能撼动 sub 层级的天体),
# 不含 sub 自己的子系统(那些是 sub 的从属天体, 在 sub 的 SOI 内, 非摄动源)。
func _collect_perturbers(sub: CelestialSystem, out_arr: Array[Celestial]) -> void:
	var s: CelestialSystem = sub
	while s.parent_system != null:
		var parent: CelestialSystem = s.parent_system
		if parent.dominant != null:
			out_arr.append(parent.dominant)
		for sib in parent.child_systems:
			if sib == s:
				continue
			if sib.dominant != null:
				out_arr.append(sib.dominant)
		s = parent
	if s.dominant != null:
		out_arr.append(s.dominant)


# 多体势面归属判定(替代写死的 Roche 椭球): P 在 sub.dominant 的 SOI 内 ⇔ max_η < 1。
# 无其他 dominant → 退化球(Hill×IN)。签名同旧 _inside_roche_ellipse, _capture_descend 不用改逻辑。
func _inside_potential_surface(sub: CelestialSystem, px: float, py: float, pz: float, eta_thresh: float = 1.0) -> bool:
	var T: Celestial = sub.dominant
	if T == null:
		return false
	var sources: Array[Celestial] = []
	_collect_perturbers(sub, sources)
	if sources.is_empty():
		var dx: float = px - T._wx
		var dy: float = py - T._wy
		var dz: float = pz - T._wz
		var r_in: float = sub._hill_radius * eta_thresh
		return (dx * dx + dy * dy + dz * dz) < r_in * r_in
	return _max_perturbation_ratio(T, sources, px, py, pz) < eta_thresh


# P 是否已逃出 sys 引力作用区(η ≥ OUT 阈值), 用于触发上抛。
# NaN 防御: 物理发散时 η/位置/hill 会变 NaN —— 此时视为"未逃逸"(false), 不触发 reparent,
# 斩断 "NaN→误判上抛→reparent 速度换算出错→更多 NaN→翻转闪烁" 恶性循环。
# (η<IN 的捕获侧 _inside_potential_surface 对 NaN 同样返回 false=不下钻, 保守安全。)
func _escaped_from(sys: CelestialSystem, px: float, py: float, pz: float) -> bool:
	var T: Celestial = sys.dominant
	if T == null:
		return false
	var parent: CelestialSystem = sys.parent_system
	if parent == null:
		return false   # 顶层不往上抛
	# 逃逸目标是"无 dominant 的群": 仅当群是多体(>1 子系统)才有逃逸意义(双星 Roche lobe)。
	# 单成员退化群(如空群包单恒星系, sys.hill≈0 无意义) → 不逃逸, 子天体留原系统, 避免震荡。
	if parent.dominant == null and parent.child_systems.size() <= 1:
		return false
	var hill: float = sys._hill_radius
	if is_nan(hill) or hill <= 0.0:
		return false
	var sources: Array[Celestial] = []
	_collect_perturbers(sys, sources)
	if sources.is_empty():
		var dx: float = px - T._wx
		var dy: float = py - T._wy
		var dz: float = pz - T._wz
		if is_nan(dx) or is_nan(dy) or is_nan(dz):
			return false
		return sqrt(dx * dx + dy * dy + dz * dz) >= hill * _SOI_HYSTERESIS_OUT
	var eta: float = _max_perturbation_ratio(T, sources, px, py, pz)
	if is_nan(eta):
		return false
	return eta >= _SOI_HYSTERESIS_OUT


# sys 的顶层系统(沿 parent_system 上溯到无父)。视觉椭球找群质心方向用。
func _get_top_of(sys: CelestialSystem) -> CelestialSystem:
	var s: CelestialSystem = sys
	while s.parent_system != null:
		s = s.parent_system
	return s


func _update_orbit(ox: float, oy: float, oz: float) -> void:
	if not _show_orbit:
		return
	for i in range(_orbit_rings.size()):
		var c: Celestial = _orbit_targets[i]
		var sph: MeshInstance3D = _orbit_rings[i]
		if not _predict_data.has(c):
			sph.visible = false
			continue
		sph.visible = true
		sph.global_position = Vector3.ZERO   # 节点原点对齐渲染原点(顶点已是渲染坐标, 抵消容器场景位)
		var traj: PackedVector3Array = _predict_data[c]
		sph.mesh = _make_line_mesh(traj, ox, oy, oz)


# 折线 mesh(世界 double − 浮动原点)。
func _make_line_mesh(traj: PackedVector3Array, ox: float, oy: float, oz: float) -> ArrayMesh:
	var positions := PackedVector3Array()
	var n := traj.size()
	for i in range(n - 1):
		positions.append(Vector3(traj[i].x - ox, traj[i].y - oy, traj[i].z - oz))
		positions.append(Vector3(traj[i + 1].x - ox, traj[i + 1].y - oy, traj[i + 1].z - oz))
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return arr_mesh


func _collect_focus_all() -> void:
	_focus_list.clear()
	for t in _get_all_tops():
		_collect_focus(t)


func _collect_focus(sys: CelestialSystem) -> void:
	for c in sys.members:
		_focus_list.append(c)
	for sub in sys.child_systems:
		_collect_focus(sub)


func _all_celestials() -> Array[Celestial]:
	var all: Array[Celestial] = []
	for t in _get_all_tops():
		_collect_celestials(t, all)
	return all


func _collect_celestials(sys: CelestialSystem, out: Array[Celestial]) -> void:
	for c in sys.members:
		out.append(c)
	for sub in sys.child_systems:
		_collect_celestials(sub, out)


# 天体 c 的拖尾参考体(它绕的中心): 从 c.owner_system 向上找第一个 dominant != c 的系统。
# Moon→Planet, Planet(子系统主)→Star, Star(恒星系主)→群质心(null=原点)。拖尾存相对它的位置。
func _trail_reference(c: Celestial) -> Celestial:
	var sys: CelestialSystem = c.owner_system
	while sys != null:
		if sys.dominant != null and sys.dominant != c:
			return sys.dominant
		sys = sys.parent_system
	return null


# c 的轨迹/轨道应挂的容器系统: 它绕的中心(ref)所在的 system; ref==null(绕群质心)→顶层群。
# 顶层群容器存恒星系中心; 恒星系容器存行星; 行星系容器存卫星 —— 按轨道层级(与 _build_visuals_in 一致)。
func _trail_container_for(c: Celestial) -> CelestialSystem:
	var ref: Celestial = _trail_reference(c)
	if ref != null:
		return ref.owner_system
	return _get_top_of(c.owner_system)


# 清空 sys 子树内所有天体的拖尾(子系统移交后父链变 → 参考体变, 历史拖尾会错位)。
func _clear_trails_in(sys: CelestialSystem) -> void:
	for c in sys.members:
		c._trail.clear()
	for sub in sys.child_systems:
		_clear_trails_in(sub)


func _build_soi_visuals_all() -> void:
	for t in _get_all_tops():
		_collect_soi(t)


func _collect_soi(sys: CelestialSystem) -> void:
	# 顶层(无父级系统)不画 SOI —— 整个星系群外边界, 画框无意义。收集各系统自带的预制体 SOI 节点。
	if sys.parent_system != null and sys._hill_radius > 0.0 and sys._soi_visual != null:
		_soi_spheres.append(sys._soi_visual)
		_soi_targets.append(sys)
	for sub in sys.child_systems:
		_collect_soi(sub)


# 为天体 c 在本系统的 Trails/Orbits 容器里生成 trail+orbit 节点(命名 Trail_/Orbit_<名>)。
# 行星进入系统时调; 节点和天体并列(非天体子节点), 编辑器层级清晰。
func _ensure_visuals_for(c: Celestial) -> void:
	if _trails_container != null and c._trail_visual == null:
		var t := MeshInstance3D.new()
		t.name = "Trail_" + c.name + "_" + c.owner_system.name
		t.material_override = _make_trail_material()
		t.visible = false
		_trails_container.add_child(t)
		c._trail_visual = t
	if _orbits_container != null and c._orbit_visual == null:
		var o := MeshInstance3D.new()
		o.name = "Orbit_" + c.name + "_" + c.owner_system.name
		o.material_override = _make_orbit_material()
		o.visible = false
		_orbits_container.add_child(o)
		c._orbit_visual = o


# 行星离开系统时删除其 trail+orbit 节点(从本系统容器移除)。
func _remove_visuals_for(c: Celestial) -> void:
	if c._trail_visual != null:
		c._trail_visual.queue_free()
		c._trail_visual = null
	if c._orbit_visual != null:
		c._orbit_visual.queue_free()
		c._orbit_visual = null


# 初始化: 为每个天体在其 owner 系统的容器生成 trail/orbit 节点。
func _build_celestial_visuals_all() -> void:
	for t in _get_all_tops():
		_build_visuals_in(t)


func _build_visuals_in(sys: CelestialSystem) -> void:
	# sys 容器存"绕 sys 中心的天体": 非 dominant member(绕 sys.dominant) + 子系统中心(绕 sys 中心)。
	# 顶层群容器存恒星系中心(Star); 恒星系容器存行星; 行星系容器存卫星 —— 按轨道层级。
	for c in sys.members:
		if c == sys.dominant:
			continue
		sys._ensure_visuals_for(c)
	for sub in sys.child_systems:
		if sub.dominant != null:
			sys._ensure_visuals_for(sub.dominant)
	for sub in sys.child_systems:
		_build_visuals_in(sub)


func _add_soi_sphere(target_sys: CelestialSystem) -> void:
	var sph := MeshInstance3D.new()
	sph.name = "SOI_%s" % target_sys.name
	# 单位球 mesh + scale: 半径每帧由 _update_soi 随 _hill_radius 动态缩放(免重建 mesh)。
	sph.mesh = _make_wireframe_sphere(1.0, 24, 12)
	sph.scale = Vector3(target_sys._hill_radius, target_sys._hill_radius, target_sys._hill_radius)
	sph.material_override = _make_soi_material(target_sys)
	sph.visible = _show_soi
	add_child(sph)
	_soi_spheres.append(sph)
	_soi_targets.append(target_sys)


func _make_soi_material(target_sys: CelestialSystem) -> Material:
	var is_top: bool = target_sys.parent_system == null
	var col: Color = Color(1.0, 0.85, 0.3, 0.35) if is_top else Color(0.3, 0.85, 1.0, 0.35)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _SOI_SHADER_CODE
	mat.shader = sh
	mat.set_shader_parameter("line_color", col)
	return mat


# 沿单位方向 (dx,dy,dz) 从 T 出发的射线上, 求 max_η=1 的边界半径 r。
# η 沿射线单调趋增 → 步长扫描找首个 η≥1 过零区间 → 区间内二分细化。
# 多体 η 可能非严格单调, 故扫描而非纯二分。use_ball/sources 空 → 回退 fallback_r。
func _soi_radius_on_ray(T: Celestial, sources: Array[Celestial], use_ball: bool,
		fallback_r: float, r_max: float,
		dx: float, dy: float, dz: float) -> float:
	if use_ball:
		return fallback_r
	# 内联 η 计算(不调 _max_perturbation_ratio), 省 GDScript 函数调用开销(视觉路径性能关键)。
	var twx: float = T._wx
	var twy: float = T._wy
	var twz: float = T._wz
	var tm: float = T.mass
	var n_scan: int = 10
	var r_prev: float = 0.0
	for k in range(1, n_scan + 1):
		var r_cur: float = r_max * float(k) / float(n_scan)
		var px: float = twx + dx * r_cur
		var py: float = twy + dy * r_cur
		var pz: float = twz + dz * r_cur
		var g_t: float = G * tm / (r_cur * r_cur)
		var eta_cur: float = 0.0
		if g_t > 0.0:
			for S in sources:
				var vpx: float = S._wx - px
				var vpy: float = S._wy - py
				var vpz: float = S._wz - pz
				var dp2: float = vpx * vpx + vpy * vpy + vpz * vpz
				if dp2 < 1e-6:
					continue
				var kp: float = G * S.mass / (dp2 * sqrt(dp2))
				var stx: float = S._wx - twx
				var sty: float = S._wy - twy
				var stz: float = S._wz - twz
				var dt2: float = stx * stx + sty * sty + stz * stz
				if dt2 < 1e-6:
					continue
				var kt: float = G * S.mass / (dt2 * sqrt(dt2))
				var tax: float = kp * vpx - kt * stx
				var tay: float = kp * vpy - kt * sty
				var taz: float = kp * vpz - kt * stz
				var eta: float = sqrt(tax * tax + tay * tay + taz * taz) / g_t
				if eta > eta_cur:
					eta_cur = eta
		if eta_cur >= 1.0:
			var lo: float = r_prev
			var hi: float = r_cur
			for _b in range(8):
				var mid: float = 0.5 * (lo + hi)
				var bpx: float = twx + dx * mid
				var bpy: float = twy + dy * mid
				var bpz: float = twz + dz * mid
				var bg_t: float = G * tm / (mid * mid)
				var b_eta: float = 0.0
				if bg_t > 0.0:
					for S in sources:
						var bvx: float = S._wx - bpx
						var bvy: float = S._wy - bpy
						var bvz: float = S._wz - bpz
						var bp2: float = bvx * bvx + bvy * bvy + bvz * bvz
						if bp2 < 1e-6:
							continue
						var bkp: float = G * S.mass / (bp2 * sqrt(bp2))
						var bstx: float = S._wx - twx
						var bsty: float = S._wy - twy
						var bstz: float = S._wz - twz
						var bdt2: float = bstx * bstx + bsty * bsty + bstz * bstz
						if bdt2 < 1e-6:
							continue
						var bkt: float = G * S.mass / (bdt2 * sqrt(bdt2))
						var bax: float = bkp * bvx - bkt * bstx
						var bay: float = bkp * bvy - bkt * bsty
						var baz: float = bkp * bvz - bkt * bstz
						var e_b: float = sqrt(bax * bax + bay * bay + baz * baz) / bg_t
						if e_b > b_eta:
							b_eta = e_b
				if b_eta >= 1.0:
					hi = mid
				else:
					lo = mid
			return 0.5 * (lo + hi)
		r_prev = r_cur
	return r_max


# 等势面线框 mesh: 球面方向(θ,φ)径向采样求 η=1 半径, 连经纬线(PRIMITIVE_LINES)。
# 照 _make_wireframe_sphere 双循环结构, 仅顶点半径从固定 r 换成 r(θ,φ)。
# 顶点 = (T 世界位 - 浮动原点) + r·dir。sources 空 → 退化为 Hill 球线框。
func _make_potential_surface_mesh(T: Celestial, sources: Array[Celestial],
		ox: float, oy: float, oz: float, n_lon: int, n_lat: int, hill: float) -> ArrayMesh:
	var tx: float = T._wx - ox
	var ty: float = T._wy - oy
	var tz: float = T._wz - oz
	var d_near2: float = 1e30
	for S in sources:
		var ex: float = S._wx - T._wx
		var ey: float = S._wy - T._wy
		var ez: float = S._wz - T._wz
		var d2: float = ex * ex + ey * ey + ez * ez
		if d2 < d_near2:
			d_near2 = d2
	# η=1 面(定义: tidal/g=1)朝源方向在 ~0.8×源距; r_max=1.5×最近源距 确保扫描覆盖到边界。
	var r_max: float = maxf(hill, 1.0)
	if not sources.is_empty():
		r_max = maxf(sqrt(d_near2) * 1.5, 1.0)
	var fallback_r: float = hill if hill > 0.0 else r_max
	var use_ball: bool = sources.is_empty()
	# 半径查表 rad[i][j](i=0..n_lat φ, j=0..n_lon θ): 每 (φ,θ) 只采样一次, 经纬线复用。
	# 旧版每线段端点独立采样 → 2·((n_lat-1)·n_lon + n_lon·n_lat) 次; 查表仅 (n_lat+1)·(n_lon+1) 次。
	var rad: Array = []
	rad.resize(n_lat + 1)
	for i in range(n_lat + 1):
		var phi: float = PI * float(i) / float(n_lat)
		var sinp: float = sin(phi)
		var cosp: float = cos(phi)
		var row: Array = []
		row.resize(n_lon + 1)
		for j in range(n_lon + 1):
			var theta: float = TAU * float(j) / float(n_lon)
			row[j] = _soi_radius_on_ray(T, sources, use_ball, fallback_r, r_max,
				sinp * cos(theta), cosp, sinp * sin(theta))
		rad[i] = row
	var positions := PackedVector3Array()
	# 纬线圈: 固定 φ, 连相邻 θ(避开极点 φ=0/π 退化)。
	for i in range(1, n_lat):
		var phi: float = PI * float(i) / float(n_lat)
		var sinp: float = sin(phi)
		var cosp: float = cos(phi)
		for j in range(n_lon):
			var t0: float = TAU * float(j) / float(n_lon)
			var t1: float = TAU * float(j + 1) / float(n_lon)
			var r0: float = rad[i][j]
			var r1: float = rad[i][j + 1]
			positions.append(Vector3(tx + sinp * cos(t0) * r0, ty + cosp * r0, tz + sinp * sin(t0) * r0))
			positions.append(Vector3(tx + sinp * cos(t1) * r1, ty + cosp * r1, tz + sinp * sin(t1) * r1))
	# 经线: 固定 θ, 连相邻 φ。
	for j in range(n_lon):
		var theta: float = TAU * float(j) / float(n_lon)
		var ct: float = cos(theta)
		var st: float = sin(theta)
		for i in range(n_lat):
			var p0: float = PI * float(i) / float(n_lat)
			var p1: float = PI * float(i + 1) / float(n_lat)
			var s0: float = sin(p0)
			var c0: float = cos(p0)
			var s1: float = sin(p1)
			var c1: float = cos(p1)
			var r0: float = rad[i][j]
			var r1: float = rad[i + 1][j]
			positions.append(Vector3(tx + s0 * ct * r0, ty + c0 * r0, tz + s0 * st * r0))
			positions.append(Vector3(tx + s1 * ct * r1, ty + c1 * r1, tz + s1 * st * r1))
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return arr_mesh


func _make_wireframe_sphere(r: float, n_lon: int, n_lat: int) -> ArrayMesh:
	var positions := PackedVector3Array()
	for i in range(1, n_lat):
		var phi := PI * float(i) / float(n_lat)
		var y := r * cos(phi)
		var rr := r * sin(phi)
		for j in range(n_lon):
			var t0 := TAU * float(j) / float(n_lon)
			var t1 := TAU * float(j + 1) / float(n_lon)
			positions.append(Vector3(rr * cos(t0), y, rr * sin(t0)))
			positions.append(Vector3(rr * cos(t1), y, rr * sin(t1)))
	for j in range(n_lon):
		var theta := TAU * float(j) / float(n_lon)
		for i in range(n_lat):
			var p0 := PI * float(i) / float(n_lat)
			var p1 := PI * float(i + 1) / float(n_lat)
			positions.append(Vector3(r * sin(p0) * cos(theta), r * cos(p0), r * sin(p0) * sin(theta)))
			positions.append(Vector3(r * sin(p1) * cos(theta), r * cos(p1), r * sin(p1) * sin(theta)))
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return arr_mesh


# 为每个有预测的天体建一条预测线 mesh: 非 dominant 成员 + 子系统 dominant(作为父质点绕父)。
func _build_orbit_visuals_all() -> void:
	for t in _get_all_tops():
		_collect_orbit_targets(t)


func _collect_orbit_targets(sys: CelestialSystem) -> void:
	for c in sys.members:
		if c == sys.dominant or c.body == null:
			continue
		_collect_orbit_prefab(c)
	for sub in sys.child_systems:
		if sub.dominant != null:
			_collect_orbit_prefab(sub.dominant)
	for sub in sys.child_systems:
		_collect_orbit_targets(sub)


# 收集天体自带的预制体 Orbit 节点(替代运行时 new MeshInstance3D)。
func _collect_orbit_prefab(c: Celestial) -> void:
	if c._orbit_visual == null:
		return
	if not _orbit_targets.has(c):
		_orbit_rings.append(c._orbit_visual)
		_orbit_targets.append(c)


func _add_orbit_mesh(c: Celestial) -> void:
	if c in _orbit_targets:
		return
	var sph := MeshInstance3D.new()
	sph.name = "Orbit_%s" % c.name
	sph.material_override = _make_orbit_material()
	sph.visible = _show_orbit
	add_child(sph)
	_orbit_rings.append(sph)
	_orbit_targets.append(c)


# 解析轨道椭圆: 遍历每层 sim, 对"非 dominant"天体(成员 + 子系统质点)从当前 (r,v) 求 Kepler
# 椭圆并采样。每帧重算 → 永远反映当前 osculating 轨道。逃逸体(能量≥0)不画。
func _compute_predictions() -> void:
	_predict_data.clear()
	for t in _get_all_tops():
		_predict_layer(t)


func _predict_layer(sys: CelestialSystem) -> void:
	if sys.dominant != null and sys.dominant.body != null:
		var dom_body: Body = sys.dominant.body
		var mu: float = G * sys.dominant.mass
		for c in sys.members:                                 # 非 dominant 成员(如卫星)
			if c == sys.dominant or c.body == null:
				continue
			_predict_one(sys, dom_body, mu, c.body, c)
		for sub in sys.child_systems:                         # 子系统质点 → 挂子系统 dominant
			if sys.child_proxy.has(sub) and sub.dominant != null:
				_predict_one(sys, dom_body, mu, sys.child_proxy[sub], sub.dominant)
	for sub in sys.child_systems:
		_predict_layer(sub)


# 解析轨道椭圆(移植 web writeOrbit): 从当前状态矢量 (r,v) 相对 dominant 求 Kepler 椭圆,
# 采样 _ORBIT_SEG 段完美闭合曲线。逃逸/双曲(能量≥0 或 e≥1)→ 不画。
# 每帧从当前状态重算 → 永远反映当前 osculating 轨道, 无数值积分误差/滞后 → 丝滑。
func _predict_one(sys: CelestialSystem, dom_body: Body, mu: float, body: Body, target: Celestial) -> void:
	var rx: float = body.px - dom_body.px
	var ry: float = body.py - dom_body.py
	var rz: float = body.pz - dom_body.pz
	var vx: float = body.vx - dom_body.vx
	var vy: float = body.vy - dom_body.vy
	var vz: float = body.vz - dom_body.vz
	var r_len: float = sqrt(rx * rx + ry * ry + rz * rz)
	if r_len < 1e-9 or mu <= 0.0:
		return
	# 角动量 h = r × v
	var hx: float = ry * vz - rz * vy
	var hy: float = rz * vx - rx * vz
	var hz: float = rx * vy - ry * vx
	var h_len: float = sqrt(hx * hx + hy * hy + hz * hz)
	if h_len < 1e-9:
		return
	# 偏心率矢量 e = (v × h)/μ − r/|r|  (指向近星点)
	var vxh_x: float = vy * hz - vz * hy
	var vxh_y: float = vz * hx - vx * hz
	var vxh_z: float = vx * hy - vy * hx
	var ex: float = vxh_x / mu - rx / r_len
	var ey: float = vxh_y / mu - ry / r_len
	var ez: float = vxh_z / mu - rz / r_len
	var e: float = sqrt(ex * ex + ey * ey + ez * ez)
	var energy: float = 0.5 * (vx * vx + vy * vy + vz * vz) - mu / r_len
	if energy >= 0.0 or e >= 0.999:
		return                                 # 逃逸/双曲 → 不画闭合椭圆
	var p: float = h_len * h_len / mu          # 半通径 p = h²/μ
	# 轨道平面正交基: nHat=h/|h|; pHat=e/e (e≈0 取 r方向); qHat=nHat×pHat
	var nx: float = hx / h_len
	var ny: float = hy / h_len
	var nz: float = hz / h_len
	var pxh: float
	var pyh: float
	var pzh: float
	if e > 1e-5:
		pxh = ex / e
		pyh = ey / e
		pzh = ez / e
	else:
		pxh = rx / r_len
		pyh = ry / r_len
		pzh = rz / r_len
	var qx: float = ny * pzh - nz * pyh
	var qy: float = nz * pxh - nx * pzh
	var qz: float = nx * pyh - ny * pxh
	# 采样闭合椭圆: r(θ) = p/(1+e·cosθ), 点 = dominant世界位 + rr·(cos·pHat + sin·qHat)
	var dom_world := Vector3(sys.dominant._wx, sys.dominant._wy, sys.dominant._wz)
	var world_traj := PackedVector3Array()
	var n: int = _ORBIT_SEG
	for i in range(n):
		var th: float = (float(i) / float(n - 1)) * TAU
		var c: float = cos(th)
		var s: float = sin(th)
		var rr: float = p / (1.0 + e * c)
		world_traj.append(Vector3(
			dom_world.x + rr * (c * pxh + s * qx),
			dom_world.y + rr * (c * pyh + s * qy),
			dom_world.z + rr * (c * pzh + s * qz)))
	_predict_data[target] = world_traj


func _make_orbit_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.65, 0.8, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _build_trail_mesh() -> void:
	_trail_mesh = MeshInstance3D.new()
	_trail_mesh.name = "Trails"
	_trail_mesh.material_override = _make_trail_material()
	_trail_mesh.visible = _show_trail
	add_child(_trail_mesh)


func _update_trail_mesh(ox: float, oy: float, oz: float) -> void:
	if not _show_trail:
		return
	# 每天体更新自己的预制体 Trail 节点(替代单 mesh)。trail 点相对父级(dominant), 加参考当前位。
	for c in _all_celestials():
		if c._trail_visual == null:
			continue
		c._trail_visual.visible = true
		c._trail_visual.global_position = Vector3.ZERO   # 节点原点对齐渲染原点(顶点已是渲染坐标, 抵消容器场景位)
		var ref_c: Celestial = _trail_reference(c)
		var rx := 0.0
		var ry := 0.0
		var rz := 0.0
		if ref_c != null:
			rx = ref_c._wx
			ry = ref_c._wy
			rz = ref_c._wz
		var positions := PackedVector3Array()
		var tr: Array = c._trail
		var n: int = tr.size()
		for i in range(n - 1):
			var p0: Vector3 = tr[i]
			var p1: Vector3 = tr[i + 1]
			positions.append(Vector3(p0.x + rx - ox, p0.y + ry - oy, p0.z + rz - oz))
			positions.append(Vector3(p1.x + rx - ox, p1.y + ry - oy, p1.z + rz - oz))
		if positions.size() < 2:
			continue   # trail 不足一段, 跳过(避免空 mesh 警告)
		var arr_mesh := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		c._trail_visual.mesh = arr_mesh


func _make_trail_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.9, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _update_camera_and_hud() -> void:
	if _focus_list.is_empty():
		return
	var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
	if orbit_camera != null:
		orbit_camera.target = (fc as Node3D).global_position
		if focus_idx != _last_focus_idx:
			orbit_camera.distance = fc.radius * 6.0
			_last_focus_idx = focus_idx
			_sync_editor_from_focus()
	if _hud != null and sim != null:
		_hud.text = "focus: %s   speed: %.1f   (TAB [/]调速 F2 SOI F3 轨迹 F4 尾迹 左键 滚轮)\nenergy: %.3f" % [
			fc.name, sim_speed, sim.energy().get("total", 0.0)]


func _unhandled_input(event: InputEvent) -> void:
	if not _is_main_top:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_clicking = true
			_click_pos = event.position
		else:
			if _clicking and event.position.distance_to(_click_pos) < 6.0:
				_pick_focus(event.position)
			_clicking = false
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				focus_idx = (focus_idx + 1) % max(_focus_list.size(), 1)
			KEY_BRACKETRIGHT:
				sim_speed = min(sim_speed + 0.2, 10.0)
			KEY_BRACKETLEFT:
				sim_speed = max(sim_speed - 0.2, 0.0)
			KEY_F2:
				_show_soi = not _show_soi
				for sph in _soi_spheres:
					sph.visible = _show_soi
			KEY_F3:
				_show_orbit = not _show_orbit
				for ring in _orbit_rings:
					ring.visible = _show_orbit
			KEY_F4:
				_show_trail = not _show_trail
				for c in _all_celestials():
					if c._trail_visual != null:
						c._trail_visual.visible = _show_trail


func _pick_focus(mouse_pos: Vector2) -> void:
	if orbit_camera == null or _focus_list.is_empty():
		return
	var origin: Vector3 = orbit_camera.project_ray_origin(mouse_pos)
	var rdir: Vector3 = orbit_camera.project_ray_normal(mouse_pos)
	var best_i: int = -1
	var best_t: float = 1e18
	for i in range(_focus_list.size()):
		var c: Celestial = _focus_list[i]
		var center: Vector3 = (c as Node3D).global_position
		var R: float = max(c.radius * 1.5, 50.0)
		# 相机越远 → 天体在屏幕上越小 → 点击半径随距离动态扩大,
		# 让碰撞球在屏幕上至少占 pick_min_pixels 像素(屏幕角半径 → 世界半径)。
		# 屏幕高 vp_h 像素对应 fov 竖直视场, 故每像素 ≈ fov/vp_h 弧度,
		# 世界半径 ≈ 相机距离 × tan(半视场) × 2 × (像素占比)。
		var dist_cam: float = center.distance_to(origin)
		var vp_h: float = maxf(get_viewport().get_visible_rect().size.y, 1.0)
		var r_screen: float = dist_cam * tan(deg_to_rad(orbit_camera.fov) * 0.5) * 2.0 * (float(pick_min_pixels) / vp_h)
		R = maxf(R, r_screen)
		var oc: Vector3 = origin - center
		var bb: float = oc.dot(rdir)
		var cc: float = oc.dot(oc) - R * R
		var disc: float = bb * bb - cc
		if disc < 0.0:
			continue
		var sq: float = sqrt(disc)
		var t: float = -bb - sq
		if t < 0.0:
			t = -bb + sq
		if t < 0.0:
			continue
		if t < best_t:
			best_t = t
			best_i = i
	if best_i >= 0:
		focus_idx = best_i


# ===================== 属性编辑面板 =====================
func _build_celestial_editor() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	var panel := PanelContainer.new()
	cl.add_child(panel)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -250.0
	panel.offset_right = -10.0
	panel.offset_top = 60.0
	panel.offset_bottom = 60.0
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)
	_editor_title = Label.new()
	_editor_title.text = "(未聚焦)"
	vbox.add_child(_editor_title)
	_mass_spin = _add_prop_spin(vbox, "mass", 0.0, 10000000.0, 10.0, _on_mass_changed)
	_radius_spin = _add_prop_spin(vbox, "radius", 1.0, 5000.0, 5.0, _on_radius_changed)
	_color_pick = _add_prop_color(vbox, "color", _on_color_changed)
	_sync_editor_from_focus()


func _add_prop_spin(parent: Control, label_text: String, minv: float, maxv: float, step: float, callback: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(52, 0)
	row.add_child(l)
	var spin := SpinBox.new()
	spin.min_value = minv
	spin.max_value = maxv
	spin.step = step
	spin.value_changed.connect(callback)
	spin.custom_minimum_size = Vector2(140, 0)
	row.add_child(spin)
	return spin


func _add_prop_color(parent: Control, label_text: String, callback: Callable) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(52, 0)
	row.add_child(l)
	var cp := ColorPickerButton.new()
	cp.color = Color.WHITE
	cp.custom_minimum_size = Vector2(140, 0)
	cp.edit_alpha = false
	cp.color_changed.connect(callback)
	row.add_child(cp)
	return cp


func _current_focus() -> Celestial:
	if _focus_list.is_empty():
		return null
	return _focus_list[focus_idx % _focus_list.size()]


func _sync_editor_from_focus() -> void:
	if _editor_title == null:
		return
	var fc: Celestial = _current_focus()
	if fc == null:
		_editor_title.text = "(未聚焦)"
		return
	_editor_syncing = true
	_editor_title.text = "编辑: %s" % fc.name
	_mass_spin.value = fc.mass
	_radius_spin.value = fc.radius
	_color_pick.color = fc.color
	_editor_syncing = false


func _on_mass_changed(v: float) -> void:
	if _editor_syncing:
		return
	var fc: Celestial = _current_focus()
	if fc != null:
		fc.mass = v
		if fc.body != null:
			fc.body.mass = v
		_recompute_after_mass_change(fc)


func _recompute_after_mass_change(fc: Celestial) -> void:
	var sys: CelestialSystem = fc.owner_system
	while sys != null:
		var parent: CelestialSystem = sys.parent_system
		if parent != null and parent.child_proxy.has(sys):
			var proxy: Body = parent.child_proxy[sys]
			proxy.mass = float(sys.get_total_mass())
		sys = parent
	_recompute_hill_all()
	_rebuild_soi_spheres()
	_compute_predictions()              # 改 mass → 重新数值预测轨道


func _recompute_hill_all() -> void:
	for t in _get_all_tops():
		_recompute_hill_recursive(t)


func _recompute_hill_recursive(sys: CelestialSystem) -> void:
	var parent: CelestialSystem = sys.parent_system
	if parent != null and sys.dominant != null and parent.child_proxy.has(sys):
		# 子系统(有 dominant)的 Hill: 相对父参考点, M = 父参考质量。
		# 父有 dominant → 相对父 dominant, M = 父 dominant 质量;
		# 父是星系群(无 dominant) → 相对群质心, M = 群总质量。
		var proxy: Body = parent.child_proxy[sys]
		var sdist: float = 0.0
		var m_ref: float = 0.0
		if parent.dominant != null and parent.dominant.body != null:
			var db: Body = parent.dominant.body
			var dx: float = proxy.px - db.px
			var dy: float = proxy.py - db.py
			var dz: float = proxy.pz - db.pz
			sdist = sqrt(dx * dx + dy * dy + dz * dz)
			m_ref = parent.dominant.mass
		else:
			var tm := 0.0
			var bx := 0.0
			var by := 0.0
			var bz := 0.0
			for s2 in parent.child_systems:
				if not parent.child_proxy.has(s2):
					continue
				var pb2: Body = parent.child_proxy[s2]
				tm += pb2.mass
				bx += pb2.px * pb2.mass
				by += pb2.py * pb2.mass
				bz += pb2.pz * pb2.mass
			if tm > 0.0:
				bx /= tm
				by /= tm
				bz /= tm
			var dx: float = proxy.px - bx
			var dy: float = proxy.py - by
			var dz: float = proxy.pz - bz
			sdist = sqrt(dx * dx + dy * dy + dz * dz)
			m_ref = tm
		if sdist > 0.0 and m_ref > 0.0:
			var m: float = float(sys.get_total_mass())
			sys._hill_radius = sdist * pow(m / (3.0 * m_ref), 1.0 / 3.0)
	elif parent == null:
		# 顶层边界(有 dominant → 最远成员; 星系群 → 最远质点到质心)
		sys._hill_radius = sys._compute_top_boundary()
	for sub in sys.child_systems:
		_recompute_hill_recursive(sub)


# 等势面 mesh 强制刷新: reparent/初始化后立即重建所有 SOI 视觉, 不等限频计数器。
func _rebuild_soi_spheres() -> void:
	if _soi_spheres.is_empty():
		return
	_rebuild_soi_meshes_now()
	_soi_rebuild_counter = 0


func _on_radius_changed(v: float) -> void:
	if _editor_syncing:
		return
	var fc: Celestial = _current_focus()
	if fc != null:
		fc.radius = v


func _on_color_changed(c: Color) -> void:
	if _editor_syncing:
		return
	var fc: Celestial = _current_focus()
	if fc != null:
		fc.color = c


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	cl.add_child(_hud)
	_hud.position = Vector2(10, 40)
	_hud.add_theme_font_size_override("font_size", 14)
