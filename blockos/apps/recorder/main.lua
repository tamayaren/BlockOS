-- Recorder: captures the BlockOS screen into .rec files, plays them back,
-- and can export a recording as a standalone player program.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Args = { ... }

local Folder = "/home/Recordings"
local MaxFrames = 2000

local Page = Ui.Page.new()
local Recording = nil
local Options = { Hide = true, Countdown = true, Fps = 8 }
local Build

local function Serialise(Value)
	local Ok, Text = pcall(textutils.serialise, Value, { compact = true })
	if (Ok) then return Text end
	return textutils.serialise(Value)
end

local function ListRecordings()
	if (not fs.exists(Folder)) then fs.makeDir(Folder) end
	local Items = {}
	for _, Name in ipairs(fs.list(Folder)) do
		if (Name:match("%.rec$")) then
			local Path = fs.combine(Folder, Name)
			table.insert(Items, { Text = Name:gsub("%.rec$", ""), Right = Gfx.FormatSize(fs.getSize(Path)), Icon = "\7", IconFg = colors.red, Path = "/" .. Path })
		end
	end
	table.sort(Items, function(A, B) return A.Text > B.Text end)
	return Items
end

local function Capture()
	local Frame = BlockOS.Capture()
	local Now = os.epoch("utc")
	local Changed = {}
	local Any = false
	for Y, Line in ipairs(Frame.Lines) do
		local Previous = Recording.Last[Y]
		if (not Previous or Previous[1] ~= Line[1] or Previous[2] ~= Line[2] or Previous[3] ~= Line[3]) then
			Changed[Y] = Line
			Recording.Last[Y] = Line
			Any = true
		end
	end
	if (Any) then
		table.insert(Recording.Frames, { T = Now - Recording.Started, Lines = Changed })
	end
	Recording.W, Recording.H = Frame.W, Frame.H
end

local function StopRecording()
	if (not Recording) then return end
	Page:ClearInterval(Recording.Interval)
	BlockOS.SetRecording(false)
	local Data = {
		Version = 1,
		W = Recording.W,
		H = Recording.H,
		Duration = os.epoch("utc") - Recording.Started,
		Frames = Recording.Frames
	}
	Recording = nil
	if (#Data.Frames == 0) then return end
	local Path = fs.combine(Folder, "Recording " .. os.date("%Y-%m-%d %H%M%S") .. ".rec")
	Config.WriteText(Path, Serialise(Data))
	BlockOS.Notify("Recorder", "Saved " .. fs.getName(Path), { AppID = "recorder", Sound = false })
	Build()
end

local function StartRecording()
	if (Recording) then return end
	if (Options.Countdown) then
		for Count = 3, 1, -1 do
			BlockOS.Notify("Recorder", "Recording starts in " .. Count .. "...", { Sound = false, Duration = 1 })
			sleep(1)
		end
	end
	Recording = { Frames = {}, Last = {}, Started = os.epoch("utc") }
	BlockOS.SetRecording(true)
	if (Options.Hide) then BlockOS.Minimize() end
	Capture()
	Recording.Interval = Page:SetInterval(1 / Options.Fps, function()
		if (not Recording) then return false end
		Capture()
		if (#Recording.Frames >= MaxFrames) then StopRecording() end
		return true
	end)
	Build()
end

local function LoadRecording(Path)
	local Data = textutils.unserialise(Config.ReadText(Path) or "")
	if (type(Data) ~= "table" or type(Data.Frames) ~= "table") then return nil end
	return Data
end

-- Plays a recording full screen; any click or key other than space stops it.
local function Play(Path)
	local Data = LoadRecording(Path)
	if (not Data) then
		Ui.Alert("Recorder", "This file is not a valid recording.")
		return
	end
	BlockOS.SetFullscreen(true)
	sleep(0)
	local T = term.current()
	local W, H = T.getSize()
	local Screen = window.create(T, 1, 1, W, H, true)
	Screen.setBackgroundColor(colors.black)
	Screen.clear()
	local Paused = false
	local Index = 1
	local Clock = 0
	local Last = os.epoch("utc")
	local Timer = os.startTimer(0)
	while (Index <= #Data.Frames) do
		local Event = table.pack(os.pullEventRaw())
		local Name = Event[1]
		if (Name == "terminate" or Name == "mouse_click" or (Name == "key" and Event[2] ~= keys.space)) then
			break
		elseif (Name == "key" and Event[2] == keys.space) then
			Paused = not Paused
			Last = os.epoch("utc")
		elseif (Name == "timer" and Event[2] == Timer) then
			local Now = os.epoch("utc")
			if (not Paused) then Clock = Clock + (Now - Last) end
			Last = Now
			while (Index <= #Data.Frames and Data.Frames[Index].T <= Clock) do
				for Y, Line in pairs(Data.Frames[Index].Lines) do
					if (Y <= H) then
						Screen.setCursorPos(1, Y)
						Screen.blit(Line[1]:sub(1, W), Line[2]:sub(1, W), Line[3]:sub(1, W))
					end
				end
				Index = Index + 1
			end
			Timer = os.startTimer(.05)
		end
	end
	sleep(.5)
	Screen.setVisible(false)
	BlockOS.SetFullscreen(false)
	sleep(0)
	Page:Resize()
	Page:Draw()
end

local PlayerTemplate = [[
-- BlockOS recording player (exported by Recorder)
local Data = textutils.unserialise(%q)
local W, H = term.getSize()
term.setBackgroundColor(colors.black)
term.clear()
local Start = os.epoch("utc")
for _, Frame in ipairs(Data.Frames) do
	local Wait = Frame.T - (os.epoch("utc") - Start)
	if (Wait > 0) then sleep(Wait / 1000) end
	for Y, Line in pairs(Frame.Lines) do
		if (Y <= H) then
			term.setCursorPos(1, Y)
			term.blit(Line[1]:sub(1, W), Line[2]:sub(1, W), Line[3]:sub(1, W))
		end
	end
end
term.setCursorPos(1, H)
]]

local function Export(Item)
	local Data = Config.ReadText(Item.Path)
	if (not Data) then return end
	local Target = Item.Path:gsub("%.rec$", "") .. " player.lua"
	Config.WriteText(Target, string.format(PlayerTemplate, Data))
	Ui.Alert("Export", "Saved a standalone player to " .. Target .. ". Run it on any advanced computer.")
	Build()
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 1, W = W, H = 4,
		OnDraw = function(Self, T, Th)
			Gfx.Fill(T, Self.X, Self.Y, Self.W, Self.H, Th.Panel)
			local Color = Recording and colors.red or colors.gray
			Gfx.Fill(T, Self.X + 2, Self.Y + 1, 4, 2, Recording and colors.red or Th.WindowBg)
			Gfx.Write(T, Self.X + 3, Self.Y + 1, "\7\7", Recording and colors.white or colors.red, Recording and colors.red or Th.WindowBg)
			if (Recording) then
				local Seconds = math.floor((os.epoch("utc") - Recording.Started) / 1000)
				Gfx.Write(T, Self.X + 8, Self.Y + 1, string.format("Recording %d:%02d", math.floor(Seconds / 60), Seconds % 60), Color, Th.Panel)
				Gfx.Write(T, Self.X + 8, Self.Y + 2, #Recording.Frames .. " frames \7 click to stop", Th.SubText, Th.Panel)
			else
				Gfx.Write(T, Self.X + 8, Self.Y + 1, "Record Screen", Th.PanelFg, Th.Panel)
				Gfx.Write(T, Self.X + 8, Self.Y + 2, Gfx.Truncate("Stop from the REC item in the menu bar", Self.W - 9), Th.SubText, Th.Panel)
			end
		end,
		OnEvent = function(_, Name)
			if (Name ~= "mouse_click") then return false end
			if (Recording) then StopRecording() else StartRecording() end
			return true
		end
	}))
	Page:Add(Ui.Checkbox.new({ X = 2, Y = 6, Text = "Hide window", Value = Options.Hide, OnChange = function(_, Value) Options.Hide = Value end }))
	Page:Add(Ui.Checkbox.new({ X = 18, Y = 6, Text = "Countdown", Value = Options.Countdown, OnChange = function(_, Value) Options.Countdown = Value end }))
	local List = Page:Add(Ui.List.new({ X = 1, Y = 8, W = W, H = H - 8 }))
	List:SetItems(ListRecordings())
	List.OnActivate = function(_, _, Item) Play(Item.Path) end
	List.OnContext = function(_, _, Item, X, Y)
		if (not Item) then return end
		local Choices = { "Play", "Export Player", "Rename", "Show in Finder", "-", "Delete" }
		local Choice = Choices[Ui.ContextMenu(X, Y, Choices) or 0]
		if (Choice == "Play") then
			Play(Item.Path)
		elseif (Choice == "Export Player") then
			Export(Item)
		elseif (Choice == "Rename") then
			local Name = Ui.Prompt("Rename", "Name:", Item.Text)
			if (Name and #Name > 0) then
				local Target = fs.combine(Folder, Name .. ".rec")
				if (not fs.exists(Target)) then fs.move(Item.Path, Target) end
				Build()
			end
		elseif (Choice == "Show in Finder") then
			BlockOS.Launch("finder", { Folder })
		elseif (Choice == "Delete") then
			if (Ui.Confirm("Delete", "Delete \"" .. Item.Text .. "\"?", "Delete")) then
				fs.delete(Item.Path)
				Build()
			end
		end
	end
	if (#List.Items == 0) then
		Page:Add(Ui.Label.new({ X = 2, Y = 9, W = W - 2, Text = "No recordings yet.", Fg = "SubText" }))
	end
	Page:Add(Ui.Label.new({ X = 1, Y = H, W = W, Bg = "Panel", Fg = "SubText", Text = " Double-click to play \7 space pauses" }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_recorder_stop") then
		StopRecording()
		return true
	elseif (Name == "blockos_open" and A) then
		Play(A)
		return true
	end
	return false
end

function Page:OnTerminate()
	StopRecording()
	self:Stop()
end

Page:SetInterval(1, function() return Recording ~= nil end)

if (Args[1] and fs.exists(Args[1])) then
	Play(Args[1])
end
Page:Run()
StopRecording()
