-- BlockCloud Core: discovery, health checks and pairing. Always running.

local Protocol = BlockOS.Require("cloud/protocol")
local Clients = BlockOS.Require("server/clients")
local Server = BlockOS.Require("server/config")

local Core = {
	Name = "core",
	Title = "BlockCloud Core",
	Description = "Discovery, pairing and authentication.",
	Version = "1.0",
	System = true
}

local Manager

-- What this computer tells clients about itself.
function Core.Node()
	local Settings = Server.Settings()
	return {
		NodeID = Settings.NodeID,
		Hostname = Settings.Hostname,
		Name = Settings.DisplayName,
		Version = Server.Version(),
		Edition = "server",
		Encrypt = Settings.Encrypt ~= false,
		Pairing = Settings.PairingOpen ~= false,
		Services = Manager and Manager.Announced() or {}
	}
end

local function Announce(Target)
	local Message = { BC = Protocol.Version, K = "announce", Node = Core.Node() }
	if (Target) then
		rednet.send(Target, Message, Protocol.Discover)
	else
		rednet.broadcast(Message, Protocol.Discover)
	end
end

Core.Announce = Announce

local function ValidNonce(Value)
	return type(Value) == "string" and #Value >= 16 and #Value <= 64 and Value:match("^%x+$") ~= nil
end

function Core.Init(Ctx)
	Manager = Ctx.Manager
	Ctx.Rpc.Register("core", {
		ping = { Access = "public", Handler = function()
			return { Node = Core.Node(), Time = os.epoch("utc") }
		end },

		pair_request = { Access = "public", Handler = function(Req, Args)
			if (Server.Settings().PairingOpen == false) then Ctx.Rpc.Fail("pairing_closed") end
			if (not ValidNonce(Args.Nonce) or type(Args.Check) ~= "string" or #Args.Check ~= 64) then
				Ctx.Rpc.Fail("invalid")
			end
			local Request, Err = Clients.Request(Req.Sender, Args.Name, Args.Nonce, Args.Check)
			if (not Request) then Ctx.Rpc.Fail(Err) end
			return { RequestID = Request.ID, ServerNonce = Request.ServerNonce, Status = "pending", Node = Core.Node() }
		end },

		-- Only the computer that asked can see the outcome of its request.
		pair_status = { Access = "public", Handler = function(Req, Args)
			Clients.Expire()
			local Request = Clients.Pending[Args.RequestID]
			if (not Request or Request.ComputerID ~= Req.Sender) then Ctx.Rpc.Fail("pairing_expired") end
			if (Request.Status == "denied") then
				Clients.Pending[Request.ID] = nil
				Ctx.Rpc.Fail("pairing_denied")
			elseif (Request.Status == "approved") then
				return { Status = "approved", ClientID = Request.ClientID, Permission = Request.Permission, Proof = Request.Proof, Node = Core.Node() }
			end
			return { Status = "pending" }
		end },

		-- Paired clients call this to confirm their key still works and learn their permission.
		hello = { Access = "read", Handler = function(Req)
			for ID, Request in pairs(Clients.Pending) do
				if (Request.ClientID == Req.Client.ID) then Clients.Pending[ID] = nil end
			end
			return { Permission = Req.Client.Permission, Name = Req.Client.Name, Node = Core.Node() }
		end },

		unpair = { Access = "read", Handler = function(Req)
			Clients.Revoke(Req.Client.ID)
			return true
		end }
	})
end

-- Approval from the console or bcloud: also nudges the waiting client so it need not poll.
function Core.Approve(RequestID, Code, Permission, Name)
	local Client, Err = Clients.Approve(RequestID, Code, Permission, Name)
	if (Client) then
		pcall(rednet.send, Client.ComputerID, { BC = Protocol.Version, K = "push", Op = "pair_status", ID = RequestID }, Protocol.Name("core"))
	end
	return Client, Err
end

function Core.Deny(RequestID)
	local Request = Clients.Pending[RequestID]
	local Ok = Clients.Deny(RequestID)
	if (Ok and Request) then
		pcall(rednet.send, Request.ComputerID, { BC = Protocol.Version, K = "push", Op = "pair_status", ID = RequestID }, Protocol.Name("core"))
	end
	return Ok
end

function Core.Run(Ctx)
	local Settings = Server.Settings()
	if (Protocol.OpenModems() > 0) then
		pcall(rednet.host, Protocol.Discover, Settings.Hostname)
		-- One announcement at boot lets clients that were waiting reconnect straight away.
		Announce()
		Ctx.Log.Info("core", "Announced " .. Settings.Hostname .. " on the network")
	else
		Ctx.Log.Warn("core", "No modem attached. Attach a wireless, ender or wired modem.")
	end
	local Housekeeping = os.startTimer(30)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "rednet_message" and C == Protocol.Discover) then
			if (type(B) == "table" and B.BC == Protocol.Version and B.K == "discover") then
				Announce(A)
			end
		elseif (Event == "timer" and A == Housekeeping) then
			Ctx.Rpc.Cleanup()
			Clients.Expire()
			Clients.Flush()
			Housekeeping = os.startTimer(30)
		elseif (Event == "peripheral") then
			if (Protocol.OpenModems() > 0) then
				pcall(rednet.host, Protocol.Discover, Server.Settings().Hostname)
				Announce()
			end
			os.queueEvent("blockcloud_status")
		elseif (Event == "peripheral_detach") then
			os.queueEvent("blockcloud_status")
		elseif (Event == "blockcloud_config") then
			-- The hostname may have changed.
			if (Protocol.OpenModems() > 0) then
				pcall(rednet.unhost, Protocol.Discover)
				pcall(rednet.host, Protocol.Discover, Server.Settings().Hostname)
			end
		end
	end
end

function Core.Health()
	local Modems = Protocol.Modems()
	if (#Modems == 0) then return "error", "No modem attached" end
	local Pending = #Clients.PendingList()
	if (Pending > 0) then return "warn", Pending .. " pairing request" .. (Pending == 1 and "" or "s") end
	return "ok", #Modems .. " modem" .. (#Modems == 1 and "" or "s")
end

function Core.Stop()
	Clients.Flush(true)
end

return Core
