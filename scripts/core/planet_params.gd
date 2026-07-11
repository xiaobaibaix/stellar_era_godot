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
## 行星半径(世界单位)。改它需要重建网格(见 REBUILD_KEYS)。
@export_range(10.0, 2000.0, 1.0) var radius: float = 100.0:
	set(v): radius = v; param_changed.emit("radius")
## 地形隆起的最大高度(相对半径的比例, 实际位移 = height_at × maxHeight)。越大山脉越夸张。
@export_range(0.0, 50.0, 0.1) var maxHeight: float = 8.0:
	set(v): maxHeight = v; param_changed.emit("maxHeight")
## 海平面高度阈值: height_at < seaLevel 视为海洋(配色 + 后续海面 mesh)。
@export_range(-0.5, 0.5, 0.01) var seaLevel: float = 0.0:
	set(v): seaLevel = v; param_changed.emit("seaLevel")

# ---- 外观 ----
@export_group("外观")
## 线框模式: 开启后整个行星以线框渲染(调试 LOD 用)。
@export var wireframe: bool = false:
	set(v): wireframe = v; param_changed.emit("wireframe")
## 画中画(小窗口)开关(Phase 5)。
@export var showInset: bool = true:
	set(v): showInset = v; param_changed.emit("showInset")
## 海面 mesh 开关(Phase 2)。
@export var showOcean: bool = true:
	set(v): showOcean = v; param_changed.emit("showOcean")
## 大气散射壳开关(Phase 2)。
@export var showAtmosphere: bool = true:
	set(v): showAtmosphere = v; param_changed.emit("showAtmosphere")
## 体积云开关(Phase 2)。
@export var showClouds: bool = true:
	set(v): showClouds = v; param_changed.emit("showClouds")
## 体积光(godray)开关(Phase 5)。
@export var showGodrays: bool = true:
	set(v): showGodrays = v; param_changed.emit("showGodrays")

# ---- 相机与角色 ----
@export_group("相机与角色")
## 观察者(自由飞行)模式移动速度。
@export_range(5.0, 400.0, 1.0) var spectatorSpeed: float = 80.0:
	set(v): spectatorSpeed = v; param_changed.emit("spectatorSpeed")
## 角色表面行走速度。
@export_range(1.0, 200.0, 1.0) var walkSpeed: float = 25.0:
	set(v): walkSpeed = v; param_changed.emit("walkSpeed")
## 鼠标纵向是否反转。
@export var invertY: bool = true:
	set(v): invertY = v; param_changed.emit("invertY")

# ---- 太阳 ----
@export_group("太阳")
## 太阳仰角(度, -90..90): 控制日高低。
@export_range(-90.0, 90.0, 0.5) var sunElevation: float = 35.0:
	set(v): sunElevation = v; param_changed.emit("sunElevation")
## 太阳方位角(度, 0..360): 控制日照方向。
@export_range(0.0, 360.0, 0.5) var sunAzimuth: float = 40.0:
	set(v): sunAzimuth = v; param_changed.emit("sunAzimuth")
## 自动日照: 太阳自动绕行星转, 模拟昼夜。
@export var autoSun: bool = false:
	set(v): autoSun = v; param_changed.emit("autoSun")
## 自动日照转速(度/秒)。
@export_range(0.0, 60.0, 0.1) var sunSpeed: float = 6.0:
	set(v): sunSpeed = v; param_changed.emit("sunSpeed")

# ---- 大气散射 ----
@export_group("大气散射")
## 大气壳半径 = 行星半径 × atmoScale(壳要略大于行星)。
@export_range(1.0, 1.5, 0.001) var atmoScale: float = 1.08:
	set(v): atmoScale = v; param_changed.emit("atmoScale")
## 瑞利散射强度(短波长, 主导天空蓝/日间色)。
@export_range(0.0, 0.5, 0.001) var atmoRayleigh: float = 0.08:
	set(v): atmoRayleigh = v; param_changed.emit("atmoRayleigh")
## 米氏散射强度(全波长, 主导雾霭/地平线光晕)。
@export_range(0.0, 0.3, 0.001) var atmoMie: float = 0.03:
	set(v): atmoMie = v; param_changed.emit("atmoMie")
## 米氏相位不对称量(-1..1): 越大越聚集向前(强银边/前向光晕)。
@export_range(0.0, 0.99, 0.01) var atmoMieG: float = 0.76:
	set(v): atmoMieG = v; param_changed.emit("atmoMieG")
## 大气密度随高度衰减指数(越大越贴地表衰减越快)。
@export_range(1.0, 16.0, 0.1) var atmoDensityFalloff: float = 6.0:
	set(v): atmoDensityFalloff = v; param_changed.emit("atmoDensityFalloff")
## 米氏衰减指数(通常比密度衰减大, 贴近地表的雾)。
@export_range(1.0, 32.0, 0.1) var atmoMieFalloff: float = 16.0:
	set(v): atmoMieFalloff = v; param_changed.emit("atmoMieFalloff")
## 太阳光照强度(亮度倍率)。
@export_range(0.0, 80.0, 0.1) var atmoSunIntensity: float = 22.0:
	set(v): atmoSunIntensity = v; param_changed.emit("atmoSunIntensity")
## 曝光(最终亮度倍率, 接近 HDR 输出后)。
@export_range(0.0, 4.0, 0.01) var atmoExposure: float = 1.0:
	set(v): atmoExposure = v; param_changed.emit("atmoExposure")
## 视线积分步数: 越多越精确、越慢(主光线步进)。
@export_range(4, 64, 1) var atmoSteps: int = 24:
	set(v): atmoSteps = v; param_changed.emit("atmoSteps")
## 光照(自散射/阴影)积分步数: 较少即可。
@export_range(2, 32, 1) var atmoLightSteps: int = 8:
	set(v): atmoLightSteps = v; param_changed.emit("atmoLightSteps")
## 云在地表的投影柔和度。
@export_range(0.0, 1.0, 0.01) var atmoShadowSoftness: float = 0.6:
	set(v): atmoShadowSoftness = v; param_changed.emit("atmoShadowSoftness")
## 暮光增强(日出日落时暖色加强)。
@export_range(0.0, 1.0, 0.01) var atmoTwilight: float = 0.3:
	set(v): atmoTwilight = v; param_changed.emit("atmoTwilight")
## ACES 色调映射开关(开: 电影感, 高光更柔和)。
@export var atmoACES: bool = true:
	set(v): atmoACES = v; param_changed.emit("atmoACES")
## 臭氧吸收量(影响天空/日落的青绿调)。
@export_range(0.0, 0.3, 0.001) var atmoOzone: float = 0.02:
	set(v): atmoOzone = v; param_changed.emit("atmoOzone")
## 抖动(去 banding 色带)强度。
@export_range(0.0, 1.0, 0.01) var atmoDither: float = 0.5:
	set(v): atmoDither = v; param_changed.emit("atmoDither")
## 透射率 LUT 预烘焙开关(开: 更准、略多显存)。
@export var atmoLUT: bool = true:
	set(v): atmoLUT = v; param_changed.emit("atmoLUT")

# ---- 体积云 ----
@export_group("体积云")
## 云层底部高度 = 行星半径 × cloudBottom。
@export_range(1.0, 1.1, 0.001) var cloudBottom: float = 1.01:
	set(v): cloudBottom = v; param_changed.emit("cloudBottom")
## 云层顶部高度 = 行星半径 × cloudTop(必须 > cloudBottom)。
@export_range(1.01, 1.3, 0.001) var cloudTop: float = 1.06:
	set(v): cloudTop = v; param_changed.emit("cloudTop")
## 云覆盖量(0 无云, 1 满天)。
@export_range(0.0, 1.0, 0.01) var cloudCoverage: float = 0.5:
	set(v): cloudCoverage = v; param_changed.emit("cloudCoverage")
## 云密度(单点透明度)。
@export_range(0.0, 4.0, 0.01) var cloudDensity: float = 1.2:
	set(v): cloudDensity = v; param_changed.emit("cloudDensity")
## 云噪声细节频率(越大细节越密)。
@export_range(0.0, 0.5, 0.001) var cloudFreq: float = 0.06:
	set(v): cloudFreq = v; param_changed.emit("cloudFreq")
## 云域扭曲(让云边缘自然卷曲)。
@export_range(0.0, 2.0, 0.01) var cloudWarp: float = 0.5:
	set(v): cloudWarp = v; param_changed.emit("cloudWarp")
## 风速(云层平移速度, 制造动效)。
@export_range(0.0, 5.0, 0.01) var cloudWindSpeed: float = 0.6:
	set(v): cloudWindSpeed = v; param_changed.emit("cloudWindSpeed")
## 云层主积分步数(越多越精细、越慢)。
@export_range(4, 96, 1) var cloudSteps: int = 24:
	set(v): cloudSteps = v; param_changed.emit("cloudSteps")
## 云光照(自阴影)积分步数。
@export_range(2, 16, 1) var cloudLightSteps: int = 6:
	set(v): cloudLightSteps = v; param_changed.emit("cloudLightSteps")
## 云光吸收强度。
@export_range(0.0, 4.0, 0.01) var cloudAbsorb: float = 1.0:
	set(v): cloudAbsorb = v; param_changed.emit("cloudAbsorb")
## 银边强度(前向散射, 云迎光边缘发亮)。
@export_range(0.0, 4.0, 0.01) var cloudSilver: float = 1.0:
	set(v): cloudSilver = v; param_changed.emit("cloudSilver")
## 粉末效应(云深处更亮, 增强体积感)。
@export_range(0.0, 2.0, 0.01) var cloudPowder: float = 0.6:
	set(v): cloudPowder = v; param_changed.emit("cloudPowder")
## 云在地表的投影强度。
@export_range(0.0, 1.0, 0.01) var cloudShadow: float = 0.7:
	set(v): cloudShadow = v; param_changed.emit("cloudShadow")

# ---- 体积光 ----
@export_group("体积光")
## 体积光(godray)强度。
@export_range(0.0, 2.0, 0.01) var godrayStrength: float = 0.6:
	set(v): godrayStrength = v; param_changed.emit("godrayStrength")
## 体积光介质密度(越浓光束越明显)。
@export_range(0.0, 2.0, 0.01) var godrayDensity: float = 0.7:
	set(v): godrayDensity = v; param_changed.emit("godrayDensity")
## 体积光采样数(越多越平滑、越慢)。
@export_range(8, 128, 1) var godraySamples: int = 48:
	set(v): godraySamples = v; param_changed.emit("godraySamples")
## 体积光阈值(遮挡深度, 控制光束出现的范围)。
@export_range(0.0, 1.0, 0.01) var godrayThreshold: float = 0.45:
	set(v): godrayThreshold = v; param_changed.emit("godrayThreshold")

# ---- LOD ----
@export_group("LOD")
## 最大细分层数: 越大近处 patch 越细(细节越多, 但 patch 越多越费)。
@export_range(1, 12, 1) var maxLevel: int = 8:
	set(v): maxLevel = v; param_changed.emit("maxLevel")
## 细分触发倍率: 相机距 patch 中心 < edge_len × splitFactor 就细分。
@export_range(1.0, 6.0, 0.05) var splitFactor: float = 2.5:
	set(v): splitFactor = v; param_changed.emit("splitFactor")
## 预取环倍率(>1): 进入 edge_len × splitFactor × prefetchFactor 即后台预生成下一级,
## 到 splitFactor 才显示。摊平生成峰值、消除 pop-in。=1 关闭预取。
@export_range(1.0, 3.0, 0.05) var prefetchFactor: float = 1.4:
	set(v): prefetchFactor = v; param_changed.emit("prefetchFactor")
## 每片 patch 的网格分辨率(必须是 2 的幂)。越大单 patch 顶点越多、越平滑、越费。
@export_range(4, 64, 1) var patchResolution: int = 16:
	set(v): patchResolution = v; param_changed.emit("patchResolution")  # 必须 2 的幂
## 视锥剔除余量: 越大越晚剔除(减少旋转时 pop-in, 但多渲染些视锥外 patch)。
@export_range(0.0, 1.0, 0.01) var frustumMargin: float = 0.15:
	set(v): frustumMargin = v; param_changed.emit("frustumMargin")
## 近距半径: 相机距 patch < 此值时强制按距离细分、不参与视锥剔除(避免环视时背后补细分)。
@export_range(1.0, 500.0, 1.0) var nearRadius: float = 50.0:
	set(v): nearRadius = v; param_changed.emit("nearRadius")

# ---- 大陆噪声 fBm ----
@export_group("大陆噪声")
## 大陆随机种子: 改它整张地形图案换样。
@export_range(0, 999999, 1) var continentSeed: int = 1337:
	set(v): continentSeed = v; param_changed.emit("continentSeed")
## 大陆频率: 越大大陆块越小越碎。
@export_range(0.01, 8.0, 0.01) var continentFreq: float = 1.2:
	set(v): continentFreq = v; param_changed.emit("continentFreq")
## 大陆 fBm 叠加层数: 越多细节越丰富、越慢。
@export_range(1, 8, 1) var continentOctaves: int = 5:
	set(v): continentOctaves = v; param_changed.emit("continentOctaves")
## 大陆每层增益(振幅衰减): 越大高频细节越突出。
@export_range(0.0, 1.0, 0.01) var continentGain: float = 0.5:
	set(v): continentGain = v; param_changed.emit("continentGain")
## 大陆每层频率倍率(通常 2.0)。
@export_range(1.0, 4.0, 0.01) var continentLacunarity: float = 2.0:
	set(v): continentLacunarity = v; param_changed.emit("continentLacunarity")

# ---- 山脉 Ridged ----
@export_group("山脉")
## 山脉随机种子。
@export_range(0, 999999, 1) var mountainSeed: int = 9001:
	set(v): mountainSeed = v; param_changed.emit("mountainSeed")
## 山脉频率: 越大山脊越密。
@export_range(0.01, 8.0, 0.01) var mountainFreq: float = 3.0:
	set(v): mountainFreq = v; param_changed.emit("mountainFreq")
## 山脉 ridged 噪声层数。
@export_range(1, 8, 1) var mountainOctaves: int = 5:
	set(v): mountainOctaves = v; param_changed.emit("mountainOctaves")
## 山脉强度: 山脉对高度的贡献权重(海里不叠山)。
@export_range(0.0, 2.0, 0.01) var mountainStrength: float = 0.6:
	set(v): mountainStrength = v; param_changed.emit("mountainStrength")

# ---- 结构增强 ----
@export_group("结构增强")
## 域扭曲种子: 扰动采样坐标, 让大陆/山脉边缘更自然。
@export_range(0, 999999, 1) var warpSeed: int = 777:
	set(v): warpSeed = v; param_changed.emit("warpSeed")
## 域扭曲强度(越大地形越扭曲变形)。
@export_range(0.0, 1.0, 0.01) var warpStrength: float = 0.2:
	set(v): warpStrength = v; param_changed.emit("warpStrength")
## 域扭曲频率。
@export_range(0.01, 8.0, 0.01) var warpFreq: float = 1.0:
	set(v): warpFreq = v; param_changed.emit("warpFreq")
## 板块边界种子: cellular 噪声形成板块, 边界起脊(造山脉带)。
@export_range(0, 999999, 1) var plateSeed: int = 555:
	set(v): plateSeed = v; param_changed.emit("plateSeed")
## 板块频率: 越大板块越小越密。
@export_range(0.01, 8.0, 0.01) var plateFreq: float = 1.6:
	set(v): plateFreq = v; param_changed.emit("plateFreq")
## 板块脊强度(边界造山幅度)。
@export_range(0.0, 2.0, 0.01) var plateStrength: float = 0.5:
	set(v): plateStrength = v; param_changed.emit("plateStrength")
## 湿度噪声种子: 决定干旱/湿润分布(影响生物群系配色)。
@export_range(0, 999999, 1) var moistureSeed: int = 333:
	set(v): moistureSeed = v; param_changed.emit("moistureSeed")
## 湿度频率。
@export_range(0.01, 8.0, 0.01) var moistureFreq: float = 1.2:
	set(v): moistureFreq = v; param_changed.emit("moistureFreq")
## 气候配色开关: 关闭则用单一高度配色, 开启则温度×湿度→生物群系。
@export var useClimate: bool = true:
	set(v): useClimate = v; param_changed.emit("useClimate")
## 气候海拔归一范围: 把(高度-海平面)映射到此范围算温度。
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
