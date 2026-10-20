-- Brocreate: paint pictures with solid colours and text characters, save them and set them as the wallpaper.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Image = BlockOS.Require("image")
local Wallpaper = BlockOS.Require("wallpaper")

local Args = { ... }

local Folder = "/home/Pictures"
local MaxUndo = 30
local MaxSide = 164

local Tools = {
	{ ID = "pen", Label = "Pen", Short = "Pn" },
	{ ID = "line", Label = "Line", Short = "Ln" },
	{ ID = "box", Label = "Box", Short = "Bx" },
	{ ID = "fill", Label = "Fill", Short = "Fl" },
	{ ID = "text", Label = "Text", Short = "Tx" },
	{ ID = "pick", Label = "Pick", Short = "Pk" },
	{ ID = "erase", Label = "Erase", Short = "Er" }
}

-- Palette entries that need dark marks on top.
local Light = { ["0"] = true, ["1"] = true, ["3"] = true, ["4"] = true, ["5"] = true, ["6"] = true, ["8"] = true, ["9"] = true }

local Page = Ui.Page.new()
local State = { Tool = "pen", Ink = "solid", Char = "#", Primary = "f", Secondary = "0", Filled = false }
local View = { ScrollX = 0, ScrollY = 0 }
local Layout = { CX = 1, CY = 2, CW = 1, CH = 1, Swatch = 2 }
local Doc, Stroke, Caret, Hover, CanvasWidget
local Undo, Redo = {}, {}

--
-- Document
--

local function FromImage(Img)
	local NewDoc = { W = Img.W, H = Img.H, Text = {}, Fg = {}, Bg = {}, Base = Img.Rows[1][3]:sub(1, 1) }
	for Y = 1, Img.H do
		local Row = Img.Rows[Y]
		local Text, Fg, Bg = {}, {}, {}
		for X = 1, Img.W do
			Text[X] = Row[1]:sub(X, X)
			Fg[X] = Row[2]:sub(X, X)
			Bg[X] = Row[3]:sub(X, X)
		end
		NewDoc.Text[Y], NewDoc.Fg[Y], NewDoc.Bg[Y] = Text, Fg, Bg
	end
	return NewDoc
end

local function ToImage()
	local Rows = {}
	for Y = 1, Doc.H do
		Rows[Y] = { table.concat(Doc.Text[Y]), table.concat(Doc.Fg[Y]), table.concat(Doc.Bg[Y]) }
	end
	return { W = Doc.W, H = Doc.H, Rows = Rows }
end

local function DisplayName()
	return Doc.Path and fs.getName(Doc.Path) or "Untitled"
end

local function UpdateTitle()
	BlockOS.SetTitle(DisplayName() .. (Doc.Dirty and " *" or ""))
end

local function MarkDirty()
	if (Doc.Dirty) then return end
	Doc.Dirty = true
	UpdateTitle()
end

local function ClampScroll()
	View.ScrollX = math.max(0, math.min(View.ScrollX, Doc.W - Layout.CW))
	View.ScrollY = math.max(0, math.min(View.ScrollY, Doc.H - Layout.CH))
end

local function SetDoc(NewDoc, Path)
	Doc = NewDoc
	Doc.Path = Path
	Doc.Dirty = false
	Undo, Redo = {}, {}
	View.ScrollX, View.ScrollY = 0, 0
	Stroke, Caret, Hover = nil, nil, nil
	UpdateTitle()
	Page:Invalidate()
end

local function PushUndo()
	table.insert(Undo, ToImage())
	if (#Undo > MaxUndo) then table.remove(Undo, 1) end
	Redo = {}
end

local function Restore(Snapshot)
	local Restored = FromImage(Snapshot)
	Restored.Path, Restored.Base = Doc.Path, Doc.Base
	Doc = Restored
	ClampScroll()
	MarkDirty()
end

local function DoUndo()
	if (#Undo == 0) then return end
	table.insert(Redo, ToImage())
	Restore(table.remove(Undo))
end

local function DoRedo()
	if (#Redo == 0) then return end
	table.insert(Undo, ToImage())
	Restore(table.remove(Redo))
end

local function HasCharacters()
	for Y = 1, Doc.H do
		for X = 1, Doc.W do
			if (Doc.Text[Y][X] ~= " ") then return true end
		end
	end
	return false
end

--
-- Painting
--

local function InBounds(X, Y)
	return X >= 1 and Y >= 1 and X <= Doc.W and Y <= Doc.H
end

-- What a cell becomes under the current ink (solid colour, character or eraser).
local function Inked(X, Y, Color)
	if (State.Tool == "erase") then
		return " ", "f", Doc.Base
	elseif (State.Ink == "solid") then
		return " ", Doc.Fg[Y][X], Color
	end
	return State.Char, Color, Doc.Bg[Y][X]
end

local function Plot(X, Y, Color)
	if (not InBounds(X, Y)) then return end
	Doc.Text[Y][X], Doc.Fg[Y][X], Doc.Bg[Y][X] = Inked(X, Y, Color)
end

local function LinePoints(X1, Y1, X2, Y2)
	local Points = {}
	local DX, DY = math.abs(X2 - X1), -math.abs(Y2 - Y1)
	local StepX = (X1 < X2) and 1 or -1
	local StepY = (Y1 < Y2) and 1 or -1
	local Err = DX + DY
	while (true) do
		table.insert(Points, { X1, Y1 })
		if (X1 == X2 and Y1 == Y2) then break end
		local Double = 2 * Err
		if (Double >= DY) then
			Err = Err + DY
			X1 = X1 + StepX
		end
		if (Double <= DX) then
			Err = Err + DX
			Y1 = Y1 + StepY
		end
	end
	return Points
end

local function BoxPoints(X1, Y1, X2, Y2)
	local Points = {}
	local Left, Right = math.max(1, math.min(X1, X2)), math.min(Doc.W, math.max(X1, X2))
	local Top, Bottom = math.max(1, math.min(Y1, Y2)), math.min(Doc.H, math.max(Y1, Y2))
	local EdgeLeft, EdgeRight = math.min(X1, X2), math.max(X1, X2)
	local EdgeTop, EdgeBottom = math.min(Y1, Y2), math.max(Y1, Y2)
	for Y = Top, Bottom do
		for X = Left, Right do
			if (State.Filled or Y == EdgeTop or Y == EdgeBottom or X == EdgeLeft or X == EdgeRight) then
				table.insert(Points, { X, Y })
			end
		end
	end
	return Points
end

local function ShapePoints(Shape)
	if (State.Tool == "line") then
		return LinePoints(Shape.X1, Shape.Y1, Shape.X2, Shape.Y2)
	end
	return BoxPoints(Shape.X1, Shape.Y1, Shape.X2, Shape.Y2)
end

-- Solid ink fills the area of matching background and keeps characters; character ink fills matching cells.
local function Fill(StartX, StartY, Color)
	if (not InBounds(StartX, StartY)) then return false end
	local Solid = State.Ink == "solid"
	local function KeyOf(X, Y)
		if (Solid) then return Doc.Bg[Y][X] end
		return Doc.Text[Y][X] .. Doc.Fg[Y][X] .. Doc.Bg[Y][X]
	end
	local Target = KeyOf(StartX, StartY)
	local Seen = {}
	local Stack = { { StartX, StartY } }
	while (#Stack > 0) do
		local Point = table.remove(Stack)
		local X, Y = Point[1], Point[2]
		local Index = Y * (Doc.W + 1) + X
		if (InBounds(X, Y) and not Seen[Index] and KeyOf(X, Y) == Target) then
			Seen[Index] = true
			if (Solid) then
				Doc.Bg[Y][X] = Color
			else
				Doc.Text[Y][X], Doc.Fg[Y][X] = State.Char, Color
			end
			table.insert(Stack, { X + 1, Y })
			table.insert(Stack, { X - 1, Y })
			table.insert(Stack, { X, Y + 1 })
			table.insert(Stack, { X, Y - 1 })
		end
	end
	return true
end

local function Pick(X, Y, Button)
	if (not InBounds(X, Y)) then return end
	if (Button == 2) then
		State.Secondary = Doc.Bg[Y][X]
	elseif (State.Ink == "char" and Doc.Text[Y][X] ~= " ") then
		State.Primary, State.Char = Doc.Fg[Y][X], Doc.Text[Y][X]
	else
		State.Primary = Doc.Bg[Y][X]
	end
end

--
-- Canvas view
--

-- Page position of image cell 1, 1. Small images are centred, large ones scroll.
local function Origin()
	local OffsetX = (Doc.W <= Layout.CW) and math.floor((Layout.CW - Doc.W) / 2) or -View.ScrollX
	local OffsetY = (Doc.H <= Layout.CH) and math.floor((Layout.CH - Doc.H) / 2) or -View.ScrollY
	return Layout.CX + OffsetX, Layout.CY + OffsetY
end

local function ToCell(PageX, PageY)
	local OriginX, OriginY = Origin()
	return PageX - OriginX + 1, PageY - OriginY + 1
end

local function Pan(DX, DY)
	View.ScrollX = View.ScrollX + DX
	View.ScrollY = View.ScrollY + DY
	ClampScroll()
end

local function BeginStroke(Button, PageX, PageY)
	local X, Y = ToCell(PageX, PageY)
	Hover = { X, Y }
	Caret = nil
	if (Button == 3) then
		Stroke = { Pan = true, LastX = PageX, LastY = PageY }
		return true
	end
	local Color = (Button == 2) and State.Secondary or State.Primary
	local Tool = State.Tool
	if (Tool == "pen" or Tool == "erase") then
		PushUndo()
		Stroke = { LastX = X, LastY = Y, Color = Color }
		Plot(X, Y, Color)
		MarkDirty()
	elseif (Tool == "line" or Tool == "box") then
		Stroke = { Shape = true, X1 = X, Y1 = Y, X2 = X, Y2 = Y, Color = Color }
	elseif (Tool == "fill" and InBounds(X, Y)) then
		PushUndo()
		Fill(X, Y, Color)
		MarkDirty()
	elseif (Tool == "pick") then
		Pick(X, Y, Button)
	elseif (Tool == "text" and InBounds(X, Y)) then
		Caret = { X = X, Y = Y, StartX = X, Color = Color }
	end
	return true
end

local function ContinueStroke(PageX, PageY)
	if (not Stroke) then return false end
	if (Stroke.Pan) then
		Pan(Stroke.LastX - PageX, Stroke.LastY - PageY)
		Stroke.LastX, Stroke.LastY = PageX, PageY
		return true
	end
	local X, Y = ToCell(PageX, PageY)
	Hover = { X, Y }
	if (Stroke.Shape) then
		Stroke.X2, Stroke.Y2 = X, Y
		return true
	end
	for _, Point in ipairs(LinePoints(Stroke.LastX, Stroke.LastY, X, Y)) do
		Plot(Point[1], Point[2], Stroke.Color)
	end
	Stroke.LastX, Stroke.LastY = X, Y
	return true
end

local function EndStroke()
	if (Stroke and Stroke.Shape) then
		PushUndo()
		for _, Point in ipairs(ShapePoints(Stroke)) do
			Plot(Point[1], Point[2], Stroke.Color)
		end
		MarkDirty()
	end
	Stroke = nil
	return true
end

-- Text tool: the whole typing run since the click is one undo step.
local function TypeText(Text)
	if (not Caret) then return false end
	if (not Caret.Pushed) then
		PushUndo()
		Caret.Pushed = true
	end
	for Index = 1, #Text do
		if (InBounds(Caret.X, Caret.Y)) then
			Doc.Text[Caret.Y][Caret.X] = Text:sub(Index, Index)
			Doc.Fg[Caret.Y][Caret.X] = Caret.Color
		end
		Caret.X = math.min(Caret.X + 1, Doc.W + 1)
	end
	MarkDirty()
	return true
end

local function CaretKey(Key)
	if (Key == keys.enter or Key == keys.numPadEnter) then
		Caret.X = Caret.StartX
		Caret.Y = math.min(Caret.Y + 1, Doc.H)
	elseif (Key == keys.backspace) then
		if (Caret.X <= 1) then return true end
		Caret.X = Caret.X - 1
		TypeText(" ")
		Caret.X = Caret.X - 1
	elseif (Key == keys.left or Key == keys.right) then
		Caret.X = math.max(1, math.min(Doc.W, Caret.X + ((Key == keys.left) and -1 or 1)))
	elseif (Key == keys.up or Key == keys.down) then
		Caret.Y = math.max(1, math.min(Doc.H, Caret.Y + ((Key == keys.up) and -1 or 1)))
	else
		return false
	end
	return true
end

local function CanvasKey(Key)
	if (Ui.Modifiers.Ctrl) then return false end
	if (Caret) then return CaretKey(Key) end
	local Step = Ui.Modifiers.Shift and 8 or 1
	if (Key == keys.left) then
		Pan(-Step, 0)
	elseif (Key == keys.right) then
		Pan(Step, 0)
	elseif (Key == keys.up) then
		Pan(0, -Step)
	elseif (Key == keys.down) then
		Pan(0, Step)
	else
		return false
	end
	return true
end

local function DrawCanvas(Self, T, Th)
	Gfx.Fill(T, Self.X, Self.Y, Self.W, Self.H, Th.Panel, Th.SubText, "\127")
	local OriginX, OriginY = Origin()
	local First = math.max(1, Self.X - OriginX + 1)
	local Last = math.min(Doc.W, Self.X + Self.W - OriginX)
	if (First > Last) then return end
	for Y = math.max(1, Self.Y - OriginY + 1), math.min(Doc.H, Self.Y + Self.H - OriginY) do
		T.setCursorPos(OriginX + First - 1, OriginY + Y - 1)
		T.blit(
			table.concat(Doc.Text[Y], "", First, Last),
			table.concat(Doc.Fg[Y], "", First, Last),
			table.concat(Doc.Bg[Y], "", First, Last)
		)
	end
	if (Stroke and Stroke.Shape) then
		for _, Point in ipairs(ShapePoints(Stroke)) do
			local X, Y = Point[1], Point[2]
			local ScreenX, ScreenY = OriginX + X - 1, OriginY + Y - 1
			if (InBounds(X, Y) and Ui.Inside(Self, ScreenX, ScreenY)) then
				T.setCursorPos(ScreenX, ScreenY)
				T.blit(Inked(X, Y, Stroke.Color))
			end
		end
	end
end

local function CaretPos(Self)
	if (not Caret) then return nil end
	local OriginX, OriginY = Origin()
	local X, Y = OriginX + Caret.X - 1, OriginY + Caret.Y - 1
	if (not Ui.Inside(Self, X, Y)) then return nil end
	local Under = InBounds(Caret.X, Caret.Y) and Doc.Bg[Caret.Y][Caret.X] or Doc.Base
	local Color = Caret.Color
	if (Color == Under) then Color = Light[Under] and "f" or "0" end
	return X, Y, 2 ^ tonumber(Color, 16)
end

--
-- Files
--

local function ParseSize(Answer)
	if (not Answer) then return nil end
	local W, H = Answer:match("^%s*(%d+)%s*[xX*, ]%s*(%d+)%s*$")
	W, H = tonumber(W), tonumber(H)
	if (not W or W < 1 or H < 1 or W > MaxSide or H > MaxSide) then
		Ui.Alert("Canvas Size", "Enter a size like 51x19, up to " .. MaxSide .. " on each side.")
		return nil
	end
	return W, H
end

local function DefaultSize()
	if (BlockOS.ScreenSize) then return BlockOS.ScreenSize() end
	return term.getSize()
end

local function BlankDoc(W, H, Base)
	return FromImage(Image.new(W, H, Base))
end

local function SaveTo(Path)
	if (Path:lower():match("%.nfp$") and HasCharacters()) then
		if (not Ui.Confirm("Save as .nfp", ".nfp pictures only keep colours, so characters will be lost.", "Save")) then return false end
	end
	if (not Image.Save(Path, ToImage(), DisplayName())) then
		Ui.Alert("Save Failed", "Could not write " .. Path)
		return false
	end
	Doc.Path = Path
	Doc.Dirty = false
	UpdateTitle()
	local Settings = Config.Settings()
	if (Settings.Wallpaper == "picture" and Settings.WallpaperImage == Path) then
		Wallpaper.Invalidate()
		os.queueEvent("blockos_settings")
	end
	return true
end

local function SaveAs()
	if (not fs.exists(Folder)) then fs.makeDir(Folder) end
	local Path = Ui.PickFile({
		Title = "Save Picture", Save = true,
		Dir = Doc.Path and fs.getDir(Doc.Path) or Folder,
		Name = Doc.Path and fs.getName(Doc.Path) or "Untitled.bimg"
	})
	if (not Path) then return false end
	if (not Image.IsImage(Path)) then Path = Path .. ".bimg" end
	if (fs.isDir(Path) or fs.isReadOnly(Path)) then
		Ui.Alert("Save Picture", "Can't save to " .. Path)
		return false
	end
	if (fs.exists(Path) and Path ~= Doc.Path) then
		if (not Ui.Confirm("Replace", "\"" .. fs.getName(Path) .. "\" already exists. Replace it?", "Replace")) then return false end
	end
	return SaveTo(Path)
end

local function Save()
	if (Doc.Path) then return SaveTo(Doc.Path) end
	return SaveAs()
end

-- Returns true when it is fine to throw the current picture away.
local function ConfirmDiscard()
	if (not Doc.Dirty) then return true end
	local Choice = Ui.Alert("Unsaved Changes", "Save changes to \"" .. DisplayName() .. "\"?", { "Cancel", "Don't Save", "Save" })
	if (Choice == 3) then return Save() end
	return Choice == 2
end

local function OpenPath(Path)
	local Img, Err = Image.Load(Path)
	if (not Img) then
		Ui.Alert("Open Picture", fs.getName(Path) .. ": " .. tostring(Err))
		return false
	end
	SetDoc(FromImage(Img), Path)
	return true
end

local function OpenPicture()
	if (not ConfirmDiscard()) then return end
	local Path = Ui.PickFile({ Title = "Open Picture", Dir = fs.exists(Folder) and Folder or "home" })
	if (Path) then OpenPath(Path) end
end

local function NewPicture()
	if (not ConfirmDiscard()) then return end
	local ScreenW, ScreenH = DefaultSize()
	local W, H = ParseSize(Ui.Prompt("New Picture", "Width x height. The background uses your right-click colour.", ScreenW .. "x" .. ScreenH))
	if (not W) then return end
	local NewDoc = BlankDoc(W, H, State.Secondary)
	SetDoc(NewDoc, nil)
end

local function ResizeCanvas()
	local W, H = ParseSize(Ui.Prompt("Canvas Size", "Width x height. New space uses the background colour.", Doc.W .. "x" .. Doc.H))
	if (not W) then return end
	PushUndo()
	local Resized = BlankDoc(W, H, Doc.Base)
	for Y = 1, math.min(H, Doc.H) do
		for X = 1, math.min(W, Doc.W) do
			Resized.Text[Y][X], Resized.Fg[Y][X], Resized.Bg[Y][X] = Doc.Text[Y][X], Doc.Fg[Y][X], Doc.Bg[Y][X]
		end
	end
	Resized.Path, Resized.Base = Doc.Path, Doc.Base
	Doc = Resized
	Caret = nil
	ClampScroll()
	MarkDirty()
end

local function ClearCanvas()
	PushUndo()
	local Path, Base = Doc.Path, Doc.Base
	Doc = BlankDoc(Doc.W, Doc.H, Base)
	Doc.Path = Path
	Caret = nil
	MarkDirty()
end

local function SetAsWallpaper()
	if ((Doc.Dirty or not Doc.Path) and not Save()) then return end
	local Settings = Config.Settings()
	Settings.Wallpaper = "picture"
	Settings.WallpaperImage = Doc.Path
	Wallpaper.Invalidate()
	Config.Save("settings")
	BlockOS.Notify("Brocreate", "Wallpaper set to " .. DisplayName())
end

local function ChooseChar()
	local Code = Ui.PickChar("Character", State.Char:byte())
	if (Code) then
		State.Char = string.char(Code)
		State.Ink = "char"
	end
end

--
-- Layout
--

local function FileMenu(Self)
	local Options = { "New...", "Open...", "Save", "Save As...", "-", "Set as Wallpaper", "-", "Canvas Size..." }
	local Choice = Options[Ui.ContextMenu(Self.X, Self.Y + 1, Options) or 0]
	if (Choice == "New...") then
		NewPicture()
	elseif (Choice == "Open...") then
		OpenPicture()
	elseif (Choice == "Save") then
		Save()
	elseif (Choice == "Save As...") then
		SaveAs()
	elseif (Choice == "Set as Wallpaper") then
		SetAsWallpaper()
	elseif (Choice == "Canvas Size...") then
		ResizeCanvas()
	end
	Page:Invalidate()
end

local function EditMenu(Self)
	local Options = {
		{ Text = "Undo", Disabled = #Undo == 0 },
		{ Text = "Redo", Disabled = #Redo == 0 },
		"-",
		{ Text = State.Filled and "Shapes: Filled" or "Shapes: Outline" },
		{ Text = "Choose Character..." },
		"-",
		{ Text = "Clear Canvas" }
	}
	local Index = Ui.ContextMenu(Self.X, Self.Y + 1, Options)
	local Choice = Index and Options[Index].Text
	if (Choice == "Undo") then
		DoUndo()
	elseif (Choice == "Redo") then
		DoRedo()
	elseif (Choice == "Shapes: Filled" or Choice == "Shapes: Outline") then
		State.Filled = not State.Filled
	elseif (Choice == "Choose Character...") then
		ChooseChar()
	elseif (Choice == "Clear Canvas") then
		ClearCanvas()
	end
	Page:Invalidate()
end

local function ToolColors(Self, Th)
	if (State.Tool == Self.Tool) then return Th.Accent, Th.AccentFg end
	return Th.Panel, Th.Text
end

local function InkColors(Self, Th)
	if (State.Ink == Self.Ink) then return Th.Accent, Th.AccentFg end
	return Th.ButtonBg, Th.ButtonFg
end

local function StatusText()
	local Size = Doc.W .. "x" .. Doc.H
	if (Caret) then return "Typing \7 " .. Size end
	if (Hover and InBounds(Hover[1], Hover[2])) then
		return Hover[1] .. "," .. Hover[2] .. " \7 " .. Size
	end
	return Size
end

local function DrawPalette(Self, T, Th)
	Gfx.Fill(T, Self.X, Self.Y, Self.W, 1, Th.Panel)
	local Swatch = Layout.Swatch
	for Index = 0, 15 do
		local Hex = string.format("%x", Index)
		local Marks = (Hex == State.Primary and "L" or " ") .. (Hex == State.Secondary and "R" or " ")
		if (Swatch == 1) then
			Marks = (Hex == State.Primary and "L") or (Hex == State.Secondary and "R") or " "
		end
		T.setCursorPos(Self.X + Index * Swatch, Self.Y)
		T.blit(Marks, string.rep(Light[Hex] and "f" or "0", Swatch), string.rep(Hex, Swatch))
	end
end

local function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Layout.CX, Layout.CY = 1, 2
	Layout.CW, Layout.CH = W, math.max(1, H - 3)
	Layout.Swatch = (W >= 34) and 2 or 1
	ClampScroll()

	Page:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1 }))
	Page:Add(Ui.Button.new({ X = 1, Y = 1, Text = " File ", Style = "plain", Bg = "Panel", Fg = "Text", KeepFocus = true, OnClick = FileMenu }))
	Page:Add(Ui.Button.new({ X = 7, Y = 1, Text = " Edit ", Style = "plain", Bg = "Panel", Fg = "Text", KeepFocus = true, OnClick = EditMenu }))
	local ToolsW = 0
	for _, Tool in ipairs(Tools) do
		ToolsW = ToolsW + #Tool.Label + 1
	end
	local Wide = 13 + ToolsW <= W
	local X = 14
	for _, Tool in ipairs(Tools) do
		local Label = " " .. (Wide and Tool.Label or Tool.Short)
		local Button = Page:Add(Ui.Button.new({
			X = X, Y = 1, W = #Label, Text = Label, Tool = Tool.ID, KeepFocus = true,
			OnClick = function(Self)
				State.Tool = Self.Tool
				Caret, Stroke = nil, nil
			end
		}))
		Button.Colors = ToolColors
		X = X + #Label
	end

	CanvasWidget = Page:Add(Ui.Canvas.new({
		X = Layout.CX, Y = Layout.CY, W = Layout.CW, H = Layout.CH, Focusable = true, KeepFocus = true,
		OnDraw = DrawCanvas,
		OnCursor = CaretPos,
		OnEvent = function(Self, Name, A, B, C)
			if (Name == "mouse_click") then
				return BeginStroke(A, B, C)
			elseif (Name == "mouse_drag") then
				return ContinueStroke(B, C)
			elseif (Name == "mouse_up") then
				return EndStroke()
			elseif (Name == "mouse_scroll") then
				if (Ui.Modifiers.Shift) then
					Pan(A * 2, 0)
				else
					Pan(0, A)
				end
				return true
			elseif (Name == "char") then
				if (Caret) then return TypeText(A) end
				if (State.Ink == "char" and State.Tool ~= "text") then
					State.Char = A
					return true
				end
				return false
			elseif (Name == "paste") then
				return TypeText((A:gsub("[\r\n]", " ")))
			elseif (Name == "key") then
				return CanvasKey(A)
			end
			return false
		end
	}))

	Page:Add(Ui.Canvas.new({
		X = 1, Y = H - 1, W = W, H = 1, KeepFocus = true,
		OnDraw = DrawPalette,
		OnEvent = function(Self, Name, A, B)
			if (Name ~= "mouse_click") then return false end
			local Index = math.floor((B - Self.X) / Layout.Swatch)
			if (Index < 0 or Index > 15) then return true end
			if (A == 2) then
				State.Secondary = string.format("%x", Index)
			else
				State.Primary = string.format("%x", Index)
			end
			return true
		end
	}))

	Page:Add(Ui.Panel.new({ X = 1, Y = H, W = W, H = 1 }))
	local SolidButton = Page:Add(Ui.Button.new({
		X = 1, Y = H, Text = " Solid ", Ink = "solid", KeepFocus = true,
		OnClick = function()
			State.Ink = "solid"
		end
	}))
	SolidButton.Colors = InkColors
	local CharButton = Page:Add(Ui.Button.new({
		X = 9, Y = H, W = 8, Ink = "char", KeepFocus = true,
		Text = function()
			return " Char " .. State.Char .. " "
		end,
		OnClick = function(_, Button)
			if (State.Ink == "char" or Button == 2) then
				ChooseChar()
			end
			State.Ink = "char"
		end
	}))
	CharButton.Colors = InkColors
	if (W >= 20) then
		Page:Add(Ui.Label.new({ X = 18, Y = H, W = W - 18, Align = "right", Fg = "SubText", Bg = "Panel", Text = StatusText }))
	end

	Page:SetFocus(CanvasWidget)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_close") then
		if (ConfirmDiscard()) then self:Stop() end
		return true
	elseif (Name == "key" and Ui.Modifiers.Ctrl) then
		if (A == keys.s) then
			Save()
		elseif (A == keys.o) then
			OpenPicture()
		elseif (A == keys.n) then
			NewPicture()
		elseif (A == keys.z) then
			DoUndo()
		elseif (A == keys.y) then
			DoRedo()
		else
			return false
		end
		return true
	end
	return false
end

function Page:OnTerminate()
	if (ConfirmDiscard()) then self:Stop() end
end

BlockOS.SetCloseHandler(true)
local Target = Args[1] and (shell and shell.resolve(Args[1]) or Args[1])
if (Target and not Target:find("^/")) then Target = "/" .. Target end
local ScreenW, ScreenH = DefaultSize()
SetDoc(BlankDoc(ScreenW, ScreenH, State.Secondary), nil)
if (Target and fs.exists(Target) and not fs.isDir(Target)) then
	OpenPath(Target)
end
Page:Run()
