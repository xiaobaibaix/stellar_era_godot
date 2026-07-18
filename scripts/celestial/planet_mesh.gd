## PlanetMesh: 真实星球外观示例(贴图球)。
## 继承 CelestialMesh, override build() 换材质; 几何复用基类 _make_sphere。
## 用法: 在 Celestial 的 mesh_strategy 槽挂一个 PlanetMesh 资源(.tres)并设 albedo_texture。
class_name PlanetMesh
extends CelestialMesh

@export var albedo_texture: Texture2D
@export var roughness: float = 1.0
@export var metallic: float = 0.0


func build(c: Celestial) -> Node3D:
	var mi := _make_sphere(c)
	var mat := StandardMaterial3D.new()
	if albedo_texture != null:
		mat.albedo_texture = albedo_texture
	else:
		mat.albedo_color = c.color      # 没贴图 → 退回纯色
	mat.roughness = roughness
	mat.metallic = metallic
	mi.material_override = mat
	return mi
