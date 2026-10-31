-- Server log: the last few hundred lines in memory for the console, and a rotating file on disk.

local Log = {}

Log.Path = "/blockos/data/cloud/logs/server.log"
Log.OldPath = "/blockos/data/cloud/logs/server.old.log"
Log.MaxFile = 32 * 1024
Log.Lines = {}
Log.Limit = 200
Log.Levels = { debug = 1, info = 2, warn = 3, error = 4 }
Log.Level = "info"
Log.Counter = 0

local function Stamp()
	local Ok, Text = pcall(os.date, "%Y-%m-%d %H:%M:%S")
	return Ok and Text or tostring(os.clock())
end

local function Append(Line)
	local Dir = fs.getDir(Log.Path)
	if (not fs.exists(Dir)) then fs.makeDir(Dir) end
	if (fs.exists(Log.Path) and fs.getSize(Log.Path) > Log.MaxFile) then
		if (fs.exists(Log.OldPath)) then fs.delete(Log.OldPath) end
		fs.move(Log.Path, Log.OldPath)
	end
	local Handle = fs.open(Log.Path, "a")
	if (Handle) then
		Handle.writeLine(Line)
		Handle.close()
	end
end

function Log.Write(Level, Source, Text)
	if ((Log.Levels[Level] or 2) < (Log.Levels[Log.Level] or 2)) then return end
	local Entry = { Time = Stamp(), Level = Level, Source = Source, Text = tostring(Text) }
	table.insert(Log.Lines, Entry)
	if (#Log.Lines > Log.Limit) then table.remove(Log.Lines, 1) end
	Log.Counter = Log.Counter + 1
	pcall(Append, Entry.Time .. " " .. Level:upper() .. " [" .. Source .. "] " .. Entry.Text)
	os.queueEvent("blockcloud_log")
end

function Log.Info(Source, Text) Log.Write("info", Source, Text) end
function Log.Warn(Source, Text) Log.Write("warn", Source, Text) end
function Log.Error(Source, Text) Log.Write("error", Source, Text) end
function Log.Debug(Source, Text) Log.Write("debug", Source, Text) end

return Log
