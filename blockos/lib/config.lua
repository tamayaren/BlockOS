-- Persistent configuration stored as serialised Lua tables under /blockos/data.

local Config = {}

Config.DataDir = "/blockos/data"
Config.Repo = "https://raw.githubusercontent.com/tamayaren/BlockOS/main/"

Config.Defaults = {
	settings = {
		Theme = "light",
		Accent = colors.blue,
		Wallpaper = "overworld",
		WallpaperColor = colors.cyan,
		Dock = { "finder", "launchpad", "terminal", "editor", "appstore", "messages", "notes", "btunes", "settings" },
		DockSize = "small",
		DockStyle = "solid",
		Animations = true,
		NetworkVisible = true,
		LockColors = "accent",
		Clock24 = true,
		ClockSource = "real",
		ShowSeconds = false,
		AutoUpdate = true,
		AutoInstall = false,
		UpdateURL = Config.Repo,
		Notifications = true,
		NotificationSound = true,
		AutoLogin = false,
		IdleLock = 0,
		StartupApps = {},
		Repositories = { Config.Repo .. "store/catalog.cfg" }
	}
}

local Cache = {}

local function DeepCopy(Value)
	if (type(Value) ~= "table") then return Value end
	local Copy = {}
	for Key, Item in pairs(Value) do
		Copy[Key] = DeepCopy(Item)
	end
	return Copy
end

Config.DeepCopy = DeepCopy

function Config.Read(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil end
	local Handle = fs.open(Path, "r")
	if (not Handle) then return nil end
	local Data = Handle.readAll()
	Handle.close()
	return textutils.unserialise(Data or "")
end

function Config.Write(Path, Value)
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then
		fs.makeDir(Dir)
	end
	local Handle = fs.open(Path, "w")
	if (not Handle) then return false end
	Handle.write(textutils.serialise(Value))
	Handle.close()
	return true
end

function Config.ReadText(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil end
	local Handle = fs.open(Path, "r")
	if (not Handle) then return nil end
	local Data = Handle.readAll()
	Handle.close()
	return Data
end

function Config.WriteText(Path, Text)
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then
		fs.makeDir(Dir)
	end
	local Handle = fs.open(Path, "w")
	if (not Handle) then return false end
	Handle.write(Text)
	Handle.close()
	return true
end

-- Returns a cached table for Name, filling in any missing default keys.
function Config.Load(Name)
	if (Cache[Name]) then return Cache[Name] end
	local Data = Config.Read(fs.combine(Config.DataDir, Name .. ".dat")) or {}
	local Defaults = Config.Defaults[Name]
	if (Defaults) then
		for Key, Value in pairs(Defaults) do
			if (Data[Key] == nil) then
				Data[Key] = DeepCopy(Value)
			end
		end
	end
	Cache[Name] = Data
	return Data
end

function Config.Save(Name)
	local Data = Cache[Name]
	if (not Data) then return false end
	local Ok = Config.Write(fs.combine(Config.DataDir, Name .. ".dat"), Data)
	if (Name == "settings") then
		os.queueEvent("blockos_settings")
	end
	return Ok
end

function Config.Settings()
	return Config.Load("settings")
end

function Config.Reload(Name)
	Cache[Name] = nil
	return Config.Load(Name)
end

function Config.Version()
	local Version = Config.ReadText("/blockos/version.txt")
	if (not Version) then return "0.0.0" end
	return (Version:gsub("%s+", ""))
end

return Config
