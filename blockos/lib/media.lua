-- Shared audio state: the system volume and what is playing right now, for the Control Center.

local Config = BlockOS.Require("config")

local Media = {}

Media.Source = nil

-- System volume from 0 to 1. Apps multiply their own volume by it.
function Media.Volume()
	local Value = tonumber(Config.Settings().Volume) or 100
	return math.max(0, math.min(100, Value)) / 100
end

-- An app that plays audio registers Describe, which returns
-- { Title = ..., Artist = ..., State = "playing" | "paused" | "loading" | "stopped", Elapsed = s, Total = s }.
-- The app receives "blockos_media" events with "toggle", "next" or "previous" from the Control Center.
function Media.SetSource(Describe)
	local Current = BlockOS.Current and BlockOS.Current()
	Media.Source = { Describe = Describe, Owner = Current and Current.ID }
end

function Media.ClearSource(Describe)
	if (Media.Source and (Describe == nil or Media.Source.Describe == Describe)) then
		Media.Source = nil
	end
end

-- What is playing, or nil when nothing is. Owner is the process ID of the app playing it.
function Media.Now()
	local Source = Media.Source
	if (not Source) then return nil end
	local Ok, Info = pcall(Source.Describe)
	if (not Ok or type(Info) ~= "table" or not Info.State or Info.State == "stopped") then return nil end
	Info.Owner = Source.Owner
	return Info
end

function Media.Send(Action)
	os.queueEvent("blockos_media", Action)
end

return Media
