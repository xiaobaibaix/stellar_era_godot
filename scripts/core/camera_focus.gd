# gdlint: disable=variable-name, max-line-length
## 相机焦点切换: PLANET(围绕行星) ⇄ PLAYER(围绕角色)。
## - M 键: 在两种焦点之间平滑切换(Transform3D.interpolate_with + ease-in-out, ~1s)。
## - 切换期间冻结输入(避免 yaw/pitch/distance 跟鼠标飘, 与插值叠加产生抖动);
##   切换结束从最终 Transform 反推 yaw/pitch/distance, 避免回弹到旧轨道参数。
## - PLAYER 焦点下, 相机离行星中心 > 大气壳(=radius×atmoScale) × auto_switch_ratio → 自动切回 PLANET
##   (相当于"用户在角色视角把相机拉很远"的自然手势 → 弹回全球视角)。
## - 两种焦点都给完整轨道控制(左键拖旋转, 滚轮缩放); PLAYER 焦点走自己的轨道, 不依赖 player.camera_slot
##   (player.gd 的 slot 仍由 main.gd 的 reparent 模式用, 这条路径不冲突)。
class_name CameraFocus
extends Camera3D

enum Focus { PLANET, PLAYER }

@export var planet_path: NodePath
@export var player_path: NodePath
@export var focus: Focus = Focus.PLANET

@export_group("Orbit")
@export var yaw: float = 0.78
@export var pitch: float = 0.55
@export var distance: float = 800.0
@export_range(0.0, 1.0) var damp: float = 0.2
@export var rotate_speed: float = 0.005
@export var zoom_factor: float = 0.1
@export var min_distance: float = 5.0
@export var max_distance: float = 5000.0
@export var invert_y: bool = true

@export_group("Planet focus")
## PLANET 焦点下最小距离 = 行星半径 × 此倍率(避免相机钻进大气壳/地表)。
@export var planet_min_distance_ratio: float = 1.3

@export_group("Player focus")
## 切到 PLAYER 焦点时, 若当前 distance > planet.radius × player_reset_ratio(刚从全球过来),
## 重置为 player_default_distance; 否则保留当前 distance(已在角色附近)。
@export var player_reset_ratio: float = 1.5
## 切到 PLAYER 焦点的默认轨道距离(第三人称)。
@export var player_default_distance: float = 12.0
## 第三人称俯仰角(弧度, 相对玩家径向 up; 正=相机抬高俯视)。
@export var player_default_pitch: float = 0.35

@export_group("Transition")
@export var transition_duration: float = 1.0
## PLAYER 焦点下, 相机到行星中心 > 大气壳半径 × 此倍率 → 自动切回 PLANET。
@export var auto_switch_ratio: float = 1.5

@export_group("Window")
## _ready 时把窗口拉回普通窗口模式(覆盖 project.godot 的全局 mode=3 全屏)。
## test_planet 调试用: 不全屏; 其他场景用本脚本时可在 Inspector 关掉。
@export var force_windowed: bool = true

var _target_yaw: float
var _target_pitch: float
var _target_distance: float

var _planet: Planet
var _player: Player

var _transitioning: bool = false
var _transition_t: float = 0.0
var _from_xform: Transform3D
var _pending_focus: int = -1


func _ready() -> void:
	if force_windowed:
		# project.godot 全局 mode=3(全屏); test_planet 调试要普通窗口, 这里覆盖。
		# 用 DisplayServer(主窗口 API) 比 Window.mode setter 更稳(macOS 全屏 Space 切换有边角 case)。
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# 用 is 检查避免路径错/类型不匹配时把整个 _ready 废掉(get_node_or_null 返回错类型 → 运行时错 → 后续代码不跑)。
	if planet_path != NodePath():
		var pn: Node = get_node_or_null(planet_path)
		if pn is Planet:
			_planet = pn
	if player_path != NodePath():
		var pl: Node = get_node_or_null(player_path)
		if pl is Player:
			_player = pl
	# 用初始 transform 反推 yaw/pitch/distance(对齐 OrbitCamera 思路): 否则脚本默认 distance(800)
	# 在某些 radius 下会让相机落在星球内, 每次运行都得手动拉出来。
	var fp := _focus_point(focus)
	var rel := global_position - fp
	var d := rel.length()
	if d > 1e-3:
		distance = d
		pitch = asin(clampf(rel.y / d, -1.0, 1.0))
		yaw = atan2(rel.x, rel.z)
	_target_yaw = yaw
	_target_pitch = pitch
	_target_distance = distance
	# far 必须覆盖最远缩放距离 + 行星尺寸, 否则球比 far 远会被裁 / LOD 视锥剔除把整球剔掉。
	near = 0.5
	far = max_distance * 4.0
	current = true


func _unhandled_input(event: InputEvent) -> void:
	# 切换期间冻结轨道输入(否则 yaw/pitch/distance 会继续被鼠标/滚轮推着走, 与插值叠加产生抖动)。
	if _transitioning:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		toggle_focus()
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_target_yaw -= event.relative.x * rotate_speed
		var sgn := -1.0 if invert_y else 1.0
		_target_pitch -= event.relative.y * rotate_speed * sgn
		_target_pitch = clampf(_target_pitch, -1.55, 1.55)
	elif event is InputEventMouseButton and event.is_pressed():
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_target_distance *= (1.0 - zoom_factor)
			MOUSE_BUTTON_WHEEL_DOWN:
				_target_distance *= (1.0 + zoom_factor)
		_target_distance = clampf(_target_distance, _effective_min_distance(), max_distance)


func _process(delta: float) -> void:
	if _transitioning:
		_transition_t = minf(_transition_t + delta / transition_duration, 1.0)
		var eased := _ease_in_out(_transition_t)
		# 终点每帧采样(PLAYER 焦点下角色在走, 终点要跟着移动), 否则过渡结束瞬间会" snap "到正确位置。
		var end_xform := _desired_end_xform(_pending_focus)
		# 球面插值位置(不直线插值): 从 (730,0,0) 直线到 (0,331,11), t≈0.7 时到行星半径之内(318 < 326)
		# → 相机裁进地形里, 看起来"卡住没动"。改成绕行星外缘的大圆弧: 减中心 → 方向 slerp + 半径 lerp → 加回中心。
		var center: Vector3 = _planet.global_position if (_planet != null and is_instance_valid(_planet)) else Vector3.ZERO
		var start_rel: Vector3 = _from_xform.origin - center
		var end_rel: Vector3 = end_xform.origin - center
		var start_len: float = start_rel.length()
		var end_len: float = end_rel.length()
		var cam_pos: Vector3
		if start_len > 1e-3 and end_len > 1e-3:
			var start_dir: Vector3 = start_rel / start_len
			var end_dir: Vector3 = end_rel / end_len
			# 方向走单位球大圆 + 半径线性插值: 任一时刻相机到中心的距离 = lerpf(start_len, end_len, eased),
			# 必落在 [min, max] 端点之间; 两端点都在行星外 → 整段路径都在行星外, 不会裁进地表。
			var mid_dir: Vector3 = start_dir.slerp(end_dir, eased)
			var mid_len: float = lerpf(start_len, end_len, eased)
			cam_pos = center + mid_dir * mid_len
		else:
			cam_pos = _from_xform.origin.lerp(end_xform.origin, eased)
		var look_target: Vector3 = _focus_point(_pending_focus)
		# 平滑 blend up: PLANET→PLAYER 时从世界 UP 渐变到角色径向 up, 避免过渡结束瞬间 roll snap。
		var end_up: Vector3 = Vector3.UP
		if _pending_focus == Focus.PLAYER and _player != null and is_instance_valid(_player):
			end_up = _player.global_transform.basis.y
		var blend_up: Vector3 = Vector3.UP.slerp(end_up, eased).normalized()
		var x: Transform3D = Transform3D()
		x.origin = cam_pos
		x = x.looking_at(look_target, blend_up)
		global_transform = x
		if _transition_t >= 1.0:
			focus = _pending_focus
			_transitioning = false
			_pending_focus = -1
			# 过渡结束, 从最终 Transform 反推 yaw/pitch/distance, 否则下一帧的轨道计算会用旧值 → 角度/距离对不上新焦点。
			_recapture_orbit_state()
	else:
		yaw = lerp(yaw, _target_yaw, damp)
		pitch = lerp(pitch, _target_pitch, damp)
		distance = lerp(distance, _target_distance, damp)
		global_transform = _compute_orbit_xform(focus)
		# PLAYER 焦点下, 用户把相机拉出大气壳很远 → 自动切回 PLANET(等价于"用户想看全球")。
		if focus == Focus.PLAYER and _planet != null and is_instance_valid(_planet):
			var cam_d := global_position.distance_to(_planet.global_position)
			var atmo_shell := _planet.params.radius * _planet.params.atmoScale
			if cam_d > atmo_shell * auto_switch_ratio:
				_start_transition(Focus.PLANET)


func _focus_point(f: int) -> Vector3:
	match f:
		Focus.PLANET:
			return _planet.global_position if (_planet != null and is_instance_valid(_planet)) else Vector3.ZERO
		Focus.PLAYER:
			return _player.global_position if (_player != null and is_instance_valid(_player)) else Vector3.ZERO
	return Vector3.ZERO


func _effective_min_distance() -> float:
	# PLANET 焦点要避免相机钻进大气壳; PLAYER 焦点用通用 min_distance(角色附近, 不需要大气约束)。
	if focus == Focus.PLANET and _planet != null and is_instance_valid(_planet):
		return _planet.params.radius * planet_min_distance_ratio
	return min_distance


# 当前(已 damped) yaw/pitch/distance → 轨道变换。每帧用, 跟随用户输入平滑变化。
func _compute_orbit_xform(f: int) -> Transform3D:
	var fp := _focus_point(f)
	var x := Transform3D()
	if f == Focus.PLAYER and _player != null and is_instance_valid(_player):
		# PLAYER 焦点用角色基做参考系: yaw 绕径向 up(basis.y)转, pitch 沿径向抬升, 屏幕上方向 = 径向外。
		# 用世界 UP 会让角色走到星球侧面时相机 roll 90°(世界 Y 此时是切向, 不是径向) → 看起来严重倾斜。
		var pb := _player.global_transform.basis
		var up: Vector3 = pb.y            # 径向外
		var back: Vector3 = pb.z          # 角色后方(_align_basis: basis.z = -fwd)
		var cp := cos(pitch)
		# 在角色切平面里: 从"后方"绕 up 转 yaw → 切向位置; 沿 up 抬 sin(pitch) → 第三人称俯仰。
		var tangent: Vector3 = back.rotated(up, yaw)
		var offset: Vector3 = tangent * (cp * distance) + up * (sin(pitch) * distance)
		x.origin = fp + offset
		x = x.looking_at(fp, up)
	else:
		# PLANET 焦点: 球面对称, 用世界轴没问题。
		var cp := cos(pitch)
		var offset := Vector3(cp * sin(yaw) * distance, sin(pitch) * distance, cp * cos(yaw) * distance)
		x.origin = fp + offset
		x = x.looking_at(fp, Vector3.UP)
	return x


# 过渡终点变换(每帧采样, 实时跟随焦点位置/朝向)。
# PLANET: 沿"当前相机→焦点"方向拉到 planet_min_distance_ratio × R × 1.5 之外(略余量避免太贴大气壳)。
# PLAYER: 摆在角色"后方 + 略上"(第三人称), 距离用 player_default_distance(若当前 distance 太大)或保持当前。
func _desired_end_xform(f: int) -> Transform3D:
	var fp := _focus_point(f)
	var x := Transform3D()
	match f:
		Focus.PLANET:
			var target_d: float = (_planet.params.radius * planet_min_distance_ratio * 1.5) if (_planet != null and is_instance_valid(_planet)) else distance
			var dir: Vector3 = global_position - fp
			if dir.length() < 1e-3:
				dir = Vector3.FORWARD
			dir = dir.normalized()
			x.origin = fp + dir * target_d
			x = x.looking_at(fp, Vector3.UP)
		Focus.PLAYER:
			# 角色朝向: player.gd 的 _align_basis 把 basis.z 设为 -forward, 所以"角色后方" = +basis.z 方向。
			# 径向 up = basis.y(指向行星外)。
			var want_d: float = distance
			if _planet != null and is_instance_valid(_planet) and distance > _planet.params.radius * player_reset_ratio:
				want_d = player_default_distance
			if _player != null and is_instance_valid(_player):
				var pb := _player.global_transform.basis
				var back := pb.z
				var up := pb.y
				# 后方 want_d × cos(pitch) + 径向 up want_d × sin(pitch) = 第三人称俯视
				var off := back * (want_d * cos(player_default_pitch)) + up * (want_d * sin(player_default_pitch))
				x.origin = fp + off
				x = x.looking_at(fp, up)
			else:
				x.origin = fp + Vector3.BACK * want_d
				x = x.looking_at(fp, Vector3.UP)
	return x


# 过渡结束: 用最终 transform(对当前 focus 的焦点)反推 yaw/pitch/distance, 让随后的轨道控制能从过渡终点继续。
func _recapture_orbit_state() -> void:
	var fp := _focus_point(focus)
	var rel := global_position - fp
	var d := rel.length()
	if d < 1e-3:
		return
	_target_distance = clampf(d, _effective_min_distance(), max_distance)
	if focus == Focus.PLAYER and _player != null and is_instance_valid(_player):
		# PLAYER 焦点: 把世界 rel 表达到角色本地系(正交基 → inverse = transpose), 再按 _compute_orbit_xform
		# 的约定(back=+Z, up=+Y, yaw 绕 +Y 右手)反算 yaw/pitch; 否则过渡终点与下一帧轨道算的会对不上。
		var pb := _player.global_transform.basis
		var local_rel: Vector3 = pb.inverse() * rel
		_target_pitch = asin(clampf(local_rel.y / d, -1.0, 1.0))
		_target_yaw = atan2(local_rel.x, local_rel.z)
	else:
		_target_pitch = asin(clampf(rel.y / d, -1.0, 1.0))
		_target_yaw = atan2(rel.x, rel.z)
	distance = _target_distance
	pitch = _target_pitch
	yaw = _target_yaw


func toggle_focus() -> void:
	_start_transition(Focus.PLANET if focus == Focus.PLAYER else Focus.PLAYER)


func _start_transition(new_focus: int) -> void:
	if _transitioning or new_focus == focus:
		return
	_transitioning = true
	_transition_t = 0.0
	_from_xform = global_transform
	_pending_focus = new_focus


func _ease_in_out(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)
