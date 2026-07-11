## 共享 patch 生成线程池(移植 src/planet.js 的 WorkerPool + src/worker.js)。
## 用 Godot 内置 WorkerThreadPool(进程级), 所有 Planet 实例复用。
## 任务在线程内跑 PatchBuilder(纯数据), 结果用 call_deferred 回主线程。
##
## 取消: C++ 任务无法中断, 所以调用方在结果回来时用 node.cancelled + planet._gen 自检,
## 过期/取消的结果直接丢弃。
class_name PatchWorkerPool
extends RefCounted

static var _instance: PatchWorkerPool = null

static func instance() -> PatchWorkerPool:
	if _instance == null:
		_instance = PatchWorkerPool.new()
	return _instance


## msg: { A,B,C(Vector3), N, R, maxHeight, seaLevel, terrain(dict), strides(Array) }
## on_done: Callable(result_dict)  在主线程调用(result 带 gen)
func submit(msg: Dictionary, on_done: Callable, gen: int) -> void:
	WorkerThreadPool.add_task(func() -> void:
		var terrain := Terrain.from_dict(msg.terrain)
		var result: Dictionary = PatchBuilder.build_patch_arrays(
			msg.A, msg.B, msg.C, msg.N, msg.R, msg.maxHeight,
			terrain, msg.strides)
		result["gen"] = gen
		on_done.call_deferred(result)
	)
