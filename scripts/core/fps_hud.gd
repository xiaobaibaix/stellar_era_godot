## 调试 FPS HUD: 挂到场景里的 CanvasLayer 上即可, _ready 自动建 Label, 每帧刷 FPS。
## 用法: 场景加一个 CanvasLayer 节点, script 挂本文件; 或代码 FPSHud.new() + add_child。
extends CanvasLayer

var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.name = "FPSLabel"
	_label.position = Vector2(8, 8)
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_label)


func _process(_delta: float) -> void:
	_label.text = "FPS: %d" % Engine.get_frames_per_second()
