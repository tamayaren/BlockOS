-- BlockCloud network protocol: names, message envelopes, signing and error codes.
-- Shared by the Server Edition services and the client library.
--
-- Every BlockCloud message is a rednet table:
--   { BC = 1, K = "req" | "res" | "push" | "discover" | "announce", ID = request id,
--     Svc = service, Op = operation, Cl = client id, T = epoch ms, N = nonce,
--     E = encrypted?, B = body (Codec-encoded, maybe encrypted), S = signature }
-- Requests and responses between paired computers are signed with HMAC-SHA256 over the
-- header fields and body; pairing and discovery messages are unsigned.

local Codec = BlockOS.Require("cloud/codec")
local Auth = BlockOS.Require("cloud/auth")

local Protocol = {}

Protocol.Version = 1
-- Rednet protocol names. They are namespaced so they never collide with BlockOS Messages
-- (blockos_chat), Network (blockos_presence) or Turtles (blockos_turtle).
Protocol.Discover = "blockcloud/discover"
Protocol.Prefix = "blockcloud/svc/"
-- Requests older or newer than this are rejected as replays; CC computers share the host clock.
Protocol.MaxSkew = 120000
Protocol.MaxBody = 64 * 1024

function Protocol.Name(Service)
	return Protocol.Prefix .. Service
end

function Protocol.ServiceOf(Name)
	if (type(Name) ~= "string" or Name:sub(1, #Protocol.Prefix) ~= Protocol.Prefix) then return nil end
	return Name:sub(#Protocol.Prefix + 1)
end

Protocol.Errors = {
	timeout = "The server did not answer in time.",
	unavailable = "The server is not reachable. Check that it is on and in modem range.",
	no_modem = "No modem is attached to this computer.",
	denied = "You do not have permission to do that.",
	not_paired = "This computer is not paired with the server. Pair it again.",
	bad_signature = "The message could not be verified.",
	replay = "The request was too old or was repeated.",
	invalid = "The request was not valid.",
	invalid_path = "That path is not allowed.",
	invalid_name = "That name is not allowed.",
	not_found = "No such file or folder.",
	exists = "An item with that name already exists.",
	not_dir = "That is not a folder.",
	is_dir = "That is a folder.",
	no_space = "There is not enough storage space on the server.",
	too_large = "That file is too large for this server.",
	busy = "The server is busy. Try again in a moment.",
	transfer_lost = "The transfer was interrupted, probably because the server restarted.",
	checksum = "Data was damaged in transfer.",
	changed = "The file changed on the server during the download.",
	unknown_service = "The server does not offer that service.",
	unknown_op = "The server does not support that operation.",
	pairing_closed = "The server is not accepting new computers right now.",
	pairing_denied = "The administrator declined the pairing request.",
	pairing_expired = "The pairing request expired. Start again.",
	local_io = "A file on this computer could not be read or written.",
	internal = "The server ran into a problem. Check its logs."
}

function Protocol.Error(Code, Detail)
	return { Code = Code, Message = Detail or Protocol.Errors[Code] or Code }
end

-- A readable message for an error table or string.
function Protocol.Describe(Err)
	if (type(Err) == "table") then
		return tostring(Err.Message or Protocol.Errors[Err.Code] or Err.Code or "Unknown error")
	end
	return Protocol.Errors[Err] or tostring(Err)
end

local Token = "^[%w_%-%.]+$"

local function Signed(Msg)
	return table.concat({
		Msg.K, Msg.ID, Msg.Svc, Msg.Op, Msg.Cl or "-", string.format("%d", Msg.T), Msg.N, Msg.E and "1" or "0", Msg.B
	}, "\n")
end

-- Checks the shape of an incoming envelope before anything else looks at it.
function Protocol.Valid(Msg)
	if (type(Msg) ~= "table" or Msg.BC ~= Protocol.Version) then return false end
	if (type(Msg.K) ~= "string" or type(Msg.ID) ~= "string" or #Msg.ID > 48 or not Msg.ID:match(Token)) then return false end
	if (type(Msg.Svc) ~= "string" or not Msg.Svc:match(Token) or type(Msg.Op) ~= "string" or not Msg.Op:match(Token)) then return false end
	if (Msg.Cl ~= nil and (type(Msg.Cl) ~= "string" or not Msg.Cl:match(Token))) then return false end
	if (type(Msg.T) ~= "number" or type(Msg.N) ~= "string" or not Msg.N:match(Token)) then return false end
	if (type(Msg.B) ~= "string" or #Msg.B > Protocol.MaxBody) then return false end
	return true
end

function Protocol.NewID()
	return Auth.RandomHex(10)
end

-- Fills in the body and signature of an envelope. Keys may be nil for unsigned messages.
function Protocol.Seal(Msg, Value, Keys, Encrypt)
	Msg.BC = Protocol.Version
	Msg.T = Msg.T or os.epoch("utc")
	Msg.N = Msg.N or Auth.RandomHex(6)
	local Body = Codec.Encode(Value)
	Msg.E = (Keys ~= nil and Encrypt) and true or false
	if (Msg.E) then
		Body = Auth.Crypt(Keys.Enc, Msg.N .. Msg.ID, Body)
	end
	Msg.B = Body
	Msg.S = Keys and Auth.Sign(Keys, Signed(Msg)) or nil
	return Msg
end

-- Verifies (when Keys are given) and decodes an envelope's body. Returns the value or nil, code.
function Protocol.Open(Msg, Keys)
	if (Keys) then
		if (not Auth.Verify(Keys, Signed(Msg), Msg.S)) then return nil, "bad_signature" end
	elseif (Msg.E) then
		return nil, "invalid"
	end
	local Body = Msg.B
	if (Msg.E) then
		Body = Auth.Crypt(Keys.Enc, Msg.N .. Msg.ID, Body)
	end
	local Value, Err = Codec.Decode(Body)
	if (Err) then return nil, "invalid" end
	return Value
end

function Protocol.Fresh(Msg, Now)
	return math.abs((Now or os.epoch("utc")) - Msg.T) <= Protocol.MaxSkew
end

-- Opens every attached modem for rednet. Returns the number of modems.
function Protocol.OpenModems()
	if (not rednet) then return 0 end
	local Count = 0
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "modem") then
			if (not rednet.isOpen(Side)) then pcall(rednet.open, Side) end
			Count = Count + 1
		end
	end
	return Count
end

-- Lists attached modems: { Side, Wireless, Open }.
function Protocol.Modems()
	local List = {}
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "modem") then
			local Ok, Wireless = pcall(peripheral.call, Side, "isWireless")
			table.insert(List, { Side = Side, Wireless = Ok and Wireless or false, Open = rednet.isOpen(Side) })
		end
	end
	return List
end

return Protocol
