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
	# ESC 退回轨道相机
	if _in_player_mode and event.is_action_pressed("ui_cancel"):
		if toggle != null:
			toggle.set_pressed_no_signal(false)
		_enter_orbit()
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
		_enter_player()
	else:
		_enter_orbit()


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
