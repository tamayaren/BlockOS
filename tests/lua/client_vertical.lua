-- The milestone's vertical slice on two computers: discover the Data Center, pair, upload a
-- text document, read it, edit and save it, manage files, and check it survives a server restart.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Drive = BlockOS.Require("cloud/drive")
	local Protocol = BlockOS.Require("cloud/protocol")
	local Codec = BlockOS.Require("cloud/codec")
	sleep(2)

	local Nodes = Client.Discover(2)
	T.Check("discovers the server", Nodes and #Nodes == 1 and Nodes[1].Hostname == "datacenter" and Nodes[1].ComputerID == 1, Nodes and #Nodes)
	local Node = Nodes[1]
	local HasDrive = false
	for _, Service in ipairs(Node.Services) do if (Service.Name == "blockdrive") then HasDrive = true end end
	T.Check("server announces BlockDrive", HasDrive)

	-- Unpaired computers cannot use the drive.
	local Result, Err = Client.Request(1, "blockdrive", "list", { Path = "" })
	T.ExpectError("unpaired request refused", "not_paired", Result, Err)

	local Session, PairErr = Client.StartPairing(Node, "Office PC")
	T.Check("pairing request accepted", Session ~= nil, T.Describe(PairErr))
	T.Check("still pending before approval", Client.PollPairing(Session) == "pending")
	local Wrong = T.Admin(1, { Op = "approve", Code = "AAAAAAAA", Permission = "write" })
	T.Check("wrong code is refused by the server", Wrong and Wrong.Ok == false and tostring(Wrong.Err):find("does not match") ~= nil, Wrong and Wrong.Err)
	local Approval = T.Admin(1, { Op = "approve", Code = Session.Code:sub(1, 4):lower() .. "-" .. Session.Code:sub(5), Permission = "write" })
	T.Check("admin approves with the code", Approval and Approval.Ok, Approval and Approval.Err)
	local Server, WaitErr = Client.WaitPairing(Session, nil, 30)
	T.Check("client completes pairing", Server ~= nil and Server.Permission == "write", T.Describe(WaitErr))
	T.Check("pairing persisted", Client.Reload()[Node.NodeID] ~= nil)
	Server = Client.Get(Node.NodeID)
	local Hello = Client.Hello(Server)
	T.Check("hello with signed request", Hello and Hello.Permission == "write")

	local Info = Drive.Info(Server)
	T.Check("drive info lists the Shared share", Info and Info.Shares[1] == "Shared" and Info.Free > 0, Info and textutils.serialise(Info.Shares))

	-- Upload a text document from a local file.
	local Original = "Quarterly report\nRevenue: 64 diamonds\n"
	T.WriteFile("/home/report.txt", Original)
	local Entry, UpErr = Drive.Upload(Server, "/home/report.txt", "Shared/report.txt")
	T.Check("upload text document", Entry and Entry.Size == #Original, T.Describe(UpErr))
	local Again, AgainErr = Drive.Upload(Server, "/home/report.txt", "Shared/report.txt")
	T.ExpectError("upload refuses to overwrite by default", "exists", Again, AgainErr)
	local Listing = Drive.List(Server, "Shared")
	T.Check("listing shows the file and size", Listing and Listing.Entries[1] and Listing.Entries[1].Name == "report.txt" and Listing.Entries[1].Size == #Original)
	local Text = Drive.ReadText(Server, "Shared/report.txt")
	T.Check("read the file remotely", Text == Original, Text)
	local Edited = Original .. "Profit: 12 emeralds\n"
	local Saved, SaveErr = Drive.WriteText(Server, "Shared/report.txt", Edited)
	T.Check("save edited text", Saved and Saved.Size == #Edited, T.Describe(SaveErr))
	T.Check("edited text reads back", Drive.ReadText(Server, "Shared/report.txt") == Edited)
	local OnServer = T.Admin(1, { Op = "inspect", Path = "Shared/report.txt" })
	T.Check("bytes really stored on the server computer", OnServer and OnServer.Data == Edited)

	-- File management.
	T.Check("make folder", Drive.MakeDir(Server, "Shared/docs") ~= nil)
	local _, DirErr = Drive.MakeDir(Server, "Shared/docs")
	T.Check("make existing folder fails", DirErr and DirErr.Code == "exists")
	T.Check("move into folder", Drive.Move(Server, "Shared/report.txt", "Shared/docs/report.txt") ~= nil)
	T.Check("copy file", Drive.Copy(Server, "Shared/docs/report.txt", "Shared/docs/copy.txt") ~= nil)
	T.Check("rename file", Drive.Rename(Server, "Shared/docs/copy.txt", "renamed.txt") ~= nil)
	local Names = {}
	for _, Item in ipairs((Drive.List(Server, "Shared/docs") or { Entries = {} }).Entries) do Names[#Names + 1] = Item.Name end
	T.Check("folder contents after copy and rename", table.concat(Names, ",") == "renamed.txt,report.txt", table.concat(Names, ","))
	T.Check("delete file", Drive.Delete(Server, "Shared/docs/renamed.txt") == true)
	local Gone, GoneErr = Drive.Stat(Server, "Shared/docs/renamed.txt")
	T.ExpectError("deleted file is gone", "not_found", Gone, GoneErr)
	local Moved, MovedErr = Drive.Move(Server, "Shared/docs", "Shared/docs/inside")
	T.ExpectError("cannot move a folder into itself", "invalid", Moved, MovedErr)
	local Share, ShareErr = Drive.Delete(Server, "Shared")
	T.ExpectError("shares cannot be deleted remotely", "denied", Share, ShareErr)
	local Download, DownErr = Drive.Download(Server, "Shared/docs/report.txt", "/home/Downloads/report.txt")
	T.Check("download to a local file", Download == #Edited and T.ReadFile("/home/Downloads/report.txt") == Edited, T.Describe(DownErr))

	-- Escaping the storage root.
	local Escapes = { "..", "../../blockos", "Shared/../../..", "/../rom", "..\\..\\startup.lua", ".blockcloud/tmp", "Shared/.blockcloud" }
	local Blocked = 0
	for _, Remote in ipairs(Escapes) do
		local R, E = Drive.List(Server, Remote)
		if (R == nil and E and E.Code == "invalid_path") then Blocked = Blocked + 1 end
	end
	T.Check("path traversal blocked", Blocked == #Escapes, Blocked .. "/" .. #Escapes)
	local _, EscapeErr = Drive.WriteText(Server, "../../escape.txt", "x")
	T.Check("cannot write outside storage", EscapeErr and EscapeErr.Code == "invalid_path" and not T.Admin(1, { Op = "inspect" }).Escaped)

	-- A multi-chunk binary file survives the round trip byte for byte.
	local Bytes = {}
	for Index = 1, 40000 do Bytes[Index] = string.char((Index * 7 + math.floor(Index / 256)) % 256) end
	local Binary = table.concat(Bytes)
	T.WriteFile("/home/blob.bin", Binary)
	local Started = os.epoch("utc")
	local BinEntry, BinErr = Drive.Upload(Server, "/home/blob.bin", "Shared/blob.bin")
	local UpMs = os.epoch("utc") - Started
	T.Check("upload 40 KB binary (" .. UpMs .. " ms)", BinEntry and BinEntry.Size == #Binary, T.Describe(BinErr))
	Started = os.epoch("utc")
	local Back = Drive.ReadText(Server, "Shared/blob.bin")
	T.Check("download 40 KB binary intact (" .. (os.epoch("utc") - Started) .. " ms)", Back == Binary)

	-- Limits: bigger than the server's disk, and bigger than the admin's per-file limit.
	local Huge, HugeErr = Drive.WriteText(Server, "Shared/huge.bin", ("x"):rep(2500000))
	T.ExpectError("upload larger than the disk refused", "no_space", Huge, HugeErr)
	T.Admin(1, { Op = "set", Key = "MaxFileKB", Value = 10 })
	local Big, BigErr = Drive.WriteText(Server, "Shared/big.txt", ("y"):rep(20000))
	T.ExpectError("upload over the file size limit refused", "too_large", Big, BigErr)
	T.Admin(1, { Op = "set", Key = "MaxFileKB", Value = 0 })

	-- An upload that stops half way leaves the existing file untouched.
	local Begin = Client.Call(Server, "blockdrive", "upload_begin", { Path = "Shared/docs/report.txt", Size = 20000, Sum = 1, Overwrite = true })
	local Chunk = Client.Call(Server, "blockdrive", "upload_chunk", { Transfer = Begin.Transfer, Index = 1, Data = ("z"):rep(8192), Sum = Codec.Adler32(("z"):rep(8192)) })
	T.Check("partial upload started", Begin and Chunk and Chunk.Next == 2)
	T.Check("interrupted upload leaves file intact", Drive.ReadText(Server, "Shared/docs/report.txt") == Edited)
	T.Check("staging file exists during upload", T.Admin(1, { Op = "inspect" }).Temp == 1)
	local BadCommit, BadCommitErr = Client.Call(Server, "blockdrive", "upload_commit", { Transfer = Begin.Transfer })
	T.ExpectError("incomplete upload cannot be committed", "checksum", BadCommit, BadCommitErr)
	T.Check("file still intact after failed commit", Drive.ReadText(Server, "Shared/docs/report.txt") == Edited)

	-- Forged and replayed requests.
	local Forged = { Keys = BlockOS.Require("cloud/auth").Keys(("ab"):rep(32)), ClientID = Server.ClientID, Encrypt = false }
	local FR, FE = Client.Request(1, "blockdrive", "list", { Path = "" }, Forged)
	T.ExpectError("request signed with the wrong key refused", "bad_signature", FR, FE)
	local Unknown = { Keys = Forged.Keys, ClientID = "deadbeef", Encrypt = false }
	local UR, UE = Client.Request(1, "blockdrive", "list", { Path = "" }, Unknown)
	T.ExpectError("unknown client id refused", "not_paired", UR, UE)
	local Auth = BlockOS.Require("cloud/auth")
	local Old = Protocol.Seal({ K = "req", ID = Protocol.NewID(), Svc = "blockdrive", Op = "list", Cl = Server.ClientID, T = os.epoch("utc") - 600000 }, { Path = "" }, Auth.Keys(Server.Key), false)
	rednet.send(1, Old, Protocol.Name("blockdrive"))
	local _, Reply = rednet.receive(Protocol.Name("blockdrive"), 5)
	local Body = Reply and Protocol.Open(Reply, Auth.Keys(Server.Key))
	T.Check("stale request refused as replay", Body and Body.Code == "replay", Body and Body.Code)

	-- Restart the storage computer; the file must still be there and the client must recover.
	T.Admin(1, { Op = "reboot" })
	sleep(1)
	local During, DuringErr = Drive.List(Server, "Shared")
	T.Check("request during restart fails cleanly or succeeds", During ~= nil or (DuringErr and DuringErr.Code == "unavailable"), T.Describe(DuringErr))
	local Announced = false
	local Deadline = os.clock() + 30
	while (os.clock() < Deadline and not Announced) do
		local Sender, Message = rednet.receive(Protocol.Discover, 2)
		if (Sender and Client.HandleAnnounce(Sender, Message)) then Announced = true end
	end
	T.Check("server announces itself after restarting", Announced)
	T.Check("client sees server online again", Client.Online(Server))
	T.Check("edited file persists across restart", Drive.ReadText(Server, "Shared/docs/report.txt") == Edited)
	T.Check("pairing persists across restart", Client.Hello(Server) ~= nil)
	local After = T.Admin(1, { Op = "inspect" })
	T.Check("staging files cleared on boot", After and After.Temp == 0, After and After.Temp)
end)
