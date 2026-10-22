-- Remote paths for BlockCloud storage. A remote path is relative to a share root and written
-- with forward slashes ("Shared/docs/notes.txt"); "" is the root. Paths are validated strictly
-- rather than resolved, so ".." and other escapes are rejected instead of being interpreted.

local Path = {}

Path.MaxLength = 240
Path.MaxComponent = 64
Path.MaxDepth = 24
-- Kept inside every storage root for staging uploads; never visible or addressable remotely.
Path.Reserved = ".blockcloud"

local Forbidden = "[%c\"%*:<>%?|]"

-- Returns the canonical form of a remote path, or nil and an error code.
function Path.Normalize(Remote)
	if (type(Remote) ~= "string") then return nil, "invalid_path" end
	if (#Remote > Path.MaxLength) then return nil, "invalid_path" end
	local Parts = {}
	for Part in Remote:gsub("\\", "/"):gmatch("[^/]+") do
		if (Part == "..") then return nil, "invalid_path" end
		if (Part ~= ".") then
			if (#Part > Path.MaxComponent or Part:find(Forbidden) or Part:match("^%s") or Part:match("%s$")) then
				return nil, "invalid_path"
			end
			if (Part:lower() == Path.Reserved) then return nil, "invalid_path" end
			Parts[#Parts + 1] = Part
		end
	end
	if (#Parts > Path.MaxDepth) then return nil, "invalid_path" end
	return table.concat(Parts, "/")
end

-- Checks a single file or folder name (for create and rename).
function Path.ValidName(Name)
	if (type(Name) ~= "string" or Name == "" or Name == "." or Name:find("[/\\]")) then return false end
	local Normal = Path.Normalize(Name)
	return Normal == Name
end

function Path.Join(Base, Name)
	if (Base == nil or Base == "") then return Name end
	if (Name == nil or Name == "") then return Base end
	return Base .. "/" .. Name
end

function Path.Parent(Remote)
	return Remote:match("^(.*)/[^/]*$") or ""
end

function Path.Name(Remote)
	return Remote:match("([^/]*)$") or Remote
end

-- True when Child is Parent itself or somewhere below it.
function Path.Within(Parent, Child)
	if (Parent == "") then return true end
	return Child == Parent or Child:sub(1, #Parent + 1) == Parent .. "/"
end

function Path.Split(Remote)
	local Parts = {}
	for Part in Remote:gmatch("[^/]+") do
		Parts[#Parts + 1] = Part
	end
	return Parts
end

-- Maps a remote path to a local path under Root. Returns the local path or nil and an error code.
-- The containment check runs on the combined path too, as a second line of defence.
function Path.Resolve(Root, Remote)
	local Normal, Err = Path.Normalize(Remote)
	if (not Normal) then return nil, Err end
	local Base = "/" .. fs.combine(Root, "")
	local Local = "/" .. fs.combine(Base, Normal)
	if (Local ~= Base and Local:sub(1, #Base + 1) ~= Base .. "/") then
		return nil, "invalid_path"
	end
	return Local, nil, Normal
end

-- Storage roots must be a dedicated folder: not the computer root, the ROM or the OS itself.
function Path.ValidRoot(Root)
	if (type(Root) ~= "string") then return false, "Storage location must be a path." end
	local Clean = fs.combine(Root, "")
	if (Clean == "") then return false, "The storage location cannot be the root of the computer." end
	local Top = Clean:match("^[^/]+")
	if (Top == "rom" or Top == "blockos" or Top == "startup" or Top == "startup.lua") then
		return false, "The storage location cannot be inside /" .. Top .. "."
	end
	if (fs.exists(Clean) and not fs.isDir(Clean)) then
		return false, "/" .. Clean .. " is a file."
	end
	return true
end

return Path
