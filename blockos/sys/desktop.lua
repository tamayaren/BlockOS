-- BlockOS desktop: a compositing window manager with a macOS-style topbar, dock,
-- launchpad, notifications and lock screen. Every window runs a program in its own
-- coroutine; the focused window draws straight through while the rest are composited.

local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")
local Config = BlockOS.Require("config")
local Apps = BlockOS.Require("apps")
local Wallpaper = BlockOS.Require("wallpaper")
local Users = BlockOS.Require("users")
local Login = BlockOS.Load("/blockos/sys/login.lua")

local Desktop = {}

local MinW, MinH = 14, 4
local FrameTime = .05
local LogPath = "/blockos/data/log.txt"

local Native, Screen, Hidden
local ScreenW, ScreenH = 51, 19
local RootShell

local Processes = {}
local Services = {}
local Focused = nil
local CurrentProc = nil
local NextID = 1
local Running = true
local SessionStarted = false

local Menu = nil
local Dialog = nil
local Launchpad = { Open = false, Query = "", Page = 1, Regions = {} }
local Toasts = {}
local History = {}
local Drag = nil
local MouseTarget = nil
local RevealUntil = nil
local Locked = false
local LockScreen = nil
local Modifiers = {}
local RedrawTimer = nil
local ClockTimer = nil
local LastInput = os.clock()
local AppCache = {}
local TopbarRegions = {}
local DockRegions = {}
local LastTitleClick = { Time = 0 }
local Recording = false
local AnimationQueue = {}
local Deferred = {}
local Ghost = nil
local PendingLock = false
local PendingUnlock = false
local FadeLevel = 1
local FullscreenHinted = false

local Redraw, ScheduleRedraw, Focus, Launch, Notify, Lock, CloseProc, Kill, OpenMenu, Multishell

local ModifierKeys = {
	[keys.leftCtrl] = "Ctrl", [keys.rightCtrl] = "Ctrl",
	[keys.leftShift] = "Shift", [keys.rightShift] = "Shift",
	[keys.leftAlt] = "Alt", [keys.rightAlt] = "Alt"
}

local InputEvents = {
	mouse_click = true, mouse_drag = true, mouse_up = true, mouse_scroll = true,
	key = true, key_up = true, char = true, paste = true
}

local function Log(Text)
	local Handle = fs.open(LogPath, fs.exists(LogPath) and fs.getSize(LogPath) < 16384 and "a" or "w")
	if (not Handle) then return end
	Handle.writeLine(os.date("%Y-%m-%d %H:%M:%S ") .. tostring(Text))
	Handle.close()
end

local function Copy(List)
	local Result = {}
	for Index, Item in ipairs(List) do
		Result[Index] = Item
	end
	return Result
end

local function RefreshApps()
	AppCache = Apps.All()
end

-- The small dock shows one row of icons with the running indicator below it.
local function DockHeight()
	return (Config.Settings().DockSize == "large") and 3 or 2
end

local function DockTop()
	return ScreenH - DockHeight() + 1
end

-- Usable window area between the topbar and dock: X, Y, W, H.
local function WorkArea()
	return 1, 2, ScreenW, ScreenH - DockHeight() - 1
end

local function AnimationsEnabled()
	return Config.Settings().Animations ~= false
end

-- Dims the whole screen; 1 is normal colours, 0 is black.
local function SetFadeLevel(Level)
	if (not Gfx.SetFade(Screen, Level)) then return false end
	FadeLevel = Level
	return true
end

-- Animations run from the desktop's main loop, never inside an app's coroutine.
local function QueueAnimation(Animation)
	if (not AnimationsEnabled()) then return false end
	table.insert(AnimationQueue, Animation)
	return true
end

local function HintFullscreen()
	if (FullscreenHinted) then return end
	FullscreenHinted = true
	Notify("Full Screen", "Right click on an empty space on top to show window buttons.", { Sound = false, Duration = 7 })
end

local function WindowRect(Proc)
	if (Proc.Fullscreen) then
		return { 1, 1, ScreenW, ScreenH }
	end
	return { Proc.X, Proc.Y, Proc.W, Proc.H }
end

local function FocusedFullscreen()
	return Focused ~= nil and Focused.Fullscreen and not Focused.Minimized
end

local function RevealActive()
	return RevealUntil ~= nil and os.clock() < RevealUntil
end

local function ContentRect(Proc)
	if (Proc.Fullscreen) then
		return 1, 1, ScreenW, ScreenH
	end
	return Proc.X, Proc.Y + 1, Proc.W, Proc.H - 1
end

local function ClampWindow(Proc)
	local _, AreaY, AreaW, AreaH = WorkArea()
	Proc.W = math.max(MinW, math.min(Proc.W, AreaW))
	Proc.H = math.max(MinH, math.min(Proc.H, AreaH))
	Proc.X = math.max(1, math.min(Proc.X, AreaW - Proc.W + 1))
	Proc.Y = math.max(AreaY, math.min(Proc.Y, AreaY + AreaH - Proc.H))
end

local function ApplyGeometry(Proc)
	local X, Y, W, H = ContentRect(Proc)
	local OldW, OldH = Proc.Window.getSize()
	Proc.Window.reposition(X, Y, W, H)
	if (OldW ~= W or OldH ~= H) then
		Proc.PendingResize = true
	end
end

local function Show(Proc)
	if (Proc.Shown) then
		Proc.Window.redraw()
	else
		Proc.Window.setVisible(true)
		Proc.Shown = true
	end
end

local function Hide(Proc)
	Proc.Live = false
	if (Proc.Shown) then
		Proc.Window.setVisible(false)
		Proc.Shown = false
	end
end

local function Post(Proc, ...)
	Proc.Inbox = Proc.Inbox or {}
	table.insert(Proc.Inbox, table.pack(...))
end

local function TopVisible()
	for Index = #Processes, 1, -1 do
		if (not Processes[Index].Minimized) then
			return Processes[Index]
		end
	end
	return nil
end

local function FindProc(ID)
	for _, Proc in ipairs(Processes) do
		if (Proc.ID == ID) then return Proc end
	end
	return nil
end

local function ProcsOf(AppID)
	local Result = {}
	for _, Proc in ipairs(Processes) do
		if (Proc.AppID == AppID) then
			table.insert(Result, Proc)
		end
	end
	return Result
end

--
-- Process management
--

local Mutators = { write = true, blit = true, clear = true, clearLine = true, scroll = true }

-- Wraps a window so that drawing from a background window schedules a composite.
local function MakeProxy(Proc)
	local Proxy = {}
	for Name, Fn in pairs(Proc.Window) do
		if (Mutators[Name]) then
			Proxy[Name] = function(...)
				if (not Proc.Live and not Proc.Minimized) then
					ScheduleRedraw()
				end
				return Fn(...)
			end
		else
			Proxy[Name] = Fn
		end
	end
	Proxy.setVisible = function(Visible)
		Proc.AppHidden = not Visible
		if (Proc.Live) then
			Proc.Window.setVisible(Visible)
			Proc.Shown = Visible
		elseif (Visible) then
			ScheduleRedraw()
		end
	end
	Proxy.reposition = function() end
	return Proxy
end

local function Crash(Proc, Err)
	Proc.Dead = true
	Proc.Title = Proc.Title .. " (crashed)"
	Log((Proc.AppID or Proc.Title) .. ": " .. tostring(Err))
	local T = Proc.Window
	local W, H = T.getSize()
	T.setBackgroundColor(colors.black)
	T.clear()
	T.setTextColor(colors.red)
	local Lines = Gfx.Wrap("This app quit unexpectedly:\n" .. tostring(Err), W - 2)
	for Row = 1, math.min(#Lines, H - 2) do
		T.setCursorPos(2, Row + 1)
		T.write(Lines[Row])
	end
	T.setTextColor(colors.lightGray)
	T.setCursorPos(2, H)
	T.write(Gfx.Truncate("Click or press a key to close", W - 2))
	T.setCursorBlink(false)
	ScheduleRedraw()
end

local function Resume(Proc, Name, ...)
	if (Proc.Dead or Proc.PendingStart and Name) then return end
	if (Name and Proc.Filter and Proc.Filter ~= Name and Name ~= "terminate") then return end
	local Previous = term.redirect(Proc.Redirect)
	local PreviousProc = CurrentProc
	CurrentProc = Proc
	local Ok, Result
	if (Name) then
		Ok, Result = coroutine.resume(Proc.Co, Name, ...)
	else
		Ok, Result = coroutine.resume(Proc.Co)
	end
	CurrentProc = PreviousProc
	Proc.Redirect = term.current()
	term.redirect(Previous)
	if (Proc.Service) then
		if (not Ok or coroutine.status(Proc.Co) == "dead") then
			if (not Ok) then Log(Proc.Name .. ": " .. tostring(Result)) end
			Proc.Dead = true
			for Index, Other in ipairs(Services) do
				if (Other == Proc) then
					table.remove(Services, Index)
					break
				end
			end
		else
			Proc.Filter = Result
		end
		return
	end
	if (not Ok) then
		Crash(Proc, Result)
	elseif (Proc.Closing or coroutine.status(Proc.Co) == "dead") then
		Kill(Proc)
	else
		Proc.Filter = Result
	end
end

function Kill(Proc)
	for Index, Other in ipairs(Processes) do
		if (Other == Proc) then
			table.remove(Processes, Index)
			break
		end
	end
	Proc.Dead = true
	Hide(Proc)
	if (MouseTarget == Proc) then MouseTarget = nil end
	if (Drag and Drag.Proc == Proc) then Drag = nil end
	if (Focused == Proc) then Focused = TopVisible() end
	Redraw()
end

function CloseProc(Proc)
	if (not Proc) then return end
	if (Proc.CloseHandler and not Proc.Dead) then
		Post(Proc, "blockos_close")
		return
	end
	Kill(Proc)
end

local function Spawn(Opts)
	local _, AreaY, AreaW, AreaH = WorkArea()
	local Proc = {
		ID = NextID,
		Title = Opts.Title or "Untitled",
		AppID = Opts.AppID,
		Icon = Opts.Icon,
		AllowTitle = Opts.AllowTitle,
		PendingStart = true,
		Live = false
	}
	NextID = NextID + 1
	Proc.W = Opts.Width or math.min(40, AreaW - 4)
	Proc.H = Opts.Height or math.min(14, AreaH)
	local Count = #Processes
	Proc.X = math.floor((AreaW - Proc.W) / 2) + 1 + (Count % 4) * 2 - 3
	Proc.Y = AreaY + (Count % 3)
	ClampWindow(Proc)
	Proc.Fullscreen = Opts.Mode == "fullscreen"
	if (Proc.Fullscreen) then HintFullscreen() end
	local X, Y, W, H = ContentRect(Proc)
	Proc.Window = window.create(Screen, X, Y, W, H, false)
	-- Windows copy their parent's palette, so one made mid-fade would keep the dimmed colours.
	if (FadeLevel < 1) then Gfx.SetFade(Proc.Window, 1) end
	Proc.Term = MakeProxy(Proc)
	Proc.Redirect = Proc.Term
	Proc.Co = coroutine.create(Opts.Fn)
	table.insert(Processes, Proc)
	if (QueueAnimation({ Kind = "open", Proc = Proc, From = Opts.From })) then
		Proc.Opening = true
	end
	Focus(Proc)
	return Proc
end

local function Quote(Arg)
	Arg = tostring(Arg)
	if (Arg == "" or Arg:find("[%s\"]")) then
		return "\"" .. Arg:gsub("\"", "") .. "\""
	end
	return Arg
end

-- Runs a program inside a fresh CraftOS shell so it gets its own shell API and require.
local function ProgramFn(Path, Args, Hold)
	return function()
		local Env = { shell = RootShell, multishell = Multishell }
		local List = { "/blockos/sys/run.lua", Hold and "hold" or "nohold", Quote(Path) }
		for _, Arg in ipairs(Args or {}) do
			table.insert(List, Quote(Arg))
		end
		os.run(Env, "/rom/programs/shell.lua", table.unpack(List))
	end
end

local function LaunchpadSeed()
	local W, H = math.max(3, math.floor(ScreenW / 6)), math.max(2, math.floor(ScreenH / 6))
	return { math.floor((ScreenW - W) / 2) + 1, math.floor((ScreenH - H) / 2) + 1, W, H }
end

local function CloseLaunchpad()
	if (not Launchpad.Open) then return end
	if (not QueueAnimation({ Kind = "launchpad" })) then
		Launchpad.Open = false
		Redraw()
	end
end

local function ToggleLaunchpad()
	Menu = nil
	if (Launchpad.Open) then
		CloseLaunchpad()
		return
	end
	Launchpad.Open = true
	Launchpad.Query = ""
	Launchpad.Page = 1
	if (QueueAnimation({ Kind = "launchpad", Opening = true })) then
		Launchpad.Rect = LaunchpadSeed()
	end
	Redraw()
end

function Launch(Target, Args, Opts)
	Opts = Opts or {}
	local App = AppCache[Target] or Apps.Get(Target)
	if (App) then
		if (App.Builtin == "launchpad") then
			ToggleLaunchpad()
			return nil
		end
		if (App.Single) then
			local Existing = ProcsOf(App.ID)
			if (#Existing > 0) then
				Focus(Existing[#Existing])
				if (Args and #Args > 0) then
					Post(Existing[#Existing], "blockos_open", table.unpack(Args))
				end
				return Existing[#Existing].ID
			end
		end
		local Proc = Spawn({
			Title = App.Name,
			AppID = App.ID,
			Icon = App.Icon,
			Mode = Opts.Mode or App.Mode,
			Width = App.Width,
			Height = App.Height,
			AllowTitle = App.AllowTitle,
			From = Opts.From,
			Fn = ProgramFn(App.Path, Args, false)
		})
		return Proc.ID
	end
	local Path = Target
	if (type(Path) == "string" and not fs.exists(Path)) then
		Path = RootShell.resolveProgram(Path)
	end
	if (type(Path) == "string" and fs.exists(Path) and not fs.isDir(Path)) then
		local Proc = Spawn({
			Title = fs.getName(Path),
			AllowTitle = true,
			Mode = Opts.Mode,
			Fn = ProgramFn(Path, Args, Opts.Hold ~= false)
		})
		return Proc.ID
	end
	return nil, "Not found: " .. tostring(Target)
end

local function OpenFile(Path)
	if (not fs.exists(Path)) then return false end
	if (fs.isDir(Path)) then
		Launch("finder", { Path })
		return true
	end
	local Extension = Path:match("%.([%w]+)$")
	Extension = Extension and Extension:lower()
	if (Extension == "dfpwm") then
		Launch("btunes", { Path })
	elseif (Extension == "rec") then
		Launch("recorder", { Path })
	elseif (Extension == "txt" and AppCache.notes) then
		Launch("notes", { Path })
	elseif ((Extension == "bimg" or Extension == "nfp") and AppCache.brocreate) then
		Launch("brocreate", { Path })
	elseif (Extension == "lua" or not Extension) then
		Launch(Path, {}, { Hold = true })
	else
		Launch("editor", { Path })
	end
	return true
end

local function StartService(Name, Fn)
	local Service = {
		Name = Name,
		Service = true,
		Redirect = Hidden,
		Co = coroutine.create(function()
			local Ok, Err = pcall(Fn)
			if (not Ok) then Log(Name .. ": " .. tostring(Err)) end
		end)
	}
	table.insert(Services, Service)
	Resume(Service)
end

local function Broadcast(Event)
	for _, Proc in ipairs(Copy(Processes)) do
		if (not Proc.Dead and not Proc.PendingStart) then
			Resume(Proc, table.unpack(Event, 1, Event.n))
		end
	end
	for _, Service in ipairs(Copy(Services)) do
		Resume(Service, table.unpack(Event, 1, Event.n))
	end
end

local function SendMouse(Proc, Name, Button, X, Y)
	local CX, CY = ContentRect(Proc)
	Resume(Proc, Name, Button, X - CX + 1, Y - CY + 1)
end

local function FlushPending()
	for _ = 1, 8 do
		local Any = false
		for _, Proc in ipairs(Copy(Processes)) do
			if (not Proc.Dead and Proc.PendingStart) then
				Proc.PendingStart = nil
				Any = true
				Resume(Proc)
			end
			if (not Proc.Dead and Proc.PendingResize) then
				Proc.PendingResize = nil
				Any = true
				Resume(Proc, "term_resize")
			end
			while (not Proc.Dead and Proc.Inbox and #Proc.Inbox > 0) do
				local Event = table.remove(Proc.Inbox, 1)
				Any = true
				Resume(Proc, table.unpack(Event, 1, Event.n))
			end
		end
		if (not Any) then break end
	end
end

--
-- Window state
--

-- A window losing focus never sees the release of keys still held, so send it now.
local function ReleaseModifiers(Proc)
	if (not Proc or Proc.Dead) then return end
	if (Modifiers.Ctrl) then Post(Proc, "key_up", keys.leftCtrl) end
	if (Modifiers.Shift) then Post(Proc, "key_up", keys.leftShift) end
	if (Modifiers.Alt) then Post(Proc, "key_up", keys.leftAlt) end
end

function Focus(Proc)
	if (Focused and Focused ~= Proc) then
		ReleaseModifiers(Focused)
	end
	if (Proc) then
		if (Proc.Minimized and QueueAnimation({ Kind = "open", Proc = Proc })) then
			Proc.Opening = true
		end
		Proc.Minimized = false
		for Index, Other in ipairs(Processes) do
			if (Other == Proc) then
				table.remove(Processes, Index)
				break
			end
		end
		table.insert(Processes, Proc)
	end
	if (Focused ~= Proc) then
		RevealUntil = nil
	end
	Focused = Proc
	Redraw()
end

local function Minimize(Proc)
	if (not Proc or Proc.Minimized) then return end
	QueueAnimation({ Kind = "minimize", Proc = Proc, From = WindowRect(Proc) })
	Proc.Minimized = true
	Hide(Proc)
	if (Focused == Proc) then
		ReleaseModifiers(Proc)
		Focused = TopVisible()
	end
	Redraw()
end

local function ToggleFullscreen(Proc)
	if (not Proc) then return end
	Proc.Fullscreen = not Proc.Fullscreen
	if (Proc.Fullscreen) then HintFullscreen() end
	RevealUntil = nil
	if (not Proc.Fullscreen) then
		ClampWindow(Proc)
	end
	ApplyGeometry(Proc)
	Focus(Proc)
end

local function Zoom(Proc)
	if (not Proc or Proc.Fullscreen) then return end
	if (Proc.Saved) then
		Proc.X, Proc.Y, Proc.W, Proc.H = table.unpack(Proc.Saved)
		Proc.Saved = nil
	else
		Proc.Saved = { Proc.X, Proc.Y, Proc.W, Proc.H }
		local AreaX, AreaY, AreaW, AreaH = WorkArea()
		Proc.X, Proc.Y, Proc.W, Proc.H = AreaX, AreaY, AreaW, AreaH
	end
	ClampWindow(Proc)
	ApplyGeometry(Proc)
	Redraw()
end

local function RevealTopbar()
	RevealUntil = os.clock() + 3
	Redraw()
end

--
-- Drawing
--

local function DrawWallpaper()
	local Settings = Config.Settings()
	local Rows = Wallpaper.Render(Settings.Wallpaper, ScreenW, ScreenH, Settings.WallpaperColor, Settings.WallpaperImage)
	for Y = 1, ScreenH do
		Screen.setCursorPos(1, Y)
		Screen.blit(Rows[Y][1], Rows[Y][2], Rows[Y][3])
	end
end

local function DrawFrame(Proc, Th, Active, Row)
	local Y = Row or Proc.Y
	local X, W = Proc.X, Proc.W
	if (Proc.Fullscreen) then
		X, W = 1, ScreenW
	end
	local Bg = Active and Th.TitleBg or Th.TitleIdleBg
	local Fg = Active and Th.TitleFg or Th.TitleIdleFg
	Gfx.Fill(Screen, X, Y, W, 1, Bg)
	local Title = Gfx.Truncate(Proc.Title, W - 9)
	local TitleX = math.max(X + 8, X + math.floor((W - #Title) / 2))
	Gfx.Write(Screen, TitleX, Y, Title, Fg, Bg)
	local Lights = Active and { Th.Close, Th.Minimize, Th.Zoom } or { Th.TitleIdleFg, Th.TitleIdleFg, Th.TitleIdleFg }
	for Index, Color in ipairs(Lights) do
		Gfx.Write(Screen, X + Index * 2 - 1, Y, "\7", Color, Bg)
	end
end

local function FormatClock()
	local Settings = Config.Settings()
	if (Settings.ClockSource == "game") then
		return "Day " .. os.day() .. " " .. textutils.formatTime(os.time(), Settings.Clock24)
	end
	local Format = Settings.Clock24 and "%H:%M" or "%I:%M %p"
	if (Settings.ShowSeconds) then
		Format = Settings.Clock24 and "%H:%M:%S" or "%I:%M:%S %p"
	end
	return os.date("%a " .. Format)
end

local function UpdateStatus()
	local Ok, Updater = pcall(BlockOS.Require, "updater")
	if (not Ok) then return nil end
	return Updater.State.Status
end

local function UnreadMessages()
	local Ok, Chat = pcall(BlockOS.Require, "chat")
	if (not Ok or not Chat.Loaded) then return 0 end
	return Chat.UnreadTotal()
end

local function AppName()
	if (Focused) then
		local App = Focused.AppID and AppCache[Focused.AppID]
		return App and App.Name or Focused.Title
	end
	return "BlockOS"
end

local function DrawTopbar(Th)
	TopbarRegions = {}
	Gfx.Fill(Screen, 1, 1, ScreenW, 1, Th.TopbarBg)
	Screen.setCursorPos(2, 1)
	Screen.blit("\131", Gfx.ToBlit(colors.lime), Gfx.ToBlit(colors.brown))
	table.insert(TopbarRegions, { X = 1, W = 3, Menu = "logo" })
	local X = 4
	local Name = Gfx.Truncate(AppName(), 14)
	Gfx.Write(Screen, X, 1, Name, Th.TopbarFg, Th.TopbarBg)
	table.insert(TopbarRegions, { X = X - 1, W = #Name + 2, Menu = "app" })
	X = X + #Name + 2
	for _, Title in ipairs({ "Go", "Window" }) do
		if (X + #Title < ScreenW - 12) then
			Gfx.Write(Screen, X, 1, Title, Th.TopbarFg, Th.TopbarBg)
			table.insert(TopbarRegions, { X = X - 1, W = #Title + 2, Menu = Title:lower() })
			X = X + #Title + 2
		end
	end
	local Clock = FormatClock()
	local Right = ScreenW - #Clock
	Gfx.Write(Screen, Right, 1, Clock, Th.TopbarFg, Th.TopbarBg)
	table.insert(TopbarRegions, { X = Right, W = #Clock, Action = "clock" })
	local Status = UpdateStatus()
	if (Status == "available" or Status == "ready") then
		Right = Right - 3
		Gfx.Write(Screen, Right, 1, "\24", Th.Accent, Th.TopbarBg)
		table.insert(TopbarRegions, { X = Right - 1, W = 3, Action = "update" })
	end
	if (Recording) then
		Right = Right - 7
		Gfx.Write(Screen, Right, 1, "\7 REC", colors.red, Th.TopbarBg)
		table.insert(TopbarRegions, { X = Right - 1, W = 7, Action = "recording" })
	end
end

local function DockItems()
	local Items = {}
	local Seen = {}
	for _, ID in ipairs(Config.Settings().Dock) do
		local App = AppCache[ID]
		if (App and not Seen[ID]) then
			Seen[ID] = true
			table.insert(Items, { App = App, Pinned = true })
		end
	end
	for _, Proc in ipairs(Processes) do
		if (Proc.AppID and AppCache[Proc.AppID]) then
			if (not Seen[Proc.AppID]) then
				Seen[Proc.AppID] = true
				table.insert(Items, { App = AppCache[Proc.AppID] })
			end
		elseif (not Proc.AppID) then
			table.insert(Items, { Proc = Proc, Icon = { Lines = { ">_ ", "   " }, Fg = colors.lime, Bg = colors.black } })
		end
	end
	local Max = math.floor((ScreenW - 1) / 4)
	while (#Items > Max) do
		table.remove(Items)
	end
	return Items
end

local function ItemRunning(Item)
	if (Item.Proc) then return true, Focused == Item.Proc end
	local Windows = ProcsOf(Item.App.ID)
	return #Windows > 0, Focused ~= nil and Focused.AppID == Item.App.ID
end

-- Writes text over whatever is already on screen, keeping its background colours.
local function WriteOver(X, Y, Text, Fg)
	if (Y < 1 or Y > ScreenH or X < 1 or X + #Text - 1 > ScreenW) then return end
	local _, _, Bg = Screen.getLine(Y)
	Screen.setCursorPos(X, Y)
	Screen.blit(Text, string.rep(Gfx.ToBlit(Fg), #Text), Bg:sub(X, X + #Text - 1))
end

local function DrawDock(Th)
	local Settings = Config.Settings()
	local Clear = Settings.DockStyle == "transparent"
	local Height = DockHeight()
	local IconRows = Height - 1
	local Items = DockItems()
	local W = #Items * 4 + 1
	local X0 = math.floor((ScreenW - W) / 2) + 1
	local Top = DockTop()
	if (not Clear) then
		Gfx.Fill(Screen, X0, Top, W, Height, Th.DockBg)
	end
	DockRegions = {}
	local Unread = UnreadMessages()
	for Index, Item in ipairs(Items) do
		local X = X0 + 1 + (Index - 1) * 4
		local Icon = Item.App and Item.App.Icon or Item.Icon
		for Row = 1, IconRows do
			Screen.setCursorPos(X, Top + Row - 1)
			Screen.blit(Gfx.Pad(Icon.Lines[Row] or "", 3), string.rep(Gfx.ToBlit(Icon.Fg), 3), string.rep(Gfx.ToBlit(Icon.Bg), 3))
		end
		if (Item.App and Item.App.ID == "messages" and Unread > 0) then
			Gfx.Write(Screen, X + 2, Top, Unread > 9 and "+" or tostring(Unread), colors.white, colors.red)
		end
		local IsRunning, IsFocused = ItemRunning(Item)
		if (IsRunning) then
			local Color = IsFocused and Th.Accent or Th.DockFg
			if (Clear) then
				WriteOver(X + 1, Top + IconRows, "\7", IsFocused and Th.Accent or colors.white)
			else
				Gfx.Write(Screen, X + 1, Top + IconRows, "\7", Color, Th.DockBg)
			end
		end
		Item.X = X
		table.insert(DockRegions, Item)
	end
end

-- The dock icon a window minimizes into or opens from: X, Y, W, H.
local function DockSlot(Proc)
	local Rows = DockHeight() - 1
	for _, Item in ipairs(DockRegions) do
		if (Item.Proc == Proc or (Item.App and Proc.AppID and Item.App.ID == Proc.AppID)) then
			return { Item.X, DockTop(), 3, Rows }
		end
	end
	return { math.floor(ScreenW / 2), DockTop(), 3, Rows }
end

local function LaunchpadApps()
	local List = {}
	local Query = Launchpad.Query:lower()
	for _, App in pairs(AppCache) do
		if (not App.Hidden and App.Builtin ~= "launchpad") then
			if (Query == "" or App.Name:lower():find(Query, 1, true)) then
				table.insert(List, App)
			end
		end
	end
	table.sort(List, function(A, B) return A.Name:lower() < B.Name:lower() end)
	return List
end

local function DrawLaunchpad(Th)
	Launchpad.Regions = {}
	if (Launchpad.Rect) then
		local Rect = Launchpad.Rect
		Gfx.Fill(Screen, Rect[1], Rect[2], Rect[3], Rect[4], colors.gray, colors.lightGray, "\127")
		return
	end
	Gfx.Fill(Screen, 1, 1, ScreenW, ScreenH, colors.gray, colors.lightGray, "\127")
	local SearchW = math.min(24, ScreenW - 4)
	local SearchX = math.floor((ScreenW - SearchW) / 2) + 1
	local Query = Launchpad.Query
	local Text = (#Query > 0) and Query or "Search"
	Gfx.Write(Screen, SearchX, 2, Gfx.Pad(" \16 " .. Text, SearchW), (#Query > 0) and colors.white or colors.lightGray, colors.black)
	local List = LaunchpadApps()
	local CellW, CellH = 10, 4
	local Cols = math.max(1, math.floor((ScreenW - 2) / CellW))
	local Rows = math.max(1, math.floor((ScreenH - 5) / CellH))
	local PerPage = Cols * Rows
	local Pages = math.max(1, math.ceil(#List / PerPage))
	Launchpad.Pages = Pages
	Launchpad.Page = math.max(1, math.min(Launchpad.Page, Pages))
	local StartX = math.floor((ScreenW - Cols * CellW) / 2) + 1
	local StartY = 4
	local First = (Launchpad.Page - 1) * PerPage
	for Slot = 1, PerPage do
		local App = List[First + Slot]
		if (not App) then break end
		local Col = (Slot - 1) % Cols
		local Row = math.floor((Slot - 1) / Cols)
		local X = StartX + Col * CellW
		local Y = StartY + Row * CellH
		for Line = 1, 2 do
			Screen.setCursorPos(X + 3, Y + Line - 1)
			Screen.blit(Gfx.Pad(App.Icon.Lines[Line] or "", 3), string.rep(Gfx.ToBlit(App.Icon.Fg), 3), string.rep(Gfx.ToBlit(App.Icon.Bg), 3))
		end
		Gfx.Write(Screen, X, Y + 2, Gfx.Pad(App.Name, CellW - 1, "center"), colors.white, colors.gray)
		table.insert(Launchpad.Regions, { X = X, Y = Y, W = CellW - 1, H = 3, App = App })
	end
	if (#List == 0) then
		Gfx.Center(Screen, 6, "No apps found", colors.white, colors.gray)
	end
	if (Pages > 1) then
		local Dots = ""
		for Page = 1, Pages do
			Dots = Dots .. "\7 "
		end
		local DotX = math.floor((ScreenW - #Dots) / 2) + 1
		for Page = 1, Pages do
			Gfx.Write(Screen, DotX + (Page - 1) * 2, ScreenH, "\7", (Page == Launchpad.Page) and colors.white or colors.lightGray, colors.gray)
		end
	end
end

local function ToastWidth()
	return math.min(28, ScreenW - 2)
end

local function DrawToasts(Th)
	local Y = (FocusedFullscreen() and not RevealActive()) and 1 or 2
	local W = ToastWidth()
	for _, Toast in ipairs(Toasts) do
		local X = ScreenW - W + (Toast.Slide or 0)
		local Lines = Gfx.Wrap(Toast.Text or "", W - 2)
		local H = math.min(#Lines, 2) + 2
		Gfx.Fill(Screen, X, Y, W, H, Th.MenuBg)
		Gfx.Write(Screen, X + 1, Y, Gfx.Truncate(Toast.Title, W - 2), Th.Accent, Th.MenuBg)
		for Row = 1, H - 2 do
			Gfx.Write(Screen, X + 1, Y + Row, Gfx.Truncate(Lines[Row], W - 2), Th.MenuFg, Th.MenuBg)
		end
		Gfx.Write(Screen, X + W - 2, Y, "x", Th.MenuDim, Th.MenuBg)
		Toast.X, Toast.Y, Toast.W, Toast.H = X, Y, W, H
		Y = Y + H + 1
		if (Y > ScreenH - 3) then break end
	end
end

local function DrawMenu(Th)
	local Current = Menu
	local Height = #Current.Items
	local Shown = Current.Reveal or Height
	-- Dock menus sit above the dock, so they unroll upwards.
	local First = Current.Up and (Height - Shown + 1) or 1
	local Last = Current.Up and Height or Shown
	Gfx.Fill(Screen, Current.X, Current.Y + First - 1, Current.W, Last - First + 1, Th.MenuBg)
	for Index = First, Last do
		local Item = Current.Items[Index]
		local Y = Current.Y + Index - 1
		if (Item == "-") then
			Gfx.Write(Screen, Current.X, Y, string.rep("\140", Current.W), Th.MenuDim, Th.MenuBg)
		else
			local Bg, Fg = Th.MenuBg, Item.Disabled and Th.MenuDim or Th.MenuFg
			if (Index == Current.Hover and not Item.Disabled) then
				Bg, Fg = Th.Accent, Th.AccentFg
			end
			local Prefix = Item.Checked and "\4" or " "
			local Hint = Item.Hint or ""
			Gfx.Write(Screen, Current.X, Y, Gfx.Pad(Prefix .. Item.Text, Current.W - #Hint - 1) .. Hint .. " ", Fg, Bg)
		end
	end
	if (not Current.Reveal) then
		Gfx.Shadow(Screen, Current.X, Current.Y, Current.W, Height, Th.Shadow)
	end
end

local function DrawDialog(Th)
	local Current = Dialog
	local W = math.min(34, ScreenW - 4)
	local Lines = Gfx.Wrap(Current.Text or "", W - 4)
	local H = #Lines + 5
	local X = math.floor((ScreenW - W) / 2) + 1
	local Y = math.floor((ScreenH - H) / 2) + 1
	Gfx.Fill(Screen, X, Y, W, H, Th.MenuBg)
	Gfx.Fill(Screen, X, Y, W, 1, Th.TitleBg)
	Gfx.Center(Screen, Y, Current.Title, Th.TitleFg, Th.TitleBg, X, W)
	for Row, Line in ipairs(Lines) do
		Gfx.Write(Screen, X + 2, Y + Row + 1, Line, Th.MenuFg, Th.MenuBg)
	end
	local ButtonX = X + W - 1
	for Index = #Current.Buttons, 1, -1 do
		local Button = Current.Buttons[Index]
		local Text = " " .. Button.Text .. " "
		ButtonX = ButtonX - #Text
		local Bg = Button.Primary and Th.Accent or Th.ButtonBg
		local Fg = Button.Primary and Th.AccentFg or Th.ButtonFg
		Gfx.Write(Screen, ButtonX, Y + H - 2, Text, Fg, Bg)
		Button.X, Button.Y, Button.W = ButtonX, Y + H - 2, #Text
		ButtonX = ButtonX - 1
	end
	Gfx.Shadow(Screen, X, Y, W, H, Th.Shadow)
end

-- An empty window outline used while a window opens or minimizes.
local function DrawGhost(Th)
	local X, Y, W, H = Ghost[1], Ghost[2], Ghost[3], Ghost[4]
	Gfx.Fill(Screen, X, Y, W, H, Th.WindowBg)
	Gfx.Fill(Screen, X, Y, W, 1, Th.TitleBg)
	if (W >= 6 and H >= 2) then
		Gfx.Write(Screen, X + 1, Y, "\7 \7 \7", Th.TitleIdleFg, Th.TitleBg)
	end
	if (W >= 4 and H >= 3) then
		Gfx.Shadow(Screen, X, Y, W, H, Th.Shadow)
	end
end

local function RestoreCursor()
	if (Focused and Focused.Live and not Focused.AppHidden) then
		if (Focused.Window.restoreCursor) then
			Focused.Window.restoreCursor()
		else
			Focused.Window.setCursorPos(Focused.Window.getCursorPos())
		end
	else
		Screen.setCursorBlink(false)
	end
end

function Redraw()
	if (RedrawTimer) then
		os.cancelTimer(RedrawTimer)
		RedrawTimer = nil
	end
	if (Locked) then
		if (LockScreen and LockScreen.Timer) then LockScreen:Draw() end
		return
	end
	local Th = Theme.Get()
	Screen.setVisible(false)
	DrawWallpaper()
	local FullFocus = FocusedFullscreen()
	local Revealed = FullFocus and RevealActive()
	local Overlay = Menu or Dialog or Launchpad.Open or #Toasts > 0 or Revealed or Ghost
	for _, Proc in ipairs(Processes) do
		Proc.Live = false
		if (Proc.Minimized or Proc.Opening) then
			Hide(Proc)
		else
			if (not Proc.Fullscreen) then
				DrawFrame(Proc, Th, Proc == Focused)
			end
			Show(Proc)
			if (Proc == Focused and not Overlay and not Proc.Dead) then
				Proc.Live = true
				if (Proc.AppHidden) then
					Proc.Window.setVisible(false)
					Proc.Shown = false
				end
			else
				Hide(Proc)
			end
		end
	end
	if (not FullFocus) then
		DrawTopbar(Th)
		DrawDock(Th)
	elseif (Revealed) then
		DrawTopbar(Th)
		DrawFrame(Focused, Th, true, 2)
	end
	if (Launchpad.Open) then DrawLaunchpad(Th) end
	DrawToasts(Th)
	if (Menu) then DrawMenu(Th) end
	if (Dialog) then DrawDialog(Th) end
	if (Ghost) then DrawGhost(Th) end
	Screen.setVisible(true)
	RestoreCursor()
end

function ScheduleRedraw()
	if (Locked or RedrawTimer) then return end
	RedrawTimer = os.startTimer(.1)
end

--
-- Notifications and dialogs
--

local function PlaySound(Count)
	local Speaker = peripheral.find("speaker")
	if (not Speaker) then return end
	for _ = 1, Count or 1 do
		pcall(Speaker.playNote, "bell", 1, 18)
	end
end

function Notify(Title, Text, Opts)
	Opts = Opts or {}
	local Entry = { Title = tostring(Title), Text = tostring(Text or ""), AppID = Opts.AppID, Args = Opts.Args, Expires = os.clock() + (Opts.Duration or 5) }
	table.insert(History, 1, Entry)
	while (#History > 30) do table.remove(History) end
	local Settings = Config.Settings()
	if (not Settings.Notifications) then return end
	table.insert(Toasts, 1, Entry)
	while (#Toasts > 3) do table.remove(Toasts) end
	if (QueueAnimation({ Kind = "toast", Toast = Entry })) then
		Entry.Slide = ToastWidth() + 1
	end
	if (Settings.NotificationSound and Opts.Sound ~= false) then
		PlaySound(Opts.Repeat)
	end
	Redraw()
end

local function ShowDialog(Title, Text, Buttons)
	Menu = nil
	Dialog = { Title = Title, Text = Text, Buttons = Buttons }
	Redraw()
end

local function Confirm(Title, Text, YesText, OnYes)
	ShowDialog(Title, Text, {
		{ Text = "Cancel" },
		{ Text = YesText, Primary = true, Action = OnYes }
	})
end

--
-- Session: lock, login, services
--

local function SchedulerService()
	local Schedule = BlockOS.Require("schedule")
	while (true) do
		for _, Entry in ipairs(Schedule.CollectDue()) do
			if (Entry.Kind == "reminder") then
				Notify("Reminder", Entry.Item.Title, { AppID = "reminders" })
			else
				Notify("Alarm", Entry.Item.Label or "Alarm", { AppID = "clock", Repeat = 3, Duration = 10 })
			end
		end
		sleep(1)
	end
end

local function ChatService()
	local Chat = BlockOS.Require("chat")
	Chat.Load()
	Chat.OpenModems()
	Chat.Presence()
	local Timer = os.startTimer(30)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "rednet_message" and C == Chat.Protocol) then
			local Room, Message = Chat.Receive(A, B)
			if (Room) then
				os.queueEvent("blockos_chat", Room.ID)
				if (not (Focused and Focused.AppID == "messages")) then
					local Title = Room.Target and Message.Nick or ("#" .. Room.Name)
					local Body = Message.Text
					if (Message.Kind == "me") then
						Body = "* " .. Message.Nick .. " " .. Body
					elseif (not Room.Target) then
						Body = Message.Nick .. ": " .. Body
					end
					Notify(Title, Body, { AppID = "messages" })
				else
					ScheduleRedraw()
				end
			end
		elseif (Event == "timer" and A == Timer) then
			Chat.Presence()
			Timer = os.startTimer(30)
		elseif (Event == "peripheral") then
			Chat.OpenModems()
		end
	end
end

local function UpdateService()
	local Updater = BlockOS.Require("updater")
	sleep(10)
	while (true) do
		local Settings = Config.Settings()
		if (Settings.AutoUpdate and http) then
			local Manifest = Updater.Check()
			if (Manifest and Manifest.Newer) then
				if (Settings.AutoInstall) then
					if (Updater.Apply(Manifest)) then
						Notify("Software Update", "BlockOS " .. Manifest.Version .. " was installed. Restart to finish.", { AppID = "settings", Args = { "update" } })
					end
				else
					Notify("Software Update", "BlockOS " .. Manifest.Version .. " is available.", { AppID = "settings", Args = { "update" } })
				end
			end
			ScheduleRedraw()
		end
		sleep(7200)
	end
end

local function PresenceService()
	local Presence = BlockOS.Require("presence")
	Presence.OpenModems()
	Presence.Locate()
	local Timer = os.startTimer(60)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "rednet_message" and C == Presence.Protocol) then
			Presence.Answer(A, B)
		elseif (Event == "timer" and A == Timer) then
			Presence.Locate()
			Timer = os.startTimer(Presence.Position and 60 or 300)
		elseif (Event == "peripheral") then
			Presence.OpenModems()
		end
	end
end

local function StartSession()
	if (SessionStarted) then return end
	SessionStarted = true
	Users.EnsureHome()
	RefreshApps()
	StartService("scheduler", SchedulerService)
	StartService("chat", ChatService)
	StartService("presence", PresenceService)
	StartService("updater", UpdateService)
	for _, ID in ipairs(Config.Settings().StartupApps or {}) do
		Launch(ID)
	end
end

local function Power(Action)
	local Run = (Action == "restart") and os.reboot or os.shutdown
	if (not QueueAnimation({ Kind = "power", Run = Run })) then
		Run()
	end
end

local function EnterLock()
	Menu = nil
	Dialog = nil
	Launchpad.Open = false
	Drag = nil
	MouseTarget = nil
	for _, Proc in ipairs(Processes) do
		Hide(Proc)
	end
	Locked = true
	LockScreen = Login.new(Screen, { OnPower = Power })
	LockScreen:Start()
end

-- Locking fades the desktop out and the lock screen in.
function Lock()
	if (Locked or PendingLock) then return end
	if (SessionStarted and QueueAnimation({ Kind = "lock" })) then
		PendingLock = true
		return
	end
	EnterLock()
end

local function Unlock()
	if (LockScreen) then LockScreen:Stop() end
	LockScreen = nil
	Locked = false
	Modifiers = {}
	LastInput = os.clock()
	StartSession()
	Redraw()
end

local function LogOut()
	for _, Proc in ipairs(Copy(Processes)) do
		Kill(Proc)
	end
	Lock()
end

--
-- Menus
--

local function MenuWidth(Items)
	local W = 8
	for _, Item in ipairs(Items) do
		if (Item ~= "-") then
			W = math.max(W, #Item.Text + #(Item.Hint or "") + 4)
		end
	end
	return math.min(W, ScreenW - 2)
end

function OpenMenu(Name, X, Y, Items)
	if (not Items) then
		Items = {}
		local User = Users.Primary()
		if (Name == "logo") then
			Items = {
				{ Text = "About BlockOS", Action = function() Launch("about") end },
				"-",
				{ Text = "System Settings...", Action = function() Launch("settings") end },
				{ Text = "App Store...", Action = function() Launch("appstore") end },
				"-",
				{ Text = "Force Quit...", Action = function() OpenMenu("forcequit", 2, 2) end, Disabled = #Processes == 0 },
				"-",
				{ Text = "Lock Screen", Hint = "^\24L", Action = Lock },
				{ Text = "Log Out " .. (User and User.Name or ""), Action = LogOut },
				"-",
				{ Text = "Restart...", Action = function() Confirm("Restart", "Restart the computer now?", "Restart", function() Power("restart") end) end },
				{ Text = "Shut Down...", Action = function() Confirm("Shut Down", "Shut down the computer now?", "Shut Down", function() Power("shutdown") end) end }
			}
		elseif (Name == "forcequit") then
			for _, Proc in ipairs(Processes) do
				local Target = Proc
				table.insert(Items, { Text = Gfx.Truncate(Proc.Title, 24), Action = function() Kill(Target) end })
			end
		elseif (Name == "app") then
			local Current = Focused
			local Title = AppName()
			Items = {
				{ Text = "About " .. Title, Disabled = not Current, Action = function()
					local App = Current and Current.AppID and AppCache[Current.AppID]
					ShowDialog(Title, App and ((App.Description or "") .. "\n\nVersion " .. (App.Version or Config.Version())) or "A program running on BlockOS.", { { Text = "OK", Primary = true } })
				end },
				"-",
				{ Text = "Hide " .. Title, Hint = "^\24M", Disabled = not Current, Action = function() Minimize(Current) end },
				{ Text = "Quit " .. Title, Hint = "^\24W", Disabled = not Current, Action = function()
					if (Current and Current.AppID) then
						for _, Proc in ipairs(ProcsOf(Current.AppID)) do CloseProc(Proc) end
					else
						CloseProc(Current)
					end
				end }
			}
		elseif (Name == "go") then
			local Places = {
				{ "Home", "/home" }, { "Documents", "/home/Documents" }, { "Downloads", "/home/Downloads" },
				{ "Music", "/home/Music" }, { "Applications", "apps:" }, { "Computer", "/" }
			}
			for _, Place in ipairs(Places) do
				local Target = Place[2]
				table.insert(Items, { Text = Place[1], Action = function() Launch("finder", { Target }) end })
			end
			table.insert(Items, "-")
			table.insert(Items, { Text = "Terminal", Hint = "^\24T", Action = function() Launch("terminal") end })
			table.insert(Items, { Text = "Launchpad", Hint = "^\24Spc", Action = ToggleLaunchpad })
		elseif (Name == "window") then
			local Current = Focused
			Items = {
				{ Text = "Minimize", Hint = "^\24M", Disabled = not Current, Action = function() Minimize(Current) end },
				{ Text = "Zoom", Disabled = not Current or (Current and Current.Fullscreen), Action = function() Zoom(Current) end },
				{ Text = (Current and Current.Fullscreen) and "Exit Full Screen" or "Enter Full Screen", Hint = "^\24F", Disabled = not Current, Action = function() ToggleFullscreen(Current) end },
				"-",
				{ Text = "Close Window", Hint = "^\24W", Disabled = not Current, Action = function() CloseProc(Current) end }
			}
			if (#Processes > 0) then
				table.insert(Items, "-")
				for Index = #Processes, 1, -1 do
					local Proc = Processes[Index]
					table.insert(Items, { Text = Gfx.Truncate(Proc.Title, 22), Checked = Proc == Focused, Action = function() Focus(Proc) end })
				end
			end
		end
	end
	if (#Items == 0) then return end
	local W = MenuWidth(Items)
	Y = Y or 2
	while (Y + #Items - 1 > ScreenH) do
		Y = Y - 1
	end
	Menu = {
		Name = Name,
		Items = Items,
		X = math.max(1, math.min(X or 1, ScreenW - W)),
		Y = math.max(1, Y),
		W = W,
		Hover = 0,
		Up = Name == "dock"
	}
	if (#Items > 1 and QueueAnimation({ Kind = "menu", Menu = Menu })) then
		Menu.Reveal = 1
	end
	Redraw()
end

local function RunMenuItem(Index)
	local Item = Menu and Menu.Items[Index]
	if (not Item or Item == "-" or Item.Disabled) then return false end
	Menu = nil
	Redraw()
	if (Item.Action) then Item.Action() end
	return true
end

local function OpenDockMenu(Item)
	local Items = {}
	if (Item.Proc) then
		Items = {
			{ Text = "Show", Action = function() Focus(Item.Proc) end },
			{ Text = "Quit", Action = function() CloseProc(Item.Proc) end }
		}
	else
		local App = Item.App
		local Windows = ProcsOf(App.ID)
		for Index = #Windows, 1, -1 do
			local Proc = Windows[Index]
			table.insert(Items, { Text = Gfx.Truncate(Proc.Title, 20), Checked = Proc == Focused, Action = function() Focus(Proc) end })
		end
		if (#Windows > 0) then table.insert(Items, "-") end
		if (App.Builtin ~= "launchpad") then
			table.insert(Items, { Text = (#Windows > 0) and "New Window" or "Open", Action = function() Launch(App.ID) end })
		end
		local Pinned = Apps.IsPinned(App.ID)
		table.insert(Items, { Text = Pinned and "Remove from Dock" or "Keep in Dock", Action = function() Apps.SetPinned(App.ID, not Pinned) end })
		if (#Windows > 0) then
			table.insert(Items, "-")
			table.insert(Items, { Text = "Quit", Action = function()
				for _, Proc in ipairs(Windows) do CloseProc(Proc) end
			end })
		end
	end
	OpenMenu("dock", Item.X, DockTop() - #Items, Items)
end

local function OpenDesktopMenu(X, Y)
	OpenMenu("desktop", X, Y, {
		{ Text = "New Terminal", Action = function() Launch("terminal") end },
		{ Text = "Open Finder", Action = function() Launch("finder") end },
		{ Text = "Launchpad", Action = ToggleLaunchpad },
		"-",
		{ Text = "Change Wallpaper...", Action = function() Launch("settings", { "appearance" }) end },
		{ Text = "About BlockOS", Action = function() Launch("about") end }
	})
end

--
-- Input
--

local function ActivateDockItem(Item)
	if (Item.Proc) then
		Focus(Item.Proc)
		return
	end
	local App = Item.App
	if (App.Builtin == "launchpad") then
		ToggleLaunchpad()
		return
	end
	local Windows = ProcsOf(App.ID)
	if (#Windows == 0) then
		Launch(App.ID)
	elseif (Focused and Focused.AppID == App.ID and #Windows > 1) then
		Focus(Windows[1])
	else
		Focus(Windows[#Windows])
	end
end

local function TopbarClick(Button, X)
	for _, Region in ipairs(TopbarRegions) do
		if (X >= Region.X and X < Region.X + Region.W) then
			if (Region.Menu) then
				OpenMenu(Region.Menu, Region.X, 2)
			elseif (Region.Action == "clock") then
				Launch("clock")
			elseif (Region.Action == "update") then
				Launch("settings", { "update" })
			elseif (Region.Action == "recording") then
				os.queueEvent("blockos_recorder_stop")
			end
			if (RevealUntil) then RevealUntil = os.clock() + 3 end
			return
		end
	end
end

local function TitlebarClick(Proc, Relative, X, Y)
	if (Relative == 1) then
		CloseProc(Proc)
	elseif (Relative == 3) then
		Minimize(Proc)
	elseif (Relative == 5) then
		ToggleFullscreen(Proc)
	elseif (not Proc.Fullscreen) then
		local Now = os.clock()
		if (LastTitleClick.Proc == Proc and Now - LastTitleClick.Time < .4) then
			LastTitleClick = { Time = 0 }
			Zoom(Proc)
			return
		end
		LastTitleClick = { Proc = Proc, Time = Now }
		Drag = { Proc = Proc, Mode = "move", OffX = X - Proc.X, OffY = Y - Proc.Y }
	end
end

local function LaunchpadClick(X, Y)
	for _, Region in ipairs(Launchpad.Regions) do
		if (X >= Region.X and X < Region.X + Region.W and Y >= Region.Y and Y < Region.Y + Region.H) then
			Launchpad.Open = false
			Launch(Region.App.ID, nil, { From = { Region.X + 3, Region.Y, 3, 2 } })
			Redraw()
			return
		end
	end
	if (Y == 2 or Y == ScreenH) then return end
	CloseLaunchpad()
end

local function OnClick(Button, X, Y)
	if (Dialog) then
		for _, Item in ipairs(Dialog.Buttons) do
			if (Item.X and Y == Item.Y and X >= Item.X and X < Item.X + Item.W) then
				Dialog = nil
				Redraw()
				if (Item.Action) then Item.Action() end
				return
			end
		end
		return
	end
	if (Menu) then
		local Current = Menu
		if (X >= Current.X and X < Current.X + Current.W and Y >= Current.Y and Y < Current.Y + #Current.Items) then
			RunMenuItem(Y - Current.Y + 1)
			return
		end
		Menu = nil
		Redraw()
		if (Y ~= 1) then return end
		for _, Region in ipairs(TopbarRegions) do
			if (Region.Menu == Current.Name and X >= Region.X and X < Region.X + Region.W) then
				return
			end
		end
	end
	if (Launchpad.Open) then
		LaunchpadClick(X, Y)
		return
	end
	for Index, Toast in ipairs(Toasts) do
		if (Toast.X and X >= Toast.X and X < Toast.X + Toast.W and Y >= Toast.Y and Y < Toast.Y + Toast.H) then
			table.remove(Toasts, Index)
			if (Toast.AppID and X < Toast.X + Toast.W - 2) then
				Launch(Toast.AppID, Toast.Args)
			end
			Redraw()
			return
		end
	end
	local FullFocus = FocusedFullscreen()
	local Revealed = FullFocus and RevealActive()
	if (FullFocus and not Revealed and Y == 1 and (X <= 2 or Button == 2)) then
		RevealTopbar()
		return
	end
	if (Y == 1 and (not FullFocus or Revealed)) then
		TopbarClick(Button, X)
		return
	end
	if (Revealed and Y == 2) then
		TitlebarClick(Focused, X - 1, X, Y)
		return
	end
	if (not FullFocus and Y >= DockTop()) then
		for _, Item in ipairs(DockRegions) do
			if (X >= Item.X and X < Item.X + 3) then
				if (Button == 2) then
					OpenDockMenu(Item)
				else
					ActivateDockItem(Item)
				end
				return
			end
		end
		if (Config.Settings().DockStyle ~= "transparent") then return end
	end
	for Index = #Processes, 1, -1 do
		local Proc = Processes[Index]
		local Inside
		if (Proc.Fullscreen) then
			Inside = true
		else
			Inside = X >= Proc.X and X < Proc.X + Proc.W and Y >= Proc.Y and Y < Proc.Y + Proc.H
		end
		if (not Proc.Minimized and not Proc.Opening and Inside) then
			if (Proc ~= Focused) then Focus(Proc) end
			if (not Proc.Fullscreen and Y == Proc.Y) then
				TitlebarClick(Proc, X - Proc.X, X, Y)
				return
			end
			if (Proc.Dead) then
				Kill(Proc)
				return
			end
			if (not Proc.Fullscreen and X == Proc.X + Proc.W - 1 and Y == Proc.Y + Proc.H - 1) then
				Drag = { Proc = Proc, Mode = "resize" }
				return
			end
			MouseTarget = Proc
			SendMouse(Proc, "mouse_click", Button, X, Y)
			return
		end
	end
	if (Focused) then
		Focused = nil
		Redraw()
	end
	if (Button == 2) then
		OpenDesktopMenu(X, Y)
	end
end

local function OnDrag(Button, X, Y)
	if (Menu) then
		local Index = Y - Menu.Y + 1
		if (X >= Menu.X and X < Menu.X + Menu.W and Menu.Items[Index]) then
			Menu.Hover = Index
			Redraw()
		end
		return
	end
	if (Drag) then
		local Proc = Drag.Proc
		local _, AreaY, AreaW, AreaH = WorkArea()
		if (Drag.Mode == "move") then
			Proc.X = X - Drag.OffX
			Proc.Y = Y - Drag.OffY
		else
			Proc.W = math.min(X - Proc.X + 1, AreaW - Proc.X + 1)
			Proc.H = math.min(Y - Proc.Y + 1, AreaY + AreaH - Proc.Y)
		end
		Proc.Saved = nil
		ClampWindow(Proc)
		ApplyGeometry(Proc)
		Redraw()
		return
	end
	if (MouseTarget and not MouseTarget.Dead) then
		SendMouse(MouseTarget, "mouse_drag", Button, X, Y)
	end
end

local function OnUp(Button, X, Y)
	if (Menu and Menu.Hover > 0 and Y ~= 1) then
		local Index = Y - Menu.Y + 1
		if (X >= Menu.X and X < Menu.X + Menu.W and Index == Menu.Hover) then
			RunMenuItem(Index)
			return
		end
	end
	if (Drag) then
		Drag = nil
		return
	end
	if (MouseTarget and not MouseTarget.Dead) then
		SendMouse(MouseTarget, "mouse_up", Button, X, Y)
	end
	MouseTarget = nil
end

local function OnScroll(Direction, X, Y)
	if (Launchpad.Open) then
		Launchpad.Page = math.max(1, math.min((Launchpad.Pages or 1), Launchpad.Page + Direction))
		Redraw()
		return
	end
	if (Menu or Dialog) then return end
	local FullFocus = FocusedFullscreen()
	if (FullFocus and Y == 1 and Direction < 0) then
		RevealTopbar()
		return
	end
	for Index = #Processes, 1, -1 do
		local Proc = Processes[Index]
		if (not Proc.Minimized and not Proc.Opening) then
			local CX, CY, CW, CH = ContentRect(Proc)
			if (X >= CX and X < CX + CW and Y >= CY and Y < CY + CH) then
				if (not Proc.Dead) then
					SendMouse(Proc, "mouse_scroll", Direction, X, Y)
				end
				return
			end
		end
	end
end

local function CycleWindows()
	if (#Processes < 2) then
		if (Processes[1]) then Focus(Processes[1]) end
		return
	end
	Focus(Processes[1])
end

local function Shortcut(Key)
	if (Key == keys.f) then
		ToggleFullscreen(Focused)
	elseif (Key == keys.w or Key == keys.q) then
		CloseProc(Focused)
	elseif (Key == keys.m) then
		Minimize(Focused)
	elseif (Key == keys.tab) then
		CycleWindows()
	elseif (Key == keys.space) then
		ToggleLaunchpad()
	elseif (Key == keys.l) then
		Lock()
	elseif (Key == keys.t) then
		Launch("terminal")
	elseif (Key == keys.up and FocusedFullscreen()) then
		RevealTopbar()
	else
		return false
	end
	return true
end

local function OnKey(Name, Key, Held)
	local Modifier = ModifierKeys[Key]
	if (Modifier) then
		Modifiers[Modifier] = (Name == "key")
	end
	if (Name == "key" and not Modifier and Modifiers.Ctrl and Modifiers.Shift and Shortcut(Key)) then
		return
	end
	if (Dialog) then
		if (Name == "key" and (Key == keys.enter or Key == keys.numPadEnter)) then
			local Primary = Dialog.Buttons[#Dialog.Buttons]
			Dialog = nil
			Redraw()
			if (Primary.Action) then Primary.Action() end
		end
		return
	end
	if (Menu) then
		if (Name ~= "key") then return end
		if (Key == keys.down or Key == keys.up) then
			local Step = (Key == keys.down) and 1 or -1
			for _ = 1, #Menu.Items do
				Menu.Hover = (Menu.Hover - 1 + Step) % #Menu.Items + 1
				local Item = Menu.Items[Menu.Hover]
				if (Item ~= "-" and not Item.Disabled) then break end
			end
			Redraw()
		elseif (Key == keys.enter or Key == keys.numPadEnter) then
			RunMenuItem(Menu.Hover)
		elseif (not Modifier) then
			Menu = nil
			Redraw()
		end
		return
	end
	if (Launchpad.Open) then
		if (Name ~= "key") then return end
		if (Key == keys.backspace) then
			if (#Launchpad.Query == 0) then
				CloseLaunchpad()
			else
				Launchpad.Query = Launchpad.Query:sub(1, -2)
			end
			Redraw()
		elseif (Key == keys.enter or Key == keys.numPadEnter) then
			local First = LaunchpadApps()[1]
			Launchpad.Open = false
			if (First) then Launch(First.ID) end
			Redraw()
		end
		return
	end
	if (Focused) then
		if (Focused.Dead) then
			if (Name == "key" and not Modifier) then Kill(Focused) end
			return
		end
		Resume(Focused, Name, Key, Held)
	end
end

local function OnText(Event)
	if (Dialog or Menu) then return end
	if (Launchpad.Open) then
		Launchpad.Query = (Launchpad.Query .. Event[2]):sub(1, 20)
		Launchpad.Page = 1
		Redraw()
		return
	end
	if (Focused and not Focused.Dead) then
		Resume(Focused, table.unpack(Event, 1, Event.n))
	end
end

local function OnResize()
	ScreenW, ScreenH = Native.getSize()
	Screen.reposition(1, 1, ScreenW, ScreenH)
	for _, Proc in ipairs(Processes) do
		ClampWindow(Proc)
		ApplyGeometry(Proc)
	end
	Redraw()
end

local function ClockTick()
	local Changed = false
	local Now = os.clock()
	for Index = #Toasts, 1, -1 do
		local Toast = Toasts[Index]
		if (Toast.Expires <= Now and not Toast.Leaving) then
			if (QueueAnimation({ Kind = "toastout", Toast = Toast })) then
				Toast.Leaving = true
			else
				table.remove(Toasts, Index)
				Changed = true
			end
		end
	end
	if (RevealUntil and Now >= RevealUntil) then
		RevealUntil = nil
		Changed = true
	end
	local IdleLock = Config.Settings().IdleLock or 0
	if (not Locked and IdleLock > 0 and Now - LastInput > IdleLock * 60) then
		Lock()
		return
	end
	if (Locked) then return end
	if (Changed) then
		Redraw()
	elseif (not FocusedFullscreen() and not Launchpad.Open) then
		DrawTopbar(Theme.Get())
		if (Menu) then DrawMenu(Theme.Get()) end
		RestoreCursor()
	end
end

local function HandleEvent(Event)
	local Name = Event[1]
	if (Name == "timer") then
		local ID = Event[2]
		if (ID == RedrawTimer) then
			RedrawTimer = nil
			Redraw()
			return
		elseif (ID == ClockTimer) then
			ClockTimer = os.startTimer(1)
			ClockTick()
			return
		elseif (Locked and LockScreen and ID == LockScreen.Timer) then
			LockScreen:Event("timer", ID)
			return
		end
		Broadcast(Event)
		return
	end
	if (Name == "term_resize") then
		OnResize()
		return
	end
	if (Locked) then
		if (InputEvents[Name]) then
			LastInput = os.clock()
			if (not PendingUnlock and LockScreen:Event(table.unpack(Event, 1, Event.n))) then
				if (QueueAnimation({ Kind = "unlock" })) then
					PendingUnlock = true
				else
					Unlock()
				end
			end
		elseif (Name ~= "terminate") then
			Broadcast(Event)
		end
		return
	end
	if (InputEvents[Name]) then
		LastInput = os.clock()
	end
	if (Name == "mouse_click") then
		OnClick(Event[2], Event[3], Event[4])
	elseif (Name == "mouse_drag") then
		OnDrag(Event[2], Event[3], Event[4])
	elseif (Name == "mouse_up") then
		OnUp(Event[2], Event[3], Event[4])
	elseif (Name == "mouse_scroll") then
		OnScroll(Event[2], Event[3], Event[4])
	elseif (Name == "key" or Name == "key_up") then
		OnKey(Name, Event[2], Event[3])
	elseif (Name == "char" or Name == "paste") then
		OnText(Event)
	elseif (Name == "terminate") then
		if (Focused and not Focused.Dead) then
			Resume(Focused, "terminate")
		end
	elseif (Name == "blockos_settings" or Name == "blockos_apps") then
		RefreshApps()
		for _, Proc in ipairs(Processes) do
			ClampWindow(Proc)
			ApplyGeometry(Proc)
		end
		Redraw()
		Broadcast(Event)
	elseif (Name == "disk") then
		local Side = Event[2]
		local Label = disk.getLabel(Side) or (disk.hasAudio(Side) and disk.getAudioTitle(Side)) or "Untitled disk"
		Notify("Disk inserted", Label .. " (" .. Side .. ")", { AppID = "finder", Args = { disk.getMountPath(Side) or "/" } })
		Broadcast(Event)
	else
		Broadcast(Event)
	end
end

--
-- Animations
--

-- Waits without losing events: anything that arrives is handled after the animation.
local function Wait(Seconds)
	local Timer = os.startTimer(Seconds)
	while (true) do
		local Event = table.pack(os.pullEventRaw())
		if (Event[1] == "timer" and Event[2] == Timer) then return end
		table.insert(Deferred, Event)
	end
end

local function EaseOut(T)
	return 1 - (1 - T) ^ 2
end

local function EaseIn(T)
	return T * T
end

local function Lerp(A, B, T)
	return math.floor(A + (B - A) * T + .5)
end

local function PlayRect(From, To, Frames, Ease)
	for Frame = 1, Frames do
		local T = Ease(Frame / Frames)
		Ghost = {
			Lerp(From[1], To[1], T), Lerp(From[2], To[2], T),
			math.max(1, Lerp(From[3], To[3], T)), math.max(1, Lerp(From[4], To[4], T))
		}
		Redraw()
		Wait(FrameTime)
	end
	Ghost = nil
end

local function Fade(From, To, Steps)
	for Step = 1, Steps do
		if (not SetFadeLevel(From + (To - From) * Step / Steps)) then return end
		Wait(FrameTime)
	end
end

local Players = {}

function Players.open(Animation)
	local Proc = Animation.Proc
	if (Proc.Dead or not Proc.Opening) then
		Proc.Opening = nil
		return
	end
	PlayRect(Animation.From or DockSlot(Proc), WindowRect(Proc), 5, EaseOut)
	Proc.Opening = nil
	Redraw()
end

function Players.minimize(Animation)
	if (not Animation.Proc.Minimized) then return end
	PlayRect(Animation.From, DockSlot(Animation.Proc), 5, EaseIn)
	Redraw()
end

local function HasToast(Toast)
	for _, Other in ipairs(Toasts) do
		if (Other == Toast) then return true end
	end
	return false
end

function Players.toast(Animation)
	local Toast = Animation.Toast
	while (HasToast(Toast) and (Toast.Slide or 0) > 0) do
		Toast.Slide = math.floor(Toast.Slide * .45)
		Redraw()
		Wait(FrameTime)
	end
end

function Players.toastout(Animation)
	local Toast = Animation.Toast
	local W = ToastWidth()
	while (HasToast(Toast) and (Toast.Slide or 0) < W) do
		Toast.Slide = math.min(W, (Toast.Slide or 0) + math.ceil(W / 3))
		Redraw()
		Wait(FrameTime)
	end
	for Index, Other in ipairs(Toasts) do
		if (Other == Toast) then table.remove(Toasts, Index) break end
	end
	Redraw()
end

local function CaptureScreen()
	local Rows = {}
	for Y = 1, ScreenH do
		Rows[Y] = { Screen.getLine(Y) }
	end
	return Rows
end

local function PaintRows(Rows)
	for Y = 1, ScreenH do
		Screen.setCursorPos(1, Y)
		Screen.blit(Rows[Y][1], Rows[Y][2], Rows[Y][3])
	end
end

-- Bleeds one screen into another cell by cell, spreading out from the middle.
local function Dissolve(From, To, Frames)
	local MidX, MidY = (ScreenW + 1) / 2, (ScreenH + 1) / 2
	local Reach = math.sqrt(MidX ^ 2 + (MidY * 1.5) ^ 2)
	local Ranks = {}
	for Y = 1, ScreenH do
		Ranks[Y] = {}
		for X = 1, ScreenW do
			local Distance = math.sqrt((X - MidX) ^ 2 + ((Y - MidY) * 1.5) ^ 2) / Reach
			Ranks[Y][X] = Distance * .5 + math.random() * .45
		end
	end
	for Frame = 1, Frames do
		local Cut = EaseIn(Frame / Frames)
		for Y = 1, ScreenH do
			local Old, New, Rank = From[Y], To[Y], Ranks[Y]
			local Text, Fg, Bg = {}, {}, {}
			for X = 1, ScreenW do
				local Source = (Rank[X] < Cut) and New or Old
				Text[X] = Source[1]:sub(X, X)
				Fg[X] = Source[2]:sub(X, X)
				Bg[X] = Source[3]:sub(X, X)
			end
			Screen.setCursorPos(1, Y)
			Screen.blit(table.concat(Text), table.concat(Fg), table.concat(Bg))
		end
		Wait(FrameTime)
	end
end

function Players.lock()
	local From = CaptureScreen()
	EnterLock()
	local To = CaptureScreen()
	-- Nothing reaches the monitor until we yield, so the lock screen never flashes up early.
	PaintRows(From)
	Dissolve(From, To, 16)
	PendingLock = false
	if (LockScreen) then LockScreen:Draw() end
end

function Players.unlock()
	local From = CaptureScreen()
	PendingUnlock = false
	Unlock()
	local To = CaptureScreen()
	PaintRows(From)
	Dissolve(From, To, 12)
	Redraw()
end

function Players.menu(Animation)
	local Current = Animation.Menu
	local Count = #Current.Items
	local Frames = 5
	for Frame = 1, Frames - 1 do
		if (Menu ~= Current) then return end
		Current.Reveal = math.max(1, math.ceil(Count * Frame / Frames))
		Redraw()
		Wait(FrameTime)
	end
	Current.Reveal = nil
	if (Menu == Current) then Redraw() end
end

function Players.launchpad(Animation)
	local Full = { 1, 1, ScreenW, ScreenH }
	local Seed = LaunchpadSeed()
	local From, To = Seed, Full
	if (not Animation.Opening) then From, To = Full, Seed end
	for Frame = 1, 4 do
		if (not Launchpad.Open) then break end
		local T = Animation.Opening and EaseOut(Frame / 4) or EaseIn(Frame / 4)
		Launchpad.Rect = {
			Lerp(From[1], To[1], T), Lerp(From[2], To[2], T),
			math.max(1, Lerp(From[3], To[3], T)), math.max(1, Lerp(From[4], To[4], T))
		}
		Redraw()
		Wait(FrameTime)
	end
	Launchpad.Rect = nil
	if (not Animation.Opening) then Launchpad.Open = false end
	Redraw()
end

function Players.fadein()
	Fade(0, 1, 5)
end

function Players.power(Animation)
	Fade(1, 0, 6)
	Animation.Run()
end

local function RunAnimations()
	while (#AnimationQueue > 0) do
		local Animation = table.remove(AnimationQueue, 1)
		local Ok, Err = pcall(Players[Animation.Kind], Animation)
		if (not Ok) then
			Ghost = nil
			Launchpad.Rect = nil
			if (Menu) then Menu.Reveal = nil end
			PendingLock, PendingUnlock = false, false
			if (Animation.Proc) then Animation.Proc.Opening = nil end
			SetFadeLevel(1)
			Log("animation: " .. tostring(Err))
			Redraw()
		end
	end
end

--
-- Public API for apps
--

local function InstallAPI()
	BlockOS.Desktop = true
	BlockOS.Shell = RootShell
	BlockOS.Launch = function(Target, Args, Opts)
		return Launch(Target, Args, Opts)
	end
	BlockOS.Open = OpenFile
	BlockOS.Notify = function(Title, Text, Opts)
		Notify(Title, Text, Opts)
	end
	BlockOS.SetTitle = function(Title)
		if (CurrentProc and not CurrentProc.Service) then
			CurrentProc.Title = tostring(Title)
			ScheduleRedraw()
		end
	end
	BlockOS.Current = function()
		local Proc = CurrentProc
		if (not Proc or Proc.Service) then return nil end
		return { ID = Proc.ID, AppID = Proc.AppID, Title = Proc.Title, Fullscreen = Proc.Fullscreen, Focused = Proc == Focused }
	end
	BlockOS.IsFocused = function()
		return CurrentProc ~= nil and CurrentProc == Focused
	end
	BlockOS.SetFullscreen = function(Value)
		local Proc = CurrentProc
		if (Proc and not Proc.Service and Proc.Fullscreen ~= (Value and true or false)) then
			ToggleFullscreen(Proc)
		end
	end
	BlockOS.Minimize = function()
		if (CurrentProc and not CurrentProc.Service) then Minimize(CurrentProc) end
	end
	BlockOS.Quit = function()
		if (CurrentProc and not CurrentProc.Service) then CurrentProc.Closing = true end
	end
	BlockOS.SetCloseHandler = function(Value)
		if (CurrentProc) then CurrentProc.CloseHandler = Value and true or nil end
	end
	BlockOS.Focus = function(ID)
		local Proc = FindProc(ID)
		if (Proc) then Focus(Proc) end
	end
	BlockOS.Kill = function(ID)
		local Proc = FindProc(ID)
		if (Proc and Proc ~= CurrentProc) then Kill(Proc) end
	end
	BlockOS.Processes = function()
		local List = {}
		for _, Proc in ipairs(Processes) do
			table.insert(List, { ID = Proc.ID, AppID = Proc.AppID, Title = Proc.Title, Minimized = Proc.Minimized })
		end
		return List
	end
	BlockOS.Capture = function()
		local Lines = {}
		for Y = 1, ScreenH do
			Lines[Y] = { Screen.getLine(Y) }
		end
		return { W = ScreenW, H = ScreenH, Lines = Lines }
	end
	BlockOS.SetRecording = function(Value)
		Recording = Value and true or false
		ScheduleRedraw()
	end
	BlockOS.Notifications = function()
		return History
	end
	BlockOS.Lock = function() Lock() end
	BlockOS.Restart = function() Power("restart") end
	BlockOS.Shutdown = function() Power("shutdown") end
	BlockOS.User = function() return Users.Primary() end
	BlockOS.ScreenSize = function() return ScreenW, ScreenH end

	Multishell = {
		getCurrent = function() return CurrentProc and CurrentProc.ID or 0 end,
		getCount = function() return #Processes end,
		getFocus = function() return Focused and Focused.ID or 0 end,
		setFocus = function(ID)
			local Proc = FindProc(ID)
			if (not Proc) then return false end
			Focus(Proc)
			return true
		end,
		getTitle = function(ID)
			local Proc = FindProc(ID)
			return Proc and Proc.Title
		end,
		setTitle = function(ID, Title)
			local Proc = FindProc(ID)
			if (Proc and Proc.AllowTitle) then
				Proc.Title = tostring(Title)
				ScheduleRedraw()
			end
		end,
		launch = function(Env, Path, ...)
			local Args = table.pack(...)
			local Proc = Spawn({
				Title = fs.getName(Path),
				AllowTitle = true,
				Fn = function()
					os.run(Env, Path, table.unpack(Args, 1, Args.n))
				end
			})
			return Proc.ID
		end
	}
	BlockOS.Multishell = Multishell
end

function Desktop.Run(Shell)
	RootShell = Shell
	Native = term.current()
	ScreenW, ScreenH = Native.getSize()
	-- The boot screen ends faded to black; restore the palette before any window copies it.
	Gfx.SetFade(Native, 1)
	Screen = window.create(Native, 1, 1, ScreenW, ScreenH, true)
	Hidden = window.create(Screen, 1, 1, 1, 1, false)
	term.redirect(Screen)
	InstallAPI()
	RefreshApps()
	ClockTimer = os.startTimer(1)
	-- Fade the first screen in from black.
	if (not (AnimationsEnabled() and SetFadeLevel(0) and QueueAnimation({ Kind = "fadein" }))) then
		SetFadeLevel(1)
	end
	if (Config.Settings().AutoLogin) then
		StartSession()
		Redraw()
	else
		EnterLock()
	end
	while (Running) do
		local Event = table.remove(Deferred, 1)
		if (not Event) then
			RunAnimations()
			Event = table.remove(Deferred, 1) or table.pack(os.pullEventRaw())
		end
		local Ok, Err = pcall(HandleEvent, Event)
		if (not Ok) then
			Log("desktop: " .. tostring(Err))
		end
		Ok, Err = pcall(FlushPending)
		if (not Ok) then
			Log("desktop: " .. tostring(Err))
		end
	end
end

return Desktop
