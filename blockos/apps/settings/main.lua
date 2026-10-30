-- Settings: appearance, dock, users, notifications, network, login items and software update.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")
local Config = BlockOS.Require("config")
local Apps = BlockOS.Require("apps")
local Users = BlockOS.Require("users")
local Wallpaper = BlockOS.Require("wallpaper")
local Updater = BlockOS.Require("updater")

local Args = { ... }

local Settings = Config.Settings()
local Page = Ui.Page.new()
local Build

local Sections = {
	{ ID = "general", Name = "General", Icon = "\15" },
	{ ID = "appearance", Name = "Appearance", Icon = "\4" },
	{ ID = "dock", Name = "Dock", Icon = "\22" },
	{ ID = "users", Name = "Users & Login", Icon = "\2" },
	{ ID = "notifications", Name = "Notifications", Icon = "\7" },
	{ ID = "network", Name = "Network", Icon = "\29" },
	{ ID = "startup", Name = "Login Items", Icon = "\16" },
	{ ID = "update", Name = "Software Update", Icon = "\24" }
}

local Current = 1
for Index, Section in ipairs(Sections) do
	if (Section.ID == Args[1]) then Current = Index end
end

local UpdateProgress = nil
local UpdateMessage = nil

local function Save()
	Config.Save("settings")
end

local function Row(Y, Label, Content)
	Page:Add(Ui.Label.new({ X = Page.ContentX, Y = Y, Text = Label }))
	return Content
end

local function Swatches(X, Y, Choices, Get, Set)
	return Page:Add(Ui.Canvas.new({
		X = X, Y = Y, W = #Choices * 2, H = 1,
		OnDraw = function(Self, T)
			for Index, Color in ipairs(Choices) do
				local Mark = (Color == Get()) and "\7" or " "
				Gfx.Write(T, Self.X + (Index - 1) * 2, Self.Y, Mark .. " ", (Color == colors.white) and colors.black or colors.white, Color)
			end
		end,
		OnEvent = function(Self, Name, _, MouseX)
			if (Name ~= "mouse_click") then return false end
			local Color = Choices[math.floor((MouseX - Self.X) / 2) + 1]
			if (Color) then Set(Color) end
			return true
		end
	}))
end

local function ToggleRow(Y, Label, Key, After)
	local X = Page.ContentX
	Page:Add(Ui.Toggle.new({
		X = X, Y = Y, Value = Settings[Key],
		OnChange = function(_, Value)
			Settings[Key] = Value
			Save()
			if (After) then After(Value) end
		end
	}))
	Page:Add(Ui.Label.new({ X = X + 5, Y = Y, W = Page.ContentW - 5, Text = Label }))
end

local Builders = {}

function Builders.general(X, Y, W)
	local Label = Page:Add(Ui.Input.new({ X = X + 11, Y = Y, W = math.min(20, W - 18), Value = os.getComputerLabel() or "" }))
	Row(Y, "Name", Label)
	Page:Add(Ui.Button.new({ X = X + W - 6, Y = Y, W = 6, Text = "Set", OnClick = function()
		os.setComputerLabel(#Label.Value > 0 and Label.Value or nil)
		BlockOS.Notify("Settings", "Computer name updated.", { Sound = false })
	end }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 2, Text = "Clock" }))
	Page:Add(Ui.Tabs.new({
		X = X + 11, Y = Y + 2, W = math.min(22, W - 11), Items = { "Real time", "Minecraft" }, Selected = Settings.ClockSource == "game" and 2 or 1,
		OnChange = function(_, Index)
			Settings.ClockSource = (Index == 2) and "game" or "real"
			Save()
		end
	}))
	ToggleRow(Y + 4, "24-hour time", "Clock24")
	ToggleRow(Y + 6, "Show seconds", "ShowSeconds")
	local Free = fs.getFreeSpace("/")
	local Capacity = fs.getCapacity and fs.getCapacity("/") or nil
	Page:Add(Ui.Label.new({ X = X, Y = Y + 8, W = W, Fg = "SubText", Text = "Computer #" .. os.getComputerID() .. " \7 " .. (_HOST or os.version()) }))
	if (Capacity) then
		Page:Add(Ui.Label.new({ X = X, Y = Y + 9, Text = "Storage", Fg = "SubText" }))
		Page:Add(Ui.Progress.new({ X = X + 9, Y = Y + 9, W = W - 9, Value = 1 - Free / Capacity }))
		Page:Add(Ui.Label.new({ X = X, Y = Y + 10, W = W, Fg = "SubText", Text = Gfx.FormatSize(Free) .. " free of " .. Gfx.FormatSize(Capacity) }))
	end
end

function Builders.appearance(X, Y, W, H)
	Page:Add(Ui.Label.new({ X = X, Y = Y, Text = "Mode" }))
	Page:Add(Ui.Tabs.new({
		X = X + 11, Y = Y, W = math.min(16, W - 11), Items = { "Light", "Dark" }, Selected = Settings.Theme == "dark" and 2 or 1,
		OnChange = function(_, Index)
			Settings.Theme = (Index == 2) and "dark" or "light"
			Save()
		end
	}))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 2, Text = "Accent" }))
	Swatches(X + 11, Y + 2, Theme.Accents, function() return Settings.Accent end, function(Color)
		Settings.Accent = Color
		Save()
	end)
	Page:Add(Ui.Label.new({ X = X, Y = Y + 4, Text = "Wallpaper" }))
	local Items = {}
	local Selected = 1
	for Index, Entry in ipairs(Wallpaper.List) do
		table.insert(Items, { Text = Entry.Name, ID = Entry.ID })
		if (Entry.ID == Settings.Wallpaper) then Selected = Index end
	end
	local ListW = math.min(14, W - 2)
	local List = Page:Add(Ui.List.new({ X = X, Y = Y + 5, W = ListW, H = math.min(#Items, H - 7), Items = Items, Bg = "Panel" }))
	List.Selected = Selected
	List.OnSelect = function(_, _, Item)
		Settings.Wallpaper = Item.ID
		Save()
	end
	local PreviewW = W - ListW - 1
	if (PreviewW >= 8) then
		Page:Add(Ui.Canvas.new({
			X = X + ListW + 1, Y = Y + 5, W = PreviewW, H = math.min(6, H - 8),
			OnDraw = function(Self, T)
				Wallpaper.Draw(T, Self.X, Self.Y, Self.W, Self.H, Settings.Wallpaper, Settings.WallpaperColor)
			end
		}))
		Page:Add(Ui.Label.new({ X = X + ListW + 1, Y = Y + 5 + math.min(6, H - 8), Text = "Colour", Fg = "SubText" }))
		Swatches(X + ListW + 8, Y + 5 + math.min(6, H - 8), { colors.cyan, colors.blue, colors.purple, colors.pink, colors.green, colors.orange, colors.gray, colors.black }, function()
			return Settings.WallpaperColor
		end, function(Color)
			Settings.WallpaperColor = Color
			Save()
		end)
	end
end

function Builders.dock(X, Y, W, H)
	local List = Page:Add(Ui.List.new({ X = X, Y = Y, W = W, H = H - 4, Bg = "Panel" }))
	local function Fill()
		local Items = {}
		for Index, ID in ipairs(Settings.Dock) do
			local App = Apps.Get(ID)
			if (App) then
				table.insert(Items, { Text = App.Name, Icon = Gfx.Pad(App.Icon.Lines[1], 3), IconFg = App.Icon.Bg, Index = Index })
			end
		end
		List:SetItems(Items, true)
	end
	Fill()
	local function MoveSelected(Step)
		local Item = List.Items[List.Selected]
		if (not Item) then return end
		local Target = Item.Index + Step
		if (Target < 1 or Target > #Settings.Dock) then return end
		Settings.Dock[Item.Index], Settings.Dock[Target] = Settings.Dock[Target], Settings.Dock[Item.Index]
		Save()
		Fill()
		List:Select(List.Selected + Step)
	end
	local ButtonY = Y + H - 3
	Page:Add(Ui.Button.new({ X = X, Y = ButtonY, W = 3, Text = "\24", OnClick = function() MoveSelected(-1) end }))
	Page:Add(Ui.Button.new({ X = X + 4, Y = ButtonY, W = 3, Text = "\25", OnClick = function() MoveSelected(1) end }))
	Page:Add(Ui.Button.new({ X = X + 8, Y = ButtonY, Text = " Remove ", OnClick = function()
		local Item = List.Items[List.Selected]
		if (Item) then
			table.remove(Settings.Dock, Item.Index)
			Save()
			Fill()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 18, Y = ButtonY, Text = " Add App ", Style = "primary", OnClick = function()
		local Choices, Names = {}, {}
		for _, App in ipairs(Apps.List()) do
			if (not Apps.IsPinned(App.ID)) then
				table.insert(Choices, App)
				table.insert(Names, App.Name)
			end
		end
		if (#Names == 0) then return end
		local Index = Ui.Choose("Add to Dock", Names)
		if (Index) then
			table.insert(Settings.Dock, Choices[Index].ID)
			Save()
			Fill()
		end
	end }))
end

function Builders.users(X, Y, W)
	local User = Users.Primary()
	if (not User) then return end
	Page:Add(Ui.Canvas.new({
		X = X, Y = Y, W = 3, H = 2,
		OnDraw = function(Self, T)
			Gfx.Fill(T, Self.X, Self.Y, 3, 2, User.Color or colors.blue)
			Gfx.Write(T, Self.X + 1, Self.Y, User.Name:sub(1, 1):upper(), colors.white, User.Color or colors.blue)
		end
	}))
	Page:Add(Ui.Label.new({ X = X + 4, Y = Y, W = W - 4, Text = User.Name }))
	Page:Add(Ui.Label.new({ X = X + 4, Y = Y + 1, W = W - 4, Text = "Administrator", Fg = "SubText" }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 3, Text = " Rename ", OnClick = function()
		local Name = Ui.Prompt("Rename", "New name:", User.Name)
		if (Name and #Name > 0) then
			Users.Update(User.Name, { Name = Name })
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 10, Y = Y + 3, Text = " Change Password ", OnClick = function()
		if (User.HasPassword) then
			local Old = Ui.Prompt("Change Password", "Current password:", "", "\7")
			if (not Old) then return end
			if (not Users.Verify(User.Name, Old)) then
				Ui.Alert("Change Password", "That password is incorrect.")
				return
			end
		end
		local New = Ui.Prompt("Change Password", "New password (empty for none):", "", "\7")
		if (not New) then return end
		local Again = Ui.Prompt("Change Password", "Confirm new password:", "", "\7")
		if (Again ~= New) then
			Ui.Alert("Change Password", "The passwords do not match.")
			return
		end
		Users.SetPassword(User.Name, New)
		Ui.Alert("Change Password", "Password updated.")
		Build()
	end }))
	ToggleRow(Y + 5, "Log in automatically", "AutoLogin")
	Page:Add(Ui.Label.new({ X = X, Y = Y + 7, Text = "Lock after" }))
	local Options = { 0, 1, 5, 15 }
	local Selected = 1
	for Index, Minutes in ipairs(Options) do
		if (Minutes == Settings.IdleLock) then Selected = Index end
	end
	Page:Add(Ui.Tabs.new({
		X = X + 11, Y = Y + 7, W = math.min(24, W - 11), Items = { "Never", "1m", "5m", "15m" }, Selected = Selected,
		OnChange = function(_, Index)
			Settings.IdleLock = Options[Index]
			Save()
		end
	}))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 9, Text = " Lock Screen Now ", Style = "primary", OnClick = function() BlockOS.Lock() end }))
end

function Builders.notifications(X, Y, W, H)
	ToggleRow(Y, "Show notifications", "Notifications")
	ToggleRow(Y + 2, "Play a sound on speakers", "NotificationSound")
	Page:Add(Ui.Button.new({ X = X, Y = Y + 4, Text = " Send Test ", OnClick = function()
		BlockOS.Notify("Hello from BlockOS", "Notifications are working.", { AppID = "settings", Args = { "notifications" } })
	end }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 6, Text = "Recent", Fg = "SubText" }))
	local Items = {}
	for _, Entry in ipairs(BlockOS.Notifications and BlockOS.Notifications() or {}) do
		table.insert(Items, { Text = Entry.Title .. ": " .. Entry.Text })
	end
	Page:Add(Ui.List.new({ X = X, Y = Y + 7, W = W, H = math.max(1, H - 8), Items = Items, Bg = "Panel" }))
end

function Builders.network(X, Y, W)
	local Chat = BlockOS.Require("chat")
	Chat.Load()
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Text = "Computer ID: " .. os.getComputerID() }))
	local Row = Y + 2
	local Found = false
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "modem") then
			Found = true
			local Modem = peripheral.wrap(Name)
			local Kind = Modem.isWireless() and "Wireless modem" or "Wired modem"
			local Open = rednet.isOpen(Name)
			Page:Add(Ui.Label.new({ X = X, Y = Row, W = W - 10, Text = Kind .. " (" .. Name .. ")" }))
			Page:Add(Ui.Button.new({ X = X + W - 8, Y = Row, W = 8, Text = Open and "Close" or "Open", OnClick = function()
				if (rednet.isOpen(Name)) then rednet.close(Name) else rednet.open(Name) end
				Build()
			end }))
			Row = Row + 1
		end
	end
	if (not Found) then
		Page:Add(Ui.Label.new({ X = X, Y = Row, W = W, H = 2, Text = "No modems attached. Attach a wireless or ender modem to use Messages and Turtles.", Fg = "SubText" }))
		Row = Row + 2
	end
	Row = Row + 1
	Page:Add(Ui.Label.new({ X = X, Y = Row, Text = "Nickname" }))
	local Nick = Page:Add(Ui.Input.new({ X = X + 10, Y = Row, W = math.min(18, W - 18), Value = Chat.GetNick(), MaxLength = 20 }))
	Page:Add(Ui.Button.new({ X = X + W - 6, Y = Row, W = 6, Text = "Set", OnClick = function()
		if (#Nick.Value > 0) then
			Chat.SetNick(Nick.Value)
			BlockOS.Notify("Messages", "Nickname set to " .. Nick.Value, { Sound = false })
		end
	end }))
end

function Builders.startup(X, Y, W, H)
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Text = "Open these apps when you log in:", Fg = "SubText" }))
	local List = Page:Add(Ui.List.new({ X = X, Y = Y + 1, W = W, H = H - 5, Bg = "Panel" }))
	local Items = {}
	for Index, ID in ipairs(Settings.StartupApps) do
		local App = Apps.Get(ID)
		table.insert(Items, { Text = App and App.Name or ID, Index = Index })
	end
	List:SetItems(Items)
	Page:Add(Ui.Button.new({ X = X, Y = Y + H - 3, Text = " Add ", Style = "primary", OnClick = function()
		local Choices, Names = {}, {}
		for _, App in ipairs(Apps.List()) do
			if (App.Builtin ~= "launchpad") then
				table.insert(Choices, App)
				table.insert(Names, App.Name)
			end
		end
		local Index = Ui.Choose("Add Login Item", Names)
		if (Index) then
			table.insert(Settings.StartupApps, Choices[Index].ID)
			Save()
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 7, Y = Y + H - 3, Text = " Remove ", OnClick = function()
		local Item = List.Items[List.Selected]
		if (Item) then
			table.remove(Settings.StartupApps, Item.Index)
			Save()
			Build()
		end
	end }))
end

function Builders.update(X, Y, W, H)
	local State = Updater.State
	local Lines = {
		"Installed: BlockOS " .. Config.Version()
	}
	if (State.Latest) then
		table.insert(Lines, "Latest: BlockOS " .. tostring(State.Latest.Version))
	end
	local Status = ({
		idle = "Not checked yet.",
		checking = "Checking for updates...",
		available = "An update is available.",
		uptodate = "BlockOS is up to date.",
		downloading = "Downloading update...",
		ready = "Update installed. Restart to finish.",
		error = "Error: " .. tostring(State.Error)
	})[State.Status] or ""
	table.insert(Lines, UpdateMessage or Status)
	for Index, Line in ipairs(Lines) do
		Page:Add(Ui.Label.new({ X = X, Y = Y + Index - 1, W = W, Text = Line, Fg = (Index == #Lines) and "Accent" or "Text" }))
	end
	local ButtonY = Y + #Lines + 1
	Page:Add(Ui.Button.new({ X = X, Y = ButtonY, Text = " Check Now ", OnClick = function()
		UpdateMessage = nil
		Updater.State.Status = "checking"
		Build()
		Page:Draw()
		Updater.Check()
		Build()
	end }))
	if (State.Status == "available" and State.Latest) then
		Page:Add(Ui.Button.new({ X = X + 13, Y = ButtonY, Text = " Update Now ", Style = "primary", OnClick = function()
			UpdateProgress = 0
			Build()
			local Ok, Err = Updater.Apply(State.Latest, function(Done, Total, Path)
				UpdateProgress = Total > 0 and Done / Total or 1
				UpdateMessage = "Downloading " .. Path
				Build()
				Page:Draw()
			end)
			UpdateProgress = nil
			UpdateMessage = Ok and "Update installed. Restart to finish." or ("Update failed: " .. tostring(Err))
			Build()
		end }))
	elseif (State.Status == "ready") then
		Page:Add(Ui.Button.new({ X = X + 13, Y = ButtonY, Text = " Restart ", Style = "primary", OnClick = function() os.reboot() end }))
	end
	if (UpdateProgress) then
		Page:Add(Ui.Progress.new({ X = X, Y = ButtonY + 2, W = W, Value = UpdateProgress }))
	end
	local OptionsY = ButtonY + 4
	ToggleRow(OptionsY, "Check automatically", "AutoUpdate")
	ToggleRow(OptionsY + 2, "Install in the background", "AutoInstall")
	if (OptionsY + 4 < Y + H) then
		Page:Add(Ui.Label.new({ X = X, Y = OptionsY + 4, Text = "Channel", Fg = "SubText" }))
		local Url = Page:Add(Ui.Input.new({ X = X + 8, Y = OptionsY + 4, W = W - 8, Value = Settings.UpdateURL }))
		Url.OnSubmit = function(_, Value)
			Settings.UpdateURL = Value
			Save()
			BlockOS.Notify("Software Update", "Update channel saved.", { Sound = false })
		end
	end
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local SideW = (W >= 40) and 16 or 0
	Page.ContentX = SideW + 2
	Page.ContentW = W - SideW - 3
	local Sidebar = Page:Add(Ui.List.new({ X = 1, Y = 1, W = SideW, H = H, Bg = "Panel", SingleClick = true, Visible = SideW > 0 }))
	local Items = {}
	for _, Section in ipairs(Sections) do
		table.insert(Items, { Text = Section.Name, Icon = Section.Icon, IconFg = "Accent" })
	end
	Sidebar:SetItems(Items)
	Sidebar.Selected = Current
	Sidebar.OnActivate = function(_, Index)
		Current = Index
		UpdateMessage = nil
		Build()
	end
	local Section = Sections[Current]
	if (SideW == 0) then
		Page:Add(Ui.Button.new({ X = 1, Y = 1, W = W, Text = "\31 " .. Section.Name, Bg = "Panel", OnClick = function()
			local Names = {}
			for _, Entry in ipairs(Sections) do table.insert(Names, Entry.Name) end
			local Index = Ui.Choose("Settings", Names, Current)
			if (Index) then
				Current = Index
				Build()
			end
		end }))
	else
		Page:Add(Ui.Label.new({ X = Page.ContentX, Y = 1, W = Page.ContentW, Text = Section.Name, Fg = "Accent" }))
	end
	Builders[Section.ID](Page.ContentX, 3, Page.ContentW, H - 3)
	BlockOS.SetTitle("Settings \7 " .. Section.Name)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_open" and A) then
		for Index, Section in ipairs(Sections) do
			if (Section.ID == A) then Current = Index end
		end
		Build()
		return true
	elseif (Name == "blockos_settings" or Name == "peripheral" or Name == "peripheral_detach") then
		if (Sections[Current].ID ~= "general") then Build() end
		return true
	end
	return false
end

Page:Run()
