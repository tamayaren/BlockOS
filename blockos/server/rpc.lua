-- BlockCloud request dispatcher. Services register operations here; incoming requests are
-- validated, authenticated, de-duplicated and run in their own worker coroutine so a slow
-- operation never stops the server from receiving other messages.

local Protocol = BlockOS.Require("cloud/protocol")
local Auth = BlockOS.Require("cloud/auth")
local Clients = BlockOS.Require("server/clients")
local Log = BlockOS.Require("server/log")

local Rpc = {}

Rpc.Services = {}
Rpc.Workers = {}
Rpc.MaxWorkers = 8
Rpc.Stats = { Requests = 0, Errors = 0, Rejected = 0, Started = os.epoch("utc") }

local Seen = {}
local Buckets = {}

-- Access is "public" (no pairing needed), "read" or "write".
function Rpc.Register(Service, Ops)
	Rpc.Services[Service] = Rpc.Services[Service] or {}
	for Op, Def in pairs(Ops) do
		Rpc.Services[Service][Op] = Def
	end
end

function Rpc.Unregister(Service)
	Rpc.Services[Service] = nil
end

-- Handlers raise protocol errors with this; anything else is reported as an internal error.
function Rpc.Fail(Code, Detail)
	error({ BlockCloud = true, Code = Code, Message = Detail or Protocol.Errors[Code] }, 0)
end

-- Gives other coroutines a turn during long work (and avoids "too long without yielding").
function Rpc.Yield()
	os.queueEvent("blockcloud_yield")
	os.pullEvent("blockcloud_yield")
end

local function Reply(Sender, ProtocolName, Request, Body, Keys)
	local Response = Protocol.Seal({
		K = "res", ID = Request.ID, Svc = Request.Svc, Op = Request.Op, Cl = Request.Cl
	}, Body, Keys, Request.E)
	rednet.send(Sender, Response, ProtocolName)
	return Response
end

local function ErrorBody(Code, Detail)
	return { Ok = false, Code = Code, Msg = Detail or Protocol.Errors[Code] or Code }
end

-- Unpaired computers get a small budget of public requests, so pairing spam stays cheap.
local function Allowed(Sender)
	local Now = os.epoch("utc")
	local Bucket = Buckets[Sender]
	if (not Bucket or Now - Bucket.Since > 10000) then
		Bucket = { Since = Now, Count = 0 }
		Buckets[Sender] = Bucket
	end
	Bucket.Count = Bucket.Count + 1
	return Bucket.Count <= 30
end

local function Resume(Worker, ...)
	local Ok, Result = coroutine.resume(Worker.Co, ...)
	if (not Ok) then
		Log.Error("rpc", Worker.Label .. ": " .. tostring(Result))
	elseif (coroutine.status(Worker.Co) ~= "dead") then
		Worker.Filter = Result
		return
	end
	for Index, Other in ipairs(Rpc.Workers) do
		if (Other == Worker) then
			table.remove(Rpc.Workers, Index)
			break
		end
	end
end

-- Handles a rednet message on a blockcloud/svc/* protocol.
function Rpc.Handle(Sender, Msg, ProtocolName)
	if (not Protocol.Valid(Msg) or Msg.K ~= "req" or Protocol.Name(Msg.Svc) ~= ProtocolName) then return end
	Rpc.Stats.Requests = Rpc.Stats.Requests + 1
	local Service = Rpc.Services[Msg.Svc]
	local Def = Service and Service[Msg.Op]
	local Client, Keys
	if (Def and Def.Access ~= "public") then
		Client = Clients.Get(Msg.Cl)
		if (not Client or Client.ComputerID ~= Sender) then
			Rpc.Stats.Rejected = Rpc.Stats.Rejected + 1
			Reply(Sender, ProtocolName, Msg, ErrorBody("not_paired"))
			return
		end
		Keys = Auth.Keys(Client.Key)
	elseif (not Allowed(Sender)) then
		Rpc.Stats.Rejected = Rpc.Stats.Rejected + 1
		return
	end

	-- A retry of a request already answered gets the same answer; one still running is ignored.
	local SeenKey = (Msg.Cl or ("#" .. Sender)) .. ":" .. Msg.ID
	local Previous = Seen[SeenKey]
	if (Previous) then
		if (Previous.Response) then rednet.send(Sender, Previous.Response, ProtocolName) end
		return
	end

	local Args, Err = Protocol.Open(Msg, Keys)
	if (Err) then
		Rpc.Stats.Rejected = Rpc.Stats.Rejected + 1
		if (Client) then Log.Warn("auth", "Rejected a request claiming to be " .. Client.Name .. ": " .. Err) end
		Reply(Sender, ProtocolName, Msg, ErrorBody(Err))
		return
	end
	if (Keys and not Protocol.Fresh(Msg)) then
		Rpc.Stats.Rejected = Rpc.Stats.Rejected + 1
		Reply(Sender, ProtocolName, Msg, ErrorBody("replay"), Keys)
		return
	end
	if (not Service) then
		Reply(Sender, ProtocolName, Msg, ErrorBody("unknown_service"), Keys)
		return
	end
	if (not Def) then
		Reply(Sender, ProtocolName, Msg, ErrorBody("unknown_op"), Keys)
		return
	end
	if (Def.Access == "write" and Client.Permission ~= "write") then
		Reply(Sender, ProtocolName, Msg, ErrorBody("denied"), Keys)
		return
	end
	if (#Rpc.Workers >= Rpc.MaxWorkers) then
		Reply(Sender, ProtocolName, Msg, ErrorBody("busy"), Keys)
		return
	end
	if (Client) then Clients.Touch(Client) end

	local Entry = { Time = os.epoch("utc") }
	Seen[SeenKey] = Entry
	local Ctx = { Sender = Sender, Client = Client, Service = Msg.Svc, Op = Msg.Op, ID = Msg.ID }
	local Worker = { Label = Msg.Svc .. "." .. Msg.Op }
	Worker.Co = coroutine.create(function()
		local Ok, Result = pcall(Def.Handler, Ctx, type(Args) == "table" and Args or {})
		local Body
		if (Ok) then
			Body = { Ok = true, R = Result }
		elseif (type(Result) == "table" and Result.BlockCloud) then
			Body = ErrorBody(Result.Code, Result.Message)
		else
			Rpc.Stats.Errors = Rpc.Stats.Errors + 1
			Log.Error(Msg.Svc, Msg.Op .. ": " .. tostring(Result))
			Body = ErrorBody("internal")
		end
		local SendOk, Response = pcall(Reply, Sender, ProtocolName, Msg, Body, Keys)
		if (SendOk) then
			Entry.Response = Response
		else
			Log.Error("rpc", "Could not send a reply: " .. tostring(Response))
			Entry.Response = Reply(Sender, ProtocolName, Msg, ErrorBody("internal"), Keys)
		end
	end)
	table.insert(Rpc.Workers, Worker)
	Resume(Worker)
end

-- Passes an event to the workers waiting for it.
function Rpc.Dispatch(Event)
	if (#Rpc.Workers == 0) then return end
	for _, Worker in ipairs({ table.unpack(Rpc.Workers) }) do
		if (Worker.Filter == nil or Worker.Filter == Event[1]) then
			Resume(Worker, table.unpack(Event, 1, Event.n))
		end
	end
end

-- Forgets answered requests once their timestamps could no longer pass the freshness check.
function Rpc.Cleanup()
	local Cutoff = os.epoch("utc") - Protocol.MaxSkew * 2
	for Key, Entry in pairs(Seen) do
		if (Entry.Time < Cutoff) then Seen[Key] = nil end
	end
	for Sender, Bucket in pairs(Buckets) do
		if (os.epoch("utc") - Bucket.Since > 60000) then Buckets[Sender] = nil end
	end
end

return Rpc
