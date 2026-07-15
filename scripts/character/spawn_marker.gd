# gdlint: disable=variable-name, max-line-length
## 出生点标记: 进入角色模式前, 鼠标在地表点击放置的箭头(可重复点击覆盖)。
## 外形 = 圆柱杆 + 圆锥头, 沿径向法线(+Y)竖在位移后的地表上; 无光照 + 自发光 → 昼夜都可见。
## 由 main.gd 在标记模式下实例化 + place() 定位; main.gd 每帧按相机距离 scale 保持屏幕大小稳定。
class_name SpawnMarker
extends Node3D

@export var color: Color = Color(1.0, 0.55, 0.0)   # 亮橙
@export var height: float = 30.0                   # 箭头总高(世界单位, 在缩放前)


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # 不受光照 → 夜侧也亮
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED              # 双面, 轨道斜看也不缺面

	var shaft_h: float = height * 0.7
	var head_h: float = height * 0.3

	# 杆: 底部贴地表(y=0), 向上
	var shaft_mi := MeshInstance3D.new()
	var shaft := CylinderMesh.new()
	shaft.top_radius = height * 0.05
	shaft.bottom_radius = height * 0.05
	shaft.height = shaft_h
	shaft_mi.mesh = shaft
	shaft_mi.material_override = mat
	shaft_mi.position = Vector3(0.0, shaft_h * 0.5, 0.0)
	add_child(shaft_mi)

	# 头: 杆顶之上(Godot 无 ConeMesh → CylinderMesh top_radius=0 即圆锥, 尖朝上)
	var head_mi := MeshInstance3D.new()
	var head := CylinderMesh.new()
	head.top_radius = 0.0
	head.bottom_radius = height * 0.17
	head.height = head_h
	head_mi.mesh = head
	head_mi.material_override = mat
	head_mi.position = Vector3(0.0, shaft_h + head_h * 0.5, 0.0)
	add_child(head_mi)

	visible = false


## surface_world: 位移后地表点(世界); up: 该点径向法线(单位)。把 +Y 对齐 up、底部落在地表。
func place(surface_world: Vector3, up: Vector3) -> void:
	var helper := Vector3(0.0, 0.0, 1.0)
	if absf(up.dot(helper)) > 0.99:
		helper = Vector3(1.0, 0.0, 0.0)
	var x := up.cross(helper).normalized()
	var z := x.cross(up).normalized()
	var b := Basis(x, up, z).orthonormalized()
	global_transform = Transform3D(b, surface_world)
	visible = true
