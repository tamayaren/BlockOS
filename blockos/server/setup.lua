-- Server Edition setup: hostname, storage location, admin password and updates.
-- Shown by the installer, and on first boot if setup never finished.

local Server = BlockOS.Require("server/config")
local Path = BlockOS.Require("cloud/path")

local Setup = {}

local function Defaults()
	local Settings = Server.Settings()
	local Label = os.getComputerLabel()
	return {
		Hostname = (Label and Server.ValidHostname(Label)) and Label or Settings.Hostname,
		DisplayName = Settings.DisplayName,
		StorageRoot = Settings.StorageRoot,
		Password = "",
		Confirm = "",
		AutoUpdate = Settings.AutoUpdate ~= false,
		AutoInstall = Settings.AutoInstall ~= false,
		Public = Settings.Public ~= false,
		Visitors = Settings.Visitors == "read" and "read" or "write"
	}
end

-- Storage locations to offer: the default folder and a folder on each attached disk drive.
local function Locations()
	local List = { { Text = "This computer  /blockcloud/storage", Path = "/blockcloud/storage" } }
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "drive" and disk.hasData(Side)) then
			local Mount = disk.getMountPath(Side)
			table.insert(List, { Text = "Disk " .. (disk.getLabel(Side) or Mount) .. "  /" .. Mount .. "/blockcloud", Path = "/" .. Mount .. "/blockcloud" })
		end
	end
	return List
end

local function Finish(State)
	local Settings = Server.Settings()
	Settings.Hostname = State.Hostname
	Settings.DisplayName = State.DisplayName
	Settings.StorageRoot = "/" .. fs.combine(State.StorageRoot, "")
	Settings.AutoUpdate = State.AutoUpdate
	Settings.AutoInstall = State.AutoInstall
	Settings.Public = State.Public ~= false
	Settings.Visitors = State.Visitors == "read" and "read" or "write"
	Settings.Configured = true
	Server.Save()
	if (State.Password ~= "") then Server.SetPassword(State.Password) end
	os.setComputerLabel(State.Hostname)
	if (not fs.exists(Settings.StorageRoot)) then fs.makeDir(Settings.StorageRoot) end
end

Setup.Finish = Finish

-- Validates the answers; returns an error message or nil.
local function Check(State, Step)
	if (Step == "identity") then
		if (not Server.ValidHostname(State.Hostname)) then return "The hostname needs 1-24 letters, digits, - or _." end
		if (#State.DisplayName == 0 or #State.DisplayName > 32) then return "The name needs 1-32 characters." end
	elseif (Step == "storage") then
		local Ok, Err = Path.ValidRoot(State.StorageRoot)
		if (not Ok) then return Err end
	elseif (Step == "admin") then
		if (State.Password ~= State.Confirm) then return "The passwords do not match." end
	end
	return nil
end

function Setup.Run(Opts)
	Opts = Opts or {}
	local Ui = BlockOS.Require("ui")
	local Gfx = BlockOS.Require("gfx")
	local Logo = BlockOS.Require("logo")
	local State = Defaults()
	local Steps = { "welcome", "identity", "storage", "access", "admin", "updates" }
	if (Opts.Install) then table.insert(Steps, "install") end
	table.insert(Steps, "done")
	local Page = Ui.Page.new({ Bg = "WindowBg" })
	local StepIndex = 1
	local Error = nil
	local Build

	local function Go(Delta)
		if (Delta > 0) then
			Error = Check(State, Steps[StepIndex])
			if (Error) then
				Page:Invalidate()
				Build()
				return
			end
		end
		StepIndex = math.max(1, math.min(#Steps, StepIndex + Delta))
		Error = nil
		Build()
	end

	local function Heading(Title, Subtitle)
		Page:Add(Ui.Label.new({ X = 3, Y = 2, W = Page.W - 4, Text = Title, Fg = "Accent" }))
		if (Subtitle) then
			Page:Add(Ui.Label.new({ X = 3, Y = 3, W = Page.W - 4, H = 2, Text = Subtitle, Fg = "SubText" }))
		end
	end

	local function Footer(NextText, OnNext)
		local W, H = Page.W, Page.H
		if (StepIndex > 1 and not State.Finished) then
			Page:Add(Ui.Button.new({ X = 2, Y = H - 1, Text = " Back ", OnClick = function() Go(-1) end }))
		end
		Page:Add(Ui.Button.new({ X = W - #NextText - 3, Y = H - 1, Text = " " .. NextText .. " ", Style = "primary", OnClick = OnNext or function() Go(1) end }))
		Page:Add(Ui.Label.new({ X = 3, Y = H - 3, W = W - 4, Fg = colors.red, Text = function() return Error or "" end }))
	end

	local function Field(Y, Label, Key, Opts2)
		Opts2 = Opts2 or {}
		Page:Add(Ui.Label.new({ X = 3, Y = Y, Text = Label }))
		local Input = Page:Add(Ui.Input.new({ X = 17, Y = Y, W = math.min(28, Page.W - 19), Value = State[Key], Mask = Opts2.Mask, MaxLength = Opts2.Max }))
		Input.OnChange = function(_, Value) State[Key] = Value end
		Input.OnSubmit = function() Go(1) end
		return Input
	end

	local Builders = {}

	function Builders.welcome()
		local W, H = Page.W, Page.H
		local LogoW, LogoH = Logo.Size(Logo.Big)
		Page:Add(Ui.Canvas.new({ X = 1, Y = 2, W = W, H = LogoH, OnDraw = function(Self, T)
			Logo.Draw(T, math.floor((W - LogoW) / 2) + 1, Self.Y, Logo.Big)
		end }))
		Page:Add(Ui.Label.new({ X = 1, Y = LogoH + 3, W = W, Align = "center", Text = "BlockOS Server Edition" .. (Opts.Version and (" " .. Opts.Version) or "") }))
		Page:Add(Ui.Label.new({ X = 3, Y = LogoH + 5, W = W - 4, H = 3, Align = "center", Fg = "SubText",
			Text = "Turns this computer into a BlockCloud server with BlockDrive network storage for your BlockOS computers." }))
		Footer("Set Up \26")
	end

	function Builders.identity()
		Heading("Name this server", "Clients find it by its hostname and show its name in BlockDrive.")
		local First = Field(6, "Hostname", "Hostname", { Max = 24 })
		Field(8, "Display name", "DisplayName", { Max = 32 })
		Page:Add(Ui.Label.new({ X = 3, Y = 10, W = Page.W - 4, Fg = "SubText", Text = "Computer ID: " .. os.getComputerID() }))
		Page:SetFocus(First)
		Footer("Continue")
	end

	function Builders.storage()
		Heading("Storage location", "BlockDrive keeps shared files here. Disk drives you attach, also over wired modems, are pooled with it automatically.")
		local Items = Locations()
		local List = Page:Add(Ui.List.new({ X = 3, Y = 6, W = Page.W - 4, H = math.min(#Items, 4), Items = Items, Bg = "Panel" }))
		for Index, Item in ipairs(Items) do
			if (Item.Path == State.StorageRoot) then List.Selected = Index end
		end
		local Input = Field(math.min(#Items, 4) + 7, "Folder", "StorageRoot")
		List.OnSelect = function(_, _, Item)
			State.StorageRoot = Item.Path
			Input:SetValue(Item.Path)
		end
		Footer("Continue")
	end

	function Builders.access()
		Heading("Who can use it", "A public server works for every computer in range straight away. A private one needs the administrator to pair each computer with a code.")
		local Visitors
		Page:Add(Ui.Toggle.new({ X = 3, Y = 6, Value = not State.Public, OnChange = function(_, Value)
			State.Public = not Value
			Visitors.Visible = State.Public
			Page:Invalidate()
		end }))
		Page:Add(Ui.Label.new({ X = 9, Y = 6, Text = "Require pairing (private server)" }))
		Visitors = Page:Add(Ui.Tabs.new({ X = 3, Y = 8, W = math.min(30, Page.W - 4), Items = { "Visitors: read only", "Read & write" },
			Selected = State.Visitors == "read" and 1 or 2, Visible = State.Public, OnChange = function(_, Index)
				State.Visitors = Index == 1 and "read" or "write"
			end }))
		Page:Add(Ui.Label.new({ X = 3, Y = 10, W = Page.W - 4, H = 3, Fg = "SubText",
			Text = "Paired computers always keep their own permission and encrypted transfers. Change this later in Settings > Security." }))
		Footer("Continue")
	end

	function Builders.admin()
		Heading("Administrator password", "Locks this console. Leave it empty if the Data Center is private. Services run either way.")
		local First = Field(6, "Password", "Password", { Mask = "\7" })
		Field(8, "Confirm", "Confirm", { Mask = "\7" })
		Page:SetFocus(First)
		Footer("Continue")
	end

	function Builders.updates()
		Heading("Software updates", "Server Edition updates from its own channel, never the desktop one.")
		Page:Add(Ui.Toggle.new({ X = 3, Y = 6, Value = State.AutoUpdate, OnChange = function(_, Value) State.AutoUpdate = Value end }))
		Page:Add(Ui.Label.new({ X = 9, Y = 6, Text = "Check for updates automatically" }))
		Page:Add(Ui.Toggle.new({ X = 3, Y = 8, Value = State.AutoInstall, OnChange = function(_, Value) State.AutoInstall = Value end }))
		Page:Add(Ui.Label.new({ X = 9, Y = 8, Text = "Install them in the background" }))
		Page:Add(Ui.Label.new({ X = 3, Y = 10, W = Page.W - 4, H = 2, Fg = "SubText", Text = "Change this later in the console under Settings > Updates." }))
		Footer(Opts.Install and "Install" or "Continue")
	end

	function Builders.install()
		Heading("Installing BlockOS Server " .. (Opts.Version or ""), "Copying system files. Your stored files and settings are kept.")
		local Bar = Page:Add(Ui.Progress.new({ X = 3, Y = 7, W = Page.W - 4, Value = 0 }))
		local Status = Page:Add(Ui.Label.new({ X = 3, Y = 9, W = Page.W - 4, Text = "Preparing...", Fg = "SubText" }))
		Page:Draw()
		local Ok, Err = pcall(Opts.Install, function(Done, Total, Name)
			Bar.Value = Total > 0 and Done / Total or 1
			Status.Text = Name or ""
			Page:Draw()
		end)
		if (not Ok) then
			Status.Text = "Install failed: " .. tostring(Err)
			Status.Fg = colors.red
			Page:Add(Ui.Button.new({ X = Page.W - 8, Y = Page.H - 1, Text = " Quit ", OnClick = function() Page:Stop() end }))
			Page:Invalidate()
			return
		end
		Finish(State)
		State.Finished = true
		Go(1)
	end

	function Builders.done()
		if (not State.Finished) then
			Finish(State)
			State.Finished = true
		end
		Heading("Ready", nil)
		Page:Add(Ui.Label.new({ X = 3, Y = 4, W = Page.W - 4, H = 6, Text =
			State.Hostname .. " will start BlockCloud and BlockDrive every time it boots. To connect a BlockOS computer, install BlockDrive there, choose Add Server, and approve it in this console under Pairing." }))
		local Text = Opts.Install and "Restart" or "Start Server"
		Footer(Text, function() Page:Stop() end)
	end

	function Build()
		Page:Clear()
		Builders[Steps[StepIndex]]()
		function Page:OnDrawOver(T, Th)
			local X = math.floor((self.W - (#Steps * 2 - 1)) / 2) + 1
			for Index = 1, #Steps do
				Gfx.Write(T, X + (Index - 1) * 2, self.H, "\7", Index == StepIndex and Th.Accent or Th.Border, Th.WindowBg)
			end
		end
		Page:Invalidate()
	end

	function Page:OnLayout() Build() end
	function Page:OnTerminate()
		if (Opts.Install) then self:Stop() end
	end
	Page:Run()
	term.setBackgroundColor(colors.black)
	term.clear()
	term.setCursorPos(1, 1)
	return State
end

-- Plain prompts for basic computers (no colour screen) and unattended scripts.
function Setup.RunText(Opts)
	Opts = Opts or {}
	local State = Defaults()
	local function Ask(Question, Key, Mask)
		while (true) do
			write(Question .. " [" .. (Mask and "" or tostring(State[Key])) .. "]: ")
			local Answer = read(Mask)
			if (Answer ~= "") then State[Key] = Answer end
			return
		end
	end
	print("BlockOS Server setup")
	for _, Step in ipairs({ "identity", "storage", "access", "admin" }) do
		while (true) do
			if (Step == "access") then
				write("Require pairing (private server)? (y/N): ")
				State.Public = (read() or ""):lower():sub(1, 1) ~= "y"
			elseif (Step == "identity") then
				Ask("Hostname", "Hostname")
				Ask("Display name", "DisplayName")
			elseif (Step == "storage") then
				Ask("Storage folder", "StorageRoot")
			else
				State.Password, State.Confirm = "", ""
				Ask("Admin password (empty for none)", "Password", "*")
				if (State.Password ~= "") then Ask("Confirm password", "Confirm", "*") end
				if (State.Password == "") then State.Confirm = "" end
			end
			local Err = Check(State, Step)
			if (not Err) then break end
			printError(Err)
		end
	end
	if (Opts.Install) then Opts.Install() end
	Finish(State)
	print("Setup complete.")
	return State
end

return Setup
