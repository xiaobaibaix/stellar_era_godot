## 共享 patch 生成线程池(移植 src/planet.js 的 WorkerPool + src/worker.js)。
## 用 Godot 内置 WorkerThreadPool(进程级), 所有 Planet 实例复用。
## 任务在线程内跑 PatchBuilder(纯数据), 结果用 call_deferred 回主线程。
##
## Terrain 复用: 同 generation 参数不变, 成百上千个任务共享同一个 Terrain,
## 省掉每任务 5 个 FastNoiseLite 的分配/配置(worker 里的显著开销)。
## 取消: C++ 任务无法中断, 所以调用方在结果回来时用 node.cancelled + planet._gen 自检,
## 过期/取消的结果直接丢弃。
class_name PatchWorkerPool
extends RefCounted

static var _instance: PatchWorkerPool = null

# 实例级缓存 + 互斥(pool 是单例, 实例变量即全局共享; Mutex 在构造时 new, 避免 static 初始化限制)。
var _terr_cache: Dictionary = {}
var _terr_mutex: Mutex = Mutex.new()


static func instance() -> PatchWorkerPool:
	if _instance == null:
		_instance = PatchWorkerPool.new()
	return _instance


# 以 terrain 字典内容哈希为 key 缓存 Terrain; 不同 generation 参数变化时自然换条目。
func _get_terrain(d: Dictionary) -> Terrain:
	var key: int = hash(d)
	_terr_mutex.lock()
	var t: Variant = _terr_cache.get(key, null)
	if t == null:
		t = Terrain.from_dict(d)
		# 简单淘汰: 参数基本不变, 实际只 1~2 个条目; 超阈值清空防爆。
		if _terr_cache.size() > 8:
			_terr_cache.clear()
		_terr_cache[key] = t
	_terr_mutex.unlock()
	return t


## msg: { A,B,C(Vector3), N, R, maxHeight, seaLevel, terrain(dict), strides(Array) }
## on_done: Callable(result_dict)  在主线程调用(result 带 gen)
func submit(msg: Dictionary, on_done: Callable, gen: int) -> void:
	WorkerThreadPool.add_task(func() -> void:
		var terrain := _get_terrain(msg.terrain)
		var result: Dictionary = PatchBuilder.build_patch_arrays(
			msg.A, msg.B, msg.C, msg.N, msg.R, msg.maxHeight,
			terrain, msg.strides)
		result["gen"] = gen
		on_done.call_deferred(result)
	)
