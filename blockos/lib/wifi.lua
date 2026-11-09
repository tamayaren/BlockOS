-- Wi-Fi: switches modems on and off. A modem that is off is closed and cannot be opened
-- or transmit on until it is switched back on, whichever app or API tries (rednet, gps, wrap).

local Config = BlockOS.Require("config")

local Wifi = {}

-- Modem methods that put a modem on the air.
local Guarded = { open = true, transmit = true }

local RawCall = peripheral.call

local function IsModem(Name)
	return type(Name) == "string" and peripheral.getType(Name) == "modem"
end

function Wifi.IsWireless(Name)
	local Ok, Wireless = pcall(RawCall, Name, "isWireless")
	return Ok and Wireless == true
end

-- Wi-Fi itself (every wireless and ender modem) is on unless turned off in Settings or the Control Center.
function Wifi.On()
	return Config.Settings().WiFi ~= false
end

-- Whether a modem may be used: not switched off on its own, and Wi-Fi on if it is wireless.
function Wifi.Allowed(Name)
	local Settings = Config.Settings()
	if ((Settings.ModemsOff or {})[Name]) then return false end
	if (Settings.WiFi == false and Wifi.IsWireless(Name)) then return false end
	return true
end

-- Every attached modem: { Name, Wireless, Allowed, Open }.
function Wifi.Modems()
	local List = {}
	for _, Name in ipairs(peripheral.getNames()) do
		if (IsModem(Name)) then
			table.insert(List, {
				Name = Name,
				Wireless = Wifi.IsWireless(Name),
				Allowed = Wifi.Allowed(Name),
				Open = rednet.isOpen(Name)
			})
		end
	end
	return List
end

-- Short status for the Control Center: "On", "Off" or "No modem".
function Wifi.Status()
	if (not Wifi.On()) then return "Off" end
	for _, Modem in ipairs(Wifi.Modems()) do
		if (Modem.Wireless and Modem.Allowed) then return "On" end
	end
	return "No modem"
end

function Wifi.SetOn(Value)
	Config.Settings().WiFi = Value and true or false
	Config.Save("settings")
	Wifi.Apply()
end

function Wifi.SetModem(Name, Value)
	local Settings = Config.Settings()
	Settings.ModemsOff = Settings.ModemsOff or {}
	Settings.ModemsOff[Name] = (not Value) and true or nil
	Config.Save("settings")
	Wifi.Apply()
end

-- Closes every modem that is switched off. Apps reopen the others the next time they need them.
function Wifi.Apply()
	for _, Name in ipairs(peripheral.getNames()) do
		if (IsModem(Name) and not Wifi.Allowed(Name)) then
			pcall(RawCall, Name, "closeAll")
		end
	end
end

-- Guards peripheral.call, which rednet, gps and wrapped modems all go through. Installed once by the desktop.
function Wifi.Install()
	if (Wifi.Installed) then return end
	Wifi.Installed = true
	peripheral.call = function(Name, Method, ...)
		if (Guarded[Method] and IsModem(Name) and not Wifi.Allowed(Name)) then
			return nil
		end
		return RawCall(Name, Method, ...)
	end
	Wifi.Apply()
end

return Wifi
