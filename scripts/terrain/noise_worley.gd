## 3D Worley(细胞)噪声: 移植 src/terrain.js 的 hash3 + worley。
## 用于板块边界带(F2-F1 在细胞边界→0, 起脊)。返回最近/次近特征点距离 (f1, f2)。
## GDScript int 是 64 位, 这里不追求与 JS bit-exact, hash 质量足够即可。
class_name NoiseWorley
extends RefCounted


static func hash3(i: int, j: int, k: int, p_seed: int) -> Vector3:
	var h: int = (i * 374761393) ^ (j * 668265263) ^ (k * 40503) ^ (p_seed * 971)
	h = (h ^ (h >> 13)) * 1274126177
	h ^= h >> 16
	var rx: float = (h & 0xFFFFFF) / 16777216.0
	h = (h ^ 0x9e3779b9) * 2246822519
	h ^= h >> 15
	var ry: float = (h & 0xFFFFFF) / 16777216.0
	h = (h ^ 0x85ebca6b) * 3266489917
	h ^= h >> 13
	var rz: float = (h & 0xFFFFFF) / 16777216.0
	return Vector3(rx, ry, rz)


## 返回 Vector2(f1, f2): 最近/次近特征点距离
static func worley(x: float, y: float, z: float, freq: float, p_seed: int) -> Vector2:
	var px: float = x * freq
	var py: float = y * freq
	var pz: float = z * freq
	var ix: int = floori(px)
	var iy: int = floori(py)
	var iz: int = floori(pz)
	var f1: float = 1e9
	var f2: float = 1e9
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var cx: int = ix + dx
				var cy: int = iy + dy
				var cz: int = iz + dz
				var r := hash3(cx, cy, cz, p_seed)
				var fx: float = cx + r.x - px
				var fy: float = cy + r.y - py
				var fz: float = cz + r.z - pz
				var d: float = sqrt(fx * fx + fy * fy + fz * fz)
				if d < f1:
					f2 = f1
					f1 = d
				elif d < f2:
					f2 = d
	return Vector2(f1, f2)
