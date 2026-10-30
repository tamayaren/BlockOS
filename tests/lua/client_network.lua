-- Unreliable network: 10% of modem messages are dropped, and the harness powers the server
-- off from 40 s to 55 s. Transfers must still complete intact, and calls while the server
-- is off must fail with a clear error in bounded time and recover once it is back.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Drive = BlockOS.Require("cloud/drive")
	sleep(2)
	local Nodes
	for _ = 1, 3 do
		Nodes = Client.Discover(2)
		if (Nodes and #Nodes > 0) then break end
	end
	T.Check("lossy: discovered", Nodes and #Nodes == 1)
	local Session
	for _ = 1, 3 do
		Session = Client.StartPairing(Nodes[1], "Lossy")
		if (Session) then break end
	end
	local Approval
	for _ = 1, 3 do
		Approval = T.Admin(1, { Op = "approve", Code = Session.Code, Permission = "write" }, 4)
		if (Approval) then break end
	end
	local Server, Err = Client.WaitPairing(Session, nil, 60)
	T.Check("lossy: paired despite loss", Server ~= nil, T.Describe(Err))

	local Bytes = {}
	for Index = 1, 30000 do Bytes[Index] = string.char(math.random(0, 255)) end
	local Data = table.concat(Bytes)
	local Good = 0
	for Round = 1, 3 do
		local Entry, UpErr = Drive.WriteText(Server, "Shared/lossy" .. Round .. ".bin", Data)
		local Back, DownErr = Drive.ReadText(Server, "Shared/lossy" .. Round .. ".bin")
		if (Entry and Back == Data) then Good = Good + 1 else print(T.Describe(UpErr or DownErr)) end
	end
	T.Check("lossy: 3 x 30 KB round trips intact", Good == 3, Good .. "/3")

	-- Wait for the power cut, then measure how long a failing call takes.
	while (os.clock() < 42) do sleep(1) end
	local Started = os.clock()
	local Result, OffErr = Drive.List(Server, "Shared")
	local Took = os.clock() - Started
	T.Check("offline: clear error (" .. math.floor(Took * 10) / 10 .. " s)", Result == nil and OffErr and OffErr.Code == "unavailable" and Took < 10, T.Describe(OffErr))
	T.Check("offline: status shows server offline", Client.Online(Server) == false)
	T.Check("offline: readable message", OffErr and OffErr.Message:find("not reachable") ~= nil)

	-- Recover from the boot announcement (or by retrying) once the server is back.
	local Recovered = false
	local Deadline = os.clock() + 60
	while (os.clock() < Deadline and not Recovered) do
		local Sender, Message = rednet.receive("blockcloud/discover", 3)
		if (Sender) then Client.HandleAnnounce(Sender, Message) end
		if (Client.Online(Server) or (not Sender and Drive.List(Server, "Shared"))) then Recovered = true end
	end
	T.Check("recovers after the server returns (at " .. math.floor(os.clock()) .. " s)", Recovered)
	T.Check("data intact after power cut", Drive.ReadText(Server, "Shared/lossy1.bin") == Data)
end)
