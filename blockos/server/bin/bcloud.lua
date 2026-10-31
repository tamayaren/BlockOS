-- bcloud: BlockOS Server administration from the shell (setup, recovery, scripting).
-- Talks to the running services directly, so it works in the console's Shell and in the
-- recovery shell alike.

local Server = BlockOS.Require("server/config")
local Manager = BlockOS.Require("server/service_manager")
local Clients = BlockOS.Require("server/clients")
local Log = BlockOS.Require("server/log")
local Rpc = BlockOS.Require("server/rpc")
local Path = BlockOS.Require("cloud/path")
local Volumes = BlockOS.Require("server/volumes")

local Args = { ... }
local Command = Args[1]

local function Usage()
	print("Usage: bcloud <command>")
	print("  status                    services, storage, clients")
	print("  pending                   computers waiting to pair")
	print("  approve <n> <code> [read] approve request n")
	print("  deny <n>                  decline request n")
	print("  clients                   paired computers")
	print("  perm <n> read|write       change a client's access")
	print("  remove <n>                unpair client n")
	print("  restart <service>         restart a service")
	print("  disks                     disk drives and how they are used")
	print("  disk <n> pool|share|off   pool disk n, give it its own")
	print("                            share, or leave it unused")
	print("  disk <n> name <name>      rename disk n")
	print("  logs [lines]              recent log lines")
	print("  update [install]          check for (and install) updates")
	print("  set <key> <value>         hostname, name, storage,")
	print("                            quota, public on|off,")
	print("                            visitors read|write, pairing, encrypt,")
	print("                            disks on|off, diskmode pool|share|off")
	print("  password                  set the admin password")
end

local function Core()
	local Service = Manager.Get("core")
	return Service and Service.Module
end

local function Pick(List, Text)
	local Index = tonumber(Text)
	local Item = Index and List[Index]
	if (not Item) then printError("No entry " .. tostring(Text) .. ". Run the list command first.") end
	return Item
end

if (not Manager.Get("core")) then
	printError("BlockCloud is not running on this computer.")
	return
end

if (Command == "status") then
	local Settings = Server.Settings()
	print(Settings.Hostname .. " (" .. Settings.DisplayName .. "), computer #" .. os.getComputerID() .. ", BlockOS Server " .. Server.Version())
	for _, Status in ipairs(Manager.Status()) do
		print(string.format("  %-16s %-10s %s", Status.Title, Status.State, Status.Detail or ""))
	end
	local Drive = Manager.Get("blockdrive")
	if (Drive and Drive.Module.Root) then
		local Usage = Drive.Module.Usage()
		print("Storage " .. Drive.Module.Root() .. ": " .. Usage.Files .. " files, " .. Usage.Bytes .. " bytes, " .. fs.getFreeSpace(Drive.Module.Root()) .. " bytes free")
	end
	local Visitors = 0
	for _ in pairs(Rpc.Visitors) do Visitors = Visitors + 1 end
	local Settings = Server.Settings()
	print((Settings.Public ~= false and ("Public: visitors may " .. (Settings.Visitors == "read" and "read" or "read and write")) or "Private: pairing required")
		.. "; " .. #Clients.List() .. " paired, " .. Visitors .. " visitors, " .. #Clients.PendingList() .. " pending, " .. Rpc.Stats.Requests .. " requests")
elseif (Command == "pending") then
	local List = Clients.PendingList()
	if (#List == 0) then print("No pairing requests.") end
	for Index, Request in ipairs(List) do
		print(Index .. ". " .. Request.Name .. " (computer #" .. Request.ComputerID .. ")")
	end
elseif (Command == "approve" and Args[2] and Args[3]) then
	local Request = Pick(Clients.PendingList(), Args[2])
	if (not Request) then return end
	local Client, Err = Core().Approve(Request.ID, Args[3], Args[4] == "read" and "read" or "write")
	if (Client) then print("Paired " .. Client.Name .. " (" .. Client.Permission .. ").") else printError(Err) end
elseif (Command == "deny" and Args[2]) then
	local Request = Pick(Clients.PendingList(), Args[2])
	if (Request) then
		Core().Deny(Request.ID)
		print("Declined.")
	end
elseif (Command == "clients") then
	local List = Clients.List()
	if (#List == 0) then print("No paired computers.") end
	for Index, Client in ipairs(List) do
		print(Index .. ". " .. Client.Name .. " (computer #" .. Client.ComputerID .. ", " .. Client.Permission .. ")")
	end
elseif (Command == "perm" and Args[2] and (Args[3] == "read" or Args[3] == "write")) then
	local Client = Pick(Clients.List(), Args[2])
	if (Client) then
		Clients.SetPermission(Client.ID, Args[3])
		print(Client.Name .. " is now " .. Args[3] .. ".")
	end
elseif (Command == "remove" and Args[2]) then
	local Client = Pick(Clients.List(), Args[2])
	if (Client) then
		Clients.Revoke(Client.ID)
		print("Unpaired " .. Client.Name .. ".")
	end
elseif (Command == "restart" and Args[2]) then
	if (not Manager.Get(Args[2])) then
		printError("No service " .. Args[2])
		return
	end
	Manager.Restart(Args[2])
	print("Restarted " .. Args[2] .. ".")
elseif (Command == "disks") then
	Volumes.Refresh()
	local List = Volumes.List()
	local Drive = Manager.Get("blockdrive")
	if (Drive and Drive.Module.PoolSpace) then
		local Free, Capacity, Pooled = Drive.Module.PoolSpace()
		print("Pool: " .. Volumes.Primary() .. " + " .. Pooled .. " disks, " .. Free .. " of " .. tostring(Capacity) .. " bytes free")
	end
	if (#List == 0) then print("No disk drives with a disk.") end
	for Index, Volume in ipairs(List) do
		local Free = Volume.Mode ~= "off" and fs.exists(Volume.Root) and fs.getFreeSpace(Volume.Root) or nil
		print(Index .. ". " .. Volume.Name .. "  " .. Volume.Mode .. "  " .. Volume.Side .. " " .. Volume.Mount .. (Free and ("  " .. Free .. " free") or ""))
	end
	if (Server.Settings().ShareDisks == false) then print("Disks are not used: bcloud set disks on") end
elseif (Command == "disk" and Args[2] and Args[3]) then
	Volumes.Refresh()
	local Volume = Pick(Volumes.List(), Args[2])
	if (not Volume) then return end
	if (Args[3] == "name" and Args[4]) then
		local Name = table.concat(Args, " ", 4)
		local Ok, Err = Volumes.Rename(Volume.Key, Name)
		if (Ok) then print("Disk " .. Volume.Name .. " is now called " .. Name .. ".") else printError(Err) end
	elseif (Volumes.Modes[Args[3]]) then
		local Warning = Volumes.ModeWarning(Volume, Args[3])
		if (Warning) then print(Warning) end
		Volumes.SetMode(Volume.Key, Args[3])
		print("Disk " .. Volume.Name .. ": " .. ({ pool = "pooled", share = "shared on its own", off = "not used" })[Args[3]] .. ".")
	else
		Usage()
	end
elseif (Command == "logs") then
	local Count = tonumber(Args[2]) or 15
	for Index = math.max(1, #Log.Lines - Count + 1), #Log.Lines do
		local Entry = Log.Lines[Index]
		print(Entry.Time:sub(12) .. " " .. Entry.Level .. " " .. Entry.Source .. ": " .. Entry.Text)
	end
elseif (Command == "update") then
	local Updates = Manager.Get("updater").Module
	print("Checking " .. Server.Settings().UpdateURL)
	Updates.Check(Args[2] == "install")
	print(Updates.Message)
elseif (Command == "set" and Args[2] and Args[3]) then
	local Settings = Server.Settings()
	local Value = table.concat(Args, " ", 3)
	local Key = Args[2]
	if (Key == "hostname") then
		if (not Server.ValidHostname(Value)) then return printError("Use 1-24 letters, digits, - or _.") end
		Settings.Hostname = Value
		os.setComputerLabel(Value)
	elseif (Key == "name") then
		Settings.DisplayName = Value:sub(1, 32)
	elseif (Key == "storage") then
		local Ok, Err = Path.ValidRoot(Value)
		if (not Ok) then return printError(Err) end
		Settings.StorageRoot = "/" .. fs.combine(Value, "")
	elseif (Key == "quota") then
		Settings.QuotaMB = tonumber(Value) or 0
	elseif (Key == "public") then
		Settings.Public = Value == "on" or Value == "true" or Value == "yes"
	elseif (Key == "visitors") then
		if (Value ~= "read" and Value ~= "write") then return printError("Use read or write.") end
		Settings.Visitors = Value
	elseif (Key == "diskmode") then
		if (not Volumes.Modes[Value]) then return printError("Use pool, share or off.") end
		Settings.DiskMode = Value
	elseif (Key == "pairing" or Key == "encrypt" or Key == "disks") then
		Settings[({ pairing = "PairingOpen", encrypt = "Encrypt", disks = "ShareDisks" })[Key]] = Value == "on" or Value == "true" or Value == "yes"
	else
		return printError("Unknown setting " .. Key)
	end
	Server.Save()
	if (Key == "storage") then Manager.Restart("blockdrive") end
	if (Key == "disks") then Volumes.Refresh() os.queueEvent("blockcloud_storage") end
	if (Key == "hostname" or Key == "encrypt" or Key == "public" or Key == "visitors") then Core().Announce() end
	print("Saved.")
elseif (Command == "password") then
	write("New admin password (empty for none): ")
	local First = read("*")
	if (First ~= "") then
		write("Again: ")
		if (read("*") ~= First) then return printError("The passwords did not match.") end
	end
	Server.SetPassword(First)
	print(First == "" and "Password removed." or "Password set.")
else
	Usage()
end
