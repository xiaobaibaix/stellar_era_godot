## 递归天体系统节点。
##
## 自相似: 恒星系是一个 CelestialSystem, 行星系(行星+卫星)也是 CelestialSystem。
## 物理: 每层持自己的 NBodySystem(复用 scripts/solar/nbody_system.gd), 只算本层成员。
## 耦合: 子 CelestialSystem 在父层注册为一个"质点 body"(质量=子系统总质量),
##       随父层 sim 积分 → 整体轨道; 子层内部独立积分 → 相对轨道。叠加 = 嵌套。
## 多顶层: 多个恒星系可并列挂在 Main 下(各自独立 sim, 互不隶属)。
##       第一个顶层 = main_top, 管全局浮动原点 / 相机 / HUD / 跨顶层聚焦 / SOI;
##       其他顶层只跑自己的 sim + 渲染。
##       顶层物理原点 = 节点编辑器位置(读 transform) → 并列恒星系各自定位, 不重叠。
## 坐标: 成员 body.p 是【相对本系统主导体】的 double; 世界 double = world_barycenter + body.p;
##       渲染 = 世界 double − 全局浮动原点 → 32 位 global_position(大尺度不抖)。
## 操作: TAB 聚焦 / [/] 调速 / F2 SOI / 左键点击聚焦天体 / 滚轮缩放。
## SOI: 每个天体系统的引力作用范围; F2 开关线框(稀疏经纬线, 半透明, 只画朝相机半球)。
##      - 子系统(有父): 相对父 dominant 的 Hill 球 r=a·(m/(3M))^(1/3)。
##      - 顶层(无父): 系统边界 = 最远成员/子系统距离 × 1.5。
class_name CelestialSystem
extends Node3D

# SOI 线框 shader: fragment 阶段判断线段片段径向是否朝相机, 背面(背离相机)丢弃。
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

# 全局协调(多顶层共享): main_top 管全局浮动原点 / 相机 / HUD / 跨顶层聚焦与 SOI。
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
@export var orbit_camera: OrbitCamera              # 跟随相机(复用 main 的 Camera3D)

var sim: NBodySystem
var members: Array[Celestial] = []           # 本层天体
var dominant: Celestial = null    # 主导体(恒星 / 行星) = 本层 sim 原点
var child_systems: Array[CelestialSystem] = []
var child_proxy: Dictionary = {}  # CelestialSystem -> Body(它在父 sim 里的质点)
var _lights: Array[OmniLight3D] = []   # 手动加的直接子点光源 → 跟随本层 dominant(恒星)

var parent_system: CelestialSystem = null
var _is_main_top: bool = false     # 本顶层是否为协调者(第一个顶层)

var _hill_radius: float = 0.0          # 本系统的引力作用范围半径(子系统=Hill球; 顶层=系统边界)

# 本系统主导体的【世界 double 位置】(顶层=节点编辑器位置; 子层由父层每帧下传)
var _bcx: float = 0.0
var _bcy: float = 0.0
var _bcz: float = 0.0

var _hud: Label = null
var focus_idx: int = 0
var _last_focus_idx: int = -1     # 上次聚焦索引; 仅切换时重置相机距离, 否则滚轮缩放会被每帧覆盖
var _focus_list: Array = []       # Array[Celestial] 跨顶层递归收集, main_top 聚焦用

# SOI 可视化(仅 main_top 管理, 收集所有系统的线框球)
var _show_soi: bool = false
var _soi_spheres: Array[MeshInstance3D] = []
var _soi_targets: Array[CelestialSystem] = []

# 左键点击聚焦(顶层): 短按 = 射线拾取天体聚焦; 拖动 > 6px 视为 OrbitCamera 旋转
var _clicking: bool = false
var _click_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	sim = NBodySystem.new(G, softening)
	parent_system = get_parent() as CelestialSystem
	_collect()
	_init_physics()
	if parent_system == null:
		# 顶层物理原点 = 节点编辑器位置(读 transform) → 并列恒星系各自定位, 不重叠
		var gp: Vector3 = global_position
		_bcx = gp.x
		_bcy = gp.y
		_bcz = gp.z
		# 第一个有效顶层 = main_top(管全局协调); 游戏重启时旧的已失效, 重新认主
		if main_top == null or not is_instance_valid(main_top):
			main_top = self
		if main_top == self:
			_is_main_top = true
			_build_hud()
			# 延迟到所有兄弟顶层 _ready 完成(CS2 等)再收集 → 跨顶层 focus / SOI 才完整
			call_deferred("_collect_focus_all")
			call_deferred("_build_soi_visuals_all")


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


# 建本层 sim: 主导体放原点, 其余绕主导体; 子系统作质点绕主导体。
# 初始相位用编辑器位置方向 → 运行时初始位置对齐编辑器。
func _init_physics() -> void:
	if dominant == null and not members.is_empty():
		dominant = members[0]
	if dominant != null:
		var db := Body.new(dominant.name, dominant.mass)
		db.type = dominant.type
		db.radius = dominant.radius
		db.color = dominant.color
		db.set_pos(0.0, 0.0, 0.0)              # 主导体 = 本层原点
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
			var phase: float = atan2(rel.z, rel.x)      # 编辑器位置的方向角
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
		# 顶层自身的引力作用范围(系统边界): 最远成员/子系统到 dominant 的距离 × 1.5
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


# 收集所有并列顶层(Main 下的 CelestialSystem 且无父系统)。
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


# 只有 main_top 驱动整棵树(含其他并列顶层); 其他节点 _physics_process 空转。
func _physics_process(_delta: float) -> void:
	if not _is_main_top:
		return
	_frame()


# main_top 一帧: step 所有顶层 → 定全局浮动原点 → 渲染所有顶层 → SOI → 相机/HUD。
func _frame() -> void:
	var tops: Array[CelestialSystem] = _get_all_tops()
	for t in tops:
		t._step_recursive()
	if not _focus_list.is_empty():
		var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
		global_ox = fc._wx
		global_oy = fc._wy
		global_oz = fc._wz
	for t in tops:
		t._render_recursive(global_ox, global_oy, global_oz)
		t._update_soi(global_ox, global_oy, global_oz)
	_update_camera_and_hud()


# 自顶向下: step 本层 → 暂存成员世界 double 位置 → 下传子系统质心 → 递归。
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
	for sub in child_systems:
		var pb: Body = child_proxy[sub]
		sub._bcx = _bcx + pb.px
		sub._bcy = _bcy + pb.py
		sub._bcz = _bcz + pb.pz
		sub._step_recursive()


# 写 global_position(世界 double − 全局浮动原点)。点光源跟随本层 dominant。
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


# SOI 线框跟随各自系统 dominant 的渲染位置。
func _update_soi(ox: float, oy: float, oz: float) -> void:
	if not _show_soi:
		return
	for i in range(_soi_spheres.size()):
		var tgt: CelestialSystem = _soi_targets[i]
		if tgt.dominant != null:
			(_soi_spheres[i] as Node3D).global_position = Vector3(
				tgt.dominant._wx - ox, tgt.dominant._wy - oy, tgt.dominant._wz - oz)


# 跨顶层收集聚焦天体(main_top 用)。
func _collect_focus_all() -> void:
	_focus_list.clear()
	for t in _get_all_tops():
		_collect_focus(t)


func _collect_focus(sys: CelestialSystem) -> void:
	for c in sys.members:
		_focus_list.append(c)
	for sub in sys.child_systems:
		_collect_focus(sub)


# 跨顶层收集所有系统的作用范围线框(main_top 用)。
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


# 顶层系统边界用不同颜色, 和子系统 Hill 球区分; 都用低透明度。shader discard 背面。
func _make_soi_material(target_sys: CelestialSystem) -> Material:
	var is_top: bool = target_sys.parent_system == null
	var col: Color = Color(1.0, 0.85, 0.3, 0.35) if is_top else Color(0.3, 0.85, 1.0, 0.35)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _SOI_SHADER_CODE
	mat.shader = sh
	mat.set_shader_parameter("line_color", col)
	return mat


# 经纬线网格球(线框)。n_lon 条经线(过两极) + n_lat-1 条纬线(水平圆), 用 PRIMITIVE_LINES。
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


func _update_camera_and_hud() -> void:
	if _focus_list.is_empty():
		return
	var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
	if orbit_camera != null:
		orbit_camera.target = (fc as Node3D).global_position
		if focus_idx != _last_focus_idx:
			orbit_camera.distance = fc.radius * 6.0
			_last_focus_idx = focus_idx
	if _hud != null and sim != null:
		_hud.text = "focus: %s   speed: %.1f   (TAB 聚焦  [/] 调速  F2 SOI  左键点击聚焦  滚轮缩放)\nenergy: %.3f" % [
			fc.name, sim_speed, sim.energy().get("total", 0.0)]


func _unhandled_input(event: InputEvent) -> void:
	if not _is_main_top:
		return
	# 左键: 短按(位移<6px) = 射线拾取天体聚焦; 拖动由 OrbitCamera 旋转, 不触发聚焦。
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


# 鼠标射线 → 和所有聚焦天体(跨顶层)做球相交 → 命中最近的就 focus_idx 指过去。
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


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	cl.add_child(_hud)
	_hud.position = Vector2(10, 40)
	_hud.add_theme_font_size_override("font_size", 14)
