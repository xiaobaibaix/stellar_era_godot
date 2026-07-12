## 天体(N 体引力内核用)。移植 webs/solar_system/nbody.js 的 Body。
## 位置/速度/加速度用【double 标量】(GDScript 的 float 即 64 位 double), 不用 Vector3(32 位)——
## 太阳系尺度坐标(1e9+)若用 32 位会抖动丢精度。渲染时再减浮动原点、转 Vector3 交给 Node3D。
class_name Body
extends RefCounted

var name: String = ""
var mass: float = 1.0
var radius: float = 1.0
var color: Color = Color.WHITE
var type: String = "planet"            # "star" | "planet" | "moon" | "asteroid"
var primary: Body = null               # 主星(画轨道椭圆用)

# double 精度运动学量(标量; 不并成 Vector3 以保 64 位)
var px: float = 0.0; var py: float = 0.0; var pz: float = 0.0   # position
var vx: float = 0.0; var vy: float = 0.0; var vz: float = 0.0   # velocity
var ax: float = 0.0; var ay: float = 0.0; var az: float = 0.0   # acceleration
var _ox: float = 0.0; var _oy: float = 0.0; var _oz: float = 0.0  # accOld(Verlet 用)


func _init(p_name: String = "", p_mass: float = 1.0) -> void:
	name = p_name
	mass = p_mass


# double 标量设位/设速(链式)。高精度值(如 dist=1e9)必须走这里, 不要经 Vector3。
func set_pos(x: float, y: float, z: float) -> Body:
	px = x; py = y; pz = z
	return self


func set_vel(x: float, y: float, z: float) -> Body:
	vx = x; vy = y; vz = z
	return self


# 相对速度大小(调试/能量计算用)
func speed_squared() -> float:
	return vx * vx + vy * vy + vz * vz


## 渲染用: 返回相对 origin 的 32 位 Vector3(给 Node3D.transform.origin)。
## origin 为浮动原点(通常是聚焦体位置, double); 相减后转 32 位, 数值小、不抖。
func pos_relative(ox: float, oy: float, oz: float) -> Vector3:
	return Vector3(px - ox, py - oy, pz - oz)
