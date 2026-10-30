-- Setup Assistant: the onboarding flow shown by the installer and on first boot.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")
local Config = BlockOS.Require("config")
local Logo = BlockOS.Require("logo")
local Users = BlockOS.Require("users")
local Wallpaper = BlockOS.Require("wallpaper")

local Setup = {}

function Setup.Run(Opts)
	Opts = Opts or {}
	local Settings = Config.Settings()
	local State = {
		Label = os.getComputerLabel() or ("BlockOS-" .. os.getComputerID()),
		Name = "",
		Password = "",
		Confirm = "",
		AutoLogin = false
	}
	local Steps = { "welcome", "computer", "account", "appearance", "updates" }
	if (Opts.Install) then
		table.insert(Steps, "install")
	end
	table.insert(Steps, "done")

	local Page = Ui.Page.new({ Bg = "WindowBg" })
	local StepIndex = 1
	local Error = nil
	local Frame = 0
	local Stars = {}
	local Build

	local function Go(Delta)
		StepIndex = math.max(1, math.min(#Steps, StepIndex + Delta))
		Error = nil
		Frame = 0
		Build()
	end

	local function Footer(CanBack, NextText, OnNext)
		local W, H = Page.W, Page.H
		if (CanBack) then
			Page:Add(Ui.Button.new({ X = 2, Y = H - 1, Text = " Back ", OnClick = function() Go(-1) end }))
		end
		Page:Add(Ui.Button.new({
			X = W - #NextText - 3, Y = H - 1, Text = " " .. NextText .. " ", Style = "primary",
			OnClick = OnNext or function() Go(1) end
		}))
	end

	local function Heading(Title, Subtitle)
		Page:Add(Ui.Label.new({ X = 3, Y = 2, W = Page.W - 4, Text = Title, Fg = "Accent" }))
		if (Subtitle) then
			Page:Add(Ui.Label.new({ X = 3, Y = 3, W = Page.W - 4, H = 2, Text = Subtitle, Fg = "SubText" }))
		end
	end

	local function Finish()
		Settings.AutoLogin = State.AutoLogin
		Config.Save("settings")
		if (#State.Label > 0) then
			os.setComputerLabel(State.Label)
		end
		if (not Users.Find(State.Name)) then
			Users.Create(State.Name, State.Password, { Color = Settings.Accent })
		end
	end

	local function BuildWelcome()
		Page.Bg = colors.black
		local W, H = Page.W, Page.H
		Stars = {}
		for _ = 1, math.floor(W * H / 14) do
			table.insert(Stars, { X = math.random(1, W), Y = math.random(1, H), Phase = math.random(0, 10) })
		end
		function Page:OnDraw(T)
			for _, Star in ipairs(Stars) do
				local Bright = (Frame + Star.Phase) % 12
				local Char = (Bright < 2) and "+" or ((Bright < 6) and "." or " ")
				Gfx.Write(T, Star.X, Star.Y, Char, (Bright < 2) and colors.white or colors.gray, colors.black)
			end
			local LogoW, LogoH = Logo.Size()
			local LogoY = math.max(2, math.floor(H / 2) - LogoH)
			Logo.DrawPartial(T, math.floor((W - LogoW) / 2) + 1, LogoY, math.min(1, Frame / 10))
			if (Frame >= 10) then
				Gfx.Center(T, LogoY + LogoH + 1, "Welcome to BlockOS", colors.white, colors.black)
				Gfx.Center(T, LogoY + LogoH + 2, "A desktop for CC: Tweaked", colors.lightGray, colors.black)
			end
		end
		Page:Add(Ui.Button.new({
			X = math.floor((W - 15) / 2) + 1, Y = H - 2, W = 15, Text = "Get Started \26", Style = "primary",
			OnClick = function() Go(1) end
		}))
	end

	local function BuildComputer()
		Heading("Name this computer", "Other computers see this name in Messages and on the network.")
		local Field = Page:Add(Ui.Input.new({ X = 3, Y = 7, W = math.min(30, Page.W - 6), Value = State.Label, MaxLength = 32 }))
		Field.OnChange = function(_, Value) State.Label = Value end
		Field.OnSubmit = function() Go(1) end
		Page:Add(Ui.Label.new({ X = 3, Y = 9, W = Page.W - 4, Text = "Computer ID: " .. os.getComputerID(), Fg = "SubText" }))
		Page:SetFocus(Field)
		Footer(true, "Continue")
	end

	local function BuildAccount()
		Heading("Create your account", "Choose a name and a password for the login screen.")
		local FieldW = math.min(26, Page.W - 18)
		Page:Add(Ui.Label.new({ X = 3, Y = 6, Text = "Name", Fg = "Text" }))
		local Name = Page:Add(Ui.Input.new({ X = 14, Y = 6, W = FieldW, Value = State.Name, MaxLength = 20, Placeholder = "Steve" }))
		Page:Add(Ui.Label.new({ X = 3, Y = 8, Text = "Password", Fg = "Text" }))
		local Password = Page:Add(Ui.Input.new({ X = 14, Y = 8, W = FieldW, Value = State.Password, Mask = "\7" }))
		Page:Add(Ui.Label.new({ X = 3, Y = 10, Text = "Confirm", Fg = "Text" }))
		local Confirm = Page:Add(Ui.Input.new({ X = 14, Y = 10, W = FieldW, Value = State.Confirm, Mask = "\7" }))
		local Auto = Page:Add(Ui.Checkbox.new({ X = 3, Y = 12, Text = "Log in automatically", Value = State.AutoLogin }))
		Auto.OnChange = function(_, Value) State.AutoLogin = Value end
		Page:Add(Ui.Label.new({ X = 3, Y = 14, W = Page.W - 4, Fg = colors.red, Text = function() return Error or "" end }))
		Name.OnChange = function(_, Value) State.Name = Value end
		Password.OnChange = function(_, Value) State.Password = Value end
		Confirm.OnChange = function(_, Value) State.Confirm = Value end
		local function Validate()
			if (#State.Name:gsub("%s", "") == 0) then
				Error = "Please enter a name."
			elseif (State.Password ~= State.Confirm) then
				Error = "Passwords do not match."
			else
				Go(1)
				return
			end
			Page:Invalidate()
		end
		Name.OnSubmit = function() Page:SetFocus(Password) end
		Password.OnSubmit = function() Page:SetFocus(Confirm) end
		Confirm.OnSubmit = Validate
		Page:SetFocus(Name)
		Footer(true, "Continue", Validate)
	end

	local function BuildAppearance()
		Heading("Choose your look")
		local W = Page.W
		Page:Add(Ui.Label.new({ X = 3, Y = 4, Text = "Appearance" }))
		local Mode = Page:Add(Ui.Tabs.new({ X = 16, Y = 4, W = 16, Items = { "Light", "Dark" }, Selected = Settings.Theme == "dark" and 2 or 1 }))
		Mode.OnChange = function(_, Index)
			Settings.Theme = (Index == 2) and "dark" or "light"
		end
		Page:Add(Ui.Label.new({ X = 3, Y = 6, Text = "Accent" }))
		Page:Add(Ui.Canvas.new({
			X = 16, Y = 6, W = #Theme.Accents * 3, H = 1,
			OnDraw = function(Self, T, Th)
				for Index, Color in ipairs(Theme.Accents) do
					local Char = (Color == Settings.Accent) and " \7 " or "   "
					Gfx.Write(T, Self.X + (Index - 1) * 3, Self.Y, Char, colors.white, Color)
				end
			end,
			OnEvent = function(Self, Name, Button, X)
				if (Name ~= "mouse_click") then return false end
				local Index = math.floor((X - Self.X) / 3) + 1
				if (Theme.Accents[Index]) then
					Settings.Accent = Theme.Accents[Index]
				end
				return true
			end
		}))
		Page:Add(Ui.Label.new({ X = 3, Y = 8, Text = "Wallpaper" }))
		local Items = {}
		local Selected = 1
		for Index, Entry in ipairs(Wallpaper.List) do
			table.insert(Items, { Text = Entry.Name, ID = Entry.ID })
			if (Entry.ID == Settings.Wallpaper) then Selected = Index end
		end
		local List = Page:Add(Ui.List.new({ X = 3, Y = 9, W = 16, H = math.min(#Items, Page.H - 11), Items = Items, Bg = "Panel" }))
		List.Selected = Selected
		List.OnSelect = function(_, _, Item)
			Settings.Wallpaper = Item.ID
		end
		local PreviewW = math.min(24, W - 24)
		if (PreviewW >= 8) then
			Page:Add(Ui.Canvas.new({
				X = 21, Y = 9, W = PreviewW, H = math.min(7, Page.H - 11),
				OnDraw = function(Self, T)
					Wallpaper.Draw(T, Self.X, Self.Y, Self.W, Self.H, Settings.Wallpaper, Settings.WallpaperColor)
					Gfx.Fill(T, Self.X, Self.Y, Self.W, 1, colors.white)
					Gfx.Write(T, Self.X + 1, Self.Y, "\131", colors.lime, colors.brown)
					Gfx.Fill(T, Self.X + 4, Self.Y + 2, math.max(Self.W - 8, 4), 3, colors.white)
					Gfx.Fill(T, Self.X + 4, Self.Y + 2, math.max(Self.W - 8, 4), 1, colors.lightGray)
					Gfx.Write(T, Self.X + 5, Self.Y + 2, "\7\7\7", Settings.Accent, colors.lightGray)
				end
			}))
		end
		Footer(true, "Continue")
	end

	local function BuildUpdates()
		Heading("Software updates", "BlockOS can keep itself up to date from github.com/tamayaren/BlockOS.")
		local Check = Page:Add(Ui.Toggle.new({ X = 3, Y = 7, Value = Settings.AutoUpdate }))
		Check.OnChange = function(_, Value) Settings.AutoUpdate = Value end
		Page:Add(Ui.Label.new({ X = 9, Y = 7, Text = "Check for updates automatically" }))
		local Install = Page:Add(Ui.Toggle.new({ X = 3, Y = 9, Value = Settings.AutoInstall }))
		Install.OnChange = function(_, Value) Settings.AutoInstall = Value end
		Page:Add(Ui.Label.new({ X = 9, Y = 9, Text = "Install updates in the background" }))
		Page:Add(Ui.Label.new({ X = 3, Y = 11, W = Page.W - 4, H = 3, Fg = "SubText", Text = "You can change this later in Settings > Software Update." }))
		Footer(true, Opts.Install and "Install" or "Continue")
	end

	local function BuildInstall()
		Heading("Installing BlockOS " .. (Opts.Version or ""), "Copying system files. This only takes a moment.")
		local Bar = Page:Add(Ui.Progress.new({ X = 3, Y = 8, W = Page.W - 4, Value = 0 }))
		local Status = Page:Add(Ui.Label.new({ X = 3, Y = 10, W = Page.W - 4, Text = "Preparing...", Fg = "SubText" }))
		Page:Draw()
		local Ok, Err = pcall(Opts.Install, function(Done, Total, Path)
			Bar.Value = Total > 0 and Done / Total or 1
			Status.Text = Path or ""
			Page:Draw()
		end)
		if (not Ok) then
			Status.Text = "Install failed: " .. tostring(Err)
			Status.Fg = colors.red
			Page:Draw()
			Footer(false, "Quit", function() Page:Stop() end)
			return
		end
		Finish()
		State.Finished = true
		Go(1)
	end

	local function BuildDone()
		if (not Opts.Install and not State.Finished) then
			Finish()
			State.Finished = true
		end
		local W, H = Page.W, Page.H
		local LogoW, LogoH = Logo.Size(Logo.Small)
		function Page:OnDraw(T, Th)
			Logo.Draw(T, math.floor((W - LogoW) / 2) + 1, 3, Logo.Small)
			Gfx.Center(T, 4 + LogoH, "You're all set, " .. State.Name .. "!", Th.Accent, Th.WindowBg)
			Gfx.Center(T, 6 + LogoH, "Tip: right-click the dock or desktop for options.", Th.SubText, Th.WindowBg)
			Gfx.Center(T, 7 + LogoH, "Ctrl+Shift+Space opens Launchpad.", Th.SubText, Th.WindowBg)
		end
		local Text = Opts.Install and "Restart" or "Start BlockOS"
		Page:Add(Ui.Button.new({
			X = math.floor((W - #Text - 4) / 2) + 1, Y = H - 2, W = #Text + 4, Text = Text, Style = "primary",
			OnClick = function() Page:Stop() end
		}))
	end

	local Builders = {
		welcome = BuildWelcome,
		computer = BuildComputer,
		account = BuildAccount,
		appearance = BuildAppearance,
		updates = BuildUpdates,
		install = BuildInstall,
		done = BuildDone
	}

	function Build()
		Page:Clear()
		Page.OnDraw = nil
		Page.Bg = "WindowBg"
		local Name = Steps[StepIndex]
		function Page:OnDrawOver(T, Th)
			if (Name == "welcome") then return end
			local Dots = #Steps * 2 - 1
			local X = math.floor((self.W - Dots) / 2) + 1
			for Index = 1, #Steps do
				Gfx.Write(T, X + (Index - 1) * 2, self.H, "\7", (Index == StepIndex) and Th.Accent or Th.Border, self:GetBg(Th))
			end
		end
		Builders[Name]()
		Page:Invalidate()
	end

	function Page:OnLayout()
		Build()
	end

	function Page:OnTerminate()
		if (Opts.Install) then self:Stop() end
	end

	Page:SetInterval(.1, function()
		Frame = Frame + 1
		return Steps[StepIndex] == "welcome"
	end)

	Page:Run()
	term.setBackgroundColor(colors.black)
	term.clear()
	term.setCursorPos(1, 1)
	return State
end

return Setup
