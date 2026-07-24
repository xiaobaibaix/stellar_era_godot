# gdlint: disable=variable-name, max-line-length
## 相机导演: 按键(默认 M)在两种模式间切换 ——
##   CHARACTER: 相机贴到角色, 由 character_controller 第三人称驱动(捕获鼠标看向)。
##   PLANET:    相机拉远聚焦星球, 由 OrbitCamera 驱动(左键拖拽 / 滚轮缩放)。
##
## 全场景共用**一台**相机(= orbit_camera 指向的那台, 同时也是角色的 external_camera)。切换只是把这台
## 相机的"驱动权"在 角色控制器 ↔ 轨道相机脚本 之间交接, 并切鼠标模式。因为始终是同一台相机,
## GpuPlanet.camera 指向它即可, LOD/剔除自动跟随当前视角, 两模式都正确。
##
## 非侵入: 不改角色/轨道相机脚本。角色侧靠公开的 set_camera_active(); 轨道相机侧靠 set_process() /
## set_process_unhandled_input()(内置方法, 决定其 _process / _unhandled_input 是否触发)。
extends Node

enum Mode { CHARACTER, PLANET }

## 挂 character_controller.gd 的角色节点(需提供 set_camera_active(bool))。
@export var character: Node
## 聚焦星球的轨道相机(OrbitCamera; 也就是全场景共用的那台相机)。
@export var orbit_camera: OrbitCamera
## 星球(用于把轨道相机的聚焦目标/距离按半径自适应, 避免相机落进星球内部)。
@export var planet: GpuPlanet
## 切换键(默认 M)。
@export var toggle_key: Key = KEY_M
## 起始模式。
@export var start_mode: Mode = Mode.CHARACTER

var _mode: int = Mode.CHARACTER


func _ready() -> void:
	_mode = start_mode
	# 延迟到所有节点 _ready 之后再应用初始模式, 避免与角色/轨道相机自身 _ready 初始化的时序打架。
	_apply_mode.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == toggle_key:
		toggle()


## 在两模式间切换。
func toggle() -> void:
	_mode = (Mode.PLANET if _mode == Mode.CHARACTER else Mode.CHARACTER)
	_apply_mode()


## 直接设定模式(Mode.CHARACTER / Mode.PLANET)。
func set_mode(m: int) -> void:
	_mode = m
	_apply_mode()


func get_mode() -> int:
	return _mode


func _apply_mode() -> void:
	var to_character := _mode == Mode.CHARACTER
	# 把相机**重挂**到当前聚焦对象下: 角色模式 → 挂到角色; 星球模式 → 挂回星球。
	# keep_global_transform=true → 世界位姿不变, 切换不跳。于是"聚焦谁相机就在谁身上", 驱动权随之交接。
	if orbit_camera != null:
		var new_parent: Node = character if to_character else planet
		if new_parent != null and orbit_camera.get_parent() != new_parent:
			orbit_camera.reparent(new_parent, true)
	# 轨道相机: 角色模式关掉(停自我摆位 + 停左键/滚轮), 星球模式开。
	if orbit_camera != null:
		orbit_camera.set_process(not to_character)
		orbit_camera.set_process_unhandled_input(not to_character)
		if not to_character:
			_focus_planet()              # 按半径把聚焦目标/距离调好, 避免相机落进星球里
			orbit_camera.current = true   # 回到星球模式确保它是渲染相机
	# 角色相机驱动: 角色模式交给角色(内部会设 current + 捕获鼠标), 星球模式收回。
	if character != null and character.has_method("set_camera_active"):
		character.set_camera_active(to_character)
	# 鼠标模式: 第三人称要捕获看向; 轨道要可见以便左键拖拽。
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if to_character else Input.MOUSE_MODE_VISIBLE


# 切到星球视角: 相机绕【球心】旋转(不是角色)。按半径把目标/距离调好, 保证相机在星球外部、
# 缩放不进球内(半径变了也自适应)。角色相对星球很小, 整球视角下会小到看不见, 属正常。
func _focus_planet() -> void:
	if orbit_camera == null:
		return
	var center: Vector3 = planet.global_position if planet != null else Vector3.ZERO
	var r: float = 100.0
	if planet != null and planet.params != null:
		r = planet.params.radius
	orbit_camera.target = center
	orbit_camera.min_distance = maxf(r * 1.1, 2.0)      # 禁止缩放进球内
	orbit_camera.max_distance = maxf(orbit_camera.max_distance, r * 8.0)
	# 距离若在球内/太近, 拉到能看到整颗星球的观察距离(保留用户已有的更远缩放)。
	if orbit_camera.distance < r * 1.2:
		orbit_camera.set_orbit(center, r * 2.5)
