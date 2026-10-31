-- BlockOS Server console: status at a glance, paired clients, pairing approvals, logs and
-- server settings. Administration only; the services run whether or not this is open.

local Host = ...
local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")
local Config = BlockOS.Require("config")
local Server = BlockOS.Require("server/config")
local Manager = BlockOS.Require("server/service_manager")
local Clients = BlockOS.Require("server/clients")
local Rpc = BlockOS.Require("server/rpc")
local Log = BlockOS.Require("server/log")
local Protocol = BlockOS.Require("cloud/protocol")
local Path = BlockOS.Require("cloud/path")
local Updater = BlockOS.Require("updater")
local Volumes = BlockOS.Require("server/volumes")

local Page = Ui.Page.new()
local Tabs = { "Overview", "Clients", "Pairing", "Logs", "Settings" }
local State = { Tab = 1, Section = 1, Locked = Server.HasPassword(), Message = nil, RebuildTimer = nil, Password = "" }
local Build

local Dots = { ok = colors.lime, warn = colors.orange, error = colors.red, off = colors.gray }

local Util = {}

function Util.Ago(Epoch)
	if (not Epoch) then return "never" end
	local Seconds = math.max(0, math.floor((os.epoch("utc") - Epoch) / 1000))
	if (Seconds < 60) then return "just now" end
	if (Seconds < 3600) then return math.floor(Seconds / 60) .. "m ago" end
	if (Seconds < 86400) then return math.floor(Seconds / 3600) .. "h ago" end
	return math.floor(Seconds / 86400) .. "d ago"
end

function Util.Uptime()
	local Seconds = math.floor(os.clock())
	local Hours = math.floor(Seconds / 3600)
	local Minutes = math.floor(Seconds / 60) % 60
	return Hours > 0 and (Hours .. "h " .. Minutes .. "m") or (Minutes .. "m")
end

function Util.Drive()
	local Service = Manager.Get("blockdrive")
	return Service and Service.Module
end

function Util.Core()
	local Service = Manager.Get("core")
	return Service and Service.Module
end

function Util.Updates()
	local Service = Manager.Get("updater")
	return Service and Service.Module
end

function Util.Say(Text)
	State.Message = Text
	Page:Invalidate()
end

-- Several status events often arrive together; rebuild once, shortly after.
function Util.Soon()
	if (not State.RebuildTimer) then State.RebuildTimer = os.startTimer(.5) end
end

-- One line of label + coloured dot + text, for the overview.
function Util.Line(Y, Label, Level, Text, X, W)
	Page:Add(Ui.Canvas.new({
		X = X, Y = Y, W = W, H = 1,
		OnDraw = function(Self, T, Th)
			Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(Label, 10), Th.SubText, Th.WindowBg)
			local TextX = Self.X + 10
			if (Level) then
				Gfx.Write(T, TextX, Self.Y, "\7", Dots[Level] or Th.SubText, Th.WindowBg)
				TextX = TextX + 2
			end
			Gfx.Write(T, TextX, Self.Y, Gfx.Truncate(Text, Self.W - (TextX - Self.X)), Th.Text, Th.WindowBg)
		end
	}))
end

local Tab = {}

function Tab.Overview(X, Y, W, H)
	local Settings = Server.Settings()
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Fg = "Accent", Text = Settings.Hostname .. "  \7  " .. Settings.DisplayName }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 1, W = W, Fg = "SubText",
		Text = "BlockOS Server " .. Server.Version() .. "  \7  Computer #" .. os.getComputerID() .. "  \7  up " .. Util.Uptime() }))
	local Row = Y + 3
	local Modems = Protocol.Modems()
	local Sides = {}
	for _, Modem in ipairs(Modems) do
		table.insert(Sides, Modem.Side .. (Modem.Wireless and " wireless" or " wired") .. (Modem.Open and "" or " closed"))
	end
	Util.Line(Row, "Network", #Modems > 0 and "ok" or "error", #Modems > 0 and table.concat(Sides, ", ") or "No modem attached!", X, W)
	Row = Row + 1
	for Index, Status in ipairs(Manager.Status()) do
		Util.Line(Row, Index == 1 and "Services" or "", Status.Level, Gfx.Pad(Status.Title, 17) .. (Status.State ~= "running" and Status.State or (Status.Detail or "")), X, W)
		Row = Row + 1
	end
	local Drive = Util.Drive()
	Row = Row + 1
	if (Drive and Drive.Root) then
		local Root = Drive.Root()
		local Usage = Drive.Usage()
		-- The pool: the main storage folder and every pooled disk together.
		local Free, Capacity, Pooled = Drive.PoolSpace()
		local Counts = Volumes.Summary()
		Page:Add(Ui.Label.new({ X = X, Y = Row, Text = "Storage", Fg = "SubText" }))
		if (Capacity and Capacity > 0) then
			Page:Add(Ui.Progress.new({ X = X + 10, Y = Row, W = math.max(4, W - 30), Value = 1 - Free / Capacity }))
			Page:Add(Ui.Label.new({ X = X + W - 19, Y = Row, W = 19, Align = "right", Text = Gfx.FormatSize(Free) .. " free" }))
		else
			Page:Add(Ui.Label.new({ X = X + 10, Y = Row, W = W - 10, Text = Gfx.FormatSize(Free) .. " free" }))
		end
		Page:Add(Ui.Label.new({ X = X + 10, Y = Row + 1, W = W - 10, Fg = "SubText",
			Text = Root .. (Pooled > 0 and (" + " .. Pooled .. " disk" .. (Pooled == 1 and "" or "s")) or "") .. "  \7  " .. Usage.Files .. " files, " .. Gfx.FormatSize(Usage.Bytes) }))
		if (Counts.share + Counts.off > 0) then
			Page:Add(Ui.Label.new({ X = X + 10, Y = Row + 2, W = W - 10, Fg = "SubText",
				Text = Counts.share .. " disk" .. (Counts.share == 1 and "" or "s") .. " shared on their own, " .. Counts.off .. " unused" }))
			Row = Row + 1
		end
		Row = Row + 3
	end
	local List = Clients.List()
	local Recent = 0
	for _, Client in ipairs(List) do
		if (Client.LastSeen and os.epoch("utc") - Client.LastSeen < 600000) then Recent = Recent + 1 end
	end
	local Pending = #Clients.PendingList()
	local Visitors = 0
	for _, Seen in pairs(Rpc.Visitors) do
		if (os.epoch("utc") - Seen < 600000) then Visitors = Visitors + 1 end
	end
	Util.Line(Row, "Access", nil, Util.AccessText(), X, W)
	Util.Line(Row + 1, "Clients", Pending > 0 and "warn" or nil,
		#List .. " paired, " .. Recent .. " active" .. (Server.Settings().Public ~= false and (", " .. Visitors .. " visitors") or "")
		.. (Pending > 0 and (", " .. Pending .. " waiting to pair") or ""), X, W)
	Util.Line(Row + 2, "Requests", nil, Rpc.Stats.Requests .. " handled, " .. Rpc.Stats.Rejected .. " rejected, " .. Rpc.Stats.Errors .. " errors", X, W)
end

function Tab.Clients(X, Y, W, H)
	local Items = {}
	for _, Client in ipairs(Clients.List()) do
		table.insert(Items, {
			Text = Client.Name .. " (#" .. Client.ComputerID .. ")",
			Right = (Client.Permission == "write" and "read/write" or "read only") .. "  " .. Util.Ago(Client.LastSeen),
			Icon = "\2", IconFg = Client.Permission == "write" and "Accent" or "SubText",
			Client = Client
		})
	end
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, H = 4, Fg = "SubText",
			Text = "No computers are paired yet. On a BlockOS computer, open BlockDrive and choose Add Server; the request appears under Pairing." }))
		return
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y, W = W, H = H - 2, Items = Items, Bg = "Panel" }))
	List.Selected = 1
	local function Selected()
		local Item = List.Items[List.Selected]
		return Item and Item.Client
	end
	Page:Add(Ui.Button.new({ X = X, Y = Y + H - 1, Text = " Permission ", OnClick = function()
		local Client = Selected()
		if (not Client) then return end
		local Choice = Ui.Alert("Permission", "What may " .. Client.Name .. " do?", { "Cancel", "Read only", "Read & write" })
		if (Choice == 2 or Choice == 3) then
			Clients.SetPermission(Client.ID, Choice == 2 and "read" or "write")
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 13, Y = Y + H - 1, Text = " Rename ", OnClick = function()
		local Client = Selected()
		local Name = Client and Ui.Prompt("Rename", "Name for computer #" .. Client.ComputerID .. ":", Client.Name)
		if (Name and #Name > 0) then
			Clients.Rename(Client.ID, Name)
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 22, Y = Y + H - 1, Text = " Remove ", Style = "danger", OnClick = function()
		local Client = Selected()
		if (Client and Ui.Confirm("Remove", "Unpair " .. Client.Name .. "? It will have to pair again to use BlockDrive.", "Remove")) then
			Clients.Revoke(Client.ID)
			Build()
		end
	end }))
end

-- Public: any computer may use BlockDrive with the visitor permission. Private: pairing needed.
function Util.AccessText()
	local Settings = Server.Settings()
	if (Settings.Public == false) then return "Private: computers must pair" end
	return "Public: anyone may " .. (Settings.Visitors == "read" and "read" or "read and write") .. ", no pairing"
end

function Tab.Pairing(X, Y, W, H)
	local Settings = Server.Settings()
	Page:Add(Ui.Label.new({ X = X, Y = Y + 1, W = W, Fg = "Accent", Text = Util.AccessText() .. (Settings.Public ~= false and " (optional)" or "") }))
	Y, H = Y + 1, H - 1
	Page:Add(Ui.Toggle.new({ X = X, Y = Y, Value = Settings.PairingOpen ~= false, OnChange = function(_, Value)
		Settings.PairingOpen = Value
		Server.Save()
		Log.Info("auth", Value and "Pairing requests allowed" or "Pairing requests turned off")
	end }))
	Page:Add(Ui.Label.new({ X = X + 5, Y = Y, W = W - 5, Text = "Accept new pairing requests" }))
	local Items = {}
	for _, Request in ipairs(Clients.PendingList()) do
		table.insert(Items, { Text = Request.Name .. " (#" .. Request.ComputerID .. ")", Right = Util.Ago(Request.Created), Icon = "?", IconFg = "Accent", Request = Request })
	end
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = X, Y = Y + 2, W = W, H = 5, Fg = "SubText",
			Text = "No computers are waiting. When one asks to pair, it shows an 8-character code: approve the request here and type that code to confirm it is the right computer."
				.. (Settings.Public ~= false and " On a public server, pairing gives a computer its own permission and encrypted transfers." or "") }))
		return
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y + 2, W = W, H = H - 4, Items = Items, Bg = "Panel" }))
	List.Selected = 1
	local function Approve()
		local Item = List.Items[List.Selected]
		if (not Item) then return end
		local Request = Item.Request
		local Code = Ui.Prompt("Approve " .. Request.Name, "Type the code shown on computer #" .. Request.ComputerID .. ":", "")
		if (not Code or Code == "") then return end
		local Choice = Ui.Alert("Permission", "What may " .. Request.Name .. " do?", { "Cancel", "Read only", "Read & write" })
		if (Choice ~= 2 and Choice ~= 3) then return end
		local Client, Err = Util.Core().Approve(Request.ID, Code, Choice == 2 and "read" or "write")
		if (Client) then
			Util.Say("Paired " .. Client.Name .. ".")
		else
			Ui.Alert("Not approved", Err or "Unknown error")
		end
		Build()
	end
	List.OnActivate = Approve
	Page:Add(Ui.Button.new({ X = X, Y = Y + H - 1, Text = " Approve... ", Style = "primary", OnClick = Approve }))
	Page:Add(Ui.Button.new({ X = X + 13, Y = Y + H - 1, Text = " Decline ", OnClick = function()
		local Item = List.Items[List.Selected]
		if (Item) then
			Util.Core().Deny(Item.Request.ID)
			Build()
		end
	end }))
end

function Tab.Logs(X, Y, W, H)
	local Colours = { debug = "SubText", info = "Text", warn = colors.orange, error = colors.red }
	local Items = {}
	for _, Entry in ipairs(Log.Lines) do
		table.insert(Items, { Text = Entry.Time:sub(12) .. " " .. Entry.Source .. ": " .. Entry.Text, Fg = Colours[Entry.Level] })
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y, W = W, H = H, Items = Items, Bg = "Panel" }))
	List.Scroll = math.max(0, #Items - H)
	List.OnActivate = function(_, _, Item) Ui.Alert("Log", Item.Text) end
end

--
-- Settings
--

local Sections = { "General", "Storage", "Disks", "Security", "Updates", "Services", "Appearance" }
local Section = {}

-- A labelled input with a Set button; Apply returns an error message or nil.
function Util.Field(X, Y, W, Label, Value, Apply, Mask)
	Page:Add(Ui.Label.new({ X = X, Y = Y, Text = Label }))
	local Field = Page:Add(Ui.Input.new({ X = X + 11, Y = Y, W = W - 18, Value = tostring(Value or ""), Mask = Mask }))
	local function Submit()
		local Err = Apply(Field.Value)
		if (Err) then Ui.Alert(Label, Err) else Util.Say(Label .. " saved.") end
		Build()
	end
	Field.OnSubmit = Submit
	Page:Add(Ui.Button.new({ X = X + W - 6, Y = Y, W = 6, Text = "Set", OnClick = Submit }))
	return Field
end

function Util.Switch(X, Y, W, Label, Key, After)
	local Settings = Server.Settings()
	Page:Add(Ui.Toggle.new({ X = X, Y = Y, Value = Settings[Key] ~= false, OnChange = function(_, Value)
		Settings[Key] = Value
		Server.Save()
		if (After) then After(Value) end
	end }))
	Page:Add(Ui.Label.new({ X = X + 5, Y = Y, W = W - 5, Text = Label }))
end

function Section.General(X, Y, W)
	local Settings = Server.Settings()
	Util.Field(X, Y, W, "Hostname", Settings.Hostname, function(Value)
		if (not Server.ValidHostname(Value)) then return "Use 1-24 letters, digits, - or _." end
		Settings.Hostname = Value
		os.setComputerLabel(Value)
		Server.Save()
		Util.Core().Announce()
	end)
	Util.Field(X, Y + 2, W, "Name", Settings.DisplayName, function(Value)
		if (#Value == 0 or #Value > 32) then return "Use 1-32 characters." end
		Settings.DisplayName = Value
		Server.Save()
	end)
	Page:Add(Ui.Label.new({ X = X, Y = Y + 4, W = W, H = 2, Fg = "SubText", Text = "Clients see the name in BlockDrive: BlockDrive > " .. Settings.DisplayName .. " > Shared." }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 7, Text = " Restart Server ", OnClick = function()
		if (Ui.Confirm("Restart", "Restart this computer? Clients reconnect automatically.", "Restart")) then os.reboot() end
	end }))
	Page:Add(Ui.Button.new({ X = X + 17, Y = Y + 7, Text = " Shut Down ", Style = "danger", OnClick = function()
		if (Ui.Confirm("Shut Down", "Shut down? BlockDrive will be unavailable until the computer is turned on again.", "Shut Down")) then os.shutdown() end
	end }))
end

function Section.Storage(X, Y, W)
	local Settings = Server.Settings()
	Util.Field(X, Y, W, "Location", Settings.StorageRoot, function(Value)
		local Ok, Err = Path.ValidRoot(Value)
		if (not Ok) then return Err end
		if (not Ui.Confirm("Storage location", "Serve files from /" .. fs.combine(Value, "") .. "? Existing files are not moved.", "Change")) then return nil end
		Settings.StorageRoot = "/" .. fs.combine(Value, "")
		Server.Save()
		Manager.Restart("blockdrive")
	end)
	Util.Field(X, Y + 2, W, "Quota MB", Settings.QuotaMB, function(Value)
		local Number = tonumber(Value)
		if (not Number or Number < 0) then return "Enter a number of megabytes, or 0 for no quota." end
		Settings.QuotaMB = Number
		Server.Save()
	end)
	Util.Field(X, Y + 4, W, "Max file KB", Settings.MaxFileKB, function(Value)
		local Number = tonumber(Value)
		if (not Number or Number < 0) then return "Enter a size in KB, or 0 for no limit." end
		Settings.MaxFileKB = Number
		Server.Save()
	end)
	Page:Add(Ui.Label.new({ X = X, Y = Y + 6, W = W, H = 2, Fg = "SubText", Text = "Shares are the top-level folders. Make new shares in Finder." }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 8, Text = " Open in Finder ", Style = "primary", OnClick = function()
		local Drive = Util.Drive()
		Host.Launch("finder", { Drive and Drive.Root() or Settings.StorageRoot })
	end }))
end

local ModeNames = { pool = "pooled", share = "own share", off = "unused" }

-- Disk drives, attached directly or over wired modems: pooled, shared on their own, or unused.
function Section.Disks(X, Y, W, H)
	local Settings = Server.Settings()
	Volumes.Refresh()
	Util.Switch(X, Y, W, "Use disk drives", "ShareDisks", function()
		Volumes.Refresh()
		os.queueEvent("blockcloud_storage")
		Build()
	end)
	Page:Add(Ui.Label.new({ X = X, Y = Y + 1, Text = "New disks" }))
	local Modes = { "pool", "share", "off" }
	local Selected = 1
	for Index, Mode in ipairs(Modes) do
		if (Mode == (Settings.DiskMode or "pool")) then Selected = Index end
	end
	Page:Add(Ui.Tabs.new({ X = X + 10, Y = Y + 1, W = math.min(27, W - 10), Items = { "Pool", "Own share", "Unused" }, Selected = Selected,
		OnChange = function(_, Index)
			Settings.DiskMode = Modes[Index]
			Server.Save()
			Volumes.Refresh()
			os.queueEvent("blockcloud_storage")
		end }))
	local Drive = Util.Drive()
	local Items = {}
	for _, Volume in ipairs(Volumes.List()) do
		local Free = Volume.Mode ~= "off" and Drive and Drive.FreeSpace(Volume.Root)
		table.insert(Items, {
			Text = Volume.Name, Volume = Volume, Icon = "\22",
			IconFg = Volume.Mode == "pool" and "Accent" or (Volume.Mode == "share" and colors.cyan or "SubText"),
			Right = ModeNames[Volume.Mode] .. (Free and ("  " .. Gfx.FormatSize(Free)) or "")
		})
	end
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = X, Y = Y + 3, W = W, H = 5, Fg = "SubText",
			Text = "No disk drives with a disk. Attach disk drives directly or over wired modems; each disk adds its space to the pool, or becomes its own share." }))
		return
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y + 3, W = W, H = math.max(2, H - 7), Items = Items, Bg = "Panel" }))
	List.Selected = 1
	Page:Add(Ui.Label.new({ X = X, Y = Y + H - 3, W = W, Fg = "SubText", Text = function()
		local Item = List.Items[List.Selected]
		local Volume = Item and Item.Volume
		if (not Volume) then return "" end
		return Volume.Side .. "  " .. Volume.Mount .. (Volume.ID and ("  id " .. Volume.ID) or "") .. (Volume.Label and ("  \"" .. Volume.Label .. "\"") or "")
	end }))
	local function SetMode(Mode)
		local Item = List.Items[List.Selected]
		if (not Item) then return end
		local Warning = Volumes.ModeWarning(Item.Volume, Mode)
		if (Warning and not Ui.Confirm("Disk", Warning, "Change")) then return end
		Volumes.SetMode(Item.Volume.Key, Mode)
		Log.Info("blockdrive", Item.Volume.Name .. " is now " .. ModeNames[Mode])
		Build()
	end
	local ButtonY = Y + H - 1
	Page:Add(Ui.Button.new({ X = X, Y = ButtonY, Text = " Pool ", OnClick = function() SetMode("pool") end }))
	Page:Add(Ui.Button.new({ X = X + 7, Y = ButtonY, Text = " Own Share ", OnClick = function() SetMode("share") end }))
	Page:Add(Ui.Button.new({ X = X + 19, Y = ButtonY, Text = " Unused ", OnClick = function() SetMode("off") end }))
	Page:Add(Ui.Button.new({ X = X + 28, Y = ButtonY, Text = " Rename ", OnClick = function()
		local Item = List.Items[List.Selected]
		local Name = Item and Ui.Prompt("Rename disk", "Name (the share name when it has its own share):", Item.Volume.Name)
		if (Name and Name ~= "" and Name ~= Item.Volume.Name) then
			local Ok, Err = Volumes.Rename(Item.Volume.Key, Name)
			if (not Ok) then Ui.Alert("Rename disk", Err) end
			Build()
		end
	end }))
end

function Section.Security(X, Y, W)
	local Settings = Server.Settings()
	-- Pairing is optional unless required here; visitors get the permission chosen below.
	Page:Add(Ui.Toggle.new({ X = X, Y = Y, Value = Settings.Public == false, OnChange = function(_, Value)
		Settings.Public = not Value
		Server.Save()
		Util.Core().Announce()
		Log.Info("auth", Value and "Pairing is now required (private server)" or "Server is now public: no pairing needed")
		Build()
	end }))
	Page:Add(Ui.Label.new({ X = X + 5, Y = Y, W = W - 5, Text = "Require pairing (private server)" }))
	if (Settings.Public ~= false) then
		Page:Add(Ui.Label.new({ X = X, Y = Y + 1, Text = "Visitors" }))
		Page:Add(Ui.Tabs.new({ X = X + 11, Y = Y + 1, W = math.min(26, W - 11), Items = { "Read only", "Read & write" },
			Selected = Settings.Visitors == "read" and 1 or 2, OnChange = function(_, Index)
				Settings.Visitors = Index == 1 and "read" or "write"
				Server.Save()
				Util.Core().Announce()
			end }))
	end
	Y = Y + 3
	Util.Switch(X, Y, W, "Accept pairing requests", "PairingOpen")
	Util.Switch(X, Y + 2, W, "Encrypt file transfers", "Encrypt", function()
		Util.Core().Announce()
	end)
	Page:Add(Ui.Label.new({ X = X, Y = Y + 4, Text = "Lock after" }))
	local Minutes = Page:Add(Ui.Input.new({ X = X + 11, Y = Y + 4, W = 4, Value = tostring(Settings.LockMinutes or 0) }))
	Page:Add(Ui.Label.new({ X = X + 16, Y = Y + 4, Text = "min idle", Fg = "SubText" }))
	Page:Add(Ui.Button.new({ X = X + W - 6, Y = Y + 4, W = 6, Text = "Set", OnClick = function()
		Settings.LockMinutes = math.max(0, tonumber(Minutes.Value) or 0)
		Server.Save()
		Util.Say("Auto-lock saved.")
	end }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 6, Text = Server.HasPassword() and " Change Password " or " Set Password ", OnClick = function()
		if (Server.HasPassword()) then
			local Old = Ui.Prompt("Password", "Current admin password:", "", "\7")
			if (not Old) then return end
			if (not Server.CheckPassword(Old)) then
				Ui.Alert("Password", "That is not the current password.")
				return
			end
		end
		local New = Ui.Prompt("Password", "New admin password (empty for none):", "", "\7")
		if (not New) then return end
		if (New ~= "" and Ui.Prompt("Password", "Type it again:", "", "\7") ~= New) then
			Ui.Alert("Password", "The passwords did not match.")
			return
		end
		Server.SetPassword(New)
		Log.Info("console", New == "" and "Admin password removed" or "Admin password changed")
		Build()
	end }))
	Page:Add(Ui.Button.new({ X = X + 19, Y = Y + 6, Text = " Lock Now ", Enabled = Server.HasPassword(), OnClick = function()
		State.Locked = true
		Host.SetLocked(true)
		Build()
	end }))
end

function Section.Updates(X, Y, W)
	local Settings = Server.Settings()
	local Service = Util.Updates()
	local Latest = Updater.State.Latest
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Text = "Installed: " .. Server.Version() .. (Latest and ("   Latest: " .. tostring(Latest.Version)) or "") }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 1, W = W, Fg = "Accent", Text = Service and Service.Message or "" }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + 3, Text = " Check Now ", OnClick = function()
		os.queueEvent("blockcloud_update", "check")
		Util.Say("Checking for updates...")
	end }))
	Page:Add(Ui.Button.new({ X = X + 12, Y = Y + 3, Text = " Install Now ", Style = "primary", OnClick = function()
		os.queueEvent("blockcloud_update", "install")
		Util.Say("Installing in the background...")
	end }))
	if (Service and Service.Pending) then
		Page:Add(Ui.Button.new({ X = X + 26, Y = Y + 3, Text = " Restart ", OnClick = function() os.reboot() end }))
	end
	Util.Switch(X, Y + 5, W, "Check automatically", "AutoUpdate")
	Util.Switch(X, Y + 6, W, "Install in the background", "AutoInstall")
	Util.Switch(X, Y + 7, W, "Restart when no one is transferring", "AutoRestart")
	Util.Field(X, Y + 9, W, "Every (h)", Settings.UpdateHours, function(Value)
		local Number = tonumber(Value)
		if (not Number or Number < 1) then return "Enter a number of hours (1 or more)." end
		Settings.UpdateHours = Number
		Server.Save()
	end)
	Util.Field(X, Y + 11, W, "Channel", Settings.UpdateURL, function(Value)
		if (not Value:match("^https?://")) then return "Enter an http(s) URL ending in /." end
		Settings.UpdateURL = Value
		Server.Save()
	end)
end

function Section.Services(X, Y, W, H)
	local Items = {}
	for _, Status in ipairs(Manager.Status()) do
		table.insert(Items, { Text = Status.Title, Right = Status.State, Icon = "\7", IconFg = Dots[Status.Level] or "SubText", Status = Status })
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y, W = W, H = math.min(#Items, H - 6), Items = Items, Bg = "Panel" }))
	List.Selected = 1
	local Detail = Page:Add(Ui.Label.new({ X = X, Y = Y + #Items + 1, W = W, H = 2, Fg = "SubText", Text = function()
		local Item = List.Items[List.Selected]
		return Item and (Item.Status.Detail or "") or ""
	end }))
	local ButtonY = Detail.Y + 3
	Page:Add(Ui.Button.new({ X = X, Y = ButtonY, Text = " Restart ", OnClick = function()
		local Item = List.Items[List.Selected]
		if (Item) then
			Manager.Restart(Item.Status.Name)
			Build()
		end
	end }))
	Page:Add(Ui.Button.new({ X = X + 10, Y = ButtonY, Text = " Enable/Disable ", OnClick = function()
		local Item = List.Items[List.Selected]
		if (not Item) then return end
		if (Item.Status.System) then
			Ui.Alert(Item.Status.Title, "This service is part of BlockCloud and is always on.")
			return
		end
		Manager.SetEnabled(Item.Status.Name, Item.Status.State == "disabled")
		Build()
	end }))
end

function Section.Appearance(X, Y, W)
	local Settings = Config.Settings()
	Page:Add(Ui.Label.new({ X = X, Y = Y, Text = "Mode" }))
	Page:Add(Ui.Tabs.new({ X = X + 8, Y = Y, W = 16, Items = { "Light", "Dark" }, Selected = Settings.Theme == "dark" and 2 or 1, OnChange = function(_, Index)
		Settings.Theme = Index == 2 and "dark" or "light"
		Config.Save("settings")
	end }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 2, Text = "Accent" }))
	Page:Add(Ui.Canvas.new({
		X = X + 8, Y = Y + 2, W = #Theme.Accents * 3, H = 1,
		OnDraw = function(Self, T)
			for Index, Color in ipairs(Theme.Accents) do
				Gfx.Write(T, Self.X + (Index - 1) * 3, Self.Y, Color == Settings.Accent and " \7 " or "   ", colors.white, Color)
			end
		end,
		OnEvent = function(Self, Name, _, MouseX)
			if (Name ~= "mouse_click") then return false end
			local Color = Theme.Accents[math.floor((MouseX - Self.X) / 3) + 1]
			if (Color) then
				Settings.Accent = Color
				Config.Save("settings")
			end
			return true
		end
	}))
end

function Tab.Settings(X, Y, W, H)
	local SideW = W >= 44 and 12 or 0
	local Side = Page:Add(Ui.List.new({ X = X, Y = Y, W = SideW, H = H, Bg = "Panel", SingleClick = true, Visible = SideW > 0 }))
	local Items = {}
	for _, Name in ipairs(Sections) do table.insert(Items, { Text = Name }) end
	Side:SetItems(Items)
	Side.Selected = State.Section
	Side.OnActivate = function(_, Index)
		State.Section = Index
		Build()
	end
	if (SideW == 0) then
		Page:Add(Ui.Button.new({ X = X, Y = Y, W = W, Text = "\31 " .. Sections[State.Section], Bg = "Panel", OnClick = function()
			local Index = Ui.Choose("Settings", Sections, State.Section)
			if (Index) then
				State.Section = Index
				Build()
			end
		end }))
		Y, H = Y + 2, H - 2
	end
	Section[Sections[State.Section]](X + SideW + (SideW > 0 and 1 or 0), Y, W - SideW - (SideW > 0 and 1 or 0), H)
end

--
-- Lock screen
--

function Util.BuildLock(W, H)
	local Settings = Server.Settings()
	local Logo = BlockOS.Require("logo")
	local LogoW, LogoH = Logo.Size(Logo.Small)
	local Top = math.max(2, math.floor((H - LogoH - 9) / 2))
	Page:Add(Ui.Canvas.new({ X = 1, Y = Top, W = W, H = LogoH, OnDraw = function(Self, T)
		Logo.Draw(T, math.floor((W - LogoW) / 2) + 1, Self.Y, Logo.Small)
	end }))
	Page:Add(Ui.Label.new({ X = 1, Y = Top + LogoH + 1, W = W, Align = "center", Fg = "Accent", Text = Settings.Hostname .. "  \7  " .. Settings.DisplayName }))
	local Errors = 0
	for _, Status in ipairs(Manager.Status()) do
		if (Status.Level == "error") then Errors = Errors + 1 end
	end
	Page:Add(Ui.Label.new({ X = 1, Y = Top + LogoH + 2, W = W, Align = "center", Fg = "SubText",
		Text = Errors == 0 and "All services running" or (Errors .. " service" .. (Errors == 1 and "" or "s") .. " need attention") }))
	local FieldW = math.min(24, W - 4)
	local Field = Page:Add(Ui.Input.new({ X = math.floor((W - FieldW) / 2) + 1, Y = Top + LogoH + 4, W = FieldW, Mask = "\7", Placeholder = "Admin password" }))
	Field.OnSubmit = function(_, Value)
		if (Server.CheckPassword(Value)) then
			State.Locked = false
			State.Message = nil
			Host.SetLocked(false)
			Host.LastInput = os.clock()
			Log.Info("console", "Console unlocked")
		else
			State.Message = "Wrong password."
			Field:SetValue("")
		end
		Build()
	end
	Page:Add(Ui.Label.new({ X = 1, Y = Top + LogoH + 6, W = W, Align = "center", Fg = colors.red, Text = function() return State.Message or "" end }))
	Page:SetFocus(Field)
end

--
-- Layout
--

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	if (Host.Locked ~= State.Locked) then Host.SetLocked(State.Locked) end
	Page:Add(Ui.Canvas.new({ X = 1, Y = 1, W = W, H = 1, OnDraw = function(Self, T, Th)
		Gfx.Fill(T, 1, 1, W, 1, Th.TopbarBg)
		Gfx.Write(T, 2, 1, "\4 BlockOS Server", Th.TopbarFg, Th.TopbarBg)
		local Settings = Server.Settings()
		local Right = Settings.Hostname .. "  " .. textutils.formatTime(os.time("local"), true)
		Gfx.Write(T, W - #Right, 1, Right, Th.TopbarDim, Th.TopbarBg)
	end }))
	if (State.Locked) then
		Util.BuildLock(W, H)
		Page:Invalidate()
		return
	end
	local Names = {}
	for Index, Name in ipairs(Tabs) do
		Names[Index] = Name
	end
	local Pending = #Clients.PendingList()
	if (Pending > 0) then Names[3] = "Pairing " .. Pending end
	Page:Add(Ui.Tabs.new({ X = 1, Y = 2, W = W, Items = Names, Selected = State.Tab, OnChange = function(_, Index)
		State.Tab = Index
		State.Message = nil
		Build()
	end }))
	Tab[Tabs[State.Tab]](2, 4, W - 2, H - 5)
	-- Bottom bar: the one graphical app, an admin shell, and the last message.
	Page:Add(Ui.Panel.new({ X = 1, Y = H, W = W, H = 1, Bg = "Panel" }))
	Page:Add(Ui.Button.new({ X = 1, Y = H, Text = " \16 Finder ", Bg = "Panel", OnClick = function()
		local Drive = Util.Drive()
		Host.Launch("finder", { Drive and Drive.Root() or "/" })
	end }))
	Page:Add(Ui.Button.new({ X = 11, Y = H, Text = " >_ Shell ", Bg = "Panel", OnClick = function() Host.Launch("shell") end }))
	if (Server.HasPassword()) then
		Page:Add(Ui.Button.new({ X = 21, Y = H, Text = " Lock ", Bg = "Panel", OnClick = function()
			State.Locked = true
			Build()
		end }))
	end
	Page:Add(Ui.Label.new({ X = 28, Y = H, W = W - 28, Align = "right", Bg = "Panel", Fg = "SubText", Text = function() return State.Message or "" end }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

local Refresh = { blockcloud_status = true, blockcloud_clients = true, blockcloud_storage = true, blockcloud_config = true, peripheral = true, peripheral_detach = true }

function Page:OnEvent(Name, A)
	if (Name == "timer" and A == State.RebuildTimer) then
		State.RebuildTimer = nil
		-- Avoid rebuilding under the admin's fingers in Settings, where fields hold typed text.
		if (Tabs[State.Tab] ~= "Settings" or State.Locked) then Build() end
		return true
	elseif (Refresh[Name]) then
		Util.Soon()
		if (Name == "blockcloud_clients" and #Clients.PendingList() > 0) then
			Util.Say("A computer is waiting to pair.")
		end
	elseif (Name == "blockcloud_log" and Tabs[State.Tab] == "Logs") then
		Util.Soon()
	end
	return false
end

function Page:OnTerminate() end

-- The clock, uptime and auto-lock tick slowly: nothing here needs to redraw often.
Page:SetInterval(15, function()
	local Minutes = tonumber(Server.Settings().LockMinutes) or 0
	if (not State.Locked and Server.HasPassword() and Minutes > 0 and os.clock() - Host.LastInput > Minutes * 60) then
		State.Locked = true
		Log.Info("console", "Console locked after " .. Minutes .. " idle minutes")
		Build()
		return true
	end
	if (Tabs[State.Tab] == "Overview" and not State.Locked) then Build() end
	return true
end)

Page:Run()
