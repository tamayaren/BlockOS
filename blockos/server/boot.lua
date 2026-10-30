-- BlockOS Server Edition boot: installs the BlockOS API, runs first-time setup, starts the
-- BlockCloud services and then the admin console. Services start without anyone logging in.
-- Press S on the boot screen for a recovery shell (services keep running there too).

local Shell = shell
local Loaded = {}
local Fresh = { ui = true }

_G.BlockOS = { Root = "/blockos", Edition = "server" }

function BlockOS.Load(Path, ...)
	local Fn, Err = loadfile(Path, nil, _G)
	if (not Fn) then error(Err, 2) end
	return Fn(...)
end

-- "server/<name>" loads from /blockos/server, anything else from /blockos/lib.
function BlockOS.Require(Name)
	if (Loaded[Name]) then return Loaded[Name] end
	local Path = (Name:sub(1, 7) == "server/") and ("/blockos/" .. Name .. ".lua") or ("/blockos/lib/" .. Name .. ".lua")
	local Module = BlockOS.Load(Path)
	if (not Fresh[Name]) then Loaded[Name] = Module end
	return Module
end

local function Panic(Err)
	term.redirect(term.native())
	if (term.nativePaletteColor) then
		for Index = 0, 15 do
			term.setPaletteColor(2 ^ Index, term.nativePaletteColor(2 ^ Index))
		end
	end
	term.setBackgroundColor(term.isColor() and colors.blue or colors.black)
	term.setTextColor(colors.white)
	term.clear()
	term.setCursorPos(2, 2)
	print(" :(  BlockOS Server ran into a problem.")
	print()
	print(" " .. tostring(Err))
	print()
	print(" [R] Restart now    [S] Recovery shell")
	print(" Details: /blockos/data/cloud/logs/server.log")
	local Handle = fs.open("/blockos/data/cloud/logs/server.log", "a")
	if (Handle) then
		Handle.writeLine("PANIC " .. tostring(Err))
		Handle.close()
	end
	-- Unattended servers restart themselves so storage comes back without anyone present.
	local Remaining = 30
	local Timer = os.startTimer(1)
	while (true) do
		local _, H = term.getSize()
		term.setCursorPos(2, H - 1)
		term.clearLine()
		write(" Restarting automatically in " .. Remaining .. "s")
		local Event, A = os.pullEventRaw()
		if (Event == "timer" and A == Timer) then
			Remaining = Remaining - 1
			if (Remaining <= 0) then os.reboot() end
			Timer = os.startTimer(1)
		elseif (Event == "key" and A == keys.r) then
			os.reboot()
		elseif (Event == "key" and A == keys.s) then
			term.setBackgroundColor(colors.black)
			term.clear()
			term.setCursorPos(1, 1)
			return
		end
	end
end

-- Logo, name and a line of progress while the services start.
local function BootScreen(Step)
	if (not term.isColor()) then
		print("BlockOS Server: " .. Step)
		return
	end
	local Logo = BlockOS.Require("logo")
	local W, H = term.getSize()
	local LogoW, LogoH = Logo.Size(Logo.Big)
	local Y = math.max(1, math.floor((H - LogoH - 4) / 2))
	term.setBackgroundColor(colors.black)
	term.clear()
	Logo.Draw(term.current(), math.floor((W - LogoW) / 2) + 1, Y, Logo.Big)
	local Gfx = BlockOS.Require("gfx")
	Gfx.Center(term.current(), Y + LogoH + 1, "BlockOS Server", colors.white, colors.black)
	Gfx.Center(term.current(), Y + LogoH + 3, Step, colors.gray, colors.black)
	Gfx.Center(term.current(), H, "Press S for a recovery shell", colors.gray, colors.black)
end

local function WantsRecovery()
	local Timer = os.startTimer(.6)
	while (true) do
		local Event, A = os.pullEventRaw()
		if (Event == "timer" and A == Timer) then return false end
		if ((Event == "key" and A == keys.s) or (Event == "char" and A == "s")) then return true end
	end
end

-- Services plus a plain CraftOS shell: used on basic computers and for recovery.
local function RunHeadless(Runtime, Reason)
	term.setBackgroundColor(colors.black)
	term.setTextColor(colors.white)
	term.clear()
	term.setCursorPos(1, 1)
	local Server = BlockOS.Require("server/config")
	local Settings = Server.Settings()
	print("BlockOS Server " .. Server.Version() .. " - " .. Reason)
	print(Settings.Hostname .. " (computer #" .. os.getComputerID() .. "), storage " .. Settings.StorageRoot)
	print("BlockCloud services are running. Type 'bcloud' for")
	print("server commands, 'reboot' to restart.")
	parallel.waitForAny(function()
		Runtime.Run()
	end, function()
		while (true) do
			Shell.run("/rom/programs/shell.lua")
			print("The shell exited; the services are still running. Press any key for a new shell.")
			os.pullEvent("key")
		end
	end)
end

local Ok, Err = pcall(function()
	local Config = BlockOS.Require("config")
	BlockOS.Version = Config.Version()
	math.randomseed(os.epoch("utc") + os.getComputerID())
	local Server = BlockOS.Require("server/config")
	Server.ConfigureUpdater()

	if (not Server.Settings().Configured) then
		local Setup = BlockOS.Load("/blockos/server/setup.lua")
		if (term.isColor()) then
			Setup.Run({ Mode = "firstboot" })
		else
			Setup.RunText()
		end
	end

	for _, Dir in ipairs({ "/blockos/bin", "/blockos/server/bin" }) do
		if (not Shell.path():find(Dir, 1, true)) then
			Shell.setPath(Shell.path() .. ":" .. Dir)
		end
	end

	BootScreen("Starting services...")
	-- Asked before the services start, so no network message is missed while waiting.
	local Recovery = term.isColor() and WantsRecovery()
	local Runtime = BlockOS.Require("server/init")
	Runtime.Start()
	if (not term.isColor() or Recovery) then
		RunHeadless(Runtime, Recovery and "recovery shell" or "headless mode")
		return
	end
	local Host = BlockOS.Load("/blockos/server/ui/host.lua")
	Host.Start(Shell)
	Runtime.Run(Host)
end)

if (not Ok) then
	Panic(Err)
end
