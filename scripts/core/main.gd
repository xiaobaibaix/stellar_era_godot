# gdlint: disable=variable-name, max-line-length
## 主场景控制:
## - FPS 显示。
## - 角色模式(Planet/Player)已下线, 等 GpuPlanet 接入 main.tscn 时重写。
extends Node

@export var camera: Camera3D
@export var fps_label: Label                # 右上角 FPS 显示(运行时每 0.25s 刷新)

var _fps_acc: float = 0.0   # FPS 文本刷新累加器


func _process(delta: float) -> void:
	_update_fps(delta)


func _update_fps(delta: float) -> void:
	if fps_label == null:
		return
	_fps_acc += delta
	if _fps_acc >= 0.25:
		_fps_acc = 0.0
		fps_label.text = "FPS:%d" % Engine.get_frames_per_second()
