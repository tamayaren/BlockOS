-- Paired client computers and pending pairing requests.
-- Paired clients persist in /blockos/data/cloud/clients.dat; pending requests live in memory
-- and expire, so a restart simply asks the client to pair again.

local Config = BlockOS.Require("config")
local Auth = BlockOS.Require("cloud/auth")
local Log = BlockOS.Require("server/log")

local Clients = {}

Clients.Path = "/blockos/data/cloud/clients.dat"
Clients.PendingLimit = 16
Clients.PendingLifetime = 10 * 60 * 1000

local Data = nil
local Dirty = false
local LastSave = 0
Clients.Pending = {}

local function Load()
	if (not Data) then
		local Saved = Config.Read(Clients.Path)
		Data = type(Saved) == "table" and Saved or {}
	end
	return Data
end

function Clients.Save()
	Config.Write(Clients.Path, Load())
	Dirty = false
	LastSave = os.epoch("utc")
	os.queueEvent("blockcloud_clients")
end

-- Writes LastSeen updates at most once a minute to spare the disk.
function Clients.Flush(Force)
	if (Dirty and (Force or os.epoch("utc") - LastSave > 60000)) then
		Clients.Save()
	end
end

function Clients.Get(ClientID)
	if (type(ClientID) ~= "string") then return nil end
	return Load()[ClientID]
end

function Clients.List()
	local List = {}
	for _, Client in pairs(Load()) do
		table.insert(List, Client)
	end
	table.sort(List, function(A, B) return (A.Name or ""):lower() < (B.Name or ""):lower() end)
	return List
end

function Clients.Touch(Client)
	Client.LastSeen = os.epoch("utc")
	Dirty = true
end

function Clients.SetPermission(ClientID, Permission)
	local Client = Clients.Get(ClientID)
	if (not Client or (Permission ~= "read" and Permission ~= "write")) then return false end
	Client.Permission = Permission
	Clients.Save()
	Log.Info("auth", "Permission for " .. Client.Name .. " set to " .. Permission)
	return true
end

function Clients.Rename(ClientID, Name)
	local Client = Clients.Get(ClientID)
	if (not Client) then return false end
	Client.Name = tostring(Name):sub(1, 32)
	Clients.Save()
	return true
end

function Clients.Revoke(ClientID)
	local Client = Clients.Get(ClientID)
	if (not Client) then return false end
	Load()[ClientID] = nil
	Clients.Save()
	Log.Info("auth", "Removed client " .. Client.Name .. " (computer #" .. Client.ComputerID .. ")")
	return true
end

--
-- Pairing
--

function Clients.Expire()
	local Now = os.epoch("utc")
	for ID, Request in pairs(Clients.Pending) do
		if (Now - Request.Created > Clients.PendingLifetime) then
			Clients.Pending[ID] = nil
		end
	end
end

-- Records a request from a client. One request per computer; a new one replaces the old.
function Clients.Request(ComputerID, Name, ClientNonce, Check)
	Clients.Expire()
	local Count = 0
	for ID, Request in pairs(Clients.Pending) do
		if (Request.ComputerID == ComputerID) then
			Clients.Pending[ID] = nil
		elseif (Request.Status == "pending") then
			Count = Count + 1
		end
	end
	if (Count >= Clients.PendingLimit) then return nil, "busy" end
	local Request = {
		ID = Auth.RandomHex(8),
		ComputerID = ComputerID,
		Name = tostring(Name or ("Computer #" .. ComputerID)):sub(1, 32),
		ClientNonce = ClientNonce,
		ServerNonce = Auth.RandomHex(16),
		Check = Check,
		Created = os.epoch("utc"),
		Status = "pending"
	}
	Clients.Pending[Request.ID] = Request
	Log.Info("auth", "Pairing request from " .. Request.Name .. " (computer #" .. ComputerID .. ")")
	os.queueEvent("blockcloud_clients")
	return Request
end

function Clients.PendingList()
	Clients.Expire()
	local List = {}
	for _, Request in pairs(Clients.Pending) do
		if (Request.Status == "pending") then table.insert(List, Request) end
	end
	table.sort(List, function(A, B) return A.Created < B.Created end)
	return List
end

-- Approves a request with the code shown on the client. Returns the new client or nil, reason.
function Clients.Approve(RequestID, CodeText, Permission, Name)
	local Request = Clients.Pending[RequestID]
	if (not Request or Request.Status ~= "pending") then return nil, "That request is no longer waiting." end
	local Code = Auth.CleanCode(CodeText)
	if (Auth.CodeCheck(Code, Request.ClientNonce) ~= Request.Check) then
		Log.Warn("auth", "Wrong pairing code entered for " .. Request.Name)
		return nil, "That code does not match the one shown on the client."
	end
	Permission = (Permission == "read") and "read" or "write"
	local Key = Auth.DeriveKey(Code, Request.ID, Request.ClientNonce, Request.ServerNonce)
	local Client = {
		ID = Auth.RandomHex(12),
		ComputerID = Request.ComputerID,
		Name = tostring(Name or Request.Name):sub(1, 32),
		Key = BlockOS.Require("cloud/codec").ToHex(Key),
		Permission = Permission,
		PairedAt = os.epoch("utc"),
		LastSeen = os.epoch("utc")
	}
	Load()[Client.ID] = Client
	Clients.Save()
	Request.Status = "approved"
	Request.ClientID = Client.ID
	Request.Proof = Auth.ApprovalProof(Key, Request.ID, Client.ID, Permission)
	Request.Permission = Permission
	Log.Info("auth", "Paired " .. Client.Name .. " (computer #" .. Client.ComputerID .. ", " .. Permission .. ")")
	return Client
end

function Clients.Deny(RequestID)
	local Request = Clients.Pending[RequestID]
	if (not Request) then return false end
	Request.Status = "denied"
	Log.Info("auth", "Declined pairing request from " .. Request.Name)
	os.queueEvent("blockcloud_clients")
	return true
end

return Clients
