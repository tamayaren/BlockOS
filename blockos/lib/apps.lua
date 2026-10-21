-- Application registry: bundled apps in /blockos/apps, installed apps in /blockos/userapps.
-- Each app folder holds an app.cfg (serialised Lua table) and its entry script.

local Config = BlockOS.Require("config")

local Apps = {}

Apps.SystemDir = "/blockos/apps"
Apps.UserDir = "/blockos/userapps"

local IconColors = {
	"blue", "purple", "magenta", "red", "orange", "yellow", "lime", "green", "cyan", "lightBlue", "pink", "brown"
}

local function ColorOf(Value, Fallback)
	if (type(Value) == "number") then return Value end
	if (type(Value) == "string" and colors[Value]) then return colors[Value] end
	return Fallback
end

function Apps.DefaultIcon(Name)
	local Initials = Name:gsub("[^%w]", ""):sub(1, 2)
	if (#Initials == 0) then Initials = "?" end
	local Hash = 0
	for Index = 1, #Name do
		Hash = (Hash * 31 + Name:byte(Index)) % 997
	end
	return {
		Lines = { " " .. Initials:upper() .. string.rep(" ", 2 - #Initials), "   " },
		Fg = colors.white,
		Bg = colors[IconColors[Hash % #IconColors + 1]]
	}
end

local function Normalize(Meta, Dir, System)
	local App = {}
	for Key, Value in pairs(Meta) do
		App[Key] = Value
	end
	App.ID = fs.getName(Dir)
	App.Dir = "/" .. fs.combine(Dir, "")
	App.Path = "/" .. fs.combine(Dir, Meta.Main or "main.lua")
	App.System = System
	App.Name = Meta.Name or App.ID
	App.Mode = Meta.Mode or "window"
	local Icon = Meta.Icon
	if (type(Icon) == "table" and type(Icon.Lines) == "table") then
		App.Icon = {
			Lines = { tostring(Icon.Lines[1] or "   "), tostring(Icon.Lines[2] or "   ") },
			Fg = ColorOf(Icon.Fg, colors.white),
			Bg = ColorOf(Icon.Bg, colors.gray)
		}
	else
		App.Icon = Apps.DefaultIcon(App.Name)
	end
	return App
end

local function ReadDir(Root, System, Into)
	if (not fs.isDir(Root)) then return end
	for _, Name in ipairs(fs.list(Root)) do
		local Dir = fs.combine(Root, Name)
		local Meta = fs.isDir(Dir) and Config.Read(fs.combine(Dir, "app.cfg"))
		if (type(Meta) == "table") then
			Into[Name] = Normalize(Meta, Dir, System)
		end
	end
end

function Apps.All()
	local Result = {}
	ReadDir(Apps.SystemDir, true, Result)
	ReadDir(Apps.UserDir, false, Result)
	return Result
end

function Apps.List(IncludeHidden)
	local Result = {}
	for _, App in pairs(Apps.All()) do
		if (IncludeHidden or not App.Hidden) then
			table.insert(Result, App)
		end
	end
	table.sort(Result, function(A, B) return A.Name:lower() < B.Name:lower() end)
	return Result
end

function Apps.Get(ID)
	if (type(ID) ~= "string" or #ID == 0) then return nil end
	for _, Root in ipairs({ Apps.UserDir, Apps.SystemDir }) do
		local Dir = fs.combine(Root, ID)
		local Meta = Config.Read(fs.combine(Dir, "app.cfg"))
		if (type(Meta) == "table") then
			return Normalize(Meta, Dir, Root == Apps.SystemDir)
		end
	end
	return nil
end

function Apps.MakeID(Name)
	local ID = Name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if (#ID == 0) then ID = "app" end
	return ID
end

-- Writes an app to /blockos/userapps. Meta uses the app.cfg fields.
function Apps.Install(Meta, Source)
	local ID = Meta.ID or Apps.MakeID(Meta.Name or "app")
	if (fs.exists(fs.combine(Apps.SystemDir, ID))) then
		ID = ID .. "-app"
	end
	local Dir = fs.combine(Apps.UserDir, ID)
	if (not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Stored = {}
	for Key, Value in pairs(Meta) do
		if (Key ~= "ID") then Stored[Key] = Value end
	end
	Stored.Main = "main.lua"
	Stored.Installed = os.epoch and os.epoch("utc") or 0
	Config.WriteText(fs.combine(Dir, "main.lua"), Source)
	Config.Write(fs.combine(Dir, "app.cfg"), Stored)
	os.queueEvent("blockos_apps")
	return Apps.Get(ID)
end

function Apps.Uninstall(ID)
	local Dir = fs.combine(Apps.UserDir, ID)
	if (not fs.exists(Dir)) then return false end
	fs.delete(Dir)
	local Settings = Config.Settings()
	for Index = #Settings.Dock, 1, -1 do
		if (Settings.Dock[Index] == ID) then
			table.remove(Settings.Dock, Index)
		end
	end
	for Index = #Settings.Shortcuts, 1, -1 do
		if (Settings.Shortcuts[Index] == Apps.AppShortcut(ID)) then
			table.remove(Settings.Shortcuts, Index)
		end
	end
	Config.Save("settings")
	os.queueEvent("blockos_apps")
	return true
end

function Apps.Fetch(Url)
	if (not http) then return nil, "HTTP is disabled on this server" end
	local Ok, Err = http.checkURL(Url)
	if (not Ok) then return nil, Err or "URL not allowed" end
	local Response, Message = http.get(Url, nil, true)
	if (not Response) then return nil, Message or "Request failed" end
	local Body = Response.readAll()
	Response.close()
	return Body
end

function Apps.FetchPastebin(Code)
	Code = tostring(Code):gsub("^https?://pastebin%.com/", ""):gsub("^raw/", ""):gsub("[^%w]", "")
	if (#Code == 0) then return nil, "Invalid Pastebin code" end
	return Apps.Fetch("https://pastebin.com/raw/" .. Code .. "?cb=" .. ("%x"):format(math.random(0, 2 ^ 30)))
end

function Apps.IsPinned(ID)
	for _, Pinned in ipairs(Config.Settings().Dock) do
		if (Pinned == ID) then return true end
	end
	return false
end

function Apps.SetPinned(ID, Pinned)
	local Dock = Config.Settings().Dock
	for Index = #Dock, 1, -1 do
		if (Dock[Index] == ID) then
			table.remove(Dock, Index)
		end
	end
	if (Pinned) then
		table.insert(Dock, ID)
	end
	Config.Save("settings")
end

--
-- Desktop shortcuts: settings.Shortcuts holds "app:<id>" for apps and absolute paths for files.
--

function Apps.AppShortcut(ID)
	return "app:" .. ID
end

local function ShortcutTarget(Target)
	if (Target:sub(1, 4) == "app:") then return Target end
	return "/" .. fs.combine(Target, "")
end

function Apps.HasShortcut(Target)
	Target = ShortcutTarget(Target)
	for _, Entry in ipairs(Config.Settings().Shortcuts) do
		if (Entry == Target) then return true end
	end
	return false
end

function Apps.SetShortcut(Target, Enabled)
	Target = ShortcutTarget(Target)
	local Shortcuts = Config.Settings().Shortcuts
	for Index = #Shortcuts, 1, -1 do
		if (Shortcuts[Index] == Target) then
			table.remove(Shortcuts, Index)
		end
	end
	if (Enabled) then
		table.insert(Shortcuts, Target)
	end
	Config.Save("settings")
end

-- Follows a moved or renamed file or folder; a nil New drops the shortcuts instead.
function Apps.MoveShortcuts(Old, New)
	Old = ShortcutTarget(Old)
	New = New and ShortcutTarget(New)
	local Shortcuts = Config.Settings().Shortcuts
	local Changed = false
	for Index = #Shortcuts, 1, -1 do
		local Entry = Shortcuts[Index]
		if (Entry == Old or Entry:sub(1, #Old + 1) == Old .. "/") then
			Changed = true
			if (New) then
				Shortcuts[Index] = New .. Entry:sub(#Old + 1)
			else
				table.remove(Shortcuts, Index)
			end
		end
	end
	if (Changed) then Config.Save("settings") end
end

return Apps
