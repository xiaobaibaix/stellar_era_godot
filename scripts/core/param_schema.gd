## 参数 schema: 把 web 版 presets/default.json 的全部参数定义成
## { default, group, min, max, step, kind } 的集合, 供参数总线与 GUI 共用。
## kind: "slider"(浮点滑块) / "int"(整数) / "toggle"(布尔) / "seed"(可随机化整数)
class_name ParamSchema
extends RefCounted

# 分组顺序(对应 web lil-gui 文件夹布局)
const GROUPS := [
	"几何", "外观", "相机与角色", "太阳",
	"大气散射", "体积云", "体积光", "LOD",
	"大陆噪声", "山脉", "结构增强",
]

# name -> { default, group, min, max, step, kind }
const SCHEMA := {
	# ---- 几何 ----
	"radius":            {"default": 100.0, "group": "几何", "min": 10.0,  "max": 2000.0, "step": 1.0,   "kind": "slider"},
	"maxHeight":         {"default": 8.0,   "group": "几何", "min": 0.0,   "max": 50.0,   "step": 0.1,   "kind": "slider"},
	"seaLevel":          {"default": 0.0,   "group": "几何", "min": -0.5,  "max": 0.5,    "step": 0.01,  "kind": "slider"},

	# ---- 外观(开关) ----
	"wireframe":         {"default": false, "group": "外观", "kind": "toggle"},
	"showInset":         {"default": true,  "group": "外观", "kind": "toggle"},
	"showOcean":         {"default": true,  "group": "外观", "kind": "toggle"},
	"showAtmosphere":    {"default": true,  "group": "外观", "kind": "toggle"},
	"showClouds":        {"default": true,  "group": "外观", "kind": "toggle"},
	"showGodrays":       {"default": true,  "group": "外观", "kind": "toggle"},

	# ---- 相机与角色 ----
	"spectatorSpeed":    {"default": 80.0,  "group": "相机与角色", "min": 5.0,   "max": 400.0, "step": 1.0, "kind": "slider"},
	"walkSpeed":         {"default": 25.0,  "group": "相机与角色", "min": 1.0,   "max": 200.0, "step": 1.0, "kind": "slider"},
	"invertY":           {"default": true,  "group": "相机与角色", "kind": "toggle"},

	# ---- 太阳 ----
	"sunElevation":      {"default": 35.0,  "group": "太阳", "min": -90.0, "max": 90.0,  "step": 0.5, "kind": "slider"},
	"sunAzimuth":        {"default": 40.0,  "group": "太阳", "min": 0.0,   "max": 360.0, "step": 0.5, "kind": "slider"},
	"autoSun":           {"default": false, "group": "太阳", "kind": "toggle"},
	"sunSpeed":          {"default": 6.0,   "group": "太阳", "min": 0.0,   "max": 60.0,  "step": 0.1, "kind": "slider"},

	# ---- 大气散射 ----
	"atmoScale":         {"default": 1.08,  "group": "大气散射", "min": 1.0,   "max": 1.5,   "step": 0.001, "kind": "slider"},
	"atmoRayleigh":      {"default": 0.08,  "group": "大气散射", "min": 0.0,   "max": 0.5,   "step": 0.001, "kind": "slider"},
	"atmoMie":           {"default": 0.03,  "group": "大气散射", "min": 0.0,   "max": 0.3,   "step": 0.001, "kind": "slider"},
	"atmoMieG":          {"default": 0.76,  "group": "大气散射", "min": 0.0,   "max": 0.99,  "step": 0.01,  "kind": "slider"},
	"atmoDensityFalloff":{"default": 6.0,   "group": "大气散射", "min": 1.0,   "max": 16.0,  "step": 0.1,   "kind": "slider"},
	"atmoMieFalloff":    {"default": 16.0,  "group": "大气散射", "min": 1.0,   "max": 32.0,  "step": 0.1,   "kind": "slider"},
	"atmoSunIntensity":  {"default": 22.0,  "group": "大气散射", "min": 0.0,   "max": 80.0,  "step": 0.1,   "kind": "slider"},
	"atmoExposure":      {"default": 1.0,   "group": "大气散射", "min": 0.0,   "max": 4.0,   "step": 0.01,  "kind": "slider"},
	"atmoSteps":         {"default": 24,    "group": "大气散射", "min": 4,     "max": 64,    "step": 1,     "kind": "int"},
	"atmoLightSteps":    {"default": 8,     "group": "大气散射", "min": 2,     "max": 32,    "step": 1,     "kind": "int"},
	"atmoShadowSoftness":{"default": 0.6,   "group": "大气散射", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},
	"atmoTwilight":      {"default": 0.3,   "group": "大气散射", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},
	"atmoACES":          {"default": true,  "group": "大气散射", "kind": "toggle"},
	"atmoOzone":         {"default": 0.02,  "group": "大气散射", "min": 0.0,   "max": 0.3,   "step": 0.001, "kind": "slider"},
	"atmoDither":        {"default": 0.5,   "group": "大气散射", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},
	"atmoLUT":           {"default": true,  "group": "大气散射", "kind": "toggle"},

	# ---- 体积云 ----
	"cloudBottom":       {"default": 1.01,  "group": "体积云", "min": 1.0,   "max": 1.1,   "step": 0.001, "kind": "slider"},
	"cloudTop":          {"default": 1.06,  "group": "体积云", "min": 1.01,  "max": 1.3,   "step": 0.001, "kind": "slider"},
	"cloudCoverage":     {"default": 0.5,   "group": "体积云", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},
	"cloudDensity":      {"default": 1.2,   "group": "体积云", "min": 0.0,   "max": 4.0,   "step": 0.01,  "kind": "slider"},
	"cloudFreq":         {"default": 0.06,  "group": "体积云", "min": 0.0,   "max": 0.5,   "step": 0.001, "kind": "slider"},
	"cloudWarp":         {"default": 0.5,   "group": "体积云", "min": 0.0,   "max": 2.0,   "step": 0.01,  "kind": "slider"},
	"cloudWindSpeed":    {"default": 0.6,   "group": "体积云", "min": 0.0,   "max": 5.0,   "step": 0.01,  "kind": "slider"},
	"cloudSteps":        {"default": 24,    "group": "体积云", "min": 4,     "max": 96,    "step": 1,     "kind": "int"},
	"cloudLightSteps":   {"default": 6,     "group": "体积云", "min": 2,     "max": 16,    "step": 1,     "kind": "int"},
	"cloudAbsorb":       {"default": 1.0,   "group": "体积云", "min": 0.0,   "max": 4.0,   "step": 0.01,  "kind": "slider"},
	"cloudSilver":       {"default": 1.0,   "group": "体积云", "min": 0.0,   "max": 4.0,   "step": 0.01,  "kind": "slider"},
	"cloudPowder":       {"default": 0.6,   "group": "体积云", "min": 0.0,   "max": 2.0,   "step": 0.01,  "kind": "slider"},
	"cloudShadow":       {"default": 0.7,   "group": "体积云", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},

	# ---- 体积光 ----
	"godrayStrength":    {"default": 0.6,   "group": "体积光", "min": 0.0,   "max": 2.0,   "step": 0.01,  "kind": "slider"},
	"godrayDensity":     {"default": 0.7,   "group": "体积光", "min": 0.0,   "max": 2.0,   "step": 0.01,  "kind": "slider"},
	"godraySamples":     {"default": 48,    "group": "体积光", "min": 8,     "max": 128,   "step": 1,     "kind": "int"},
	"godrayThreshold":   {"default": 0.45,  "group": "体积光", "min": 0.0,   "max": 1.0,   "step": 0.01,  "kind": "slider"},

	# ---- LOD ----
	"maxLevel":          {"default": 8,     "group": "LOD", "min": 1,     "max": 12,    "step": 1,    "kind": "int"},
	"splitFactor":       {"default": 2.5,   "group": "LOD", "min": 1.0,   "max": 6.0,   "step": 0.05, "kind": "slider"},
	"patchResolution":   {"default": 16,    "group": "LOD", "min": 4,     "max": 64,    "step": 1,    "kind": "int"},  # 必须是 2 的幂(缝合算法要求)
	"frustumMargin":     {"default": 0.15,  "group": "LOD", "min": 0.0,   "max": 1.0,   "step": 0.01, "kind": "slider"},
	"nearRadius":        {"default": 50.0,  "group": "LOD", "min": 1.0,   "max": 500.0, "step": 1.0,  "kind": "slider"},

	# ---- 大陆噪声 fBm ----
	"continentSeed":      {"default": 1337,  "group": "大陆噪声", "min": 0, "max": 999999, "step": 1, "kind": "seed"},
	"continentFreq":      {"default": 1.2,   "group": "大陆噪声", "min": 0.01, "max": 8.0, "step": 0.01, "kind": "slider"},
	"continentOctaves":   {"default": 5,     "group": "大陆噪声", "min": 1, "max": 8, "step": 1, "kind": "int"},
	"continentGain":      {"default": 0.5,   "group": "大陆噪声", "min": 0.0, "max": 1.0, "step": 0.01, "kind": "slider"},
	"continentLacunarity":{"default": 2.0,   "group": "大陆噪声", "min": 1.0, "max": 4.0, "step": 0.01, "kind": "slider"},

	# ---- 山脉 Ridged ----
	"mountainSeed":      {"default": 9001,  "group": "山脉", "min": 0, "max": 999999, "step": 1, "kind": "seed"},
	"mountainFreq":      {"default": 3.0,   "group": "山脉", "min": 0.01, "max": 8.0, "step": 0.01, "kind": "slider"},
	"mountainOctaves":   {"default": 5,     "group": "山脉", "min": 1, "max": 8, "step": 1, "kind": "int"},
	"mountainStrength":  {"default": 0.6,   "group": "山脉", "min": 0.0, "max": 2.0, "step": 0.01, "kind": "slider"},

	# ---- 结构增强 ----
	"warpSeed":          {"default": 777,   "group": "结构增强", "min": 0, "max": 999999, "step": 1, "kind": "seed"},
	"warpStrength":      {"default": 0.2,   "group": "结构增强", "min": 0.0, "max": 1.0, "step": 0.01, "kind": "slider"},
	"warpFreq":          {"default": 1.0,   "group": "结构增强", "min": 0.01, "max": 8.0, "step": 0.01, "kind": "slider"},
	"plateSeed":         {"default": 555,   "group": "结构增强", "min": 0, "max": 999999, "step": 1, "kind": "seed"},
	"plateFreq":         {"default": 1.6,   "group": "结构增强", "min": 0.01, "max": 8.0, "step": 0.01, "kind": "slider"},
	"plateStrength":     {"default": 0.5,   "group": "结构增强", "min": 0.0, "max": 2.0, "step": 0.01, "kind": "slider"},
	"moistureSeed":      {"default": 333,   "group": "结构增强", "min": 0, "max": 999999, "step": 1, "kind": "seed"},
	"moistureFreq":      {"default": 1.2,   "group": "结构增强", "min": 0.01, "max": 8.0, "step": 0.01, "kind": "slider"},
	"useClimate":        {"default": true,  "group": "结构增强", "kind": "toggle"},
	"climateAltRange":   {"default": 1.0,   "group": "结构增强", "min": 0.01, "max": 2.0, "step": 0.01, "kind": "slider"},
}


static func get_defaults() -> Dictionary:
	var d := {}
	for key in SCHEMA:
		d[key] = SCHEMA[key].default
	return d


static func get_kind(key: String) -> String:
	if SCHEMA.has(key):
		return SCHEMA[key].get("kind", "slider")
	return "slider"
