@tool
## 天体节点(第1步:简单球体, 不用 Planet)。
## - 持有物理 Body(由所属 CelestialSystem 在 _ready 时分配); 自身不跑物理。
## - global_position 每帧由系统写入 = 世界 double − 全局浮动原点。
## - 编辑器里的 local position 仅用于系统初始化时读取【到主导体的距离】。
## - 外观走策略模式: @export mesh_strategy 决定怎么造 mesh/材质/光; 留空 = 默认纯色球。
## - @tool: 编辑器里也构建 mesh(作为 internal 子节点 → 3D 视图可见但不存盘, 不污染 .tscn)。
class_name Celestial
extends Node3D

@export var mass: float = 1.0
@export var radius: float = 200.0:
	set(v): radius = v; _rebuild_if_ready()
@export var type: String = "planet":
	set(v): type = v; _rebuild_if_ready()
@export var color: Color = Color(0.6, 0.7, 1.0):
	set(v): color = v; _rebuild_if_ready()
@export var is_dominant: bool = false             # 本系统主导体(恒星 / 行星)
@export var mesh_strategy: CelestialMesh:
	set(v): mesh_strategy = v; _rebuild_if_ready()

var body: Body = null                             # 物理对象(系统分配, 运行时)
var owner_system: Node = null                     # 所属 CelestialSystem

# 世界 double 位置缓存(系统每帧写; 顶层据此设浮动原点)
var _wx: float = 0.0
var _wy: float = 0.0
var _wz: float = 0.0

var _visual: Node3D = null                        # 外观子树根(internal 子节点)
var _default_mesh: CelestialMesh = null           # fallback 默认策略(缓存, 避免每次 rebuild 都 new)
var _built: bool = false                          # 首次构建完成标志(setter 据此决定是否 rebuild)

var _trail: Array = []                            # Array[Vector3] 世界 double 位置(运动尾迹, 系统每帧追加)


func _ready() -> void:
	_build_visual()


# @export 参数(radius/color/type/mesh_strategy)变化 → 即时刷新编辑器预览。
func _rebuild_if_ready() -> void:
	if _built:
		_build_visual()


func _build_visual() -> void:
	if not is_inside_tree():
		return
	# 移除旧外观子树
	if _visual != null and is_instance_valid(_visual):
		remove_child(_visual)
		_visual.queue_free()
	# 留空 → 默认纯色球(缓存实例); 挂策略 → 用策略。
	if _default_mesh == null:
		_default_mesh = CelestialMesh.new()
	var s: CelestialMesh = mesh_strategy if mesh_strategy != null else _default_mesh
	_visual = s.build(self)
	# INTERNAL_MODE_BACK: 编辑器 3D 视图可见, 但不进场景树面板、不存盘 → 不污染 .tscn。
	add_child(_visual, false, Node.INTERNAL_MODE_BACK)
	_built = true
