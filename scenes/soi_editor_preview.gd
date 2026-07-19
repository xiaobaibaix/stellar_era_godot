@tool
class_name SOIEditorPreview
extends MeshInstance3D
## 编辑器内 SOI 等势面 + 轨道预览: 挂在 celestial_system.tscn 的 SOI 节点上(仅借宿, 自身 mesh 不动)。
## 实际渲染到 owner=null 临时子节点(挂在本系统下) → 不进场景存盘、不污染 git diff。
##
## SOI: 多体引力 η=1 等势面(复刻 _make_potential_surface_mesh/_soi_radius_on_ray)。
##   无 is_dominant 子节点时 → 取质量最大的 Celestial 当 dominant(用户: "月球也要画, 就算没有也要画")。
##   顶层(parent 非 CelestialSystem) / 无外部摄动源 → 不画(无穷大, 同运行时 _build_soi_visuals_all 守卫)。
## Orbit: 绕 dominant 的初始圆轨道。运行时无速度数据 → 用 add_orbiting 的圆速度(v=√(G·M_dom/dist),
##   moon 倾角 0.25)从场景树位置复刻, 画整圆(= 运行时 osculating 椭圆的初始态)。
##   每个 member/child_system 绕本系统 dominant 各一个圆。月球轨迹 = PlanetSystem1 下 MoonSystem(sub)绕 Planet 的圆。
##
## 运行时由 celestial_system.gd 接管; is_editor_hint() 守卫, 运行时 _process 直接 return + 清预览。
## celestial_system.gd 非 @tool → 其实例是 placeholder, 方法调用失败 → SOI 数学须本地复制(bare G→传参 sys.G)。

const _PREVIEW_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;
uniform vec4 line_color;
void fragment() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	vec3 radial = normalize(VERTEX - center);
	if (dot(radial, normalize(-VERTEX)) < 0.0) discard;
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a;
}
"""

const _ORBIT_SEG: int = 64

var _last_sig: String = ""
var _soi_preview: MeshInstance3D = null
var _orbit_preview: MeshInstance3D = null


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		# 运行时: 清掉可能残留的预览子节点(理论不会被存盘加载, 双保险), 交给 celestial_system.gd。
		_clear_previews()
		return
	var sys: CelestialSystem = get_parent() as CelestialSystem
	if sys == null:
		return
	# 自动归属: 仅顶层系统每帧跑(避免每个系统实例重复判定)。选中并正在交互的非dominant天体
	# 按 SOI η=1 等势面实时 reparent, 保持世界位(视觉无跳变), owner 不变(存盘到 main.tscn 新路径)。
	if not (sys.get_parent() is CelestialSystem):
		_try_auto_reparent(sys)
	var parent_is_cs: bool = sys.get_parent() is CelestialSystem
	var dom: Celestial = _dominant_of(sys)
	var sources: Array[Celestial] = []
	if parent_is_cs:
		_collect_perturbers_edit(sys, sources)
	# 位置/质量/G 未变则跳过重建(编辑器空闲时近乎零开销)。
	var sig := _signature(sys, dom, sources)
	if sig == _last_sig:
		return
	_last_sig = sig

	# --- SOI: 仅非顶层 + 有 dominant + 有外部摄动源 才画 ---
	if parent_is_cs and dom != null and not sources.is_empty():
		_sync_world(dom)
		for s in sources:
			_sync_world(s)
		var pv: MeshInstance3D = _ensure_soi(sys)
		var so: Vector3 = sys.global_position
		pv.mesh = _make_potential_surface_mesh(dom, sources, so.x, so.y, so.z, 24, 12, 0.0, sys.G)
	else:
		_clear_soi()

	# --- Orbit: 有 dominant + 有绕轨天体 才画(顶层恒星系的行星轨道也画) ---
	if dom != null:
		var omesh: ArrayMesh = _make_orbit_mesh(sys, dom)
		if omesh != null:
			var ov: MeshInstance3D = _ensure_orbit(sys)
			ov.mesh = omesh
		else:
			_clear_orbit()
	else:
		_clear_orbit()


# ===== 预览节点管理(owner=null → 不存盘) =====

func _ensure_soi(sys: CelestialSystem) -> MeshInstance3D:
	if _soi_preview != null and is_instance_valid(_soi_preview):
		return _soi_preview
	var pv := MeshInstance3D.new()
	pv.name = "__SOIPreview__"
	pv.material_override = _make_soi_material()
	sys.add_child(pv)
	pv.owner = null
	_soi_preview = pv
	return pv


func _ensure_orbit(sys: CelestialSystem) -> MeshInstance3D:
	if _orbit_preview != null and is_instance_valid(_orbit_preview):
		return _orbit_preview
	var pv := MeshInstance3D.new()
	pv.name = "__OrbitPreview__"
	pv.material_override = _make_orbit_material()
	sys.add_child(pv)
	pv.owner = null
	_orbit_preview = pv
	return pv


func _clear_previews() -> void:
	_clear_soi()
	_clear_orbit()


func _clear_soi() -> void:
	if _soi_preview != null and is_instance_valid(_soi_preview):
		_soi_preview.queue_free()
	_soi_preview = null


func _clear_orbit() -> void:
	if _orbit_preview != null and is_instance_valid(_orbit_preview):
		_orbit_preview.queue_free()
	_orbit_preview = null


# ===== 材质 =====

# 非顶层系统 SOI 用蓝色(同运行时 _make_soi_material 的 child 色)。
func _make_soi_material() -> Material:
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _PREVIEW_SHADER
	mat.shader = sh
	mat.set_shader_parameter("line_color", Color(0.3, 0.85, 1.0, 0.35))
	return mat


# 轨道用淡蓝灰(同运行时 _make_orbit_material)。
func _make_orbit_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.65, 0.8, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# ===== 系统 / 摄动源 / 签名 =====

# 本系统主导体: 优先 is_dominant; 都没有 → 质量最大的 Celestial(用户要"月球也画", 运行时 _init_physics 同款 fallback)。
func _dominant_of(sys: CelestialSystem) -> Celestial:
	var best: Celestial = null
	for c in sys.get_children():
		if c is Celestial:
			if c.is_dominant:
				return c
			if best == null or c.mass > best.mass:
				best = c
	return best


# 编辑器版摄动源收集: 复刻 _collect_perturbers(celestial_system.gd:772-785), 用场景树代替运行时字段。
func _collect_perturbers_edit(sub: CelestialSystem, out_arr: Array) -> void:
	var s: CelestialSystem = sub
	while s.get_parent() is CelestialSystem:
		var parent: CelestialSystem = s.get_parent() as CelestialSystem
		var pd: Celestial = _dominant_of(parent)
		if pd != null:
			out_arr.append(pd)
		for sib in parent.get_children():
			if sib is CelestialSystem and sib != s:
				var sd: Celestial = _dominant_of(sib as CelestialSystem)
				if sd != null:
					out_arr.append(sd)
		s = parent
	# 顶层 s 的 dominant(运行时第 784-785 行)。
	var td: Celestial = _dominant_of(s)
	if td != null:
		out_arr.append(td)


func _sync_world(c: Celestial) -> void:
	var gp: Vector3 = c.global_position
	c._wx = gp.x
	c._wy = gp.y
	c._wz = gp.z


# 签名覆盖 SOI(dom+sources) 与 Orbit(本系统所有天体位置) 的全部输入 + G。任一变化才重建。
func _signature(sys: CelestialSystem, dom: Celestial, sources: Array) -> String:
	var s := "G:%.4f" % sys.G
	if dom != null:
		s += "|dom:%.3f,%.3f,%.3f:%.3f" % [dom.position.x, dom.position.y, dom.position.z, dom.mass]
	for c in sys.get_children():
		if c is Celestial:
			s += "|c:%.3f,%.3f,%.3f:%.3f:%d:%s" % [c.position.x, c.position.y, c.position.z, c.mass, int(c.is_dominant), c.type]
		elif c is CelestialSystem:
			s += "|cs:%.3f,%.3f,%.3f" % [c.position.x, c.position.y, c.position.z]
	for src in sources:
		var gp: Vector3 = src.global_position
		s += "|src:%.3f,%.3f,%.3f:%.3f" % [gp.x, gp.y, gp.z, src.mass]
	return s


# ===== 轨道: 绕 dominant 的初始圆(add_orbiting 圆速度 + 倾角, 整圆采样) =====

func _make_orbit_mesh(sys: CelestialSystem, dom: Celestial) -> ArrayMesh:
	var dom_local: Vector3 = dom.position
	var positions := PackedVector3Array()
	for c in sys.get_children():
		if c is Celestial:
			if c == dom:
				continue
			_append_circle(positions, dom_local, c.position, 0.25 if c.type == "moon" else 0.0)
		elif c is CelestialSystem:
			# 子系统质点 inclination=0(_init_physics 对 sub 不传 inclination)。
			_append_circle(positions, dom_local, c.position, 0.0)
	if positions.is_empty():
		return null
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return arr_mesh


# 圆轨道平面 = xz 平面绕 x 轴倾斜 inc(add_orbiting 的 inclination 旋转)。
# 基: pHat=(1,0,0); qHat=(0,−sin·inc, cos·inc)。点 = dom_local + dist·(cos·pHat + sin·qHat)。
func _append_circle(positions: PackedVector3Array, dom_local: Vector3, body_local: Vector3, inc: float) -> void:
	var rel: Vector3 = body_local - dom_local
	var dist: float = rel.length()
	if dist < 1.0:
		dist = 2000.0
	var qy: float = -sin(inc)
	var qz: float = cos(inc)
	var n: int = _ORBIT_SEG
	for i in range(n):
		var t0: float = (float(i) / float(n)) * TAU
		var t1: float = (float(i + 1) / float(n)) * TAU
		positions.append(dom_local + dist * Vector3(cos(t0), sin(t0) * qy, sin(t0) * qz))
		positions.append(dom_local + dist * Vector3(cos(t1), sin(t1) * qy, sin(t1) * qz))


# ===== SOI: celestial_system.gd 的 _make_potential_surface_mesh / _soi_radius_on_ray 逐字副本 =====
# (仅 bare G → 传参 g)。改其一务必同步另一处。

func _make_potential_surface_mesh(T: Celestial, sources: Array[Celestial],
		ox: float, oy: float, oz: float, n_lon: int, n_lat: int, hill: float, g: float) -> ArrayMesh:
	var tx: float = T._wx - ox
	var ty: float = T._wy - oy
	var tz: float = T._wz - oz
	var d_near2: float = 1e30
	for S in sources:
		var ex: float = S._wx - T._wx
		var ey: float = S._wy - T._wy
		var ez: float = S._wz - T._wz
		var d2: float = ex * ex + ey * ey + ez * ez
		if d2 < d_near2:
			d_near2 = d2
	# η=1 面(定义: tidal/g=1)朝源方向在 ~0.8×源距; r_max=1.5×最近源距 确保扫描覆盖到边界。
	var r_max: float = maxf(hill, 1.0)
	if not sources.is_empty():
		r_max = maxf(sqrt(d_near2) * 1.5, 1.0)
	var fallback_r: float = hill if hill > 0.0 else r_max
	var use_ball: bool = sources.is_empty()
	# 半径查表 rad[i][j](i=0..n_lat φ, j=0..n_lon θ): 每 (φ,θ) 只采样一次, 经纬线复用。
	var rad: Array = []
	rad.resize(n_lat + 1)
	for i in range(n_lat + 1):
		var phi: float = PI * float(i) / float(n_lat)
		var sinp: float = sin(phi)
		var cosp: float = cos(phi)
		var row: Array = []
		row.resize(n_lon + 1)
		for j in range(n_lon + 1):
			var theta: float = TAU * float(j) / float(n_lon)
			row[j] = _soi_radius_on_ray(T, sources, use_ball, fallback_r, r_max,
				sinp * cos(theta), cosp, sinp * sin(theta), g)
		rad[i] = row
	var positions := PackedVector3Array()
	# 纬线圈: 固定 φ, 连相邻 θ(避开极点 φ=0/π 退化)。
	for i in range(1, n_lat):
		var phi: float = PI * float(i) / float(n_lat)
		var sinp: float = sin(phi)
		var cosp: float = cos(phi)
		for j in range(n_lon):
			var t0: float = TAU * float(j) / float(n_lon)
			var t1: float = TAU * float(j + 1) / float(n_lon)
			var r0: float = rad[i][j]
			var r1: float = rad[i][j + 1]
			positions.append(Vector3(tx + sinp * cos(t0) * r0, ty + cosp * r0, tz + sinp * sin(t0) * r0))
			positions.append(Vector3(tx + sinp * cos(t1) * r1, ty + cosp * r1, tz + sinp * sin(t1) * r1))
	# 经线: 固定 θ, 连相邻 φ。
	for j in range(n_lon):
		var theta: float = TAU * float(j) / float(n_lon)
		var ct: float = cos(theta)
		var st: float = sin(theta)
		for i in range(n_lat):
			var p0: float = PI * float(i) / float(n_lat)
			var p1: float = PI * float(i + 1) / float(n_lat)
			var s0: float = sin(p0)
			var c0: float = cos(p0)
			var s1: float = sin(p1)
			var c1: float = cos(p1)
			var r0: float = rad[i][j]
			var r1: float = rad[i + 1][j]
			positions.append(Vector3(tx + s0 * ct * r0, ty + c0 * r0, tz + s0 * st * r0))
			positions.append(Vector3(tx + s1 * ct * r1, ty + c1 * r1, tz + s1 * st * r1))
	var arr_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return arr_mesh


func _soi_radius_on_ray(T: Celestial, sources: Array[Celestial], use_ball: bool,
		fallback_r: float, r_max: float,
		dx: float, dy: float, dz: float, g: float) -> float:
	if use_ball:
		return fallback_r
	# 内联 η 计算(不调 _max_perturbation_ratio), 省 GDScript 函数调用开销(视觉路径性能关键)。
	var twx: float = T._wx
	var twy: float = T._wy
	var twz: float = T._wz
	var tm: float = T.mass
	var n_scan: int = 10
	var r_prev: float = 0.0
	for k in range(1, n_scan + 1):
		var r_cur: float = r_max * float(k) / float(n_scan)
		var px: float = twx + dx * r_cur
		var py: float = twy + dy * r_cur
		var pz: float = twz + dz * r_cur
		var g_t: float = g * tm / (r_cur * r_cur)
		var eta_cur: float = 0.0
		if g_t > 0.0:
			for S in sources:
				var vpx: float = S._wx - px
				var vpy: float = S._wy - py
				var vpz: float = S._wz - pz
				var dp2: float = vpx * vpx + vpy * vpy + vpz * vpz
				if dp2 < 1e-6:
					continue
				var kp: float = g * S.mass / (dp2 * sqrt(dp2))
				var stx: float = S._wx - twx
				var sty: float = S._wy - twy
				var stz: float = S._wz - twz
				var dt2: float = stx * stx + sty * sty + stz * stz
				if dt2 < 1e-6:
					continue
				var kt: float = g * S.mass / (dt2 * sqrt(dt2))
				var tax: float = kp * vpx - kt * stx
				var tay: float = kp * vpy - kt * sty
				var taz: float = kp * vpz - kt * stz
				var eta: float = sqrt(tax * tax + tay * tay + taz * taz) / g_t
				if eta > eta_cur:
					eta_cur = eta
		if eta_cur >= 1.0:
			var lo: float = r_prev
			var hi: float = r_cur
			for _b in range(8):
				var mid: float = 0.5 * (lo + hi)
				var bpx: float = twx + dx * mid
				var bpy: float = twy + dy * mid
				var bpz: float = twz + dz * mid
				var bg_t: float = g * tm / (mid * mid)
				var b_eta: float = 0.0
				if bg_t > 0.0:
					for S in sources:
						var bvx: float = S._wx - bpx
						var bvy: float = S._wy - bpy
						var bvz: float = S._wz - bpz
						var bp2: float = bvx * bvx + bvy * bvy + bvz * bvz
						if bp2 < 1e-6:
							continue
						var bkp: float = g * S.mass / (bp2 * sqrt(bp2))
						var bstx: float = S._wx - twx
						var bsty: float = S._wy - twy
						var bstz: float = S._wz - twz
						var bdt2: float = bstx * bstx + bsty * bsty + bstz * bstz
						if bdt2 < 1e-6:
							continue
						var bkt: float = g * S.mass / (bdt2 * sqrt(bdt2))
						var bax: float = bkp * bvx - bkt * bstx
						var bay: float = bkp * bvy - bkt * bsty
						var baz: float = bkp * bvz - bkt * bstz
						var e_b: float = sqrt(bax * bax + bay * bay + baz * baz) / bg_t
						if e_b > b_eta:
							b_eta = e_b
				if b_eta >= 1.0:
					hi = mid
				else:
					lo = mid
			return 0.5 * (lo + hi)
		r_prev = r_cur
	return r_max


# ===================== 编辑器自动归属 reparent(用户: 移动天体时实时算归属) =====================
# 仅顶层系统的 SOIEditorPreview 每帧跑(_process 守卫)。取 EditorInterface 选中天体,
# 按 SOI η=1 等势面判定应属系统, 与当前父不同则 reparent。
#   - exclude 当前父: 否则 c 被"自己当 dominant 的容器"(Moon之于MoonSystem)在中心永久捕获, 无法降级。
#   - is_dominant 天体(Star/Planet, SOI 几何中心)跳过 —— 挪它们会破坏 SOI。
#   - cooldown: 防 η 边界抖动导致同天体高频反复 reparent。
#   - 保持世界位 + owner: 视觉无跳变, 存盘到 main.tscn 新路径, 不破坏 celestial.tscn 实例关系。
const _REPARENT_COOLDOWN: int = 30   # 帧(~0.5s @60fps)
var _proc_count: int = 0
var _last_reparent_proc: Dictionary = {}   # c.get_instance_id() -> proc_count
var _last_reparent_pos: Dictionary = {}   # c.get_instance_id() -> Vector3 上次 reparent 基准位(防静止抖动)
@export var _diag_proc: int = 0   # 诊断(读两次看递增): _process 计数, 不增=@tool没在编辑器跑
@export var _diag_sel: int = 0   # 诊断: 上帧选中的非dominant Celestial 数(0=没选/选了MoonSystem或dominant)
@export var _diag_last: String = ""   # 诊断: "Moon:A->B" / "stable@A" / "cooldown" / "nosel" / "Moon:not in top"


func _try_auto_reparent(top: CelestialSystem) -> void:
	_proc_count += 1
	_diag_proc += 1
	var sel := EditorInterface.get_selection()
	if sel == null:
		_diag_sel = 0
		_diag_last = "nosel(null)"
		return
	var sel_nodes = sel.get_selected_nodes()
	_sync_all_world(top)   # η 判定需全树天体世界位(_wx/_wy/_wz)
	_diag_sel = 0
	if sel_nodes.is_empty():
		_diag_last = "nosel"
	for node in sel_nodes:
		if node is Celestial:
			var c: Celestial = node as Celestial
			# 中心天体(dominant)固定不挪 —— 移动卫星系统 = 移动容器(MoonSystem), 不是掏出中心天体。
			# is_dominant(Star/Planet)或 fallback 当 dominant(Moon之于MoonSystem)都算。否则用户手动
			# 拖 Moon 到 MoonSystem 整理结构时, @tool 会立即 reparent 覆盖(Moon 被判归 CS1 弹走)。
			if c.is_dominant:
				continue
			var self_sys: CelestialSystem = _find_owning_dominant_system(top, c)
			if self_sys != null:
				_diag_last = "%s: dom of %s (中心天体, 固定)" % [c.name, self_sys.name]
				continue
			_diag_sel += 1
			var cur: Node = c.get_parent()
			if not (cur is CelestialSystem):
				_diag_last = "%s: cur not CS" % c.name
				continue
			if not _is_in_subtree(c, top):
				_diag_last = "%s: not in top" % c.name
				continue
			var cid: int = c.get_instance_id()
			var p: Vector3 = c.global_position
			if _last_reparent_proc.has(cid):
				var last_pos: Vector3 = _last_reparent_pos[cid]
				if p.distance_to(last_pos) < 1.0 and _proc_count - int(_last_reparent_proc[cid]) < _REPARENT_COOLDOWN:
					_diag_last = "%s: cooldown" % c.name
					continue
			# c 是游离天体(不当任何系统 dominant), 按 SOI 归属 reparent。
			var desired: CelestialSystem = _capture_descend_edit(top, p.x, p.y, p.z, null)
			if desired == null or desired == cur:
				_diag_last = "%s: stable@%s" % [c.name, cur.name]
				continue
			_diag_last = "%s: %s->%s" % [c.name, cur.name, desired.name]
			_reparent_keep_world(c, desired)
			_last_reparent_proc[cid] = _proc_count
			_last_reparent_pos[cid] = p
		elif node is CelestialSystem:
			# 选中"系统容器"(如 MoonSystem, 内含 Moon 当 dominant): 整个系统按 SOI 归属 reparent。
			# 对应运行时 _reparent_subsystem。用户架构: 卫星=容器, 月球是容器中心。exclude 自己防自捕获。
			var sub: CelestialSystem = node as CelestialSystem
			var scur: Node = sub.get_parent()
			if not (scur is CelestialSystem) or scur == top:
				_diag_last = "%s: sub top" % sub.name
				continue   # 顶层/直接挂顶层群的不 reparent
			if not _is_in_subtree(sub, top):
				_diag_last = "%s: not in top" % sub.name
				continue
			if _dominant_of(sub) == null:
				_diag_last = "%s: no dom" % sub.name
				continue   # 空群(无dominant)无归属意义
			_diag_sel += 1
			var scid: int = sub.get_instance_id()
			var sp: Vector3 = sub.global_position
			if _last_reparent_proc.has(scid):
				var slast: Vector3 = _last_reparent_pos[scid]
				if sp.distance_to(slast) < 1.0 and _proc_count - int(_last_reparent_proc[scid]) < _REPARENT_COOLDOWN:
					_diag_last = "%s: cooldown" % sub.name
					continue
			var sdesired: CelestialSystem = _capture_descend_edit(top, sp.x, sp.y, sp.z, sub)
			if sdesired == null or sdesired == scur:
				_diag_last = "%s: stable@%s" % [sub.name, scur.name]
				continue
			_diag_last = "%s: %s->%s" % [sub.name, scur.name, sdesired.name]
			_reparent_keep_world(sub, sdesired)
			_last_reparent_proc[scid] = _proc_count
			_last_reparent_pos[scid] = sp


# 找 c 当 dominant 的系统(c 的"私有容器", 如 Moon 之于 MoonSystem)。永远 exclude —— 否则 c 在
# 自己中心 η=0 被永久捕获。遍历 top 子树所有 CelestialSystem。
func _find_owning_dominant_system(root: Node, c: Celestial) -> CelestialSystem:
	if root is CelestialSystem and _dominant_of(root as CelestialSystem) == c:
		return root as CelestialSystem
	for ch in root.get_children():
		var found: CelestialSystem = _find_owning_dominant_system(ch, c)
		if found != null:
			return found
	return null


# 从 start 向下找包含 (px,py,pz) 的最深子系统(复刻 _capture_descend, exclude 当前父防自捕获)。
func _capture_descend_edit(start: CelestialSystem, px: float, py: float, pz: float,
		exclude: CelestialSystem) -> CelestialSystem:
	var s: CelestialSystem = start
	while true:
		var nxt: CelestialSystem = null
		for ch in s.get_children():
			if not (ch is CelestialSystem) or ch == exclude:
				continue
			var sub: CelestialSystem = ch as CelestialSystem
			if _dominant_of(sub) == null:
				continue
			if _inside_potential_surface_edit(sub, px, py, pz, 1.0):
				nxt = sub
				break
		if nxt == null:
			return s
		s = nxt
	return s   # 不可达; 满足 GDScript 全路径返回


# 复刻 _inside_potential_surface: sources 空→退化 Hill 估计球(η_thresh 缩放); 否则 η<eta_thresh。
func _inside_potential_surface_edit(sub: CelestialSystem, px: float, py: float, pz: float,
		eta_thresh: float) -> bool:
	var T: Celestial = _dominant_of(sub)
	if T == null:
		return false
	var g: float = sub.G
	var sources: Array[Celestial] = []
	_collect_perturbers_edit(sub, sources)
	if sources.is_empty():
		var Tp := T.global_position
		var dx: float = px - Tp.x
		var dy: float = py - Tp.y
		var dz: float = pz - Tp.z
		var hill_est: float = _hill_estimate(sub, T)
		var r_in: float = hill_est * eta_thresh
		return (dx * dx + dy * dy + dz * dz) < r_in * r_in
	return _max_eta_edit(T, sources, px, py, pz, g) < eta_thresh


# 复刻 _max_perturbation_ratio(用 T/sources 的 _wx/_wy/_wz, 传参 g = sub.G)。
func _max_eta_edit(T: Celestial, sources: Array, px: float, py: float, pz: float, g: float) -> float:
	if sources.is_empty():
		return 0.0
	# 直接用 global_position(不依赖 _wx —— 后者经 _walk_sync 的 `is Celestial` 同步, 脚本类检查在 @tool
	# 对实例化节点不可靠, 会漏同步导致 η≈0 误判)。
	var Tp := T.global_position
	var rx: float = px - Tp.x
	var ry: float = py - Tp.y
	var rz: float = pz - Tp.z
	var r2: float = rx * rx + ry * ry + rz * rz
	if r2 < 1e-6:
		return 0.0
	var g_t: float = g * T.mass / r2
	if g_t <= 0.0:
		return 0.0
	var max_eta: float = 0.0
	for S in sources:
		var Sp: Vector3 = S.global_position
		var vpx: float = Sp.x - px
		var vpy: float = Sp.y - py
		var vpz: float = Sp.z - pz
		var dp2: float = vpx * vpx + vpy * vpy + vpz * vpz
		if dp2 < 1e-6:
			continue
		var kp: float = g * S.mass / (dp2 * sqrt(dp2))
		var vtx: float = Sp.x - Tp.x
		var vty: float = Sp.y - Tp.y
		var vtz: float = Sp.z - Tp.z
		var dt2: float = vtx * vtx + vty * vty + vtz * vtz
		if dt2 < 1e-6:
			continue
		var kt: float = g * S.mass / (dt2 * sqrt(dt2))
		var tax: float = kp * vpx - kt * vtx
		var tay: float = kp * vpy - kt * vty
		var taz: float = kp * vpz - kt * vtz
		var eta: float = sqrt(tax * tax + tay * tay + taz * taz) / g_t
		if eta > max_eta:
			max_eta = eta
	return max_eta


# Hill 估计(编辑器无运行时 _hill_radius): dominant 到最近摄动源距离 × 0.5(L1 量级近似)。
# 无摄动源(单星顶层) → 返回大值, 该层总能容纳, 靠下层 SOI 捕获细分。
func _hill_estimate(sub: CelestialSystem, T: Celestial) -> float:
	var sources: Array[Celestial] = []
	_collect_perturbers_edit(sub, sources)
	if sources.is_empty():
		return 1e12
	var Tp := T.global_position
	var nearest: float = 1e30
	for S in sources:
		var Sp: Vector3 = S.global_position
		var dx: float = Sp.x - Tp.x
		var dy: float = Sp.y - Tp.y
		var dz: float = Sp.z - Tp.z
		var d: float = sqrt(dx * dx + dy * dy + dz * dz)
		if d < nearest:
			nearest = d
	return nearest * 0.5


# reparent 保持世界位 + owner。owner 不变 → 存盘到 main.tscn 新路径, celestial.tscn 实例关系不破坏。
func _reparent_keep_world(c: Node3D, to: CelestialSystem) -> void:
	# Node.reparent(new_parent, keep_global_transform=true): Godot 内置, 正确带所有子节点跟随 +
	# 世界位保持 + 实例关系。旧的手动 remove/add 会让 celestial.tscn 实例子节点(如 Moon 嵌在
	# MoonSystem 实例里)在跨实例 reparent 时脱落丢失。
	var prev_owner: Node = c.owner
	var cur: Node = c.get_parent()
	var from_name: String = cur.name if cur != null else "?"
	c.reparent(to, true)
	# owner 保持(存盘归属不变)——reparent 不改 owner, 但跨实例保险重设。
	if prev_owner != null and _is_in_subtree(to, prev_owner):
		c.owner = prev_owner
	print("[SOI-edit] %s: %s -> %s" % [c.name, from_name, to.name])


# 同步 top 子树所有 Celestial 的 _wx/_wy/_wz = global_position(η 判定输入)。
func _sync_all_world(top: CelestialSystem) -> void:
	_walk_sync(top)


func _walk_sync(n: Node) -> void:
	if n is Celestial:
		_sync_world(n as Celestial)
	for ch in n.get_children():
		_walk_sync(ch)


# node 是否在 ancestor 子树内(沿 parent 上溯)。
func _is_in_subtree(node: Node, ancestor: Node) -> bool:
	var n: Node = node
	while n != null:
		if n == ancestor:
			return true
		n = n.get_parent()
	return false
