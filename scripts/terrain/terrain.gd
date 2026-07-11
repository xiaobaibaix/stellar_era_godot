## 地形高度场 + 生物群系配色(移植 src/terrain.js)。
## 单值径向高度场 → 碰撞/缝合/无限细节全部保持。
## Simplex 用 Godot 内置 FastNoiseLite(C++ 实现), Worley 用 NoiseWorley。
## 一个"代"内参数快照为局部常量, 保证主线程与 worker 结果一致。
class_name Terrain
extends RefCounted

# 参数快照
var sea: float = 0.0
var warp: float = 0.0
var wf: float = 1.0
var plate: float = 0.0
var pf: float = 1.6
var plate_seed: int = 555
var use_climate: bool = true
var alt_range: float = 1.0
var mtn_strength: float = 0.6
var mo_freq: float = 1.2

# 噪声(大陆/山脉/域扭曲/湿度/板块)
var noise_c: FastNoiseLite
var noise_m: FastNoiseLite
var noise_w: FastNoiseLite
var noise_h: FastNoiseLite
# 板块边界带: FastNoiseLite cellular(F2-F1, C++ 实现替代自写 Worley —— 后者是 height_at 头号 GDScript 热点)
var noise_plate: FastNoiseLite

# 调色板(对应 terrain.js 默认值)
const COL_OCEAN_SHALLOW := Color(0.20, 0.45, 0.62)
const COL_OCEAN_DEEP := Color(0.03, 0.12, 0.30)
const COL_BEACH := Color(0.82, 0.78, 0.55)
const COL_DRY := Color(0.78, 0.70, 0.42)
const COL_WET := Color(0.13, 0.45, 0.15)
const COL_COLD_DRY := Color(0.55, 0.53, 0.45)
const COL_COLD_WET := Color(0.22, 0.38, 0.32)
const COL_ROCK := Color(0.50, 0.50, 0.52)
const COL_SNOW := Color(0.97, 0.97, 1.0)


static func _mk_noise(seedv: int, freq: float, octaves: int, gain: float, lac: float, fractal: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.seed = seedv
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.fractal_gain = gain
	n.fractal_lacunarity = lac
	return n


static func _mk_simplex(seedv: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.seed = seedv
	n.frequency = freq
	return n


static func _mk_cellular(seedv: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.seed = seedv
	n.frequency = freq
	# cellular_distance 用默认(EUCLIDEAN); return_type=4 即 DISTANCE2_SUB → F2-F1(细胞边界处→0 起脊)。
	# 用整数值而非枚举常量名, 避免不同 Godot 版本枚举名差异导致脚本解析失败(曾因此让整个 Terrain 类编译不过)。
	n.cellular_return_type = 4
	return n


## 从 PlanetParams 构造(主线程用)
static func from_params(p: PlanetParams) -> Terrain:
	var t := Terrain.new()
	t.sea = p.seaLevel
	t.warp = p.warpStrength
	t.wf = p.warpFreq
	t.plate = p.plateStrength
	t.pf = p.plateFreq
	t.plate_seed = p.plateSeed
	t.use_climate = p.useClimate
	t.alt_range = p.climateAltRange
	t.mtn_strength = p.mountainStrength
	t.mo_freq = p.moistureFreq
	t.noise_c = _mk_noise(p.continentSeed, p.continentFreq, p.continentOctaves, p.continentGain, p.continentLacunarity, FastNoiseLite.FRACTAL_FBM)
	t.noise_m = _mk_noise(p.mountainSeed, p.mountainFreq, p.mountainOctaves, 0.5, 2.0, FastNoiseLite.FRACTAL_RIDGED)
	t.noise_w = _mk_simplex(p.warpSeed, p.warpFreq)
	t.noise_h = _mk_simplex(p.moistureSeed, p.moistureFreq)
	t.noise_plate = _mk_cellular(p.plateSeed, p.plateFreq)
	return t


## 从参数快照字典构造(worker 线程用, 避免跨线程读 Resource)
static func from_dict(d: Dictionary) -> Terrain:
	var t := Terrain.new()
	t.sea = d.seaLevel
	t.warp = d.warpStrength
	t.wf = d.warpFreq
	t.plate = d.plateStrength
	t.pf = d.plateFreq
	t.plate_seed = d.plateSeed
	t.use_climate = d.useClimate
	t.alt_range = d.climateAltRange
	t.mtn_strength = d.mountainStrength
	t.mo_freq = d.moistureFreq
	t.noise_c = _mk_noise(d.continentSeed, d.continentFreq, d.continentOctaves, d.continentGain, d.continentLacunarity, FastNoiseLite.FRACTAL_FBM)
	t.noise_m = _mk_noise(d.mountainSeed, d.mountainFreq, d.mountainOctaves, 0.5, 2.0, FastNoiseLite.FRACTAL_RIDGED)
	t.noise_w = _mk_simplex(d.warpSeed, d.warpFreq)
	t.noise_h = _mk_simplex(d.moistureSeed, d.moistureFreq)
	t.noise_plate = _mk_cellular(d.plateSeed, d.plateFreq)
	return t


func height_at(x: float, y: float, z: float) -> float:
	# 域扭曲: 一层噪声扰动采样坐标
	var wx: float = x
	var wy: float = y
	var wz: float = z
	if warp > 0.0:
		var q0: float = noise_w.get_noise_3d(x * wf, y * wf, z * wf)
		var q1: float = noise_w.get_noise_3d(x * wf + 31.4, y * wf + 12.7, z * wf + 5.2)
		var q2: float = noise_w.get_noise_3d(x * wf + 7.7, y * wf + 41.3, z * wf + 19.1)
		wx = x + warp * q0
		wy = y + warp * q1
		wz = z + warp * q2
	# 大陆(低频 fBm) → 掩膜(海里不叠山)
	var cont: float = noise_c.get_noise_3d(wx, wy, wz)
	var land: float = smoothstep(-0.06, 0.10, cont)
	# 山脉(ridged): ridged 噪声映射到 [0,1]
	var mr: float = noise_m.get_noise_3d(wx, wy, wz)
	var mtn: float = clampf(1.0 - abs(mr), 0.0, 1.0)
	# 板块边界带: cellular F2-F1(边界处→0, 内部→大); 1-(F2-F1) 在边界→1 起脊
	var belt: float = 0.0
	if plate > 0.0:
		var f2_f1: float = noise_plate.get_noise_3d(wx, wy, wz)
		belt = pow(1.0 - clampf(f2_f1, 0.0, 1.0), 6.0)
	var mountains: float = (mtn + belt * plate) * land
	return cont + mountains * mtn_strength


func color_for(h: float, x: float, y: float, z: float) -> Color:
	# 海洋: 深浅水渐变
	if h < sea:
		var d: float = clampf((sea - h) / 0.3, 0.0, 1.0)
		return COL_OCEAN_SHALLOW.lerp(COL_OCEAN_DEEP, d)
	if not use_climate:
		var t: float = clampf(h, 0.0, 1.0)
		if t < 0.05:
			return COL_BEACH
		if t < 0.4:
			return COL_WET
		if t < 0.7:
			return COL_ROCK
		return COL_SNOW
	# 海岸沙滩
	if h - sea < 0.02:
		return COL_BEACH
	# 气候: 温度(海拔+纬度) × 湿度 → 生物群系
	var alt: float = clampf((h - sea) / alt_range, 0.0, 1.0)
	var lat: float = abs(y)  # 纬度 0..1
	var temp: float = clampf((1.0 - alt) * (1.0 - lat), 0.0, 1.0)
	var moist: float = noise_h.get_noise_3d(x * mo_freq, y * mo_freq, z * mo_freq) * 0.5 + 0.5
	moist = clampf(moist * (1.0 - alt * 0.4), 0.0, 1.0)
	# 高海拔 / 极寒 → 岩石到雪
	if alt > 0.72 or temp < 0.12:
		var s: float = clampf((max(alt, 1.0 - temp) - 0.6) / 0.4, 0.0, 1.0)
		return COL_ROCK.lerp(COL_SNOW, s)
	var cold := COL_COLD_DRY.lerp(COL_COLD_WET, moist)
	var warm := COL_DRY.lerp(COL_WET, moist)
	return cold.lerp(warm, temp)


static func smoothstep(a: float, b: float, x: float) -> float:
	var t: float = clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
