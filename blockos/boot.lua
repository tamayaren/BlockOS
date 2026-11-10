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
	-- Calculator moved from the App Store into BlockOS; drop the old store copy.
	if (fs.exists("/blockos/apps/calculator") and fs.exists("/blockos/userapps/calculator")) then
		fs.delete("/blockos/userapps/calculator")
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
	-- Savannah ships with BlockOS 1.6.0: put it in the dock once, next to Launchpad.
	if (not Settings.SavannahDocked) then
		Settings.SavannahDocked = true
		local Docked, After = false, 0
		for Index, ID in ipairs(Settings.Dock) do
			if (ID == "savannah") then Docked = true end
			if (ID == "launchpad" or ID == "finder") then After = math.max(After, Index) end
		end
		if (not Docked) then table.insert(Settings.Dock, After + 1, "savannah") end
		Config.Save("settings")
	end
end

-- Packs system files and apps that are still stored as plain text, once per installed version.
local function Optimize(Compress)
	local W, H = term.getSize()
	term.setBackgroundColor(colors.black)
	term.setTextColor(colors.white)
	term.clear()
	local Title = "Optimizing storage..."
	term.setCursorPos(math.floor((W - #Title) / 2) + 1, math.floor(H / 2))
	term.write(Title)
	term.setTextColor(colors.lightGray)
	Compress.Compact(function(Done, Total)
		local Text = math.floor(Done / math.max(Total, 1) * 100) .. "%"
		term.setCursorPos(math.floor((W - #Text) / 2) + 1, math.floor(H / 2) + 2)
		term.clearLine()
		term.write(Text)
	end)
end

local Ok, Err = pcall(function()
	-- Packed files have to be readable before anything else is loaded.
	local Compress = BlockOS.Require("compress")
	Compress.Hook()
	local Config = BlockOS.Require("config")
	BlockOS.Version = Config.Version()
	Migrate(Config)
	local Settings = Config.Settings()
	Compress.Enabled = Settings.Compression
	if (Settings.Compression and Settings.Compacted ~= BlockOS.Version) then
		Optimize(Compress)
		Settings.Compacted = BlockOS.Version
		Config.Save("settings")
	end
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
