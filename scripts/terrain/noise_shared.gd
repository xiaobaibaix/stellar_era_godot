# gdlint: disable=variable-name
## GPU/CPU 共享整数哈希梯度噪声(Perlin)。Phase 1+ Step1。
##
## 必须与 shaders/terrain.gdshader(及 noise_test.gdshader) 里的噪声【逐位一致】——
## GPU 位移与 CPU 碰撞 height_at 共用同一高度场, 不一致就会穿地/悬空。
##
## GLSL 用 uint(自然 mod 2^32 回绕); GDScript int 是 64 位有符号 →
##   - 乘法用 _mul32 拆半字避免 int64 溢出(32×32=64 位结果 > 2^63);
##   - 每步 & MASK32 仿真 uint 回绕, 负数按二补码低 32 位(与 GLSL uint(int) mod 2^32 一致)。
class_name NoiseShared
extends RefCounted

const MASK32: int = 0xFFFFFFFF


# 32 位无符号乘法: a,b ∈ [0,2^32-1] → (a*b) mod 2^32。拆 b 成高低 16 位避免 int64 溢出。
static func mul32(a: int, b: int) -> int:
	var b_lo: int = b & 0xFFFF
	var b_hi: int = b >> 16
	var lo: int = a * b_lo                            # a<2^32, b_lo<2^16 → <2^48
	var hi: int = (a * b_hi) & 0xFFFF                 # 取低 16 位(高 16 位 ×2^16 才进低 32 位)
	return (lo + (hi << 16)) & MASK32


# 32 位整数哈希(输入 n ∈ [0,2^32-1])。对应 GLSL:
#   n = (n<<13) ^ n;  n = n*(n*n*15731 + 789221) + 1376312589;
static func hash_u32(n: int) -> int:
	n = n & MASK32
	n = (n ^ ((n << 13) & MASK32)) & MASK32
	var nn: int = mul32(n, n)
	var a: int = (mul32(nn, 15731) + 789221) & MASK32
	return (mul32(n, a) + 1376312589) & MASK32


# 3D 整数坐标 → uint32 哈希。ix/iy/iz 可为负(网格坐标); 低 32 位与 GLSL uint 路径一致。
static func hash3(ix: int, iy: int, iz: int) -> int:
	var n: int = (ix * 374761393) ^ (iy * 668265263) ^ (iz * 1274126177)
	return hash_u32(n & MASK32)


# Perlin 梯度表(12 个方向, 经典 Ken Perlin)。顺序/取值与 shader 内数组逐项一致。
const GRAD: Array = [
	Vector3(1.0, 1.0, 0.0), Vector3(-1.0, 1.0, 0.0), Vector3(1.0, -1.0, 0.0), Vector3(-1.0, -1.0, 0.0),
	Vector3(1.0, 0.0, 1.0), Vector3(-1.0, 0.0, 1.0), Vector3(1.0, 0.0, -1.0), Vector3(-1.0, 0.0, -1.0),
	Vector3(0.0, 1.0, 1.0), Vector3(0.0, -1.0, 1.0), Vector3(0.0, 1.0, -1.0), Vector3(0.0, -1.0, -1.0),
]


static func grad_dot(h: int, x: float, y: float, z: float) -> float:
	var g: Vector3 = GRAD[h % 12]
	return g.x * x + g.y * y + g.z * z


static func fade(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


# 3D Perlin 噪声, 输出 ≈ [-1,1]。x,y,z = 采样位置(通常 = 方向 d × freq)。
static func noise3(x: float, y: float, z: float) -> float:
	var ix: int = int(floor(x))
	var iy: int = int(floor(y))
	var iz: int = int(floor(z))
	var fx: float = x - float(ix)
	var fy: float = y - float(iy)
	var fz: float = z - float(iz)
	var u: float = fade(fx)
	var v: float = fade(fy)
	var w: float = fade(fz)
	# 8 角点梯度点积
	var c000: float = grad_dot(hash3(ix, iy, iz), fx, fy, fz)
	var c100: float = grad_dot(hash3(ix + 1, iy, iz), fx - 1.0, fy, fz)
	var c010: float = grad_dot(hash3(ix, iy + 1, iz), fx, fy - 1.0, fz)
	var c110: float = grad_dot(hash3(ix + 1, iy + 1, iz), fx - 1.0, fy - 1.0, fz)
	var c001: float = grad_dot(hash3(ix, iy, iz + 1), fx, fy, fz - 1.0)
	var c101: float = grad_dot(hash3(ix + 1, iy, iz + 1), fx - 1.0, fy, fz - 1.0)
	var c011: float = grad_dot(hash3(ix, iy + 1, iz + 1), fx, fy - 1.0, fz - 1.0)
	var c111: float = grad_dot(hash3(ix + 1, iy + 1, iz + 1), fx - 1.0, fy - 1.0, fz - 1.0)
	# 三线性插值(与 shader lerp 顺序一致)
	var x0: float = lerpf(c000, c100, u)
	var x1: float = lerpf(c010, c110, u)
	var x2: float = lerpf(c001, c101, u)
	var x3: float = lerpf(c011, c111, u)
	var y0: float = lerpf(x0, x1, v)
	var y1: float = lerpf(x2, x3, v)
	return lerpf(y0, y1, w)


# fbm(分形布朗)。种子用坐标偏移区分(同一噪声函数 + 不同采样原点, 与 shader 一致)。
static func fbm(x: float, y: float, z: float, octaves: int, gain: float, lacunarity: float) -> float:
	var s: float = 0.0
	var a: float = 0.5
	for _i in range(octaves):
		s += a * noise3(x, y, z)
		x *= lacunarity
		y *= lacunarity
		z *= lacunarity
		a *= gain
	return s   # 大致 [-1,1]


# ridged(山脊): 累加 (1-|noise|)²。输出 ≥ 0, 越大越尖锐。
static func ridged(x: float, y: float, z: float, octaves: int, gain: float, lacunarity: float) -> float:
	var s: float = 0.0
	var a: float = 0.5
	for _i in range(octaves):
		var n: float = 1.0 - abs(noise3(x, y, z))
		s += a * n * n
		x *= lacunarity
		y *= lacunarity
		z *= lacunarity
		a *= gain
	return s


# Worley/cellular F2-F1(板块边界带)。输入 = 采样位置(通常 = 方向 d × plateFreq + seed 偏移)。
# 整数哈希把每个 cell 映射到一个 [0,1)³ 随机点, 取最近(F1)/次近(F2)两点距离差。
# cell 边界处 F1≈F2 → F2-F1≈0; cell 中心 F1≈0 → F2-F1≈1。与 shader 逐位一致。
static func hash_to_point(h: int) -> Vector3:
	var rx: float = float(h & 0xFFFF) / 65535.0
	var ry: float = float((h >> 16) & 0xFFFF) / 65535.0
	var rz: float = float(hash_u32(h) & 0xFFFF) / 65535.0
	return Vector3(rx, ry, rz)


static func worley_f2f1(x: float, y: float, z: float) -> float:
	var cx: int = int(floor(x))
	var cy: int = int(floor(y))
	var cz: int = int(floor(z))
	var p := Vector3(x, y, z)
	var f1: float = 1.0e9
	var f2: float = 1.0e9
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var ccx: int = cx + dx
				var ccy: int = cy + dy
				var ccz: int = cz + dz
				var h3: int = hash3(ccx, ccy, ccz)
				var rp: Vector3 = Vector3(float(ccx), float(ccy), float(ccz)) + hash_to_point(h3)
				var d: float = rp.distance_to(p)
				if d < f1:
					f2 = f1
					f1 = d
				elif d < f2:
					f2 = d
	return f2 - f1
