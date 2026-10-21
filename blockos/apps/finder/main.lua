-- Finder: file manager with favourites, disks and an Applications view.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Apps = BlockOS.Require("apps")
local Config = BlockOS.Require("config")
local Image = BlockOS.Require("image")
local Wallpaper = BlockOS.Require("wallpaper")

local Args = { ... }

local AppsPath = "apps:"
local Printable = { txt = true, md = true, log = true }
local Current = Args[1] or "/home"
local Back, Forward = {}, {}
local Page = Ui.Page.new()
local Sidebar, Files, PathLabel, Status

BlockOS.Clipboard = BlockOS.Clipboard or {}

local Kinds = {
	lua = { Icon = "\4", Fg = colors.yellow, Name = "Lua script" },
	txt = { Icon = "\7", Fg = colors.lightGray, Name = "Text" },
	md = { Icon = "\7", Fg = colors.lightGray, Name = "Markdown" },
	dfpwm = { Icon = "\14", Fg = colors.red, Name = "DFPWM audio" },
	rec = { Icon = "\7", Fg = colors.red, Name = "Recording" },
	nfp = { Icon = "\127", Fg = colors.pink, Name = "Paint image" },
	bimg = { Icon = "\127", Fg = colors.magenta, Name = "Brocreate picture" },
	json = { Icon = "\7", Fg = colors.orange, Name = "JSON" },
	cfg = { Icon = "\7", Fg = colors.orange, Name = "Config" }
}

local function Normalize(Path)
	if (Path == AppsPath) then return Path end
	return "/" .. fs.combine(Path, "")
end

local function KindOf(Path)
	if (fs.isDir(Path)) then
		return { Icon = "\16", Fg = colors.lightBlue, Name = "Folder" }
	end
	local Extension = Path:match("%.([%w]+)$")
	return Kinds[Extension and Extension:lower() or ""] or { Icon = "\7", Fg = colors.gray, Name = "File" }
end

local function DisplayName(Path)
	if (Path == AppsPath) then return "Applications" end
	if (Path == "/") then return "Computer" end
	if (Path == "/home") then return "Home" end
	return fs.getName(Path)
end

local function UniqueName(Dir, Name)
	if (not fs.exists(fs.combine(Dir, Name))) then return Name end
	local Base, Extension = Name:match("^(.-)(%.[^%.]*)$")
	if (not Base or Base == "") then
		Base, Extension = Name, ""
	end
	local Index = 1
	while (true) do
		local Candidate = Base .. " copy" .. (Index > 1 and (" " .. Index) or "") .. Extension
		if (not fs.exists(fs.combine(Dir, Candidate))) then return Candidate end
		Index = Index + 1
	end
end

local function SidebarItems()
	local Items = {
		{ Text = "Favorites", Header = true },
		{ Text = "Home", Path = "/home", Icon = "\127", IconFg = colors.lightBlue },
		{ Text = "Documents", Path = "/home/Documents", Icon = "\7", IconFg = colors.lightBlue },
		{ Text = "Downloads", Path = "/home/Downloads", Icon = "\25", IconFg = colors.lightBlue },
		{ Text = "Music", Path = "/home/Music", Icon = "\14", IconFg = colors.lightBlue },
		{ Text = "Recordings", Path = "/home/Recordings", Icon = "\7", IconFg = colors.red },
		{ Text = "Pictures", Path = "/home/Pictures", Icon = "\127", IconFg = colors.magenta },
		{ Text = "Locations", Header = true },
		{ Text = "Apps", Path = AppsPath, Icon = "\4", IconFg = colors.purple },
		{ Text = "Computer", Path = "/", Icon = "\8", IconFg = colors.gray }
	}
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "drive" and disk.hasData(Side)) then
			local Mount = disk.getMountPath(Side)
			table.insert(Items, { Text = disk.getLabel(Side) or Mount, Path = "/" .. Mount, Icon = "\22", IconFg = colors.gray, Side = Side })
		end
	end
	return Items
end

local Refresh

local function Navigate(Path, SkipHistory)
	Path = Normalize(Path)
	if (Path ~= AppsPath and not fs.isDir(Path)) then
		BlockOS.Open(Path)
		return
	end
	if (not SkipHistory and Path ~= Current) then
		table.insert(Back, Current)
		Forward = {}
	end
	Current = Path
	Refresh()
end

local function OpenItem(Item)
	if (not Item) then return end
	if (Item.App) then
		BlockOS.Launch(Item.App.ID)
	elseif (Item.IsDir) then
		Navigate(Item.Path)
	else
		BlockOS.Open(Item.Path)
	end
end

function Refresh()
	local Items = {}
	if (Current == AppsPath) then
		for _, App in ipairs(Apps.List()) do
			table.insert(Items, {
				Text = App.Name,
				Icon = Gfx.Pad(App.Icon.Lines[1], 3),
				IconFg = App.Icon.Bg,
				Right = App.System and "System" or "Installed",
				App = App
			})
		end
	else
		if (not fs.isDir(Current)) then Current = "/" end
		local Names = fs.list(Current)
		table.sort(Names, function(A, B) return A:lower() < B:lower() end)
		local Dirs, Plain = {}, {}
		for _, Name in ipairs(Names) do
			local Path = fs.combine(Current, Name)
			local Kind = KindOf(Path)
			local Entry = { Text = Name, Icon = Kind.Icon, IconFg = Kind.Fg, Path = "/" .. Path, IsDir = fs.isDir(Path) }
			if (Entry.IsDir) then
				Entry.Right = "--"
				table.insert(Dirs, Entry)
			else
				Entry.Right = Gfx.FormatSize(fs.getSize(Path))
				table.insert(Plain, Entry)
			end
		end
		for _, Entry in ipairs(Dirs) do table.insert(Items, Entry) end
		for _, Entry in ipairs(Plain) do table.insert(Items, Entry) end
	end
	Files:SetItems(Items)
	local SideItems = SidebarItems()
	Sidebar:SetItems(SideItems, true)
	Sidebar.Selected = 0
	for Index, Item in ipairs(SideItems) do
		if (Item.Path == Current) then Sidebar.Selected = Index end
	end
	PathLabel.Text = DisplayName(Current)
	if (Current == AppsPath) then
		Status.Text = #Items .. " apps"
	else
		Status.Text = #Items .. " items, " .. Gfx.FormatSize(fs.getFreeSpace(Current)) .. " free" .. (fs.isReadOnly(Current) and ", read-only" or "")
	end
	BlockOS.SetTitle(DisplayName(Current))
	Page:Invalidate()
end

local function Paste(Dir)
	local Clip = BlockOS.Clipboard
	if (not Clip.Path or not fs.exists(Clip.Path) or Dir == AppsPath) then return end
	local Target = fs.combine(Dir, UniqueName(Dir, fs.getName(Clip.Path)))
	local Ok, Err = pcall(function()
		if (Clip.Cut) then
			fs.move(Clip.Path, Target)
			Apps.MoveShortcuts(Clip.Path, Target)
		else
			fs.copy(Clip.Path, Target)
		end
	end)
	if (not Ok) then
		Ui.Alert("Paste failed", tostring(Err))
	end
	if (Clip.Cut) then BlockOS.Clipboard = {} end
	Refresh()
end

local function NewItem(Folder)
	if (Current == AppsPath or fs.isReadOnly(Current)) then return end
	local Name = Ui.Prompt(Folder and "New Folder" or "New File", "Name:", Folder and "untitled folder" or "untitled.txt")
	if (not Name or #Name == 0) then return end
	local Path = fs.combine(Current, UniqueName(Current, Name))
	if (Folder) then
		fs.makeDir(Path)
	else
		local Handle = fs.open(Path, "w")
		if (Handle) then Handle.close() end
	end
	Refresh()
end

local function DeleteItem(Item)
	if (not Item or not Item.Path or fs.isReadOnly(Item.Path)) then return end
	if (Ui.Confirm("Delete", "Delete \"" .. fs.getName(Item.Path) .. "\"? This cannot be undone.", "Delete")) then
		local Ok, Err = pcall(fs.delete, Item.Path)
		if (Ok) then
			Apps.MoveShortcuts(Item.Path, nil)
		else
			Ui.Alert("Delete failed", tostring(Err))
		end
		Refresh()
	end
end

local function GetInfo(Item)
	if (Item.App) then
		local App = Item.App
		Ui.Alert(App.Name, (App.Description or "No description.") .. "\n\nID: " .. App.ID .. "\nLocation: " .. App.Dir)
		return
	end
	local Path = Item.Path
	local Lines = { "Kind: " .. KindOf(Path).Name, "Where: " .. fs.getDir(Path) }
	if (not Item.IsDir) then
		table.insert(Lines, "Size: " .. Gfx.FormatSize(fs.getSize(Path)))
	end
	if (fs.attributes) then
		local Ok, Attributes = pcall(fs.attributes, Path)
		if (Ok and Attributes.modified and Attributes.modified > 0) then
			table.insert(Lines, "Modified: " .. os.date("%Y-%m-%d %H:%M", math.floor(Attributes.modified / 1000)))
		end
	end
	table.insert(Lines, fs.isReadOnly(Path) and "Read-only" or "Writable")
	Ui.Alert(fs.getName(Path), table.concat(Lines, "\n"))
end

local function SetWallpaper(Path)
	if (not Image.Load(Path)) then
		Ui.Alert("Set as Wallpaper", fs.getName(Path) .. " is not a picture BlockOS can read.")
		return
	end
	local Settings = Config.Settings()
	Settings.Wallpaper = Wallpaper.Picture.ID
	Settings.WallpaperImage = "/" .. fs.combine(Path, "")
	Wallpaper.Invalidate()
	Config.Save("settings")
end

local function AppMenu(Item, X, Y)
	local App = Item.App
	local Pinned = Apps.IsPinned(App.ID)
	local OnDesktop = Apps.HasShortcut(Apps.AppShortcut(App.ID))
	local Options = { "Open", "Open Full Screen", "-", Pinned and "Remove from Dock" or "Keep in Dock", OnDesktop and "Remove from Desktop" or "Add to Desktop", "Add to Login Items", "Get Info" }
	if (not App.System) then
		table.insert(Options, "-")
		table.insert(Options, "Uninstall")
	end
	local Choice = Options[Ui.ContextMenu(X, Y, Options) or 0]
	if (Choice == "Open") then
		BlockOS.Launch(App.ID)
	elseif (Choice == "Open Full Screen") then
		BlockOS.Launch(App.ID, {}, { Mode = "fullscreen" })
	elseif (Choice == "Keep in Dock" or Choice == "Remove from Dock") then
		Apps.SetPinned(App.ID, not Pinned)
	elseif (Choice == "Add to Desktop" or Choice == "Remove from Desktop") then
		Apps.SetShortcut(Apps.AppShortcut(App.ID), not OnDesktop)
	elseif (Choice == "Add to Login Items") then
		local Settings = Config.Settings()
		table.insert(Settings.StartupApps, App.ID)
		Config.Save("settings")
	elseif (Choice == "Get Info") then
		GetInfo(Item)
	elseif (Choice == "Uninstall") then
		if (Ui.Confirm("Uninstall", "Remove " .. App.Name .. " from this computer?", "Uninstall")) then
			Apps.Uninstall(App.ID)
			Refresh()
		end
	end
end

local function FileMenu(Item, X, Y)
	local ReadOnly = Current == AppsPath or fs.isReadOnly(Current)
	local HasClip = BlockOS.Clipboard.Path ~= nil
	if (not Item) then
		local Options = {
			{ Text = "New Folder", Disabled = ReadOnly },
			{ Text = "New File", Disabled = ReadOnly },
			{ Text = "Paste", Disabled = ReadOnly or not HasClip },
			"-",
			{ Text = "Open in Terminal" },
			{ Text = "Refresh" }
		}
		local Index = Ui.ContextMenu(X, Y, Options)
		local Choice = Index and Options[Index].Text
		if (Choice == "New Folder") then
			NewItem(true)
		elseif (Choice == "New File") then
			NewItem(false)
		elseif (Choice == "Paste") then
			Paste(Current)
		elseif (Choice == "Open in Terminal") then
			BlockOS.Launch("terminal", { Current })
		elseif (Choice == "Refresh") then
			Refresh()
		end
		return
	end
	if (Item.App) then
		AppMenu(Item, X, Y)
		return
	end
	local Locked = fs.isReadOnly(Item.Path)
	local OnDesktop = Apps.HasShortcut(Item.Path)
	local Options = {
		{ Text = "Open" },
		{ Text = "Edit", Disabled = Item.IsDir },
		{ Text = "Run", Disabled = Item.IsDir },
		"-",
		{ Text = "Rename", Disabled = Locked },
		{ Text = "Duplicate", Disabled = ReadOnly },
		{ Text = "Copy" },
		{ Text = "Cut", Disabled = Locked },
		{ Text = "Paste", Disabled = ReadOnly or not HasClip },
		"-",
		{ Text = OnDesktop and "Remove from Desktop" or "Add to Desktop" },
		{ Text = "Get Info" },
		{ Text = "Delete", Disabled = Locked }
	}
	local Extension = (fs.getName(Item.Path):match("%.(%w+)$") or ""):lower()
	if (not Item.IsDir and Printable[Extension]) then
		table.insert(Options, 4, { Text = "Print" })
	end
	if (not Item.IsDir and Image.IsImage(Item.Path)) then
		table.insert(Options, 4, { Text = "Set as Wallpaper" })
	end
	local Index = Ui.ContextMenu(X, Y, Options)
	local Choice = Index and Options[Index].Text
	if (Choice == "Open") then
		OpenItem(Item)
	elseif (Choice == "Edit") then
		BlockOS.Launch("editor", { Item.Path })
	elseif (Choice == "Run") then
		BlockOS.Launch(Item.Path, {}, { Hold = true })
	elseif (Choice == "Print") then
		BlockOS.Launch("print", { Item.Path })
	elseif (Choice == "Set as Wallpaper") then
		SetWallpaper(Item.Path)
	elseif (Choice == "Add to Desktop" or Choice == "Remove from Desktop") then
		Apps.SetShortcut(Item.Path, not OnDesktop)
	elseif (Choice == "Rename") then
		local Name = Ui.Prompt("Rename", "New name:", fs.getName(Item.Path))
		if (Name and #Name > 0 and Name ~= fs.getName(Item.Path)) then
			local Target = fs.combine(fs.getDir(Item.Path), Name)
			if (fs.exists(Target)) then
				Ui.Alert("Rename", "An item with that name already exists.")
			else
				fs.move(Item.Path, Target)
				Apps.MoveShortcuts(Item.Path, Target)
			end
		end
		Refresh()
	elseif (Choice == "Duplicate") then
		fs.copy(Item.Path, fs.combine(Current, UniqueName(Current, fs.getName(Item.Path))))
		Refresh()
	elseif (Choice == "Copy" or Choice == "Cut") then
		BlockOS.Clipboard = { Path = Item.Path, Cut = Choice == "Cut" }
	elseif (Choice == "Paste") then
		Paste(Item.IsDir and Item.Path or Current)
	elseif (Choice == "Get Info") then
		GetInfo(Item)
	elseif (Choice == "Delete") then
		DeleteItem(Item)
	end
end

local function GoUp()
	if (Current == AppsPath or Current == "/") then return end
	Navigate("/" .. fs.getDir(Current))
end

function Page:OnLayout(W, H)
	self:Clear()
	local SideW = (W >= 34) and 12 or 0
	self:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
	self:Add(Ui.Button.new({ X = 1, Y = 1, W = 3, Text = "\17", Bg = "Panel", OnClick = function()
		if (#Back > 0) then
			table.insert(Forward, Current)
			Current = table.remove(Back)
			Refresh()
		end
	end }))
	self:Add(Ui.Button.new({ X = 4, Y = 1, W = 3, Text = "\16", Bg = "Panel", OnClick = function()
		if (#Forward > 0) then
			table.insert(Back, Current)
			Current = table.remove(Forward)
			Refresh()
		end
	end }))
	self:Add(Ui.Button.new({ X = 7, Y = 1, W = 3, Text = "\24", Bg = "Panel", OnClick = GoUp }))
	PathLabel = self:Add(Ui.Label.new({ X = 11, Y = 1, W = W - 18, Text = "", Bg = "Panel", Fg = "PanelFg" }))
	self:Add(Ui.Button.new({ X = W - 6, Y = 1, W = 3, Text = "+", Bg = "Panel", OnClick = function() NewItem(true) end }))
	self:Add(Ui.Button.new({ X = W - 3, Y = 1, W = 3, Text = "\15", Bg = "Panel", OnClick = function() FileMenu(nil, W - 3, 2) end }))
	Sidebar = self:Add(Ui.List.new({ X = 1, Y = 2, W = SideW, H = H - 2, Bg = "Panel", Focusable = false, SingleClick = true, Visible = SideW > 0 }))
	Sidebar.RenderItem = function(_, T, Th, Item, X, Y, Width, Selected, RowBg, RowFg)
		if (Item.Header) then
			Gfx.Write(T, X, Y, Gfx.Pad(Item.Text, Width), Th.SubText, Th.Panel)
			return
		end
		Gfx.Write(T, X, Y, " " .. (Item.Icon or " ") .. " " .. Gfx.Truncate(Item.Text, Width - 4), Selected and RowFg or Th.PanelFg, RowBg)
		if (not Selected) then
			Gfx.Write(T, X + 1, Y, Item.Icon or " ", Item.IconFg or Th.PanelFg, RowBg)
		end
	end
	Sidebar.OnActivate = function(_, _, Item)
		if (Item.Header) then return end
		Navigate(Item.Path)
	end
	Sidebar.OnContext = function(_, _, Item, X, Y)
		if (Item and Item.Side) then
			local Choice = Ui.ContextMenu(X, Y, { "Open", "Eject" })
			if (Choice == 1) then
				Navigate(Item.Path)
			elseif (Choice == 2) then
				disk.eject(Item.Side)
			end
		end
	end
	Files = self:Add(Ui.List.new({ X = SideW + 1, Y = 2, W = W - SideW, H = H - 2 }))
	Files.OnActivate = function(_, _, Item) OpenItem(Item) end
	Files.OnContext = function(_, _, Item, X, Y) FileMenu(Item, X, Y) end
	Status = self:Add(Ui.Label.new({ X = 1, Y = H, W = W, Text = "", Bg = "Panel", Fg = "SubText", Align = "center" }))
	self:SetFocus(Files)
	Refresh()
end

function Page:OnEvent(Name, A)
	if (Name == "key") then
		if (A == keys.backspace) then
			GoUp()
			return true
		elseif (A == keys.delete) then
			DeleteItem(Files.Items[Files.Selected])
			return true
		end
	elseif (Name == "disk" or Name == "disk_eject" or Name == "blockos_apps" or Name == "peripheral" or Name == "peripheral_detach") then
		Refresh()
		return true
	elseif (Name == "blockos_open") then
		Navigate(A)
		return true
	end
	return false
end

Current = Normalize(Current)
Page:Run()
