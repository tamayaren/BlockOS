-- BlockDrive client API: a remote filesystem on a paired BlockCloud server.
-- Deliberately separate from CC's fs API; remote paths are never treated as local ones.
-- Every function returns its result, or nil and an error table { Code, Message }.

local Client = BlockOS.Require("cloud/client")
local Transfer = BlockOS.Require("cloud/transfer")
local Path = BlockOS.Require("cloud/path")
local Protocol = BlockOS.Require("cloud/protocol")

local Drive = {}

local function Call(Server, Op, Args)
	return Client.Call(Server, "blockdrive", Op, Args)
end

-- Name, Shares, Free, Capacity, Used, Quota, MaxFile, Permission.
function Drive.Info(Server) return Call(Server, "info", {}) end

-- Entries: { Name, Dir, Size, Modified }, folders first.
function Drive.List(Server, Remote) return Call(Server, "list", { Path = Remote or "" }) end

function Drive.Stat(Server, Remote) return Call(Server, "stat", { Path = Remote }) end
function Drive.MakeDir(Server, Remote) return Call(Server, "mkdir", { Path = Remote }) end
function Drive.Delete(Server, Remote) return Call(Server, "delete", { Path = Remote }) end
function Drive.Move(Server, From, To) return Call(Server, "move", { From = From, To = To }) end
function Drive.Copy(Server, From, To) return Call(Server, "copy", { From = From, To = To }) end

function Drive.Rename(Server, Remote, NewName)
	if (not Path.ValidName(NewName)) then return nil, Protocol.Error("invalid_name") end
	return Drive.Move(Server, Remote, Path.Join(Path.Parent(Remote), NewName))
end

-- Opts: Overwrite, OnProgress, Cancelled.
function Drive.Upload(Server, LocalPath, Remote, Opts)
	return Transfer.Upload(Server, Remote, { Path = LocalPath }, Opts)
end

function Drive.Download(Server, Remote, LocalPath, Opts)
	Opts = Opts or {}
	Opts.Path = LocalPath
	return Transfer.Download(Server, Remote, Opts)
end

function Drive.ReadText(Server, Remote, Opts)
	return Transfer.Download(Server, Remote, Opts)
end

function Drive.WriteText(Server, Remote, Text, Opts)
	Opts = Opts or {}
	if (Opts.Overwrite == nil) then Opts.Overwrite = true end
	return Transfer.Upload(Server, Remote, { Data = Text }, Opts)
end

-- Text files BlockDrive opens in its editor.
Drive.TextTypes = { txt = true, md = true, lua = true, cfg = true, json = true, log = true, csv = true, ini = true }

function Drive.IsText(Name)
	local Extension = (Name:match("%.(%w+)$") or ""):lower()
	return Drive.TextTypes[Extension] == true or not Name:find("%.")
end

return Drive
