## 天体外观策略(策略模式): 把"怎么造 mesh / 材质 / 光"从 Celestial 解耦。
## Celestial 持有一个 CelestialMesh(@export mesh_strategy), _ready 时调 build(self)。
## - 留空 → 默认纯色球(与最初占位天体一致)。
## - 挂子类(PlanetMesh / 自定义) → 换成真实外观, Celestial 结构零改动。
##
## 扩展方式: override build()。可用 _make_sphere(c) 复用球几何, 再换材质 / 加细节节点。
class_name CelestialMesh
extends Resource


## 球几何(无材质)。子类复用半径, 避免重复造 SphereMesh。
func _make_sphere(c: Celestial) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Sphere"
	var sm := SphereMesh.new()
	sm.radius = c.radius
	sm.height = c.radius * 2.0
	mi.mesh = sm
	return mi


## 默认外观: 纯色球; 恒星额外自发光 + 近场点光(与最初占位行为完全一致)。
func build(c: Celestial) -> Node3D:
	var mi := _make_sphere(c)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c.color
	if c.type == "star":
		mat.emission_enabled = true
		mat.emission = c.color
		mat.emission_energy_multiplier = 2.5
	mi.material_override = mat
	if c.type == "star":
		var light := OmniLight3D.new()
		light.name = "StarLight"
		light.light_energy = 5.0
		light.light_color = c.color
		# 开阴影: 行星挡光 → 月亮进入本影锥变暗(月食)。两处 Star 处光源必须都开,
		# 否则未开阴影的那个会用无阴影照明把月食效果冲掉。
		light.shadow_enabled = true
		mi.add_child(light)
	return mi
