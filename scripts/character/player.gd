# gdlint: disable=variable-name, max-line-length
## 玩家表面漫游: 径向重力 + 解析贴地(不用碰撞体)。
## 球体是无缝 LOD 四叉树 mesh, 每帧随相机分裂/合并, 逐 patch 生成/更新 Jolt 碰撞体代价过高;
## 而 terrain 是单值径向高度场, planet.height_at(dir) 直接给出任意方向的精确地面半径 →
## 解析贴地最合适(对齐 web character.js 的 groundRadius 思路)。
## CharacterBody3D 仅作载体节点; 行星碰撞不依赖它的 CollisionShape3D(留给以后物体间碰撞)。
class_name Player
extends CharacterBody3D

@export var planet: Planet
@export var feet_offset: float = 1.0        # 胶囊中心到脚底的偏移(贴地距离)
@export var camera_slot: Node3D             # 第三人称相机挂点(运行时每帧驱动其全局变换)
@export var mouse_look: bool = false        # true: 鼠标接管朝向(相机控制角色模式)
@export var mouse_sensitivity: float = 0.0025
@export var cam_height: float = 2.5         # 相机枢轴高出角色的距离
@export var cam_distance: float = 6.0       # 相机离枢轴(角色)的距离
@export var cam_pitch_min: float = -0.4
@export var cam_pitch_max: float = 1.3
@export var cam_distance_min: float = 3.0   # 滚轮拉近下限
@export var cam_distance_max: float = 40.0  # 滚轮拉远上限
@export var cam_zoom_step: float = 1.0      # 滚轮每格缩放距离

var _yaw: float = 0.0           # 朝向角(绕径向 up 旋转)
var _vel: Vector3 = Vector3.ZERO
var _on_ground: bool = true
var _cam_pitch: float = 0.35        # 相机俯仰(绕枢轴的仰角)
var _initialized: bool = false      # 首帧(terrain 就绪后)贴地初始化
var _jump_prev: bool = false        # 上一帧跳跃键状态(边沿检测)


func _ready() -> void:
	# 自动找 Planet 祖先(Player 预制体一般作为 Planet 的子节点)
	if planet == null:
		var p := get_parent()
		while p != null:
			if p is Planet:
				planet = p
				break
			p = p.get_parent()
	# 找相机挂点(预制体里 Player 根下的 CameraSlot, 与本节点同级)
	if camera_slot == null:
		camera_slot = get_parent().get_node_or_null("CameraSlot")
	# Player 是 Planet 的子节点 → 本节点 _ready 早于 Planet._ready(terrain 尚未建),
	# 此处不采样高度; 贴地/朝向推迟到 _physics_process 首帧(terrain 届时已建)。


func _physics_process(delta: float) -> void:
	# terrain 由 Planet._ready 构建; 子节点 _ready 早于父节点, 首帧前 terrain 可能仍为 null。
	if planet == null or not is_instance_valid(planet) or planet.terrain == null:
		return
	if not _initialized:
		_initialized = true
		_snap_to_surface()
		_align_basis()
	var center: Vector3 = planet.global_position
	var pos: Vector3 = global_position - center
	var up: Vector3 = pos.normalized() if pos.length_squared() > 1e-6 else Vector3.UP

	# 切向基: forward 在切平面里(世界 FORWARD 投影), 再绕 up 转 _yaw
	var fwd: Vector3 = _tangent_forward(up)
	var right: Vector3 = fwd.rotated(up, PI / 2.0)

	# 输入(直接读物理键, 不依赖 InputMap —— 规避 action 未注册/解析时静默返回 0 的风险)
	var in_fwd: float = _key(KEY_W) - _key(KEY_S)
	var in_right: float = _key(KEY_A) - _key(KEY_D)
	if Input.is_physical_key_pressed(KEY_Q):
		_yaw += planet.params.turnSpeed * delta
	if Input.is_physical_key_pressed(KEY_E):
		_yaw -= planet.params.turnSpeed * delta

	# 切向速度(定速; 释放即停) —— 速度来自 PlanetParams.walkSpeed
	var wish: Vector3 = fwd * in_fwd + right * in_right
	var tangent_v: Vector3 = wish.normalized() * planet.params.walkSpeed if wish.length() > 1e-4 else Vector3.ZERO

	# 径向分量: 重力下拉 + 起跳(沿当前 up) —— 来自 PlanetParams
	var radial_v: float = _vel.dot(up)
	radial_v -= planet.params.gravity * delta
	var jump_now: bool = Input.is_physical_key_pressed(KEY_SPACE)
	if _on_ground and jump_now and not _jump_prev:
		radial_v = planet.params.jumpForce
	_jump_prev = jump_now

	# 积分: 切向 + 径向
	global_position += (tangent_v + up * radial_v) * delta

	# 用【移动后】的位置重算径向再贴地 —— 否则切向位移会被旧径向线吸回原地(= 移不动)
	_reground(center, tangent_v, radial_v)
	_align_basis()
	var new_up: Vector3 = (global_position - center).normalized()
	_update_camera_slot(new_up, _tangent_forward(new_up))


# 物理键按住 → 1.0 / 0.0
func _key(code: int) -> float:
	return 1.0 if Input.is_physical_key_pressed(code) else 0.0


# 地面世界半径 = 行星半径 + 该方向高度 × 高度振幅
func _ground_radius(up: Vector3) -> float:
	var h: float = planet.height_at(up.x, up.y, up.z)
	return planet.params.radius + h * planet.params.maxHeight


# 世界 FORWARD 投影到切平面 → 归一 → 绕 up 转 _yaw 得当前朝向
func _tangent_forward(up: Vector3) -> Vector3:
	var f: Vector3 = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	if f.length_squared() < 1e-6:
		f = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	return f.normalized().rotated(up, _yaw)


# 移动后贴地: 用【新位置】的径向重算地面半径。
# 行走时切向位移会让半径略增(√(R²+step²)), 必须用新径向 + 一个贴合带判定,
# 否则会被旧径向线吸回帧初位置 → 切向位移每帧被抹掉, 表现为"按方向键不动"。
func _reground(center: Vector3, tangent_v: Vector3, radial_v: float) -> void:
	var pos: Vector3 = global_position - center
	var new_up: Vector3 = pos.normalized() if pos.length_squared() > 1e-6 else Vector3.UP
	var min_dist: float = _ground_radius(new_up) + feet_offset
	var dist: float = pos.length()
	var stick: float = 1.0   # 切向移动会微微浮离表面, 留贴合带避免每帧被判"离地"
	if dist <= min_dist or (radial_v <= 0.0 and dist <= min_dist + stick):
		global_position = center + new_up * min_dist
		_vel = tangent_v            # 贴地: 径向归零, 只剩切向
		_on_ground = true
	else:
		_vel = tangent_v + new_up * radial_v
		_on_ground = false


func _snap_to_surface() -> void:
	if planet == null:
		return
	var center: Vector3 = planet.global_position
	var pos: Vector3 = global_position - center
	var up: Vector3 = pos.normalized() if pos.length_squared() > 1e-6 else Vector3.UP
	global_position = center + up * (_ground_radius(up) + feet_offset)


# 让模型 +Y 指向径向外(站直), -Z 指向朝向(以后挂相机用)
func _align_basis() -> void:
	if planet == null:
		return
	var up: Vector3 = (global_position - planet.global_position).normalized()
	var fwd: Vector3 = _tangent_forward(up)
	var right: Vector3 = fwd.rotated(up, PI / 2.0)
	var b := Basis()
	b.x = right
	b.y = up
	b.z = -fwd
	global_transform.basis = b.orthonormalized()


func _unhandled_input(event: InputEvent) -> void:
	# 相机控制角色模式: 鼠标横向转角色朝向, 纵向调相机俯仰
	if mouse_look and event is InputEventMouseMotion:
		_yaw -= event.relative.x * mouse_sensitivity
		# 纵向受 PlanetParams.invertY 控制: true=反转(保持当前手感), false=正向
		var pitch_sgn := 1.0 if (planet != null and planet.params.invertY) else -1.0
		_cam_pitch = clampf(_cam_pitch + event.relative.y * mouse_sensitivity * pitch_sgn, cam_pitch_min, cam_pitch_max)
	elif mouse_look and event is InputEventMouseButton and event.is_pressed():
		# 滚轮缩放相机距离(俯仰不变, 仅拉远/拉近)
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				cam_distance = maxf(cam_distance_min, cam_distance - cam_zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				cam_distance = minf(cam_distance_max, cam_distance + cam_zoom_step)


# 第三人称相机挂点: 绕角色上方枢轴, 按俯仰角摆在角色后上方并 look_at 枢轴。
# 相机被 reparent 到 camera_slot 下后即跟随此处变换(见 main.gd)。
func _update_camera_slot(up: Vector3, fwd: Vector3) -> void:
	if camera_slot == null:
		return
	var pivot: Vector3 = global_position + up * cam_height
	var off: Vector3 = (-fwd * cos(_cam_pitch) + up * sin(_cam_pitch)) * cam_distance
	camera_slot.global_position = pivot + off
	camera_slot.look_at(pivot, up)
