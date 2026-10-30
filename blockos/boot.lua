-- BlockOS boot: installs the global BlockOS API, runs first-time setup and starts the desktop.

local Shell = shell
local Loaded = {}
local Fresh = { ui = true }

_G.BlockOS = { Root = "/blockos" }

function BlockOS.Load(Path, ...)
	local Fn, Err = loadfile(Path, nil, _G)
	if (not Fn) then error(Err, 2) end
	return Fn(...)
end

-- Libraries are shared between apps, except those with per-app state (the UI toolkit).
function BlockOS.Require(Name)
	if (Loaded[Name]) then return Loaded[Name] end
	local Module = BlockOS.Load("/blockos/lib/" .. Name .. ".lua")
	if (not Fresh[Name]) then
		Loaded[Name] = Module
	end
	return Module
end

local function Panic(Err)
	term.redirect(term.native())
	if (term.nativePaletteColor) then
		for Index = 0, 15 do
			term.setPaletteColor(2 ^ Index, term.nativePaletteColor(2 ^ Index))
		end
	end
	term.setBackgroundColor(colors.blue)
	term.setTextColor(colors.white)
	term.clear()
	local W, H = term.getSize()
	term.setCursorPos(2, 2)
	print(" :(  BlockOS ran into a problem.")
	print()
	term.setTextColor(colors.lightBlue)
	print(" " .. tostring(Err))
	print()
	term.setTextColor(colors.white)
	print(" [R] Restart    [S] Recovery shell")
	print(" Details were saved to /blockos/data/log.txt")
	local Handle = fs.open("/blockos/data/log.txt", "a")
	if (Handle) then
		Handle.writeLine("PANIC " .. tostring(Err))
		Handle.close()
	end
	while (true) do
		local _, Key = os.pullEvent("key")
		if (Key == keys.r) then
			os.reboot()
		elseif (Key == keys.s) then
			term.setBackgroundColor(colors.black)
			term.clear()
			term.setCursorPos(1, 1)
			return
		end
	end
end

if (not term.isColor()) then
	print("BlockOS needs an Advanced Computer or Advanced Turtle.")
	return
end

-- Carries settings and files over from older releases.
local function Migrate(Config)
	if (fs.exists("/blockos/apps/btunes") and fs.exists("/blockos/apps/musicstream")) then
		fs.delete("/blockos/apps/musicstream")
	end
	local Settings = Config.Settings()
	local Changed = false
	for _, List in ipairs({ Settings.Dock or {}, Settings.StartupApps or {} }) do
		for Index, ID in ipairs(List) do
			if (ID == "musicstream") then
				List[Index] = "btunes"
				Changed = true
			end
		end
	end
	if (Changed) then
		local HasNotes = false
		for _, ID in ipairs(Settings.Dock or {}) do
			if (ID == "notes") then HasNotes = true end
		end
		for Index, ID in ipairs(Settings.Dock or {}) do
			if (ID == "btunes" and not HasNotes) then
				table.insert(Settings.Dock, Index, "notes")
				break
			end
		end
		Config.Save("settings")
	end
end

local Ok, Err = pcall(function()
	local Config = BlockOS.Require("config")
	BlockOS.Version = Config.Version()
	Migrate(Config)
	math.randomseed(os.epoch("utc") + os.getComputerID())

	local Users = BlockOS.Require("users")
	local Gfx = BlockOS.Require("gfx")
	if (Users.HasAny()) then
		BlockOS.Load("/blockos/sys/splash.lua").Run(term.current())
	else
		BlockOS.Load("/blockos/sys/setup.lua").Run({ Mode = "firstboot" })
	end
	if (not Config.Settings().Animations) then
		Gfx.SetFade(term.current(), 1)
	end

	if (not Shell.path():find("/blockos/bin", 1, true)) then
		Shell.setPath(Shell.path() .. ":/blockos/bin")
	end
	local Desktop = BlockOS.Load("/blockos/sys/desktop.lua")
	Desktop.Run(Shell)
end)

if (not Ok) then
	Panic(Err)
end
