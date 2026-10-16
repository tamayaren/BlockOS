-- Shared store for reminders and clock alarms; the desktop service fires their notifications.

local Config = BlockOS.Require("config")

local Schedule = {}

local DataPath = "/blockos/data/schedule.dat"

Schedule.Data = nil

function Schedule.Load()
	if (Schedule.Data) then return Schedule.Data end
	local Data = Config.Read(DataPath) or {}
	Data.Lists = Data.Lists or { "Personal", "Work" }
	Data.Reminders = Data.Reminders or {}
	Data.Alarms = Data.Alarms or {}
	Data.NextID = Data.NextID or 1
	Schedule.Data = Data
	return Data
end

function Schedule.Save()
	Config.Write(DataPath, Schedule.Load())
	os.queueEvent("blockos_schedule")
end

function Schedule.Now()
	return math.floor(os.epoch("local") / 1000)
end

function Schedule.AddReminder(Reminder)
	local Data = Schedule.Load()
	Reminder.ID = Data.NextID
	Data.NextID = Data.NextID + 1
	Reminder.Created = Schedule.Now()
	Reminder.Done = false
	table.insert(Data.Reminders, Reminder)
	Schedule.Save()
	return Reminder
end

function Schedule.RemoveReminder(ID)
	local Data = Schedule.Load()
	for Index, Reminder in ipairs(Data.Reminders) do
		if (Reminder.ID == ID) then
			table.remove(Data.Reminders, Index)
			break
		end
	end
	Schedule.Save()
end

function Schedule.AddAlarm(Alarm)
	local Data = Schedule.Load()
	Alarm.ID = Data.NextID
	Data.NextID = Data.NextID + 1
	Alarm.Enabled = true
	table.insert(Data.Alarms, Alarm)
	Schedule.Save()
	return Alarm
end

function Schedule.RemoveAlarm(ID)
	local Data = Schedule.Load()
	for Index, Alarm in ipairs(Data.Alarms) do
		if (Alarm.ID == ID) then
			table.remove(Data.Alarms, Index)
			break
		end
	end
	Schedule.Save()
end

-- Parses "in 10m", "in 2h", "14:30", "tomorrow 9:00", "2026-11-02 08:15" into a local timestamp.
function Schedule.ParseDue(Text)
	Text = tostring(Text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if (Text == "") then return nil end
	local Now = Schedule.Now()
	local Amount, Unit = Text:match("^in%s+(%d+)%s*(%a+)$")
	if (Amount) then
		local Scale = ({ s = 1, sec = 1, m = 60, min = 60, mins = 60, h = 3600, hr = 3600, hour = 3600, hours = 3600, d = 86400, day = 86400, days = 86400 })[Unit]
		if (not Scale) then return nil end
		return Now + tonumber(Amount) * Scale
	end
	local Today = os.date("!*t", Now)
	local function At(Day, Hour, Minute)
		local Base = Now - (Today.hour * 3600 + Today.min * 60 + Today.sec)
		return Base + Day * 86400 + Hour * 3600 + Minute * 60
	end
	local Year, Month, Day, Hour, Minute = Text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)$")
	if (Year) then
		local Target = { year = tonumber(Year), month = tonumber(Month), day = tonumber(Day), hour = 0, min = 0, sec = 0 }
		local Midnight = os.time(Target) - os.time({ year = 1970, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
		return Midnight + tonumber(Hour) * 3600 + tonumber(Minute) * 60
	end
	local Tomorrow, TimeText = Text:match("^(tomorrow)%s*(.*)$")
	if (Tomorrow) then
		local H, M = TimeText:match("^(%d%d?):(%d%d)$")
		return At(1, tonumber(H or 9), tonumber(M or 0))
	end
	local H, M, Suffix = Text:match("^(%d%d?):(%d%d)%s*([ap]?m?)$")
	if (H) then
		H = tonumber(H)
		if (Suffix == "pm" and H < 12) then H = H + 12 end
		if (Suffix == "am" and H == 12) then H = 0 end
		local Target = At(0, H, tonumber(M))
		if (Target <= Now) then Target = Target + 86400 end
		return Target
	end
	return nil
end

function Schedule.FormatDue(Stamp)
	if (not Stamp) then return "" end
	local Now = Schedule.Now()
	local Delta = Stamp - Now
	local Clock = os.date("!%H:%M", Stamp)
	if (os.date("!%Y%m%d", Stamp) == os.date("!%Y%m%d", Now)) then
		return "Today " .. Clock
	elseif (os.date("!%Y%m%d", Stamp) == os.date("!%Y%m%d", Now + 86400)) then
		return "Tomorrow " .. Clock
	elseif (Delta < 0 and Delta > -86400) then
		return "Yesterday " .. Clock
	end
	return os.date("!%b %d %H:%M", Stamp)
end

-- Returns reminders and alarms that just became due, marking them as fired.
function Schedule.CollectDue()
	local Data = Schedule.Load()
	local Now = Schedule.Now()
	local Fired = {}
	local Changed = false
	for _, Reminder in ipairs(Data.Reminders) do
		if (not Reminder.Done and Reminder.Due and not Reminder.Notified and Reminder.Due <= Now) then
			Reminder.Notified = true
			Changed = true
			table.insert(Fired, { Kind = "reminder", Item = Reminder })
		end
	end
	local GameTime = os.time()
	local Day = os.day()
	for _, Alarm in ipairs(Data.Alarms) do
		if (Alarm.Enabled) then
			if (Alarm.Source == "game") then
				local Key = Day
				if (Alarm.LastDay ~= Key and GameTime >= Alarm.Time and GameTime < Alarm.Time + .25) then
					Alarm.LastDay = Key
					Changed = true
					table.insert(Fired, { Kind = "alarm", Item = Alarm })
				end
			else
				local Key = os.date("!%Y%m%d", Now)
				local Minutes = tonumber(os.date("!%H", Now)) * 60 + tonumber(os.date("!%M", Now))
				if (Alarm.LastDay ~= Key and Minutes == Alarm.Time) then
					Alarm.LastDay = Key
					Changed = true
					table.insert(Fired, { Kind = "alarm", Item = Alarm })
				end
			end
		end
	end
	if (Changed) then Schedule.Save() end
	return Fired
end

return Schedule
