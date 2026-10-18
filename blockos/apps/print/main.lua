-- Print: lays text files out on printed pages and sends them to an attached printer.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")

local Args = { ... }

-- Every CC printer page is 25 characters by 21 lines.
local PageW, PageH = 25, 21

local Page = Ui.Page.new()
local Doc = { Path = nil, Pages = {}, Title = "" }
local Copies = 1
local Shown = 1
local Scroll = 0
local PrinterName = nil
local Status = nil
local Busy = false
local TitleField
local Build

local function Printers()
	local List = {}
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "printer") then
			table.insert(List, { Name = Name, Device = peripheral.wrap(Name) })
		end
	end
	return List
end

local function CurrentPrinter()
	local List = Printers()
	for _, Printer in ipairs(List) do
		if (Printer.Name == PrinterName) then return Printer end
	end
	if (List[1]) then PrinterName = List[1].Name end
	return List[1]
end

-- Wraps one line to the page width, breaking at spaces where possible and keeping indentation.
local function WrapLine(Line, Width)
	local Rows = {}
	Line = Line:gsub("\t", "  ")
	while (#Line > Width) do
		local Space = Line:sub(1, Width + 1):match(".*() ")
		if (Space and Space > 1) then
			table.insert(Rows, Line:sub(1, Space - 1))
			Line = Line:sub(Space + 1)
		else
			table.insert(Rows, Line:sub(1, Width))
			Line = Line:sub(Width + 1)
		end
	end
	table.insert(Rows, Line)
	return Rows
end

local function Paginate(Text)
	local Pages = {}
	local Current = {}
	Text = Text:gsub("\r\n?", "\n")
	for Line in (Text .. "\n"):gmatch("(.-)\n") do
		for _, Row in ipairs(WrapLine(Line, PageW)) do
			if (#Current == PageH) then
				table.insert(Pages, Current)
				Current = {}
			end
			table.insert(Current, Row)
		end
	end
	-- Drop trailing blank lines so a final newline does not cost a sheet of paper.
	while (#Current > 0 and Current[#Current]:match("^%s*$")) do
		table.remove(Current)
	end
	if (#Current > 0 or #Pages == 0) then table.insert(Pages, Current) end
	return Pages
end

local function Load(Path)
	local Handle = Path and fs.exists(Path) and not fs.isDir(Path) and fs.open(Path, "r")
	if (not Handle) then
		Status = Path and ("Cannot open " .. fs.getName(Path)) or nil
		return false
	end
	local Text = Handle.readAll() or ""
	Handle.close()
	Doc.Path = Path
	Doc.Pages = Paginate(Text)
	Doc.Title = (fs.getName(Path):gsub("%.[^%.]+$", ""))
	Shown, Scroll = 1, 0
	Status = nil
	BlockOS.SetTitle("Print \7 " .. fs.getName(Path))
	return true
end

-- Two short lines: ink and paper levels, or why there are none.
local function PrinterStatus(Printer)
	if (not Printer) then return "No printer", "attached" end
	local Ok, Ink = pcall(Printer.Device.getInkLevel)
	local _, Paper = pcall(Printer.Device.getPaperLevel)
	if (not Ok) then return "Not responding", "" end
	return "Ink " .. tostring(Ink), "Paper " .. tostring(Paper)
end

local function PrintDocument()
	if (Busy or #Doc.Pages == 0) then return end
	local Printer = CurrentPrinter()
	if (not Printer) then
		Status = "Attach a printer next to the computer or over a wired modem."
		return
	end
	local Device = Printer.Device
	local Title = (#TitleField.Value > 0) and TitleField.Value or Doc.Title
	local Total = #Doc.Pages * Copies
	local Done = 0
	Busy = true
	for _ = 1, Copies do
		for Index, Lines in ipairs(Doc.Pages) do
			if (not Device.newPage()) then
				if (Device.getPaperLevel() == 0) then
					Status = "Out of paper. Add paper to the printer and try again."
				elseif (Device.getInkLevel() == 0) then
					Status = "Out of ink. Add a dye to the printer and try again."
				else
					Status = "The output tray is full. Take the printed pages out."
				end
				Busy = false
				return
			end
			Device.setPageTitle((#Doc.Pages > 1) and (Title .. " " .. Index .. "/" .. #Doc.Pages) or Title)
			for Row, Line in ipairs(Lines) do
				Device.setCursorPos(1, Row)
				Device.write(Line)
			end
			if (not Device.endPage()) then
				Status = "The output tray is full. Take the printed pages out."
				Busy = false
				return
			end
			Done = Done + 1
			Status = "Printing page " .. Done .. " of " .. Total .. "..."
			Page:Draw()
		end
	end
	Busy = false
	Status = "Printed " .. Total .. ((Total == 1) and " page." or " pages.")
	BlockOS.Notify("Print", Title .. " \7 " .. Total .. ((Total == 1) and " page" or " pages"), { Sound = false })
end

local function ChooseFile()
	local Path = Ui.PickFile({ Title = "Print", Dir = Doc.Path and fs.getDir(Doc.Path) or "/home" })
	if (Path and Load(Path)) then
		Build()
	elseif (Path) then
		Build()
	end
end

local function ChoosePrinter(X, Y)
	local List = Printers()
	if (#List == 0) then return end
	local Options = {}
	for _, Printer in ipairs(List) do
		table.insert(Options, { Text = Printer.Name })
	end
	local Index = Ui.ContextMenu(X, Y, Options)
	if (Index) then PrinterName = List[Index].Name end
end

local function DrawPreview(Self, T, Th)
	Gfx.Fill(T, Self.X, Self.Y, Self.W, Self.H, Th.Panel)
	local Lines = Doc.Pages[Shown]
	if (not Lines) then
		local Message = Gfx.Wrap("Choose a text file to print, or right-click one in Finder and pick Print.", Self.W - 4)
		for Row, Line in ipairs(Message) do
			Gfx.Write(T, Self.X + 2, Self.Y + Row, Line, Th.SubText, Th.Panel)
		end
		return
	end
	local PaperX = Self.X + math.max(0, math.floor((Self.W - PageW) / 2))
	for Row = 1, math.min(Self.H, PageH - Scroll) do
		local Line = Lines[Row + Scroll] or ""
		Gfx.Write(T, PaperX, Self.Y + Row - 1, Gfx.Pad(Line, PageW), colors.black, colors.white)
	end
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local SideW = 16
	local PreviewW = math.max(PageW + 2, W - SideW - 1)
	local SideX = PreviewW + 2
	local Narrow = SideX + SideW - 1 > W

	Page:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
	Page:Add(Ui.Label.new({ X = 2, Y = 1, W = W - 12, Bg = "Panel", Text = function()
		return Doc.Path and fs.getName(Doc.Path) or "No document"
	end }))
	Page:Add(Ui.Button.new({ X = W - 8, Y = 1, W = 9, Text = "Open...", Bg = "Panel", OnClick = ChooseFile }))

	Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = Narrow and W or PreviewW, H = H - 1,
		OnDraw = DrawPreview,
		OnEvent = function(_, Name, A)
			if (Name == "mouse_scroll") then
				Scroll = math.max(0, math.min(PageH - (H - 1), Scroll + A * 2))
				return true
			end
			return false
		end
	}))
	if (Narrow) then
		Page:Add(Ui.Button.new({ X = W - 8, Y = H, W = 9, Text = "Print", Style = "primary", OnClick = PrintDocument }))
		return
	end

	Page:Add(Ui.Label.new({ X = SideX, Y = 2, Text = "Printer", Fg = "SubText" }))
	local PickPrinter
	PickPrinter = Page:Add(Ui.Button.new({ X = SideX, Y = 3, W = SideW, Text = function()
		local Printer = CurrentPrinter()
		return Gfx.Truncate(Printer and Printer.Name or "None", SideW - 3) .. " \31"
	end, OnClick = function() ChoosePrinter(PickPrinter.X, PickPrinter.Y + 1) end }))
	Page:Add(Ui.Label.new({ X = SideX, Y = 4, W = SideW, Fg = "SubText", Text = function()
		return (PrinterStatus(CurrentPrinter()))
	end }))
	Page:Add(Ui.Label.new({ X = SideX, Y = 5, W = SideW, Fg = "SubText", Text = function()
		return select(2, PrinterStatus(CurrentPrinter()))
	end }))

	Page:Add(Ui.Label.new({ X = SideX, Y = 6, Text = "Title", Fg = "SubText" }))
	TitleField = Page:Add(Ui.Input.new({ X = SideX, Y = 7, W = SideW, Value = Doc.Title, Placeholder = "Page title", MaxLength = 30 }))

	Page:Add(Ui.Label.new({ X = SideX, Y = 9, Text = "Copies", Fg = "SubText" }))
	Page:Add(Ui.Button.new({ X = SideX + 8, Y = 9, W = 3, Text = "-", OnClick = function() Copies = math.max(1, Copies - 1) end }))
	Page:Add(Ui.Label.new({ X = SideX + 11, Y = 9, W = 3, Align = "center", Text = function() return tostring(Copies) end }))
	Page:Add(Ui.Button.new({ X = SideX + 14, Y = 9, W = 2, Text = "+", OnClick = function() Copies = math.min(64, Copies + 1) end }))

	Page:Add(Ui.Button.new({ X = SideX, Y = 11, W = 3, Text = "\17", OnClick = function()
		Shown = math.max(1, Shown - 1)
		Scroll = 0
	end }))
	Page:Add(Ui.Label.new({ X = SideX + 3, Y = 11, W = SideW - 6, Align = "center", Text = function()
		return "Page " .. math.min(Shown, #Doc.Pages) .. "/" .. #Doc.Pages
	end }))
	Page:Add(Ui.Button.new({ X = SideX + SideW - 3, Y = 11, W = 3, Text = "\16", OnClick = function()
		Shown = math.min(#Doc.Pages, Shown + 1)
		Scroll = 0
	end }))

	Page:Add(Ui.Button.new({ X = SideX, Y = 13, W = SideW, Text = "Print", Style = "primary", OnClick = PrintDocument }))
	Page:Add(Ui.Label.new({ X = SideX, Y = 14, W = SideW, H = math.max(1, H - 13), Fg = "SubText", Text = function()
		return Status or ""
	end }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "peripheral" or Name == "peripheral_detach") then
		return true
	elseif (Name == "blockos_open" and A) then
		if (Load(A)) then Build() end
		return true
	end
	return false
end

Load(Args[1])
Page:Run()
