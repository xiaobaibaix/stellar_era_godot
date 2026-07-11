## 行星参数资源(对应 web 版 params 对象 / presets/default.json)。
## 全部用 @export, 直接在 Godot 编辑器 Inspector 调节(分组 + 范围滑块 + 撤销重做)。
## 运行时改属性也会触发 setter -> param_changed(key) 信号, 应用层据此实时响应。
##
## 持久化: 保存场景即持久化(资源内嵌或存 .tres); 也可 save_as_tres() 导出预设。
class_name PlanetParams
extends Resource

signal param_changed(key: String)
signal bulk_changed

# ---- 几何 ----
@export_group("几何")
@export_range(10.0, 2000.0, 1.0) var radius: float = 100.0:
	set(v): radius = v; param_changed.emit("radius")
@export_range(0.0, 50.0, 0.1) var maxHeight: float = 8.0:
	set(v): maxHeight = v; param_changed.emit("maxHeight")
@export_range(-0.5, 0.5, 0.01) var seaLevel: float = 0.0:
	set(v): seaLevel = v; param_changed.emit("seaLevel")

# ---- 外观 ----
@export_group("外观")
@export var wireframe: bool = false:
	set(v): wireframe = v; param_changed.emit("wireframe")
@export var showInset: bool = true:
	set(v): showInset = v; param_changed.emit("showInset")
@export var showOcean: bool = true:
	set(v): showOcean = v; param_changed.emit("showOcean")
@export var showAtmosphere: bool = true:
	set(v): showAtmosphere = v; param_changed.emit("showAtmosphere")
@export var showClouds: bool = true:
	set(v): showClouds = v; param_changed.emit("showClouds")
@export var showGodrays: bool = true:
	set(v): showGodrays = v; param_changed.emit("showGodrays")

# ---- 相机与角色 ----
@export_group("相机与角色")
@export_range(5.0, 400.0, 1.0) var spectatorSpeed: float = 80.0:
	set(v): spectatorSpeed = v; param_changed.emit("spectatorSpeed")
@export_range(1.0, 200.0, 1.0) var walkSpeed: float = 25.0:
	set(v): walkSpeed = v; param_changed.emit("walkSpeed")
@export var invertY: bool = true:
	set(v): invertY = v; param_changed.emit("invertY")

# ---- 太阳 ----
@export_group("太阳")
@export_range(-90.0, 90.0, 0.5) var sunElevation: float = 35.0:
	set(v): sunElevation = v; param_changed.emit("sunElevation")
@export_range(0.0, 360.0, 0.5) var sunAzimuth: float = 40.0:
	set(v): sunAzimuth = v; param_changed.emit("sunAzimuth")
@export var autoSun: bool = false:
	set(v): autoSun = v; param_changed.emit("autoSun")
@export_range(0.0, 60.0, 0.1) var sunSpeed: float = 6.0:
	set(v): sunSpeed = v; param_changed.emit("sunSpeed")

# ---- 大气散射 ----
@export_group("大气散射")
@export_range(1.0, 1.5, 0.001) var atmoScale: float = 1.08:
	set(v): atmoScale = v; param_changed.emit("atmoScale")
@export_range(0.0, 0.5, 0.001) var atmoRayleigh: float = 0.08:
	set(v): atmoRayleigh = v; param_changed.emit("atmoRayleigh")
@export_range(0.0, 0.3, 0.001) var atmoMie: float = 0.03:
	set(v): atmoMie = v; param_changed.emit("atmoMie")
@export_range(0.0, 0.99, 0.01) var atmoMieG: float = 0.76:
	set(v): atmoMieG = v; param_changed.emit("atmoMieG")
@export_range(1.0, 16.0, 0.1) var atmoDensityFalloff: float = 6.0:
	set(v): atmoDensityFalloff = v; param_changed.emit("atmoDensityFalloff")
@export_range(1.0, 32.0, 0.1) var atmoMieFalloff: float = 16.0:
	set(v): atmoMieFalloff = v; param_changed.emit("atmoMieFalloff")
@export_range(0.0, 80.0, 0.1) var atmoSunIntensity: float = 22.0:
	set(v): atmoSunIntensity = v; param_changed.emit("atmoSunIntensity")
@export_range(0.0, 4.0, 0.01) var atmoExposure: float = 1.0:
	set(v): atmoExposure = v; param_changed.emit("atmoExposure")
@export_range(4, 64, 1) var atmoSteps: int = 24:
	set(v): atmoSteps = v; param_changed.emit("atmoSteps")
@export_range(2, 32, 1) var atmoLightSteps: int = 8:
	set(v): atmoLightSteps = v; param_changed.emit("atmoLightSteps")
@export_range(0.0, 1.0, 0.01) var atmoShadowSoftness: float = 0.6:
	set(v): atmoShadowSoftness = v; param_changed.emit("atmoShadowSoftness")
@export_range(0.0, 1.0, 0.01) var atmoTwilight: float = 0.3:
	set(v): atmoTwilight = v; param_changed.emit("atmoTwilight")
@export var atmoACES: bool = true:
	set(v): atmoACES = v; param_changed.emit("atmoACES")
@export_range(0.0, 0.3, 0.001) var atmoOzone: float = 0.02:
	set(v): atmoOzone = v; param_changed.emit("atmoOzone")
@export_range(0.0, 1.0, 0.01) var atmoDither: float = 0.5:
	set(v): atmoDither = v; param_changed.emit("atmoDither")
@export var atmoLUT: bool = true:
	set(v): atmoLUT = v; param_changed.emit("atmoLUT")

# ---- 体积云 ----
@export_group("体积云")
@export_range(1.0, 1.1, 0.001) var cloudBottom: float = 1.01:
	set(v): cloudBottom = v; param_changed.emit("cloudBottom")
@export_range(1.01, 1.3, 0.001) var cloudTop: float = 1.06:
	set(v): cloudTop = v; param_changed.emit("cloudTop")
@export_range(0.0, 1.0, 0.01) var cloudCoverage: float = 0.5:
	set(v): cloudCoverage = v; param_changed.emit("cloudCoverage")
@export_range(0.0, 4.0, 0.01) var cloudDensity: float = 1.2:
	set(v): cloudDensity = v; param_changed.emit("cloudDensity")
@export_range(0.0, 0.5, 0.001) var cloudFreq: float = 0.06:
	set(v): cloudFreq = v; param_changed.emit("cloudFreq")
@export_range(0.0, 2.0, 0.01) var cloudWarp: float = 0.5:
	set(v): cloudWarp = v; param_changed.emit("cloudWarp")
@export_range(0.0, 5.0, 0.01) var cloudWindSpeed: float = 0.6:
	set(v): cloudWindSpeed = v; param_changed.emit("cloudWindSpeed")
@export_range(4, 96, 1) var cloudSteps: int = 24:
	set(v): cloudSteps = v; param_changed.emit("cloudSteps")
@export_range(2, 16, 1) var cloudLightSteps: int = 6:
	set(v): cloudLightSteps = v; param_changed.emit("cloudLightSteps")
@export_range(0.0, 4.0, 0.01) var cloudAbsorb: float = 1.0:
	set(v): cloudAbsorb = v; param_changed.emit("cloudAbsorb")
@export_range(0.0, 4.0, 0.01) var cloudSilver: float = 1.0:
	set(v): cloudSilver = v; param_changed.emit("cloudSilver")
@export_range(0.0, 2.0, 0.01) var cloudPowder: float = 0.6:
	set(v): cloudPowder = v; param_changed.emit("cloudPowder")
@export_range(0.0, 1.0, 0.01) var cloudShadow: float = 0.7:
	set(v): cloudShadow = v; param_changed.emit("cloudShadow")

# ---- 体积光 ----
@export_group("体积光")
@export_range(0.0, 2.0, 0.01) var godrayStrength: float = 0.6:
	set(v): godrayStrength = v; param_changed.emit("godrayStrength")
@export_range(0.0, 2.0, 0.01) var godrayDensity: float = 0.7:
	set(v): godrayDensity = v; param_changed.emit("godrayDensity")
@export_range(8, 128, 1) var godraySamples: int = 48:
	set(v): godraySamples = v; param_changed.emit("godraySamples")
@export_range(0.0, 1.0, 0.01) var godrayThreshold: float = 0.45:
	set(v): godrayThreshold = v; param_changed.emit("godrayThreshold")

# ---- LOD ----
@export_group("LOD")
@export_range(1, 12, 1) var maxLevel: int = 8:
	set(v): maxLevel = v; param_changed.emit("maxLevel")
@export_range(1.0, 6.0, 0.05) var splitFactor: float = 2.5:
	set(v): splitFactor = v; param_changed.emit("splitFactor")
@export_range(4, 64, 1) var patchResolution: int = 16:
	set(v): patchResolution = v; param_changed.emit("patchResolution")  # 必须 2 的幂
@export_range(0.0, 1.0, 0.01) var frustumMargin: float = 0.15:
	set(v): frustumMargin = v; param_changed.emit("frustumMargin")
@export_range(1.0, 500.0, 1.0) var nearRadius: float = 50.0:
	set(v): nearRadius = v; param_changed.emit("nearRadius")

# ---- 大陆噪声 fBm ----
@export_group("大陆噪声")
@export_range(0, 999999, 1) var continentSeed: int = 1337:
	set(v): continentSeed = v; param_changed.emit("continentSeed")
@export_range(0.01, 8.0, 0.01) var continentFreq: float = 1.2:
	set(v): continentFreq = v; param_changed.emit("continentFreq")
@export_range(1, 8, 1) var continentOctaves: int = 5:
	set(v): continentOctaves = v; param_changed.emit("continentOctaves")
@export_range(0.0, 1.0, 0.01) var continentGain: float = 0.5:
	set(v): continentGain = v; param_changed.emit("continentGain")
@export_range(1.0, 4.0, 0.01) var continentLacunarity: float = 2.0:
	set(v): continentLacunarity = v; param_changed.emit("continentLacunarity")

# ---- 山脉 Ridged ----
@export_group("山脉")
@export_range(0, 999999, 1) var mountainSeed: int = 9001:
	set(v): mountainSeed = v; param_changed.emit("mountainSeed")
@export_range(0.01, 8.0, 0.01) var mountainFreq: float = 3.0:
	set(v): mountainFreq = v; param_changed.emit("mountainFreq")
@export_range(1, 8, 1) var mountainOctaves: int = 5:
	set(v): mountainOctaves = v; param_changed.emit("mountainOctaves")
@export_range(0.0, 2.0, 0.01) var mountainStrength: float = 0.6:
	set(v): mountainStrength = v; param_changed.emit("mountainStrength")

# ---- 结构增强 ----
@export_group("结构增强")
@export_range(0, 999999, 1) var warpSeed: int = 777:
	set(v): warpSeed = v; param_changed.emit("warpSeed")
@export_range(0.0, 1.0, 0.01) var warpStrength: float = 0.2:
	set(v): warpStrength = v; param_changed.emit("warpStrength")
@export_range(0.01, 8.0, 0.01) var warpFreq: float = 1.0:
	set(v): warpFreq = v; param_changed.emit("warpFreq")
@export_range(0, 999999, 1) var plateSeed: int = 555:
	set(v): plateSeed = v; param_changed.emit("plateSeed")
@export_range(0.01, 8.0, 0.01) var plateFreq: float = 1.6:
	set(v): plateFreq = v; param_changed.emit("plateFreq")
@export_range(0.0, 2.0, 0.01) var plateStrength: float = 0.5:
	set(v): plateStrength = v; param_changed.emit("plateStrength")
@export_range(0, 999999, 1) var moistureSeed: int = 333:
	set(v): moistureSeed = v; param_changed.emit("moistureSeed")
@export_range(0.01, 8.0, 0.01) var moistureFreq: float = 1.2:
	set(v): moistureFreq = v; param_changed.emit("moistureFreq")
@export var useClimate: bool = true:
	set(v): useClimate = v; param_changed.emit("useClimate")
@export_range(0.01, 2.0, 0.01) var climateAltRange: float = 1.0:
	set(v): climateAltRange = v; param_changed.emit("climateAltRange")


## 批量通知(载入预设/重置后调用)
func emit_bulk_changed() -> void:
	bulk_changed.emit()


## 导出为 .tres 预设文件(对应 web 版 "存到项目 presets/")
func save_as_tres(path: String) -> Error:
	return ResourceSaver.save(self, path)


## 这些 key 的变更需要重建地形网格(而非实时更新)
const REBUILD_KEYS := [
	"radius", "maxHeight", "seaLevel", "patchResolution",
	"continentSeed", "continentFreq", "continentOctaves", "continentGain", "continentLacunarity",
	"mountainSeed", "mountainFreq", "mountainOctaves", "mountainStrength",
	"warpSeed", "warpStrength", "warpFreq",
	"plateSeed", "plateFreq", "plateStrength",
	"moistureSeed", "moistureFreq", "useClimate", "climateAltRange",
]


func requires_rebuild(key: String) -> bool:
	return key in REBUILD_KEYS
