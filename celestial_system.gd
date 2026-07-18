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
			_build_hud()
			call_deferred("_collect_focus_all")
			call_deferred("_build_soi_visuals_all")
			call_deferred("_build_orbit_visuals_all")
			call_deferred("_build_celestial_editor")
			call_deferred("_build_trail_mesh")


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
	if parent_system == null:
		sim.zero_momentum()
		var max_d: float = 0.0
		for c in members:
			if c == dominant:
				continue
			max_d = max(max_d, float((c.position - dominant.position).length()))
		for sub in child_systems:
			max_d = max(max_d, float((sub.position - dominant.position).length()))
		_hill_radius = max_d * 1.5


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
		var wp := Vector3(c._wx, c._wy, c._wz)
		if c._trail.is_empty() or (c._trail.back() as Vector3).distance_to(wp) > max(c.radius * 0.3, 5.0):
			c._trail.append(wp)
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
		var tgt: CelestialSystem = _soi_targets[i]
		if tgt.dominant != null:
			(_soi_spheres[i] as Node3D).global_position = Vector3(
				tgt.dominant._wx - ox, tgt.dominant._wy - oy, tgt.dominant._wz - oz)


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
	for sub in sys.child_systems:
		if _scan_system_soi(sub):
			changed = true
	return changed


# 决定天体 c 应属哪个系统(同一顶层内), 两侧 hysteresis:
#  - 逃出: c 到当前主导距离 > 当前 Hill×OUT → 离开当前系统, 从父起向下找捕获目标。
#  - 捕获: 否则从当前系统起向下找更深的包含者(顶层成员可被行星 Hill 捕获)。
func _resolve_desired_owner(c: Celestial) -> CelestialSystem:
	var cur: CelestialSystem = c.owner_system
	var px: float = c._wx
	var py: float = c._wy
	var pz: float = c._wz
	if cur.parent_system != null and cur.dominant != null and cur._hill_radius > 0.0:
		var de: float = _dist3(px, py, pz, cur.dominant._wx, cur.dominant._wy, cur.dominant._wz)
		if de > cur._hill_radius * _SOI_HYSTERESIS_OUT:
			return _capture_descend(cur.parent_system, px, py, pz)
	return _capture_descend(cur, px, py, pz)


# 从 start 向下找包含点 (px,py,pz) 的最深子系统(含 start 自身)。
# 仅当到子系统主导距离 < 子系统 Hill×IN 才下钻(捕获阈值)。
func _capture_descend(start: CelestialSystem, px: float, py: float, pz: float) -> CelestialSystem:
	var s: CelestialSystem = start
	while true:
		var nxt: CelestialSystem = null
		for sub in s.child_systems:
			if sub.dominant == null or sub._hill_radius <= 0.0:
				continue
			var d: float = _dist3(px, py, pz, sub.dominant._wx, sub.dominant._wy, sub.dominant._wz)
			if d < sub._hill_radius * _SOI_HYSTERESIS_IN:
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
	# 4) 节点挂到 to(视觉位置每帧由物理驱动, 此处只为层级一致)
	if c.get_parent() == from:
		from.remove_child(c)
	if c.get_parent() == null:
		to.add_child(c)
	print("[SOI] %s: %s -> %s" % [c.name, from.name, to.name])


# 移交后刷新: Hill(顶层边界随成员变化)/SOI 球/轨道预测。
func _after_reparent() -> void:
	_recompute_hill_all()
	_rebuild_soi_spheres()
	_compute_predictions()


func _dist3(ax: float, ay: float, az: float, bx: float, by: float, bz: float) -> float:
	var dx: float = ax - bx
	var dy: float = ay - by
	var dz: float = az - bz
	return sqrt(dx * dx + dy * dy + dz * dz)


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


func _build_soi_visuals_all() -> void:
	for t in _get_all_tops():
		_collect_soi(t)


func _collect_soi(sys: CelestialSystem) -> void:
	if sys._hill_radius > 0.0:
		_add_soi_sphere(sys)
	for sub in sys.child_systems:
		_collect_soi(sub)


func _add_soi_sphere(target_sys: CelestialSystem) -> void:
	var sph := MeshInstance3D.new()
	sph.name = "SOI_%s" % target_sys.name
	sph.mesh = _make_wireframe_sphere(target_sys._hill_radius, 24, 12)
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
		_add_orbit_mesh(c)
	for sub in sys.child_systems:
		if sub.dominant != null:
			_add_orbit_mesh(sub.dominant)
	for sub in sys.child_systems:
		_collect_orbit_targets(sub)


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
	if _trail_mesh == null or not _show_trail:
		return
	var positions := PackedVector3Array()
	for c in _all_celestials():
		var tr: Array = c._trail
		var n: int = tr.size()
		for i in range(n - 1):
			var p0: Vector3 = tr[i]
			var p1: Vector3 = tr[i + 1]
			positions.append(Vector3(p0.x - ox, p0.y - oy, p0.z - oz))
			positions.append(Vector3(p1.x - ox, p1.y - oy, p1.z - oz))
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_trail_mesh.mesh = arr_mesh


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
				if _trail_mesh != null:
					_trail_mesh.visible = _show_trail


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
	if sys.parent_system != null and sys.dominant != null:
		var parent: CelestialSystem = sys.parent_system
		if parent.dominant != null and parent.dominant.body != null and parent.child_proxy.has(sys):
			var proxy: Body = parent.child_proxy[sys]
			var dx: float = proxy.px - parent.dominant.body.px
			var dy: float = proxy.py - parent.dominant.body.py
			var dz: float = proxy.pz - parent.dominant.body.pz
			var sdist: float = sqrt(dx * dx + dy * dy + dz * dz)
			if sdist > 0.0:
				var m: float = float(sys.get_total_mass())
				sys._hill_radius = sdist * pow(m / (3.0 * parent.dominant.mass), 1.0 / 3.0)
	elif sys.dominant != null and sys.dominant.body != null:
		var max_d: float = 0.0
		for c in sys.members:
			if c == sys.dominant or c.body == null:
				continue
			var dx: float = c.body.px - sys.dominant.body.px
			var dy: float = c.body.py - sys.dominant.body.py
			var dz: float = c.body.pz - sys.dominant.body.pz
			max_d = max(max_d, sqrt(dx * dx + dy * dy + dz * dz))
		for sub in sys.child_systems:
			if sys.child_proxy.has(sub):
				var proxy: Body = sys.child_proxy[sub]
				var dx: float = proxy.px - sys.dominant.body.px
				var dy: float = proxy.py - sys.dominant.body.py
				var dz: float = proxy.pz - sys.dominant.body.pz
				max_d = max(max_d, sqrt(dx * dx + dy * dy + dz * dz))
		sys._hill_radius = max_d * 1.5
	for sub in sys.child_systems:
		_recompute_hill_recursive(sub)


func _rebuild_soi_spheres() -> void:
	for i in range(_soi_spheres.size()):
		var tgt: CelestialSystem = _soi_targets[i]
		(_soi_spheres[i] as MeshInstance3D).mesh = _make_wireframe_sphere(tgt._hill_radius, 24, 12)


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
