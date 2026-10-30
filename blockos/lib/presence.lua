-- Lets BlockOS computers find each other over rednet, with GPS positions when a cluster is in range.

local Config = BlockOS.Require("config")
local Users = BlockOS.Require("users")

local Presence = {}

Presence.Protocol = "blockos_presence"
Presence.Position = nil
Presence.LocatedAt = nil

function Presence.Visible()
	return Config.Settings().NetworkVisible ~= false
end

-- Opens every modem for rednet; returns whether any modem is attached.
function Presence.OpenModems()
	if (not rednet) then return false end
	local Any = false
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "modem") then
			if (not rednet.isOpen(Side)) then pcall(rednet.open, Side) end
			Any = true
		end
	end
	return Any
end

-- Asks the GPS cluster for this computer's position. Blocks for up to Timeout seconds.
function Presence.Locate(Timeout)
	if (not gps) then return nil end
	local Ok, X, Y, Z = pcall(gps.locate, Timeout or 2)
	if (Ok and X) then
		Presence.Position = { X = math.floor(X + .5), Y = math.floor(Y + .5), Z = math.floor(Z + .5) }
	else
		Presence.Position = nil
	end
	Presence.LocatedAt = os.clock()
	return Presence.Position
end

function Presence.Info()
	local User = Users.Primary()
	return {
		Type = "here",
		ID = os.getComputerID(),
		Label = os.getComputerLabel(),
		User = User and User.Name or nil,
		Version = Config.Version(),
		Turtle = turtle ~= nil,
		Position = Presence.Position
	}
end

-- Replies to a scan from another computer, unless this one is hidden.
function Presence.Answer(Sender, Message)
	if (type(Message) ~= "table" or Message.Type ~= "scan") then return false end
	if (Sender == os.getComputerID() or not Presence.Visible()) then return false end
	rednet.send(Sender, Presence.Info(), Presence.Protocol)
	return true
end

function Presence.Scan()
	if (not Presence.OpenModems()) then return false, "No modem attached" end
	rednet.broadcast({ Type = "scan" }, Presence.Protocol)
	return true
end

-- Turns a reply into a tidy record, or nil if it is not one.
function Presence.Parse(Sender, Message)
	if (type(Message) ~= "table" or Message.Type ~= "here") then return nil end
	local Position = type(Message.Position) == "table" and Message.Position or nil
	if (Position and not (tonumber(Position.X) and tonumber(Position.Y) and tonumber(Position.Z))) then
		Position = nil
	end
	return {
		ID = Sender,
		Label = type(Message.Label) == "string" and Message.Label or nil,
		User = type(Message.User) == "string" and Message.User or nil,
		Version = type(Message.Version) == "string" and Message.Version or nil,
		Turtle = Message.Turtle == true,
		Position = Position
	}
end

function Presence.Name(Entry)
	return Entry.Label or ("Computer #" .. Entry.ID)
end

local Directions = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- Distance in blocks and a compass direction from one position to another (north is -Z).
function Presence.Bearing(From, To)
	local DX, DY, DZ = To.X - From.X, To.Y - From.Y, To.Z - From.Z
	local Distance = math.sqrt(DX * DX + DY * DY + DZ * DZ)
	if (DX == 0 and DZ == 0) then return Distance, "" end
	local Angle = math.deg((math.atan2 or math.atan)(DX, -DZ)) % 360
	return Distance, Directions[math.floor((Angle + 22.5) / 45) % 8 + 1]
end

return Presence
