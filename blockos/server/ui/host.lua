-- Server Edition app host: runs the admin console, Finder (the only graphical app) and admin
-- shells, one full-screen at a time under a BlockOS-style title bar. Much lighter than the
-- desktop window manager: no dock, Launchpad, animations or overlapping windows.

local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")
local Apps = BlockOS.Require("apps")
local Log = BlockOS.Require("server/log")

local Host = {}

local Native, RootShell
local W, H = 51, 19
local Console = nil
local Procs = {}
local Front = nil
local CurrentProc = nil
local NextID = 1
local Fake

Host.Locked = false
Host.LastInput = os.clock()

local InputEvents = {
	mouse_click = true, mouse_drag = true, mouse_up = true, mouse_scroll = true,
	key = true, key_up = true, char = true, paste = true
}

local function Visible()
	return Front or Console
end

local function DrawBar()
	if (not Front) then return end
	local Th = Theme.Get()
	Gfx.Fill(Native, 1, 1, W, 1, Th.TopbarBg)
	Gfx.Write(Native, 1, 1, " x ", colors.white, Th.Close)
	Gfx.Write(Native, 5, 1, "\17 Console", Th.Accent, Th.TopbarBg)
	local Title = Gfx.Truncate(Front.Title, W - 22)
	Gfx.Write(Native, math.floor((W - #Title) / 2) + 1, 1, Title, Th.TopbarFg, Th.TopbarBg)
	local Clock = textutils.formatTime(os.time("local"), true)
	Gfx.Write(Native, W - #Clock, 1, Clock, Th.TopbarDim, Th.TopbarBg)
end

local function Show()
	for _, Proc in ipairs(Procs) do
		Proc.Window.setVisible(Proc == Front)
	end
	if (Console) then Console.Window.setVisible(Front == nil) end
	if (not Console and not Front) then return end
	DrawBar()
	local Target = Visible()
	if (Target) then
		Target.Window.redraw()
		Target.Window.restoreCursor()
	end
end

local function Remove(Proc)
	for Index, Other in ipairs(Procs) do
		if (Other == Proc) then
			table.remove(Procs, Index)
			break
		end
	end
	Proc.Dead = true
	Proc.Window.setVisible(false)
	if (Front == Proc) then Front = Procs[#Procs] end
	Show()
end

local function Resume(Proc, ...)
	if (Proc.Dead) then return end
	local Name = ...
	if (Name and Proc.Filter and Proc.Filter ~= Name and Name ~= "terminate") then return end
	local Previous = term.redirect(Proc.Window)
	local PreviousProc = CurrentProc
	CurrentProc = Proc
	local Ok, Result = coroutine.resume(Proc.Co, ...)
	CurrentProc = PreviousProc
	term.redirect(Previous)
	if (not Ok) then
		Log.Error("ui", Proc.Title .. ": " .. tostring(Result))
		if (Proc == Console) then
			error(Result, 0)
		end
		Remove(Proc)
	elseif (coroutine.status(Proc.Co) == "dead" or Proc.Closing) then
		if (Proc == Console) then
			error("The console exited", 0)
		end
		Remove(Proc)
	else
		Proc.Filter = Result
	end
end

local function Spawn(Opts)
	local Proc = { ID = NextID, Title = Opts.Title, AppID = Opts.AppID }
	NextID = NextID + 1
	if (Opts.Console) then
		Proc.Window = window.create(Native, 1, 1, W, H, true)
	else
		Proc.Window = window.create(Native, 1, 2, W, H - 1, false)
	end
	Proc.Co = coroutine.create(Opts.Fn)
	if (Opts.Console) then
		Console = Proc
	else
		table.insert(Procs, Proc)
		Front = Proc
		Show()
	end
	Resume(Proc)
	return Proc
end

local function Quote(Arg)
	Arg = tostring(Arg)
	if (Arg == "" or Arg:find("[%s\"]")) then
		return "\"" .. Arg:gsub("\"", "") .. "\""
	end
	return Arg
end

-- Runs a program in a fresh CraftOS shell so it gets its own shell API, like the desktop does.
local function ProgramFn(Path, Args, Hold)
	return function()
		local List = { "/blockos/sys/run.lua", Hold and "hold" or "nohold", Quote(Path) }
		for _, Arg in ipairs(Args or {}) do
			table.insert(List, Quote(Arg))
		end
		os.run({ shell = RootShell, multishell = Fake }, "/rom/programs/shell.lua", table.unpack(List))
	end
end

local function Post(Proc, ...)
	Resume(Proc, ...)
end

local function Find(AppID)
	for _, Proc in ipairs(Procs) do
		if (Proc.AppID == AppID) then return Proc end
	end
	return nil
end

function Host.Launch(Target, Args, Opts)
	Opts = Opts or {}
	if (Host.Locked) then return nil, "The console is locked" end
	if (Target == "finder") then
		local Existing = Find("finder")
		if (Existing) then
			Front = Existing
			Show()
			if (Args and Args[1]) then Post(Existing, "blockos_open", Args[1]) end
			return Existing.ID
		end
		local App = Apps.Get("finder")
		return Spawn({ Title = "Finder", AppID = "finder", Fn = ProgramFn(App.Path, Args, false) }).ID
	elseif (Target == "terminal" or Target == "shell") then
		local Dir = Args and Args[1]
		return Spawn({ Title = "Shell", AppID = "shell", Fn = function()
			term.setBackgroundColor(colors.black)
			term.clear()
			term.setCursorPos(1, 1)
			term.setTextColor(colors.yellow)
			print("BlockOS Server shell. 'bcloud' manages the server;")
			print("'exit' returns to the console.")
			term.setTextColor(colors.white)
			local Env = { shell = RootShell, multishell = Fake }
			if (Dir and fs.isDir(Dir)) then
				os.run(Env, "/rom/programs/shell.lua", "/rom/programs/cd.lua", Dir)
			end
			os.run(Env, "/rom/programs/shell.lua")
		end }).ID
	elseif (Target == "editor" or Target == "edit") then
		local Path = Args and Args[1]
		if (not Path) then return nil, "No file given" end
		return Spawn({ Title = "Edit " .. fs.getName(Path), AppID = "edit", Fn = ProgramFn("/rom/programs/edit.lua", { Path }, false) }).ID
	end
	local Path = type(Target) == "string" and Target
	if (Path and not fs.exists(Path)) then Path = RootShell.resolveProgram(Path) end
	if (Path and fs.exists(Path) and not fs.isDir(Path)) then
		return Spawn({ Title = fs.getName(Path), Fn = ProgramFn(Path, Args, Opts.Hold ~= false) }).ID
	end
	return nil, tostring(Target) .. " is not available on BlockOS Server"
end

-- Folders open in Finder; files open in the CraftOS editor (nothing runs by accident).
function Host.Open(Path)
	if (not fs.exists(Path)) then return false end
	if (fs.isDir(Path)) then
		Host.Launch("finder", { Path })
	else
		Host.Launch("editor", { Path })
	end
	return true
end

function Host.ShowConsole()
	Front = nil
	Show()
end

function Host.Apps()
	return Procs
end

-- Locking hides every app until the administrator unlocks the console.
function Host.SetLocked(Locked)
	Host.Locked = Locked
	if (Locked) then Front = nil end
	Show()
end

local function InstallAPI()
	BlockOS.Desktop = false
	BlockOS.Shell = RootShell
	BlockOS.Clipboard = BlockOS.Clipboard or {}
	BlockOS.Launch = Host.Launch
	BlockOS.Open = Host.Open
	BlockOS.ShowConsole = Host.ShowConsole
	BlockOS.Notify = function(Title, Text)
		Log.Info("notice", tostring(Title) .. ": " .. tostring(Text))
	end
	BlockOS.SetTitle = function(Title)
		if (CurrentProc and CurrentProc ~= Console) then
			CurrentProc.Title = tostring(Title)
			DrawBar()
		end
	end
	BlockOS.Current = function()
		local Proc = CurrentProc
		if (not Proc) then return nil end
		return { ID = Proc.ID, AppID = Proc.AppID, Title = Proc.Title, Fullscreen = true, Focused = Proc == Visible() }
	end
	BlockOS.IsFocused = function() return CurrentProc ~= nil and CurrentProc == Visible() end
	BlockOS.SetFullscreen = function() end
	BlockOS.Minimize = function() Host.ShowConsole() end
	BlockOS.Quit = function()
		if (CurrentProc and CurrentProc ~= Console) then CurrentProc.Closing = true end
	end
	BlockOS.SetCloseHandler = function(Value)
		if (CurrentProc) then CurrentProc.CloseHandler = Value and true or nil end
	end
	BlockOS.Processes = function()
		local List = {}
		for _, Proc in ipairs(Procs) do
			table.insert(List, { ID = Proc.ID, AppID = Proc.AppID, Title = Proc.Title })
		end
		return List
	end
	BlockOS.Restart = function() os.reboot() end
	BlockOS.Shutdown = function() os.shutdown() end
	BlockOS.ScreenSize = function() return W, H end
	Fake = {
		getCurrent = function() return CurrentProc and CurrentProc.ID or 0 end,
		getCount = function() return #Procs end,
		getFocus = function() return Front and Front.ID or 0 end,
		setFocus = function() return false end,
		getTitle = function(ID)
			for _, Proc in ipairs(Procs) do if (Proc.ID == ID) then return Proc.Title end end
		end,
		setTitle = function(ID, Title)
			for _, Proc in ipairs(Procs) do if (Proc.ID == ID) then Proc.Title = tostring(Title) end end
			DrawBar()
		end,
		launch = function(Env, Path, ...)
			local Args = table.pack(...)
			return Spawn({ Title = fs.getName(Path), Fn = function() os.run(Env, Path, table.unpack(Args, 1, Args.n)) end }).ID
		end
	}
	BlockOS.Multishell = Fake
end

local function CloseFront()
	local Proc = Front
	if (not Proc) then return end
	if (Proc.CloseHandler) then
		Resume(Proc, "blockos_close")
	else
		Remove(Proc)
	end
end

function Host.Start(Shell)
	RootShell = Shell
	Native = term.current()
	W, H = Native.getSize()
	InstallAPI()
	Spawn({ Title = "Console", Console = true, Fn = function()
		BlockOS.Load("/blockos/server/ui/console.lua", Host)
	end })
	Show()
end

-- Called by the runtime with every event, after the services have seen it.
function Host.Dispatch(Event)
	local Name = Event[1]
	if (not Console) then
		-- The console kept crashing: wait for R to try again. Services are unaffected.
		if (Name == "key" and Event[2] == keys.r) then
			Host.Crashes = {}
			Host.Recover()
		end
		return
	end
	if (InputEvents[Name]) then
		Host.LastInput = os.clock()
		if (Front and Name == "mouse_click" and Event[4] == 1) then
			if (Event[3] <= 3) then
				CloseFront()
			elseif (Event[3] <= 13) then
				Host.ShowConsole()
			end
			return
		end
		local Target = Visible()
		if (Front and (Name == "mouse_click" or Name == "mouse_drag" or Name == "mouse_up" or Name == "mouse_scroll")) then
			if (Event[4] < 2) then return end
			Resume(Target, Name, Event[2], Event[3], Event[4] - 1)
		else
			Resume(Target, table.unpack(Event, 1, Event.n))
		end
	elseif (Name == "terminate") then
		-- Ctrl+T stops a program in the shell or closes Finder, but never the console.
		if (Front) then Resume(Front, "terminate") end
	elseif (Name == "term_resize") then
		W, H = Native.getSize()
		Console.Window.reposition(1, 1, W, H)
		for _, Proc in ipairs(Procs) do
			Proc.Window.reposition(1, 2, W, H - 1)
		end
		Resume(Console, "term_resize")
		for _, Proc in ipairs({ table.unpack(Procs) }) do Resume(Proc, "term_resize") end
		Show()
	else
		Resume(Console, table.unpack(Event, 1, Event.n))
		for _, Proc in ipairs({ table.unpack(Procs) }) do
			Resume(Proc, table.unpack(Event, 1, Event.n))
		end
		if (Front and Name == "timer") then DrawBar() end
	end
	local Target = Visible()
	if (Target and not Target.Dead) then Target.Window.restoreCursor() end
end

Host.Crashes = {}

-- If the console crashes, start a fresh one; the services were never affected.
function Host.Recover()
	Console = nil
	Front = nil
	local Now = os.clock()
	table.insert(Host.Crashes, Now)
	while (Host.Crashes[1] and Now - Host.Crashes[1] > 60) do table.remove(Host.Crashes, 1) end
	if (#Host.Crashes > 3) then
		Log.Error("ui", "The console keeps crashing; showing the fallback screen")
		term.redirect(Native)
		Native.setBackgroundColor(colors.black)
		Native.setTextColor(colors.white)
		Native.clear()
		Native.setCursorPos(1, 1)
		print("BlockOS Server: the console keeps crashing.")
		print("BlockCloud services are still running.")
		print("Details: /blockos/data/cloud/logs/server.log")
		print()
		print("Press R to try again, or reboot holding S on the")
		print("boot screen for a recovery shell.")
		return
	end
	Log.Warn("ui", "Restarting the console")
	Spawn({ Title = "Console", Console = true, Fn = function()
		BlockOS.Load("/blockos/server/ui/console.lua", Host)
	end })
	Show()
end

return Host
