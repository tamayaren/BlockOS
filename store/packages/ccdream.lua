-- CCDream: an editor for ccinternet websites (.ccmd pages) from the BlockOS App Store.
-- Syntax highlighting, a live preview panel, a file browser for the site's folder, snippets
-- for every ccmd block and publishing straight to a ccinternet core through domain://.
-- Args: a .ccmd file or a site folder to open.

local Ui = BlockOS.Require("ui")

if (not fs.exists("/blockos/lib/ccinternet/layout.lua")) then
	Ui.Alert("CCDream", "CCDream needs BlockOS 1.6.0 or later. Update BlockOS in Settings > Software Update, then open CCDream again.")
	return
end

local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Theme = BlockOS.Require("theme")
local Ccmd = BlockOS.Require("ccinternet/ccmd")
local Layout = BlockOS.Require("ccinternet/layout")
local Image = BlockOS.Require("ccinternet/image")
local Protocol = BlockOS.Require("ccinternet/protocol")
local Site = BlockOS.Require("ccinternet/site")
local Tasks = BlockOS.Load("/blockos/lib/tasks.lua")

local Args = { ... }
local Page = Ui.Page.new()
local Modifiers = Ui.Modifiers

local C = {
	DataPath = "/blockos/data/ccdream.dat",
	SitesDir = "/home/Sites",
	PreviewDelay = 0.35,
	MaxUpload = 125000,
	Indent = "  "
}

-- The open document.
local D = {
	Lines = { "" }, X = 1, Y = 1, ScrollX = 0, ScrollY = 0, ScrollRow = 0,
	Path = nil, Modified = false, Anchor = nil, Undo = {}, Redo = {},
	Version = 0, LastKind = nil, LastTime = 0
}

-- Project (the site folder), preview and window state.
local P = { Root = nil, Site = nil, Expanded = {}, Items = {} }
local V = { Mode = "split", ShowFiles = true, Scroll = 0, Version = -1, ChangedAt = 0, Images = {}, Message = nil, MessageAt = 0, Find = "", Busy = nil }
local S = { Data = {} }
local W = {} -- widgets

local Ed = {}   -- text editing
local HL = {}   -- syntax highlighting
local PV = {}   -- preview
local FB = {}   -- file browser
local PJ = {}   -- project and files
local Menu = {} -- menus and snippets

local function Say(Text)
	V.Message, V.MessageAt = Text, os.clock()
	Page:Invalidate()
end

local function SaveData()
	Config.Write(C.DataPath, S.Data)
end

local function ReadText(Path)
	return Site.ReadFile(Path)
end

--
-- Text model
--

local function DisplayWidth(Line, Upto)
	local Width = 0
	for Index = 1, math.min(Upto, #Line) do
		Width = Width + ((Line:sub(Index, Index) == "\t") and 2 or 1)
	end
	return Width
end

local function CharFromDisplay(Line, Column)
	local Width = 0
	for Index = 1, #Line do
		local Step = (Line:sub(Index, Index) == "\t") and 2 or 1
		if (Width + Step > Column) then return Index end
		Width = Width + Step
	end
	return #Line + 1
end

function Ed.Changed()
	D.Modified = true
	D.Version = D.Version + 1
	V.ChangedAt = os.clock()
end

function Ed.Text()
	return table.concat(D.Lines, "\n")
end

function Ed.SetText(Text)
	D.Lines = {}
	for Line in (tostring(Text):gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
		D.Lines[#D.Lines + 1] = Line
	end
	if (#D.Lines > 1 and D.Lines[#D.Lines] == "") then table.remove(D.Lines) end
	if (#D.Lines == 0) then D.Lines = { "" } end
	D.X, D.Y, D.ScrollX, D.ScrollY, D.ScrollRow = 1, 1, 0, 0, 0
	D.Anchor, D.Undo, D.Redo = nil, {}, {}
	D.Modified = false
	D.Version = D.Version + 1
	V.ChangedAt = 0
end

function Ed.Clamp()
	D.Y = math.max(1, math.min(D.Y, #D.Lines))
	D.X = math.max(1, math.min(D.X, #D.Lines[D.Y] + 1))
end

function Ed.Range()
	if (not D.Anchor) then return nil end
	local AX, AY, BX, BY = D.Anchor.X, D.Anchor.Y, D.X, D.Y
	if (AY > BY or (AY == BY and AX > BX)) then AX, AY, BX, BY = BX, BY, AX, AY end
	if (AX == BX and AY == BY) then return nil end
	return AX, AY, BX, BY
end

function Ed.Selected()
	local AX, AY, BX, BY = Ed.Range()
	if (not AX) then return nil end
	if (AY == BY) then return D.Lines[AY]:sub(AX, BX - 1) end
	local Parts = { D.Lines[AY]:sub(AX) }
	for Line = AY + 1, BY - 1 do Parts[#Parts + 1] = D.Lines[Line] end
	Parts[#Parts + 1] = D.Lines[BY]:sub(1, BX - 1)
	return table.concat(Parts, "\n")
end

function Ed.DeleteSelection()
	local AX, AY, BX, BY = Ed.Range()
	D.Anchor = nil
	if (not AX) then return false end
	local Head, Tail = D.Lines[AY]:sub(1, AX - 1), D.Lines[BY]:sub(BX)
	for _ = AY + 1, BY do table.remove(D.Lines, AY + 1) end
	D.Lines[AY] = Head .. Tail
	D.X, D.Y = AX, AY
	Ed.Changed()
	return true
end

function Ed.Insert(Text)
	Ed.DeleteSelection()
	Text = tostring(Text):gsub("\r\n?", "\n")
	local Line = D.Lines[D.Y]
	local Head, Tail = Line:sub(1, D.X - 1), Line:sub(D.X)
	local Pieces = {}
	for Piece in (Text .. "\n"):gmatch("(.-)\n") do Pieces[#Pieces + 1] = Piece end
	if (#Pieces == 1) then
		D.Lines[D.Y] = Head .. Pieces[1] .. Tail
		D.X = D.X + #Pieces[1]
	else
		D.Lines[D.Y] = Head .. Pieces[1]
		for Index = 2, #Pieces do table.insert(D.Lines, D.Y + Index - 1, Pieces[Index]) end
		local Last = D.Y + #Pieces - 1
		D.X = #D.Lines[Last] + 1
		D.Lines[Last] = D.Lines[Last] .. Tail
		D.Y = Last
	end
	Ed.Changed()
end

function Ed.PushUndo(Kind)
	local Now = os.clock()
	if (Kind == "type" and D.LastKind == "type" and Now - D.LastTime < 1.5) then
		D.LastTime = Now
		return
	end
	table.insert(D.Undo, { Text = Ed.Text(), X = D.X, Y = D.Y })
	if (#D.Undo > 100) then table.remove(D.Undo, 1) end
	D.Redo = {}
	D.LastKind, D.LastTime = Kind, Now
end

function Ed.UndoStep(Reverse)
	local From, To = D.Undo, D.Redo
	if (Reverse) then From, To = D.Redo, D.Undo end
	local Shot = table.remove(From)
	if (not Shot) then return end
	table.insert(To, { Text = Ed.Text(), X = D.X, Y = D.Y })
	local Undo, Redo, Path = D.Undo, D.Redo, D.Path
	local ScrollX, ScrollY, ScrollRow = D.ScrollX, D.ScrollY, D.ScrollRow
	Ed.SetText(Shot.Text)
	D.Undo, D.Redo, D.Path = Undo, Redo, Path
	D.X, D.Y, D.ScrollX, D.ScrollY, D.ScrollRow = Shot.X, Shot.Y, ScrollX, ScrollY, ScrollRow
	D.LastKind = nil
	Ed.Changed()
end

--
-- Word wrap: the view starts D.ScrollRow visual rows into line D.ScrollY + 1.
--

-- Display columns where each visual row of a line starts, breaking after the last space that fits.
function Ed.WrapStarts(Display, Width)
	local Starts = { 0 }
	local Position = 0
	while (#Display - Position >= Width) do
		local Break = Display:sub(Position + 1, Position + Width):match("^.*%S *() ")
		Position = Position + (Break or Width)
		Starts[#Starts + 1] = Position
	end
	return Starts
end

-- The gutter grows with the line count, so keep it current between draws.
function Ed.Gutter()
	local Box = W.Editor
	if (Box) then Box.Gutter = #tostring(#D.Lines) + 2 end
	return Box and Box.Gutter or 3
end

function Ed.WrapWidth()
	return math.max(2, W.Editor and (W.Editor.W - Ed.Gutter()) or 2)
end

function Ed.LineStarts(Index)
	return Ed.WrapStarts((D.Lines[Index]:gsub("\t", "  ")), Ed.WrapWidth())
end

-- The visual row (from 0) of the cursor within its line, and its column within that row.
function Ed.CursorRow()
	local Starts = Ed.LineStarts(D.Y)
	local Column = DisplayWidth(D.Lines[D.Y], D.X - 1)
	local Row = 0
	for Index = 2, #Starts do
		if (Starts[Index] <= Column) then Row = Index - 1 end
	end
	return Row, Column - Starts[Row + 1]
end

-- Moves a (line, row) position by Delta visual rows, stopping at the ends of the document.
function Ed.StepRows(Index, Row, Delta)
	while (Delta < 0) do
		if (Row > 0) then
			Row = Row - 1
		elseif (Index > 1) then
			Index = Index - 1
			Row = #Ed.LineStarts(Index) - 1
		else
			break
		end
		Delta = Delta + 1
	end
	while (Delta > 0) do
		if (Row < #Ed.LineStarts(Index) - 1) then
			Row = Row + 1
		elseif (Index < #D.Lines) then
			Index, Row = Index + 1, 0
		else
			break
		end
		Delta = Delta - 1
	end
	return Index, Row
end

-- Visual rows from the top of the view down to the cursor: -1 when it is above, at most Limit.
function Ed.CursorOffset(Limit)
	local Row = Ed.CursorRow()
	if (D.Y - 1 < D.ScrollY or (D.Y - 1 == D.ScrollY and Row < D.ScrollRow)) then return -1 end
	local Rows = Row - D.ScrollRow
	for Index = D.ScrollY + 1, D.Y - 1 do
		Rows = Rows + #Ed.LineStarts(Index)
		if (Rows >= Limit) then return Limit end
	end
	return Rows
end

-- Keeps the cursor on screen.
function Ed.Ensure()
	Ed.Clamp()
	local Box = W.Editor
	if (not Box or not Box.Visible) then return end
	local ViewW, ViewH = Box.W - Ed.Gutter(), Box.H
	if (V.Wrap) then
		D.ScrollX = 0
		D.ScrollY = math.max(0, math.min(D.ScrollY, #D.Lines - 1))
		D.ScrollRow = math.min(D.ScrollRow, #Ed.LineStarts(D.ScrollY + 1) - 1)
		local Offset = Ed.CursorOffset(ViewH)
		if (Offset < 0) then
			D.ScrollY, D.ScrollRow = D.Y - 1, (Ed.CursorRow())
		elseif (Offset >= ViewH) then
			local Top, Row = Ed.StepRows(D.Y, (Ed.CursorRow()), 1 - ViewH)
			D.ScrollY, D.ScrollRow = Top - 1, Row
		end
		return
	end
	if (D.Y <= D.ScrollY) then D.ScrollY = D.Y - 1 end
	if (D.Y > D.ScrollY + ViewH) then D.ScrollY = D.Y - ViewH end
	local Column = DisplayWidth(D.Lines[D.Y], D.X - 1)
	if (Column < D.ScrollX) then D.ScrollX = math.max(0, Column - 4) end
	if (Column >= D.ScrollX + ViewW - 1) then D.ScrollX = Column - ViewW + 2 end
end

-- Inserts a block of text on its own lines at the cursor.
function Ed.InsertBlock(Text)
	Ed.PushUndo("edit")
	local Before = D.Lines[D.Y]:sub(1, D.X - 1)
	if (Before:match("%S")) then
		D.X = #D.Lines[D.Y] + 1
		Text = "\n" .. Text
	end
	Ed.Insert(Text)
	Ed.Ensure()
end

-- Wraps the selection (or inserts at the cursor) with Open and Close.
function Ed.Wrap(Open, Close, Placeholder)
	Ed.PushUndo("edit")
	local Selected = Ed.Selected() or Placeholder or ""
	Ed.Insert(Open .. Selected .. Close)
	if (#Selected > 0 and not Selected:find("\n")) then
		D.Anchor = { X = D.X - #Close - #Selected, Y = D.Y }
		D.X = D.X - #Close
	end
	Ed.Ensure()
end

function Ed.Move(Key)
	local Line = D.Lines[D.Y]
	local ViewH = W.Editor and W.Editor.H or 10
	if (Key == keys.left) then
		if (Modifiers.Ctrl) then
			local Position = Line:sub(1, D.X - 1):find("[%w_]+[^%w_]*$") or 1
			D.X = (Position == D.X) and math.max(1, D.X - 1) or Position
		elseif (D.X > 1) then
			D.X = D.X - 1
		elseif (D.Y > 1) then
			D.Y = D.Y - 1
			D.X = #D.Lines[D.Y] + 1
		end
	elseif (Key == keys.right) then
		if (Modifiers.Ctrl) then
			local _, Finish = Line:find("^[^%w_]*[%w_]*", D.X)
			D.X = (Finish or #Line) + 1
		elseif (D.X <= #Line) then
			D.X = D.X + 1
		elseif (D.Y < #D.Lines) then
			D.Y, D.X = D.Y + 1, 1
		end
	elseif (Key == keys.up or Key == keys.down or Key == keys.pageUp or Key == keys.pageDown) then
		local Column = DisplayWidth(Line, D.X - 1)
		local Step = ({ [keys.up] = -1, [keys.down] = 1, [keys.pageUp] = -ViewH, [keys.pageDown] = ViewH })[Key]
		if (V.Wrap) then
			local Row, Offset = Ed.CursorRow()
			local TargetY, TargetRow = Ed.StepRows(D.Y, Row, Step)
			local Starts = Ed.LineStarts(TargetY)
			Column = Starts[TargetRow + 1] + Offset
			if (Starts[TargetRow + 2]) then Column = math.min(Column, Starts[TargetRow + 2] - 1) end
			D.Y = TargetY
		else
			D.Y = math.max(1, math.min(#D.Lines, D.Y + Step))
		end
		D.X = CharFromDisplay(D.Lines[D.Y], Column)
	elseif (Key == keys.home) then
		if (Modifiers.Ctrl) then
			D.X, D.Y = 1, 1
		else
			local Indent = #Line:match("^[ \t]*") + 1
			D.X = (D.X == Indent) and 1 or Indent
		end
	elseif (Key == keys["end"]) then
		if (Modifiers.Ctrl) then D.Y = #D.Lines end
		D.X = #D.Lines[D.Y] + 1
	else
		return false
	end
	return true
end

-- Container tags close themselves when their opening tag is typed.
local AutoClose = { topbar = true, p = true, table = true, form = true }

function Ed.Type(Char)
	Ed.PushUndo(Char == " " and "space" or "type")
	Ed.Insert(Char)
	if (Char == ">") then
		local Before = D.Lines[D.Y]:sub(1, D.X - 1)
		local Name = Before:match("<(%a+)[^<>]*>$")
		if (Name and AutoClose[Name:lower()] and not Before:match("/>$") and not D.Lines[D.Y]:sub(D.X):find("</" .. Name, 1, true)) then
			local X = D.X
			Ed.Insert("</" .. Name:lower() .. ">")
			D.X = X
		end
	end
end

function Ed.NewLine()
	Ed.PushUndo("edit")
	local Indent = D.Lines[D.Y]:match("^[ \t]*")
	Ed.Insert("\n" .. Indent:sub(1, D.X - 1))
end

function Ed.Backspace()
	Ed.PushUndo("delete")
	if (Ed.DeleteSelection()) then return end
	local Line = D.Lines[D.Y]
	if (D.X > 1) then
		local Unit = C.Indent
		if (Line:sub(1, D.X - 1):match("^%s+$") and Line:sub(D.X - #Unit, D.X - 1) == Unit) then
			D.Lines[D.Y] = Line:sub(1, D.X - #Unit - 1) .. Line:sub(D.X)
			D.X = D.X - #Unit
		else
			D.Lines[D.Y] = Line:sub(1, D.X - 2) .. Line:sub(D.X)
			D.X = D.X - 1
		end
	elseif (D.Y > 1) then
		local Previous = D.Lines[D.Y - 1]
		D.Lines[D.Y - 1] = Previous .. Line
		table.remove(D.Lines, D.Y)
		D.Y, D.X = D.Y - 1, #Previous + 1
	else
		return
	end
	Ed.Changed()
end

function Ed.Delete()
	Ed.PushUndo("delete")
	if (Ed.DeleteSelection()) then return end
	local Line = D.Lines[D.Y]
	if (D.X <= #Line) then
		D.Lines[D.Y] = Line:sub(1, D.X - 1) .. Line:sub(D.X + 1)
	elseif (D.Y < #D.Lines) then
		D.Lines[D.Y] = Line .. D.Lines[D.Y + 1]
		table.remove(D.Lines, D.Y + 1)
	else
		return
	end
	Ed.Changed()
end

function Ed.Copy(Cut)
	local Text = Ed.Selected()
	if (not Text) then
		Text = D.Lines[D.Y] .. "\n"
		if (Cut) then
			Ed.PushUndo("edit")
			if (#D.Lines > 1) then table.remove(D.Lines, D.Y) else D.Lines[1] = "" end
			Ed.Changed()
		end
	elseif (Cut) then
		Ed.PushUndo("edit")
		Ed.DeleteSelection()
	end
	BlockOS.TextClipboard = Text
	Say(Cut and "Cut" or "Copied")
end

function Ed.Paste()
	local Text = BlockOS.TextClipboard
	if (not Text) then return end
	Ed.PushUndo("edit")
	Ed.Insert(Text)
end

function Ed.SelectAll()
	D.Anchor = { X = 1, Y = 1 }
	D.Y = #D.Lines
	D.X = #D.Lines[D.Y] + 1
end

function Ed.FindNext(Query, FromStart)
	if (not Query or Query == "") then return false end
	local StartY, StartX = D.Y, D.X
	if (FromStart) then StartY, StartX = 1, 1 end
	local Needle = Query:lower()
	for Offset = 0, #D.Lines do
		local Line = ((StartY - 1 + Offset) % #D.Lines) + 1
		local Start, Finish = D.Lines[Line]:lower():find(Needle, Offset == 0 and StartX or 1, true)
		if (Start) then
			D.Anchor = { X = Start, Y = Line }
			D.X, D.Y = Finish + 1, Line
			Ed.Ensure()
			return true
		end
	end
	Say("Not found: " .. Query)
	return false
end

function Ed.Find()
	local Query = Ui.Prompt("Find", "Search for:", V.Find)
	if (Query) then
		V.Find = Query
		Ed.FindNext(Query)
	end
end

function Ed.Replace()
	local Query = Ui.Prompt("Replace", "Find:", Ed.Selected() or V.Find)
	if (not Query or Query == "") then return end
	local With = Ui.Prompt("Replace", "Replace with:", "")
	if (not With) then return end
	Ed.PushUndo("edit")
	local Pattern = Query:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	local Safe = With:gsub("%%", "%%%%")
	local Count = 0
	for Index, Line in ipairs(D.Lines) do
		local Updated, Hits = Line:gsub(Pattern, Safe)
		D.Lines[Index] = Updated
		Count = Count + Hits
	end
	V.Find = Query
	if (Count > 0) then Ed.Changed() end
	Say("Replaced " .. Count .. (Count == 1 and " time" or " times"))
end

function Ed.GoToLine()
	local Value = tonumber(Ui.Prompt("Go to Line", "Line (1-" .. #D.Lines .. "):", tostring(D.Y)) or "")
	if (Value) then
		D.Y, D.X, D.Anchor = math.floor(Value), 1, nil
		Ed.Ensure()
	end
end

--
-- Syntax highlighting
--

function HL.Palette(Th)
	if (Th.Dark) then
		return { Bg = "f", Text = "0", Tag = "4", Attr = "9", String = "1", Comment = "d", Punct = "8", Link = "3", Escape = "a", Key = "4", Gutter = "7", GutterFg = "8", Selection = "b" }
	end
	return { Bg = "0", Text = "f", Tag = "b", Attr = "a", String = "e", Comment = "d", Punct = "7", Link = "9", Escape = "1", Key = "b", Gutter = "8", GutterFg = "7", Selection = "3" }
end

-- Lines holding the front matter: { Start, Stop } or nil.
function HL.FrontMatter()
	local Index = 1
	while (D.Lines[Index] and (D.Lines[Index]:match("^%s*$") or D.Lines[Index]:match("^%s*#"))) do Index = Index + 1 end
	if (not D.Lines[Index] or not D.Lines[Index]:match("^%s*%-%-%-?%s*$")) then return nil end
	for Stop = Index + 1, math.min(#D.Lines, Index + 40) do
		if (D.Lines[Stop]:match("^%s*%-%-%-?%s*$")) then return { Start = Index, Stop = Stop } end
	end
	return { Start = Index, Stop = #D.Lines }
end

-- Returns the blit foreground for one line.
function HL.Line(Line, Index, Pal, Front)
	local Length = #Line
	local Out = {}
	local function Paint(From, To, Colour)
		for Position = From, math.min(To, Length) do Out[Position] = Colour end
	end
	if (Length == 0) then return "" end
	if (Front and Index >= Front.Start and Index <= Front.Stop) then
		if (Index == Front.Start or Index == Front.Stop) then
			Paint(1, Length, Pal.Punct)
		elseif (Line:match("^%s*#")) then
			Paint(1, Length, Pal.Comment)
		else
			local _, Colon = Line:find("^%s*[%w_%-]+%s*:")
			Paint(1, Length, Pal.String)
			if (Colon) then
				Paint(1, Colon - 1, Pal.Key)
				Paint(Colon, Colon, Pal.Punct)
			end
		end
		return table.concat(Out)
	end
	if (Line:match("^%s*#")) then
		Paint(1, Length, Pal.Comment)
		return table.concat(Out)
	end
	local Stack = {}
	local IsTable = Line:match("^%s*|") ~= nil
	local Position = 1
	while (Position <= Length) do
		local Char = Line:sub(Position, Position)
		local Plain = Stack[#Stack] or Pal.Text
		if (Char == "\\" and Position < Length) then
			Paint(Position, Position + 1, Pal.Escape)
			Position = Position + 2
		elseif (Char == "<" and Line:find("^</?%a", Position)) then
			local _, Finish = Line:find("^</?[%a][%w%-]*", Position)
			Paint(Position, Position, Pal.Punct)
			Paint(Position + 1, Finish, Pal.Tag)
			Position = Finish + 1
			while (Position <= Length and Line:sub(Position, Position) ~= ">") do
				local Next = Line:sub(Position, Position)
				local A, B = Line:find("^[%a_][%w_%-]*", Position)
				if (A) then
					Paint(A, B, Pal.Attr)
					Position = B + 1
				elseif (Next == "\"" or Next == "'") then
					local Close = Line:find(Next, Position + 1, true) or Length
					Paint(Position, Close, Pal.String)
					Position = Close + 1
				else
					Paint(Position, Position, Pal.Punct)
					Position = Position + 1
				end
			end
			Paint(Position, Position, Pal.Punct)
			Position = Position + 1
		elseif (Char == "[" and Line:find("^%[[^%]]*%]%([^%)]*%)", Position)) then
			local _, Finish, Label = Line:find("^%[([^%]]*)%]%([^%)]*%)", Position)
			Paint(Position, Finish, Pal.String)
			Paint(Position, Position, Pal.Punct)
			Paint(Position + 1, Position + #Label, Pal.Link)
			Paint(Position + #Label + 1, Position + #Label + 2, Pal.Punct)
			Paint(Finish, Finish, Pal.Punct)
			Position = Finish + 1
		elseif (Char == "{" and Line:find("^{[^{}]*}", Position)) then
			local _, Finish, Inner = Line:find("^{([^{}]*)}", Position)
			Inner = Inner:gsub("^%s+", ""):gsub("%s+$", "")
			if (Inner == "/") then
				Stack[#Stack] = nil
				Paint(Position, Finish, Pal.Punct)
			else
				local Colour = Ccmd.Colour(Inner:match("^(.-)%s+on%s+") or Inner)
				if (Colour) then
					if (Colour == Pal.Bg) then Colour = Pal.Text end
					Stack[#Stack + 1] = Colour
					Paint(Position, Finish, Colour)
					Paint(Position, Position, Pal.Punct)
					Paint(Finish, Finish, Pal.Punct)
				else
					Paint(Position, Finish, Plain)
				end
			end
			Position = Finish + 1
		else
			Paint(Position, Position, (IsTable and Char == "|") and Pal.Punct or Plain)
			Position = Position + 1
		end
	end
	return table.concat(Out)
end

--
-- Project: the site folder shown in the file browser
--

function PJ.Open(Root)
	P.Root = "/" .. fs.combine(Root, "")
	P.Site = Site.New(P.Root)
	P.Expanded = {}
	V.Images = {}
	S.Data.LastRoot = P.Root
	SaveData()
	FB.Refresh()
end

function PJ.Refresh()
	if (P.Site) then P.Site:Refresh() end
	V.Images = {}
	V.Version = -1
	FB.Refresh()
end

-- The file whose location is "/".
function PJ.HomeFile()
	if (not P.Site) then return nil end
	local Routes = P.Site:Routes()
	return Routes["/"] and P.Site:RealPath(Routes["/"])
end

function PJ.Slug(Name)
	local Slug = Name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	return Slug ~= "" and Slug or "page"
end

-- The homepage's topbar, so new pages share the site's navigation.
function PJ.Topbar()
	local Home = PJ.HomeFile()
	local Source = Home and ReadText(Home)
	return Source and Source:match("(<topbar.-</topbar>)")
end

function PJ.PageTemplate(Title, Location)
	local Lines = { "--", "title: " .. Title, "location: " .. Location, "--" }
	local Topbar = PJ.Topbar()
	if (Topbar) then Lines[#Lines + 1] = Topbar end
	Lines[#Lines + 1] = "<br/>"
	Lines[#Lines + 1] = "<p alignment=\"center\">"
	Lines[#Lines + 1] = "{yellow}" .. Ccmd.Escape(Title) .. "{/}"
	Lines[#Lines + 1] = "</p>"
	Lines[#Lines + 1] = "<br/>"
	Lines[#Lines + 1] = "<p>"
	Lines[#Lines + 1] = "Write something here."
	Lines[#Lines + 1] = "</p>"
	return table.concat(Lines, "\n") .. "\n"
end

function PJ.NewPage(Folder)
	if (not P.Root) then
		Ui.Alert("New Page", "Open a site folder first (File > Open Folder or New Site).")
		return
	end
	if (not Ed.ConfirmDiscard()) then return end
	local Title = Ui.Prompt("New Page", "Page title:", "")
	if (not Title or Title:match("^%s*$")) then return end
	local Slug = PJ.Slug(Title)
	Folder = Folder or P.Root
	local Path = "/" .. fs.combine(Folder, Slug .. ".ccmd")
	local Number = 1
	while (fs.exists(Path)) do
		Number = Number + 1
		Path = "/" .. fs.combine(Folder, Slug .. "-" .. Number .. ".ccmd")
	end
	local Location = (P.Site:SitePath(Folder) or "/"):gsub("/$", "") .. "/" .. fs.getName(Path):gsub("%.ccmd$", "")
	Config.WriteText(Path, PJ.PageTemplate(Title, Location))
	PJ.Refresh()
	Ed.Load(Path)
end

function PJ.NewSite()
	if (not Ed.ConfirmDiscard()) then return end
	local Name = Ui.Prompt("New Site", "Name of the site:", "My Site")
	if (not Name or Name:match("^%s*$")) then return end
	local Folder = fs.combine(C.SitesDir, PJ.Slug(Name))
	if (fs.exists(Folder)) then
		Ui.Alert("New Site", "/" .. Folder .. " already exists. Open it with File > Open Folder.")
		return
	end
	fs.makeDir(Folder)
	local Bar = "<topbar color=\"orange\" text-color=\"black\">\n[Home](/) [About](/about)\n</topbar>"
	Config.WriteText(fs.combine(Folder, "index.ccmd"), table.concat({
		"--", "title: " .. Name, "location: /", "--",
		"# Lines starting with # are comments. Try the Insert menu for tables, pictures and forms.",
		Bar,
		"<br/>",
		"<p alignment=\"center\">",
		"{yellow}Welcome to " .. Ccmd.Escape(Name) .. "!{/}",
		"This page was made with {orange}CCDream{/}.",
		"</p>",
		"<br/>",
		"<p>",
		"Edit this page and watch the preview update.",
		"Visit the [About](/about) page too.",
		"</p>"
	}, "\n") .. "\n")
	Config.WriteText(fs.combine(Folder, "about.ccmd"), table.concat({
		"--", "title: About - " .. Name, "location: /about", "--",
		Bar,
		"<br/>",
		"<p>",
		"This site is about...",
		"</p>"
	}, "\n") .. "\n")
	PJ.Open(Folder)
	Ed.Load("/" .. fs.combine(Folder, "index.ccmd"))
end

function PJ.OpenFolder()
	if (not Ed.ConfirmDiscard()) then return end
	if (not fs.exists(C.SitesDir)) then fs.makeDir(C.SitesDir) end
	local Folder = Ui.PickFile({ Title = "Open Site Folder", Dir = P.Root or C.SitesDir, Folders = true })
	if (not Folder) then return end
	PJ.Open(Folder)
	local Home = PJ.HomeFile()
	if (Home) then Ed.Load(Home) else Ed.Blank() end
end

-- Opens a file or folder from the arguments, Finder or Savannah.
function PJ.OpenPath(Path)
	Path = "/" .. fs.combine(Path, "")
	if (fs.isDir(Path)) then
		PJ.Open(Path)
		local Home = PJ.HomeFile()
		if (Home) then Ed.Load(Home) else Ed.Blank() end
		return
	end
	local Root = Site.FindRoot(Path)
	if (Root ~= P.Root) then PJ.Open(Root) end
	Ed.Load(Path)
end

-- Every site file as { [relative path] = contents } for domain://upload.
function PJ.Collect()
	local Files, Total = {}, 0
	for _, File in ipairs(P.Site:Files()) do
		local Data = ReadText(File.Full)
		if (Data) then
			Files[File.Path:sub(2)] = Data
			Total = Total + #Data
		end
	end
	return Files, Total
end

function PJ.Host()
	local Saved = Config.Read("/blockos/data/savannah.dat")
	if (type(Saved) == "table" and type(Saved.Host) == "string" and Saved.Host ~= "") then return Saved.Host end
	local Host = settings and settings.get("ccinternet.host")
	if (type(Host) == "string" and Host ~= "") then return Host end
	return Protocol.DefaultHost
end

-- What a domain:// page says: its notices (the lines a core colours red, orange or lime)
-- and, as a fallback, all of its text.
local Notices = { e = true, ["1"] = true, ["5"] = true }

local function PageText(Source)
	local Doc = Ccmd.Parse(Source or "")
	local Lines, Notes = {}, {}
	local function Walk(Blocks)
		for _, Block in ipairs(Blocks) do
			if (Block.Type == "text") then
				for _, Spans in ipairs(Block.Lines) do
					local Parts, Noted = {}, false
					for _, Span in ipairs(Spans) do
						Parts[#Parts + 1] = Span.Text
						if (Notices[Span.Fg or ""] and Span.Text:match("%S")) then Noted = true end
					end
					local Text = table.concat(Parts):gsub("^%s+", "")
					if (Text ~= "") then
						Lines[#Lines + 1] = Text
						if (Noted) then Notes[#Notes + 1] = Text end
					end
				end
			elseif (Block.Type == "form") then
				Walk(Block.Blocks)
			end
		end
	end
	Walk(Doc.Blocks)
	return Lines, Notes
end

function PJ.Publish()
	if (not P.Root) then
		Ui.Alert("Publish", "Open a site folder first.")
		return
	end
	if (V.Busy) then return end
	if (D.Modified and not Ed.Save()) then return end
	local Files, Total = PJ.Collect()
	if (Total > C.MaxUpload) then
		Ui.Alert("Publish", "This site is " .. Gfx.FormatSize(Total) .. ". A domain holds about " .. Gfx.FormatSize(C.MaxUpload) .. " (one floppy disk).")
		return
	end
	S.Data.Domains = S.Data.Domains or {}
	local Domain = Ui.Prompt("Publish", "Upload this site to your domain on the ccinternet. Register one at domain:// in Savannah.\nDomain:", S.Data.Domains[P.Root] or "")
	if (not Domain or Domain:match("^%s*$")) then return end
	Domain = Domain:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("^ccmd://", ""):gsub("/.*$", "")
	local Password = Ui.Prompt("Publish", "Password for " .. Domain .. ":", "", "*")
	if (not Password or Password == "") then return end
	S.Data.Domains[P.Root] = Domain
	SaveData()
	local Transport = Protocol.NetworkTransport(PJ.Host())
	V.Busy = "Publishing to " .. Domain .. "..."
	local Task
	Task = Tasks.Spawn(function()
		return Transport.Send("POST", "domain://upload", { Accept = "text/ccmd" }, { domain = Domain, password = Password, files = Files, folder = "/" }, { Timeout = 15 })
	end, function(Ok, Result, Problem)
		V.Busy = nil
		Page:Invalidate()
		if (not Ok) then Result, Problem = nil, Result end
		if (not Result) then
			Ui.Alert("Publish failed", tostring(Problem) .. "\n\nCCDream needs a wireless or ender modem and a running ccinternet core.")
			return
		end
		local Lines, Notes = PageText(Result.Body)
		local Uploaded = false
		for _, Line in ipairs(Lines) do
			if (Line:match("^Uploaded %d+ files?%.")) then Uploaded = true end
		end
		if (Result.Status < 400 and Uploaded) then
			if (Ui.Alert("Published", table.concat(Notes, "\n") .. "\nYour site is live at ccmd://" .. Domain, { "OK", "Open" }) == 2) then
				BlockOS.Launch("savannah", { "ccmd://" .. Domain })
			end
		else
			local Said = #Notes > 0 and Notes or { table.unpack(Lines, 1, math.min(#Lines, 4)) }
			Ui.Alert("Publish failed", table.concat(Said, "\n"))
		end
	end)
	if (Task.Done) then V.Busy = nil end
	Page:Invalidate()
end

--
-- Files: loading and saving the open page
--

function Ed.UpdateTitle()
	BlockOS.SetTitle((D.Modified and "\7 " or "") .. (D.Path and fs.getName(D.Path) or "Untitled") .. " - CCDream")
end

function Ed.Blank()
	Ed.SetText(table.concat({ "--", "title: Untitled", "location: /", "--", "<p>", "Hello from {yellow}CCDream{/}!", "</p>" }, "\n"))
	D.Path = nil
	PV.Parse()
	Ed.UpdateTitle()
end

function Ed.Load(Path)
	local Text = ReadText(Path)
	Ed.SetText(Text or "")
	D.Path = "/" .. fs.combine(Path, "")
	V.Scroll = 0
	PV.Parse()
	S.Data.LastFile = D.Path
	SaveData()
	Ed.UpdateTitle()
	Say(Text and ("Opened " .. fs.getName(Path)) or "New file")
end

function Ed.SaveAs()
	local Path = Ui.PickFile({ Save = true, Dir = D.Path and fs.getDir(D.Path) or P.Root or C.SitesDir, Name = D.Path and fs.getName(D.Path) or "page.ccmd" })
	if (not Path) then return false end
	if (not Path:lower():match("%.ccmd$") and not Path:find("%.%w+$")) then Path = Path .. ".ccmd" end
	D.Path = Path
	return true
end

function Ed.Save()
	if (not D.Path and not Ed.SaveAs()) then return false end
	if (fs.isReadOnly(D.Path)) then
		Ui.Alert("Save", "This location is read-only.")
		return false
	end
	local _, _, Problem = Ccmd.ParseFrontMatter(Ed.Text())
	if (not Config.WriteText(D.Path, Ed.Text() .. "\n")) then
		Ui.Alert("Save", "Could not write " .. D.Path)
		return false
	end
	D.Modified = false
	if (not P.Root or not P.Site:SitePath(D.Path)) then PJ.Open(Site.FindRoot(D.Path)) end
	PJ.Refresh()
	Say(Problem and ("Saved, but: " .. Problem) or ("Saved " .. fs.getName(D.Path)))
	Ed.UpdateTitle()
	return true
end

function Ed.ConfirmDiscard()
	if (not D.Modified) then return true end
	local Choice = Ui.Alert("Unsaved changes", "Save changes to " .. (D.Path and fs.getName(D.Path) or "Untitled") .. "?", { "Cancel", "Don't Save", "Save" })
	if (Choice == 3) then return Ed.Save() end
	return Choice == 2
end

function Ed.OpenFile()
	if (not Ed.ConfirmDiscard()) then return end
	local Path = Ui.PickFile({ Title = "Open Page", Dir = P.Root or C.SitesDir })
	if (Path) then PJ.OpenPath(Path) end
end

function Ed.Close()
	if (Ed.ConfirmDiscard()) then
		BlockOS.Quit()
		Page:Stop()
	end
end

-- The address of the open page inside its site, as Savannah shows it.
function Ed.Address()
	if (not D.Path or not P.Site) then return nil end
	local Path = P.Site:SitePath(D.Path)
	if (not Path) then return nil end
	local Location = PV.Doc and PV.Doc.Meta.location and Protocol.NormalizePath(PV.Doc.Meta.location)
	if (Location and P.Site:Resolve(Location) == Path) then return Location end
	return Path
end

function Ed.OpenInSavannah()
	if (D.Modified and not Ed.Save()) then return end
	if (not D.Path) then return end
	BlockOS.Launch("savannah", { D.Path })
end

--
-- Preview
--

function PV.Base()
	local Location = PV.Doc and PV.Doc.Meta.location and Protocol.NormalizePath(PV.Doc.Meta.location)
	if (not Location and D.Path and P.Site) then Location = P.Site:SitePath(D.Path) end
	return Protocol.ParseUrl("local://site" .. (Location or "/"))
end

function PV.Picture(Src)
	local Parsed = Protocol.ParseUrl(Src, PV.Base())
	if (not Parsed or Parsed.Scheme ~= "local" or not P.Site) then return nil end
	local File = P.Site:Resolve(Parsed.Path)
	if (not File) then return false end
	if (V.Images[File] == nil) then
		V.Images[File] = Image.Parse(P.Site:Read(File) or "", File) or false
	end
	return V.Images[File]
end

function PV.Parse()
	PV.Doc = Ccmd.Parse(Ed.Text())
	V.Version = D.Version
	PV.Page = nil
end

function PV.Rebuild()
	local Box = W.Preview
	if (not Box or not Box.Visible) then return end
	if (V.Version ~= D.Version) then PV.Parse() end
	PV.Page = Layout.Build(PV.Doc, Box.W, Box.H, { Images = PV.Picture })
	PV.Built = Box.W .. "x" .. Box.H
	V.Scroll = math.max(0, math.min(V.Scroll, PV.Page.MaxScroll))
end

function PV.Draw(Self, T, Th)
	if (not PV.Page or V.Version ~= D.Version and os.clock() - V.ChangedAt >= C.PreviewDelay or PV.Built ~= Self.W .. "x" .. Self.H) then
		PV.Rebuild()
	end
	local Pg = PV.Page
	if (not Pg) then return end
	local Blank = { string.rep(" ", Pg.ViewW), string.rep("0", Pg.ViewW), string.rep(Pg.Background, Pg.ViewW) }
	for Y = 1, Pg.ViewH do
		local Row = Pg.Rows[V.Scroll + Y] or Blank
		T.setCursorPos(Self.X + Pg.ViewX - 1, Self.Y + Pg.ViewY + Y - 2)
		T.blit(Row[1], Row[2], Row[3])
	end
	if (Pg.Bar) then
		for Index, Row in ipairs(Pg.Bar.Rows) do
			T.setCursorPos(Self.X, Self.Y + Index - 1)
			T.blit(Row[1], Row[2], Row[3])
		end
	end
end

function PV.DrawHeader(Self, T, Th)
	local Address = Ed.Address() or "Preview"
	local Title = PV.Doc and PV.Doc.Title or ""
	local Text = " \16 " .. Address .. (Title ~= "" and ("  " .. Title) or "")
	Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(Text, Self.W - 7), Th.SubText, Th.Panel)
end

-- Follows a link in the preview: pages of this site open in the editor, others in Savannah.
function PV.Follow(Href)
	local Parsed = Protocol.ParseUrl(Href, PV.Base())
	if (not Parsed) then return end
	if (Parsed.Scheme ~= "local") then
		BlockOS.Launch("savannah", { Protocol.FormatUrl(Parsed) })
		return
	end
	local File = P.Site and P.Site:Resolve(Parsed.Path)
	local Real = File and P.Site:RealPath(File)
	if (not Real or not Real:lower():match("%.ccmd$")) then
		Say("No page at " .. Parsed.Path)
		return
	end
	if (Real == D.Path) then return end
	if (Ed.ConfirmDiscard()) then Ed.Load(Real) end
end

function PV.Event(Self, Name, A, B, C)
	if (Name == "mouse_scroll") then
		if (PV.Page) then V.Scroll = math.max(0, math.min(PV.Page.MaxScroll, V.Scroll + A * 2)) end
		return true
	elseif (Name == "mouse_click" and PV.Page) then
		local Region = Layout.Hit(PV.Page, B - Self.X + 1, C - Self.Y + 1, V.Scroll)
		local Href = Region and (Region.Href or (Region.Button and Region.Button.Href))
		if (Href) then PV.Follow(Href) end
		return true
	end
	return false
end

--
-- File browser
--

local Icons = {
	ccmd = { "@", colors.orange }, nft = { "\127", colors.pink }, bimg = { "\127", colors.magenta },
	nfp = { "\127", colors.pink }, txt = { "\7", colors.lightGray }
}

function FB.Refresh()
	local Items = {}
	local function Walk(Dir, Depth)
		if (Depth > 6 or #Items > 300) then return end
		local Names = fs.list(Dir)
		table.sort(Names, function(A, B)
			local DA, DB = fs.isDir(fs.combine(Dir, A)), fs.isDir(fs.combine(Dir, B))
			if (DA ~= DB) then return DA end
			return A:lower() < B:lower()
		end)
		for _, Name in ipairs(Names) do
			local Full = "/" .. fs.combine(Dir, Name)
			if (Name:sub(1, 1) ~= ".") then
				local IsDir = fs.isDir(Full)
				Items[#Items + 1] = { Name = Name, Path = Full, Dir = IsDir, Depth = Depth }
				if (IsDir and P.Expanded[Full]) then Walk(Full, Depth + 1) end
			end
		end
	end
	if (P.Root and fs.isDir(P.Root)) then Walk(P.Root, 0) end
	P.Items = Items
	if (W.Files) then W.Files:SetItems(Items, true) end
end

function FB.Render(Self, T, Th, Item, X, Y, Width, Selected, RowBg, RowFg)
	local Current = Item.Path == D.Path
	local Bg = Current and Th.Accent or RowBg
	local Fg = Current and Th.AccentFg or RowFg
	Gfx.Fill(T, X, Y, Width, 1, Bg)
	local Indent = string.rep(" ", Item.Depth)
	local Icon, IconFg
	if (Item.Dir) then
		Icon, IconFg = P.Expanded[Item.Path] and "\31" or "\16", colors.lightBlue
	else
		local Kind = Icons[(Item.Name:match("%.(%w+)$") or ""):lower()] or { "\7", colors.gray }
		Icon, IconFg = Kind[1], Kind[2]
	end
	Gfx.Write(T, X, Y, Gfx.Truncate(" " .. Indent, Width), Fg, Bg)
	if (#Indent + 2 <= Width) then Gfx.Write(T, X + #Indent + 1, Y, Icon, Current and Fg or IconFg, Bg) end
	Gfx.Write(T, X + #Indent + 2, Y, Gfx.Truncate(" " .. Item.Name, math.max(0, Width - #Indent - 2)), Fg, Bg)
end

function FB.Activate(_, _, Item)
	if (Item.Dir) then
		P.Expanded[Item.Path] = not P.Expanded[Item.Path] or nil
		FB.Refresh()
	elseif (Item.Path ~= D.Path) then
		if (Item.Name:lower():match("%.ccmd$") or Item.Name:lower():match("%.txt$") or not Item.Name:find("%.")) then
			if (Ed.ConfirmDiscard()) then Ed.Load(Item.Path) end
		else
			BlockOS.Open(Item.Path)
		end
	end
end

function FB.Context(_, _, Item, X, Y)
	local Folder = Item and (Item.Dir and Item.Path or "/" .. fs.getDir(Item.Path)) or P.Root
	local Options = {
		{ Text = "New Page..." },
		{ Text = "New Folder..." },
		"-",
		{ Text = "Rename...", Disabled = not Item },
		{ Text = "Delete", Disabled = not Item },
		"-",
		{ Text = "Open in Savannah", Disabled = not Item or Item.Dir },
		{ Text = "Show in Finder" },
		{ Text = "Refresh" }
	}
	local Index = Ui.ContextMenu(X, Y, Options)
	local Choice = Index and Options[Index].Text
	if (not P.Root) then return end
	if (Choice == "New Page...") then
		PJ.NewPage(Folder)
	elseif (Choice == "New Folder...") then
		local Name = Ui.Prompt("New Folder", "Name:", "img")
		if (Name and Name:match("%S")) then
			fs.makeDir(fs.combine(Folder, Name))
			P.Expanded[Folder] = true
			PJ.Refresh()
		end
	elseif (Choice == "Rename...") then
		local Name = Ui.Prompt("Rename", "New name:", Item.Name)
		if (Name and Name:match("%S") and Name ~= Item.Name) then
			local Target = "/" .. fs.combine(fs.getDir(Item.Path), Name)
			if (fs.exists(Target)) then
				Ui.Alert("Rename", Name .. " already exists.")
			else
				fs.move(Item.Path, Target)
				if (D.Path == Item.Path) then D.Path = Target Ed.UpdateTitle() end
				PJ.Refresh()
			end
		end
	elseif (Choice == "Delete") then
		if (Ui.Confirm("Delete", "Delete " .. Item.Name .. (Item.Dir and " and everything in it" or "") .. "?", "Delete")) then
			fs.delete(Item.Path)
			if (D.Path == Item.Path) then
				D.Modified = false
				Ed.Blank()
			end
			PJ.Refresh()
		end
	elseif (Choice == "Open in Savannah") then
		BlockOS.Launch("savannah", { Item.Path })
	elseif (Choice == "Show in Finder") then
		BlockOS.Launch("finder", { Folder })
	elseif (Choice == "Refresh") then
		PJ.Refresh()
	end
end

--
-- Editor widget
--

function Ed.Draw(Self, T, Th)
	local Pal = HL.Palette(Th)
	local Digits = #tostring(#D.Lines)
	Self.Gutter = Digits + 2
	local ViewW = Self.W - Self.Gutter
	local AX, AY, BX, BY = Ed.Range()
	local Front = HL.FrontMatter()
	local Index, Part = D.ScrollY + 1, V.Wrap and D.ScrollRow or 0
	local Built = nil
	for Row = 1, Self.H do
		local Line = D.Lines[Index]
		T.setCursorPos(Self.X, Self.Y + Row - 1)
		if (not Line) then
			T.blit(string.rep(" ", Self.W), string.rep(Pal.Text, Self.W), string.rep(Pal.Gutter, Self.Gutter) .. string.rep(Pal.Bg, ViewW))
		else
			if (not Built) then
				local Colours = HL.Line(Line, Index, Pal, Front)
				local Chars, Fg, Bg = {}, {}, {}
				for Position = 1, #Line do
					local Char = Line:sub(Position, Position)
					local Selected = AX and (Index > AY or (Index == AY and Position >= AX)) and (Index < BY or (Index == BY and Position < BX))
					local Code = Colours:sub(Position, Position)
					if (Code == "") then Code = Pal.Text end
					local Back = Selected and Pal.Selection or Pal.Bg
					for _ = 1, (Char == "\t") and 2 or 1 do
						Chars[#Chars + 1] = (Char == "\t") and " " or Char
						Fg[#Fg + 1] = Code
						Bg[#Bg + 1] = Back
					end
				end
				Built = { Text = table.concat(Chars), Fg = table.concat(Fg), Bg = table.concat(Bg) }
				if (V.Wrap) then
					Built.Starts = Ed.WrapStarts(Built.Text, Ed.WrapWidth())
					Part = math.min(Part, #Built.Starts - 1)
				end
			end
			-- The slice of the line on this row: one wrapped part, or the scrolled window.
			local From, To = D.ScrollX, D.ScrollX + ViewW
			if (Built.Starts) then
				From = Built.Starts[Part + 1]
				To = math.min(Built.Starts[Part + 2] or #Built.Text, From + ViewW)
			end
			local Number = " " .. ((Part == 0) and Gfx.Pad(tostring(Index), Digits, "right") or string.rep(" ", Digits)) .. " "
			local Text = Built.Text:sub(From + 1, To)
			local Pad = ViewW - #Text
			T.blit(
				Number .. Text .. string.rep(" ", Pad),
				string.rep(Index == D.Y and Pal.Text or Pal.GutterFg, #Number) .. Built.Fg:sub(From + 1, To) .. string.rep(Pal.Text, Pad),
				string.rep(Pal.Gutter, #Number) .. Built.Bg:sub(From + 1, To) .. string.rep(Pal.Bg, Pad)
			)
			if (Built.Starts and Built.Starts[Part + 2]) then
				Part = Part + 1
			else
				Index, Part, Built = Index + 1, 0, nil
			end
		end
	end
end

function Ed.Cursor(Self)
	local Colour = 2 ^ tonumber(HL.Palette(Theme.Get()).Text, 16)
	if (V.Wrap) then
		local Offset = Ed.CursorOffset(Self.H)
		local _, Inset = Ed.CursorRow()
		if (Offset < 0 or Offset >= Self.H or Inset >= Self.W - Self.Gutter) then return nil end
		return Self.X + Self.Gutter + Inset, Self.Y + Offset, Colour
	end
	local Row = D.Y - D.ScrollY
	if (Row < 1 or Row > Self.H) then return nil end
	local Column = DisplayWidth(D.Lines[D.Y], D.X - 1) - D.ScrollX
	if (Column < 0 or Column >= Self.W - Self.Gutter) then return nil end
	return Self.X + Self.Gutter + Column, Self.Y + Row - 1, Colour
end

local function MousePosition(Self, X, Y)
	if (V.Wrap) then
		local Top = math.max(1, math.min(#D.Lines, D.ScrollY + 1))
		local Line, Row = Ed.StepRows(Top, D.ScrollRow, math.max(0, Y - Self.Y))
		local Starts = Ed.LineStarts(Line)
		Row = math.min(Row, #Starts - 1)
		local Inset = Starts[Row + 1] + math.max(0, X - Self.X - Self.Gutter)
		if (Starts[Row + 2]) then Inset = math.min(Inset, Starts[Row + 2] - 1) end
		return CharFromDisplay(D.Lines[Line], Inset), Line
	end
	local Index = math.max(1, math.min(#D.Lines, D.ScrollY + Y - Self.Y + 1))
	local Column = math.max(0, X - Self.X - Self.Gutter + D.ScrollX)
	return CharFromDisplay(D.Lines[Index], Column), Index
end

local Shortcuts = {
	[keys.s] = function() Ed.Save() end,
	[keys.o] = function() Ed.OpenFile() end,
	[keys.n] = function() PJ.NewPage() end,
	[keys.z] = function() Ed.UndoStep(false) end,
	[keys.y] = function() Ed.UndoStep(true) end,
	[keys.c] = function() Ed.Copy(false) end,
	[keys.x] = function() Ed.Copy(true) end,
	[keys.a] = function() Ed.SelectAll() end,
	[keys.f] = function() Ed.Find() end,
	[keys.h] = function() Ed.Replace() end,
	[keys.g] = function() Ed.GoToLine() end,
	[keys.b] = function() Menu.ToggleFiles() end,
	[keys.p] = function() Menu.CycleMode() end,
	[keys.d] = function()
		Ed.PushUndo("edit")
		table.insert(D.Lines, D.Y + 1, D.Lines[D.Y])
		D.Y = D.Y + 1
		Ed.Changed()
	end,
	[keys.q] = function() Ed.Close() end,
	[keys.w] = function() Ed.Close() end
}

function Ed.Event(Self, Name, A, B, MouseY)
	if (Name == "mouse_click" or Name == "mouse_drag") then
		local X, Y = MousePosition(Self, B, MouseY)
		if (Name == "mouse_click") then
			if (A == 2) then
				Menu.Edit(B, MouseY)
				return true
			end
			D.Anchor = Modifiers.Shift and (D.Anchor or { X = D.X, Y = D.Y }) or { X = X, Y = Y }
		end
		D.X, D.Y = X, Y
		Ed.Ensure()
		return true
	elseif (Name == "mouse_up") then
		if (D.Anchor and D.Anchor.X == D.X and D.Anchor.Y == D.Y) then D.Anchor = nil end
		return true
	elseif (Name == "mouse_scroll") then
		if (V.Wrap) then
			local Top, Row = Ed.StepRows(math.max(1, math.min(#D.Lines, D.ScrollY + 1)), D.ScrollRow, A * 3)
			D.ScrollY, D.ScrollRow = Top - 1, Row
			return true
		end
		D.ScrollY = math.max(0, math.min(D.ScrollY + A * 3, math.max(0, #D.Lines - Self.H)))
		return true
	elseif (Name == "char") then
		if (Modifiers.Ctrl) then return true end
		Ed.Type(A)
		Ed.Ensure()
		return true
	elseif (Name == "paste") then
		Ed.PushUndo("edit")
		Ed.Insert(A)
		Ed.Ensure()
		return true
	elseif (Name ~= "key") then
		return false
	end
	if (Modifiers.Ctrl) then
		if (Shortcuts[A]) then
			Shortcuts[A]()
		elseif (not Ed.Move(A)) then
			return false
		elseif (not Modifiers.Shift) then
			D.Anchor = nil
		end
		Ed.Ensure()
		return true
	end
	local Before = { X = D.X, Y = D.Y }
	if (Ed.Move(A)) then
		D.Anchor = Modifiers.Shift and (D.Anchor or Before) or nil
	elseif (A == keys.enter or A == keys.numPadEnter) then
		Ed.NewLine()
	elseif (A == keys.backspace) then
		Ed.Backspace()
	elseif (A == keys.delete) then
		Ed.Delete()
	elseif (A == keys.tab) then
		Ed.PushUndo("edit")
		Ed.Insert(C.Indent)
	elseif (A == keys.f3) then
		Ed.FindNext(V.Find)
	elseif (A == keys.f5) then
		Ed.OpenInSavannah()
	else
		return false
	end
	Ed.Ensure()
	return true
end

--
-- Menus and snippets
--

Menu.Colours = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }

function Menu.PickColour(Title)
	local Items = {}
	for Index, Name in ipairs(Menu.Colours) do
		Items[Index] = { Text = Name, Icon = "\127", IconFg = colors[Name] }
	end
	local Index = Ui.Choose(Title or "Colour", Items)
	return Index and Menu.Colours[Index]
end

function Menu.Link()
	local Items, Targets = {}, {}
	if (P.Site) then
		local _, Pages = P.Site:Routes()
		for _, Info in ipairs(Pages) do
			if (Info.Location) then
				Items[#Items + 1] = { Text = Info.Location .. "  " .. (Info.Title or ""), Icon = "@", IconFg = colors.orange }
				Targets[#Items] = Info
			end
		end
	end
	Items[#Items + 1] = { Text = "Other address...", Icon = "\26", IconFg = "SubText" }
	local Index = Ui.Choose("Link to", Items)
	if (not Index) then return end
	local Url, Label
	if (Targets[Index]) then
		Url, Label = Targets[Index].Location, Targets[Index].Title or Targets[Index].Location
	else
		Url = Ui.Prompt("Link", "Address (ccmd://site.com, /page or domain://):", "ccmd://")
		if (not Url or Url == "") then return end
		Label = Url
	end
	local Selected = Ed.Selected()
	Ed.PushUndo("edit")
	Ed.Insert("[" .. (Selected and not Selected:find("\n") and Selected or Label:gsub("[%[%]]", "")) .. "](" .. Url:gsub("[%(%)%s]", "") .. ")")
	Ed.Ensure()
end

function Menu.Image()
	local Path = Ui.PickFile({ Title = "Choose Picture", Dir = P.Root or "/home/Pictures" })
	if (not Path) then return end
	local Src = P.Site and P.Site:SitePath(Path)
	if (not Src) then
		Ui.Alert("Picture", "Pictures must be inside the site folder (" .. tostring(P.Root) .. ") so they are uploaded with it. Copy it there first.")
		return
	end
	if (not Image.Kind(Path)) then
		Ui.Alert("Picture", "Use a .nft, .bimg or .nfp picture (Brocreate saves .bimg).")
		return
	end
	local Alt = fs.getName(Path):gsub("%.%w+$", "")
	Ed.InsertBlock("<img src=\"" .. Ccmd.Attribute(Src) .. "\" alt=\"" .. Ccmd.Attribute(Alt) .. "\" alignment=\"center\">")
end

Menu.Snippets = {
	{ "Front Matter", "--\ntitle: Page title\nlocation: /page\n--" },
	{ "Topbar", "<topbar color=\"gray\" text-color=\"white\">\n[Home](/) [About](/about)\n</topbar>" },
	{ "Sidebar", "<topbar layout=\"vertical\" color=\"gray\" text-color=\"white\">\n[Home](/)\n[About](/about)\n</topbar>" },
	{ "Paragraph", "<p>\nText\n</p>" },
	{ "Centred Paragraph", "<p alignment=\"center\">\nText\n</p>" },
	{ "Table", "<table header-color=\"gray\">\n| Name | Value |\n|---|---|\n| One | 1 |\n</table>" },
	{ "Line Break", "<br/>" },
	{ "Form", "<form action=\"/thanks\" method=\"POST\">\n<input name=\"name\" label=\"Name:\" width=\"20\"/>\n<button text=\"Send\"/>\n</form>" },
	{ "Text Field", "<input name=\"field\" label=\"Label:\" placeholder=\"\" width=\"20\"/>" },
	{ "Button Link", "<button text=\"Go\" href=\"/page\"/>" },
	{ "Comment", "# Comment" }
}

function Menu.Insert(X, Y)
	local Options = { "Link...", "Picture...", "Colour...", "-" }
	for _, Snippet in ipairs(Menu.Snippets) do Options[#Options + 1] = Snippet[1] end
	local Index = Ui.ContextMenu(X, Y, Options)
	if (not Index) then return end
	local Choice = Options[Index]
	if (Choice == "Link...") then
		Menu.Link()
	elseif (Choice == "Picture...") then
		Menu.Image()
	elseif (Choice == "Colour...") then
		local Colour = Menu.PickColour("Text colour")
		if (Colour) then Ed.Wrap("{" .. Colour .. "}", "{/}", "text") end
	else
		Ed.InsertBlock(Menu.Snippets[Index - 4][2])
	end
end

function Menu.File()
	local Options = { "New Page...", "New Site...", "Open Folder...", "Open Page...", "-", "Save", "Save As...", "-", "Open in Savannah", "Publish...", "-", "Close" }
	local Choice = Options[Ui.ContextMenu(1, 2, Options) or 0]
	if (Choice == "New Page...") then PJ.NewPage()
	elseif (Choice == "New Site...") then PJ.NewSite()
	elseif (Choice == "Open Folder...") then PJ.OpenFolder()
	elseif (Choice == "Open Page...") then Ed.OpenFile()
	elseif (Choice == "Save") then Ed.Save()
	elseif (Choice == "Save As...") then
		if (Ed.SaveAs()) then Ed.Save() end
	elseif (Choice == "Open in Savannah") then Ed.OpenInSavannah()
	elseif (Choice == "Publish...") then PJ.Publish()
	elseif (Choice == "Close") then Ed.Close()
	end
end

function Menu.Edit(X, Y)
	local Options = { "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Find...", "Find Next", "Replace...", "Go to Line..." }
	local Choice = Options[Ui.ContextMenu(X or 7, Y or 2, Options) or 0]
	if (Choice == "Undo") then Ed.UndoStep(false)
	elseif (Choice == "Redo") then Ed.UndoStep(true)
	elseif (Choice == "Cut" or Choice == "Copy") then Ed.Copy(Choice == "Cut")
	elseif (Choice == "Paste") then Ed.Paste()
	elseif (Choice == "Select All") then Ed.SelectAll()
	elseif (Choice == "Find...") then Ed.Find()
	elseif (Choice == "Find Next") then Ed.FindNext(V.Find)
	elseif (Choice == "Replace...") then Ed.Replace()
	elseif (Choice == "Go to Line...") then Ed.GoToLine()
	end
	Ed.Ensure()
end

Menu.Modes = { "code", "split", "preview" }

function Menu.SetMode(Mode)
	V.Mode = Mode
	S.Data.Mode = Mode
	SaveData()
	Page:OnLayout(Page.W, Page.H)
end

function Menu.CycleMode()
	for Index, Mode in ipairs(Menu.Modes) do
		if (Mode == V.Mode) then return Menu.SetMode(Menu.Modes[Index % #Menu.Modes + 1]) end
	end
end

function Menu.ToggleFiles()
	V.ShowFiles = not V.ShowFiles
	S.Data.ShowFiles = V.ShowFiles
	SaveData()
	Page:OnLayout(Page.W, Page.H)
end

function Menu.ToggleWrap()
	V.Wrap = not V.Wrap
	S.Data.Wrap = V.Wrap
	SaveData()
	D.ScrollX, D.ScrollRow = 0, 0
	Ed.Ensure()
	Say(V.Wrap and "Word wrap on" or "Word wrap off")
end

function Menu.View()
	local Options = {
		{ Text = (V.Mode == "code" and "\7 " or "  ") .. "Code" },
		{ Text = (V.Mode == "split" and "\7 " or "  ") .. "Code and Preview" },
		{ Text = (V.Mode == "preview" and "\7 " or "  ") .. "Preview" },
		"-",
		{ Text = V.ShowFiles and "Hide Files" or "Show Files" },
		{ Text = (V.Wrap and "\7 " or "  ") .. "Word Wrap" },
		{ Text = "Refresh" },
		{ Text = "Home Page", Disabled = not PJ.HomeFile() },
		{ Text = "Problems", Disabled = not (PV.Doc and #PV.Doc.Errors > 0) }
	}
	local Index = Ui.ContextMenu(22, 2, Options)
	if (Index and Index <= 3) then
		Menu.SetMode(Menu.Modes[Index])
	elseif (Index == 5) then
		Menu.ToggleFiles()
	elseif (Index == 6) then
		Menu.ToggleWrap()
	elseif (Index == 7) then
		PJ.Refresh()
	elseif (Index == 8) then
		local Home = PJ.HomeFile()
		if (Home and Home ~= D.Path and Ed.ConfirmDiscard()) then Ed.Load(Home) end
	elseif (Index == 9) then
		Menu.Problems()
	end
end

function Menu.Problems()
	if (not PV.Doc or #PV.Doc.Errors == 0) then return end
	Ui.Alert("Problems", table.concat(PV.Doc.Errors, "\n"))
end

--
-- Window layout
--

local function BarButton(X, Text, OnClick)
	return Ui.Button.new({ X = X, Y = 1, Text = " " .. Text .. " ", Bg = "Panel", Fg = "PanelFg", OnClick = OnClick })
end

function Page:OnLayout(Width, Height)
	local Focus = self.Focus
	self:Clear()
	self:Add(Ui.Panel.new({ X = 1, Y = 1, W = Width, H = 1, Bg = "Panel" }))
	self:Add(BarButton(1, "File", function() Menu.File() end))
	self:Add(BarButton(7, "Edit", function() Menu.Edit() end))
	self:Add(BarButton(13, "Insert", function(Self) Menu.Insert(Self.X, 2) end))
	self:Add(BarButton(21, "View", function() Menu.View() end))
	local TabsW = math.max(15, math.min(24, Width - 27))
	self:Add(Ui.Tabs.new({
		X = Width - TabsW + 1, Y = 1, W = TabsW, Items = { "Code", "Split", "Preview" },
		Selected = ({ code = 1, split = 2, preview = 3 })[V.Mode] or 2,
		OnChange = function(_, Index) Menu.SetMode(Menu.Modes[Index]) end
	}))
	local Top, BodyH = 2, math.max(1, Height - 2)
	local X = 1
	local FilesW = 0
	if (V.ShowFiles and Width >= 30) then
		FilesW = math.max(12, math.min(18, math.floor(Width * .24)))
		self:Add(Ui.Canvas.new({
			X = 1, Y = Top, W = FilesW, H = 1,
			OnDraw = function(Self, T, Th)
				local Name = P.Root and (P.Root == "/" and "Computer" or fs.getName(P.Root)) or "No folder"
				Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(" " .. Name, Self.W - 2) .. " +", Th.SubText, Th.Panel)
			end,
			OnEvent = function(Self, Name, Button, MX, MY)
				if (Name ~= "mouse_click") then return false end
				if (MX >= Self.X + Self.W - 2 or Button == 2) then FB.Context(nil, nil, nil, MX, MY + 1) end
				return true
			end
		}))
		W.Files = self:Add(Ui.List.new({
			X = 1, Y = Top + 1, W = FilesW, H = BodyH - 1, Items = P.Items, SingleClick = true,
			RenderItem = FB.Render, OnActivate = FB.Activate, OnContext = FB.Context
		}))
		self:Add(Ui.Panel.new({ X = FilesW + 1, Y = Top, W = 1, H = BodyH, Bg = "Border" }))
		X = FilesW + 2
	else
		W.Files = nil
	end
	local Rest = Width - X + 1
	local EditorW, PreviewW = Rest, 0
	if (V.Mode == "preview") then
		EditorW, PreviewW = 0, Rest
	elseif (V.Mode == "split") then
		EditorW = math.floor((Rest - 1) / 2)
		PreviewW = Rest - EditorW - 1
	end
	W.Editor = self:Add(Ui.Canvas.new({
		X = X, Y = Top, W = math.max(1, EditorW), H = BodyH, Gutter = 3, Focusable = true, KeepFocus = true,
		Visible = EditorW > 0, OnDraw = Ed.Draw, OnEvent = Ed.Event, OnCursor = Ed.Cursor
	}))
	if (PreviewW > 0) then
		local PX = X + (EditorW > 0 and EditorW + 1 or 0)
		if (EditorW > 0) then self:Add(Ui.Panel.new({ X = PX - 1, Y = Top, W = 1, H = BodyH, Bg = "Border" })) end
		self:Add(Ui.Canvas.new({ X = PX, Y = Top, W = PreviewW, H = 1, OnDraw = PV.DrawHeader }))
		self:Add(Ui.Button.new({
			X = PX + PreviewW - 7, Y = Top, W = 7, Text = "\16 Open", Bg = "Panel", Fg = "Accent",
			OnClick = function() Ed.OpenInSavannah() end
		}))
		W.Preview = self:Add(Ui.Canvas.new({ X = PX, Y = Top + 1, W = PreviewW, H = BodyH - 1, OnDraw = PV.Draw, OnEvent = PV.Event }))
	else
		W.Preview = nil
	end
	self:Add(Ui.Canvas.new({
		X = 1, Y = Height, W = Width, H = 1,
		OnDraw = function(Self, T, Th)
			local Left = " Ln " .. D.Y .. ", Col " .. D.X .. (D.Modified and "  \7 Edited" or "")
			local Right = "ccmd "
			local RightFg = Th.SubText
			if (V.Busy) then
				Right, RightFg = V.Busy .. " ", Th.Accent
			elseif (V.Message and os.clock() - V.MessageAt < 4) then
				Right = V.Message .. "  " .. Right
			elseif (PV.Doc and #PV.Doc.Errors > 0) then
				Right, RightFg = "\19 " .. PV.Doc.Errors[1] .. (#PV.Doc.Errors > 1 and (" (+" .. (#PV.Doc.Errors - 1) .. ")") or "") .. " ", colors.orange
			end
			Right = Gfx.Truncate(Right, math.max(1, Self.W - #Left - 1))
			Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(Left, Self.W - #Right), Th.SubText, Th.Panel)
			Gfx.Write(T, Self.X + Self.W - #Right, Self.Y, Right, RightFg, Th.Panel)
		end,
		OnEvent = function(Self, Name)
			if (Name == "mouse_click") then Menu.Problems() end
			return Name == "mouse_click"
		end
	}))
	if (EditorW > 0) then
		self:SetFocus(Focus == W.Files and W.Files or W.Editor)
		Ed.Ensure()
	elseif (W.Files) then
		self:SetFocus(W.Files)
	end
end

local BaseBackground = Page.Background
function Page:Background(Name, ...)
	if (Tasks.Dispatch(Name, ...)) then self.Dirty = true end
	BaseBackground(self, Name, ...)
end

local BaseHandle = Page.Handle
function Page:Handle(Name, A, ...)
	-- Ctrl shortcuts work wherever the focus is (files list or preview mode included).
	if (Name == "key" and Modifiers.Ctrl and not Modifiers.Shift and Shortcuts[A] and self.Focus ~= W.Editor) then
		Shortcuts[A]()
		self.Dirty = true
		return
	end
	if (Name == "key" and A == keys.f5) then
		Ed.OpenInSavannah()
		return
	end
	BaseHandle(self, Name, A, ...)
	if (D.Modified ~= self.LastModified) then
		self.LastModified = D.Modified
		Ed.UpdateTitle()
	end
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_close") then
		Ed.Close()
		return true
	elseif (Name == "blockos_open" and A) then
		if (Ed.ConfirmDiscard()) then PJ.OpenPath(A) end
		return true
	end
	return false
end

function Page:OnTerminate()
	Ed.Close()
end

-- Refreshes the preview a moment after typing stops, and clears old messages.
Page:SetInterval(0.2, function()
	if (V.Version ~= D.Version and os.clock() - V.ChangedAt >= C.PreviewDelay) then
		PV.Parse()
		return true
	end
	if (V.Message and os.clock() - V.MessageAt < 4.3 and os.clock() - V.MessageAt > 3.9) then return true end
	return V.Busy ~= nil
end)

-- Start up: open the argument, the last file, or offer to make a site.
local Saved = Config.Read(C.DataPath)
S.Data = type(Saved) == "table" and Saved or {}
V.Mode = S.Data.Mode or "split"
if (S.Data.ShowFiles ~= nil) then V.ShowFiles = S.Data.ShowFiles end
V.Wrap = S.Data.Wrap == true
BlockOS.SetCloseHandler(true)
Page:OnLayout(Page.W, Page.H)

local Start = Args[1] and (shell and shell.resolve(Args[1]) or Args[1])
if (Start and fs.exists(Start)) then
	PJ.OpenPath(Start)
elseif (S.Data.LastFile and fs.exists(S.Data.LastFile)) then
	PJ.OpenPath(S.Data.LastFile)
else
	Ed.Blank()
	if (S.Data.LastRoot and fs.isDir(S.Data.LastRoot)) then
		PJ.Open(S.Data.LastRoot)
	else
		Page.Pending = true
	end
end
if (Page.Pending) then
	Page.Pending = nil
	Ui.Current = Page
	Page:Draw()
	local Choice = Ui.Alert("Welcome to CCDream", "Make websites for the ccinternet. Start a new site in /home/Sites, or open a folder of .ccmd pages.", { "Later", "Open Folder", "New Site" })
	if (Choice == 3) then
		PJ.NewSite()
	elseif (Choice == 2) then
		PJ.OpenFolder()
	end
end
Page:Run()
