-- Devices: inspect this computer, redstone sides and every attached peripheral, with per-type actions.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")

local Page = Ui.Page.new()
local SelectedID = "computer"
local Build

local TypeIcons = {
	monitor = { "\8", colors.lightBlue }, modem = { "\29", colors.orange }, speaker = { "\14", colors.red },
	drive = { "\22", colors.gray }, printer = { "\127", colors.yellow }, computer = { "\8", colors.cyan },
	turtle = { "\4", colors.lime }, redstone = { "\7", colors.red }
}

local function Entries()
	local List = {
		{ ID = "computer", Text = "This Computer", Icon = "\8", IconFg = colors.cyan },
		{ ID = "redstone", Text = "Redstone", Icon = "\7", IconFg = colors.red }
	}
	local Names = peripheral.getNames()
	table.sort(Names)
	for _, Name in ipairs(Names) do
		local Kind = peripheral.getType(Name)
		local Icon = TypeIcons[Kind] or { "\4", colors.gray }
		table.insert(List, { ID = Name, Text = Name, Icon = Icon[1], IconFg = Icon[2], Kind = Kind })
	end
	return List
end

local function Info(X, Y, W, Lines)
	for Index, Line in ipairs(Lines) do
		Page:Add(Ui.Label.new({ X = X, Y = Y + Index - 1, W = 10, Text = Line[1], Fg = "SubText" }))
		Page:Add(Ui.Label.new({ X = X + 10, Y = Y + Index - 1, W = W - 10, Text = tostring(Line[2]) }))
	end
	return Y + #Lines + 1
end

local function Buttons(X, Y, W, List)
	local BX = X
	for _, Entry in ipairs(List) do
		local Width = #Entry[1] + 2
		if (BX + Width > X + W) then
			BX = X
			Y = Y + 2
		end
		Page:Add(Ui.Button.new({ X = BX, Y = Y, W = Width, Text = Entry[1], Style = Entry[3], OnClick = function()
			local Ok, Err = pcall(Entry[2])
			if (not Ok) then Ui.Alert("Devices", tostring(Err)) end
			Build()
		end }))
		BX = BX + Width + 1
	end
	return Y + 2
end

local Details = {}

function Details.computer(X, Y, W)
	local Uptime = math.floor(os.clock())
	Info(X, Y, W, {
		{ "Label", os.getComputerLabel() or "(none)" },
		{ "ID", os.getComputerID() },
		{ "Kind", (turtle and "Turtle" or (pocket and "Pocket computer" or "Computer")) .. (term.isColor() and ", advanced" or "") },
		{ "Version", _HOST or os.version() },
		{ "Uptime", string.format("%dh %02dm %02ds", math.floor(Uptime / 3600), math.floor(Uptime / 60) % 60, Uptime % 60) },
		{ "World", "Day " .. os.day() .. ", " .. textutils.formatTime(os.time(), true) },
		{ "Storage", Gfx.FormatSize(fs.getFreeSpace("/")) .. " free" },
		{ "Devices", #peripheral.getNames() .. " attached" }
	})
end

function Details.redstone(X, Y, W)
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Text = "Side      In  Out", Fg = "SubText" }))
	for Index, Side in ipairs(redstone.getSides()) do
		local Row = Y + Index
		Page:Add(Ui.Label.new({ X = X, Y = Row, W = 9, Text = Side }))
		local Input = redstone.getAnalogInput(Side)
		Page:Add(Ui.Label.new({ X = X + 10, Y = Row, W = 3, Text = tostring(Input), Fg = (Input > 0) and colors.red or "SubText" }))
		Page:Add(Ui.Toggle.new({ X = X + 14, Y = Row, Value = redstone.getOutput(Side), OnChange = function(_, Value)
			redstone.setOutput(Side, Value)
		end }))
	end
end

local function MonitorDetails(Name, X, Y, W)
	local Monitor = peripheral.wrap(Name)
	local MW, MH = Monitor.getSize()
	Y = Info(X, Y, W, { { "Size", MW .. " x " .. MH }, { "Colour", Monitor.isColor() and "yes" or "no" }, { "Scale", Monitor.getTextScale and Monitor.getTextScale() or "?" } })
	Buttons(X, Y, W, {
		{ "Test Pattern", function()
			local Palette = { colors.red, colors.orange, colors.yellow, colors.lime, colors.cyan, colors.blue, colors.purple, colors.magenta }
			for Row = 1, MH do
				Monitor.setCursorPos(1, Row)
				Monitor.setBackgroundColor(Palette[(Row - 1) % #Palette + 1])
				Monitor.clearLine()
			end
			Monitor.setCursorPos(2, 2)
			Monitor.setTextColor(colors.white)
			Monitor.write("BlockOS")
		end },
		{ "Clear", function()
			Monitor.setBackgroundColor(colors.black)
			Monitor.clear()
		end },
		{ "Scale -", function() Monitor.setTextScale(math.max(.5, Monitor.getTextScale() - .5)) end },
		{ "Scale +", function() Monitor.setTextScale(math.min(5, Monitor.getTextScale() + .5)) end }
	})
end

local function ModemDetails(Name, X, Y, W)
	local Modem = peripheral.wrap(Name)
	local Lines = { { "Type", Modem.isWireless() and "Wireless" or "Wired" }, { "Rednet", rednet.isOpen(Name) and "open" or "closed" } }
	if (not Modem.isWireless() and Modem.getNamesRemote) then
		table.insert(Lines, { "Network", #Modem.getNamesRemote() .. " remote peripherals" })
	end
	Y = Info(X, Y, W, Lines)
	Buttons(X, Y, W, {
		{ rednet.isOpen(Name) and "Close Rednet" or "Open Rednet", function()
			if (rednet.isOpen(Name)) then rednet.close(Name) else rednet.open(Name) end
		end }
	})
end

local function SpeakerDetails(Name, X, Y, W)
	local Speaker = peripheral.wrap(Name)
	Y = Info(X, Y, W, { { "Type", "Speaker" } })
	Buttons(X, Y, W, {
		{ "Chime", function()
			for Index, Pitch in ipairs({ 12, 16, 19, 24 }) do
				Speaker.playNote("chime", 1, Pitch)
				if (Index < 4) then sleep(.15) end
			end
		end },
		{ "Bell", function() Speaker.playNote("bell", 1, 12) end },
		{ "Sound...", function()
			local Sound = Ui.Prompt("Play Sound", "Sound ID:", "entity.experience_orb.pickup")
			if (Sound) then Speaker.playSound(Sound) end
		end },
		{ "Stop", function() Speaker.stop() end }
	})
end

local function DriveDetails(Name, X, Y, W)
	local Lines = { { "Disk", disk.isPresent(Name) and "inserted" or "empty" } }
	if (disk.hasData(Name)) then
		table.insert(Lines, { "Label", disk.getLabel(Name) or "(none)" })
		table.insert(Lines, { "Mount", "/" .. disk.getMountPath(Name) })
		table.insert(Lines, { "Disk ID", tostring(disk.getID(Name)) })
	elseif (disk.hasAudio(Name)) then
		table.insert(Lines, { "Music", disk.getAudioTitle(Name) })
	end
	Y = Info(X, Y, W, Lines)
	local Actions = {}
	if (disk.hasData(Name)) then
		table.insert(Actions, { "Open in Finder", function() BlockOS.Launch("finder", { "/" .. disk.getMountPath(Name) }) end })
	end
	if (disk.hasAudio(Name)) then
		table.insert(Actions, { "Play", function() disk.playAudio(Name) end })
		table.insert(Actions, { "Stop", function() disk.stopAudio(Name) end })
	end
	if (disk.isPresent(Name)) then
		table.insert(Actions, { "Eject", function() disk.eject(Name) end })
	end
	Buttons(X, Y, W, Actions)
end

local function PrinterDetails(Name, X, Y, W)
	local Printer = peripheral.wrap(Name)
	Y = Info(X, Y, W, { { "Ink", Printer.getInkLevel() }, { "Paper", Printer.getPaperLevel() } })
	local function PrintLines(Title, Lines)
		if (not Printer.newPage()) then error("Add ink and paper first.", 0) end
		Printer.setPageTitle(Title)
		local PW, PH = Printer.getPageSize()
		local Row = 1
		for _, Line in ipairs(Lines) do
			for _, Piece in ipairs(Gfx.Wrap(Line, PW)) do
				if (Row > PH) then
					Printer.endPage()
					if (not Printer.newPage()) then return end
					Printer.setPageTitle(Title)
					Row = 1
				end
				Printer.setCursorPos(1, Row)
				Printer.write(Piece)
				Row = Row + 1
			end
		end
		Printer.endPage()
	end
	Buttons(X, Y, W, {
		{ "Test Page", function()
			PrintLines("BlockOS Test", { "BlockOS printer test", "", "Computer #" .. os.getComputerID(), os.date("%Y-%m-%d %H:%M"), "", "If you can read this, printing works." })
		end },
		{ "Print File...", function()
			local Path = Ui.PickFile({ Dir = "/home/Documents" })
			if (not Path) then return end
			local Lines = {}
			local Handle = fs.open(Path, "r")
			for Line in (Handle.readAll() .. "\n"):gmatch("(.-)\n") do
				table.insert(Lines, Line)
			end
			Handle.close()
			PrintLines(fs.getName(Path), Lines)
		end }
	})
end

local function ComputerDetails(Name, X, Y, W)
	local Remote = peripheral.wrap(Name)
	Y = Info(X, Y, W, { { "ID", Remote.getID() }, { "Label", Remote.getLabel() or "(none)" }, { "Running", Remote.isOn() and "yes" or "no" } })
	Buttons(X, Y, W, {
		{ "Turn On", function() Remote.turnOn() end },
		{ "Reboot", function() Remote.reboot() end },
		{ "Shut Down", function() Remote.shutdown() end, "danger" }
	})
end

local function GenericDetails(Name, X, Y, W, H)
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Text = "Methods", Fg = "SubText" }))
	local Items = {}
	local Methods = peripheral.getMethods(Name) or {}
	table.sort(Methods)
	for _, Method in ipairs(Methods) do
		table.insert(Items, { Text = Method .. "()" })
	end
	Page:Add(Ui.List.new({ X = X, Y = Y + 1, W = W, H = math.max(1, H - 2), Items = Items }))
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local SideW = (W >= 40) and 16 or 0
	local List = Page:Add(Ui.List.new({ X = 1, Y = 1, W = SideW, H = H, Bg = "Panel", SingleClick = true, Visible = SideW > 0 }))
	local Items = Entries()
	List:SetItems(Items)
	local Current
	for Index, Item in ipairs(Items) do
		if (Item.ID == SelectedID) then
			List.Selected = Index
			Current = Item
		end
	end
	if (not Current) then
		SelectedID = "computer"
		Current = Items[1]
		List.Selected = 1
	end
	List.OnActivate = function(_, _, Item)
		SelectedID = Item.ID
		Build()
	end
	local X = SideW + 2
	local ContentW = W - SideW - 2
	local Title = Current.Kind and (Current.Text .. " (" .. Current.Kind .. ")") or Current.Text
	if (SideW == 0) then
		Page:Add(Ui.Button.new({ X = 1, Y = 1, W = W, Text = "\31 " .. Title, Bg = "Panel", OnClick = function()
			local Names = {}
			for _, Item in ipairs(Items) do table.insert(Names, Item.Text) end
			local Index = Ui.Choose("Devices", Names)
			if (Index) then
				SelectedID = Items[Index].ID
				Build()
			end
		end }))
	else
		Page:Add(Ui.Label.new({ X = X, Y = 1, W = ContentW, Text = Title, Fg = "Accent" }))
	end
	local Y = 3
	if (Current.ID == "computer" or Current.ID == "redstone") then
		Details[Current.ID](X, Y, ContentW, H - 2)
	elseif (Current.Kind == "monitor") then
		MonitorDetails(Current.ID, X, Y, ContentW)
	elseif (Current.Kind == "modem") then
		ModemDetails(Current.ID, X, Y, ContentW)
	elseif (Current.Kind == "speaker") then
		SpeakerDetails(Current.ID, X, Y, ContentW)
	elseif (Current.Kind == "drive") then
		DriveDetails(Current.ID, X, Y, ContentW)
	elseif (Current.Kind == "printer") then
		PrinterDetails(Current.ID, X, Y, ContentW)
	elseif (Current.Kind == "computer" or Current.Kind == "turtle") then
		ComputerDetails(Current.ID, X, Y, ContentW)
	else
		GenericDetails(Current.ID, X, Y, ContentW, H - 2)
	end
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name)
	if (Name == "peripheral" or Name == "peripheral_detach" or Name == "disk" or Name == "disk_eject" or Name == "monitor_resize") then
		Build()
		return true
	elseif (Name == "redstone" and SelectedID == "redstone") then
		Build()
		return true
	end
	return false
end

Page:SetInterval(1, function()
	if (SelectedID ~= "computer") then return false end
	Build()
	return true
end)

Page:Run()
