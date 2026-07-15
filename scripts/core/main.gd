# gdlint: disable=variable-name, max-line-length
## 主场景控制:
## - CheckButton「跟随角色」: 轨道相机 ⇄ 跟随角色相机(仅运行时)。
## - CheckButton「显示线框」/ F1: 纯透视 wireframe(前后边都可见)。
extends Node

@export var camera: Camera3D
@export var player: Player
@export var toggle: CheckButton
@export var wire_toggle: CheckButton       # 显示线框(纯透视 wireframe)开关
@export var planet: Planet                 # 读 stats 刷新 FPS 行 / 控制 wireframe / LOD 聚焦目标
@export var fps_label: Label                # 右上角 FPS 显示(运行时每 0.25s 刷新)

var _orbit_parent: Node
var _orbit_transform: Transform3D
var _in_player_mode: bool = false
var _wireframe: bool = false
var _fps_acc: float = 0.0   # FPS 文本刷新累加器

# 出生点标记模式: 「跟随角色」按下 → 先标记(鼠标可见、轨道相机仍可拖动环视) → 空格确认瞬移角色 + 进角色模式。
var _aim_mode: bool = false
var _aim_target: Vector3 = Vector3.ZERO          # 已标记的地表点(世界)
var _aim_up: Vector3 = Vector3.UP                # 该点径向法线
var _aim_has_target: bool = false                # 是否已放过标记(空格确认的前提)
var _aim_press_pos: Vector2 = Vector2.ZERO       # 左键按下位置(拖拽阈值判定点击)
var _aim_pressing: bool = false
var _marker: SpawnMarker = null


func _ready() -> void:
	if camera != null:
		_orbit_parent = camera.get_parent()
		_orbit_transform = camera.global_transform
	if toggle != null:
		toggle.toggled.connect(_on_toggled)
		# 空格是跳跃键; CheckButton 带键盘焦点时会被空格切换 → 跳跃时误退出控制。
		toggle.focus_mode = Control.FOCUS_NONE
	if wire_toggle != null:
		wire_toggle.toggled.connect(_on_wire_toggled)
		wire_toggle.focus_mode = Control.FOCUS_NONE


func _process(delta: float) -> void:
	_update_fps(delta)
	# 标记随相机距离缩放: 拉远/拉近时屏幕大小稳定(否则全球视角下箭头小到看不见)。
	if _aim_mode and _marker != null and _marker.visible and _aim_has_target and camera != null:
		var d: float = camera.global_position.distance_to(_aim_target)
		var s: float = clampf(d / 300.0, 0.6, 12.0)
		_marker.scale = Vector3.ONE * s


func _update_fps(delta: float) -> void:
	if fps_label == null:
		return
	_fps_acc += delta
	if _fps_acc >= 0.25:
		_fps_acc = 0.0
		var line := "FPS:%d" % Engine.get_frames_per_second()
		if planet != null:
			# 用 get() 容错读取 stats。
			var st = planet.get("stats")
			if st is Dictionary:
				var tri_k := float(st.get("triangles", 0)) * 0.001
				line += "  patch:%d  tri:%.1fk  job:%d" % [st.get("patches", 0), tri_k, st.get("inflight", 0)]
		fps_label.text = line


func _unhandled_input(event: InputEvent) -> void:
	# ESC: 先退标记模式, 再退角色模式
	if event.is_action_pressed("ui_cancel"):
		if _aim_mode:
			_cancel_aim()
			return
		if _in_player_mode:
			if toggle != null:
				toggle.set_pressed_no_signal(false)
			_enter_orbit()
			return

	# 标记模式: 左键点击 = 放/移标记; 空格 = 确认瞬移 + 进角色模式
	if _aim_mode:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				_aim_press_pos = event.position
				_aim_pressing = true
			else:
				# 拖拽阈值: 区分"轨道拖动"(OrbitCamera 处理)与"点击标记"。位移 < 6px 视为点击。
				if _aim_pressing and event.position.distance_to(_aim_press_pos) < 6.0:
					_aim_click(event.position)
				_aim_pressing = false
			return
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
			if _aim_has_target:
				_commit_spawn()
			return

	# F1 纯透视线框(仅边、前后都可见) —— 与 CheckButton「显示线框」同步
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				_wireframe = not _wireframe
				if planet != null:
					planet.set_wireframe(_wireframe)
				if wire_toggle != null:
					wire_toggle.set_pressed_no_signal(_wireframe)


func _on_toggled(pressed: bool) -> void:
	if pressed:
		_enter_aim()
	else:
		if _in_player_mode:
			_enter_orbit()
		elif _aim_mode:
			_cancel_aim()


# 「显示线框」: 纯透视 wireframe(set_wireframe 同时关背面剔除 → 前后边都可见)
func _on_wire_toggled(on: bool) -> void:
	_wireframe = on
	if planet != null:
		planet.set_wireframe(on)


func _enter_player() -> void:
	if _in_player_mode or camera == null or player == null:
		return
	_in_player_mode = true
	_orbit_transform = camera.global_transform
	# 停用 OrbitCamera 脚本(否则它每帧把相机拉回轨道目标)
	camera.set_process(false)
	camera.set_process_unhandled_input(false)
	# 挂到角色相机槽位, 局部归零 → 完全跟随槽位变换(槽位由 player.gd 每帧摆好后上方)
	var slot: Node3D = player.camera_slot
	if slot != null:
		camera.reparent(slot, true)
		camera.transform = Transform3D.IDENTITY
	camera.current = true
	player.mouse_look = true
	# LOD 聚焦目标改为角色(细分围绕角色而非相机)
	if planet != null:
		planet.lod_target = player
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if toggle != null:
		toggle.set_pressed_no_signal(true)   # 标记→确认瞬移后, 按钮=按下态


func _enter_orbit() -> void:
	if not _in_player_mode:
		return
	_in_player_mode = false
	if player != null:
		player.mouse_look = false
	# LOD 聚焦目标恢复为相机
	if planet != null:
		planet.lod_target = null
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if camera != null and _orbit_parent != null:
		camera.reparent(_orbit_parent, true)
		camera.global_transform = _orbit_transform
		camera.current = true
		camera.set_process(true)
		camera.set_process_unhandled_input(true)


# ===================== 出生点标记模式 =====================
# 「跟随角色」按下 → 进标记模式(不直接进角色模式): 鼠标可见, 轨道相机仍可左键拖动环视;
# 左键点击地表 → 放/移箭头标记(可重复覆盖); 空格 → 瞬移角色到标记点 + 进角色模式; ESC → 取消。
func _enter_aim() -> void:
	if _in_player_mode or _aim_mode or camera == null or player == null or planet == null:
		return
	_aim_mode = true
	_aim_has_target = false
	_aim_pressing = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)   # 显示光标好点选
	if _marker == null:
		_marker = SpawnMarker.new()
		_marker.name = "SpawnMarker"
		add_child(_marker)
	_marker.visible = false


func _cancel_aim() -> void:
	_aim_mode = false
	if toggle != null:
		toggle.set_pressed_no_signal(false)
	if _marker != null:
		_marker.visible = false


# 鼠标射线 → 行星基础球面相交 → 该方向径向 → height_at 算位移后地表点 + 法线 → 放标记。
# 地形是 GPU 位移的, CPU 无精确网格; 用基础球面(R)求视线方向, 再用解析高度沿径向贴到真实地表。
func _aim_click(mouse_pos: Vector2) -> void:
	if camera == null or planet == null:
		return
	var origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var rdir: Vector3 = camera.project_ray_normal(mouse_pos)
	var center: Vector3 = planet.global_position
	var R: float = planet.params.radius
	var oc: Vector3 = origin - center
	var bb: float = oc.dot(rdir)
	var cc: float = oc.dot(oc) - R * R
	var disc: float = bb * bb - cc
	if disc < 0.0:
		return   # 点到天空了 → 忽略
	var sq: float = sqrt(disc)
	var t: float = -bb - sq          # 近交点(相机在球外)
	if t < 0.0:
		t = -bb + sq                # 相机在球内 → 取远交点
	if t < 0.0:
		return
	var nd: Vector3 = (origin + rdir * t - center).normalized()
	var h: float = planet.height_at(nd.x, nd.y, nd.z)
	var surf: Vector3 = center + nd * (R + h * planet.params.maxHeight)
	_aim_target = surf
	_aim_up = nd
	_aim_has_target = true
	if _marker != null:
		_marker.place(surf, nd)


# 空格确认: 瞬移角色到标记点 → 进角色模式。
func _commit_spawn() -> void:
	if not _aim_has_target or player == null:
		return
	_aim_mode = false
	if _marker != null:
		_marker.visible = false
	player.teleport_to(_aim_target, _aim_up)
	_enter_player()
