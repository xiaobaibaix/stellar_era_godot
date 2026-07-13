## 地形高度场 + 生物群系配色(Phase 1+ : GPU/CPU 共享整数哈希噪声版)。
##
## height_at / color_for 与 shaders/terrain.gdshader 的 terrain_height / terrain_color
## 【逐位一致】(同 NoiseShared 噪声 + 同种子偏移式) —— GPU 视觉位移与 CPU 碰撞(planet_walker 贴地)
## 共用同一高度场, 不一致就会穿地/悬空。NoiseShared 已通过 Step1 自检(误差 ≤ 8bit 量化)。
##
## 单值径向高度场 → 碰撞/无限细节全部保持。接口不变, planet.gd / patch_builder / planet_walker 无感。
class_name Terrain
extends RefCounted

# 种子偏移式: 每个噪声 = vec3(seed)·(1,2,3); 与 shader uniform u_off_* 同式(planet.gd 推给 shader)。
static func off(seedv: int) -> Vector3:
	return Vector3(float(seedv), float(seedv) * 2.0, float(seedv) * 3.0)

# 参数快照(与 PlanetParams 对应)
var sea: float = 0.0
var warp: float = 0.2
var wf: float = 1.0
var cont_freq: float = 1.2
var cont_oct: int = 5
var cont_gain: float = 0.5
var cont_lac: float = 2.0
var mtn_freq: float = 3.0
var mtn_oct: int = 5
var mtn_strength: float = 0.6
var plate: float = 0.5
var pf: float = 1.6
var mo_freq: float = 1.2
var use_climate: bool = true
var alt_range: float = 1.0

# 种子偏移(由 *Seed 算出)
var off_warp: Vector3
var off_cont: Vector3
var off_mtn: Vector3
var off_plate: Vector3
var off_moist: Vector3

# 调色板(与 shader u_col_* 一致; 旧 FastNoiseLite 版的 COL_* 默认值)
const COL_OCEAN_SHALLOW := Color(0.20, 0.45, 0.62)
const COL_OCEAN_DEEP := Color(0.03, 0.12, 0.30)
const COL_BEACH := Color(0.82, 0.78, 0.55)
const COL_DRY := Color(0.78, 0.70, 0.42)
const COL_WET := Color(0.13, 0.45, 0.15)
const COL_COLD_DRY := Color(0.55, 0.53, 0.45)
const COL_COLD_WET := Color(0.22, 0.38, 0.32)
const COL_ROCK := Color(0.50, 0.50, 0.52)
const COL_SNOW := Color(0.97, 0.97, 1.0)


static func from_params(p: PlanetParams) -> Terrain:
	var t := Terrain.new()
	t.sea = p.seaLevel
	t.warp = p.warpStrength
	t.wf = p.warpFreq
	t.cont_freq = p.continentFreq
	t.cont_oct = p.continentOctaves
	t.cont_gain = p.continentGain
	t.cont_lac = p.continentLacunarity
	t.mtn_freq = p.mountainFreq
	t.mtn_oct = p.mountainOctaves
	t.mtn_strength = p.mountainStrength
	t.plate = p.plateStrength
	t.pf = p.plateFreq
	t.mo_freq = p.moistureFreq
	t.use_climate = p.useClimate
	t.alt_range = p.climateAltRange
	t.off_warp = off(p.warpSeed)
	t.off_cont = off(p.continentSeed)
	t.off_mtn = off(p.mountainSeed)
	t.off_plate = off(p.plateSeed)
	t.off_moist = off(p.moistureSeed)
	return t


static func from_dict(d: Dictionary) -> Terrain:
	var t := Terrain.new()
	t.sea = d.seaLevel
	t.warp = d.warpStrength
	t.wf = d.warpFreq
	t.cont_freq = d.continentFreq
	t.cont_oct = d.continentOctaves
	t.cont_gain = d.continentGain
	t.cont_lac = d.continentLacunarity
	t.mtn_freq = d.mountainFreq
	t.mtn_oct = d.mountainOctaves
	t.mtn_strength = d.mountainStrength
	t.plate = d.plateStrength
	t.pf = d.plateFreq
	t.mo_freq = d.moistureFreq
	t.use_climate = d.useClimate
	t.alt_range = d.climateAltRange
	t.off_warp = off(int(d.warpSeed))
	t.off_cont = off(int(d.continentSeed))
	t.off_mtn = off(int(d.mountainSeed))
	t.off_plate = off(int(d.plateSeed))
	t.off_moist = off(int(d.moistureSeed))
	return t


# 高度场(与 shaders/terrain.gdshader::terrain_height 逐位一致)。x,y,z = 单位方向 d。
func height_at(x: float, y: float, z: float) -> float:
	var d := Vector3(x, y, z)
	var pw := d
	if warp > 0.0:
		var wp := d * wf + off_warp
		var q0: float = NoiseShared.noise3(wp.x, wp.y, wp.z)
		var q1: float = NoiseShared.noise3(wp.x + 31.4, wp.y + 12.7, wp.z + 5.2)
		var q2: float = NoiseShared.noise3(wp.x + 7.7, wp.y + 41.3, wp.z + 19.1)
		pw = d + Vector3(q0, q1, q2) * warp
	var cp := pw * cont_freq + off_cont
	var cont: float = NoiseShared.fbm(cp.x, cp.y, cp.z, cont_oct, cont_gain, cont_lac)
	var land: float = smoothstep(-0.06, 0.10, cont)
	var mp := pw * mtn_freq + off_mtn
	var mtn: float = clampf(NoiseShared.ridged(mp.x, mp.y, mp.z, mtn_oct, 0.5, 2.0), 0.0, 1.0)
	var belt: float = 0.0
	if plate > 0.0:
		var pp := pw * pf + off_plate
		var f2_f1: float = NoiseShared.worley_f2f1(pp.x, pp.y, pp.z)
		belt = pow(1.0 - clampf(f2_f1, 0.0, 1.0), 6.0)
	var mountains: float = (mtn + belt * plate) * land
	return cont + mountains * mtn_strength


# 配色(与 shaders/terrain.gdshader::terrain_color 逐位一致)。h=高度, x,y,z=方向 d。
func color_for(h: float, x: float, y: float, z: float) -> Color:
	var d := Vector3(x, y, z)
	if h < sea:
		var depth: float = clampf((sea - h) / 0.3, 0.0, 1.0)
		return COL_OCEAN_SHALLOW.lerp(COL_OCEAN_DEEP, depth)
	if not use_climate:
		var t: float = clampf(h, 0.0, 1.0)
		if t < 0.05:
			return COL_BEACH
		if t < 0.4:
			return COL_WET
		if t < 0.7:
			return COL_ROCK
		return COL_SNOW
	if h - sea < 0.02:
		return COL_BEACH
	var alt: float = clampf((h - sea) / alt_range, 0.0, 1.0)
	var lat: float = absf(d.y)
	var temp: float = clampf((1.0 - alt) * (1.0 - lat), 0.0, 1.0)
	var ms := d * mo_freq + off_moist
	var moist: float = NoiseShared.noise3(ms.x, ms.y, ms.z) * 0.5 + 0.5
	moist = clampf(moist * (1.0 - alt * 0.4), 0.0, 1.0)
	if alt > 0.72 or temp < 0.12:
		var s: float = clampf((maxf(alt, 1.0 - temp) - 0.6) / 0.4, 0.0, 1.0)
		return COL_ROCK.lerp(COL_SNOW, s)
	var cold := COL_COLD_DRY.lerp(COL_COLD_WET, moist)
	var warm := COL_DRY.lerp(COL_WET, moist)
	return cold.lerp(warm, temp)


static func smoothstep(a: float, b: float, x: float) -> float:
	var t: float = clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
