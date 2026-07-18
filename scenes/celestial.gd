## 天体节点(第1步:简单球体, 不用 Planet)。
## - 持有物理 Body(由所属 CelestialSystem 在 _ready 时分配); 自身不跑物理。
## - global_position 每帧由系统写入 = 世界 double − 全局浮动原点。
## - 编辑器里的 local position 仅用于系统初始化时读取【到主导体的距离】。
class_name Celestial
extends Node3D

@export var mass: float = 1.0
@export var radius: float = 200.0                 # 视觉半径 = 球体半径
@export var type: String = "planet"               # "star" | "planet" | "moon"
@export var color: Color = Color(0.6, 0.7, 1.0)
@export var is_dominant: bool = false             # 本系统主导体(恒星 / 行星)

var body: Body = null                             # 物理对象(系统分配)
var owner_system: Node = null                     # 所属 CelestialSystem

# 世界 double 位置缓存(系统每帧写; 顶层据此设浮动原点)
var _wx: float = 0.0
var _wy: float = 0.0
var _wz: float = 0.0


func _ready() -> void:
	_build_visual()


func _build_visual() -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Sphere"
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if type == "star":
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.5
	mesh.material_override = mat
	add_child(mesh)
	if type == "star":
		var light := OmniLight3D.new()
		light.name = "StarLight"
		light.light_energy = 5.0
		light.light_color = color
		add_child(light)
