# gdlint: disable=variable-name, max-line-length
## 自包含球面行星角色控制器(挂在 robot_character.tscn 根节点)。
##
## 设计目标: 把预制体拖进场景放到星球附近即可行走, 不改动/不依赖 GpuPlanet、大气、LOD 等其余系统。
## 只**只读**地取星球的中心/半径/高度场(Terrain), 绝不写它们。
##
## 重力: 优先用 GravityFields 的 get_custom_gravity()(若角色进入了某个 GravityDetector 区域,
##   支持将来太阳系多天体/SOI 平滑切换); 否则回退到"指向最近 GpuPlanet 球心的径向重力"。
##
## 贴地: GPU 星球是纯视觉(无碰撞网格), 所以不走物理碰撞, 而是每帧用 Terrain.height_at(与着色器
##   位移逐位一致)程序化把角色夹到地表(radius + h*maxHeight)。move_and_slide 不调用(无地面碰撞体)。
##
## 相机: 内置重力对齐的第三人称相机(鼠标看向, 滚轮无), 独立于角色朝向。可用 use_own_camera 关掉。
##
## 非 @tool: 只在运行时工作(编辑器里不自动跑, 免得干扰编辑)。
extends GravityCharacter3D

# ---- 运动参数 ----
@export_group("Movement")
## 行走速度(单位/秒)。
@export var walk_speed: float = 8.0
## 奔跑速度(按住 Shift)。
@export var run_speed: float = 16.0
## 起跳初速度(沿"上"方向)。
@export var jump_speed: float = 12.0
## 无重力场时的回退重力强度(指向星球中心)。有 GravityDetector 时以场为准。
@export var gravity_strength: float = 20.0
## 水平加减速平滑(越大越跟手)。
@export var accel: float = 12.0
## 转向/立正平滑速度。
@export var align_speed: float = 12.0

@export_group("Grounding")
## 角色原点到脚底的距离(= 胶囊半高)。Model 也据此下移, 让脚踩在地面。
@export var foot_offset: float = 0.9
## 低于海平面时是否夹到海面(可在水面上行走)。关则会走到海床。
@export var stick_to_water: bool = true

@export_group("Planet")
## 可选: 显式指定 GpuPlanet。留空则自动查找(父级链 → 全场景)。
@export var planet_path: NodePath

@export_group("Camera")
## 外部相机(可选): 在**实例**上把场景里已有的 Camera3D 拖到这里。
## 留空 → 用预制体内置的 Camera3D 子节点(默认, 拖进去即用)。
@export var external_camera: Camera3D
## 是否由本控制器驱动相机(重力对齐第三人称跟随 + 鼠标看向)。
## 开(默认): 无论内置还是外部相机, 都由本控制器接管其位姿/朝向。
## 关: 只**读**相机朝向来决定移动方向, 相机位姿完全交给外部(它自己的脚本/rig)控制。
@export var control_camera: bool = true
@export var mouse_sensitivity: float = 0.003
@export var cam_distance: float = 8.0
@export var cam_height: float = 2.2
@export var cam_pitch_min_deg: float = -60.0
@export var cam_pitch_max_deg: float = 75.0

@export_group("Animation")
## 动画名(默认对应 Quaternius Animated Robot 的 clip 名)。
@export var anim_idle: String = "Robot_Idle"
@export var anim_walk: String = "Robot_Walking"
@export var anim_run: String = "Robot_Running"
@export var anim_jump: String = "Robot_Jump"
## 切换到跑步动画的速度阈值。
@export var run_anim_threshold: float = 10.0
## 美术朝向修正(度, 绕自身 Y)。Quaternius 机器人美术朝向为 +Z, 而 Godot 前方是 -Z, 故默认 180
## 让模型正面对准移动方向(否则会"倒着走 / 前后左右都反")。若换了朝 -Z 的模型就设 0。
@export var model_yaw_offset_deg: float = 180.0

# ---- 内部状态 ----
var _planet: GpuPlanet
var _center: Vector3 = Vector3.ZERO
var _radius: float = 100.0
var _max_height: float = 8.0
var _sea: float = 0.0
var _terrain: Terrain

var _model: Node3D
var _anim: AnimationPlayer
var _camera: Camera3D

var _up: Vector3 = Vector3.UP
var _v_up: float = 0.0            # 沿"上"的速度分量(重力/跳跃)
var _grounded: bool = false
var _cam_yaw: float = 0.0
var _cam_pitch: float = -0.2
var _cur_anim: String = ""
var _cam_active: bool = false     # 本控制器当前是否在驱动相机(由 set_camera_active 切换)


func _ready() -> void:
	_resolve_planet()
	_read_planet()
	# 找模型/动画/相机(路径无关, 靠名字/类型查找, 换预制体结构也不怕)。
	_model = get_node_or_null("Model")
	if _model == null:
		_model = _find_first_child_node3d_except_camera()
	_anim = find_child("AnimationPlayer", true, false) as AnimationPlayer
	# 相机解析: 外部指定优先, 否则用内置 Camera3D 子节点。
	_camera = external_camera
	if _camera == null:
		_camera = get_node_or_null("Camera3D") as Camera3D
		if _camera == null:
			_camera = find_child("Camera3D", true, false) as Camera3D
	# 应用美术朝向修正。
	if _model != null and absf(model_yaw_offset_deg) > 0.001:
		_model.rotation = Vector3(0.0, deg_to_rad(model_yaw_offset_deg), 0.0)
	_make_locomotion_loop()
	# 落到地面(初始摆放不必精确; 若被放在球心附近, 用北极兜底)。
	_snap_to_ground(true)
	# 初始相机激活: 用**内置**相机(未指定 external_camera)时自激活, 保证预制体单独拖进去也能玩;
	# 指定了外部相机时(场景管理)默认不激活, 交给场景的 CameraDirector 调 set_camera_active 接管。
	set_camera_active(control_camera and external_camera == null)


# ---- 星球解析(自动查找, 零耦合) ----
func _resolve_planet() -> void:
	if planet_path != NodePath():
		var n := get_node_or_null(planet_path)
		if n is GpuPlanet:
			_planet = n
			return
	# 父级链
	var p := get_parent()
	while p != null:
		if p is GpuPlanet:
			_planet = p
			return
		p = p.get_parent()
	# 全场景搜索(取第一个)
	_planet = _search_planet(get_tree().root)


func _search_planet(n: Node) -> GpuPlanet:
	if n is GpuPlanet:
		return n
	for c in n.get_children():
		var r := _search_planet(c)
		if r != null:
			return r
	return null


func _read_planet() -> void:
	if _planet == null:
		push_warning("[RobotCharacter] 未找到 GpuPlanet, 用默认 radius=100/maxHeight=8, 无地形起伏。")
		return
	_center = _planet.global_position
	var p: PlanetParams = _planet.params
	if p == null:
		push_warning("[RobotCharacter] GpuPlanet.params 为空, 用默认值。")
		return
	_radius = p.radius
	_max_height = p.maxHeight
	_sea = p.seaLevel
	_terrain = Terrain.from_params(p)


## 参数运行时改变后可调此刷新(可选)。
func refresh_planet() -> void:
	_read_planet()


func _find_first_child_node3d_except_camera() -> Node3D:
	for c in get_children():
		if c is Node3D and not (c is Camera3D) and not (c is CollisionShape3D):
			return c
	return null


func _make_locomotion_loop() -> void:
	if _anim == null:
		return
	for n in [anim_idle, anim_walk, anim_run]:
		if _anim.has_animation(n):
			var a := _anim.get_animation(n)
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR


# ---- 地表半径(与 GPU 着色器位移逐位一致) ----
func _ground_radius(dir: Vector3) -> float:
	if _terrain == null:
		return _radius
	var h := _terrain.height_at(dir.x, dir.y, dir.z)
	if stick_to_water:
		h = maxf(h, _sea)
	return _radius + h * _max_height


func _current_up() -> Vector3:
	var g := _gravity_vector()
	if g.length() > 0.0001:
		return (-g).normalized()
	var radial := global_position - _center
	if radial.length() > 0.0001:
		return radial.normalized()
	return Vector3.UP


func _gravity_vector() -> Vector3:
	# GravityFields 场(若进入了 detector 区域)
	var g := get_custom_gravity()
	if g.length() > 0.0001:
		return g
	# 回退: 指向星球中心的径向重力
	var to_center := _center - global_position
	if to_center.length() > 0.0001:
		return to_center.normalized() * gravity_strength
	return Vector3.DOWN * gravity_strength


func _physics_process(delta: float) -> void:
	_up = _current_up()

	# --- 水平朝向参考 ---
	var fwd_t: Vector3
	if _cam_active:
		fwd_t = _camera_horizontal_dir()                                # 我们驱动的相机: 用内部 yaw
	elif _camera != null:
		fwd_t = _project_on_tangent(-_camera.global_transform.basis.z)  # 外部/轨道相机: 读它的实际朝向
	else:
		fwd_t = _project_on_tangent(-global_transform.basis.z)          # 无相机: 用当前朝向
	var right_t := fwd_t.cross(_up).normalized()

	# --- 输入 → 期望水平速度 ---
	var iy := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var ix := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var wish := (right_t * ix + fwd_t * iy)
	var moving := wish.length() > 0.05
	if moving:
		wish = wish.normalized()
	var sprinting := Input.is_physical_key_pressed(KEY_SHIFT)
	var target_speed := (run_speed if sprinting else walk_speed) if moving else 0.0
	var target_v := wish * target_speed

	# 当前水平速度(去掉沿 up 的分量)
	var v_tan := velocity - _up * velocity.dot(_up)
	v_tan = v_tan.lerp(target_v, clampf(accel * delta, 0.0, 1.0))

	# --- 重力 / 跳跃(沿 up 的分量) ---
	var g_mag := _gravity_vector().length()
	_v_up -= g_mag * delta
	if _grounded and Input.is_action_just_pressed("jump"):
		_v_up = jump_speed
		_grounded = false

	velocity = v_tan + _up * _v_up

	# --- 位移(手动积分; 无地面碰撞体所以不用 move_and_slide) ---
	global_position += velocity * delta

	# --- 程序化贴地 ---
	_snap_to_ground(false)

	# --- 立正 + 面向移动方向 ---
	_orient(delta, v_tan)

	# --- 动画 ---
	_update_animation(v_tan.length())


func _snap_to_ground(initial: bool) -> void:
	var radial := global_position - _center
	var dist := radial.length()
	var dir: Vector3
	if dist < 0.001:
		dir = Vector3.UP   # 被放在球心 → 用北极兜底
	else:
		dir = radial / dist
	var target_r := _ground_radius(dir) + foot_offset
	if initial:
		global_position = _center + dir * target_r
		_v_up = 0.0
		_grounded = true
		return
	if dist <= target_r:
		# 穿地 → 夹回地表, 停下落速度
		global_position = _center + dir * target_r
		if _v_up < 0.0:
			_v_up = 0.0
		_grounded = true
	else:
		# 离地一点点也算站着(容差), 否则动画会抖
		_grounded = (dist - target_r) <= 0.05


func _project_on_tangent(v: Vector3) -> Vector3:
	var t := v - _up * v.dot(_up)
	if t.length() < 0.0001:
		return -global_transform.basis.z
	return t.normalized()


func _orient(delta: float, v_tan: Vector3) -> void:
	var face: Vector3
	if v_tan.length() > 0.3:
		face = v_tan.normalized()
	else:
		face = _project_on_tangent(-global_transform.basis.z)
	# 目标 basis: -Z 指向 face, Y = up
	var target := Basis.looking_at(face, _up)
	var q_cur := global_transform.basis.get_rotation_quaternion()
	var q_tgt := target.get_rotation_quaternion()
	var q := q_cur.slerp(q_tgt, clampf(align_speed * delta, 0.0, 1.0))
	var t := global_transform
	t.basis = Basis(q)
	global_transform = t


# ---- 动画状态机 ----
func _update_animation(speed: float) -> void:
	if _anim == null:
		return
	var want: String
	if not _grounded:
		want = anim_jump
	elif speed > run_anim_threshold:
		want = anim_run
	elif speed > 0.5:
		want = anim_walk
	else:
		want = anim_idle
	if want == _cur_anim:
		return
	if not _anim.has_animation(want):
		return
	_anim.play(want, 0.15)
	_cur_anim = want


## 由外部(如 CameraDirector)调用, 接管/交还本控制器对相机的驱动。
## active=true : 脱离父变换 + 设为当前相机 + 捕获鼠标 + 每帧第三人称跟随驱动。
## active=false: 停止驱动、不再碰鼠标(相机位姿交给外部, 如轨道相机)。
## 注: control_camera=false(外部完全自驱)时本方法不接管相机, 仅保证不干扰。
func set_camera_active(active: bool) -> void:
	_cam_active = active and control_camera and _camera != null
	if not _cam_active:
		return
	_camera.top_level = true
	_camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_camera_active() -> bool:
	return _cam_active


# ---- 内置第三人称相机(重力对齐, 独立朝向) ----
func _camera_horizontal_dir() -> Vector3:
	# 以世界参考在切平面上取一个稳定的"前"方向, 再按 _cam_yaw 绕 up 旋转。
	var ref := Vector3.FORWARD
	if absf(ref.dot(_up)) > 0.99:
		ref = Vector3.RIGHT
	var base_fwd := (ref - _up * ref.dot(_up)).normalized()
	return (Quaternion(_up, _cam_yaw) * base_fwd).normalized()


func _process(delta: float) -> void:
	# 只有本控制器处于激活(驱动相机)状态时才摆放相机; 否则相机交给外部(轨道相机/CameraDirector)。
	if not _cam_active:
		return
	var up := _current_up()
	var dir := _camera_horizontal_dir()
	var right := dir.cross(up).normalized()
	# 俯仰
	var look := (Quaternion(right, _cam_pitch) * dir).normalized()
	var head := global_position + up * cam_height
	var cam_pos := head - look * cam_distance
	_camera.global_position = _camera.global_position.lerp(cam_pos, clampf(12.0 * delta, 0.0, 1.0))
	_camera.look_at(head, up)


func _unhandled_input(event: InputEvent) -> void:
	# 只有激活(驱动相机)时才处理鼠标看向; 否则鼠标交给外部(轨道相机/CameraDirector)。
	if not _cam_active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_cam_yaw -= event.relative.x * mouse_sensitivity
		_cam_pitch = clampf(_cam_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(cam_pitch_min_deg), deg_to_rad(cam_pitch_max_deg))
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		# Esc 释放/捕获鼠标, 方便调试
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)
