-- 100 disk drives on a wired modem, pooled: the scale of a real Data Center rack.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Drive = BlockOS.Require("cloud/drive")
	sleep(4)
	local Node = Client.Discover(2)[1]
	T.Check("rack: server boots with 100 drives", Node ~= nil)
	local Session = Client.StartPairing(Node, "Office")
	T.Admin(1, { Op = "approve", Code = Session.Code, Permission = "write" })
	local Server = Client.WaitPairing(Session, nil, 20)
	local Started = os.epoch("utc")
	local Info = Drive.Info(Server)
	T.Check("rack: info over 100 disks (" .. (os.epoch("utc") - Started) .. " ms)", Info and Info.PooledDisks == 99 and Info.Free > 11000000,
		Info and (Info.PooledDisks .. " disks, " .. Info.Free .. " free"))
	local Piece = ("r"):rep(100000)
	local Stored = 0
	Started = os.epoch("utc")
	for Index = 1, 40 do
		if (Drive.WriteText(Server, "Shared/block" .. Index .. ".bin", Piece .. Index)) then Stored = Stored + 1 end
	end
	local Each = math.floor((os.epoch("utc") - Started) / 40)
	T.Check("rack: 4 MB spread over the rack (" .. Each .. " ms per 100 KB upload)", Stored == 40, Stored)
	Started = os.epoch("utc")
	local Listing = Drive.List(Server, "Shared")
	T.Check("rack: one listing over 100 disks (" .. (os.epoch("utc") - Started) .. " ms)", Listing and #Listing.Entries == 40)
	T.Check("rack: reads back from a far disk", Drive.ReadText(Server, "Shared/block37.bin") == Piece .. 37)
end)
