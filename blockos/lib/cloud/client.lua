-- BlockCloud client library for BlockOS apps: discovers servers, pairs with them, and makes
-- signed requests with timeouts and bounded retries. Paired servers are remembered in
-- /blockos/data/cloud/servers.dat.
--
--   local Client = BlockOS.Require("cloud/client")
--   local Nodes = Client.Discover()                      -- servers in range
--   local Result, Err = Client.Call(Server, "blockdrive", "list", { Path = "Shared" })
--
-- Calls block the calling coroutine while waiting; GUI apps run them as background tasks
-- (see cloud/tasks) so the window stays responsive.

local Config = BlockOS.Require("config")
local Protocol = BlockOS.Require("cloud/protocol")
local Auth = BlockOS.Require("cloud/auth")
local Codec = BlockOS.Require("cloud/codec")

local Client = {}

Client.Path = "/blockos/data/cloud/servers.dat"
-- Three tries with growing waits: a dead server is reported after about 7.5 seconds.
Client.Timeout = 2
Client.Retries = 2
-- NodeID -> { Online = bool, Checked = epoch, Error = text }
Client.Status = {}

local Servers = nil

local function Load()
	if (not Servers) then
		local Saved = Config.Read(Client.Path)
		Servers = type(Saved) == "table" and Saved or {}
	end
	return Servers
end

function Client.Save()
	Config.Write(Client.Path, Load())
end

function Client.Reload()
	Servers = nil
	return Load()
end

function Client.Get(NodeID)
	return Load()[NodeID]
end

function Client.List()
	local List = {}
	for _, Server in pairs(Load()) do
		table.insert(List, Server)
	end
	table.sort(List, function(A, B) return (A.Name or ""):lower() < (B.Name or ""):lower() end)
	return List
end

-- The display name used in BlockDrive: "Data Center" or the hostname.
function Client.Title(Server)
	return Server.Name or Server.Hostname or ("Computer #" .. tostring(Server.ComputerID))
end

local function Mark(Server, Online, Err)
	local Status = Client.Status[Server.NodeID] or {}
	Client.Status[Server.NodeID] = Status
	local Changed = Status.Online ~= Online
	Status.Online = Online
	Status.Checked = os.epoch("utc")
	Status.Error = Err and Protocol.Describe(Err) or nil
	if (Changed) then os.queueEvent("blockcloud_client", Server.NodeID) end
end

function Client.Online(Server)
	local Status = Client.Status[Server.NodeID]
	return Status and Status.Online
end

-- Waits for the response to request ID from ComputerID. Returns the envelope or nil on timeout.
local function Await(ComputerID, ID, ProtocolName, Timeout)
	local Timer = os.startTimer(Timeout)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "timer" and A == Timer) then
			return nil
		elseif (Event == "rednet_message" and A == ComputerID and C == ProtocolName and type(B) == "table" and B.K == "res" and B.ID == ID) then
			os.cancelTimer(Timer)
			return B
		end
	end
end

-- Sends one request and waits for its answer, resending the same request (same ID) on timeout.
-- The server de-duplicates by ID, so a resend never runs an operation twice.
-- Opts: Keys, ClientID, Encrypt, Timeout, Retries. Returns result or nil, { Code, Message }.
function Client.Request(ComputerID, Service, Op, Args, Opts)
	Opts = Opts or {}
	if (Protocol.OpenModems() == 0) then return nil, Protocol.Error("no_modem") end
	local ProtocolName = Protocol.Name(Service)
	local Msg = Protocol.Seal({ K = "req", ID = Protocol.NewID(), Svc = Service, Op = Op, Cl = Opts.ClientID }, Args or {}, Opts.Keys, Opts.Encrypt)
	local Timeout = Opts.Timeout or Client.Timeout
	local Response
	for _ = 0, Opts.Retries or Client.Retries do
		rednet.send(ComputerID, Msg, ProtocolName)
		Response = Await(ComputerID, Msg.ID, ProtocolName, Timeout)
		if (Response) then break end
		Timeout = Timeout * 1.25
	end
	if (not Response) then return nil, Protocol.Error("unavailable") end
	if (not Protocol.Valid(Response)) then return nil, Protocol.Error("invalid") end
	local Body, Err = Protocol.Open(Response, Response.S and Opts.Keys or nil)
	if (Err) then return nil, Protocol.Error(Err) end
	if (type(Body) ~= "table") then return nil, Protocol.Error("invalid") end
	-- Unsigned answers are only believed when they are errors about the pairing itself.
	if (Opts.Keys and not Response.S and not (Body.Ok == false and (Body.Code == "not_paired" or Body.Code == "bad_signature"))) then
		return nil, Protocol.Error("bad_signature")
	end
	if (Body.Ok) then return Body.R end
	return nil, Protocol.Error(Body.Code or "internal", Body.Msg)
end

-- Broadcasts a discovery request and collects announcements for Timeout seconds.
-- Returns a list of nodes: { ComputerID, NodeID, Hostname, Name, Version, Services, Paired }.
function Client.Discover(Timeout)
	if (Protocol.OpenModems() == 0) then return nil, Protocol.Error("no_modem") end
	rednet.broadcast({ BC = Protocol.Version, K = "discover" }, Protocol.Discover)
	local Found, List = {}, {}
	local Timer = os.startTimer(Timeout or 2)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "timer" and A == Timer) then break end
		if (Event == "rednet_message" and C == Protocol.Discover) then
			local Node = Client.HandleAnnounce(A, B)
			if (Node and not Found[Node.NodeID]) then
				Found[Node.NodeID] = true
				table.insert(List, Node)
			end
		end
	end
	table.sort(List, function(X, Y) return (X.Name or ""):lower() < (Y.Name or ""):lower() end)
	return List
end

-- Processes an announcement (from discovery or a server booting). Keeps paired servers'
-- details current and marks them online. Returns the node, or nil if the message is not one.
function Client.HandleAnnounce(Sender, Message)
	if (type(Message) ~= "table" or Message.BC ~= Protocol.Version or Message.K ~= "announce" or type(Message.Node) ~= "table") then return nil end
	local Node = Message.Node
	if (type(Node.NodeID) ~= "string" or not Node.NodeID:match("^%x+$")) then return nil end
	local Entry = {
		ComputerID = Sender,
		NodeID = Node.NodeID,
		Hostname = tostring(Node.Hostname or ""):sub(1, 24),
		Name = tostring(Node.Name or Node.Hostname or ""):sub(1, 32),
		Version = tostring(Node.Version or "?"),
		Encrypt = Node.Encrypt ~= false,
		Pairing = Node.Pairing ~= false,
		Services = type(Node.Services) == "table" and Node.Services or {}
	}
	local Server = Client.Get(Entry.NodeID)
	if (Server) then
		Entry.Paired = true
		-- An unsigned announcement may only move a server whose old computer stopped answering.
		if (Server.ComputerID ~= Sender and Client.Online(Server)) then return Entry end
		Server.ComputerID = Sender
		Server.Hostname = Entry.Hostname
		Server.Name = Entry.Name
		Server.Encrypt = Entry.Encrypt
		Server.Services = Entry.Services
		Mark(Server, true)
	end
	return Entry
end

local function Options(Server, Opts)
	local Result = { Keys = Auth.Keys(Server.Key), ClientID = Server.ClientID, Encrypt = Server.Encrypt }
	for Key, Value in pairs(Opts or {}) do Result[Key] = Value end
	return Result
end

-- Makes a signed call to a paired server (record or NodeID).
function Client.Call(Server, Service, Op, Args, Opts)
	if (type(Server) == "string") then Server = Client.Get(Server) end
	if (not Server) then return nil, Protocol.Error("not_paired") end
	local Result, Err = Client.Request(Server.ComputerID, Service, Op, Args, Options(Server, Opts))
	if (Err and Err.Code == "unavailable") then
		Mark(Server, false, Err)
	elseif (Err and Err.Code == "no_modem") then
		Mark(Server, false, Err)
	else
		Mark(Server, true)
	end
	return Result, Err
end

-- Checks a paired server is reachable and the pairing still holds; refreshes its details.
function Client.Hello(Server)
	local Result, Err = Client.Call(Server, "core", "hello", {}, { Retries = 1 })
	if (not Result) then return nil, Err end
	Server.Permission = Result.Permission
	if (type(Result.Node) == "table") then
		Server.Name = tostring(Result.Node.Name or Server.Name)
		Server.Hostname = tostring(Result.Node.Hostname or Server.Hostname)
		Server.Encrypt = Result.Node.Encrypt ~= false
		Server.Services = type(Result.Node.Services) == "table" and Result.Node.Services or Server.Services
	end
	Client.Save()
	return Result
end

function Client.Forget(NodeID, Notify)
	local Server = Client.Get(NodeID)
	if (not Server) then return end
	if (Notify) then pcall(Client.Call, Server, "core", "unpair", {}, { Retries = 0, Timeout = 1 }) end
	Load()[NodeID] = nil
	Client.Status[NodeID] = nil
	Client.Save()
end

--
-- Pairing
--

-- Asks a discovered server to pair. Returns a session whose Code must be shown to the user,
-- who reads it to the server's administrator.
function Client.StartPairing(Node, Name)
	local Session = {
		Node = Node,
		ComputerID = Node.ComputerID,
		Code = Auth.PairingCode(),
		Nonce = Auth.RandomHex(16)
	}
	local Result, Err = Client.Request(Node.ComputerID, "core", "pair_request", {
		Name = Name or os.getComputerLabel() or ("Computer #" .. os.getComputerID()),
		Nonce = Session.Nonce,
		Check = Auth.CodeCheck(Session.Code, Session.Nonce)
	})
	if (not Result) then return nil, Err end
	if (type(Result.RequestID) ~= "string" or type(Result.ServerNonce) ~= "string") then return nil, Protocol.Error("invalid") end
	Session.RequestID = Result.RequestID
	Session.ServerNonce = Result.ServerNonce
	return Session
end

-- Asks once whether the request was decided. Returns "pending", the new server record, or nil, err.
function Client.PollPairing(Session)
	local Result, Err = Client.Request(Session.ComputerID, "core", "pair_status", { RequestID = Session.RequestID }, { Retries = 1 })
	if (not Result) then return nil, Err end
	if (Result.Status ~= "approved") then return "pending" end
	local Key = Auth.DeriveKey(Session.Code, Session.RequestID, Session.Nonce, Session.ServerNonce)
	local ClientID, Permission = tostring(Result.ClientID), tostring(Result.Permission)
	if (Auth.ApprovalProof(Key, Session.RequestID, ClientID, Permission) ~= Result.Proof) then
		return nil, Protocol.Error("bad_signature", "The approval could not be verified. Pair again and check the code.")
	end
	local Node = type(Result.Node) == "table" and Result.Node or Session.Node
	local Server = {
		NodeID = Session.Node.NodeID,
		ComputerID = Session.ComputerID,
		Hostname = tostring(Node.Hostname or Session.Node.Hostname),
		Name = tostring(Node.Name or Session.Node.Name),
		ClientID = ClientID,
		Key = Codec.ToHex(Key),
		Permission = Permission,
		Encrypt = Node.Encrypt ~= false,
		Services = type(Node.Services) == "table" and Node.Services or {},
		PairedAt = os.epoch("utc")
	}
	Load()[Server.NodeID] = Server
	Client.Save()
	Mark(Server, true)
	return Server
end

-- Waits for the administrator, polling every few seconds and waking early when the server
-- nudges this computer. Cancelled when ShouldStop() returns true. Returns the server or nil, err.
function Client.WaitPairing(Session, ShouldStop, Timeout)
	local Deadline = os.clock() + (Timeout or 600)
	while (os.clock() < Deadline) do
		local Result, Err = Client.PollPairing(Session)
		if (Result ~= "pending") then return Result, Err end
		local Timer = os.startTimer(5)
		while (true) do
			local Event, A, B, C = os.pullEvent()
			if (ShouldStop and ShouldStop()) then
				os.cancelTimer(Timer)
				return nil, Protocol.Error("pairing_expired", "Pairing was cancelled.")
			end
			if (Event == "timer" and A == Timer) then break end
			if (Event == "rednet_message" and A == Session.ComputerID and C == Protocol.Name("core")
				and type(B) == "table" and B.K == "push" and B.ID == Session.RequestID) then
				os.cancelTimer(Timer)
				break
			end
		end
	end
	return nil, Protocol.Error("pairing_expired")
end

return Client
