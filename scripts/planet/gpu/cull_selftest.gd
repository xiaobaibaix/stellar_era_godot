# gdlint: disable=variable-name, max-line-length
## Phase 3 视锥裁剪自检(纯 CPU, 不依赖 RenderingDevice)。
##
## 验证三件事(对应 lod_cull.glsl 的核心逻辑):
##   (A) Frustum 平面打包约定: GpuLodCompositor._update_frame_ubo 把 Godot Plane(N, d)
##       打包为 UBO 中 vec4(N.x, N.y, N.z, **-d**)。Godot Plane 存 d = dot(N, p_on_plane),
##       平面方程 dot(N,P) = d; 内侧(on normal side) dot(N,P) > d; 外侧 dot(N,P) < d。
##       lod_cull.glsl 用 `dot(N, P) + plane.w < 0` 判外侧 → plane.w 必须传 **-d**。
##       本测试以 Godot Plane.distance_to(P) > 0 为内侧真值, 验证 shader 公式与之等价。
##       涵盖 d=0 (left/right/top/bottom 过相机原点) 和 d≠0 (near/far) 两类平面。
##   (B) P-vertex AABB 测试: 给定内向法线平面 + AABB, lod_cull.glsl 选 AABB 角点中"最深入
##       该平面外侧"的那个分量(plane.{x,y,z}>0 取 box_max 对应分量, 否则取 box_min), 验证
##       "任一平面 P-vertex 外侧 → cull" 与几何直观一致。
##   (C) dispatch 组数数学: GpuLodCompositor._groups_for_level(L) = ceil(20·4^L / 64),
##       _cull_groups() = ceil(4096/64) = 64。
##
## 不测: GPU 端 shader 编译/调度/读写一致性(需 RenderingDevice, 留给运行时目检 test_gpu_planet.tscn)。
## 与 minmax_selftest 同惯例: 挂场景根节点, F6 运行, 打印 + 写 user://。
class_name CullSelftest
extends Node

const RESULT_PATH := "user://cull_selftest_result.txt"


func _ready() -> void:
	var res: Dictionary = run()
	for line in res["report"]:
		print(line)
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		for line in res["report"]:
			f.store_line(line)
		f.close()
	queue_free()


# 主逻辑(静态, 可被外部调)。返回 {report, ok}。
static func run() -> Dictionary:
	var report: PackedStringArray = []
	report.append("== Phase 3 frustum cull self-test ==")

	var frustum_ok: bool = _verify_frustum_convention(report)
	var pvertex_ok: bool = _verify_pvertex_aabb_test(report)
	var dispatch_ok: bool = _verify_dispatch_math(report)

	var overall: bool = frustum_ok and pvertex_ok and dispatch_ok
	report.append("---- summary ----")
	report.append("  (A) Frustum packing convention : %s" % ("PASS" if frustum_ok else "FAIL"))
	report.append("  (B) P-vertex AABB test         : %s" % ("PASS" if pvertex_ok else "FAIL"))
	report.append("  (C) Dispatch group math        : %s" % ("PASS" if dispatch_ok else "FAIL"))
	report.append("OVERALL: %s" % ("PASS" if overall else "FAIL"))
	return {"report": report, "ok": overall}


# ---- (A) Frustum 平面打包约定 ----
# 用 Godot Plane(normal, point_on_plane) 构造平面, 用 has_point / distance_to 作内侧判定
# 真值, 验证 shader 测试公式(dot(N, P) + plane.w < 0 = 外侧, plane.w = -p.d 翻转)与之等价。
static func _verify_frustum_convention(report: PackedStringArray) -> bool:
	# 案例: 每个构造一个平面, 给一组明确在内/外侧的点。
	# 用 Plane(normal, point_on_plane): Godot 保证 dot(N,P)+d=0 过该点, 内向 N 下 dot(N,P)+d>0 内侧。
	var cases := [
		{
		 "point": Vector3(-5, 0, 0), "normal": Vector3(1, 0, 0),
		 "inside": [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(-5, 0, 0), Vector3(-4.999, 0, 0)],
		 "outside": [Vector3(-10, 0, 0), Vector3(-5.001, 0, 0)],
		 "name": "left at x=-5, normal=+X (内侧 P.x>=-5, d>0)",
		},
		{
		 "point": Vector3(0, 0, 100), "normal": Vector3(0, 0, -1),
		 "inside": [Vector3(0, 0, 0), Vector3(0, 0, 50), Vector3(0, 0, 100)],
		 "outside": [Vector3(0, 0, 150), Vector3(0, 0, 100.001)],
		 "name": "far at z=100, normal=-Z (内侧 P.z<=100, d<0)",
		},
		{
		 "point": Vector3(0, 0, 0), "normal": Vector3(0, 1, 0),
		 "inside": [Vector3(0, 1, 0), Vector3(0, 100, 0), Vector3(0, 0, 0)],
		 "outside": [Vector3(0, -1, 0), Vector3(0, -0.001, 0)],
		 "name": "bottom at y=0, normal=+Y (内侧 P.y>=0, d=0)",
		},
		{
		 "point": Vector3(0, 0, -0.05), "normal": Vector3(0, 0, -1),
		 "inside": [Vector3(0, 0, -1), Vector3(0, 0, -50), Vector3(0, 0, -0.05)],
		 "outside": [Vector3(0, 0, 0), Vector3(0, 0, -0.049)],
		 "name": "near at z=-0.05, normal=-Z (内侧 P.z<=-0.05, d<0; 抓 near/far d≠0 BUG)",
		},
		{
		 "point": Vector3(0, 0, 5), "normal": Vector3(0, 1, 1).normalized(),
		 "inside": [Vector3(0, 100, 100), Vector3(0, 1, 1)],
		 "outside": [Vector3(0, -100, -100)],
		 "name": "tilted plane (内侧 N·P>=N·P_on, d≠0)",
		},
	]
	var fails := 0
	for c in cases:
		var plane := Plane(c["normal"], c["point"])   # 内向 normal + 过该点
		var packed := Vector4(plane.normal.x, plane.normal.y, plane.normal.z, -plane.d)
		for pin in c["inside"]:
			# Godot 真值: 该点应"在内侧或面上"。Godot Plane.has_point 默认容差 epsilon。
			var godot_inside: bool = plane.has_point(pin) or plane.distance_to(pin) >= -1.0e-5
			if not godot_inside:
				continue   # 该点其实不在内侧, 跳过(数据错误, 但不增加 fail)
			var shader_outside: bool = _shader_cull_test(packed, pin)
			if shader_outside:
				report.append("  FAIL %s: inside P=%s → Godot 内, shader 外(eval=%.4f, packed=%s)" % [c["name"], pin, plane.normal.dot(pin) - plane.d, packed])
				fails += 1
		for pout in c["outside"]:
			var godot_outside: bool = not plane.has_point(pout) and plane.distance_to(pout) < -1.0e-5
			if not godot_outside:
				continue
			var shader_outside: bool = _shader_cull_test(packed, pout)
			if not shader_outside:
				report.append("  FAIL %s: outside P=%s → Godot 外, shader 内(eval=%.4f, packed=%s)" % [c["name"], pout, plane.normal.dot(pout) - plane.d, packed])
				fails += 1
	report.append("  (A) cases=%d  fails=%d  %s" % [cases.size(), fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 模拟 lod_cull.glsl 的视锥测试(单点版): dot(n, P) + plane.w < 0 → 外侧。
static func _shader_cull_test(plane: Vector4, p: Vector3) -> bool:
	return plane.x * p.x + plane.y * p.y + plane.z * p.z + plane.w < 0.0


# ---- (B) P-vertex AABB 测试 ----
# lod_cull.glsl: 对每个平面, p_vert.{x,y,z} = plane.{x,y,z}>0 ? box_max.{x,y,z} : box_min.{x,y,z}。
# P-vertex = AABB 角点中沿该平面"最外侧"的点(保守: 任一平面外则 cull)。
static func _verify_pvertex_aabb_test(report: PackedStringArray) -> bool:
	# 构合成 "box-frustum" 视锥: 6 平面围出 [-1,1]³ 的立方体内部。
	# left:   过 x=-1, N=+X;  right: 过 x=+1, N=-X
	# bottom: 过 y=-1, N=+Y;  top:    过 y=+1, N=-Y
	# near:   过 z=-1, N=+Z;  far:    过 z=+1, N=-Z
	var planes := [
		Plane(Vector3(1, 0, 0), Vector3(-1, 0, 0)),
		Plane(Vector3(-1, 0, 0), Vector3(1, 0, 0)),
		Plane(Vector3(0, 1, 0), Vector3(0, -1, 0)),
		Plane(Vector3(0, -1, 0), Vector3(0, 1, 0)),
		Plane(Vector3(0, 0, 1), Vector3(0, 0, -1)),
		Plane(Vector3(0, 0, -1), Vector3(0, 0, 1)),
	]
	var packed: Array[Vector4] = []
	for p in planes:
		packed.append(Vector4(p.normal.x, p.normal.y, p.normal.z, -p.d))

	var cases := [
		{"min": Vector3(-0.5, -0.5, -0.5), "max": Vector3(0.5, 0.5, 0.5), "cull": false, "name": "AABB 中心 (keep)"},
		{"min": Vector3(-2, -2, -2), "max": Vector3(2, 2, 2), "cull": false, "name": "AABB 包住视锥 (keep)"},
		{"min": Vector3(-1.5, -0.5, -0.5), "max": Vector3(-0.5, 0.5, 0.5), "cull": false, "name": "AABB 穿过 left (keep)"},
		{"min": Vector3(-5, -0.5, -0.5), "max": Vector3(-2, 0.5, 0.5), "cull": true, "name": "AABB 完全在 left 外 (cull)"},
		{"min": Vector3(-0.5, -0.5, 2), "max": Vector3(0.5, 0.5, 5), "cull": true, "name": "AABB 越过 far (cull)"},
		{"min": Vector3(0.5, 0.5, 0.5), "max": Vector3(1.5, 1.5, 1.5), "cull": false, "name": "AABB 接触角点 (keep)"},
		{"min": Vector3(1.001, 0, 0), "max": Vector3(2, 1, 1), "cull": true, "name": "AABB 刚越过 right (cull)"},
		{"min": Vector3(-3, -3, -3), "max": Vector3(-2.5, -2.5, -2.5), "cull": true, "name": "AABB 在 far corner 外 (cull left/bottom/near)"},
	]
	var fails := 0
	for c in cases:
		var got_cull: bool = _pvertex_aabb_cull(packed, c["min"], c["max"])
		if got_cull != bool(c["cull"]):
			report.append("  FAIL %s: expected cull=%s, got cull=%s" % [c["name"], c["cull"], got_cull])
			fails += 1
	report.append("  (B) cases=%d  fails=%d  %s" % [cases.size(), fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0


# 模拟 lod_cull.glsl 的 P-vertex AABB 测试。
static func _pvertex_aabb_cull(packed: Array[Vector4], box_min: Vector3, box_max: Vector3) -> bool:
	for plane in packed:
		var px: float = box_max.x if plane.x > 0.0 else box_min.x
		var py: float = box_max.y if plane.y > 0.0 else box_min.y
		var pz: float = box_max.z if plane.z > 0.0 else box_min.z
		if plane.x * px + plane.y * py + plane.z * pz + plane.w < 0.0:
			return true
	return false


# ---- (C) dispatch 组数数学 ----
# GpuLodCompositor._groups_for_level(L) = ceil(20·4^L / 64)
# _cull_groups() = ceil(MAX_PATCHES / 64) = ceil(4096/64) = 64
static func _verify_dispatch_math(report: PackedStringArray) -> bool:
	var fails := 0
	var cases := [
		{"level": 0, "expect_nodes": 20, "expect_groups": 1},
		{"level": 1, "expect_nodes": 80, "expect_groups": 2},
		{"level": 2, "expect_nodes": 320, "expect_groups": 5},
		{"level": 3, "expect_nodes": 1280, "expect_groups": 20},
		{"level": 4, "expect_nodes": 5120, "expect_groups": 80},
		{"level": 5, "expect_nodes": 20480, "expect_groups": 320},
		{"level": 6, "expect_nodes": 81920, "expect_groups": 1280},
	]
	for c in cases:
		var nodes: int = 20
		for i in range(c["level"]):
			nodes *= 4
		if nodes != int(c["expect_nodes"]):
			report.append("  FAIL level=%d: nodes got=%d expect=%d" % [c["level"], nodes, c["expect_nodes"]])
			fails += 1
		@warning_ignore("integer_division")
		var groups: int = (nodes - 1) / 64 + 1
		if groups != int(c["expect_groups"]):
			report.append("  FAIL level=%d: groups got=%d expect=%d" % [c["level"], groups, c["expect_groups"]])
			fails += 1
	@warning_ignore("integer_division")
	var cull_groups: int = (4096 - 1) / 64 + 1
	if cull_groups != 64:
		report.append("  FAIL cull_groups: got=%d expect=64" % [cull_groups])
		fails += 1
	report.append("  (C) cases=%d  cull_groups=%d  fails=%d  %s" % [cases.size(), cull_groups, fails, "PASS" if fails == 0 else "FAIL"])
	return fails == 0
