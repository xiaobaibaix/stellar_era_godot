# gdlint: disable=variable-name, max-line-length
## 主场景控制: CheckButton 在「轨道相机」与「跟随角色相机」间切换。
## 跟随模式: 把 Camera3D reparent 到角色的 camera_slot 下(槽位全局变换由 player.gd 每帧驱动),
##           关掉 OrbitCamera 脚本, 捕获鼠标 → 鼠标横向转角色朝向、纵向调相机俯仰。
## ESC 退回轨道模式。
extends Node

@export var camera: Camera3D
@export var player: Player
@export var toggle: CheckButton

var _orbit_parent: Node
var _orbit_transform: Transform3D
var _in_player_mode: bool = false


func _ready() -> void:
	if camera != null:
		_orbit_parent = camera.get_parent()
		_orbit_transform = camera.global_transform
	if toggle != null:
		toggle.toggled.connect(_on_toggled)
		# 空格是跳跃键; CheckButton 带键盘焦点时会被空格切换 → 跳跃时误退出控制。
		# 关掉它的键盘焦点, 只用鼠标点击操作。
		toggle.focus_mode = Control.FOCUS_NONE


func _unhandled_input(event: InputEvent) -> void:
	# ESC 退回轨道相机
	if _in_player_mode and event.is_action_pressed("ui_cancel"):
		if toggle != null:
			toggle.set_pressed_no_signal(false)
		_enter_orbit()


func _on_toggled(pressed: bool) -> void:
	if pressed:
		_enter_player()
	else:
		_enter_orbit()


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
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _enter_orbit() -> void:
	if not _in_player_mode:
		return
	_in_player_mode = false
	if player != null:
		player.mouse_look = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if camera != null and _orbit_parent != null:
		camera.reparent(_orbit_parent, true)
		camera.global_transform = _orbit_transform
		camera.current = true
		camera.set_process(true)
		camera.set_process_unhandled_input(true)
