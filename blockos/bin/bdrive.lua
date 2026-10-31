-- bdrive: BlockDrive from the terminal. Remote paths may name a server: datacenter:Shared/a.txt
-- (otherwise the only paired server is used).

local Client = BlockOS.Require("cloud/client")
local Drive = BlockOS.Require("cloud/drive")
local Auth = BlockOS.Require("cloud/auth")
local Protocol = BlockOS.Require("cloud/protocol")

local Args = { ... }
local Command = table.remove(Args, 1)

local function Usage()
	print("Usage: bdrive <command>")
	print("  servers               paired servers")
	print("  discover              servers in range")
	print("  pair <hostname>       add a server (public ones at once)")
	print("  pair <hostname> code  pair with a code even if public")
	print("  forget <hostname>     unpair")
	print("  info                  space and access")
	print("  ls [path]             list a folder")
	print("  cat <path>            print a text file")
	print("  get <path> [local]    download")
	print("  put <local> [path]    upload")
	print("  mkdir, rm <path>      make folder, delete")
	print("  mv, cp <from> <to>    move or copy")
end

local function Die(Err)
	printError(Protocol.Describe(Err))
	error("", 0)
end

local function FindServer(Name)
	for _, Server in ipairs(Client.List()) do
		if (Server.Hostname == Name or Server.Name == Name) then return Server end
	end
	return nil
end

-- Splits "host:path" into a server and a remote path.
local function Resolve(Spec)
	Spec = Spec or ""
	local Host, Remote = Spec:match("^([%w%-_]+):(.*)$")
	local Server
	if (Host) then
		Server = FindServer(Host)
		if (not Server) then Die("Not paired with " .. Host) end
	else
		local List = Client.List()
		if (#List == 0) then Die("Not paired with any server. Run: bdrive pair <hostname>") end
		if (#List > 1) then Die("Several servers are paired; write hostname:path") end
		Server, Remote = List[1], Spec
	end
	return Server, Remote
end

local function Bar(Label)
	local _, Y = term.getCursorPos()
	return function(Done, Total)
		term.setCursorPos(1, Y)
		term.clearLine()
		write(Label .. " " .. math.floor(Done / math.max(Total, 1) * 100) .. "%")
	end
end

local function Check(Result, Err)
	if (Result == nil) then Die(Err) end
	return Result
end

local function Run()
	if (Command == "servers") then
		for _, Server in ipairs(Client.List()) do
			local Ok = Client.Hello(Server)
			print(Server.Hostname .. "  " .. Client.Title(Server) .. "  #" .. Server.ComputerID .. "  " .. (Ok and (Server.Permission or "") or "offline"))
		end
	elseif (Command == "discover") then
		local Nodes = Check(Client.Discover(2))
		if (#Nodes == 0) then print("No servers answered.") end
		for _, Node in ipairs(Nodes) do
			print(Node.Hostname .. "  " .. Node.Name .. "  #" .. Node.ComputerID .. (Node.Paired and "  (added)" or (Node.Public and "  (public)" or "")))
		end
	elseif (Command == "pair" and Args[1]) then
		local Target
		for _, Node in ipairs(Check(Client.Discover(2))) do
			if (Node.Hostname == Args[1]) then Target = Node end
		end
		if (not Target) then Die("No server called " .. Args[1] .. " answered.") end
		if (Target.Public and Args[2] ~= "code") then
			local Server = Check(Client.Connect(Target))
			print("Connected to " .. Client.Title(Server) .. " (public, " .. (Server.Permission == "write" and "read/write" or "read only") .. ").")
			return
		end
		local Session = Check(Client.StartPairing(Target))
		print("Ask the administrator of " .. Target.Name .. " to approve this computer with the code:")
		print()
		print("    " .. Auth.FormatCode(Session.Code))
		print()
		print("Waiting (Ctrl+T to cancel)...")
		local Server = Check(Client.WaitPairing(Session))
		print("Paired with " .. Client.Title(Server) .. " (" .. Server.Permission .. ").")
	elseif (Command == "forget" and Args[1]) then
		local Server = FindServer(Args[1])
		if (not Server) then Die("Not paired with " .. Args[1]) end
		Client.Forget(Server.NodeID, true)
		print("Forgot " .. Args[1] .. ".")
	elseif (Command == "info") then
		local Server = Resolve(Args[1])
		local Info = Check(Drive.Info(Server))
		print(Client.Title(Server) .. ": " .. Info.Free .. " bytes free, " .. (Info.Permission == "write" and "read/write" or "read only"))
		print("Shares: " .. table.concat(Info.Shares, ", "))
	elseif (Command == "ls") then
		local Server, Remote = Resolve(Args[1])
		local Listing = Check(Drive.List(Server, Remote))
		for _, Entry in ipairs(Listing.Entries) do
			if (term.isColor()) then term.setTextColor(Entry.Dir and colors.lightBlue or colors.white) end
			print(Entry.Dir and (Entry.Name .. "/") or (Entry.Name .. "  " .. Entry.Size))
		end
		term.setTextColor(colors.white)
	elseif (Command == "cat" and Args[1]) then
		local Server, Remote = Resolve(Args[1])
		print(Check(Drive.ReadText(Server, Remote)))
	elseif (Command == "get" and Args[1]) then
		local Server, Remote = Resolve(Args[1])
		local Target = shell.resolve(Args[2] or Remote:match("[^/]*$"))
		local Size = Check(Drive.Download(Server, Remote, Target, { OnProgress = Bar("Downloading") }))
		print()
		print("Saved " .. Size .. " bytes to /" .. Target)
	elseif (Command == "put" and Args[1]) then
		local Source = shell.resolve(Args[1])
		local Server, Remote = Resolve(Args[2] or fs.getName(Source))
		if (Remote == "" or Remote:sub(-1) == "/") then Remote = Remote .. fs.getName(Source) end
		local Entry = Check(Drive.Upload(Server, Source, Remote, { Overwrite = true, OnProgress = Bar("Uploading") }))
		print()
		print("Uploaded " .. Entry.Size .. " bytes to " .. Remote)
	elseif (Command == "mkdir" and Args[1]) then
		local Server, Remote = Resolve(Args[1])
		Check(Drive.MakeDir(Server, Remote))
	elseif (Command == "rm" and Args[1]) then
		local Server, Remote = Resolve(Args[1])
		Check(Drive.Delete(Server, Remote))
	elseif ((Command == "mv" or Command == "cp") and Args[1] and Args[2]) then
		local Server, From = Resolve(Args[1])
		local _, To = Resolve(Args[2])
		Check((Command == "mv" and Drive.Move or Drive.Copy)(Server, From, To))
	else
		Usage()
	end
end

local Ok, Err = pcall(Run)
if (not Ok and Err ~= "") then printError(Err) end
