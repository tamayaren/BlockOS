-- BlockDrive: network file storage. Every remote path is resolved inside the storage volumes
-- (see server/volumes): the main storage folder pooled with the server's disk drives, plus
-- disks shared on their own. Uploads are staged in a hidden folder on the disk that will hold
-- the file and swapped in only once complete and verified, so an interrupted transfer never
-- damages an existing file.

local Path = BlockOS.Require("cloud/path")
local Codec = BlockOS.Require("cloud/codec")
local Auth = BlockOS.Require("cloud/auth")
local Server = BlockOS.Require("server/config")
local Volumes = BlockOS.Require("server/volumes")

local Drive = {
	Name = "blockdrive",
	Title = "BlockDrive",
	Description = "Network file storage.",
	Version = "1.1"
}

Drive.ChunkSize = 8192
Drive.TransferIdle = 90 * 1000
Drive.MaxTransfers = 16
Drive.MaxPerClient = 4
-- Space left free on the computer's own disk so the server can still write logs and settings.
Drive.Reserve = 16 * 1024

local Transfers = {}
local Usage = { Bytes = 0, Files = 0, Folders = 0, Scanned = false, Dirty = true }
local Rpc, Log

local function Fail(Code, Detail)
	Rpc.Fail(Code, Detail)
end

-- The main storage folder; disks are listed by Drive.Volumes().
function Drive.Root()
	return Volumes.Primary()
end

function Drive.Volumes()
	return Volumes.List()
end

local function Target(Remote)
	local Result, Err = Volumes.Target(Remote)
	if (not Result) then Fail(Err) end
	return Result
end

local function Modified(Local)
	local Ok, Attributes = pcall(fs.attributes, Local)
	return Ok and Attributes and Attributes.modified or 0
end

local function Entry(Local, Name)
	local Dir = fs.isDir(Local)
	return { Name = Name, Dir = Dir, Size = Dir and 0 or fs.getSize(Local), Modified = Modified(Local) }
end

-- Usable free bytes on one root.
local function FreeSpace(Root)
	Root = Root or Drive.Root()
	if (not fs.exists(Root)) then return 0 end
	local Free = tonumber(fs.getFreeSpace(Root)) or 0
	local OwnDisk = not fs.getDrive or fs.getDrive(Root) == "hdd"
	return math.max(0, Free - (OwnDisk and Drive.Reserve or 0))
end

local function QuotaLeft()
	local Quota = (tonumber(Server.Settings().QuotaMB) or 0) * 1024 * 1024
	if (Quota <= 0) then return math.huge end
	return math.max(0, Quota - Usage.Bytes)
end

-- Bytes clients may still add to a space (its roots together), limited by the quota.
local function Available(Roots)
	local Total = 0
	for _, Root in ipairs(Roots) do Total = Total + FreeSpace(Root) end
	return math.min(Total, QuotaLeft())
end

-- The largest single file a space can take: files are never split across disks.
local function Largest(Roots)
	local Best = 0
	for _, Root in ipairs(Roots) do Best = math.max(Best, FreeSpace(Root)) end
	return math.min(Best, QuotaLeft())
end

local function Capacity(Roots)
	if (not fs.getCapacity) then return nil end
	local Total = 0
	for _, Root in ipairs(Roots) do
		if (fs.exists(Root)) then Total = Total + (tonumber(fs.getCapacity(Root)) or 0) end
	end
	return Total
end

local function MaxFile()
	local Limit = (tonumber(Server.Settings().MaxFileKB) or 0) * 1024
	return Limit > 0 and Limit or nil
end

-- Walks every volume to total its size, yielding now and then on large trees.
local function Scan()
	local Bytes, Files, Folders, Steps = 0, 0, 0, 0
	local function Walk(Dir)
		for _, Name in ipairs(fs.list(Dir)) do
			if (Name ~= Path.Reserved) then
				local Child = fs.combine(Dir, Name)
				if (fs.isDir(Child)) then
					Folders = Folders + 1
					Walk(Child)
				else
					Files = Files + 1
					Bytes = Bytes + fs.getSize(Child)
				end
				Steps = Steps + 1
				if (Steps % 200 == 0) then sleep(0) end
			end
		end
	end
	for _, Root in ipairs(Volumes.Roots()) do
		if (fs.isDir(Root)) then pcall(Walk, Root) end
	end
	Usage.Bytes, Usage.Files, Usage.Folders = Bytes, Files, Folders
	Usage.Scanned = true
	Usage.Dirty = false
end

function Drive.Usage()
	return Usage
end

local function Changed()
	Usage.Dirty = true
	os.queueEvent("blockcloud_storage")
end

local function ParentOf(T)
	return { Normal = Path.Parent(T.Normal), Rel = Path.Parent(T.Rel), Roots = T.Roots, Space = T.Space, Volume = T.Volume }
end

local function RequireParent(T)
	if (not Volumes.IsDir(ParentOf(T))) then
		local Parent = Path.Parent(T.Normal)
		Fail("not_found", "The folder " .. (Parent == "" and "/" or Parent) .. " does not exist.")
	end
end

-- Top-level folders are the shares clients see first; they can only be changed on the server.
local function RequireNotShare(T)
	if (T.Normal == "" or not T.Normal:find("/")) then
		Fail("denied", "Shares can only be created, renamed or removed on the server.")
	end
end

local function Transfer(Ctx, ID, Kind)
	local Item = Transfers[ID]
	if (not Item or Item.Kind ~= Kind or Item.Client ~= Ctx.Client.ID) then Fail("transfer_lost") end
	Item.Touched = os.epoch("utc")
	return Item
end

local function NewTransfer(Ctx, Kind)
	local Count, Mine = 0, 0
	for _, Item in pairs(Transfers) do
		Count = Count + 1
		if (Item.Client == Ctx.Client.ID) then Mine = Mine + 1 end
	end
	if (Count >= Drive.MaxTransfers or Mine >= Drive.MaxPerClient) then Fail("busy") end
	local Item = { ID = Auth.RandomHex(8), Kind = Kind, Client = Ctx.Client.ID, Touched = os.epoch("utc") }
	Transfers[Item.ID] = Item
	return Item
end

local function EndTransfer(Item)
	Transfers[Item.ID] = nil
	if (Item.Temp and fs.exists(Item.Temp)) then pcall(fs.delete, Item.Temp) end
end

-- Reads Length bytes at Offset from a file.
local function ReadAt(Local, Offset, Length)
	local Handle = fs.open(Local, "rb")
	if (not Handle) then Fail("not_found") end
	if (Handle.seek) then
		Handle.seek("set", Offset)
	elseif (Offset > 0) then
		Handle.read(Offset)
	end
	local Data = Handle.read(Length) or ""
	Handle.close()
	return Data
end

local function Checksum(Local, Size)
	local Sum = 1
	for Offset = 0, Size - 1, Drive.ChunkSize * 4 do
		Sum = Codec.Adler32(ReadAt(Local, Offset, Drive.ChunkSize * 4), Sum)
		Rpc.Yield()
	end
	return Sum
end

-- Shares: the pool's top-level folders (from every pooled root), then disks shared on their own.
local function Shares()
	local Seen, List = {}, {}
	for _, Root in ipairs(Volumes.Pool()) do
		if (fs.isDir(Root)) then
			for _, Name in ipairs(fs.list(Root)) do
				if (Name ~= Path.Reserved and not Seen[Name] and fs.isDir(fs.combine(Root, Name))) then
					Seen[Name] = true
					table.insert(List, { Name = Name, Roots = Volumes.Pool(), Kind = "storage" })
				end
			end
		end
	end
	table.sort(List, function(A, B) return A.Name:lower() < B.Name:lower() end)
	for _, Volume in ipairs(Volumes.List()) do
		if (Volume.Mode == "share" and Volumes.Get(Volume.Name) == Volume) then
			table.insert(List, { Name = Volume.Name, Roots = { Volume.Root }, Kind = "disk", Label = Volume.Label })
		end
	end
	return List
end

local Ops = {}

function Ops.info(Ctx)
	local Settings = Server.Settings()
	local Names, Details = {}, {}
	for _, Share in ipairs(Shares()) do
		table.insert(Names, Share.Name)
		table.insert(Details, {
			Name = Share.Name, Kind = Share.Kind, Label = Share.Label, Disks = #Share.Roots,
			Free = Available(Share.Roots), Largest = Largest(Share.Roots), Capacity = Capacity(Share.Roots)
		})
	end
	local Pool = Volumes.Pool()
	return {
		Name = Settings.DisplayName,
		Shares = Names,
		Volumes = Details,
		Free = Available(Pool),
		Largest = Largest(Pool),
		Capacity = Capacity(Pool),
		PooledDisks = #Pool - 1,
		Used = Usage.Bytes,
		Quota = (tonumber(Settings.QuotaMB) or 0) * 1024 * 1024,
		MaxFile = MaxFile(),
		ChunkSize = Drive.ChunkSize,
		Permission = Ctx.Client.Permission
	}
end

function Ops.list(Ctx, Args)
	local T = Target(Args.Path or "")
	local Parts = Volumes.Find(T)
	if (#Parts == 0) then Fail("not_found") end
	local Merged, Entries = {}, {}
	local Count = 0
	for _, Part in ipairs(Parts) do
		if (not Part.Dir) then Fail("not_dir") end
		for _, Name in ipairs(fs.list(Part.Local)) do
			if (Name ~= Path.Reserved) then
				local Item = Entry(fs.combine(Part.Local, Name), Name)
				local Previous = Merged[Name]
				-- The same name on several disks: one folder, or the newest file.
				if (not Previous or (not Previous.Dir and (Item.Dir or Item.Modified > Previous.Modified))) then
					Merged[Name] = Item
				end
			end
			Count = Count + 1
			if (Count % 100 == 0) then Rpc.Yield() end
		end
	end
	for _, Item in pairs(Merged) do table.insert(Entries, Item) end
	if (T.Normal == "") then
		for _, Share in ipairs(Shares()) do
			if (Share.Kind == "disk") then
				local Item = Entry(Share.Roots[1], Share.Name)
				Item.Disk, Item.Label = true, Share.Label
				table.insert(Entries, Item)
			end
		end
	end
	table.sort(Entries, function(A, B)
		if (A.Dir ~= B.Dir) then return A.Dir end
		return A.Name:lower() < B.Name:lower()
	end)
	return { Path = T.Normal, Entries = Entries, Free = Available(T.Roots), Largest = Largest(T.Roots), ReadOnly = Ctx.Client.Permission ~= "write" }
end

function Ops.stat(Ctx, Args)
	local T = Target(Args.Path or "")
	local Part = Volumes.Locate(T)
	if (not Part) then Fail("not_found") end
	local Result = Entry(Part.Local, Path.Name(T.Normal))
	Result.Path = T.Normal
	return Result
end

function Ops.mkdir(Ctx, Args)
	local T = Target(Args.Path)
	RequireNotShare(T)
	if (Volumes.Locate(T)) then Fail("exists") end
	RequireParent(T)
	-- Folders cost almost nothing; make it where its parent already is.
	local Root = Volumes.Place(T, 0, FreeSpace)
	fs.makeDir(Volumes.Local(Root, T.Rel))
	Log.Info("blockdrive", Ctx.Client.Name .. " created " .. T.Normal)
	Changed()
	return Ops.stat(Ctx, { Path = T.Normal })
end

function Ops.delete(Ctx, Args)
	local T = Target(Args.Path)
	RequireNotShare(T)
	local Parts = Volumes.Find(T)
	if (#Parts == 0) then Fail("not_found") end
	for _, Part in ipairs(Parts) do fs.delete(Part.Local) end
	Log.Info("blockdrive", Ctx.Client.Name .. " deleted " .. T.Normal)
	Changed()
	return true
end

local function Relocate(Ctx, Args, Copy)
	local From, To = Target(Args.From), Target(Args.To)
	if (not Copy) then RequireNotShare(From) end
	RequireNotShare(To)
	local Shown = Volumes.Locate(From)
	if (not Shown) then Fail("not_found") end
	if (Volumes.Locate(To)) then Fail("exists") end
	if (From.Space == To.Space and Path.Within(From.Rel, To.Rel)) then Fail("invalid", "A folder cannot be moved or copied into itself.") end
	RequireParent(To)
	-- A folder may be spread over several disks; a file is its newest copy.
	local Parts = Shown.Dir and Volumes.Find(From) or { Shown }
	if (not Copy and From.Space == To.Space) then
		-- Within one space, each disk renames its own part: no data moves, no space needed.
		for _, Part in ipairs(Parts) do
			local Dest = Volumes.Local(Part.Root, To.Rel)
			local Parent = fs.getDir(Dest)
			if (not fs.exists(Parent)) then fs.makeDir(Parent) end
			fs.move(Part.Local, Dest)
		end
		for _, Part in ipairs(Volumes.Find(From)) do fs.delete(Part.Local) end
	else
		-- Copy file by file, each to a disk with room for it, so a folder spread over several
		-- disks can be copied even when no single disk could hold all of it.
		local Files, Dirs, Size = {}, {}, 0
		local function Collect(Local, Rel)
			if (fs.isDir(Local)) then
				table.insert(Dirs, Rel)
				for _, Name in ipairs(fs.list(Local)) do
					if (Name ~= Path.Reserved) then Collect(fs.combine(Local, Name), Path.Join(Rel, Name)) end
				end
			else
				table.insert(Files, { Source = Local, Rel = Rel, Size = fs.getSize(Local) })
				Size = Size + fs.getSize(Local)
			end
		end
		for _, Part in ipairs(Parts) do Collect(Part.Local, To.Rel) end
		if (Size > Available(To.Roots)) then Fail("no_space") end
		local Ok, Err = pcall(function()
			for _, Rel in ipairs(Dirs) do
				local Spot = { Rel = Rel, Roots = To.Roots }
				if (not Volumes.IsDir(Spot)) then fs.makeDir(Volumes.Local(Volumes.Place(Spot, 0, FreeSpace), Rel)) end
			end
			for Index, File in ipairs(Files) do
				local Spot = { Rel = File.Rel, Roots = To.Roots }
				if (not Volumes.Locate(Spot)) then
					local Root = Volumes.Place(Spot, File.Size, FreeSpace)
					if (not Root) then error("no disk has room for " .. File.Rel, 0) end
					local Dest = Volumes.Local(Root, File.Rel)
					local Parent = fs.getDir(Dest)
					if (not fs.exists(Parent)) then fs.makeDir(Parent) end
					fs.copy(File.Source, Dest)
				end
				if (Index % 20 == 0) then Rpc.Yield() end
			end
		end)
		if (not Ok) then
			-- A half-made copy is worse than none (usually a disk filled up or was removed).
			for _, Root in ipairs(To.Roots) do
				local Dest = Volumes.Local(Root, To.Rel)
				if (fs.exists(Dest)) then pcall(fs.delete, Dest) end
			end
			Changed()
			Fail("no_space", "The copy did not fit: " .. tostring(Err))
		end
		if (not Copy) then
			for _, Part in ipairs(Volumes.Find(From)) do fs.delete(Part.Local) end
		end
	end
	Log.Info("blockdrive", Ctx.Client.Name .. (Copy and " copied " or " moved ") .. From.Normal .. " to " .. To.Normal)
	Changed()
	return Ops.stat(Ctx, { Path = To.Normal })
end

function Ops.move(Ctx, Args) return Relocate(Ctx, Args, false) end
function Ops.copy(Ctx, Args) return Relocate(Ctx, Args, true) end

function Ops.upload_begin(Ctx, Args)
	local T = Target(Args.Path)
	local Size, Sum = tonumber(Args.Size), tonumber(Args.Sum)
	if (not Size or Size < 0 or Size ~= math.floor(Size) or not Sum) then Fail("invalid") end
	RequireNotShare(T)
	RequireParent(T)
	local Existing = Volumes.Locate(T)
	if (Existing and Existing.Dir) then Fail("is_dir") end
	if (Existing and not Args.Overwrite) then Fail("exists") end
	if (MaxFile() and Size > MaxFile()) then Fail("too_large", "Files on this server can be at most " .. math.floor(MaxFile() / 1024) .. " KB.") end
	-- The quota counts the net change; the chosen disk must hold the whole staged copy.
	if (Size - (Existing and fs.getSize(Existing.Local) or 0) > QuotaLeft()) then Fail("no_space") end
	local Root = Volumes.Place(T, Size, FreeSpace, Existing and Existing.Root)
	if (not Root) then
		Fail("no_space", #T.Roots > 1 and "No single disk has room for a file this size (files are not split across disks)." or nil)
	end
	local Item = NewTransfer(Ctx, "up")
	Item.Path, Item.Target, Item.Size, Item.Sum, Item.Overwrite = T.Normal, T, Size, Sum, Args.Overwrite and true or false
	-- Staged on the disk that will hold the file, so the final swap is a rename.
	Item.Root = Root
	Item.Local = Volumes.Local(Root, T.Rel)
	Item.Temp = fs.combine(Volumes.TempDir(Root), Item.ID)
	Item.Received, Item.Next, Item.Running = 0, 1, 1
	local Handle = fs.isDir(Volumes.TempDir(Root)) and fs.open(Item.Temp, "wb")
	if (not Handle) then
		Transfers[Item.ID] = nil
		Fail("internal", "Could not create a staging file.")
	end
	Handle.close()
	return { Transfer = Item.ID, ChunkSize = Drive.ChunkSize }
end

function Ops.upload_chunk(Ctx, Args)
	local Item = Transfer(Ctx, Args.Transfer, "up")
	local Index, Data = tonumber(Args.Index), Args.Data
	if (type(Data) ~= "string" or #Data > Drive.ChunkSize) then Fail("invalid") end
	-- Any chunk but the next one (usually a resend after a lost ack) just reports progress,
	-- and the client continues from Next.
	if (Index ~= Item.Next) then return { Next = Item.Next, Received = Item.Received } end
	if (Codec.Adler32(Data) ~= tonumber(Args.Sum)) then Fail("checksum") end
	if (Item.Received + #Data > Item.Size) then Fail("invalid", "More data than announced.") end
	local Handle = fs.exists(Item.Temp) and fs.open(Item.Temp, "ab")
	if (not Handle) then
		-- The disk was removed under the transfer.
		EndTransfer(Item)
		Fail("transfer_lost")
	end
	local Written = pcall(Handle.write, Data)
	pcall(Handle.close)
	if (not Written or fs.getSize(Item.Temp) ~= Item.Received + #Data) then
		EndTransfer(Item)
		Fail("no_space")
	end
	Item.Received = Item.Received + #Data
	Item.Running = Codec.Adler32(Data, Item.Running)
	Item.Next = Item.Next + 1
	return { Next = Item.Next, Received = Item.Received }
end

function Ops.upload_commit(Ctx, Args)
	local Item = Transfer(Ctx, Args.Transfer, "up")
	if (not fs.exists(Item.Temp)) then
		EndTransfer(Item)
		Fail("transfer_lost")
	end
	if (Item.Received ~= Item.Size or Item.Running ~= Item.Sum or fs.getSize(Item.Temp) ~= Item.Size) then
		EndTransfer(Item)
		Fail("checksum")
	end
	local Existing = Volumes.Locate(Item.Target)
	if (Existing and (Existing.Dir or not Item.Overwrite)) then
		EndTransfer(Item)
		Fail(Existing.Dir and "is_dir" or "exists")
	end
	local Parent = fs.getDir(Item.Local)
	if (not fs.exists(Parent)) then fs.makeDir(Parent) end
	-- Swap the finished file in. The old version is kept aside until the new one is in place.
	local Backup = Item.Temp .. ".old"
	if (fs.exists(Item.Local)) then fs.move(Item.Local, Backup) end
	local Ok, Err = pcall(fs.move, Item.Temp, Item.Local)
	if (not Ok) then
		if (fs.exists(Backup)) then fs.move(Backup, Item.Local) end
		EndTransfer(Item)
		Fail("internal", "Could not save the file: " .. tostring(Err))
	end
	if (fs.exists(Backup)) then fs.delete(Backup) end
	-- The new copy went to another disk: remove the old one (until then, the newer one wins).
	for _, Part in ipairs(Volumes.Find(Item.Target)) do
		if (Part.Local ~= Item.Local) then pcall(fs.delete, Part.Local) end
	end
	Transfers[Item.ID] = nil
	Log.Info("blockdrive", Ctx.Client.Name .. " uploaded " .. Item.Path .. " (" .. Item.Size .. " bytes)")
	Changed()
	return Ops.stat(Ctx, { Path = Item.Path })
end

function Ops.upload_abort(Ctx, Args)
	local Item = Transfers[Args.Transfer]
	if (Item and Item.Client == Ctx.Client.ID) then EndTransfer(Item) end
	return true
end

function Ops.download_begin(Ctx, Args)
	local T = Target(Args.Path)
	local Part = Volumes.Locate(T)
	if (not Part) then Fail("not_found") end
	if (Part.Dir) then Fail("is_dir") end
	local Item = NewTransfer(Ctx, "down")
	Item.Path, Item.Local = T.Normal, Part.Local
	Item.Size = fs.getSize(Part.Local)
	Item.Modified = Modified(Part.Local)
	Item.Sum = Checksum(Part.Local, Item.Size)
	return {
		Transfer = Item.ID, Size = Item.Size, Sum = Item.Sum, ChunkSize = Drive.ChunkSize,
		Chunks = math.ceil(Item.Size / Drive.ChunkSize), Modified = Item.Modified
	}
end

function Ops.download_chunk(Ctx, Args)
	local Item = Transfer(Ctx, Args.Transfer, "down")
	local Index = tonumber(Args.Index)
	if (not Index or Index < 1 or (Index - 1) * Drive.ChunkSize >= math.max(Item.Size, 1)) then Fail("invalid") end
	if (not fs.exists(Item.Local) or fs.getSize(Item.Local) ~= Item.Size or Modified(Item.Local) ~= Item.Modified) then
		EndTransfer(Item)
		Fail("changed")
	end
	local Data = ReadAt(Item.Local, (Index - 1) * Drive.ChunkSize, Drive.ChunkSize)
	return { Data = Data, Sum = Codec.Adler32(Data) }
end

function Ops.download_end(Ctx, Args)
	local Item = Transfers[Args.Transfer]
	if (Item and Item.Client == Ctx.Client.ID) then EndTransfer(Item) end
	return true
end

local Access = {
	info = "read", list = "read", stat = "read", download_begin = "read", download_chunk = "read", download_end = "read",
	mkdir = "write", delete = "write", move = "write", copy = "write",
	upload_begin = "write", upload_chunk = "write", upload_commit = "write", upload_abort = "write"
}

-- Creates the storage root and default share, clears staging files left by a shutdown,
-- and finds the disks.
function Drive.Prepare()
	local Settings = Server.Settings()
	local Ok, Err = Path.ValidRoot(Settings.StorageRoot)
	if (not Ok) then error(Err, 0) end
	local Root = Drive.Root()
	if (not fs.exists(Root)) then fs.makeDir(Root) end
	if (Settings.DefaultShare and Path.ValidName(Settings.DefaultShare)) then
		local Share = fs.combine(Root, Settings.DefaultShare)
		if (not fs.exists(Share)) then fs.makeDir(Share) end
	end
	local Temp = Volumes.TempDir(Root)
	if (fs.exists(Temp)) then fs.delete(Temp) end
	fs.makeDir(Temp)
	Transfers = {}
	Volumes.Refresh()
end

function Drive.Init(Ctx)
	Rpc, Log = Ctx.Rpc, Ctx.Log
	Drive.Prepare()
	local Registered = {}
	for Op, Level in pairs(Access) do
		Registered[Op] = { Access = Level, Handler = Ops[Op] }
	end
	Rpc.Register("blockdrive", Registered)
	Log.Info("blockdrive", "Serving " .. Drive.Root())
end

-- After disks come and go: update the volumes and drop uploads whose disk went away.
local function DisksChanged()
	if (not Volumes.Refresh()) then return end
	local Roots = {}
	for _, Root in ipairs(Volumes.Roots()) do Roots[Root] = true end
	for _, Item in pairs(Transfers) do
		if (Item.Root and not Roots[Item.Root]) then
			Log.Warn("blockdrive", "Stopped the upload of " .. tostring(Item.Path) .. ": its disk was removed")
			EndTransfer(Item)
		end
	end
	Changed()
end

local DiskEvents = { disk = true, disk_eject = true, peripheral = true, peripheral_detach = true, blockcloud_config = true }

function Drive.Run(Ctx)
	local Timer = os.startTimer(1)
	local DiskTimer
	while (true) do
		local Event, A = os.pullEvent()
		if (Event == "timer" and A == Timer) then
			local Now = os.epoch("utc")
			for _, Item in pairs(Transfers) do
				if (Now - Item.Touched > Drive.TransferIdle) then
					Log.Warn("blockdrive", "Abandoned " .. (Item.Kind == "up" and "upload of " or "download of ") .. tostring(Item.Path))
					EndTransfer(Item)
				end
			end
			if (Usage.Dirty) then
				Scan()
				os.queueEvent("blockcloud_storage")
			end
			Timer = os.startTimer(30)
		elseif (Event == "timer" and A == DiskTimer) then
			DiskTimer = nil
			DisksChanged()
		elseif (DiskEvents[Event]) then
			-- A wired network of drives sends a burst of events; look once it settles.
			if (DiskTimer) then os.cancelTimer(DiskTimer) end
			DiskTimer = os.startTimer(1)
		elseif (Event == "blockcloud_storage" and Usage.Dirty) then
			-- Rescan soon after changes, but not on every single one.
			os.cancelTimer(Timer)
			Timer = os.startTimer(5)
		end
	end
end

function Drive.ActiveTransfers()
	local Count = 0
	for _ in pairs(Transfers) do Count = Count + 1 end
	return Count
end

function Drive.Health()
	local Pool = Volumes.Pool()
	local Free = Available(Pool)
	local Active = Drive.ActiveTransfers()
	local Detail = (Active > 0 and (Active .. " transfer" .. (Active == 1 and "" or "s") .. ", ") or "")
		.. math.floor(Free / 1024) .. " KB free" .. (#Pool > 1 and (", " .. (#Pool - 1) .. " disk" .. (#Pool == 2 and "" or "s")) or "")
	if (Free < 32 * 1024) then return "warn", "Storage nearly full (" .. Detail .. ")" end
	return "ok", Detail
end

-- Space figures for the console and bcloud.
Drive.FreeSpace = FreeSpace
function Drive.PoolSpace()
	local Pool = Volumes.Pool()
	return Available(Pool), Capacity(Pool), #Pool - 1
end

function Drive.Info()
	return { ChunkSize = Drive.ChunkSize }
end

return Drive
