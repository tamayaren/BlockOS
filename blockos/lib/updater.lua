-- Checks the update channel for a newer manifest and installs it in place.

local Config = BlockOS.Require("config")

local Updater = {}

Updater.State = { Status = "idle" }

-- Which release this computer follows. The desktop uses the defaults; BlockOS Server Edition
-- swaps in its own channel and manifest, and a manifest for a different edition is refused.
Updater.Profile = { Edition = nil, Manifest = "manifest.cfg", Url = nil }

local Protected = { ["blockos/data"] = true, ["blockos/userapps"] = true }

function Updater.Base()
	local Profile = Updater.Profile
	local Base = (Profile.Url and Profile.Url()) or Config.Settings().UpdateURL or Config.Repo
	if (Base:sub(-1) ~= "/") then Base = Base .. "/" end
	return Base
end

local function ParseVersion(Version)
	local Parts = {}
	for Number in tostring(Version):gmatch("%d+") do
		table.insert(Parts, tonumber(Number))
	end
	return Parts
end

function Updater.Compare(A, B)
	local Left, Right = ParseVersion(A), ParseVersion(B)
	for Index = 1, math.max(#Left, #Right) do
		local L, R = Left[Index] or 0, Right[Index] or 0
		if (L ~= R) then
			return L < R and -1 or 1
		end
	end
	return 0
end

local function Get(Url)
	if (not http) then return nil, "HTTP is disabled" end
	local Separator = Url:find("?", 1, true) and "&" or "?"
	local Response, Err = http.get(Url .. Separator .. "t=" .. tostring(os.epoch and os.epoch("utc") or os.clock()), nil, true)
	if (not Response) then return nil, Err or "Request failed" end
	local Body = Response.readAll()
	Response.close()
	return Body
end

Updater.Get = Get

function Updater.Check()
	Updater.State.Status = "checking"
	local Body, Err = Get(Updater.Base() .. (Updater.Profile.Manifest or "manifest.cfg"))
	if (not Body) then
		Updater.State.Status = "error"
		Updater.State.Error = Err
		return nil, Err
	end
	local Manifest = textutils.unserialise(Body)
	if (type(Manifest) ~= "table" or type(Manifest.Files) ~= "table") then
		Updater.State.Status = "error"
		Updater.State.Error = "Invalid manifest"
		return nil, "Invalid manifest"
	end
	if ((Manifest.Edition or "desktop") ~= (Updater.Profile.Edition or "desktop")) then
		Updater.State.Status = "error"
		Updater.State.Error = "The update channel is for BlockOS " .. tostring(Manifest.Edition or "desktop") .. ", not this edition"
		return nil, Updater.State.Error
	end
	Manifest.Newer = Updater.Compare(Config.Version(), Manifest.Version) < 0
	Updater.State.Latest = Manifest
	Updater.State.Status = Manifest.Newer and "available" or "uptodate"
	Updater.State.Checked = os.epoch and os.epoch("utc") or 0
	return Manifest
end

-- Downloads every file in the manifest to a staging folder, then swaps them in.
function Updater.Apply(Manifest, OnProgress)
	local Staging = "/blockos/.update"
	if (fs.exists(Staging)) then fs.delete(Staging) end
	Updater.State.Status = "downloading"
	local Base = Updater.Base()
	for Index, Path in ipairs(Manifest.Files) do
		local Top = Path:match("^(blockos/[^/]+)")
		if (not Protected[Top or ""]) then
			if (OnProgress) then OnProgress(Index - 1, #Manifest.Files, Path) end
			local Body, Err = Get(Base .. Path)
			if (not Body) then
				Updater.State.Status = "error"
				Updater.State.Error = Path .. ": " .. tostring(Err)
				fs.delete(Staging)
				return false, Updater.State.Error
			end
			Config.WriteText(fs.combine(Staging, Path), Body)
		end
	end
	for _, Path in ipairs(Manifest.Files) do
		local Source = fs.combine(Staging, Path)
		if (fs.exists(Source)) then
			if (fs.exists(Path)) then fs.delete(Path) end
			local Dir = fs.getDir(Path)
			if (Dir ~= "" and not fs.exists(Dir)) then fs.makeDir(Dir) end
			fs.move(Source, Path)
		end
	end
	fs.delete(Staging)
	Config.WriteText("/blockos/version.txt", Manifest.Version)
	if (OnProgress) then OnProgress(#Manifest.Files, #Manifest.Files, "") end
	Updater.State.Status = "ready"
	return true
end

return Updater
