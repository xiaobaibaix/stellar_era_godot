@tool
class_name SOIEditorPreview
extends MeshInstance3D
## 编辑器内 SOI 等势面预览: 挂在预制体 celestial_system.tscn 的 SOI 节点上(仅借宿, 自身 mesh 不动)。
## 实际渲染到一个 INTERNAL_MODE_BACK 临时子节点(挂在本系统下) → 不进场景存盘、不污染 git diff。
## 用场景树里的位置/质量算本系统 SOI 边界并实时显示, 方便放置子天体时直观看到引力作用范围。
## 摄动源收集复刻运行时 _collect_perturbers; mesh 数学复刻 _make_potential_surface_mesh/_soi_radius_on_ray
## (必须本地复制: celestial_system.gd 非 @tool, 编辑器里其实例是 placeholder, 方法调用会失败;
##  仅 bare G 换成传参 g, 由 sys.G 读出)。保证编辑器看到的形状 = 运行时形状(同一等势面 η=1)。
## 运行时由 celestial_system.gd 接管 SOI; 本脚本 is_editor_hint() 守卫, 运行时 _process 直接返回。

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

var _last_sig: String = ""
var _preview: MeshInstance3D = null


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		# 运行时: 清掉可能残留的预览子节点(理论不会被存盘加载, 双保险), 交给 celestial_system.gd。
		_clear_preview()
		return
	var sys: CelestialSystem = get_parent() as CelestialSystem
	if sys == null:
		return
	# 顶层系统(parent 非 CelestialSystem)SOI 无穷大, 不画(同运行时 _build_soi_visuals_all 的守卫)。
	if not (sys.get_parent() is CelestialSystem):
		_clear_preview()
		_last_sig = ""
		return
	var dom: Celestial = _dominant_of(sys)
	if dom == null:
		_clear_preview()
		_last_sig = ""
		return
	# 摄动源 = 沿祖先链的祖辈 dominant + 同层兄弟 dominant(复刻 _collect_perturbers, 用场景树)。
	var sources: Array[Celestial] = []
	_collect_perturbers_edit(sys, sources)
	# 位置/质量未变则跳过重建(编辑器空闲时近乎零开销, 仅在拖动天体时重算)。
	var sig := _signature(sys, dom, sources)
	if sig == _last_sig:
		return
	_last_sig = sig
	if sources.is_empty():
		# 无外部摄动(如孤立子系统) → SOI 无穷大, 不画。
		_clear_preview()
		return
	# 同步编辑器世界位到 _wx(_soi_radius_on_ray 读 T._wx/sources._wx; 运行时由 _step 重设, 不影响)。
	_sync_world(dom)
	for s in sources:
		_sync_world(s)
	var pv: MeshInstance3D = _ensure_preview(sys)
	# mesh 原点取系统世界位 → 顶点为系统局部坐标; 预览节点(系下局部 0)随之, 拖动系统时 mesh 跟随。
	var so: Vector3 = sys.global_position
	pv.mesh = _make_potential_surface_mesh(dom, sources, so.x, so.y, so.z, 24, 12, 0.0, sys.G)


# 临时预览节点: owner=null → 不随场景存盘(纯编辑器预览; 运行时不加载, celestial_system.gd 接管 SOI)。
func _ensure_preview(sys: CelestialSystem) -> MeshInstance3D:
	if _preview != null and is_instance_valid(_preview):
		return _preview
	var pv := MeshInstance3D.new()
	pv.name = "__SOIPreview__"
	pv.material_override = _make_preview_material()
	sys.add_child(pv)
	pv.owner = null
	_preview = pv
	return pv


func _clear_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null


# 非顶层系统用蓝色(同运行时 _make_soi_material 的 child 色; 顶层不画, 不到这里)。
func _make_preview_material() -> Material:
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _PREVIEW_SHADER
	mat.shader = sh
	mat.set_shader_parameter("line_color", Color(0.3, 0.85, 1.0, 0.35))
	return mat


# 本系统主导体 = 子里首个 is_dominant 的 Celestial(同运行时 _collect 的判定)。
func _dominant_of(sys: CelestialSystem) -> Celestial:
	for c in sys.get_children():
		if c is Celestial and c.is_dominant:
			return c
	return null


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


func _signature(sys: CelestialSystem, dom: Celestial, sources: Array) -> String:
	var sp: Vector3 = sys.global_position
	var dp: Vector3 = dom.global_position
	var s := "sys:%.3f,%.3f,%.3f|dom:%.3f,%.3f,%.3f:%.3f" % [sp.x, sp.y, sp.z, dp.x, dp.y, dp.z, dom.mass]
	for c in sources:
		var cp: Vector3 = c.global_position
		s += "|s:%.3f,%.3f,%.3f:%.3f" % [cp.x, cp.y, cp.z, c.mass]
	return s


# ===== 以下两函数为 celestial_system.gd 的 _make_potential_surface_mesh / _soi_radius_on_ray 逐字副本 =====
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
