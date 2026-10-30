-- Notes: a notepad with a list of notes, word wrap and autosave. Also opens .txt files.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Args = { ... }

local Folder = "/home/Notes"
local SaveDelay = 1.5

local Page = Ui.Page.new()
local Notes = {}
local Doc = nil
local Rows = {}
local Layout = { SideW = 0, EX = 1, EY = 2, EW = 10, EH = 5 }
local Build

local function SplitLines(Text)
	local Lines = {}
	for Line in ((Text or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		table.insert(Lines, Line)
	end
	if (#Lines == 0) then Lines[1] = "" end
	return Lines
end

local function TitleOf(Lines, Path)
	for _, Line in ipairs(Lines) do
		local Trimmed = Line:match("^%s*(.-)%s*$")
		if (#Trimmed > 0) then return Trimmed end
	end
	return Path and fs.getName(Path):gsub("%.txt$", "") or "New Note"
end

local function Modified(Path)
	local Ok, Attributes = pcall(fs.attributes, Path)
	return Ok and Attributes and Attributes.modified or 0
end

local function LoadNotes()
	if (not fs.exists(Folder)) then fs.makeDir(Folder) end
	Notes = {}
	for _, Name in ipairs(fs.list(Folder)) do
		local Path = "/" .. fs.combine(Folder, Name)
		if (Name:match("%.txt$") and not fs.isDir(Path)) then
			local Lines = SplitLines(Config.ReadText(Path))
			table.insert(Notes, { Path = Path, Title = TitleOf(Lines, Path), Modified = Modified(Path) })
		end
	end
	table.sort(Notes, function(A, B) return A.Modified > B.Modified end)
	if (Doc and Doc.Path and not Doc.Path:find("^" .. Folder .. "/")) then
		table.insert(Notes, 1, { Path = Doc.Path, Title = fs.getName(Doc.Path), External = true })
	end
end

local function WordCount()
	local Count = 0
	for _, Line in ipairs(Doc.Lines) do
		for _ in Line:gmatch("%S+") do Count = Count + 1 end
	end
	return Count
end

local function Save()
	if (not Doc or not Doc.Dirty) then return true end
	local Ok = Config.WriteText(Doc.Path, table.concat(Doc.Lines, "\n"))
	if (Ok) then
		Doc.Dirty = false
		for _, Note in ipairs(Notes) do
			if (Note.Path == Doc.Path and not Note.External) then
				Note.Title = TitleOf(Doc.Lines, Doc.Path)
			end
		end
	end
	return Ok
end

local function Open(Path)
	Save()
	Doc = { Path = Path, Lines = SplitLines(Config.ReadText(Path)), X = 1, Y = 1, Scroll = 0, GoalX = nil, Dirty = false }
	BlockOS.SetTitle(fs.getName(Path))
end

local function NewNote()
	Save()
	local Path = "/" .. fs.combine(Folder, "Note " .. os.date("%Y-%m-%d %H%M%S") .. ".txt")
	Config.WriteText(Path, "")
	Open(Path)
	LoadNotes()
end

--
-- Word wrap
--

-- Splits a line into visual rows, breaking after the last space that fits.
local function Segments(Text, Width)
	local Starts = { 1 }
	local Position = 1
	while (#Text - Position + 1 >= Width) do
		local Chunk = Text:sub(Position, Position + Width - 1)
		local Break = Chunk:match("^.*() ")
		if (Break and Break > 1) then
			Position = Position + Break
		else
			Position = Position + Width
		end
		table.insert(Starts, Position)
	end
	return Starts
end

local function Rewrap()
	Rows = {}
	local Width = math.max(4, Layout.EW)
	for Index, Line in ipairs(Doc.Lines) do
		local Starts = Segments(Line, Width)
		for Part, Start in ipairs(Starts) do
			local Stop = Starts[Part + 1] and (Starts[Part + 1] - 1) or (#Line + 1)
			table.insert(Rows, { Line = Index, Start = Start, Stop = Stop, Last = Starts[Part + 1] == nil })
		end
	end
end

local function CursorRow()
	for Index, Row in ipairs(Rows) do
		if (Row.Line == Doc.Y and Doc.X >= Row.Start and Doc.X <= Row.Stop) then
			return Index, Row
		end
	end
	return #Rows, Rows[#Rows]
end

local function EnsureVisible()
	local Index = CursorRow()
	if (Index <= Doc.Scroll) then
		Doc.Scroll = Index - 1
	elseif (Index > Doc.Scroll + Layout.EH) then
		Doc.Scroll = Index - Layout.EH
	end
	Doc.Scroll = math.max(0, math.min(Doc.Scroll, math.max(0, #Rows - 1)))
end

local function Changed()
	Doc.Dirty = true
	Doc.LastEdit = os.clock()
	Doc.GoalX = nil
	Rewrap()
	EnsureVisible()
end

--
-- Editing
--

local function Insert(Text)
	local Line = Doc.Lines[Doc.Y]
	Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 1) .. Text .. Line:sub(Doc.X)
	Doc.X = Doc.X + #Text
	Changed()
end

local function NewLine()
	local Line = Doc.Lines[Doc.Y]
	local Indent = Line:match("^([%-%*] )") or ""
	Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 1)
	table.insert(Doc.Lines, Doc.Y + 1, Indent .. Line:sub(Doc.X))
	Doc.Y = Doc.Y + 1
	Doc.X = #Indent + 1
	Changed()
end

local function Backspace()
	if (Doc.X > 1) then
		local Line = Doc.Lines[Doc.Y]
		Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 2) .. Line:sub(Doc.X)
		Doc.X = Doc.X - 1
	elseif (Doc.Y > 1) then
		local Previous = Doc.Lines[Doc.Y - 1]
		Doc.Lines[Doc.Y - 1] = Previous .. Doc.Lines[Doc.Y]
		table.remove(Doc.Lines, Doc.Y)
		Doc.Y = Doc.Y - 1
		Doc.X = #Previous + 1
	else
		return
	end
	Changed()
end

local function Delete()
	local Line = Doc.Lines[Doc.Y]
	if (Doc.X <= #Line) then
		Doc.Lines[Doc.Y] = Line:sub(1, Doc.X - 1) .. Line:sub(Doc.X + 1)
	elseif (Doc.Y < #Doc.Lines) then
		Doc.Lines[Doc.Y] = Line .. Doc.Lines[Doc.Y + 1]
		table.remove(Doc.Lines, Doc.Y + 1)
	else
		return
	end
	Changed()
end

local function MoveVertical(Step)
	local Index, Row = CursorRow()
	local Target = Rows[Index + Step]
	if (not Target) then
		Doc.X = (Step < 0) and 1 or (#Doc.Lines[Doc.Y] + 1)
		return
	end
	Doc.GoalX = Doc.GoalX or (Doc.X - Row.Start)
	Doc.Y = Target.Line
	Doc.X = math.min(Target.Start + Doc.GoalX, Target.Stop)
end

local function MoveHorizontal(Step)
	Doc.GoalX = nil
	if (Step < 0) then
		if (Doc.X > 1) then
			Doc.X = Doc.X - 1
		elseif (Doc.Y > 1) then
			Doc.Y = Doc.Y - 1
			Doc.X = #Doc.Lines[Doc.Y] + 1
		end
	elseif (Doc.X <= #Doc.Lines[Doc.Y]) then
		Doc.X = Doc.X + 1
	elseif (Doc.Y < #Doc.Lines) then
		Doc.Y = Doc.Y + 1
		Doc.X = 1
	end
end

local function HandleKey(Key)
	local Ctrl = Ui.Modifiers.Ctrl
	if (Ctrl and Key == keys.s) then
		Save()
	elseif (Ctrl and Key == keys.n) then
		NewNote()
		Build()
		return true
	elseif (Key == keys.enter or Key == keys.numPadEnter) then
		NewLine()
	elseif (Key == keys.backspace) then
		Backspace()
	elseif (Key == keys.delete) then
		Delete()
	elseif (Key == keys.tab) then
		Insert("  ")
	elseif (Key == keys.left or Key == keys.right) then
		MoveHorizontal(Key == keys.left and -1 or 1)
	elseif (Key == keys.up or Key == keys.down) then
		MoveVertical(Key == keys.up and -1 or 1)
	elseif (Key == keys.pageUp or Key == keys.pageDown) then
		for _ = 1, Layout.EH - 1 do
			MoveVertical(Key == keys.pageUp and -1 or 1)
		end
	elseif (Key == keys.home or Key == keys["end"]) then
		local _, Row = CursorRow()
		Doc.X = (Key == keys.home) and Row.Start or Row.Stop
		Doc.GoalX = nil
	else
		return false
	end
	EnsureVisible()
	return true
end

--
-- Layout
--

local function SelectNote(Path)
	Open(Path)
	Rewrap()
	Build()
end

local function DeleteCurrent()
	if (not Doc) then return end
	local Title = TitleOf(Doc.Lines, Doc.Path)
	if (not Ui.Confirm("Delete Note", "Delete \"" .. Gfx.Truncate(Title, 20) .. "\"?", "Delete")) then return end
	fs.delete(Doc.Path)
	Doc = nil
	LoadNotes()
	if (#Notes == 0) then
		NewNote()
	else
		Open(Notes[1].Path)
	end
	Rewrap()
	Build()
end

local Editor

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Layout.SideW = (W >= 36) and 14 or 0
	Layout.EX = Layout.SideW + 2
	Layout.EY = 2
	Layout.EW = W - Layout.SideW - 2
	Layout.EH = H - 2
	Rewrap()
	EnsureVisible()

	Page:Add(Ui.Canvas.new({
		X = 1, Y = 1, W = W, H = 1,
		OnDraw = function(Self, T, Th)
			Gfx.Fill(T, Self.X, Self.Y, Self.W, 1, Th.Panel)
		end
	}))
	Page:Add(Ui.Button.new({ X = 1, Y = 1, Text = " + New ", Style = "plain", Bg = "Panel", OnClick = function()
		NewNote()
		Rewrap()
		Build()
	end }))
	Page:Add(Ui.Button.new({ X = 9, Y = 1, Text = " Delete ", Style = "plain", Bg = "Panel", OnClick = DeleteCurrent }))
	if (W >= 34) then
		Page:Add(Ui.Button.new({ X = 18, Y = 1, Text = " Print ", Style = "plain", Bg = "Panel", OnClick = function()
			Save()
			if (Doc.Path) then BlockOS.Launch("print", { Doc.Path }) end
		end }))
	end
	if (Layout.SideW == 0) then
		Page:Add(Ui.Button.new({ X = W - 7, Y = 1, W = 7, Text = "Notes \31", Style = "plain", Bg = "Panel", OnClick = function()
			local Names = {}
			for _, Note in ipairs(Notes) do table.insert(Names, Note.Title) end
			local Index = Ui.Choose("Notes", Names)
			if (Index) then SelectNote(Notes[Index].Path) end
		end }))
	end

	if (Layout.SideW > 0) then
		local Items = {}
		local Selected = 1
		for Index, Note in ipairs(Notes) do
			local Title = (Doc and Note.Path == Doc.Path) and TitleOf(Doc.Lines, Doc.Path) or Note.Title
			table.insert(Items, { Text = Title, Path = Note.Path })
			if (Doc and Note.Path == Doc.Path) then Selected = Index end
		end
		local List = Page:Add(Ui.List.new({ X = 1, Y = 2, W = Layout.SideW, H = H - 1, Bg = "Panel", SingleClick = true }))
		List:SetItems(Items)
		List.Selected = Selected
		List.OnActivate = function(_, _, Item)
			if (Item and (not Doc or Item.Path ~= Doc.Path)) then
				SelectNote(Item.Path)
			else
				Page:SetFocus(Editor)
			end
		end
	end

	Editor = Page:Add(Ui.Canvas.new({
		X = Layout.EX, Y = Layout.EY, W = Layout.EW, H = Layout.EH, Focusable = true, KeepFocus = true,
		OnDraw = function(Self, T, Th)
			for Offset = 1, Self.H do
				local Row = Rows[Doc.Scroll + Offset]
				local Text = ""
				local Fg = Th.Text
				if (Row) then
					Text = Doc.Lines[Row.Line]:sub(Row.Start, Row.Last and #Doc.Lines[Row.Line] or Row.Stop)
					if (Row.Line == 1) then Fg = Th.Accent end
				end
				Gfx.Write(T, Self.X, Self.Y + Offset - 1, Gfx.Pad(Text, Self.W), Fg, Th.WindowBg)
			end
		end,
		OnCursor = function(Self, Th)
			local Index, Row = CursorRow()
			local Y = Index - Doc.Scroll
			if (Y < 1 or Y > Self.H) then return nil end
			return Self.X + Doc.X - Row.Start, Self.Y + Y - 1, Th.Text
		end,
		OnEvent = function(Self, Name, A, B, C)
			if (Name == "char") then
				Insert(A)
				return true
			elseif (Name == "paste") then
				Insert((A:gsub("[\r\n]", " ")))
				return true
			elseif (Name == "key") then
				return HandleKey(A)
			elseif (Name == "mouse_click" or Name == "mouse_drag") then
				local Row = Rows[Doc.Scroll + C - Self.Y + 1] or Rows[#Rows]
				Doc.Y = Row.Line
				Doc.X = math.max(Row.Start, math.min(Row.Start + B - Self.X, Row.Stop))
				Doc.GoalX = nil
				return true
			elseif (Name == "mouse_scroll") then
				Doc.Scroll = math.max(0, math.min(Doc.Scroll + A * 2, math.max(0, #Rows - Self.H)))
				return true
			end
			return false
		end
	}))

	Page:Add(Ui.Label.new({
		X = Layout.EX, Y = H, W = Layout.EW, Fg = "SubText",
		Text = function()
			local Words = WordCount()
			return (Doc.Dirty and "Edited" or "Saved") .. " \7 " .. Words .. (Words == 1 and " word" or " words")
		end
	}))
	Page:SetFocus(Editor)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_close") then
		Save()
		self:Stop()
		return true
	elseif (Name == "blockos_open" and A and fs.exists(A)) then
		Open(A)
		LoadNotes()
		Build()
		return true
	end
	return false
end

function Page:OnTerminate()
	Save()
	self:Stop()
end

-- Autosave a moment after typing stops.
Page:SetInterval(1, function()
	if (Doc and Doc.Dirty and os.clock() - (Doc.LastEdit or 0) >= SaveDelay) then
		Save()
		return true
	end
	return false
end)

BlockOS.SetCloseHandler(true)
local Target = Args[1] and (shell and shell.resolve(Args[1]) or Args[1])
if (Target and not Target:find("^/")) then Target = "/" .. Target end
if (Target and fs.exists(Target) and not fs.isDir(Target)) then
	Open(Target)
	LoadNotes()
else
	LoadNotes()
	if (#Notes == 0) then
		NewNote()
	else
		Open(Notes[1].Path)
	end
end
Page:Run()
Save()
