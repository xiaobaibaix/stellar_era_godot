# gdlint: disable=variable-name, max-line-length
## Phase 0 验证(照搬 noise_selftest.gd 惯例: 挂场景根节点, F6 运行, 打印报告 + 写 user://)。
##
## Phase 3 v2: 适配 cell 布局(bake_res² per face, gather 归约)。
##
## 验证三件事:
##   (A) GpuIco: 12 顶点单位化 / 20 面索引合法 / 30 边每边恰 2 面 / 流形(flipped 全 false)。
##   (B) MinMax 金字塔不变量: 任意 (面, mip级, i, j) 的 (min,max) == 其 mip0 足迹内所有有效样本的
##       (min, max)。独立于 _build_face_pyramid 的实现, 用直接扫描足实验证。
##   (C) 近似刻画(离网格随机采样): mip0 cell 的中心采样值 vs 真值 height_at 的偏差统计 ——
##       cell 越粗(bake_res 越小)或地形频率越高, 偏差越大; 作为 BAKE_RES 选型依据。
##
## 注意: 自检用 BAKE_RES=64(快速验证逻辑), 生产烘焙用 512(GpuLodCompositor.BAKE_RES)。
class_name MinMaxSelftest
extends Node

const DEFAULT_BAKE_RES := 64
const RESULT_PATH := "user://minmax_selftest_result.txt"
const OFFGRID_SAMPLES := 4000          # 近似刻画采样数
const PYRAMID_PROBES := 2000           # 金字塔不变量探测数
const TOL := 1.0e-4                     # float32 归约误差容差(世界单位)


func _ready() -> void:
	var res: Dictionary = run(DEFAULT_BAKE_RES)
	var report: PackedStringArray = res["report"]
	for line in report:
		print(line)
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		for line in report:
			f.store_line(line)
		f.close()
	queue_free()


# 主逻辑(静态, 可被 godot_exec 调用)。返回 {report, ok, bake_ms, approx_oob_pct}。
static func run(bake_res: int = DEFAULT_BAKE_RES) -> Dictionary:
	var report: PackedStringArray = []
	report.append("== Phase 0 MinMax/GpuIco self-test (cell layout v2) ==")
	report.append("bake_res=%d  offgrid_samples=%d  pyramid_probes=%d  tol=%.6f" % [bake_res, OFFGRID_SAMPLES, PYRAMID_PROBES, TOL])

	var params := PlanetParams.new()
	var terrain := Terrain.from_params(params)
	report.append("params: radius=%f maxHeight=%f  (terrain 共享噪声)" % [params.radius, params.maxHeight])

	# ---- (A) GpuIco ----
	var ico_rep: PackedStringArray = GpuIco.verify()
	for line in ico_rep:
		report.append("  " + line)
	var ico_ok: bool = ico_rep[ico_rep.size() - 1].find("PASS") >= 0

	# ---- 烘焙(计时) ----
	var t1: int = Time.get_ticks_usec()
	var data: GpuMinMaxData = HeightmapBaker.bake(params, bake_res)
	var t2: int = Time.get_ticks_usec()
	var bake_ms: int = (t2 - t1) / 1000
	report.append("bake time: %d ms (20 faces × %d² height_at calls)" % [bake_ms, bake_res])

	# ---- (B) 金字塔不变量 ----
	var pyr_ok: bool = _verify_pyramid_invariant(data, bake_res, report)

	# ---- (C) 近似刻画 ----
	var oob_pct: float = _characterize_approximation(data, terrain, params, bake_res, report)

	var overall: bool = ico_ok and pyr_ok
	report.append("---- summary ----")
	report.append("(A) GpuIco      : %s" % ("PASS ✓" if ico_ok else "FAIL ✗"))
	report.append("(B) Pyramid inv : %s" % ("PASS ✓" if pyr_ok else "FAIL ✗"))
	report.append("OVERALL: %s  (bake_time=%dms  approx_oob=%.1f%%)" % ["PASS ✓" if overall else "FAIL ✗", bake_ms, oob_pct])
	return {"report": report, "ok": overall, "bake_ms": bake_ms, "approx_oob_pct": oob_pct}


# 金字塔不变量: mip[k](i,j) 的 min/max = 其 mip0 足迹内所有有效样本的 min/max。
# Cell 布局: mip k cell (i, j) 的 mip0 足迹 = [i*2^k, (i+1)*2^k - 1] × [j*2^k, (j+1)*2^k - 1]。
static func _verify_pyramid_invariant(data: GpuMinMaxData, bake_res: int, report: PackedStringArray) -> bool:
	var pyr: Array = data.build_pyramid()
	var max_err: float = 0.0
	var fails: int = 0
	var probes: int = 0
	for fi in range(GpuIco.FACE_COUNT):
		var fmips: Array = pyr[fi]
		var mip0: PackedFloat32Array = fmips[0]
		var nmip: int = fmips.size()
		for mip in range(1, nmip):
			var edge: int = bake_res >> mip          # 该 mip 的 cell 边数(cells per side)
			var step: int = 1 << mip                 # mip0 足迹边长(cells) = 2^mip
			var stride: int = max(1, edge / 6)
			var j: int = 0
			while j < edge:                          # cells 0..edge-1
				var i: int = 0
				while i < edge:
					if i + j < edge:                 # cell 有效
						probes += 1
						# 扫描 mip0 足迹 [i*step, (i+1)*step-1] × [j*step, (j+1)*step-1]
						var ref_min: float = GpuMinMaxData.MIN_SENTINEL
						var ref_max: float = GpuMinMaxData.MAX_SENTINEL
						var i0: int = i * step
						var j0: int = j * step
						var jj: int = j0
						while jj < j0 + step:
							var ii: int = i0
							while ii < i0 + step:
								if ii + jj < bake_res:   # mip0 cell 有效
									var src: int = (jj * bake_res + ii) * 2
									var mn: float = mip0[src]
									if mn < GpuMinMaxData.MIN_SENTINEL * 0.5:
										ref_min = min(ref_min, mn)
										ref_max = max(ref_max, mip0[src + 1])
								ii += 1
							jj += 1
						var arr: PackedFloat32Array = fmips[mip]
						var didx: int = (j * edge + i) * 2
						var got_min: float = arr[didx]
						var got_max: float = arr[didx + 1]
						if ref_min >= GpuMinMaxData.MIN_SENTINEL * 0.5:
							# 全 sentinel → parent 应哨兵
							if got_min < GpuMinMaxData.MIN_SENTINEL * 0.5:
								fails += 1
						else:
							var em: float = abs(got_min - ref_min)
							var ex: float = abs(got_max - ref_max)
							if em > TOL or ex > TOL:
								fails += 1
							max_err = max(max_err, max(em, ex))
						if probes >= PYRAMID_PROBES:
							break
					i += stride
				if probes >= PYRAMID_PROBES:
					break
				j += stride
			if probes >= PYRAMID_PROBES:
				break
	report.append("  (B) probes=%d  fails=%d  max_err=%.6f  %s" % [probes, fails, max_err, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 近似刻画: 离网格随机 (fi,u,v), 找到包含 (u,v) 的 mip0 cell, 比对 cell 的中心采样值 vs 真值。
# Cell 布局下 mip0 cell 只存中心点采样, 单点不能严格包夹 cell 内峰值 → 测偏差幅度。
# 这个测试现在更悲观(因为 cell 单点 vs vertex-grid 4 角点 min/max); 但仍能指导 BAKE_RES 选型。
static func _characterize_approximation(data: GpuMinMaxData, terrain: Terrain, params: PlanetParams, bake_res: int, report: PackedStringArray) -> float:
	var pyr: Array = data.build_pyramid()
	var seedv: int = 12345
	var oob: int = 0
	var max_excess: float = 0.0
	var sum_excess: float = 0.0
	var taken: int = 0
	while taken < OFFGRID_SAMPLES:
		seedv = (seedv * 1103515245 + 12345) & 0x7FFFFFFF
		var fi: int = seedv % GpuIco.FACE_COUNT
		seedv = (seedv * 1103515245 + 12345) & 0x7FFFFFFF
		var u: float = float(seedv % 980) / 1000.0
		seedv = (seedv * 1103515245 + 12345) & 0x7FFFFFFF
		var v: float = float(seedv % 980) / 1000.0
		if u + v > 0.97:
			continue
		taken += 1
		var dir: Vector3 = HeightmapBaker.dir_from_bary(fi, u, v)
		var disp: float = terrain.height_at(dir.x, dir.y, dir.z) * params.maxHeight
		# 包含 (u, v) 的 mip0 cell
		var i: int = clampi(int(floor(u * bake_res)), 0, bake_res - 1)
		var j: int = clampi(int(floor(v * bake_res)), 0, bake_res - 1)
		var fmips: Array = pyr[fi]
		var m0: PackedFloat32Array = fmips[0]
		var src: int = (j * bake_res + i) * 2
		var cell_min: float = m0[src]
		var cell_max: float = m0[src + 1]
		if cell_min >= GpuMinMaxData.MIN_SENTINEL * 0.5:
			continue   # cell 无效(三角形外), 跳过
		# cell 单点采样: min == max == cell_center_height
		# offgrid 真值偏离 cell 中心采样的幅度 → 用 max(|disp - cell|) 统计
		var excess: float = max(abs(cell_min - disp), abs(cell_max - disp))
		# 视为 "oob" 当 excess > TOL(任何 nonzero 偏差; cell 布局下这是常态)
		if excess > TOL:
			oob += 1
		max_excess = max(max_excess, excess)
		sum_excess += excess
	var pct: float = float(oob) / float(taken) * 100.0
	var mean_excess: float = (sum_excess / float(taken)) / params.maxHeight
	report.append("  (C) oob=%d/%d (%.1f%%)  max_excess=%.5f  mean_excess/maxH=%.5f" % [oob, taken, pct, max_excess, mean_excess])
	report.append("      (cell 单点采样: oob 表示 offgrid 真值 != cell 中心采样; mean_excess 越小越紧)")
	return pct
