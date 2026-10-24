-- BlockCloud runtime: one event loop feeds every event to the request dispatcher, its worker
-- coroutines and the services, and then to the admin interface. Services never depend on the
-- interface: if it is closed or crashes, they keep running.

local Protocol = BlockOS.Require("cloud/protocol")
local Rpc = BlockOS.Require("server/rpc")
local Log = BlockOS.Require("server/log")
local Server = BlockOS.Require("server/config")
local Manager = BlockOS.Require("server/service_manager")

local Runtime = {}

Runtime.Started = nil

local function Guard(Label, Fn, ...)
	local Ok, Err = pcall(Fn, ...)
	if (not Ok) then Log.Error("runtime", Label .. ": " .. tostring(Err)) end
end

function Runtime.Start()
	local Settings = Server.Settings()
	Log.Level = Settings.LogLevel or "info"
	Log.Info("runtime", "BlockOS Server " .. Server.Version() .. " starting on computer #" .. os.getComputerID() .. " as " .. Settings.Hostname)
	Protocol.OpenModems()
	Manager.Load()
	Manager.StartAll()
	Runtime.Started = os.epoch("utc")
end

function Runtime.Dispatch(Event)
	local Name = Event[1]
	if (Name == "terminate") then return end
	if (Name == "rednet_message" and Protocol.ServiceOf(Event[4])) then
		Guard("request", Rpc.Handle, Event[2], Event[3], Event[4])
	end
	Guard("workers", Rpc.Dispatch, Event)
	Guard("services", Manager.Dispatch, Event)
end

-- Runs forever. Ui, when given, receives every event after the services.
function Runtime.Run(Ui)
	while (true) do
		local Event = table.pack(os.pullEventRaw())
		Runtime.Dispatch(Event)
		if (Ui) then
			local Ok, Err = pcall(Ui.Dispatch, Event)
			if (not Ok) then
				Log.Error("console", tostring(Err))
				if (Ui.Recover) then pcall(Ui.Recover, Err) end
			end
		end
	end
end

return Runtime
