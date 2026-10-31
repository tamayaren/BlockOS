-- Starts, supervises and restarts BlockCloud services. Each service is a module in
-- /blockos/server/services with:
--   Name, Title, Description, Version, System (always on)
--   Init(Ctx)    register RPC operations and prepare state (may error)
--   Run(Ctx)     optional background loop using os.pullEvent; restarted if it crashes
--   Health()     optional: returns "ok" | "warn" | "error", detail text
--   Info()       optional: extra fields announced during discovery
-- New services (storage nodes, job workers, ...) only need a file here and an entry in Order.

local Log = BlockOS.Require("server/log")
local Rpc = BlockOS.Require("server/rpc")
local Server = BlockOS.Require("server/config")

local Manager = {}

Manager.Dir = "/blockos/server/services"
Manager.Order = { "core", "blockdrive", "updater" }
Manager.Services = {}

local Timers = {}

local function Context(Service)
	return { Rpc = Rpc, Log = Log, Server = Server, Manager = Manager, Service = Service }
end

function Manager.Enabled(Name)
	local Service = Manager.Services[Name]
	if (Service and Service.Module.System) then return true end
	local Flags = Server.Settings().Services or {}
	return Flags[Name] ~= false
end

local function Schedule(Service)
	Service.Restarts = Service.Restarts + 1
	local Delay = math.min(60, 5 * 2 ^ math.min(Service.Restarts - 1, 4))
	Service.State = "restarting"
	Service.RetryAt = os.clock() + Delay
	Timers[os.startTimer(Delay)] = Service
end

local function Fail(Service, Stage, Err)
	Service.Co = nil
	Service.LastError = tostring(Err)
	Log.Error(Service.Name, Stage .. " failed: " .. Service.LastError)
	Schedule(Service)
	os.queueEvent("blockcloud_status")
end

local function Resume(Service, ...)
	local Ok, Result = coroutine.resume(Service.Co, ...)
	if (not Ok) then
		Fail(Service, "Service", Result)
	elseif (coroutine.status(Service.Co) == "dead") then
		Service.Co = nil
		Service.State = "running"
	else
		Service.Filter = Result
	end
end

local function Start(Service)
	if (not Manager.Enabled(Service.Name)) then
		Service.State = "disabled"
		return
	end
	if (not Service.Initialised) then
		local Ok, Err = pcall(Service.Module.Init, Context(Service))
		if (not Ok) then
			Fail(Service, "Start", Err)
			return
		end
		Service.Initialised = true
	end
	Service.State = "running"
	Service.Since = os.epoch("utc")
	if (Service.Module.Run) then
		Service.Co = coroutine.create(function() Service.Module.Run(Context(Service)) end)
		Service.Filter = nil
		Resume(Service)
	end
	os.queueEvent("blockcloud_status")
end

function Manager.Load()
	for _, Name in ipairs(Manager.Order) do
		local Path = fs.combine(Manager.Dir, Name .. ".lua")
		if (fs.exists(Path)) then
			local Ok, Module = pcall(BlockOS.Load, "/" .. Path)
			if (Ok and type(Module) == "table") then
				Manager.Services[Name] = {
					Name = Name, Module = Module, State = "stopped", Restarts = 0, Initialised = false
				}
			else
				Log.Error("services", "Could not load " .. Name .. ": " .. tostring(Module))
			end
		end
	end
end

function Manager.StartAll()
	for _, Name in ipairs(Manager.Order) do
		local Service = Manager.Services[Name]
		if (Service) then Start(Service) end
	end
end

function Manager.Get(Name)
	return Manager.Services[Name]
end

-- Stops a service's background loop and removes its operations.
function Manager.Stop(Name)
	local Service = Manager.Services[Name]
	if (not Service) then return end
	if (Service.Module.Stop) then pcall(Service.Module.Stop) end
	Service.Co = nil
	Service.Initialised = false
	Service.State = "stopped"
	Rpc.Unregister(Name)
	os.queueEvent("blockcloud_status")
end

function Manager.Restart(Name)
	local Service = Manager.Services[Name]
	if (not Service) then return end
	Manager.Stop(Name)
	Service.Restarts = 0
	Start(Service)
	Log.Info(Name, "Restarted")
end

function Manager.SetEnabled(Name, Enabled)
	local Settings = Server.Settings()
	Settings.Services = Settings.Services or {}
	Settings.Services[Name] = Enabled and true or false
	Server.Save()
	if (Enabled) then
		Manager.Restart(Name)
	else
		Manager.Stop(Name)
		Manager.Services[Name].State = "disabled"
		Log.Info(Name, "Disabled")
	end
end

function Manager.Dispatch(Event)
	if (Event[1] == "timer" and Timers[Event[2]]) then
		local Service = Timers[Event[2]]
		Timers[Event[2]] = nil
		if (Service.State == "restarting") then
			Log.Info(Service.Name, "Restarting (attempt " .. Service.Restarts .. ")")
			Start(Service)
		end
		return
	end
	for _, Name in ipairs(Manager.Order) do
		local Service = Manager.Services[Name]
		if (Service and Service.Co and (Service.Filter == nil or Service.Filter == Event[1])) then
			Resume(Service, table.unpack(Event, 1, Event.n))
		end
	end
end

-- One entry per service for the console: Name, Title, State, Level, Detail.
function Manager.Status()
	local List = {}
	for _, Name in ipairs(Manager.Order) do
		local Service = Manager.Services[Name]
		if (Service) then
			local Level, Detail = "ok", nil
			if (Service.State == "running" and Service.Module.Health) then
				local Ok, A, B = pcall(Service.Module.Health)
				if (Ok) then
					Level, Detail = A or "ok", B
				else
					Level, Detail = "error", tostring(A)
				end
			elseif (Service.State == "restarting" or Service.State == "stopped") then
				Level, Detail = "error", Service.LastError
			elseif (Service.State == "disabled") then
				Level = "off"
			end
			table.insert(List, {
				Name = Name, Title = Service.Module.Title or Name, State = Service.State,
				Level = Level, Detail = Detail, Restarts = Service.Restarts, System = Service.Module.System
			})
		end
	end
	return List
end

-- Services announced to clients during discovery.
function Manager.Announced()
	local List = {}
	for _, Name in ipairs(Manager.Order) do
		local Service = Manager.Services[Name]
		if (Service and Service.State == "running" and not Service.Module.Hidden) then
			local Entry = { Name = Name, Title = Service.Module.Title, Version = Service.Module.Version }
			if (Service.Module.Info) then
				for Key, Value in pairs(Service.Module.Info()) do Entry[Key] = Value end
			end
			table.insert(List, Entry)
		end
	end
	return List
end

return Manager
