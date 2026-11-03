-- Background tasks for GUI apps. A task is a coroutine that may block on the network; the app
-- forwards every event here (before its page handles it) so the window keeps responding while
-- requests run. Each app needs its own instance: BlockOS.Load("/blockos/lib/tasks.lua").

local Tasks = { List = {} }

local function Remove(Task)
	for Index, Other in ipairs(Tasks.List) do
		if (Other == Task) then
			table.remove(Tasks.List, Index)
			return
		end
	end
end

local function Finish(Task, Ok, ...)
	Remove(Task)
	Task.Done = true
	if (Task.OnDone) then Task.OnDone(Ok, ...) end
end

local function Resume(Task, ...)
	local Result = table.pack(coroutine.resume(Task.Co, ...))
	if (Task.Done) then return end
	if (not Result[1]) then
		Finish(Task, false, Result[2])
	elseif (coroutine.status(Task.Co) == "dead") then
		Finish(Task, true, table.unpack(Result, 2, Result.n))
	else
		Task.Filter = Result[2]
	end
end

-- Starts Fn in the background. OnDone(Ok, ...) receives its results (or false and the error).
function Tasks.Spawn(Fn, OnDone)
	local Task = { Co = coroutine.create(Fn), OnDone = OnDone }
	table.insert(Tasks.List, Task)
	Resume(Task)
	return Task
end

-- Stops a task without calling its OnDone.
function Tasks.Cancel(Task)
	if (not Task or Task.Done) then return end
	Task.Done = true
	Remove(Task)
end

-- Feeds an event to waiting tasks. Returns true when any task was resumed.
function Tasks.Dispatch(Name, ...)
	if (#Tasks.List == 0 or Name == "terminate") then return false end
	local Any = false
	for _, Task in ipairs({ table.unpack(Tasks.List) }) do
		if (not Task.Done and (Task.Filter == nil or Task.Filter == Name)) then
			Resume(Task, Name, ...)
			Any = true
		end
	end
	return Any
end

function Tasks.Busy()
	return #Tasks.List > 0
end

return Tasks
