## N 体内核自检(Phase 4 第 1 步验证)。挂到临时场景的根 Node 上 F6 运行, 看 Output。
## 预期: 圆轨道 velocity-Verlet 能量漂移 << 1%, 行星到恒星距离稳定在 ~dist。
extends Node


func _ready() -> void:
	# 两体: 大质量恒星 + 圆轨道行星。G=1, 软化 0.01。
	var sim := NBodySystem.new(1.0, 0.01)
	var star := Body.new("star", 1000.0)
	star.radius = 5.0
	star.type = "star"
	sim.add(star)
	var planet := sim.add_orbiting(star, {
		"mass": 1.0, "dist": 100.0, "radius": 1.0,
		"name": "planet", "type": "planet",
	})
	sim.zero_momentum()                       # 质心不漂移

	var e0: Dictionary = sim.energy()
	var dist0 := _dist(planet, star)
	var d0 := planet.px                       # 记起始 x, 看一周后是否回到近旁(闭合轨道)

	var steps := 4000                         # ≈1 个轨道周期(T=2π√(r³/GM)≈199; dt=0.05 → 3974 步)
	var dt := 0.05
	for i in range(steps):
		sim.step(dt)

	var e1: Dictionary = sim.energy()
	var dist1 := _dist(planet, star)

	var drift: float = abs(e1.total - e0.total) / max(abs(e0.total), 1e-9) * 100.0
	print("== N-body self-test ==")
	print("steps=%d  dt=%.3f  sim_time=%.2f" % [steps, dt, sim.time])
	print("energy0=%s" % e0.total)
	print("energy1=%s" % e1.total)
	print("energy drift = %.5f %%  (圆轨道 Verlet 应 << 1%%)" % drift)
	print("dist star↔planet: start=%.3f  end=%.3f  (应稳定在 ~100)" % [dist0, dist1])
	print("planet x: start=%.3f  end=%.3f  (一周后应回到近旁)" % [d0, planet.px])
	if drift < 1.0:
		print("PASS ✓ 积分稳定")
	else:
		print("FAIL ✗ 漂移过大, 检查 step()/compute_accelerations()")


static func _dist(a: Body, b: Body) -> float:
	var dx: float = a.px - b.px
	var dy: float = a.py - b.py
	var dz: float = a.pz - b.pz
	return sqrt(dx * dx + dy * dy + dz * dz)
