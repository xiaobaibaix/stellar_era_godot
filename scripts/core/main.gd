# gdlint: disable=variable-name, max-line-length
## 主场景控制:
## - CheckButton「跟随角色」: 轨道相机 ⇄ 跟随角色相机(仅运行时)。
## - LOD 调试球显隐: 编辑器 Inspector 的 show_balls / 运行时 CheckButton「显示ball」/ F2,
##   三者共用 show_balls 状态(@tool 让 setter 在编辑器也生效)。
## @tool: 调试球在编辑器 3D 视口也能渲染并跟随; 玩家/相机切换逻辑用 is_editor_hint 挡住, 只在运行时跑。
@tool
extends Node

@export var camera: Camera3D
@export var player: Player
@export var toggle: CheckButton
@export var wire_toggle: CheckButton       # 显示线框(纯透视 wireframe)开关
@export var ball_toggle: CheckButton       # 显示 LOD 调试球开关
@export var display_ball: MeshInstance3D   # 显示环(内)调试球(轨道/编辑器用, 跟随相机)
@export var preload_ball: MeshInstance3D   # 预取环(外)调试球(轨道/编辑器用, 跟随相机)
@export var player_display_ball: MeshInstance3D   # 跟随角色模式: 显示环球(跟随角色)
@export var player_preload_ball: MeshInstance3D   # 跟随角色模式: 预取环球(跟随角色)
@export var planet: Planet                 # 用来按真实 LOD 阈值缩放调试球(读 params + target_level_at)
@export var fps_label: Label                # 右上角 FPS 显示(运行时每 0.25s 刷新)

## 显示 LOD 调试球。编辑器 Inspector 勾选 或 运行时 F2/「显示ball」; setter 统一改可见性。
@export var show_balls: bool = false:
	set(v):
		show_balls = v   # 可见性由 _process 按当前模式(相机球/角色球)统一应用

var _orbit_parent: Node
var _orbit_transform: Transform3D
var _in_player_mode: bool = false
var _wireframe: bool = false
var _fps_acc: float = 0.0   # FPS 文本刷新累加器


func _ready() -> void:
	# 调试球材质(相机球 + 角色球各一对, 同样的绿/橙配色)
	_setup_ball(display_ball, Color(0.20, 1.00, 0.35, 0.15))   # 显示环: 绿
	_setup_ball(preload_ball, Color(1.00, 0.60, 0.15, 0.10))   # 预取环: 橙
	_setup_ball(player_display_ball, Color(0.20, 1.00, 0.35, 0.15))
	_setup_ball(player_preload_ball, Color(1.00, 0.60, 0.15, 0.10))
	if Engine.is_editor_hint():
		return   # 编辑器: 只做调试球可视化, 不跑玩家/相机切换
	# ---- 以下仅运行时 ----
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
	if ball_toggle != null:
		ball_toggle.toggled.connect(_on_ball_toggled)
		ball_toggle.focus_mode = Control.FOCUS_NONE


func _setup_ball(b: MeshInstance3D, c: Color) -> void:
	if b == null:
		return
	b.material_override = _mk_ball_mat(c)


func _process(delta: float) -> void:
	_update_fps(delta)
	# 当前模式用哪对球: 跟随角色模式用 player 球(跟随角色), 否则用 Camera 球(跟随相机)
	var use_player := _in_player_mode
	var ad: MeshInstance3D = player_display_ball if use_player else display_ball
	var ap: MeshInstance3D = player_preload_ball if use_player else preload_ball
	var id_: MeshInstance3D = display_ball if use_player else player_display_ball
	var ip: MeshInstance3D = preload_ball if use_player else player_preload_ball
	# 非当前模式的球始终隐藏
	if id_ != null:
		id_.visible = false
	if ip != null:
		ip.visible = false
	if not show_balls:
		if ad != null:
			ad.visible = false
		if ap != null:
			ap.visible = false
		return
	# LOD 聚焦点: 有 lod_target(角色)用之, 否则用相机; 编辑器用编辑器视口相机
	var cam: Camera3D = camera
	if Engine.is_editor_hint():
		var vp := get_viewport()
		cam = vp.get_camera_3d() if vp != null else null
	var focus: Node3D = cam
	# @tool 下 planet.gd 偶处"重编译/解析失败"瞬态(脚本缓存未刷新), 节点退化为 Node3D,
	# 直接读 lod_target 会每帧刷 "property not found"。用 get() 容错: 取不到就回退相机, 不刷屏。
	# planet.gd 正常时 get("lod_target") 返回真实聚焦目标(角色)。
	if planet != null:
		var lt = planet.get("lod_target")
		if lt is Node3D:
			focus = lt
	if focus == null:
		return
	var fp: Vector3 = focus.global_position
	if ad != null:
		ad.global_position = fp
		ad.visible = true
	if ap != null:
		ap.global_position = fp
		ap.visible = true
	# 球径缩放到真实 LOD 阈值(跟 splitFactor/prefetchFactor/当前层级 联动)
	_size_balls_to_lod(fp, delta, ad, ap)


func _update_fps(delta: float) -> void:
	if fps_label == null:
		return
	_fps_acc += delta
	if _fps_acc >= 0.25:
		_fps_acc = 0.0
		var line := "FPS:%d" % Engine.get_frames_per_second()
		if planet != null:
			# 用 get() 容错: planet.gd 偶处 @tool 重编译瞬态, 直接读 stats 会刷错。
			var st = planet.get("stats")
			if st is Dictionary:
				var tri_k := float(st.get("triangles", 0)) * 0.001
				line += "  patch:%d  tri:%.1fk  job:%d" % [st.get("patches", 0), tri_k, st.get("inflight", 0)]
		fps_label.text = line


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	# ESC 退回轨道相机
	if _in_player_mode and event.is_action_pressed("ui_cancel"):
		if toggle != null:
			toggle.set_pressed_no_signal(false)
		_enter_orbit()
		return
	# F1 纯透视线框(仅边、前后都可见); F2 LOD 调试球 —— 均与对应 CheckButton 同步
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				_wireframe = not _wireframe
				if planet != null:
					planet.set_wireframe(_wireframe)
				if wire_toggle != null:
					wire_toggle.set_pressed_no_signal(_wireframe)
			KEY_F2:
				show_balls = not show_balls
				if ball_toggle != null:
					ball_toggle.set_pressed_no_signal(show_balls)


# 调试球材质: 半透明 + 无光照 + 双面 + 免深度测试 → 相机在球心也能看清两个同心球壳
func _mk_ball_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	return m


# 把调试球半径缩放到真实 LOD 阈值: 取相机正下方方向的细分层级, 算该层 patch 的
# show 半径(edge_len × splitFactor)与 prefetch 半径(× prefetchFactor), 据此缩放两球。
func _size_balls_to_lod(cp: Vector3, delta: float, disp: MeshInstance3D, pre: MeshInstance3D) -> void:
	if planet == null or planet.roots.is_empty():
		return
	var center: Vector3 = planet.global_position
	var dir: Vector3 = cp - center
	if dir.length_squared() < 1e-6:
		return
	var lvl: int = planet.target_level_at(dir.normalized())
	var root_edge: float = planet.roots[0].edge_len
	var edge: float = root_edge / float(1 << lvl)
	var pp: PlanetParams = planet.params
	var show_r: float = edge * pp.splitFactor
	var prefetch_r: float = show_r * pp.prefetchFactor
	_scale_ball(disp, show_r, delta)
	_scale_ball(pre, prefetch_r, delta)


# 把球的"世界半径"平滑缩放到 world_r: 每帧向目标 lerp(时间常数 ~80ms),
# 消除跨 LOD 层级边界时球径的跳变, 并抑制边界处层级抖动造成的闪烁。
func _scale_ball(b: MeshInstance3D, world_r: float, delta: float) -> void:
	if b == null or b.mesh == null:
		return
	var sm := b.mesh as SphereMesh
	if sm == null or sm.radius < 1e-6:
		return
	var target := Vector3.ONE * (world_r / sm.radius)
	var w: float = clampf(delta * 12.0, 0.0, 1.0)
	b.scale = b.scale.lerp(target, w)


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


# 「显示Ball」: 走 show_balls setter(与 Inspector/F2 同一状态)
func _on_ball_toggled(on: bool) -> void:
	show_balls = on


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
