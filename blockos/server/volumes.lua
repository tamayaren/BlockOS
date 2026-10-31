-- Storage volumes for BlockDrive. The main storage folder and the server's disk drives
-- (attached directly or over wired modems, up to a hundred or more) are combined:
--
--   pool   (default) the disk joins the main storage as one pooled space. Shares are the
--          top-level folders of the pool, so "Shared" spans every pooled disk. Each file lives
--          whole on one disk; new files go where their folder already is, or to the emptiest disk.
--   share  the disk is its own share, named after its label or ID.
--   off    the disk is not used.
--
-- A disk's files live in a "blockcloud" folder on it, so nothing else on the disk is exposed
-- (a client could otherwise write a startup file that runs wherever the floppy goes next).
-- Settings follow the floppy's ID, not its diskN mount name, which can change between boots.

local Server = BlockOS.Require("server/config")
local Path = BlockOS.Require("cloud/path")
local Log = BlockOS.Require("server/log")

local Volumes = {}

Volumes.Folder = "blockcloud"
Volumes.Modes = { pool = true, share = true, off = true }

local Current = {}
local ByName = {}
local Pool = {}
local Prepared = {}
local Started = false

function Volumes.Primary()
	return "/" .. fs.combine(Server.Settings().StorageRoot, "")
end

function Volumes.TempDir(Root)
	return "/" .. fs.combine(Root, Path.Reserved .. "/tmp")
end

local function KeyOf(Side, Mount)
	local Ok, ID = pcall(disk.getID, Side)
	if (Ok and ID) then return "id" .. ID, ID end
	return "drive:" .. Side, nil
end

local function DefaultName(Label, ID, Side)
	if (Label and Path.ValidName(Label)) then return Label end
	if (ID) then return "Disk " .. ID end
	return Side
end

-- Natural order, so "Disk 9" sorts before "Disk 10".
local function NaturalLess(A, B)
	local function Key(Text)
		return (Text:lower():gsub("%d+", function(Digits) return string.format("%012d", tonumber(Digits)) end))
	end
	return Key(A) < Key(B)
end

-- Creates the disk's folder and clears staging files left by a shutdown or an eject.
local function Prepare(Volume)
	local Marker = Volume.Key .. "@" .. Volume.Mount
	if (Prepared[Marker]) then return end
	if (not fs.exists(Volume.Root)) then fs.makeDir(Volume.Root) end
	local Temp = Volumes.TempDir(Volume.Root)
	if (fs.exists(Temp)) then fs.delete(Temp) end
	fs.makeDir(Temp)
	Prepared[Marker] = true
	if (Started) then
		Log.Info("blockdrive", "Using disk " .. Volume.Name .. " (" .. Volume.Side .. ", " .. Volume.Mode .. ")")
	end
end

-- Looks at the attached drives again. Returns true when the shared disks changed.
function Volumes.Refresh()
	local Settings = Server.Settings()
	local Saved = Settings.Disks or {}
	local Default = Volumes.Modes[Settings.DiskMode] and Settings.DiskMode or "pool"
	local Primary = Volumes.Primary()
	local List = {}
	for _, Side in ipairs(peripheral.getNames()) do
		local Ok, Type = pcall(peripheral.getType, Side)
		if (Ok and Type == "drive" and disk.hasData(Side)) then
			local MountName = disk.getMountPath(Side)
			local Mount = MountName and ("/" .. MountName)
			-- The disk holding the main storage folder is already part of it.
			if (Mount and Primary ~= Mount and Primary:sub(1, #Mount + 1) ~= Mount .. "/") then
				local Key, ID = KeyOf(Side, Mount)
				local Options = Saved[Key] or {}
				local Label = disk.getLabel(Side)
				local Mode = Options.Mode or (Options.Enabled == false and "off") or Default
				if (Settings.ShareDisks == false) then Mode = "off" end
				table.insert(List, {
					Key = Key, ID = ID, Side = Side, Mount = Mount, Label = Label,
					Root = "/" .. fs.combine(Mount, Volumes.Folder),
					Name = Options.Name or DefaultName(Label, ID, Side),
					Mode = Mode
				})
			end
		end
	end
	table.sort(List, function(A, B) return NaturalLess(A.Name, B.Name) end)
	local Names, NewPool, Signature = {}, { Primary }, {}
	for _, Volume in ipairs(List) do
		if (Volume.Mode == "share" and (Names[Volume.Name] or fs.isDir(fs.combine(Primary, Volume.Name)))) then
			-- Share names must be unique and must not hide a folder in the main storage.
			Volume.Name = Volume.Name .. " (" .. Volume.Side .. ")"
		end
		if (Volume.Mode ~= "off") then
			local Ok, Err = pcall(Prepare, Volume)
			if (not Ok) then
				Volume.Error = tostring(Err)
				Volume.Mode = "off"
				Log.Warn("blockdrive", "Cannot use disk " .. Volume.Name .. ": " .. Volume.Error)
			end
		end
		if (Volume.Mode == "share") then
			Names[Volume.Name] = Volume
		elseif (Volume.Mode == "pool") then
			table.insert(NewPool, Volume.Root)
		end
		if (Volume.Mode ~= "off") then table.insert(Signature, Volume.Mode .. ":" .. Volume.Name .. "=" .. Volume.Root) end
	end
	local Before = {}
	for _, Volume in ipairs(Current) do
		if (Volume.Mode ~= "off") then table.insert(Before, Volume.Mode .. ":" .. Volume.Name .. "=" .. Volume.Root) end
	end
	local Changed = table.concat(Before, "|") ~= table.concat(Signature, "|")
	Current, ByName, Pool = List, Names, NewPool
	if (not Started) then
		Started = true
		local Pooled, Shared = #NewPool - 1, 0
		for _ in pairs(Names) do Shared = Shared + 1 end
		if (#List > 0) then
			Log.Info("blockdrive", #List .. " disk" .. (#List == 1 and "" or "s") .. ": " .. Pooled .. " pooled, " .. Shared .. " shared on their own")
		end
	end
	return Changed
end

-- Every attached disk: Key, ID, Side, Mount, Label, Root, Name, Mode.
function Volumes.List()
	return Current
end

-- A disk shared on its own, by share name.
function Volumes.Get(Name)
	return ByName[Name]
end

-- Roots of the pooled space: the main storage folder first, then the pooled disks.
function Volumes.Pool()
	return Pool
end

-- Every folder that holds BlockDrive files.
function Volumes.Roots()
	local Roots = {}
	for _, Root in ipairs(Pool) do table.insert(Roots, Root) end
	for _, Volume in ipairs(Current) do
		if (Volume.Mode == "share" and ByName[Volume.Name] == Volume) then table.insert(Roots, Volume.Root) end
	end
	return Roots
end

-- Where a remote path lives: { Normal, Rel (path inside each root), Roots, Space ("pool" or the
-- disk's key), Volume (own-share disk or nil) }, or nil and an error code.
function Volumes.Target(Remote)
	local Normal, Err = Path.Normalize(Remote)
	if (not Normal) then return nil, Err end
	local Top = Normal:match("^[^/]+")
	local Volume = Top and ByName[Top]
	if (Volume) then
		return { Normal = Normal, Rel = Normal:sub(#Top + 2), Roots = { Volume.Root }, Space = Volume.Key, Volume = Volume }
	end
	return { Normal = Normal, Rel = Normal, Roots = Pool, Space = "pool" }
end

-- The local path of Rel inside Root (containment checked again, as a second line of defence).
function Volumes.Local(Root, Rel)
	local Local, Err = Path.Resolve(Root, Rel)
	if (not Local) then error({ BlockCloud = true, Code = Err }, 0) end
	return Local
end

local function Modified(Local)
	local Ok, Attributes = pcall(fs.attributes, Local)
	return Ok and Attributes and Attributes.modified or 0
end

-- Every root where the path exists: { Root, Local, Dir }.
function Volumes.Find(Target)
	local Found = {}
	for _, Root in ipairs(Target.Roots) do
		local Local = Volumes.Local(Root, Target.Rel)
		if (fs.exists(Local)) then
			table.insert(Found, { Root = Root, Local = Local, Dir = fs.isDir(Local) })
		end
	end
	return Found
end

-- The copy a client sees: a folder if any root has one, otherwise the newest file (so an
-- update that moved a file to another disk wins even if the old copy was not yet deleted).
function Volumes.Locate(Target)
	local Best
	for _, Part in ipairs(Volumes.Find(Target)) do
		if (Part.Dir) then return Part end
		Part.Modified = Modified(Part.Local)
		if (not Best or Part.Modified > Best.Modified) then Best = Part end
	end
	return Best
end

function Volumes.IsDir(Target)
	local Part = Volumes.Locate(Target)
	return Part ~= nil and Part.Dir
end

-- Picks the root for Size new bytes: one where the parent folder already is, if it fits
-- there, otherwise the one with the most free space. Free(Root) gives usable bytes.
function Volumes.Place(Target, Size, Free, Prefer)
	if (Prefer and Free(Prefer) >= Size) then return Prefer end
	local Parent = Path.Parent(Target.Rel)
	local Best, BestFree
	for _, Root in ipairs(Target.Roots) do
		local Space = Free(Root)
		if (Space >= Size) then
			if (fs.isDir(Volumes.Local(Root, Parent))) then return Root end
			if (not Best or Space > BestFree) then Best, BestFree = Root, Space end
		end
	end
	return Best
end

-- Files a disk holds for BlockDrive, for warnings before a disk leaves the pool or a share.
function Volumes.FileCount(Volume)
	local function Count(Dir)
		if (not fs.isDir(Dir)) then return fs.exists(Dir) and 1 or 0 end
		local Total = 0
		for _, Name in ipairs(fs.list(Dir)) do
			if (Name ~= Path.Reserved) then Total = Total + Count(fs.combine(Dir, Name)) end
		end
		return Total
	end
	local Ok, Total = pcall(Count, Volume.Root)
	return Ok and Total or 0
end

-- How many disks are pooled, shared on their own, or unused.
function Volumes.Summary()
	local Counts = { pool = 0, share = 0, off = 0 }
	for _, Volume in ipairs(Current) do Counts[Volume.Mode] = (Counts[Volume.Mode] or 0) + 1 end
	return Counts
end

-- What changing a disk's mode does to the files on it, or nil if nothing visible changes.
function Volumes.ModeWarning(Volume, Mode)
	if (Volume.Mode == Mode or Volume.Mode == "off") then return nil end
	local Files = Volumes.FileCount(Volume)
	if (Files == 0) then return nil end
	local Where = Volume.Mode == "pool" and "the pool" or ("the " .. Volume.Name .. " share")
	return Volume.Name .. " holds " .. Files .. " file" .. (Files == 1 and "" or "s") .. " in " .. Where
		.. ". They stay on the disk but BlockDrive users will " .. (Mode == "off" and "not see them" or "see them in a different place")
		.. " until the disk is set back."
end

local function Save(Key, Field, Value)
	local Settings = Server.Settings()
	Settings.Disks = Settings.Disks or {}
	Settings.Disks[Key] = Settings.Disks[Key] or {}
	Settings.Disks[Key][Field] = Value
	Server.Save()
	Volumes.Refresh()
	os.queueEvent("blockcloud_storage")
end

-- Renames a disk (its share name when shared on its own). Returns true or nil, message.
function Volumes.Rename(Key, Name)
	if (not Path.ValidName(Name)) then return nil, "That is not a valid name." end
	for _, Volume in ipairs(Current) do
		if (Volume.Key ~= Key and Volume.Name == Name) then return nil, "Another disk already uses that name." end
	end
	if (fs.isDir(fs.combine(Volumes.Primary(), Name))) then return nil, "A share in the pool already uses that name." end
	Save(Key, "Name", Name)
	return true
end

-- Mode is "pool", "share" or "off".
function Volumes.SetMode(Key, Mode)
	if (not Volumes.Modes[Mode]) then return nil, "Use pool, share or off." end
	Save(Key, "Mode", Mode)
	return true
end

return Volumes
