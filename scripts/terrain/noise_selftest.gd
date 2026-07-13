## 共享噪声 GPU/CPU 自检(Phase 1+ Step1)。挂 noise_test.tscn 根节点, F6 运行。
##
## 把 noise_test.gdshader 渲染到 64×64 SubViewport, 读回 R 通道(已映射 [0,1]),
## 与 NoiseShared 的 noise3/fbm/ridged/worley_f2f1 经同映射后的值逐像素比对。
##
## 容差 0.003(> 8 bit LDR 量化上界 0.00196)→ 通过即证明 GPU/CPU 噪声一致。
## (旧版 0.002 误差就是这 8 bit 量化, 并非不一致。)
extends Node

const TEX_SIZE := 64
const SCALE := 4.0
const TOL := 0.003
const RESULT_PATH := "user://noise_selftest_result.txt"

const NAMES := ["noise3", "fbm", "ridged", "worley_f2f1", "height_full"]

var _terrain: Terrain


func _ready() -> void:
	var vp := SubViewport.new()
	vp.name = "NoiseVP"
	vp.size = Vector2i(TEX_SIZE, TEX_SIZE)
	vp.disable_3d = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var cr := ColorRect.new()
	cr.color = Color.BLACK
	cr.size = Vector2(TEX_SIZE, TEX_SIZE)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/noise_test.gdshader")
	mat.set_shader_parameter("scale", SCALE)
	cr.material = mat
	vp.add_child(cr)

	var report := PackedStringArray()
	report.append("== noise GPU/CPU self-test (single-channel, 8bit) ==")
	report.append("tex=%d  scale=%.2f  samples/primitive=%d  tol=%s" % [TEX_SIZE, SCALE, TEX_SIZE * TEX_SIZE, TOL])

	var any_fail := false
	_terrain = Terrain.from_params(PlanetParams.new())
	for prim in range(5):
		mat.set_shader_parameter("primitive", prim)
		await get_tree().process_frame
		await get_tree().process_frame

		var img: Image = vp.get_texture().get_image()
		if img == null:
			report.append("  [%s] FAIL: viewport image null" % NAMES[prim])
			any_fail = true
			continue

		var max_err: float = 0.0
		var sum_err: float = 0.0
		var worst_uv := Vector2.ZERO
		var count: int = 0
		for py in range(TEX_SIZE):
			for px in range(TEX_SIZE):
				var uv := Vector2((float(px) + 0.5) / float(TEX_SIZE), (float(py) + 0.5) / float(TEX_SIZE))
				var gpu: float = img.get_pixel(px, py).r                       # shader 输出已映射 [0,1]
				var cpu_raw: float = _cpu_sample(prim, uv.x * SCALE, uv.y * SCALE)
				var cpu: float = clampf(cpu_raw * 0.5 + 0.5, 0.0, 1.0)         # 同映射
				var err: float = abs(gpu - cpu)
				if err > max_err:
					max_err = err
					worst_uv = uv
				sum_err += err
				count += 1
		var ok := max_err < TOL
		if not ok:
			any_fail = true
		report.append("  [%-11s] max=%s  mean=%s  worst_uv=%s  %s" % [NAMES[prim], max_err, sum_err / float(count), worst_uv, "PASS" if ok else "FAIL"])

	if any_fail:
		report.append("FAIL ✗ 有原语误差超限")
	else:
		report.append("PASS ✓ 全部原语 GPU/CPU 一致(< %s) → 可进入 Step2/3" % TOL)

	for line in report:
		print(line)
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		for line in report:
			f.store_line(line)
		f.close()
	queue_free()


func _cpu_sample(prim: int, x: float, y: float) -> float:
	match prim:
		0: return NoiseShared.noise3(x, y, 0.0)
		1: return NoiseShared.fbm(x, y, 0.0, 5, 0.5, 2.0)
		2: return NoiseShared.ridged(x, y, 0.0, 5, 0.5, 2.0)
		3: return NoiseShared.worley_f2f1(x, y, 0.0)
		4: return _terrain.height_at(x, y, 0.0)
		_: return 0.0
