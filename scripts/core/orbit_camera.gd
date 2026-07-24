## 简易轨道相机(对应 web 版 three.js OrbitControls)。
## 左键拖动旋转 / 滚轮缩放。Phase 3 会再加 PlanetWalker 第三人称相机与之并存。
## 不带 @tool: 编辑器里相机由用户手动控制(拖节点/编辑器视口), 不被本脚本的轨道定位覆盖;
## Planet 的 LOD 直接读相机节点位置, 无需本脚本在编辑器执行。
class_name OrbitCamera
extends Camera3D

var target: Vector3 = Vector3.ZERO
var yaw: float = 0.78
var pitch: float = 0.55
var distance: float = 800.0
var min_distance: float = 1.0
var max_distance: float = 50000.0
var rotate_speed: float = 0.005
var zoom_factor: float = 0.1
var invert_y: bool = true
var smooth: bool = true  # 阻尼跟随

var _cur_yaw: float = 0.78
var _cur_pitch: float = 0.55
var _cur_dist: float = 320.0


func _ready() -> void:
	# 用编辑器里摆好的相机位置反推 distance/yaw/pitch, 让运行起点 = 编辑器位置。
	# 否则脚本默认 distance(800) < 行星半径(1000), 相机会落在星球内部, 每次运行都得手动拉出来。
	# 仅当相机被实际摆放(离 target 较远)才覆盖; 用 .new() 建在原点的实例保持默认行为。
	var origin := global_position
	if origin.distance_squared_to(target) > 1.0:
		var rel := origin - target
		distance = rel.length()
		pitch = asin(clampf(rel.y / distance, -1.0, 1.0))
		yaw = atan2(rel.x, rel.z)
	_cur_yaw = yaw
	_cur_pitch = pitch
	_cur_dist = distance
	# far 必须覆盖最远缩放距离 + 行星尺寸。far 通过两条路径影响球:
	# (a) 运行时本相机是渲染相机, 球比 far 远就直接被裁;
	# (b) Planet 的 LOD 用 get_frustum()(含 far 平面)做视锥剔除, far 太小 → 视锥截短 → 整球被判视锥外被剔除。
	near = 0.5
	far = max_distance * 4.0


func set_orbit(p_target: Vector3, p_dist: float) -> void:
	target = p_target
	distance = p_dist
	_cur_dist = p_dist


## 当前 yaw/pitch/distance 对应的相机世界位姿(供模式切换过渡的目标位姿; 不改动自身)。
## 与 _process 的构造一致(组合旋转), 保证过渡结束交接给本相机时不跳。
func get_desired_transform() -> Transform3D:
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.UP, yaw)
	b = b.rotated(b.x, -pitch)
	return Transform3D(b, target + b.z * distance)


## 把平滑中间量(_cur_*)对齐到目标值。过渡结束把驱动交回本相机前调, 避免接管后再 lerp 造成跳变。
func snap_to_target() -> void:
	_cur_yaw = yaw
	_cur_pitch = pitch
	_cur_dist = distance


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		yaw -= event.relative.x * rotate_speed
		var sgn := -1.0 if invert_y else 1.0
		pitch -= event.relative.y * rotate_speed * sgn
		# 现在朝向靠组合旋转(不再 look_at UP), 极点不再退化, 可放宽到接近 ±90°(正俯视/仰视)。
		pitch = clamp(pitch, -1.5707, 1.5707)
	elif event is InputEventMouseButton and event.is_pressed():
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance *= (1.0 - zoom_factor)
			MOUSE_BUTTON_WHEEL_DOWN:
				distance *= (1.0 + zoom_factor)
		distance = clamp(distance, min_distance, max_distance)


func _process(_delta: float) -> void:
	if smooth:
		_cur_yaw = lerp(_cur_yaw, yaw, 0.2)
		_cur_pitch = lerp(_cur_pitch, pitch, 0.2)
		_cur_dist = lerp(_cur_dist, distance, 0.2)
	else:
		_cur_yaw = yaw
		_cur_pitch = pitch
		_cur_dist = distance
	# 用 yaw/pitch 直接【组合旋转】构造相机朝向(绕世界 Y 转 yaw, 再绕本地 X 转 pitch), 取代
	# look_at(target, UP)。look_at 在视线接近世界 UP(俯视/仰视到极点)时会退化 → 相机翻滚/抖动
	# ("极点问题"); 组合旋转在任意俯仰角都良定义, 且 right 轴恒水平(地平线不歪), 彻底消除极点问题。
	# 数学上 b.z 与旧 offset 方向逐位相同 → 相机位置不变, 只是朝向在极点处稳定。
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.UP, _cur_yaw)
	b = b.rotated(b.x, -_cur_pitch)
	global_transform = Transform3D(b, target + b.z * _cur_dist)
