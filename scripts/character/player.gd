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
@export var cam_ground_margin: float = 1.5  # 相机与地面的最小间隙(解析碰撞留白, 防贴面 z-fight/穿透)
@export var cam_collision_min: float = 1.5  # 相机被地形顶死时离枢轴的最小距离(防退化 look_at/钻进角色)
@export var cam_collision_steps: int = 10   # 弹簧臂沿视线的探测步数(越多越贴合, 越费; 地形平滑 10 足够)

var _yaw: float = 0.0           # 朝向角(绕径向 up 旋转)
var _vel: Vector3 = Vector3.ZERO
var _on_ground: bool = true
var _cam_pitch: float = 0.35        # 相机俯仰(绕枢轴的仰角)
var _initialized: bool = false      # 首帧(terrain 就绪后)贴地初始化
var _jump_prev: bool = false        # 上一帧跳跃键状态(边沿检测)
var _block_jump_until_release: bool = false   # 瞬移吃掉触发用的空格, 避免落地即跳(松开后恢复)
# 持久化切向基朝向(yaw=0 时)。平行传输: 每帧投影到当前切平面 → 消除"用固定 Vector3.FORWARD 投影"
# 在 ±Z 极点附近的奇点(FORWARD·up→±1 时投影长度→0, normalized 后方向乱跳 → 玩家在该位置绕圈)。
var _base_fwd: Vector3 = Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	# 自动找 Planet 祖先(Player 预制体一般作为 Planet 的子节点)
	if planet == null:
		var p := get_parent()
		while p != null:
			if p is Planet:
				planet = p
				break
			p = p.get_parent()
	# 找相机挂点(Player 根下的 CameraSlot 直接子节点)
	if camera_slot == null:
		camera_slot = get_node_or_null("CameraSlot")
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

	# 平行传输: 把上一帧的 _base_fwd 投影到当前切平面(只去掉 up 分量)→ 切向 forward 平滑随玩家位置变化,
	# 没有奇点。取代旧的"每帧从 Vector3.FORWARD 投影"—— 那在 up≈±Z(行星 Z 极点附近)投影长度→0,
	# normalized 后方向乱跳, 表现为"玩家走到该位置按直走却绕圈"。
	_parallel_transport_base_fwd(up)

	# 切向基: forward = _base_fwd 绕 up 转 _yaw
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
	var space_pressed: bool = Input.is_physical_key_pressed(KEY_SPACE)
	# 标记模式空格确认瞬移后, 屏蔽这"一下"空格 → 避免落地即跳; 直到松开空格才恢复跳跃。
	var jump_now: bool = space_pressed
	if _block_jump_until_release:
		jump_now = false
		if not space_pressed:
			_block_jump_until_release = false
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


# 平行传输持久化的 _base_fwd 到当前切平面: 只去掉 up 分量, 不再依赖固定 Vector3.FORWARD。
# 这样切向 forward 随玩家位置连续变化, 消除 ±Z 极点附近的奇点。
func _parallel_transport_base_fwd(up: Vector3) -> void:
	var proj: Vector3 = _base_fwd - up * _base_fwd.dot(up)
	if proj.length_squared() > 1e-6:
		_base_fwd = proj.normalized()
		return
	# 反极点罕见情形: _base_fwd 与 up 平行(投影=0)→ 找一个不平行于 up 的世界轴投影, 重置 _base_fwd。
	for c in [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD]:
		var p: Vector3 = c - up * c.dot(up)
		if p.length_squared() > 1e-6:
			_base_fwd = p.normalized()
			return


# _base_fwd 绕 up 转 _yaw 得当前朝向(_base_fwd 已由 _parallel_transport_base_fwd 投影到切平面)
func _tangent_forward(up: Vector3) -> Vector3:
	return _base_fwd.rotated(up, _yaw)


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


## 瞬移到出生点(标记模式空格确认时调用)。
## world_pos 已是位移后地表点; up = 该点径向法线。复用解析贴地: 设位 → 沿径向重贴 → 对齐基 → 刷相机槽位。
## 清速度/归零 yaw, 避免瞬移后带惯性或朝向错乱。
func teleport_to(world_pos: Vector3, up: Vector3) -> void:
	if planet == null or not is_instance_valid(planet):
		return
	global_position = world_pos
	_yaw = 0.0
	# 重置 _base_fwd 到新位置的切平面: 投影 FORWARD, 退化时用 RIGHT(同首帧逻辑)。
	# 否则瞬移后 _base_fwd 还是旧位置的, 在新切平面外 → 投影会大幅旋转, 朝向突变。
	var f: Vector3 = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	if f.length_squared() < 1e-6:
		f = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	_base_fwd = f.normalized()
	_vel = Vector3.ZERO
	_on_ground = true
	_block_jump_until_release = true   # 吃掉触发瞬移的这次空格, 避免落地即跳
	_snap_to_surface()
	_align_basis()
	var new_up: Vector3 = (global_position - planet.global_position).normalized()
	_update_camera_slot(new_up, _tangent_forward(new_up))


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
# 解析弹簧臂: 沿视线方向探测球面高度场, 相机被地形顶住时收拢向角色 → 永不钻到地形以下。
func _update_camera_slot(up: Vector3, fwd: Vector3) -> void:
	if camera_slot == null:
		return
	var pivot: Vector3 = global_position + up * cam_height
	# 相机相对枢轴的方向(含俯仰): _cam_pitch<0 时指向斜下方, 正是会钻进地形的情形。
	var dir: Vector3 = (-fwd * cos(_cam_pitch) + up * sin(_cam_pitch)).normalized()
	var safe_dist: float = _camera_arm_length(pivot, dir, cam_distance)
	camera_slot.global_position = pivot + dir * safe_dist
	camera_slot.look_at(pivot, up)


# 相机碰撞(解析高度场, 与 _reground 同源): 从枢轴沿 dir 步进到 desired 距离,
# 逐点用【该点自身径向】的地面半径判定(相机远离时脚下地面方向已随球面弯曲改变);
# 一旦某点低于 地面半径+cam_ground_margin, 就停在上一个安全距离 → 相机贴着地面滑向角色。
# 无碰撞体开销: 每帧至多 cam_collision_steps 次 height_at, 与角色贴地同量级。
func _camera_arm_length(pivot: Vector3, dir: Vector3, desired: float) -> float:
	var center: Vector3 = planet.global_position
	var steps: int = maxi(cam_collision_steps, 1)
	var safe: float = 0.0
	for i in range(1, steps + 1):
		var d: float = desired * float(i) / float(steps)
		var p: Vector3 = pivot + dir * d
		var radial: Vector3 = p - center
		var pr: float = radial.length()
		if pr <= 1e-4:
			break
		var up_here: Vector3 = radial / pr
		var ground: float = _ground_radius(up_here) + cam_ground_margin
		if pr < ground:
			break   # 该点已在地形之内 → 相机停在上一个安全点(向角色收拢)
		safe = d
	return clampf(safe, cam_collision_min, desired)
