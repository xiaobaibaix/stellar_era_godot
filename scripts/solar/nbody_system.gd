## N 体引力内核(纯物理, 不依赖渲染)。移植 webs/solar_system/nbody.js 的 NBodySystem。
##
## 积分器: velocity-Verlet(辛积分, 长期能量稳定; 普通欧拉会让轨道漂移/飞散)。
## 引力: 两两 F = G·m1·m2/r², 带软化 eps 避免近距奇点。
## 物理 double 精度(Body 用标量); 天体个位数 → O(n²) 在 GDScript 里无压力。
## 测试粒子(小行星带/星环): 只受大质量天体引力, 不参与两两。
class_name NBodySystem
extends RefCounted

var bodies: Array = []        # Array[Body] 大质量天体
var particles: Array = []     # 测试粒子(Dictionary: px..pz / vx..vz / _ox.._oz)
var G: float = 1.0
var softening: float = 1.0    # 软化长度(避免 r→0 力爆炸)
var time: float = 0.0


func _init(p_G: float = 1.0, p_softening: float = 1.0) -> void:
	G = p_G
	softening = p_softening


func add(body: Body) -> Body:
	bodies.append(body)
	return body


func clear() -> void:
	bodies.clear()
	particles.clear()
	time = 0.0


# 加一个测试粒子(质量忽略, 不影响其它天体)
func add_particle(p_pos: Vector3, p_vel: Vector3) -> void:
	particles.append({
		"px": p_pos.x, "py": p_pos.y, "pz": p_pos.z,
		"vx": p_vel.x, "vy": p_vel.y, "vz": p_vel.z,
		"_ox": 0.0, "_oy": 0.0, "_oz": 0.0,
	})


# 某点处来自所有大质量天体的加速度(测试粒子用)。返回 32 位 Vector3(粒子精度要求较低)。
func accel_at(px: float, py: float, pz: float) -> Vector3:
	var ax := 0.0
	var ay := 0.0
	var az := 0.0
	var eps2 := softening * softening
	for j in bodies:
		var dx: float = j.px - px
		var dy: float = j.py - py
		var dz: float = j.pz - pz
		var r2: float = dx * dx + dy * dy + dz * dz + eps2
		var s: float = G * j.mass / (r2 * sqrt(r2))
		ax += s * dx
		ay += s * dy
		az += s * dz
	return Vector3(ax, ay, az)


# 计算所有大质量天体加速度(两两引力), 写入 body.a*。O(n²)。
func compute_accelerations() -> void:
	var eps2 := softening * softening
	var n := bodies.size()
	for i in range(n):
		var bi: Body = bodies[i]
		bi.ax = 0.0
		bi.ay = 0.0
		bi.az = 0.0
	for i in range(n):
		var bi: Body = bodies[i]
		for j in range(i + 1, n):
			var bj: Body = bodies[j]
			var dx: float = bj.px - bi.px
			var dy: float = bj.py - bi.py
			var dz: float = bj.pz - bi.pz
			var r2: float = dx * dx + dy * dy + dz * dz + eps2
			var inv_r := 1.0 / sqrt(r2)
			var inv_r3 := inv_r / r2             # 1/r³
			var s := G * inv_r3
			# a_i += G·m_j/r³·d ; a_j -= G·m_i/r³·d
			var si: float = s * bj.mass
			var sj: float = s * bi.mass
			bi.ax += si * dx; bi.ay += si * dy; bi.az += si * dz
			bj.ax -= sj * dx; bj.ay -= sj * dy; bj.az -= sj * dz


# 一步 velocity-Verlet:
#   x(t+dt) = x + v·dt + ½·a·dt²
#   v(t+dt) = v + ½·(a + a_new)·dt
func step(dt: float) -> void:
	var n := bodies.size()
	var np := particles.size()
	if n == 0 and np == 0:
		return
	var half := 0.5 * dt * dt
	var hdt := 0.5 * dt

	compute_accelerations()                       # 大质量 a(t)
	for k in range(np):                           # 粒子 a0(用 t 时 massive 位置)
		var pr: Dictionary = particles[k]
		var a := accel_at(pr.px, pr.py, pr.pz)
		pr._ox = a.x; pr._oy = a.y; pr._oz = a.z

	for i in range(n):                            # drift massive
		var p: Body = bodies[i]
		p.px += p.vx * dt + p.ax * half
		p.py += p.vy * dt + p.ay * half
		p.pz += p.vz * dt + p.az * half
		p._ox = p.ax; p._oy = p.ay; p._oz = p.az   # 记 a(t)
	for k in range(np):                           # drift particles
		var pr: Dictionary = particles[k]
		pr.px += pr.vx * dt + pr._ox * half
		pr.py += pr.vy * dt + pr._oy * half
		pr.pz += pr.vz * dt + pr._oz * half

	compute_accelerations()                       # 大质量 a(t+dt)
	for i in range(n):                            # kick massive
		var p: Body = bodies[i]
		p.vx += (p._ox + p.ax) * hdt
		p.vy += (p._oy + p.ay) * hdt
		p.vz += (p._oz + p.az) * hdt
	for k in range(np):                           # kick particles(用 t+dt 时 massive 位置)
		var pr: Dictionary = particles[k]
		var a := accel_at(pr.px, pr.py, pr.pz)
		pr.vx += (pr._ox + a.x) * hdt
		pr.vy += (pr._oy + a.y) * hdt
		pr.vz += (pr._oz + a.z) * hdt
	time += dt


# 在 primary 周围加一个圆轨道天体(v = √(G·M_primary / r), 垂直于连线)。
# 速度叠加 primary 自身速度 → 天然支持嵌套(卫星绕行星绕恒星)。
func add_orbiting(primary: Body, opts: Dictionary) -> Body:
	var mass: float = opts.get("mass", 1.0)
	var radius: float = opts.get("radius", 1.0)
	var dist: float = opts.get("dist", 1.0)
	var phase: float = opts.get("phase", 0.0)
	var inclination: float = opts.get("inclination", 0.0)
	var retro: bool = opts.get("retro", false)
	var color: Color = opts.get("color", Color.WHITE)
	var bname: String = opts.get("name", "")
	var btype: String = opts.get("type", "planet")
	# 轨道平面内位置偏移(默认 xz 平面, 再绕 x 轴倾斜 inclination)
	var ox := cos(phase) * dist
	var oy := 0.0
	var oz := sin(phase) * dist
	# 切向(逆行时反向)
	var tx := -sin(phase)
	var ty := 0.0
	var tz := cos(phase)
	if retro:
		tx = -tx
		tz = -tz
	if inclination != 0.0:
		# 绕 x 轴旋转: y' = y·cos − z·sin ; z' = y·sin + z·cos
		var c := cos(inclination)
		var s := sin(inclination)
		var n_oy := oy * c - oz * s
		var n_oz := oy * s + oz * c
		oy = n_oy
		oz = n_oz
		var n_ty := ty * c - tz * s
		var n_tz := ty * s + tz * c
		ty = n_ty
		tz = n_tz
	var speed := sqrt(G * primary.mass / dist)
	var body := Body.new(bname, mass)
	body.radius = radius
	body.color = color
	body.type = btype
	# 全程 double 标量, 不经 Vector3 → 大 dist 不丢精度
	body.set_pos(primary.px + ox, primary.py + oy, primary.pz + oz)
	body.set_vel(primary.vx + tx * speed, primary.vy + ty * speed, primary.vz + tz * speed)
	body.primary = primary
	return add(body)


# 归零总动量 → 质心不漂移(整个系统留在原地)
func zero_momentum() -> void:
	var px := 0.0; var py := 0.0; var pz := 0.0
	var M := 0.0
	for bd in bodies:
		px += bd.vx * bd.mass
		py += bd.vy * bd.mass
		pz += bd.vz * bd.mass
		M += bd.mass
	if M <= 0.0:
		return
	var vxcm := px / M
	var vycm := py / M
	var vzcm := pz / M
	for bd in bodies:
		bd.vx -= vxcm
		bd.vy -= vycm
		bd.vz -= vzcm


# 质心(浮动原点/聚焦用)
func barycenter() -> Vector3:
	var bx := 0.0; var by := 0.0; var bz := 0.0
	var M := 0.0
	for bd in bodies:
		bx += bd.px * bd.mass
		by += bd.py * bd.mass
		bz += bd.pz * bd.mass
		M += bd.mass
	if M > 0.0:
		bx /= M; by /= M; bz /= M
	return Vector3(bx, by, bz)


# 总能量(动能 + 势能), 用于验证积分稳定性(应基本守恒)。
func energy() -> Dictionary:
	var ke := 0.0
	var pe := 0.0
	var n := bodies.size()
	for i in range(n):
		var b: Body = bodies[i]
		ke += 0.5 * b.mass * b.speed_squared()
	for i in range(n):
		var bi: Body = bodies[i]
		for j in range(i + 1, n):
			var bj: Body = bodies[j]
			var dx: float = bi.px - bj.px
			var dy: float = bi.py - bj.py
			var dz: float = bi.pz - bj.pz
			var r := sqrt(dx * dx + dy * dy + dz * dz) + 1e-9
			pe -= G * bi.mass * bj.mass / r
	return {"ke": ke, "pe": pe, "total": ke + pe}
