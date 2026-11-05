class_name TaskReaper

## Worker tasks whose result nobody wants any more -- a band forgotten, a
## building toppled or given back while its mesh was still being made. Waiting
## for one stalls the tick for the rest of its run (CLAUDE.md "Where new code
## runs"; Docs/WhereWorkRuns.md 3.1 b), but every task still has to be waited
## for once to be freed. So it is left to finish and waited for here, on a
## frame after it has. Only for tasks that write nothing but their own
## captured arrays: one that writes into its owner would write after the owner
## had moved on.

static var _tasks: Array[int] = []


## Leave `task` to finish; it is waited for (free by then) once it has.
static func drop(task: int) -> void:
	if task < 0:
		return
	if WorkerThreadPool.is_task_completed(task):
		WorkerThreadPool.wait_for_task_completion(task)
		return
	_tasks.append(task)
	if _tasks.size() == 1:
		(Engine.get_main_loop() as SceneTree).process_frame.connect(_reap)


## How many are still running.
static func pending() -> int:
	return _tasks.size()


static func _reap() -> void:
	var k := 0
	while k < _tasks.size():
		if WorkerThreadPool.is_task_completed(_tasks[k]):
			WorkerThreadPool.wait_for_task_completion(_tasks[k])
			_tasks.remove_at(k)
		else:
			k += 1
	if _tasks.is_empty():
		(Engine.get_main_loop() as SceneTree).process_frame.disconnect(_reap)
