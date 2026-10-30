-- Test-only startup for server computers: boots the real Server Edition and, beside it, a
-- helper that plays the administrator (approving pairing with the code a client sends it).

local function Admin()
	while (not (BlockOS and BlockOS.Require and BlockOS.Edition == "server")) do sleep(.1) end
	local Manager = BlockOS.Require("server/service_manager")
	while (not (Manager.Get("core") and Manager.Get("core").State == "running")) do sleep(.1) end
	local Core = Manager.Get("core").Module
	local Clients = BlockOS.Require("server/clients")
	while (true) do
		local Sender, Msg = rednet.receive("blockcloud-test/admin")
		local Reply = {}
		if (type(Msg) ~= "table") then
			Reply.Err = "bad command"
		elseif (Msg.Op == "approve" or Msg.Op == "deny") then
			local Found
			for _, Request in ipairs(Clients.PendingList()) do
				if (Request.ComputerID == Sender) then Found = Request end
			end
			if (not Found) then
				Reply.Err = "no pending request"
			elseif (Msg.Op == "deny") then
				Reply.Ok = Core.Deny(Found.ID)
			else
				local Client, Err = Core.Approve(Found.ID, Msg.Code, Msg.Permission)
				Reply.Ok, Reply.Err = Client ~= nil, Err
			end
		elseif (Msg.Op == "reboot") then
			rednet.send(Sender, { Ok = true }, "blockcloud-test/admin")
			sleep(.5)
			os.reboot()
		elseif (Msg.Op == "set") then
			local Server = BlockOS.Require("server/config")
			Server.Settings()[Msg.Key] = Msg.Value
			Server.Save()
			Reply.Ok = true
		elseif (Msg.Op == "bcloud") then
			Reply.Ok = shell.run("/blockos/server/bin/bcloud.lua", table.unpack(Msg.Args))
		elseif (Msg.Op == "counts") then
			-- Files under blockcloud/Shared on each disk.
			local function Count(Dir)
				if (not fs.isDir(Dir)) then return fs.exists(Dir) and 1 or 0 end
				local Total = 0
				for _, Name in ipairs(fs.list(Dir)) do Total = Total + Count(fs.combine(Dir, Name)) end
				return Total
			end
			Reply.Counts = {}
			for _, Side in ipairs(peripheral.getNames()) do
				local Mount = peripheral.getType(Side) == "drive" and disk.getMountPath(Side)
				if (Mount) then Reply.Counts[Side] = Count(fs.combine(Mount, "blockcloud/Shared")) end
			end
		elseif (Msg.Op == "eject") then
			disk.eject(Msg.Side)
			Reply.Ok = true
		elseif (Msg.Op == "update") then
			os.queueEvent("blockcloud_update", "install")
			Reply.Ok = true
		elseif (Msg.Op == "inspect") then
			local Root = "/blockcloud/storage"
			Reply.Ok = true
			Reply.Temp = fs.exists(Root .. "/.blockcloud/tmp") and #fs.list(Root .. "/.blockcloud/tmp") or -1
			Reply.Exists = Msg.Path and fs.exists(fs.combine(Root, Msg.Path))
			if (Msg.Path and fs.exists(fs.combine(Root, Msg.Path)) and not fs.isDir(fs.combine(Root, Msg.Path))) then
				local Handle = fs.open(fs.combine(Root, Msg.Path), "rb")
				Reply.Data = Handle.readAll()
				Handle.close()
			end
			Reply.Clients = #Clients.List()
			Reply.Version = BlockOS.Require("config").Version()
			Reply.Log = fs.exists("/blockos/data/cloud/logs/server.log") and fs.open("/blockos/data/cloud/logs/server.log", "r").readAll() or ""
			Reply.Escaped = fs.exists("/escape.txt") or fs.exists("/blockcloud/escape.txt")
		end
		rednet.send(Sender, Reply, "blockcloud-test/admin")
	end
end

parallel.waitForAny(function() shell.run("/blockos/server/boot.lua") end, Admin)
