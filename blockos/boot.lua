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

local Ok, Err = pcall(function()
	local Config = BlockOS.Require("config")
	BlockOS.Version = Config.Version()
	math.randomseed(os.epoch("utc") + os.getComputerID())

	local Users = BlockOS.Require("users")
	if (not Users.HasAny()) then
		BlockOS.Load("/blockos/sys/setup.lua").Run({ Mode = "firstboot" })
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
