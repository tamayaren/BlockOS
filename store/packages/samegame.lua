-- SameGame: clear groups of two or more touching blocks of the same colour.
-- A group of n blocks scores (n - 2)^2, and an empty board earns 1000 more.
-- Click a group, or use the arrow keys and Enter. U undoes, N starts over, Q quits.

local W, H = term.getSize()
local Top = 2
local BestPath = "/blockos/data/samegame.dat"
local Palette = { colors.red, colors.lime, colors.lightBlue, colors.yellow, colors.purple }

local Grid, Cols, Rows, CellW, CellH, OffsetX
local Score, Over, Undo
local Best = 0
local Cursor = { 1, 1 }

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

local function LoadBest()
	if (not fs.exists(BestPath)) then return end
	local Handle = fs.open(BestPath, "r")
	Best = tonumber(Handle.readAll()) or 0
	Handle.close()
end

local function SaveBest()
	local Handle = fs.open(BestPath, "w")
	if (not Handle) then return end
	Handle.write(tostring(Best))
	Handle.close()
end

-- Grid[Column][Row] holds a palette index; row 1 is the bottom so blocks fall towards it.
local function Layout()
	CellW = 3
	CellH = (H - Top + 1 >= 16) and 2 or 1
	Cols = math.max(2, math.floor(W / CellW))
	Rows = math.max(2, math.floor((H - Top + 1) / CellH))
	OffsetX = math.floor((W - Cols * CellW) / 2) + 1
end

local function NewGame()
	Layout()
	Grid = {}
	for Column = 1, Cols do
		Grid[Column] = {}
		for Row = 1, Rows do
			Grid[Column][Row] = math.random(1, #Palette)
		end
	end
	Score = 0
	Over = false
	Undo = nil
	Cursor = { math.ceil(Cols / 2), math.ceil(Rows / 2) }
end

local function Copy(Source)
	local Result = {}
	for Column, Cells in pairs(Source) do
		Result[Column] = {}
		for Row, Value in pairs(Cells) do
			Result[Column][Row] = Value
		end
	end
	return Result
end

local function Get(Column, Row)
	return Grid[Column] and Grid[Column][Row]
end

-- Every cell connected to Column, Row through the same colour.
local function GroupAt(Column, Row)
	local Color = Get(Column, Row)
	if (not Color) then return {}, {} end
	local Group, Seen = {}, {}
	local Stack = { { Column, Row } }
	while (#Stack > 0) do
		local Cell = table.remove(Stack)
		local Key = Cell[1] * 1000 + Cell[2]
		if (not Seen[Key] and Get(Cell[1], Cell[2]) == Color) then
			Seen[Key] = true
			table.insert(Group, Cell)
			table.insert(Stack, { Cell[1] + 1, Cell[2] })
			table.insert(Stack, { Cell[1] - 1, Cell[2] })
			table.insert(Stack, { Cell[1], Cell[2] + 1 })
			table.insert(Stack, { Cell[1], Cell[2] - 1 })
		end
	end
	return Group, Seen
end

local function HasMoves()
	for Column = 1, Cols do
		for Row = 1, Rows do
			local Color = Get(Column, Row)
			if (Color and (Get(Column + 1, Row) == Color or Get(Column, Row + 1) == Color)) then
				return true
			end
		end
	end
	return false
end

local function Empty()
	return Get(1, 1) == nil
end

local function Points(Count)
	return (Count - 2) ^ 2
end

-- Drops blocks into the gaps below them, then closes empty columns from the right.
local function Collapse()
	local Packed = {}
	for Column = 1, Cols do
		local Cells = {}
		for Row = 1, Rows do
			if (Grid[Column][Row]) then table.insert(Cells, Grid[Column][Row]) end
		end
		if (#Cells > 0) then table.insert(Packed, Cells) end
	end
	for Column = #Packed + 1, Cols do
		Packed[Column] = {}
	end
	Grid = Packed
end

local function Finish()
	Over = true
	if (Empty()) then Score = Score + 1000 end
	if (Score > Best) then
		Best = Score
		SaveBest()
	end
end

local function Remove(Column, Row)
	if (Over) then return end
	local Group = GroupAt(Column, Row)
	if (#Group < 2) then return end
	Undo = { Grid = Copy(Grid), Score = Score }
	for _, Cell in ipairs(Group) do
		Grid[Cell[1]][Cell[2]] = nil
	end
	Score = Score + Points(#Group)
	Collapse()
	if (not HasMoves()) then Finish() end
end

local function CellAt(X, Y)
	local Column = math.floor((X - OffsetX) / CellW) + 1
	local Row = Rows - math.floor((Y - Top) / CellH)
	if (X < OffsetX or Y < Top or Column < 1 or Column > Cols or Row < 1 or Row > Rows) then return nil end
	return Column, Row
end

local function Draw()
	local _, Highlight = GroupAt(Cursor[1], Cursor[2])
	local Group = 0
	for _ in pairs(Highlight) do Group = Group + 1 end
	if (Group < 2) then Highlight = {} end
	term.setCursorPos(1, 1)
	term.setBackgroundColor(colors.gray)
	term.setTextColor(colors.white)
	term.clearLine()
	term.write(" Score " .. Score .. "   Best " .. Best)
	local Info
	if (Over) then
		Info = Empty() and "Cleared! +1000  N new game " or "No more moves  N new game "
	elseif (Group >= 2) then
		Info = Group .. " blocks +" .. Points(Group) .. " "
	else
		Info = "U undo  N new  Q quit "
	end
	term.setCursorPos(math.max(1, W - #Info + 1), 1)
	term.setTextColor(Over and colors.yellow or colors.lightGray)
	term.write(Info)
	for Y = Top, H do
		local Chars, Fgs, Bgs = {}, {}, {}
		for X = 1, W do
			local Column, Row = CellAt(X, Y)
			local Color = Column and Get(Column, Row)
			local Char, Fg = " ", "0"
			if (Color and Highlight[Column * 1000 + Row]) then
				Char, Fg = "\127", Hex[colors.white]
			end
			if (Column and Column == Cursor[1] and Row == Cursor[2] and not Over) then
				local Middle = OffsetX + (Column - 1) * CellW + 1
				local Lower = Top + (Rows - Row) * CellH + CellH - 1
				if (X == Middle and Y == Lower) then
					Char, Fg = "\4", Color and Hex[colors.black] or Hex[colors.gray]
				end
			end
			Chars[X], Fgs[X], Bgs[X] = Char, Fg, Color and Hex[Palette[Color]] or "f"
		end
		term.setCursorPos(1, Y)
		term.blit(table.concat(Chars), table.concat(Fgs), table.concat(Bgs))
	end
end

local Moves = {
	[keys.left] = { -1, 0 }, [keys.a] = { -1, 0 },
	[keys.right] = { 1, 0 }, [keys.d] = { 1, 0 },
	[keys.up] = { 0, 1 }, [keys.w] = { 0, 1 },
	[keys.down] = { 0, -1 }, [keys.s] = { 0, -1 }
}

math.randomseed(os.epoch("utc"))
LoadBest()
NewGame()
Draw()

while (true) do
	local Event, A, B, C = os.pullEvent()
	if (Event == "mouse_click") then
		local Column, Row = CellAt(B, C)
		if (Column) then
			Cursor = { Column, Row }
			if (A == 1) then Remove(Column, Row) end
		end
	elseif (Event == "key") then
		if (Moves[A]) then
			Cursor[1] = math.max(1, math.min(Cols, Cursor[1] + Moves[A][1]))
			Cursor[2] = math.max(1, math.min(Rows, Cursor[2] + Moves[A][2]))
		elseif (A == keys.enter or A == keys.space) then
			Remove(Cursor[1], Cursor[2])
		elseif (A == keys.u and Undo) then
			Grid, Score, Over, Undo = Undo.Grid, Undo.Score, false, nil
		elseif (A == keys.n) then
			NewGame()
		elseif (A == keys.q) then
			break
		end
	elseif (Event == "term_resize") then
		W, H = term.getSize()
		NewGame()
	end
	Draw()
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
