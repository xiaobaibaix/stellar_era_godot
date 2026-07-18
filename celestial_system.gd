## 递归天体系统节点(第1步:静态嵌套轨道, 暂不做飞船 / SOI)。
##
## 自相似: 恒星系是一个 CelestialSystem, 行星系(行星+卫星)也是 CelestialSystem。
## 物理: 每层持自己的 NBodySystem(复用 scripts/solar/nbody_system.gd), 只算本层成员。
## 耦合: 子 CelestialSystem 在父层注册为一个"质点 body"(质量=子系统总质量),
##       随父层 sim 积分 → 整体轨道; 子层内部独立积分 → 相对轨道。叠加 = 嵌套。
## 坐标: 成员 body.p 是【相对本系统主导体】的 double; 世界 double = world_barycenter + body.p;
##       渲染 = 世界 double − 全局浮动原点 → 32 位 global_position(大尺度不抖)。
## 顶层(parent 不是 CelestialSystem): 额外管 浮动原点 / 轨道相机 / HUD / TAB 聚焦 / [/] 调速。
class_name CelestialSystem
extends Node3D

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

var parent_system: CelestialSystem = null

# 本系统主导体的【世界 double 位置】(父层每帧下传; 顶层 = 0)
var _bcx: float = 0.0
var _bcy: float = 0.0
var _bcz: float = 0.0
# 全局浮动原点(仅顶层写; 渲染时下传所有层)
var _ox: float = 0.0
var _oy: float = 0.0
var _oz: float = 0.0

var _hud: Label = null
var focus_idx: int = 0
var _focus_list: Array = []       # Array[Celestial] 递归收集, 顶层聚焦用


func _ready() -> void:
	sim = NBodySystem.new(G, softening)
	parent_system = get_parent() as CelestialSystem
	_collect()
	_init_physics()
	if parent_system == null:
		_build_hud()
		_collect_focus(self)


func _collect() -> void:
	for c in get_children():
		if c is Celestial:
			members.append(c)
			if c.is_dominant and dominant == null:
				dominant = c
		elif c is CelestialSystem:
			child_systems.append(c)


# 建本层 sim: 主导体放原点, 其余绕主导体; 子系统作质点绕主导体。
# 依赖子系统已 _ready(自底向上) → 能取 sub.get_total_mass() 与 sub.position。
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
		# 非主导 Celestial: 圆轨道, 半径 = 编辑器里到主导体的距离
		var idx := 0
		for c in members:
			if c == dominant:
				continue
			var dist := float((c.position - dominant.position).length())
			if dist < 1.0:
				dist = 2000.0 + float(idx) * 1000.0
			var b: Body = sim.add_orbiting(db, {
				"mass": c.mass, "dist": dist, "phase": idx * 1.7,
				"inclination": 0.25 if c.type == "moon" else 0.0,
				"name": c.name, "type": c.type,
			})
			b.radius = c.radius
			b.color = c.color
			c.body = b
			c.owner_system = self
			idx += 1
		# 子 CelestialSystem → 质点 body(质量=总质量, 绕主导体)
		var sidx := 0
		for sub in child_systems:
			var sdist := float((sub.position - dominant.position).length())
			if sdist < 1.0:
				sdist = 5000.0 + float(sidx) * 4000.0
			var proxy: Body = sim.add_orbiting(db, {
				"mass": float(sub.get_total_mass()), "dist": sdist,
				"phase": sidx * 2.3 + 0.5, "name": sub.name, "type": "system",
			})
			child_proxy[sub] = proxy
			sidx += 1
	if parent_system == null:
		sim.zero_momentum()                    # 顶层归零总动量 → 质心不漂移


# 子系统总质量(供父层作质点质量)。递归。
func get_total_mass() -> float:
	var m := 0.0
	for c in members:
		m += c.mass
	for sub in child_systems:
		m += sub.get_total_mass()
	return m


# 子层 _physics_process 不做事(由父层 _step_recursive 递归驱动)。
func _physics_process(_delta: float) -> void:
	if parent_system != null:
		return
	_frame()


# 顶层一帧: step 整棵树 → 定浮动原点 → 渲染整棵树 → 相机/HUD。
func _frame() -> void:
	_step_recursive()
	if not _focus_list.is_empty():
		var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
		_ox = fc._wx
		_oy = fc._wy
		_oz = fc._wz
	_render_recursive(_ox, _oy, _oz)
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


# 自顶向下写 global_position(世界 double − 浮动原点)。
func _render_recursive(ox: float, oy: float, oz: float) -> void:
	for c in members:
		if c.body == null:
			continue
		(c as Node3D).global_position = Vector3(c._wx - ox, c._wy - oy, c._wz - oz)
	for sub in child_systems:
		sub._render_recursive(ox, oy, oz)


func _collect_focus(sys: CelestialSystem) -> void:
	for c in sys.members:
		_focus_list.append(c)
	for sub in sys.child_systems:
		_collect_focus(sub)


func _update_camera_and_hud() -> void:
	if _focus_list.is_empty():
		return
	var fc: Celestial = _focus_list[focus_idx % _focus_list.size()]
	if orbit_camera != null:
		orbit_camera.target = (fc as Node3D).global_position
		orbit_camera.distance = fc.radius * 6.0
	if _hud != null and sim != null:
		_hud.text = "focus: %s   speed: %.1f   (TAB 聚焦  [/] 调速)\nenergy: %.3f" % [
			fc.name, sim_speed, sim.energy().get("total", 0.0)]


func _unhandled_input(event: InputEvent) -> void:
	if parent_system != null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				focus_idx = (focus_idx + 1) % max(_focus_list.size(), 1)
			KEY_BRACKETRIGHT:
				sim_speed = min(sim_speed + 0.2, 10.0)
			KEY_BRACKETLEFT:
				sim_speed = max(sim_speed - 0.2, 0.0)


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	cl.add_child(_hud)
	_hud.position = Vector2(10, 40)
	_hud.add_theme_font_size_override("font_size", 14)
