-- Clock: big clock, alarms (real or Minecraft time), stopwatch and timer.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Schedule = BlockOS.Require("schedule")

local Page = Ui.Page.new()
local Tab = 1
local Build

local Font = Gfx.Font

local Stopwatch = { Running = false, Start = 0, Elapsed = 0, Laps = {} }
local Timer = { Running = false, Duration = 300000, Remaining = 300000, EndsAt = 0, Fired = false }

local function Now()
	return os.epoch("utc")
end

local function BigWidth(Text)
	local Width = 0
	for Index = 1, #Text do
		local Glyph = Font[Text:sub(Index, Index)]
		Width = Width + (Glyph and #Glyph[1] or 1) + 1
	end
	return Width - 1
end

local function DrawBig(T, X, Y, Text, Color, Bg)
	for Index = 1, #Text do
		local Glyph = Font[Text:sub(Index, Index)]
		if (Glyph) then
			for Row = 1, 5 do
				local Line = Glyph[Row]
				for Column = 1, #Line do
					local Filled = Line:sub(Column, Column) == "#"
					Gfx.Write(T, X + Column - 1, Y + Row - 1, " ", Color, Filled and Color or Bg)
				end
			end
			X = X + #Glyph[1] + 1
		else
			X = X + 2
		end
	end
end

local function CenterBig(T, Y, Text, Color, Bg, W)
	DrawBig(T, math.floor((W - BigWidth(Text)) / 2) + 1, Y, Text, Color, Bg)
end

local function FormatDuration(Milliseconds, Centis)
	local Total = math.max(0, math.floor(Milliseconds / 1000))
	local Hours = math.floor(Total / 3600)
	local Minutes = math.floor(Total / 60) % 60
	local Seconds = Total % 60
	local Text
	if (Hours > 0) then
		Text = string.format("%d:%02d:%02d", Hours, Minutes, Seconds)
	else
		Text = string.format("%02d:%02d", Minutes, Seconds)
	end
	if (Centis) then
		Text = Text .. string.format(".%02d", math.floor(Milliseconds / 10) % 100)
	end
	return Text
end

local function StopwatchTime()
	if (Stopwatch.Running) then
		return Stopwatch.Elapsed + (Now() - Stopwatch.Start)
	end
	return Stopwatch.Elapsed
end

local function TimerRemaining()
	if (Timer.Running) then
		return math.max(0, Timer.EndsAt - Now())
	end
	return Timer.Remaining
end

local function BuildClock(W, H)
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = W, H = H - 1,
		OnDraw = function(Self, T, Th)
			local Settings = Config.Settings()
			local Text = os.date(Settings.Clock24 and "%H:%M" or "%I:%M")
			CenterBig(T, Self.Y + 1, Text, Th.Accent, Th.WindowBg, W)
			Gfx.Center(T, Self.Y + 7, os.date("%A, %d %B %Y") .. "  " .. os.date(":%S") .. (Settings.Clock24 and "" or os.date(" %p")), Th.Text, Th.WindowBg)
			local Game = textutils.formatTime(os.time(), Settings.Clock24)
			Gfx.Center(T, Self.Y + 9, "Minecraft: Day " .. os.day() .. ", " .. Game, Th.SubText, Th.WindowBg)
			local Hours = os.time()
			local Phase = (Hours >= 6 and Hours < 18) and "\15 Daytime" or "\7 Night"
			Gfx.Center(T, Self.Y + 10, Phase, (Hours >= 6 and Hours < 18) and colors.orange or colors.lightBlue, Th.WindowBg)
		end
	}))
end

local function FormatAlarm(Alarm)
	if (Alarm.Source == "game") then
		return textutils.formatTime(Alarm.Time, true) .. " MC"
	end
	return string.format("%02d:%02d", math.floor(Alarm.Time / 60), Alarm.Time % 60)
end

local function BuildAlarms(W, H)
	local Data = Schedule.Load()
	local List = Page:Add(Ui.List.new({ X = 1, Y = 2, W = W, H = H - 3 }))
	local Items = {}
	for _, Alarm in ipairs(Data.Alarms) do
		table.insert(Items, {
			Text = FormatAlarm(Alarm) .. "  " .. (Alarm.Label or "Alarm"),
			Icon = Alarm.Enabled and "\7" or "o",
			IconFg = Alarm.Enabled and "Accent" or "SubText",
			Right = Alarm.Enabled and "on" or "off",
			Alarm = Alarm
		})
	end
	List:SetItems(Items)
	List.OnActivate = function(_, _, Item)
		Item.Alarm.Enabled = not Item.Alarm.Enabled
		Schedule.Save()
		Build()
	end
	List.OnContext = function(_, _, Item, X, Y)
		if (not Item) then return end
		local Choice = Ui.ContextMenu(X, Y, { Item.Alarm.Enabled and "Turn Off" or "Turn On", "Delete" })
		if (Choice == 1) then
			Item.Alarm.Enabled = not Item.Alarm.Enabled
			Schedule.Save()
		elseif (Choice == 2) then
			Schedule.RemoveAlarm(Item.Alarm.ID)
		end
		Build()
	end
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = 2, Y = 3, W = W - 2, Text = "No alarms. Alarms ring while BlockOS is running.", Fg = "SubText", H = 2 }))
	end
	Page:Add(Ui.Button.new({ X = 2, Y = H, Text = " + Add Alarm ", Style = "primary", OnClick = function()
		local Index = Ui.Choose("Alarm clock", { "Real time", "Minecraft time" })
		if (not Index) then return end
		local Text = Ui.Prompt("New Alarm", "Time (HH:MM, 24-hour):", Index == 1 and os.date("%H:%M") or "06:00")
		if (not Text) then return end
		local Hour, Minute = Text:match("^(%d%d?):(%d%d)$")
		if (not Hour or tonumber(Hour) > 23 or tonumber(Minute) > 59) then
			Ui.Alert("New Alarm", "Enter the time as HH:MM.")
			return
		end
		local Label = Ui.Prompt("New Alarm", "Label:", "Alarm") or "Alarm"
		if (Index == 1) then
			Schedule.AddAlarm({ Label = Label, Time = tonumber(Hour) * 60 + tonumber(Minute), Source = "real" })
		else
			Schedule.AddAlarm({ Label = Label, Time = tonumber(Hour) + tonumber(Minute) / 60, Source = "game" })
		end
		Build()
	end }))
	Page:Add(Ui.Label.new({ X = 18, Y = H, W = W - 18, Text = "Double-click toggles", Fg = "SubText" }))
end

local function BuildStopwatch(W, H)
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = W, H = 6,
		OnDraw = function(Self, T, Th)
			local Text = FormatDuration(StopwatchTime(), false)
			CenterBig(T, Self.Y + 1, Text, Stopwatch.Running and Th.Accent or Th.Text, Th.WindowBg, W)
			Gfx.Center(T, Self.Y + 6, string.format(".%02d", math.floor(StopwatchTime() / 10) % 100), Th.SubText, Th.WindowBg)
		end
	}))
	local Laps = {}
	for Index = #Stopwatch.Laps, 1, -1 do
		table.insert(Laps, { Text = "Lap " .. Index, Right = FormatDuration(Stopwatch.Laps[Index], true) })
	end
	Page:Add(Ui.List.new({ X = 2, Y = 9, W = W - 2, H = math.max(1, H - 10), Items = Laps }))
	Page:Add(Ui.Button.new({ X = 2, Y = H, W = 9, Text = function() return Stopwatch.Running and "Stop" or "Start" end, Style = "primary", OnClick = function()
		if (Stopwatch.Running) then
			Stopwatch.Elapsed = StopwatchTime()
			Stopwatch.Running = false
		else
			Stopwatch.Start = Now()
			Stopwatch.Running = true
		end
	end }))
	Page:Add(Ui.Button.new({ X = 12, Y = H, W = 7, Text = "Lap", OnClick = function()
		if (Stopwatch.Running) then
			table.insert(Stopwatch.Laps, StopwatchTime())
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = 20, Y = H, W = 8, Text = "Reset", OnClick = function()
		Stopwatch = { Running = false, Start = 0, Elapsed = 0, Laps = {} }
		Build()
	end }))
end

local function BuildTimer(W, H)
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = W, H = 6,
		OnDraw = function(Self, T, Th)
			local Remaining = TimerRemaining()
			CenterBig(T, Self.Y + 1, FormatDuration(Remaining + 999, false), Timer.Running and Th.Accent or Th.Text, Th.WindowBg, W)
		end
	}))
	Page:Add(Ui.Progress.new({ X = 3, Y = 8, W = W - 4, Value = function()
		return Timer.Duration > 0 and (1 - TimerRemaining() / Timer.Duration) or 0
	end }))
	local function Adjust(Delta)
		if (Timer.Running) then return end
		Timer.Remaining = math.max(0, Timer.Remaining + Delta)
		Timer.Duration = Timer.Remaining
	end
	local Presets = { { "-1m", -60000 }, { "+1m", 60000 }, { "+5m", 300000 }, { "+10s", 10000 } }
	local X = 2
	for _, Preset in ipairs(Presets) do
		Page:Add(Ui.Button.new({ X = X, Y = 10, W = 6, Text = Preset[1], OnClick = function() Adjust(Preset[2]) end }))
		X = X + 7
	end
	Page:Add(Ui.Button.new({ X = 2, Y = H, W = 9, Text = function() return Timer.Running and "Pause" or "Start" end, Style = "primary", OnClick = function()
		if (Timer.Running) then
			Timer.Remaining = TimerRemaining()
			Timer.Running = false
		elseif (Timer.Remaining > 0) then
			Timer.EndsAt = Now() + Timer.Remaining
			Timer.Running = true
			Timer.Fired = false
		end
	end }))
	Page:Add(Ui.Button.new({ X = 12, Y = H, W = 8, Text = "Reset", OnClick = function()
		Timer.Running = false
		Timer.Remaining = Timer.Duration
	end }))
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Page:Add(Ui.Tabs.new({
		X = 1, Y = 1, W = W, Items = { "Clock", "Alarms", "Stopwatch", "Timer" }, Selected = Tab,
		OnChange = function(_, Index)
			Tab = Index
			Build()
		end
	}))
	local Builders = { BuildClock, BuildAlarms, BuildStopwatch, BuildTimer }
	Builders[Tab](W, H)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name)
	if (Name == "blockos_schedule" and Tab == 2) then
		Build()
		return true
	end
	return false
end

Page:SetInterval(.1, function()
	if (Timer.Running and TimerRemaining() <= 0 and not Timer.Fired) then
		Timer.Fired = true
		Timer.Running = false
		Timer.Remaining = 0
		BlockOS.Notify("Timer", "Time's up!", { AppID = "clock", Repeat = 3, Duration = 10 })
	end
	if (Tab == 1) then
		return os.clock() % 1 < .1
	end
	return (Tab == 3 and Stopwatch.Running) or (Tab == 4)
end)

Page:Run()
