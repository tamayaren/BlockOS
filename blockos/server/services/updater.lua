-- Software Update for Server Edition: checks the server channel on a schedule, installs new
-- releases in the background and restarts when no transfer is running.

local Server = BlockOS.Require("server/config")

local Service = {
	Name = "updater",
	Title = "Software Update",
	Description = "Keeps BlockOS Server Edition up to date.",
	Version = "1.0",
	System = true,
	Hidden = true
}

local Updater
local Log
Service.Message = "Not checked yet"

local function Busy(Ctx)
	local Drive = Ctx.Manager.Get("blockdrive")
	local Module = Drive and Drive.Module
	return Module and Module.ActiveTransfers and Module.ActiveTransfers() > 0
end

-- Checks, and installs when Install is true. Returns the manifest when one was found.
function Service.Check(Install)
	if (not http) then
		Service.Message = "HTTP is disabled on this Minecraft server"
		return nil
	end
	local Manifest, Err = Updater.Check()
	if (not Manifest) then
		Service.Message = "Check failed: " .. tostring(Err)
		Log.Warn("updater", Service.Message)
		return nil
	end
	if (not Manifest.Newer) then
		Service.Message = "Up to date (" .. Server.Version() .. ")"
		return Manifest
	end
	Service.Message = "Version " .. Manifest.Version .. " is available"
	Log.Info("updater", Service.Message)
	if (Install) then
		Service.Message = "Installing " .. Manifest.Version .. "..."
		os.queueEvent("blockcloud_status")
		local Ok, ApplyErr = Updater.Apply(Manifest)
		if (Ok) then
			Service.Message = "Installed " .. Manifest.Version .. "; restart to finish"
			Service.Pending = Manifest.Version
			Log.Info("updater", Service.Message)
		else
			Service.Message = "Install failed: " .. tostring(ApplyErr)
			Log.Error("updater", Service.Message)
		end
	end
	return Manifest
end

function Service.Init(Ctx)
	Log = Ctx.Log
	Updater = Server.ConfigureUpdater()
end

function Service.Run(Ctx)
	local Timer = os.startTimer(60)
	while (true) do
		local Event, A = os.pullEvent()
		local Settings = Server.Settings()
		if (Event == "blockcloud_update") then
			-- From the console or bcloud: A is "check" or "install".
			Service.Check(A == "install")
			os.queueEvent("blockcloud_status")
			if (Service.Pending and Settings.AutoRestart) then
				os.cancelTimer(Timer)
				Timer = os.startTimer(10)
			end
		elseif (Event == "timer" and A == Timer) then
			if (Service.Pending and Settings.AutoRestart) then
				if (not Busy(Ctx)) then
					Log.Info("updater", "Restarting to finish installing " .. Service.Pending)
					sleep(2)
					os.reboot()
				end
			elseif (Settings.AutoUpdate and not Service.Pending) then
				Service.Check(Settings.AutoInstall)
				os.queueEvent("blockcloud_status")
			end
			local Hours = math.max(1, tonumber(Settings.UpdateHours) or 6)
			Timer = os.startTimer(Service.Pending and 30 or Hours * 3600)
		end
	end
end

function Service.Health()
	if (Service.Pending) then return "warn", "Restart to finish installing " .. Service.Pending end
	return "ok", Service.Message
end

return Service
