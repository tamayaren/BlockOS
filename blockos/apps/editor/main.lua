-- Editor: a code editor with Lua syntax highlighting, selection, undo, find and run.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Args = { ... }

local Keywords = {}
for Word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%S+") do
	Keywords[Word] = true
end

local Builtins = {}
for Word in ([[print write read pairs ipairs require type tostring tonumber error assert pcall xpcall select next
	setmetatable getmetatable rawget rawset rawequal load loadstring loadfile dofile unpack sleep table string math
	os io fs term colors colours peripheral rednet http textutils shell multishell window keys turtle coroutine
	parallel settings disk redstone rs vector gps paintutils bit32 bit _G _ENV self BlockOS commands pocket]]):gmatch("%S+") do
	Builtins[Word] = true
end

local Hex = Gfx.Hex

local Doc = {
	Lines = { "" },
	X = 1,
	Y = 1,
	ScrollX = 0,
	ScrollY = 0,
	Path = nil,
	Modified = false,
	Anchor = nil,
	UseTabs = false,
	Undo = {},
	Redo = {}
}

local States = {}
local ValidStates = 0
local Message, MessageTime = nil, 0
local Modifiers = Ui.Modifiers
local Find = ""
local Page = Ui.Page.new()
local Editor

local function Palette(Th)
	if (Th.Dark) then
		return {
			Bg = colors.black, Text = colors.white, Keyword = colors.yellow, String = colors.red,
			Comment = colors.green, Number = colors.purple, Builtin = colors.cyan, Operator = colors.lightGray,
			Gutter = colors.gray, GutterFg = colors.lightGray, Selection = colors.blue
		}
	end
	return {
		Bg = colors.white, Text = colors.black, Keyword = colors.blue, String = colors.red,
		Comment = colors.green, Number = colors.purple, Builtin = colors.cyan, Operator = colors.gray,
		Gutter = colors.lightGray, GutterFg = colors.gray, Selection = colors.lightBlue
	}
end

local function SetMessage(Text)
	Message = Text
	MessageTime = os.clock()
end

local function IsLua()
	return not Doc.Path or Doc.Path:match("%.lua$") ~= nil or not Doc.Path:match("%.%w+$")
end

--
-- Highlighting
--

local function Highlight(Line, State, P)
	local Colors = {}
	local Length = #Line
	local Index = 1
	local function Paint(From, To, Color)
		local Code = Hex[Color]
		for Position = From, math.min(To, Length) do
			Colors[Position] = Code
		end
	end
	if (not IsLua()) then
		Paint(1, Length, P.Text)
		return table.concat(Colors), nil
	end
	if (State) then
		local _, Finish = Line:find(State.Close, 1, true)
		local Color = (State.Kind == "comment") and P.Comment or P.String
		if (not Finish) then
			Paint(1, Length, Color)
			return table.concat(Colors), State
		end
		Paint(1, Finish, Color)
		Index = Finish + 1
		State = nil
	end
	while (Index <= Length) do
		local Char = Line:sub(Index, Index)
		if (Line:sub(Index, Index + 1) == "--") then
			local Level = Line:match("^%[(=*)%[", Index + 2)
			if (Level) then
				local Close = "]" .. Level .. "]"
				local _, Finish = Line:find(Close, Index + 4 + #Level, true)
				if (not Finish) then
					Paint(Index, Length, P.Comment)
					return table.concat(Colors), { Kind = "comment", Close = Close }
				end
				Paint(Index, Finish, P.Comment)
				Index = Finish + 1
			else
				Paint(Index, Length, P.Comment)
				Index = Length + 1
			end
		elseif (Char == "\"" or Char == "'") then
			local Position = Index + 1
			while (Position <= Length) do
				local Next = Line:sub(Position, Position)
				if (Next == "\\") then
					Position = Position + 2
				elseif (Next == Char) then
					break
				else
					Position = Position + 1
				end
			end
			Paint(Index, Position, P.String)
			Index = Position + 1
		elseif (Char == "[" and Line:match("^%[=*%[", Index)) then
			local Level = Line:match("^%[(=*)%[", Index)
			local Close = "]" .. Level .. "]"
			local _, Finish = Line:find(Close, Index + 2 + #Level, true)
			if (not Finish) then
				Paint(Index, Length, P.String)
				return table.concat(Colors), { Kind = "string", Close = Close }
			end
			Paint(Index, Finish, P.String)
			Index = Finish + 1
		elseif (Char:match("%d") or (Char == "." and Line:sub(Index + 1, Index + 1):match("%d"))) then
			local _, Finish = Line:find("^0[xX]%x+", Index)
			if (not Finish) then _, Finish = Line:find("^%d*%.?%d*[eE][%+%-]?%d+", Index) end
			if (not Finish) then _, Finish = Line:find("^%d*%.?%d*", Index) end
			Paint(Index, Finish, P.Number)
			Index = Finish + 1
		elseif (Char:match("[%a_]")) then
			local Start, Finish = Line:find("^[%w_]+", Index)
			local Word = Line:sub(Start, Finish)
			local Color = P.Text
			if (Keywords[Word]) then
				Color = P.Keyword
			elseif (Builtins[Word]) then
				Color = P.Builtin
			end
			Paint(Start, Finish, Color)
			Index = Finish + 1
		else
			Paint(Index, Index, Char:match("[%+%-%*/%%%^#=<>~%.]") and P.Operator or P.Text)
			Index = Index + 1
		end
	end
	return table.concat(Colors), nil
end

local function Invalidate(FromLine)
	ValidStates = math.min(ValidStates, FromLine - 1)
end

local function StateAt(Line, P)
	if (ValidStates < 1) then
		States[1] = nil
		ValidStates = 1
	end
	while (ValidStates < Line) do
		local _, Next = Highlight(Doc.Lines[ValidStates] or "", States[ValidStates], P)
		ValidStates = ValidStates + 1
		States[ValidStates] = Next
	end
	return States[Line]
end

--
-- Text model
--

local function TabWidth()
	return 2
end

local function DisplayWidth(Line, Upto)
	local Width = 0
	for Index = 1, math.min(Upto, #Line) do
		Width = Width + ((Line:sub(Index, Index) == "\t") and TabWidth() or 1)
	end
	return Width
end

local function CharFromDisplay(Line, Column)
	local Width = 0
	for Index = 1, #Line do
		local Step = (Line:sub(Index, Index) == "\t") and TabWidth() or 1
		if (Width + Step > Column) then return Index end
		Width = Width + Step
	end
	return #Line + 1
end

local function Snapshot()
	return { Text = table.concat(Doc.Lines, "\n"), X = Doc.X, Y = Doc.Y }
end

local function Restore(Shot)
	Doc.Lines = {}
	for Line in (Shot.Text .. "\n"):gmatch("(.-)\n") do
		table.insert(Doc.Lines, Line)
	end
	if (#Doc.Lines == 0) then Doc.Lines = { "" } end
	Doc.X, Doc.Y = Shot.X, Shot.Y
	Doc.Anchor = nil
	Invalidate(1)
end

local LastUndoKind, LastUndoTime = nil, 0

local function PushUndo(Kind)
	local Now = os.clock()
	if (Kind == "type" and LastUndoKind == "type" and Now - LastUndoTime < 1.5) then
		LastUndoTime = Now
		return
	end
	table.insert(Doc.Undo, Snapshot())
	if (#Doc.Undo > 100) then table.remove(Doc.Undo, 1) end
	Doc.Redo = {}
	LastUndoKind, LastUndoTime = Kind, Now
end

local function Clamp()
	Doc.Y = math.max(1, math.min(Doc.Y, #Doc.Lines))
	Doc.X = math.max(1, math.min(Doc.X, #Doc.Lines[Doc.Y] + 1))
end

local function SelectionRange()
	if (not Doc.Anchor) then return nil end
	local AX, AY, BX, BY = Doc.Anchor.X, Doc.Anchor.Y, Doc.X, Doc.Y
	if (AY > BY or (AY == BY and AX > BX)) then
		AX, AY, BX, BY = BX, BY, AX, AY
	end
	if (AX == BX and AY == BY) then return nil end
	return AX, AY, BX, BY
end

local function SelectedText()
	local AX, AY, BX, BY = SelectionRange()
	if (not AX) then return nil end
	if (AY == BY) then
		return Doc.Lines[AY]:sub(AX, BX - 1)
	end
	local Parts = { Doc.Lines[AY]:sub(AX) }
	for Line = AY + 1, BY - 1 do
		table.insert(Parts, Doc.Lines[Line])
	end
	table.insert(Parts, Doc.Lines[BY]:sub(1, BX - 1))
	return table.concat(Parts, "\n")
end

local function DeleteSelection()
	local AX, AY, BX, BY = SelectionRange()
	Doc.Anchor = nil
	if (not AX) then return false end
	local Head = Doc.Lines[AY]:sub(1, AX - 1)
	local Tail = Doc.Lines[BY]:sub(BX)
	for _ = AY + 1, BY do
		table.remove(Doc.Lines, AY + 1)
	end
	Doc.Lines[AY] = Head .. Tail
	Doc.X, Doc.Y = AX, AY
	Doc.Modified = true
	Invalidate(AY)
	return true
end

local function InsertText(Text)
	DeleteSelection()
	Text = Text:gsub("\r\n", "\n"):gsub("\r", "\n")
	local Line = Doc.Lines[Doc.Y]
	local Head, Tail = Line:sub(1, Doc.X - 1), Line:sub(Doc.X)
	local Pieces = {}
	for Piece in (Text .. "\n"):gmatch("(.-)\n") do
		table.insert(Pieces, Piece)
	end
	if (#Pieces == 1) then
		Doc.Lines[Doc.Y] = Head .. Pieces[1] .. Tail
		Doc.X = Doc.X + #Pieces[1]
	else
		Doc.Lines[Doc.Y] = Head .. Pieces[1]
		for Index = 2, #Pieces do
			table.insert(Doc.Lines, Doc.Y + Index - 1, Pieces[Index])
		end
		local LastY = Doc.Y + #Pieces - 1
		Doc.X = #Doc.Lines[LastY] + 1
		Doc.Lines[LastY] = Doc.Lines[LastY] .. Tail
		Invalidate(Doc.Y)
		Doc.Y = LastY
	end
	Invalidate(Doc.Y)
	Doc.Modified = true
end

local function ViewSize()
	return Editor.W - Editor.Gutter, Editor.H
end

local function EnsureVisible()
	Clamp()
	local ViewW, ViewH = ViewSize()
	if (Doc.Y <= Doc.ScrollY) then Doc.ScrollY = Doc.Y - 1 end
	if (Doc.Y > Doc.ScrollY + ViewH) then Doc.ScrollY = Doc.Y - ViewH end
	local Column = DisplayWidth(Doc.Lines[Doc.Y], Doc.X - 1)
	if (Column < Doc.ScrollX) then Doc.ScrollX = math.max(0, Column - 4) end
	if (Column >= Doc.ScrollX + ViewW - 1) then Doc.ScrollX = Column - ViewW + 2 end
end

local function SetLines(Text)
	Doc.Lines = {}
	for Line in (Text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
		table.insert(Doc.Lines, Line)
	end
	if (#Doc.Lines > 1 and Doc.Lines[#Doc.Lines] == "") then
		table.remove(Doc.Lines)
	end
	if (#Doc.Lines == 0) then Doc.Lines = { "" } end
	Doc.UseTabs = false
	for _, Line in ipairs(Doc.Lines) do
		if (Line:sub(1, 1) == "\t") then
			Doc.UseTabs = true
			break
		end
	end
	Doc.X, Doc.Y, Doc.ScrollX, Doc.ScrollY = 1, 1, 0, 0
	Doc.Anchor = nil
	Doc.Undo, Doc.Redo = {}, {}
	Doc.Modified = false
	Invalidate(1)
end

local function UpdateTitle()
	BlockOS.SetTitle((Doc.Modified and "\7 " or "") .. (Doc.Path and fs.getName(Doc.Path) or "Untitled"))
end

local function LoadFile(Path)
	local Text = Config.ReadText(Path)
	if (not Text) then
		SetLines("")
		Doc.Path = Path
		SetMessage("New file")
	else
		SetLines(Text)
		Doc.Path = Path
		SetMessage("Opened " .. fs.getName(Path))
	end
	UpdateTitle()
end

local function SaveAs()
	local Path = Ui.PickFile({ Save = true, Dir = Doc.Path and fs.getDir(Doc.Path) or "/home/Documents", Name = Doc.Path and fs.getName(Doc.Path) or "untitled.lua" })
	if (not Path) then return false end
	Doc.Path = Path
	return true
end

local function Save()
	if (not Doc.Path and not SaveAs()) then return false end
	if (fs.isReadOnly(Doc.Path)) then
		Ui.Alert("Save", "This location is read-only.")
		return false
	end
	if (not Config.WriteText(Doc.Path, table.concat(Doc.Lines, "\n") .. "\n")) then
		Ui.Alert("Save", "Could not write " .. Doc.Path)
		return false
	end
	Doc.Modified = false
	SetMessage("Saved " .. fs.getName(Doc.Path))
	UpdateTitle()
	return true
end

-- Returns true when it is safe to discard the current document.
local function ConfirmDiscard()
	if (not Doc.Modified) then return true end
	local Choice = Ui.Alert("Unsaved changes", "Save changes to " .. (Doc.Path and fs.getName(Doc.Path) or "Untitled") .. "?", { "Cancel", "Don't Save", "Save" })
	if (Choice == 3) then return Save() end
	return Choice == 2
end

local function Run()
	if (not Save()) then return end
	BlockOS.Launch(Doc.Path, {}, { Hold = true })
end

local function FindNext(Query, FromStart)
	if (not Query or #Query == 0) then return false end
	local StartY, StartX = Doc.Y, Doc.X
	if (FromStart) then StartY, StartX = 1, 1 end
	for Offset = 0, #Doc.Lines do
		local Line = ((StartY - 1 + Offset) % #Doc.Lines) + 1
		local From = (Offset == 0) and StartX or 1
		local Start, Finish = Doc.Lines[Line]:find(Query, From, true)
		if (Start) then
			Doc.Anchor = { X = Start, Y = Line }
			Doc.X, Doc.Y = Finish + 1, Line
			EnsureVisible()
			return true
		end
	end
	SetMessage("Not found: " .. Query)
	return false
end

local function Indentation(Line)
	return Line:match("^[ \t]*")
end

local function IndentUnit()
	return Doc.UseTabs and "\t" or "  "
end

local function NewLine()
	PushUndo("edit")
	local Line = Doc.Lines[Doc.Y]:sub(1, Doc.X - 1)
	local Indent = Indentation(Doc.Lines[Doc.Y])
	local Trimmed = Line:gsub("%s+$", "")
	if (Trimmed:match("then$") or Trimmed:match("do$") or Trimmed:match("else$") or Trimmed:match("repeat$")
		or Trimmed:match("function%s*[%w_.:]*%b()$") or Trimmed:match("[{(]$")) then
		Indent = Indent .. IndentUnit()
	end
	InsertText("\n" .. Indent)
end

local function Move(Key)
	local Line = Doc.Lines[Doc.Y]
	local _, ViewH = ViewSize()
	if (Key == keys.left) then
		if (Modifiers.Ctrl) then
			local Before = Line:sub(1, Doc.X - 1)
			local Position = Before:find("[%w_]+[^%w_]*$") or 1
			Doc.X = (Position == Doc.X) and math.max(1, Doc.X - 1) or Position
		elseif (Doc.X > 1) then
			Doc.X = Doc.X - 1
		elseif (Doc.Y > 1) then
			Doc.Y = Doc.Y - 1
			Doc.X = #Doc.Lines[Doc.Y] + 1
		end
	elseif (Key == keys.right) then
		if (Modifiers.Ctrl) then
			local _, Finish = Line:find("^[^%w_]*[%w_]*", Doc.X)
			Doc.X = (Finish or #Line) + 1
		elseif (Doc.X <= #Line) then
			Doc.X = Doc.X + 1
		elseif (Doc.Y < #Doc.Lines) then
			Doc.Y = Doc.Y + 1
			Doc.X = 1
		end
	elseif (Key == keys.up or Key == keys.down or Key == keys.pageUp or Key == keys.pageDown) then
		local Column = DisplayWidth(Line, Doc.X - 1)
		local Step = ({ [keys.up] = -1, [keys.down] = 1, [keys.pageUp] = -ViewH, [keys.pageDown] = ViewH })[Key]
		Doc.Y = math.max(1, math.min(#Doc.Lines, Doc.Y + Step))
		Doc.X = CharFromDisplay(Doc.Lines[Doc.Y], Column)
	elseif (Key == keys.home) then
		if (Modifiers.Ctrl) then
			Doc.Y = 1
			Doc.X = 1
		else
			local Indent = #Indentation(Line) + 1
			Doc.X = (Doc.X == Indent) and 1 or Indent
		end
	elseif (Key == keys["end"]) then
		if (Modifiers.Ctrl) then Doc.Y = #Doc.Lines end
		Doc.X = #Doc.Lines[Doc.Y] + 1
	else
		return false
	end
	return true
end

--
-- Commands
--

local Clipboard = nil

local function Copy(Cut)
	local Text = SelectedText()
	if (not Text) then
		Text = Doc.Lines[Doc.Y] .. "\n"
		if (Cut) then
			PushUndo("edit")
			if (#Doc.Lines > 1) then
				table.remove(Doc.Lines, Doc.Y)
			else
				Doc.Lines[1] = ""
			end
			Doc.Modified = true
			Invalidate(Doc.Y)
		end
	elseif (Cut) then
		PushUndo("edit")
		DeleteSelection()
	end
	Clipboard = Text
	BlockOS.TextClipboard = Text
	SetMessage(Cut and "Cut" or "Copied")
end

local function PasteInternal()
	local Text = BlockOS.TextClipboard or Clipboard
	if (not Text) then return end
	PushUndo("edit")
	InsertText(Text)
end

local function UndoStep(Reverse)
	local From, To = Doc.Undo, Doc.Redo
	if (Reverse) then From, To = Doc.Redo, Doc.Undo end
	local Shot = table.remove(From)
	if (not Shot) then return end
	table.insert(To, Snapshot())
	Restore(Shot)
	Doc.Modified = true
	LastUndoKind = nil
end

local function ReplaceAll()
	local Query = Ui.Prompt("Replace", "Find:", Find)
	if (not Query or #Query == 0) then return end
	local Replacement = Ui.Prompt("Replace", "Replace with:", "")
	if (not Replacement) then return end
	PushUndo("edit")
	local Count = 0
	local Pattern = Query:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	local Safe = Replacement:gsub("%%", "%%%%")
	for Index, Line in ipairs(Doc.Lines) do
		local Updated, Hits = Line:gsub(Pattern, Safe)
		Doc.Lines[Index] = Updated
		Count = Count + Hits
	end
	Find = Query
	Doc.Modified = Count > 0 or Doc.Modified
	Invalidate(1)
	SetMessage("Replaced " .. Count .. " occurrence" .. (Count == 1 and "" or "s"))
end

local function GoToLine()
	local Value = tonumber(Ui.Prompt("Go to Line", "Line number (1-" .. #Doc.Lines .. "):", tostring(Doc.Y)) or "")
	if (Value) then
		Doc.Y = math.floor(Value)
		Doc.X = 1
		Doc.Anchor = nil
		EnsureVisible()
	end
end

local function NewDocument()
	if (not ConfirmDiscard()) then return end
	SetLines("")
	Doc.Path = nil
	UpdateTitle()
end

local function OpenDocument()
	if (not ConfirmDiscard()) then return end
	local Path = Ui.PickFile({ Dir = Doc.Path and fs.getDir(Doc.Path) or "/home/Documents" })
	if (Path) then LoadFile(Path) end
end

local function Close()
	if (ConfirmDiscard()) then
		BlockOS.Quit()
		Page:Stop()
	end
end

local function FileMenu()
	local Options = { "New", "Open...", "Save", "Save As...", "-", "Run", "-", "Close" }
	local Choice = Options[Ui.ContextMenu(1, 2, Options) or 0]
	if (Choice == "New") then
		NewDocument()
	elseif (Choice == "Open...") then
		OpenDocument()
	elseif (Choice == "Save") then
		Save()
	elseif (Choice == "Save As...") then
		if (SaveAs()) then Save() end
	elseif (Choice == "Run") then
		Run()
	elseif (Choice == "Close") then
		Close()
	end
end

local function EditMenu()
	local Options = { "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Find...", "Find Next", "Replace...", "Go to Line..." }
	local Choice = Options[Ui.ContextMenu(7, 2, Options) or 0]
	if (Choice == "Undo") then
		UndoStep(false)
	elseif (Choice == "Redo") then
		UndoStep(true)
	elseif (Choice == "Cut" or Choice == "Copy") then
		Copy(Choice == "Cut")
	elseif (Choice == "Paste") then
		PasteInternal()
	elseif (Choice == "Select All") then
		Doc.Anchor = { X = 1, Y = 1 }
		Doc.Y = #Doc.Lines
		Doc.X = #Doc.Lines[Doc.Y] + 1
	elseif (Choice == "Find...") then
		local Query = Ui.Prompt("Find", "Search for:", Find)
		if (Query) then
			Find = Query
			FindNext(Find)
		end
	elseif (Choice == "Find Next") then
		FindNext(Find)
	elseif (Choice == "Replace...") then
		ReplaceAll()
	elseif (Choice == "Go to Line...") then
		GoToLine()
	end
	EnsureVisible()
end

--
-- Editor widget
--

local function DrawEditor(Self, T, Th)
	local P = Palette(Th)
	local Digits = #tostring(#Doc.Lines)
	Self.Gutter = Digits + 2
	local ViewW = Self.W - Self.Gutter
	local AX, AY, BX, BY = SelectionRange()
	for Row = 1, Self.H do
		local LineIndex = Doc.ScrollY + Row
		local Y = Self.Y + Row - 1
		local Line = Doc.Lines[LineIndex]
		if (not Line) then
			Gfx.Fill(T, Self.X, Y, Self.Gutter, 1, P.Gutter)
			Gfx.Fill(T, Self.X + Self.Gutter, Y, ViewW, 1, P.Bg)
		else
			local Number = Gfx.Pad(tostring(LineIndex), Digits, "right") .. " "
			Gfx.Write(T, Self.X, Y, " " .. Number, (LineIndex == Doc.Y) and P.Text or P.GutterFg, P.Gutter)
			local Colors = Highlight(Line, StateAt(LineIndex, P), P)
			local Chars, Fg, Bg = {}, {}, {}
			local BgCode, SelCode = Hex[P.Bg], Hex[P.Selection]
			for Index = 1, #Line do
				local Char = Line:sub(Index, Index)
				local Selected = AX and (LineIndex > AY or (LineIndex == AY and Index >= AX)) and (LineIndex < BY or (LineIndex == BY and Index < BX))
				local Code = Colors:sub(Index, Index)
				if (Code == "") then Code = Hex[P.Text] end
				if (Char == "\t") then
					for _ = 1, TabWidth() do
						table.insert(Chars, " ")
						table.insert(Fg, Code)
						table.insert(Bg, Selected and SelCode or BgCode)
					end
				else
					table.insert(Chars, Char)
					table.insert(Fg, Code)
					table.insert(Bg, Selected and SelCode or BgCode)
				end
			end
			local Text = table.concat(Chars):sub(Doc.ScrollX + 1, Doc.ScrollX + ViewW)
			local FgText = table.concat(Fg):sub(Doc.ScrollX + 1, Doc.ScrollX + ViewW)
			local BgText = table.concat(Bg):sub(Doc.ScrollX + 1, Doc.ScrollX + ViewW)
			local Padding = ViewW - #Text
			T.setCursorPos(Self.X + Self.Gutter, Y)
			T.blit(Text .. string.rep(" ", Padding), FgText .. string.rep(Hex[P.Text], Padding), BgText .. string.rep(BgCode, Padding))
		end
	end
end

local function EditorCursor(Self)
	local Row = Doc.Y - Doc.ScrollY
	if (Row < 1 or Row > Self.H) then return nil end
	local Column = DisplayWidth(Doc.Lines[Doc.Y], Doc.X - 1) - Doc.ScrollX
	if (Column < 0 or Column >= Self.W - Self.Gutter) then return nil end
	local Th = BlockOS.Require("theme").Get()
	return Self.X + Self.Gutter + Column, Self.Y + Row - 1, Palette(Th).Text
end

local function PositionFromMouse(Self, X, Y)
	local LineIndex = math.max(1, math.min(#Doc.Lines, Doc.ScrollY + Y - Self.Y + 1))
	local Column = math.max(0, X - Self.X - Self.Gutter + Doc.ScrollX)
	return CharFromDisplay(Doc.Lines[LineIndex], Column), LineIndex
end

local function EditorEvent(Self, Name, A, B, C)
	if (Name == "mouse_click" or Name == "mouse_drag") then
		local X, Y = PositionFromMouse(Self, B, C)
		if (Name == "mouse_click") then
			if (A == 2) then
				EditMenu()
				return true
			end
			Doc.Anchor = Modifiers.Shift and (Doc.Anchor or { X = Doc.X, Y = Doc.Y }) or { X = X, Y = Y }
		end
		Doc.X, Doc.Y = X, Y
		EnsureVisible()
		return true
	elseif (Name == "mouse_up") then
		if (Doc.Anchor and Doc.Anchor.X == Doc.X and Doc.Anchor.Y == Doc.Y) then
			Doc.Anchor = nil
		end
		return true
	elseif (Name == "mouse_scroll") then
		Doc.ScrollY = math.max(0, math.min(Doc.ScrollY + A * 3, math.max(0, #Doc.Lines - Self.H)))
		return true
	elseif (Name == "char") then
		if (Modifiers.Ctrl) then return true end
		PushUndo((A == " ") and "space" or "type")
		InsertText(A)
		EnsureVisible()
		return true
	elseif (Name == "paste") then
		PushUndo("edit")
		InsertText(A)
		EnsureVisible()
		return true
	elseif (Name == "key") then
		if (Modifiers.Ctrl) then
			if (A == keys.s) then
				Save()
			elseif (A == keys.o) then
				OpenDocument()
			elseif (A == keys.n) then
				NewDocument()
			elseif (A == keys.z) then
				UndoStep(false)
			elseif (A == keys.y) then
				UndoStep(true)
			elseif (A == keys.c or A == keys.x) then
				Copy(A == keys.x)
			elseif (A == keys.a) then
				Doc.Anchor = { X = 1, Y = 1 }
				Doc.Y = #Doc.Lines
				Doc.X = #Doc.Lines[Doc.Y] + 1
			elseif (A == keys.f) then
				local Query = Ui.Prompt("Find", "Search for:", Find)
				if (Query) then
					Find = Query
					FindNext(Find)
				end
			elseif (A == keys.h) then
				ReplaceAll()
			elseif (A == keys.g) then
				GoToLine()
			elseif (A == keys.d) then
				PushUndo("edit")
				table.insert(Doc.Lines, Doc.Y + 1, Doc.Lines[Doc.Y])
				Doc.Y = Doc.Y + 1
				Doc.Modified = true
				Invalidate(Doc.Y)
			elseif (A == keys.q or A == keys.w) then
				Close()
			elseif (not Move(A)) then
				return false
			elseif (not Modifiers.Shift) then
				Doc.Anchor = nil
			end
			EnsureVisible()
			return true
		end
		local Before = { X = Doc.X, Y = Doc.Y }
		if (Move(A)) then
			if (Modifiers.Shift) then
				Doc.Anchor = Doc.Anchor or Before
			else
				Doc.Anchor = nil
			end
		elseif (A == keys.enter or A == keys.numPadEnter) then
			NewLine()
		elseif (A == keys.backspace) then
			PushUndo("delete")
			if (not DeleteSelection()) then
				if (Doc.X > 1) then
					local Line = Doc.Lines[Doc.Y]
					local Unit = IndentUnit()
					if (Line:sub(1, Doc.X - 1):match("^%s+$") and Line:sub(Doc.X - #Unit, Doc.X - 1) == Unit) then
						Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - #Unit - 1) .. Line:sub(Doc.X)
						Doc.X = Doc.X - #Unit
					else
						Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 2) .. Line:sub(Doc.X)
						Doc.X = Doc.X - 1
					end
				elseif (Doc.Y > 1) then
					local Previous = Doc.Lines[Doc.Y - 1]
					Doc.Lines[Doc.Y - 1] = Previous .. Doc.Lines[Doc.Y]
					table.remove(Doc.Lines, Doc.Y)
					Doc.Y = Doc.Y - 1
					Doc.X = #Previous + 1
				end
				Doc.Modified = true
				Invalidate(Doc.Y)
			end
		elseif (A == keys.delete) then
			PushUndo("delete")
			if (not DeleteSelection()) then
				local Line = Doc.Lines[Doc.Y]
				if (Doc.X <= #Line) then
					Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 1) .. Line:sub(Doc.X + 1)
				elseif (Doc.Y < #Doc.Lines) then
					Doc.Lines[Doc.Y] = Line .. Doc.Lines[Doc.Y + 1]
					table.remove(Doc.Lines, Doc.Y + 1)
				end
				Doc.Modified = true
				Invalidate(Doc.Y)
			end
		elseif (A == keys.tab) then
			PushUndo("edit")
			InsertText(IndentUnit())
		elseif (A == keys.f3) then
			FindNext(Find)
		elseif (A == keys.f5) then
			Run()
		else
			return false
		end
		EnsureVisible()
		return true
	end
	return false
end

function Page:OnLayout(W, H)
	self:Clear()
	self:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
	self:Add(Ui.Button.new({ X = 1, Y = 1, Text = "File", Bg = "Panel", OnClick = function() FileMenu() end }))
	self:Add(Ui.Button.new({ X = 7, Y = 1, Text = "Edit", Bg = "Panel", OnClick = function() EditMenu() end }))
	self:Add(Ui.Button.new({ X = W - 13, Y = 1, W = 6, Text = "Save", Bg = "Panel", OnClick = function() Save() end }))
	self:Add(Ui.Button.new({ X = W - 6, Y = 1, W = 7, Text = "Run \16", Style = "primary", OnClick = function() Run() end }))
	Editor = self:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = W, H = H - 2, Gutter = 3, Focusable = true, KeepFocus = true,
		OnDraw = DrawEditor,
		OnEvent = EditorEvent,
		OnCursor = EditorCursor
	}))
	self:Add(Ui.Canvas.new({
		X = 1, Y = H, W = W, H = 1,
		OnDraw = function(Self, T, Th)
			local Left = " Ln " .. Doc.Y .. ", Col " .. Doc.X .. (Doc.Modified and "  \7 Edited" or "")
			local Right = (IsLua() and "Lua" or "Text") .. " "
			if (Message and os.clock() - MessageTime < 4) then
				Right = Message .. "  " .. Right
			end
			Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(Left, Self.W - #Right) .. Right, Th.SubText, Th.Panel)
		end
	}))
	self:SetFocus(Editor)
	EnsureVisible()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_close") then
		Close()
		return true
	elseif (Name == "blockos_open" and A) then
		if (ConfirmDiscard()) then LoadFile(A) end
		return true
	end
	return false
end

function Page:OnTerminate()
	Close()
end

local BaseHandle = Page.Handle
function Page:Handle(...)
	BaseHandle(self, ...)
	if (Doc.Modified ~= self.LastModified) then
		self.LastModified = Doc.Modified
		UpdateTitle()
	end
end

BlockOS.SetCloseHandler(true)
if (Args[1]) then
	LoadFile(shell and shell.resolve(Args[1]) or Args[1])
else
	UpdateTitle()
end
Page:SetInterval(1, function()
	return Message ~= nil
end)
Page:Run()
