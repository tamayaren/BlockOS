-- BlockDrive: network file storage. Every remote path is resolved inside the configured
-- storage root; uploads are staged in a hidden folder and swapped in only once complete and
-- verified, so an interrupted transfer never damages an existing file.

local Path = BlockOS.Require("cloud/path")
local Codec = BlockOS.Require("cloud/codec")
local Auth = BlockOS.Require("cloud/auth")
local Server = BlockOS.Require("server/config")

local Drive = {
	Name = "blockdrive",
	Title = "BlockDrive",
	Description = "Network file storage.",
	Version = "1.0"
}

Drive.ChunkSize = 8192
Drive.TransferIdle = 90 * 1000
Drive.MaxTransfers = 16
Drive.MaxPerClient = 4
-- Space left free on the storage disk so the server itself can still write logs and settings.
Drive.Reserve = 16 * 1024

local Transfers = {}
local Usage = { Bytes = 0, Files = 0, Folders = 0, Scanned = false, Dirty = true }
local Rpc, Log

local function Fail(Code, Detail)
	Rpc.Fail(Code, Detail)
end

function Drive.Root()
	return "/" .. fs.combine(Server.Settings().StorageRoot, "")
end

local function TempDir()
	return fs.combine(Drive.Root(), Path.Reserved .. "/tmp")
end

local function Resolve(Remote)
	local Local, Err, Normal = Path.Resolve(Drive.Root(), Remote)
	if (not Local) then Fail(Err) end
	return Local, Normal
end

local function Modified(Local)
	local Ok, Attributes = pcall(fs.attributes, Local)
	return Ok and Attributes and Attributes.modified or 0
end

local function Entry(Local, Name)
	local Dir = fs.isDir(Local)
	return { Name = Name, Dir = Dir, Size = Dir and 0 or fs.getSize(Local), Modified = Modified(Local) }
end

local function FreeSpace()
	local Free = tonumber(fs.getFreeSpace(Drive.Root())) or 0
	return math.max(0, Free - Drive.Reserve)
end

-- Bytes a client may still add: free disk space, further limited by the quota if one is set.
local function Available()
	local Free = FreeSpace()
	local Quota = (tonumber(Server.Settings().QuotaMB) or 0) * 1024 * 1024
	if (Quota > 0) then
		Free = math.min(Free, math.max(0, Quota - Usage.Bytes))
	end
	return Free
end

local function MaxFile()
	local Limit = (tonumber(Server.Settings().MaxFileKB) or 0) * 1024
	return Limit > 0 and Limit or nil
end

local function SizeOf(Local)
	if (not fs.isDir(Local)) then return fs.getSize(Local) end
	local Total = 0
	for _, Name in ipairs(fs.list(Local)) do
		Total = Total + SizeOf(fs.combine(Local, Name))
	end
	return Total
end

-- Walks the storage tree to total its size, yielding now and then on large trees.
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
	Walk(Drive.Root())
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

local function RequireParent(Normal)
	local Parent = Path.Parent(Normal)
	local LocalParent = Resolve(Parent)
	if (not fs.isDir(LocalParent)) then Fail("not_found", "The folder " .. (Parent == "" and "/" or Parent) .. " does not exist.") end
end

-- Top-level folders are the shares clients see first; they can only be removed on the server.
local function RequireNotShare(Normal)
	if (Normal == "" or not Normal:find("/")) then
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

local Ops = {}

function Ops.info(Ctx)
	local Settings = Server.Settings()
	local Shares = {}
	for _, Name in ipairs(fs.list(Drive.Root())) do
		if (Name ~= Path.Reserved and fs.isDir(fs.combine(Drive.Root(), Name))) then
			table.insert(Shares, Name)
		end
	end
	table.sort(Shares, function(A, B) return A:lower() < B:lower() end)
	return {
		Name = Settings.DisplayName,
		Shares = Shares,
		Free = Available(),
		Capacity = fs.getCapacity and tonumber(fs.getCapacity(Drive.Root())) or nil,
		Used = Usage.Bytes,
		Quota = (tonumber(Settings.QuotaMB) or 0) * 1024 * 1024,
		MaxFile = MaxFile(),
		ChunkSize = Drive.ChunkSize,
		Permission = Ctx.Client.Permission
	}
end

function Ops.list(Ctx, Args)
	local Local, Normal = Resolve(Args.Path or "")
	if (not fs.exists(Local)) then Fail("not_found") end
	if (not fs.isDir(Local)) then Fail("not_dir") end
	local Entries = {}
	for Index, Name in ipairs(fs.list(Local)) do
		if (Name ~= Path.Reserved) then
			table.insert(Entries, Entry(fs.combine(Local, Name), Name))
		end
		if (Index % 100 == 0) then Rpc.Yield() end
	end
	table.sort(Entries, function(A, B)
		if (A.Dir ~= B.Dir) then return A.Dir end
		return A.Name:lower() < B.Name:lower()
	end)
	return { Path = Normal, Entries = Entries, Free = Available(), ReadOnly = Ctx.Client.Permission ~= "write" }
end

function Ops.stat(Ctx, Args)
	local Local, Normal = Resolve(Args.Path or "")
	if (not fs.exists(Local)) then Fail("not_found") end
	local Result = Entry(Local, Path.Name(Normal))
	Result.Path = Normal
	return Result
end

function Ops.mkdir(Ctx, Args)
	local Local, Normal = Resolve(Args.Path)
	RequireNotShare(Normal)
	if (fs.exists(Local)) then Fail("exists") end
	RequireParent(Normal)
	fs.makeDir(Local)
	Log.Info("blockdrive", Ctx.Client.Name .. " created " .. Normal)
	Changed()
	return Ops.stat(Ctx, { Path = Normal })
end

function Ops.delete(Ctx, Args)
	local Local, Normal = Resolve(Args.Path)
	RequireNotShare(Normal)
	if (not fs.exists(Local)) then Fail("not_found") end
	fs.delete(Local)
	Log.Info("blockdrive", Ctx.Client.Name .. " deleted " .. Normal)
	Changed()
	return true
end

local function Relocate(Ctx, Args, Copy)
	local From, FromNormal = Resolve(Args.From)
	local To, ToNormal = Resolve(Args.To)
	if (not Copy) then RequireNotShare(FromNormal) end
	RequireNotShare(ToNormal)
	if (not fs.exists(From)) then Fail("not_found") end
	if (fs.exists(To)) then Fail("exists") end
	if (Path.Within(FromNormal, ToNormal)) then Fail("invalid", "A folder cannot be moved or copied into itself.") end
	RequireParent(ToNormal)
	if (Copy) then
		if (SizeOf(From) > Available()) then Fail("no_space") end
		fs.copy(From, To)
	else
		fs.move(From, To)
	end
	Log.Info("blockdrive", Ctx.Client.Name .. (Copy and " copied " or " moved ") .. FromNormal .. " to " .. ToNormal)
	Changed()
	return Ops.stat(Ctx, { Path = ToNormal })
end

function Ops.move(Ctx, Args) return Relocate(Ctx, Args, false) end
function Ops.copy(Ctx, Args) return Relocate(Ctx, Args, true) end

function Ops.upload_begin(Ctx, Args)
	local Local, Normal = Resolve(Args.Path)
	local Size, Sum = tonumber(Args.Size), tonumber(Args.Sum)
	if (not Size or Size < 0 or Size ~= math.floor(Size) or not Sum) then Fail("invalid") end
	RequireNotShare(Normal)
	RequireParent(Normal)
	if (fs.isDir(Local)) then Fail("is_dir") end
	if (fs.exists(Local) and not Args.Overwrite) then Fail("exists") end
	if (MaxFile() and Size > MaxFile()) then Fail("too_large", "Files on this server can be at most " .. math.floor(MaxFile() / 1024) .. " KB.") end
	local Replacing = fs.exists(Local) and fs.getSize(Local) or 0
	if (Size - Replacing > Available()) then Fail("no_space") end
	local Item = NewTransfer(Ctx, "up")
	Item.Path, Item.Local, Item.Size, Item.Sum, Item.Overwrite = Normal, Local, Size, Sum, Args.Overwrite and true or false
	Item.Temp = fs.combine(TempDir(), Item.ID)
	Item.Received, Item.Next, Item.Running = 0, 1, 1
	local Handle = fs.open(Item.Temp, "wb")
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
	local Handle = fs.open(Item.Temp, "ab")
	if (not Handle) then Fail("internal", "Could not write the staging file.") end
	Handle.write(Data)
	Handle.close()
	Item.Received = Item.Received + #Data
	Item.Running = Codec.Adler32(Data, Item.Running)
	Item.Next = Item.Next + 1
	return { Next = Item.Next, Received = Item.Received }
end

function Ops.upload_commit(Ctx, Args)
	local Item = Transfer(Ctx, Args.Transfer, "up")
	if (Item.Received ~= Item.Size or Item.Running ~= Item.Sum or fs.getSize(Item.Temp) ~= Item.Size) then
		EndTransfer(Item)
		Fail("checksum")
	end
	if (fs.isDir(Item.Local) or (fs.exists(Item.Local) and not Item.Overwrite)) then
		EndTransfer(Item)
		Fail(fs.isDir(Item.Local) and "is_dir" or "exists")
	end
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
	local Local, Normal = Resolve(Args.Path)
	if (not fs.exists(Local)) then Fail("not_found") end
	if (fs.isDir(Local)) then Fail("is_dir") end
	local Item = NewTransfer(Ctx, "down")
	Item.Path, Item.Local = Normal, Local
	Item.Size = fs.getSize(Local)
	Item.Modified = Modified(Local)
	Item.Sum = Checksum(Local, Item.Size)
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

-- Creates the storage root and default share, and clears staging files left by a shutdown.
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
	if (fs.exists(TempDir())) then fs.delete(TempDir()) end
	fs.makeDir(TempDir())
	Transfers = {}
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

function Drive.Run(Ctx)
	local Timer = os.startTimer(1)
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
	local Free = FreeSpace()
	local Active = Drive.ActiveTransfers()
	local Detail = (Active > 0 and (Active .. " transfer" .. (Active == 1 and "" or "s") .. ", ") or "") .. math.floor(Free / 1024) .. " KB free"
	if (Free < 32 * 1024) then return "warn", "Storage nearly full (" .. Detail .. ")" end
	return "ok", Detail
end

function Drive.Info()
	return { ChunkSize = Drive.ChunkSize }
end

return Drive
