-- Control Center: the panel that drops from the menu bar's control icon, with Wi-Fi,
-- Do Not Disturb, light/dark mode, volume, now playing and recent notifications.
-- The desktop owns the screen and input; this module draws the panel and handles clicks inside it.

local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Media = BlockOS.Require("media")
local Wifi = BlockOS.Require("wifi")
local Glass = BlockOS.Require("glass")

local MaxW = 26

-- Host: Screen(), Size(), History(), Dismiss(Entry or nil for all), Launch(AppID, Args), Lock(), Alive(ProcID), Redraw().
return function(Host)
	local Control = { Open = false, Regions = {}, Offset = 0, X = 1, Y = 2, W = MaxW, H = 1 }

	local function Save()
		Config.Save("settings")
		Host.Redraw()
	end

	local function Region(X, Y, W, H, Props)
		Props.X, Props.Y, Props.W, Props.H = X, Y, W, H
		table.insert(Control.Regions, Props)
		return Props
	end

	local function NowPlaying()
		local Info = Media.Now()
		if (Info and Info.Owner and not Host.Alive(Info.Owner)) then
			Media.ClearSource()
			return nil
		end
		return Info
	end

	local function FormatTime(Seconds)
		Seconds = math.max(0, math.floor(Seconds or 0))
		return string.format("%d:%02d", math.floor(Seconds / 60), Seconds % 60)
	end

	-- Two-row tile: accent when on, a muted block when off.
	local function Tile(B, Th, X, Y, W, Lines, On, Action)
		local Bg = On and Th.Accent or (Th.Dark and colors.black or colors.lightGray)
		local Fg = On and Th.AccentFg or Th.MenuFg
		Gfx.Fill(B, X, Y, W, 2, Bg)
		for Row, Text in ipairs(Lines) do
			Gfx.Write(B, X + 1, Y + Row - 1, Gfx.Truncate(Text, W - 2), Fg, Bg)
		end
		Region(X, Y, W, 2, { Action = Action })
	end

	local function SetVolume(Value, Commit)
		local Settings = Config.Settings()
		Settings.Volume = math.max(0, math.min(100, math.floor(Value + .5)))
		if (Commit) then
			Save()
		else
			Host.Redraw()
		end
	end

	-- Draws the whole panel into B (panel-local coordinates) and returns its height.
	-- Pane is the panel's background: glass over the desktop, or the solid menu colour.
	local function Paint(B, Th, W, MaxH, Pane)
		local Settings = Config.Settings()
		local X0, CW = 2, W - 2
		Control.Regions = {}
		Control.List = nil
		Pane:Fill(B)

		local TileW = math.floor((CW - 1) / 2)
		local RightX, RightW = X0 + TileW + 1, CW - TileW - 1
		Tile(B, Th, X0, 2, TileW, { "WiFi", Wifi.Status() }, Wifi.On(), function()
			Wifi.SetOn(not Wifi.On())
			Host.Redraw()
		end)
		Tile(B, Th, RightX, 2, RightW, { "Do Not", "Disturb" }, Settings.DoNotDisturb == true, function()
			Settings.DoNotDisturb = not Settings.DoNotDisturb
			Save()
		end)
		local Dark = Settings.Theme == "dark"
		Tile(B, Th, X0, 5, TileW, { "Dark Mode", Dark and "On" or "Off" }, Dark, function()
			Settings.Theme = Dark and "light" or "dark"
			Save()
		end)
		Tile(B, Th, RightX, 5, RightW, { "Lock", "Screen" }, false, function()
			Control.Close()
			Host.Lock()
		end)

		-- Volume slider: click or drag along it, or scroll over it.
		local Volume = math.floor(Media.Volume() * 100 + .5)
		local Percent = (Volume == 0) and "Muted" or (Volume .. "%")
		Pane:Write(B, X0, 8, "Sound", "dim", Th.SubText)
		Pane:Write(B, X0 + CW - #Percent, 8, Percent, "dim", Th.SubText)
		local Filled = math.floor(Volume / 100 * CW + .5)
		Gfx.Fill(B, X0, 9, CW, 1, Th.Dark and colors.black or colors.lightGray)
		Gfx.Fill(B, X0, 9, Filled, 1, Th.Accent)
		Region(X0, 9, CW, 1, { Slider = true })
		local Row = 11

		local Info = NowPlaying()
		if (Info) then
			Pane:Write(B, X0, Row, "Now Playing", "dim", Th.SubText)
			local Title = tostring(Info.Title or "Untitled")
			if (Info.Artist) then Title = Title .. " - " .. tostring(Info.Artist) end
			Pane:Write(B, X0, Row + 1, Gfx.Truncate(Title, CW))
			local Controls = {
				{ "\171", "previous" },
				{ (Info.State == "playing") and "\149\149" or "\16", "toggle" },
				{ "\187", "next" }
			}
			for Index, Item in ipairs(Controls) do
				local X = X0 + (Index - 1) * 4
				Gfx.Write(B, X, Row + 2, Gfx.Pad(Item[1], 3, "center"), Th.ButtonFg, Th.ButtonBg)
				Region(X, Row + 2, 3, 1, { Media = Item[2] })
			end
			local Time = (Info.State == "loading") and "Loading..." or FormatTime(Info.Elapsed)
			if (Info.State ~= "loading" and (Info.Total or 0) > 0) then
				Time = Time .. "/" .. FormatTime(Info.Total)
			end
			if (#Time <= CW - 12) then
				Pane:Write(B, X0 + CW - #Time, Row + 2, Time, "dim", Th.SubText)
			end
			Row = Row + 4
		end

		-- Recent notifications, newest first, two rows each.
		local History = Host.History()
		Pane:Write(B, X0, Row, "Notifications", "dim", Th.SubText)
		if (#History > 0) then
			Pane:Write(B, X0 + CW - 5, Row, "Clear", Th.Accent)
			Region(X0 + CW - 5, Row, 5, 1, { Clear = true })
		end
		Row = Row + 1
		if (#History == 0) then
			Pane:Write(B, X0, Row, "No notifications", "dim")
			return Row + 1
		end
		local Visible = math.max(1, math.floor((MaxH - Row) / 2))
		Control.Offset = math.max(0, math.min(Control.Offset, #History - Visible))
		Control.List = { Y = Row, Visible = Visible }
		for Index = Control.Offset + 1, math.min(#History, Control.Offset + Visible) do
			local Entry = History[Index]
			Pane:Write(B, X0, Row, Gfx.Truncate(Entry.Title, CW - 2), Th.Accent)
			Pane:Write(B, X0 + CW - 1, Row, "x", "dim")
			Pane:Write(B, X0, Row + 1, Gfx.Truncate(Entry.Text, CW))
			Region(X0 + CW - 2, Row, 3, 1, { Dismiss = Entry })
			Region(X0, Row, CW, 2, { Entry = Entry })
			Row = Row + 2
		end
		return Row
	end

	function Control.Toggle()
		Control.Open = not Control.Open
		Control.Offset = 0
		Control.Reveal = nil
		Control.Sliding = false
		return Control.Open
	end

	function Control.Close()
		Control.Open = false
		Control.Reveal = nil
		Control.Sliding = false
	end

	function Control.Draw(Th)
		if (not Control.Open) then return end
		local Screen = Host.Screen()
		local ScreenW, ScreenH = Host.Size()
		local W = math.min(MaxW, ScreenW - 2)
		local MaxH = math.max(4, ScreenH - 2)
		if (not Control.Buffer) then
			Control.Buffer = window.create(Screen, 1, 1, W, MaxH, false)
		else
			Control.Buffer.reposition(1, 1, W, MaxH)
		end
		local Pane = Glass.Surface(Screen, ScreenW - W, 2, W, MaxH, "control", Th.MenuBg, Th.MenuFg, Th.MenuDim)
		Pane.OX, Pane.OY = 1, 1
		local H = math.min(MaxH, Paint(Control.Buffer, Th, W, MaxH, Pane))
		Control.X, Control.Y, Control.W, Control.H = ScreenW - W, 2, W, H
		local Shown = math.min(H, Control.Reveal or H)
		for Row = 1, Shown do
			Screen.setCursorPos(Control.X, Control.Y + Row - 1)
			Screen.blit(Control.Buffer.getLine(Row))
		end
		if (Shown == H) then
			Gfx.Shadow(Screen, Control.X, Control.Y, W, H, Th.Shadow)
		end
	end

	function Control.Contains(X, Y)
		return Control.Open and X >= Control.X and X < Control.X + Control.W and Y >= Control.Y and Y < Control.Y + Control.H
	end

	local function RegionAt(X, Y)
		local LX, LY = X - Control.X + 1, Y - Control.Y + 1
		for _, Item in ipairs(Control.Regions) do
			if (LX >= Item.X and LX < Item.X + Item.W and LY >= Item.Y and LY < Item.Y + Item.H) then
				return Item, LX
			end
		end
		return nil
	end

	local function SliderValue(Item, LX)
		return (LX - Item.X) / math.max(1, Item.W - 1) * 100
	end

	-- Returns true when the click landed on the panel.
	function Control.Click(Button, X, Y)
		if (not Control.Contains(X, Y)) then return false end
		local Item, LX = RegionAt(X, Y)
		if (not Item) then return true end
		if (Item.Slider) then
			Control.Sliding = Item
			SetVolume(SliderValue(Item, LX), false)
		elseif (Item.Action) then
			Item.Action()
		elseif (Item.Media) then
			Media.Send(Item.Media)
		elseif (Item.Clear) then
			Control.Offset = 0
			Host.Dismiss(nil)
		elseif (Item.Dismiss) then
			Host.Dismiss(Item.Dismiss)
		elseif (Item.Entry) then
			local Entry = Item.Entry
			Host.Dismiss(Entry)
			if (Entry.AppID) then
				Control.Close()
				Host.Launch(Entry.AppID, Entry.Args)
			end
		end
		return true
	end

	function Control.Drag(X)
		local Item = Control.Sliding
		if (not Item) then return false end
		SetVolume(SliderValue(Item, X - Control.X + 1), false)
		return true
	end

	function Control.Up()
		if (not Control.Sliding) then return false end
		Control.Sliding = false
		Save()
		return true
	end

	function Control.Scroll(Direction, X, Y)
		if (not Control.Contains(X, Y)) then return false end
		local Item = RegionAt(X, Y)
		if (Item and Item.Slider) then
			SetVolume(Media.Volume() * 100 - Direction * 10, true)
		elseif (Control.List and Y - Control.Y + 1 >= Control.List.Y) then
			Control.Offset = math.max(0, Control.Offset + Direction)
			Host.Redraw()
		end
		return true
	end

	return Control
end
