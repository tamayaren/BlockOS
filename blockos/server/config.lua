-- Server Edition configuration, stored in /blockos/data/cloud/server.dat next to the
-- other BlockOS settings so updates never touch it.

local Config = BlockOS.Require("config")
local Auth = BlockOS.Require("cloud/auth")

local Server = {}

Server.DataDir = "/blockos/data/cloud"
Server.Channel = "https://raw.githubusercontent.com/tamayaren/BlockOS/server/"
Server.Manifest = "server-manifest.cfg"

Config.Defaults["cloud/server"] = {
	Configured = false,
	Hostname = "datacenter",
	DisplayName = "Data Center",
	StorageRoot = "/blockcloud/storage",
	DefaultShare = "Shared",
	-- Disk drives (direct or over wired modems): ShareDisks turns them all off, DiskMode is how
	-- new disks are used (pool, share or off), Disks holds per-disk { Name, Mode } by disk ID.
	ShareDisks = true,
	DiskMode = "pool",
	Disks = {},
	-- Public servers let any computer in range use BlockDrive without pairing, with Visitors
	-- ("read" or "write") access. Paired computers keep their own permission either way.
	Public = true,
	Visitors = "write",
	PairingOpen = true,
	Encrypt = true,
	QuotaMB = 0,
	MaxFileKB = 0,
	LockMinutes = 10,
	AutoUpdate = true,
	AutoInstall = true,
	AutoRestart = true,
	UpdateHours = 6,
	UpdateURL = Server.Channel,
	Services = { blockdrive = true },
	LogLevel = "info"
}

local Migrated = false

-- Servers set up before public access existed and that already have paired computers stay
-- private: updating must never open someone's storage to everyone.
local function Migrate()
	Migrated = true
	local Saved = Config.Read(fs.combine(Config.DataDir, "cloud/server.dat"))
	if (type(Saved) ~= "table" or Saved.Public ~= nil) then return end
	local Paired = Config.Read(fs.combine(Server.DataDir, "clients.dat"))
	if (type(Paired) == "table" and next(Paired) ~= nil) then
		local Settings = Config.Load("cloud/server")
		Settings.Public = false
		Config.Save("cloud/server")
	end
end

function Server.Settings()
	if (not Migrated) then Migrate() end
	local Settings = Config.Load("cloud/server")
	if (type(Settings.NodeID) ~= "string") then
		Settings.NodeID = Auth.RandomHex(8)
		Config.Save("cloud/server")
	end
	return Settings
end

function Server.Save()
	Config.Save("cloud/server")
	os.queueEvent("blockcloud_config")
end

function Server.Version()
	return Config.Version()
end

-- Hostnames are announced on the network; keep them short and simple.
function Server.ValidHostname(Name)
	return type(Name) == "string" and #Name >= 1 and #Name <= 24 and Name:match("^[%w%-_]+$") ~= nil
end

function Server.HasPassword()
	return type(Server.Settings().AdminHash) == "string"
end

function Server.SetPassword(Password)
	local Settings = Server.Settings()
	if (not Password or Password == "") then
		Settings.AdminSalt = nil
		Settings.AdminHash = nil
	else
		Settings.AdminSalt = Auth.RandomHex(8)
		Settings.AdminHash = Auth.HashPassword(Password, Settings.AdminSalt)
	end
	Server.Save()
end

function Server.CheckPassword(Password)
	local Settings = Server.Settings()
	if (not Settings.AdminHash) then return true end
	return Auth.HashPassword(Password or "", Settings.AdminSalt or "") == Settings.AdminHash
end

-- Points the shared updater at the Server Edition channel and manifest, never the desktop one.
function Server.ConfigureUpdater()
	local Updater = BlockOS.Require("updater")
	Updater.Profile = {
		Edition = "server",
		Manifest = Server.Manifest,
		Url = function() return Server.Settings().UpdateURL or Server.Channel end
	}
	return Updater
end

return Server
