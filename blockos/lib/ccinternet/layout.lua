-- Lays out a parsed .ccmd document for a given screen size.
-- The result is a list of blit rows plus clickable regions, so drawing is just term.blit per row.
-- Vendored from https://github.com/tamayaren/ccinternet (lib/layout.lua), shared by Savannah and CCDream.

local Ccmd = BlockOS.Require("ccinternet/ccmd")

local Layout = {}

local function Clamp(Value, Low, High)
	if (Value < Low) then return Low end
	if (Value > High) then return High end
	return Value
end

-- Converts spans into cells { Ch, Fg, Bg, Link }.
local function SpanCells(Spans, Fg, Bg, LinkFg)
	local Cells = {}
	for _, Span in ipairs(Spans) do
		local Link = Span.Link and { Kind = "link", Href = Span.Href } or nil
		local SpanFg = Span.Fg or (Link and LinkFg) or Fg
		local SpanBg = Span.Bg or Bg
		local Text = Span.Text:gsub("\t", "    ")
		for Index = 1, #Text do
			Cells[#Cells + 1] = { Ch = Text:sub(Index, Index), Fg = SpanFg, Bg = SpanBg, Link = Link }
		end
	end
	return Cells
end

local function TextCells(Text, Fg, Bg)
	local Cells = {}
	for Index = 1, #Text do
		Cells[#Cells + 1] = { Ch = Text:sub(Index, Index), Fg = Fg, Bg = Bg }
	end
	return Cells
end

local function Slice(Cells, First, Last)
	local Result = {}
	for Index = First, Last do Result[#Result + 1] = Cells[Index] end
	return Result
end

local function TrimEnd(Cells)
	while (#Cells > 0 and Cells[#Cells].Ch == " " and not Cells[#Cells].Link) do Cells[#Cells] = nil end
	return Cells
end

-- Word-wraps cells into rows no wider than Width.
local function Wrap(Cells, Width)
	local Rows = {}
	local Count = #Cells
	if (Count == 0) then return { {} } end
	local Start = 1
	while (Start <= Count) do
		if (Count - Start + 1 <= Width) then
			Rows[#Rows + 1] = Slice(Cells, Start, Count)
			break
		end
		local Break
		for Index = Start + Width, Start + 1, -1 do
			if (Cells[Index].Ch == " ") then
				Break = Index
				break
			end
		end
		if (Break) then
			Rows[#Rows + 1] = TrimEnd(Slice(Cells, Start, Break - 1))
			Start = Break + 1
			while (Cells[Start] and Cells[Start].Ch == " ") do Start = Start + 1 end
		else
			Rows[#Rows + 1] = Slice(Cells, Start, Start + Width - 1)
			Start = Start + Width
		end
	end
	return Rows
end

local function NewCanvas(Width, Fg, Bg)
	return { Width = Width, Text = {}, Fg = {}, Bg = {}, DefaultFg = Fg, DefaultBg = Bg }
end

local function Put(Canvas, X, Cell)
	if (X < 1 or X > Canvas.Width) then return end
	Canvas.Text[X] = Cell.Ch
	Canvas.Fg[X] = Cell.Fg
	Canvas.Bg[X] = Cell.Bg
end

local function Finish(Canvas)
	local Text, Fg, Bg = {}, {}, {}
	for X = 1, Canvas.Width do
		Text[X] = Canvas.Text[X] or " "
		Fg[X] = Canvas.Fg[X] or Canvas.DefaultFg
		Bg[X] = Canvas.Bg[X] or Canvas.DefaultBg
	end
	return { table.concat(Text), table.concat(Fg), table.concat(Bg) }
end

local function AlignOffset(Align, Used, Width)
	if (Align == "center") then return math.floor((Width - Used) / 2) end
	if (Align == "right") then return Width - Used end
	return 0
end

-- Places cells on a canvas starting at X and records link regions on row Y.
local function PlaceCells(Canvas, Regions, Cells, X, Y)
	local Open
	for Index, Cell in ipairs(Cells) do
		local CX = X + Index - 1
		Put(Canvas, CX, Cell)
		if (Cell.Link and CX >= 1 and CX <= Canvas.Width) then
			if (Open and Open.Source == Cell.Link and Open.X2 == CX - 1) then
				Open.X2 = CX
			else
				Open = { Kind = Cell.Link.Kind, Href = Cell.Link.Href, Source = Cell.Link, Y = Y, X1 = CX, X2 = CX }
				Regions[#Regions + 1] = Open
			end
		end
	end
end

local Builder = {}
Builder.__index = Builder

function Builder:Row(Bg)
	return NewCanvas(self.Width, self.Fg, Bg or self.Bg)
end

function Builder:Push(Canvas)
	self.Rows[#self.Rows + 1] = Finish(Canvas)
	return #self.Rows
end

function Builder:Blank(Bg)
	self:Push(self:Row(Bg))
end

function Builder:Text(Block)
	local Fg = Block.TextColor or self.Fg
	local Bg = Block.Color or self.Bg
	for _, Spans in ipairs(Block.Lines) do
		local Cells = SpanCells(Spans, Fg, Bg, self.LinkFg)
		for _, Line in ipairs(Wrap(Cells, self.Width)) do
			local Canvas = self:Row(Bg)
			local Offset = AlignOffset(Block.Align, #Line, self.Width)
			PlaceCells(Canvas, self.Regions, Line, Offset + 1, #self.Rows + 1)
			self:Push(Canvas)
		end
	end
end

local function CellsWidth(Spans)
	local Width = 0
	for _, Span in ipairs(Spans or {}) do Width = Width + #Span.Text end
	return Width
end

function Builder:Table(Block)
	local Columns = Block.Columns
	if (Columns == 0) then return end
	local Widths = {}
	local function Measure(Row)
		for Column = 1, Columns do
			local Width = CellsWidth(Row[Column])
			if (Width > (Widths[Column] or 0)) then Widths[Column] = Width end
		end
	end
	for Column = 1, Columns do Widths[Column] = 1 end
	if (Block.Header) then Measure(Block.Header) end
	for _, Row in ipairs(Block.Rows) do Measure(Row) end

	-- One space before every column and one after the last.
	local Available = math.max(Columns, self.Width - Columns - 1)
	local Total = 0
	for Column = 1, Columns do Total = Total + Widths[Column] end
	while (Total > Available) do
		local Widest = 1
		for Column = 2, Columns do
			if (Widths[Column] > Widths[Widest]) then Widest = Column end
		end
		if (Widths[Widest] <= 1) then break end
		Widths[Widest] = Widths[Widest] - 1
		Total = Total - 1
	end
	local TableWidth = math.min(self.Width, Total + Columns + 1)

	local TextFg = Block.TextColor or self.Fg
	local BodyBg = Block.Color or self.Bg

	local function Emit(Row, Fg, Bg, IsHeader)
		local Wrapped = {}
		local Height = 1
		for Column = 1, Columns do
			local Cells = SpanCells(Row[Column] or {}, Fg, Bg, IsHeader and Fg or self.LinkFg)
			Wrapped[Column] = Wrap(Cells, Widths[Column])
			if (#Wrapped[Column] > Height) then Height = #Wrapped[Column] end
		end
		for Line = 1, Height do
			local Canvas = self:Row(self.Bg)
			for X = 1, TableWidth do Put(Canvas, X, { Ch = " ", Fg = Fg, Bg = Bg }) end
			local X = 2
			for Column = 1, Columns do
				local Cells = Wrapped[Column][Line] or {}
				local Offset = AlignOffset(Block.Align[Column], #Cells, Widths[Column])
				PlaceCells(Canvas, self.Regions, Cells, X + Offset, #self.Rows + 1)
				X = X + Widths[Column] + 1
			end
			self:Push(Canvas)
		end
	end

	if (Block.Header) then
		Emit(Block.Header, Block.HeaderTextColor or TextFg, Block.HeaderColor, true)
	end
	for _, Row in ipairs(Block.Rows) do
		Emit(Row, TextFg, BodyBg, false)
	end
end

function Builder:Image(Block)
	local Picture = self.Images and self.Images(Block.Src)
	if (type(Picture) ~= "table") then
		local Label = Picture == false and ("[image failed: " .. (Block.Alt or Block.Src) .. "]") or ("[" .. (Block.Alt or Block.Src) .. "]")
		local Cells = TextCells(Label:sub(1, self.Width), "7", self.Bg)
		local Canvas = self:Row()
		PlaceCells(Canvas, self.Regions, Cells, AlignOffset(Block.Align, #Cells, self.Width) + 1, #self.Rows + 1)
		self:Push(Canvas)
		return
	end
	local Width = math.min(Picture.W, self.Width)
	local Offset = AlignOffset(Block.Align, Width, self.Width)
	for _, Row in ipairs(Picture.Rows) do
		local Canvas = self:Row()
		for X = 1, Width do
			local Bg = Row[3]:sub(X, X)
			if (Bg == " ") then Bg = self.Bg end
			Put(Canvas, Offset + X, { Ch = Row[1]:sub(X, X), Fg = Row[2]:sub(X, X), Bg = Bg })
		end
		self:Push(Canvas)
	end
end

-- Text shown inside an input field.
function Layout.InputText(Input, Value)
	if (Input.Kind == "file") then
		if (type(Value) == "table") then
			local Count = 0
			for _ in pairs(Value) do Count = Count + 1 end
			return Count .. (Count == 1 and " file" or " files"), false
		end
		return Input.Placeholder or "Choose...", true
	end
	Value = tostring(Value or "")
	if (Value == "") then return Input.Placeholder or "", true end
	if (Input.Kind == "password") then return string.rep("*", #Value), false end
	return Value, false
end

function Builder:Input(Block)
	if (Block.Kind == "hidden") then return end
	local Value = self.State[Block.Id]
	if (Value == nil) then Value = Block.Value end
	local Label = Block.Label and (Block.Label .. " ") or ""
	local FieldWidth = math.min(Block.Width, self.Width)
	if (#Label + FieldWidth > self.Width) then
		if (#Label + 4 <= self.Width) then
			FieldWidth = self.Width - #Label
		else
			local Canvas = self:Row()
			PlaceCells(Canvas, self.Regions, TextCells(Block.Label:sub(1, self.Width), self.Fg, self.Bg), 1, #self.Rows + 1)
			self:Push(Canvas)
			Label = ""
		end
	end
	local Focused = self.Focus == Block.Id
	local Shown, IsPlaceholder = Layout.InputText(Block, Value)
	if (#Shown > FieldWidth) then
		Shown = Focused and Shown:sub(-FieldWidth) or Shown:sub(1, FieldWidth)
	end
	local FieldBg = Focused and "0" or Block.Color
	local FieldFg = IsPlaceholder and "7" or Block.TextColor
	local Canvas = self:Row()
	local Y = #self.Rows + 1
	PlaceCells(Canvas, self.Regions, TextCells(Label, self.Fg, self.Bg), 1, Y)
	local Field = TextCells(Shown .. string.rep(" ", FieldWidth - #Shown), FieldFg, FieldBg)
	PlaceCells(Canvas, self.Regions, Field, #Label + 1, Y)
	self.Regions[#self.Regions + 1] = { Kind = "input", Input = Block, Y = Y, X1 = #Label + 1, X2 = #Label + FieldWidth }
	self:Push(Canvas)
end

function Builder:Button(Block)
	local Text = " " .. Block.Text .. " "
	Text = Text:sub(1, self.Width)
	local Canvas = self:Row()
	local X = AlignOffset(Block.Align, #Text, self.Width) + 1
	local Y = #self.Rows + 1
	PlaceCells(Canvas, self.Regions, TextCells(Text, Block.TextColor, Block.Color), X, Y)
	self.Regions[#self.Regions + 1] = { Kind = "button", Button = Block, Href = Block.Href, Y = Y, X1 = X, X2 = X + #Text - 1 }
	self:Push(Canvas)
end

function Builder:Blocks(Blocks)
	for _, Block in ipairs(Blocks) do
		if (Block.Type == "text") then self:Text(Block)
		elseif (Block.Type == "break") then self:Blank()
		elseif (Block.Type == "table") then self:Table(Block)
		elseif (Block.Type == "image") then self:Image(Block)
		elseif (Block.Type == "input") then self:Input(Block)
		elseif (Block.Type == "button") then self:Button(Block)
		elseif (Block.Type == "form") then self:Blocks(Block.Blocks)
		end
	end
end

local function BuildTopbar(Bar, Width, Height)
	local Rows, Regions = {}, {}
	local Canvas = NewCanvas(Width, Bar.TextColor, Bar.Color)
	local X = 2
	local Used = false
	local MaxRows = math.max(1, math.floor(Height / 2))
	for _, Spans in ipairs(Bar.Items) do
		local Cells = SpanCells(Spans, Bar.TextColor, Bar.Color, Bar.TextColor)
		if (Used and X + #Cells - 1 > Width) then
			if (#Rows + 1 >= MaxRows) then break end
			Rows[#Rows + 1] = Finish(Canvas)
			Canvas = NewCanvas(Width, Bar.TextColor, Bar.Color)
			X = 2
		end
		PlaceCells(Canvas, Regions, Cells, X, #Rows + 1)
		X = X + #Cells + 2
		Used = true
	end
	Rows[#Rows + 1] = Finish(Canvas)
	return { Side = "top", Size = #Rows, Rows = Rows, Regions = Regions }
end

local function BuildSidebar(Bar, Width, Height)
	local Items = {}
	local Widest = 1
	for _, Spans in ipairs(Bar.Items) do
		local Cells = SpanCells(Spans, Bar.TextColor, Bar.Color, Bar.TextColor)
		Items[#Items + 1] = Cells
		if (#Cells > Widest) then Widest = #Cells end
	end
	local Size = Clamp(Widest + 2, 3, math.max(3, math.floor(Width / 3)))
	local Rows, Regions = {}, {}
	for Y = 1, Height do
		local Canvas = NewCanvas(Size, Bar.TextColor, Bar.Color)
		local Cells = Items[Y - 1]
		if (Cells) then PlaceCells(Canvas, Regions, Slice(Cells, 1, math.min(#Cells, Size - 2)), 2, Y) end
		Rows[Y] = Finish(Canvas)
	end
	return { Side = "left", Size = Size, Rows = Rows, Regions = Regions }
end

-- Builds a page for an area Width x Height.
-- Options: Images = function(Src) -> image | false (failed) | nil (not loaded), State = { [InputId] = value }, Focus = InputId.
function Layout.Build(Doc, Width, Height, Options)
	Options = Options or {}
	local Page = { Doc = Doc, Width = Width, Height = Height, ViewX = 1, ViewY = 1, ViewW = Width, ViewH = Height }
	if (Doc.Topbar) then
		if (Doc.Topbar.Layout == "vertical") then
			Page.Bar = BuildSidebar(Doc.Topbar, Width, Height)
			Page.ViewX = Page.Bar.Size + 1
			Page.ViewW = Width - Page.Bar.Size
		else
			Page.Bar = BuildTopbar(Doc.Topbar, Width, Height)
			Page.ViewY = Page.Bar.Size + 1
			Page.ViewH = Height - Page.Bar.Size
		end
	end
	local Build = setmetatable({
		Width = math.max(1, Page.ViewW),
		Fg = Doc.TextColor or Ccmd.Defaults.TextColor,
		Bg = Doc.Background or Ccmd.Defaults.Background,
		LinkFg = Doc.LinkColor or Ccmd.Defaults.LinkColor,
		Images = Options.Images,
		State = Options.State or {},
		Focus = Options.Focus,
		Rows = {},
		Regions = {}
	}, Builder)
	Build:Blocks(Doc.Blocks)
	Page.Rows = Build.Rows
	Page.Regions = Build.Regions
	Page.Background = Build.Bg
	Page.MaxScroll = math.max(0, #Build.Rows - Page.ViewH)
	return Page
end

-- Draws the page on a terminal-like target (usually a window the size of the page area).
function Layout.Draw(Page, Target, Scroll)
	Scroll = Clamp(Scroll or 0, 0, Page.MaxScroll)
	local Blank = { string.rep(" ", Page.ViewW), string.rep("0", Page.ViewW), string.rep(Page.Background, Page.ViewW) }
	for Y = 1, Page.ViewH do
		local Row = Page.Rows[Scroll + Y] or Blank
		Target.setCursorPos(Page.ViewX, Page.ViewY + Y - 1)
		Target.blit(Row[1], Row[2], Row[3])
	end
	if (Page.Bar) then
		for Index, Row in ipairs(Page.Bar.Rows) do
			Target.setCursorPos(1, Index)
			Target.blit(Row[1], Row[2], Row[3])
		end
	end
end

-- Returns the region under page-area coordinates X, Y.
function Layout.Hit(Page, X, Y, Scroll)
	if (Page.Bar) then
		for _, Region in ipairs(Page.Bar.Regions) do
			if (Region.Y == Y and X >= Region.X1 and X <= Region.X2) then return Region end
		end
	end
	if (X < Page.ViewX or Y < Page.ViewY or Y >= Page.ViewY + Page.ViewH) then return nil end
	local CX = X - Page.ViewX + 1
	local CY = Y - Page.ViewY + 1 + (Scroll or 0)
	for _, Region in ipairs(Page.Regions) do
		if (Region.Y == CY and CX >= Region.X1 and CX <= Region.X2) then return Region end
	end
	return nil
end

-- Returns page-area coordinates of a region, or nil when it is scrolled out of view.
function Layout.RegionPosition(Page, Region, Scroll)
	local Y = Region.Y - (Scroll or 0) + Page.ViewY - 1
	if (Y < Page.ViewY or Y >= Page.ViewY + Page.ViewH) then return nil end
	return Region.X1 + Page.ViewX - 1, Y
end

-- Scroll needed so a content row is visible.
function Layout.ScrollTo(Page, Row, Scroll)
	if (Row <= Scroll) then return Clamp(Row - 1, 0, Page.MaxScroll) end
	if (Row > Scroll + Page.ViewH) then return Clamp(Row - Page.ViewH, 0, Page.MaxScroll) end
	return Scroll
end

-- Finds the region of an input by its Id.
function Layout.InputRegion(Page, Id)
	for _, Region in ipairs(Page.Regions) do
		if (Region.Kind == "input" and Region.Input.Id == Id) then return Region end
	end
	return nil
end

return Layout
