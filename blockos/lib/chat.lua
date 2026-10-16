-- Messages backend: rooms over rednet with optional shared-key encryption.
-- Encrypted rooms use a SHA-256 keystream with an HMAC tag; wrong keys are dropped silently.

local Config = BlockOS.Require("config")
local Sha256 = BlockOS.Require("sha256")

local Chat = {}

Chat.Protocol = "blockos_chat"
Chat.HistoryLimit = 150
Chat.Loaded = false
Chat.Nick = nil
Chat.Rooms = {}
Chat.Order = {}
Chat.Seen = {}

local DataPath = "/blockos/data/chat.dat"

local function ToHex(Text)
	return (Text:gsub(".", function(Char) return string.format("%02x", Char:byte()) end))
end

local function FromHex(Text)
	return (Text:gsub("%x%x", function(Pair) return string.char(tonumber(Pair, 16)) end))
end

local function RandomHex(Length)
	local Parts = {}
	for Index = 1, Length do
		Parts[Index] = string.format("%x", math.random(0, 15))
	end
	return table.concat(Parts)
end

local function Keystream(Key, Nonce, Length)
	local Blocks = {}
	local Counter = 0
	local Total = 0
	while (Total < Length) do
		local Block = Sha256.Digest(Key .. Nonce .. Counter)
		table.insert(Blocks, Block)
		Total = Total + #Block
		Counter = Counter + 1
	end
	return table.concat(Blocks):sub(1, Length)
end

local function Xor(Text, Stream)
	local Out = {}
	for Index = 1, #Text do
		Out[Index] = string.char(bit32.bxor(Text:byte(Index), Stream:byte(Index)))
	end
	return table.concat(Out)
end

function Chat.RoomID(Name)
	return Sha256.Hex("blockos-room:" .. Name:lower()):sub(1, 16)
end

local function RoomKey(Room)
	if (not Room.Key or Room.Key == "") then return nil end
	if (not Room.KeyBytes) then
		Room.KeyBytes = Sha256.Digest(Room.Key .. ":" .. Room.Name:lower())
	end
	return Room.KeyBytes
end

local function Seal(Room, Payload)
	local Text = textutils.serialise(Payload)
	local Key = RoomKey(Room)
	if (not Key) then
		return { Plain = Text }
	end
	local Nonce = RandomHex(16)
	local Cipher = Xor(Text, Keystream(Key, Nonce, #Text))
	return {
		Nonce = Nonce,
		Body = ToHex(Cipher),
		Tag = ToHex(Sha256.Hmac(Key, Nonce .. Cipher):sub(1, 8))
	}
end

local function Open(Room, Packet)
	local Key = RoomKey(Room)
	local Text
	if (Key) then
		if (type(Packet.Body) ~= "string" or type(Packet.Nonce) ~= "string" or type(Packet.Tag) ~= "string") then return nil end
		local Cipher = FromHex(Packet.Body)
		if (ToHex(Sha256.Hmac(Key, Packet.Nonce .. Cipher):sub(1, 8)) ~= Packet.Tag) then return nil end
		Text = Xor(Cipher, Keystream(Key, Packet.Nonce, #Cipher))
	else
		if (type(Packet.Plain) ~= "string") then return nil end
		Text = Packet.Plain
	end
	local Payload = textutils.unserialise(Text)
	if (type(Payload) ~= "table") then return nil end
	return Payload
end

function Chat.Load()
	if (Chat.Loaded) then return end
	Chat.Loaded = true
	local Data = Config.Read(DataPath) or {}
	Chat.Nick = Data.Nick
	Chat.Rooms = {}
	Chat.Order = {}
	for _, Saved in ipairs(Data.Rooms or {}) do
		local Room = Chat.Join(Saved.Name, Saved.Key, Saved.Target, true)
		Room.Messages = Saved.Messages or {}
	end
	if (#Chat.Order == 0) then
		Chat.Join("general", nil, nil, true)
	end
end

function Chat.Save()
	local Data = { Nick = Chat.Nick, Rooms = {} }
	for _, ID in ipairs(Chat.Order) do
		local Room = Chat.Rooms[ID]
		local Messages = {}
		for Index = math.max(1, #Room.Messages - Chat.HistoryLimit + 1), #Room.Messages do
			table.insert(Messages, Room.Messages[Index])
		end
		table.insert(Data.Rooms, { Name = Room.Name, Key = Room.Key, Target = Room.Target, Messages = Messages })
	end
	Config.Write(DataPath, Data)
end

function Chat.GetNick()
	Chat.Load()
	if (Chat.Nick) then return Chat.Nick end
	local Users = BlockOS.Require("users")
	local User = Users.Primary()
	return (User and User.Name) or os.getComputerLabel() or ("user" .. os.getComputerID())
end

function Chat.SetNick(Nick)
	Chat.Nick = Nick
	Chat.Save()
end

function Chat.Join(Name, Key, Target, Silent)
	local ID = Target and ("dm:" .. math.min(Target, os.getComputerID()) .. ":" .. math.max(Target, os.getComputerID())) or Chat.RoomID(Name)
	if (Chat.Rooms[ID]) then return Chat.Rooms[ID] end
	local Room = {
		ID = ID,
		Name = Name,
		Key = (Key ~= "" and Key) or nil,
		Target = Target,
		Messages = {},
		Users = {},
		Unread = 0
	}
	Chat.Rooms[ID] = Room
	table.insert(Chat.Order, ID)
	if (not Silent) then
		Chat.Save()
		Chat.Presence(Room)
	end
	return Room
end

function Chat.Leave(ID)
	local Room = Chat.Rooms[ID]
	if (not Room) then return end
	Chat.Transmit(Room, "leave", {})
	Chat.Rooms[ID] = nil
	for Index, Other in ipairs(Chat.Order) do
		if (Other == ID) then
			table.remove(Chat.Order, Index)
			break
		end
	end
	Chat.Save()
end

function Chat.OpenModems()
	if (not rednet) then return false end
	local Any = false
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "modem") then
			if (not rednet.isOpen(Side)) then
				pcall(rednet.open, Side)
			end
			Any = true
		end
	end
	return Any
end

function Chat.Transmit(Room, Kind, Payload)
	if (not Chat.OpenModems()) then return false, "No modem attached" end
	Payload.Nick = Chat.GetNick()
	local Packet = Seal(Room, Payload)
	Packet.App = "BlockOS"
	Packet.V = 1
	Packet.Type = Kind
	Packet.Room = Room.ID
	Packet.MsgID = RandomHex(12)
	Chat.Seen[Packet.MsgID] = true
	if (Room.Target) then
		Packet.DMFrom = os.getComputerID()
		rednet.send(Room.Target, Packet, Chat.Protocol)
	else
		rednet.broadcast(Packet, Chat.Protocol)
	end
	return true
end

local function Append(Room, Message)
	table.insert(Room.Messages, Message)
	if (#Room.Messages > Chat.HistoryLimit * 2) then
		table.remove(Room.Messages, 1)
	end
end

function Chat.Send(ID, Text, Kind)
	local Room = Chat.Rooms[ID]
	if (not Room) then return false, "Unknown room" end
	Kind = Kind or "msg"
	local Ok, Err = Chat.Transmit(Room, Kind, { Text = Text })
	local Message = {
		Nick = Chat.GetNick(),
		Text = Text,
		Kind = Kind,
		Time = os.epoch("utc"),
		Self = true,
		Failed = not Ok
	}
	Append(Room, Message)
	Chat.Save()
	return Ok, Err
end

function Chat.Presence(Room)
	if (Room) then
		if (not Room.Target) then Chat.Transmit(Room, "presence", {}) end
		return
	end
	for _, ID in ipairs(Chat.Order) do
		local Other = Chat.Rooms[ID]
		if (not Other.Target) then Chat.Transmit(Other, "presence", {}) end
	end
end

function Chat.OnlineUsers(Room)
	local Now = os.epoch("utc")
	local List = {}
	for Sender, Info in pairs(Room.Users) do
		if (Now - Info.Seen < 90000) then
			table.insert(List, { ID = Sender, Nick = Info.Nick })
		end
	end
	table.sort(List, function(A, B) return A.Nick:lower() < B.Nick:lower() end)
	return List
end

-- Processes a rednet packet. Returns the room and message when something should be shown.
function Chat.Receive(Sender, Packet)
	Chat.Load()
	if (type(Packet) ~= "table" or Packet.App ~= "BlockOS" or type(Packet.Room) ~= "string") then return nil end
	if (Packet.MsgID and Chat.Seen[Packet.MsgID]) then return nil end
	if (Packet.MsgID) then Chat.Seen[Packet.MsgID] = true end
	local Room = Chat.Rooms[Packet.Room]
	if (not Room and Packet.DMFrom == Sender) then
		local ID = "dm:" .. math.min(Sender, os.getComputerID()) .. ":" .. math.max(Sender, os.getComputerID())
		if (ID == Packet.Room) then
			Room = Chat.Join("@" .. Sender, nil, Sender, true)
		end
	end
	if (not Room) then return nil end
	local Payload = Open(Room, Packet)
	if (not Payload) then return nil end
	local Nick = tostring(Payload.Nick or ("#" .. Sender)):sub(1, 20)
	if (Packet.Type == "leave") then
		Room.Users[Sender] = nil
		return nil
	end
	local Known = Room.Users[Sender] ~= nil
	Room.Users[Sender] = { Nick = Nick, Seen = os.epoch("utc") }
	if (Packet.Type == "presence") then
		if (not Known) then
			Chat.Transmit(Room, "presence", {})
		end
		return nil
	end
	if (Packet.Type ~= "msg" and Packet.Type ~= "me") then return nil end
	local Message = {
		Nick = Nick,
		Text = tostring(Payload.Text or ""):sub(1, 500),
		Kind = Packet.Type,
		Time = os.epoch("utc"),
		Sender = Sender
	}
	Append(Room, Message)
	Room.Unread = Room.Unread + 1
	Chat.Save()
	return Room, Message
end

function Chat.UnreadTotal()
	local Total = 0
	for _, Room in pairs(Chat.Rooms) do
		Total = Total + Room.Unread
	end
	return Total
end

return Chat
