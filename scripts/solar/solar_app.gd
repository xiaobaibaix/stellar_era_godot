## 太阳系主控(Phase 4 第 3 步)。挂 SolarSystem 根节点。
## - 从场景解析 恒星/行星/卫星 → N 体内核; 行星绕恒星、卫星绕所属行星(嵌套圆轨道)。
## - 每帧推进物理 + 浮动原点(=聚焦体 double 位置) + 把 double 位置转成【相对原点】的 32 位 Vector3
##   驱动各 Node3D → 大尺度坐标不抖。
## - 轨道相机跟随聚焦体; TAB 切换聚焦; [/] 调时间倍率。
class_name SolarApp
extends Node

@export_group("物理")
@export var G: float = 1.0
@export var sun_mass: float = 1000000.0
@export var planet_mass: float = 60.0
@export var moon_mass: float = 0.5
@export var softening: float = 10.0
@export_range(0.0, 2.0, 0.01) var dt_fixed: float = 0.5
@export_range(1, 8, 1) var substeps: int = 2
@export_range(0.0, 10.0, 0.1) var sim_speed: float = 1.0

@export_group("轨道布局(节点已在编辑器定位时用其距离, 否则用默认)")
@export var planet_dist_base: float = 3500.0
@export var planet_dist_step: float = 3000.0
@export var moon_dist: float = 600.0
@export var sun_visual_scale: float = 800.0

var sim: NBodySystem
var sun_body: Body
var bindings: Array = []          # [{body, node, planet(可 null), view_dist}]
var cam: OrbitCamera
var focus_idx: int = 0
# 浮动原点(聚焦体 double 位置; 用标量存, 不并 Vector3 保 64 位)
var _ox: float = 0.0; var _oy: float = 0.0; var _oz: float = 0.0
var _hud: Label


func _ready() -> void:
	sim = NBodySystem.new(G, softening)
	_create_camera()
	# —— 恒星 ——
	var sun_node: Node3D = get_node_or_null("Sun")
	sun_body = Body.new("Sun", sun_mass)
	sun_body.type = "star"
	sim.add(sun_body)
	if sun_node:
		sun_node.scale = Vector3.ONE * sun_visual_scale
		_bind(sun_body, sun_node, planet_dist_base * 4.0)
	# 场景里的点光源挂到太阳下 → 随太阳走(浮动原点下也始终在太阳处)
	var omni: Node3D = get_node_or_null("OmniLight3D")
	if omni and sun_node:
		omni.reparent(sun_node)
	# —— 行星 + 其下卫星 ——
	var pc: Node3D = get_node_or_null("Planets")
	if pc:
		var pidx := 0
		for child in pc.get_children():
			if not (child is Planet):
				continue
			var pn: Planet = child
			var dist := float(pn.global_position.length())       # 距太阳(原点)
			if dist < 1.0:
				dist = planet_dist_base + pidx * planet_dist_step
			var pb := sim.add_orbiting(sun_body, {
				"mass": planet_mass, "dist": dist, "phase": pidx * 1.7,
				"name": pn.name, "type": "planet",
			})
			pb.radius = pn.params.radius if pn.params != null else 300.0
			_bind(pb, pn, pb.radius * 4.0)
			pn.camera = cam                                         # 行星 LOD 用同一相机
			pidx += 1
			# 该行星的卫星(场景里挂在行星下)
			var midx := 0
			for gc in pn.get_children():
				if not gc.name.begins_with("Satellite"):
					continue
				var sn: Node3D = gc
				var mdist := float(sn.global_position.distance_to(pn.global_position))
				if mdist < 1.0:
					mdist = moon_dist + midx * 200.0
				var mb := sim.add_orbiting(pb, {
					"mass": moon_mass, "dist": mdist, "phase": midx * 2.1,
					"inclination": 0.2, "name": sn.name, "type": "moon",
				})
				_bind(mb, sn, mdist * 0.6)
				midx += 1
	sim.zero_momentum()                       # 质心不漂移
	focus_idx = 0
	_apply_focus_distance()
	_create_hud()


func _physics_process(_delta: float) -> void:
	if sim == null:
		return
	# 推进物理(子步提稳定性)
	var dt := dt_fixed * sim_speed
	var sub := max(substeps, 1)
	for _i in range(sub):
		sim.step(dt / float(sub))
	# 浮动原点 = 聚焦体
	var fb: Body = _focus_body()
	_ox = fb.px; _oy = fb.py; _oz = fb.pz
	# 驱动所有节点(相对原点的 32 位 Vector3; 数值小, 不抖)
	for b in bindings:
		(b.node as Node3D).global_position = b.body.pos_relative(_ox, _oy, _oz)
	# 相机跟随聚焦节点
	if cam != null and not bindings.is_empty():
		cam.target = (bindings[focus_idx % bindings.size()].node as Node3D).global_position
	_update_planet_sun_dirs()
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				focus_idx = (focus_idx + 1) % max(bindings.size(), 1)
				_apply_focus_distance()
			KEY_BRACKETRIGHT:
				sim_speed = min(sim_speed + 0.2, 10.0)
			KEY_BRACKETLEFT:
				sim_speed = max(sim_speed - 0.2, 0.0)


func _bind(body: Body, node: Node3D, view_dist: float) -> void:
	bindings.append({"body": body, "node": node, "planet": (node as Planet), "view_dist": view_dist})


func _focus_body() -> Body:
	if bindings.is_empty():
		return sun_body
	return bindings[focus_idx % bindings.size()].body


# 每个行星的大气 sun_dir 指向恒星: 写 params.sunElevation/Azimuth → 触发 planet._update_sun。
func _update_planet_sun_dirs() -> void:
	if sun_body == null:
		return
	for b in bindings:
		var p: Planet = b.planet
		if p == null or p.params == null:
			continue
		var dx: float = sun_body.px - b.body.px
		var dy: float = sun_body.py - b.body.py
		var dz: float = sun_body.pz - b.body.pz
		var len := sqrt(dx * dx + dy * dy + dz * dz)
		if len < 1e-6:
			continue
		p.params.sunElevation = rad_to_deg(asin(clamp(dy / len, -1.0, 1.0)))
		p.params.sunAzimuth = rad_to_deg(atan2(dz, dx))


func _apply_focus_distance() -> void:
	if cam != null and not bindings.is_empty():
		cam.distance = bindings[focus_idx % bindings.size()].view_dist


func _create_camera() -> void:
	cam = OrbitCamera.new()
	cam.name = "SolarCamera"
	add_child(cam)
	cam.current = true
	cam.target = Vector3.ZERO
	cam.distance = planet_dist_base * 4.0


func _create_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	cl.add_child(_hud)
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)


func _update_hud() -> void:
	if _hud == null or sim == null:
		return
	var fb: Body = _focus_body()
	var e: Dictionary = sim.energy()
	_hud.text = "focus: %s   sim_speed: %.1f   (TAB 聚焦  [/] 调速)\nenergy: %s" % [fb.name, sim_speed, e.get("total", 0.0)]
