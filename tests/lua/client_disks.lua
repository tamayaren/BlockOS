-- A server whose storage is pooled over several disks: one on its side and three on a wired
-- modem, with the main storage folder itself on a floppy. Files spread over the disks but
-- clients see one "Shared" share.
local T = dofile("/tests/testlib.lua")

local function Names(Listing)
	local List = {}
	for _, Entry in ipairs(Listing and Listing.Entries or {}) do table.insert(List, Entry.Name) end
	return table.concat(List, ",")
end

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Drive = BlockOS.Require("cloud/drive")
	sleep(3)
	local Node = Client.Discover(2)[1]
	local Session = Client.StartPairing(Node, "Office")
	T.Admin(1, { Op = "approve", Code = Session.Code, Permission = "write" })
	local Server = Client.WaitPairing(Session, nil, 20)
	T.Check("pool: paired", Server ~= nil)

	-- One wired disk shared on its own, and renamed (bcloud lists disks in natural order:
	-- Disk 8, Disk 100, Disk 101, Disk 102).
	local Mode = T.Admin(1, { Op = "bcloud", Args = { "disk", "3", "share" } })
	T.Admin(1, { Op = "bcloud", Args = { "disk", "3", "name", "Solo" } })
	local Info = Drive.Info(Server)
	T.Check("pool: other disks pooled behind one share, one disk on its own", Mode and Mode.Ok and Info
		and table.concat(Info.Shares, ",") == "Shared,Solo" and Info.PooledDisks == 3,
		Info and (table.concat(Info.Shares, ",") .. " " .. tostring(Info.PooledDisks)))
	T.Check("pool: write to the disk share", Drive.WriteText(Server, "Solo/solo.txt", "alone") ~= nil and Drive.ReadText(Server, "Solo/solo.txt") == "alone")
	T.Check("pool: space adds up over the disks", Info and Info.Free > 400000 and Info.Largest < 125000, Info and (Info.Free .. "/" .. Info.Largest))

	local Piece = ("p"):rep(50000)
	local Stored = 0
	for Index = 1, 6 do
		if (Drive.WriteText(Server, "Shared/part" .. Index .. ".bin", Piece .. Index)) then Stored = Stored + 1 end
	end
	T.Check("pool: 300 KB stored on 125 KB floppies", Stored == 6, Stored)
	T.Check("pool: one listing for all disks", Names(Drive.List(Server, "Shared")) == "part1.bin,part2.bin,part3.bin,part4.bin,part5.bin,part6.bin",
		Names(Drive.List(Server, "Shared")))
	local Intact = 0
	for Index = 1, 6 do
		if (Drive.ReadText(Server, "Shared/part" .. Index .. ".bin") == Piece .. Index) then Intact = Intact + 1 end
	end
	T.Check("pool: every file reads back", Intact == 6, Intact)
	local Big, BigErr = Drive.WriteText(Server, "Shared/huge.bin", ("h"):rep(130000))
	T.Check("pool: a file bigger than any one disk is refused clearly", Big == nil and BigErr and BigErr.Code == "no_space"
		and BigErr.Message:find("single disk", 1, true) ~= nil, BigErr and BigErr.Message)

	-- part1 shares a full disk: a bigger version has to move to another disk.
	local Bigger = ("q"):rep(70000)
	T.Check("pool: overwrite that must change disk", Drive.WriteText(Server, "Shared/part1.bin", Bigger) ~= nil)
	T.Check("pool: new version reads back", Drive.ReadText(Server, "Shared/part1.bin") == Bigger)

	T.Check("pool: make a folder", Drive.MakeDir(Server, "Shared/docs") ~= nil)
	T.Check("pool: move files into it from several disks", Drive.Move(Server, "Shared/part2.bin", "Shared/docs/part2.bin") ~= nil
		and Drive.Move(Server, "Shared/part5.bin", "Shared/docs/part5.bin") ~= nil)
	T.Check("pool: rename a folder spread over disks", Drive.Move(Server, "Shared/docs", "Shared/papers") ~= nil
		and Names(Drive.List(Server, "Shared/papers")) == "part2.bin,part5.bin", Names(Drive.List(Server, "Shared/papers")))
	local Old, OldErr = Drive.List(Server, "Shared/docs")
	T.ExpectError("pool: old folder name gone on every disk", "not_found", Old, OldErr)
	T.Check("pool: copy a spread folder", Drive.Copy(Server, "Shared/papers", "Shared/copies") ~= nil
		and Names(Drive.List(Server, "Shared/copies")) == "part2.bin,part5.bin" and Drive.ReadText(Server, "Shared/copies/part5.bin") == Piece .. 5)
	T.Check("pool: delete a spread folder", Drive.Delete(Server, "Shared/copies") == true and Drive.Stat(Server, "Shared/copies") == nil)

	-- Removing a pooled disk hides its files; putting it back restores them.
	local Before = #Drive.List(Server, "Shared").Entries + #Drive.List(Server, "Shared/papers").Entries
	local Counts = T.Admin(1, { Op = "counts" }).Counts
	local Victim
	for _, Side in ipairs({ "right", "drive_0", "drive_2" }) do
		if ((Counts[Side] or 0) > 0) then Victim = Side end
	end
	T.Admin(1, { Op = "eject", Side = Victim })
	sleep(2.5)
	local After = #Drive.List(Server, "Shared").Entries + #Drive.List(Server, "Shared/papers").Entries
	T.Check("pool: ejected disk's files leave the listing (" .. tostring(Victim) .. ")", Victim and After == Before - Counts[Victim], Before .. " -> " .. After)
	local Restored
	local Deadline = os.clock() + 40
	while (os.clock() < Deadline and not Restored) do
		sleep(1)
		local Listing = Drive.List(Server, "Shared")
		Restored = Listing and #Listing.Entries + #Drive.List(Server, "Shared/papers").Entries == Before
	end
	T.Check("pool: reinserted disk's files come back", Restored)
	local All = 0
	for Index = 1, 6 do
		local Remote = (Index == 2 or Index == 5) and ("Shared/papers/part" .. Index .. ".bin") or ("Shared/part" .. Index .. ".bin")
		local Text = Drive.ReadText(Server, Remote)
		if (Text == (Index == 1 and Bigger or Piece .. Index)) then All = All + 1 end
	end
	T.Check("pool: all data intact at the end", All == 6, All)
end)
