-- Snake: eat apples, grow, don't bite yourself. Arrow keys or WASD, P pauses, Q quits.

local W, H = term.getSize()
local Top = 2
local Board = { W = W, H = H - Top }
local Snake, Direction, Queued, Apple, Score, Alive, Paused
local Best = 0
local Speed = .15
local BestPath = "/blockos/data/snake.dat"

local Directions = {
	up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 }
}

local KeyMap = {
	[keys.up] = "up", [keys.w] = "up",
	[keys.down] = "down", [keys.s] = "down",
	[keys.left] = "left", [keys.a] = "left",
	[keys.right] = "right", [keys.d] = "right"
}

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

local function Occupied(X, Y)
	for _, Part in ipairs(Snake) do
		if (Part[1] == X and Part[2] == Y) then return true end
	end
	return false
end

local function PlaceApple()
	repeat
		Apple = { math.random(1, Board.W), math.random(1, Board.H) }
	until not Occupied(Apple[1], Apple[2])
end

local function Cell(X, Y, Color)
	term.setCursorPos(X, Y + Top)
	term.setBackgroundColor(Color)
	term.write(" ")
end

local function DrawStatus(Message)
	term.setCursorPos(1, 1)
	term.setBackgroundColor(colors.gray)
	term.setTextColor(colors.white)
	term.clearLine()
	term.write(" Score " .. Score .. "   Best " .. Best)
	if (Message) then
		term.setCursorPos(W - #Message, 1)
		term.write(Message)
	end
	term.setCursorPos(1, 2)
	term.setBackgroundColor(colors.green)
	term.clearLine()
end

local function DrawAll()
	term.setBackgroundColor(colors.lime)
	term.clear()
	DrawStatus()
	for Index, Part in ipairs(Snake) do
		Cell(Part[1], Part[2], Index == 1 and colors.brown or colors.green)
	end
	Cell(Apple[1], Apple[2], colors.red)
end

local function Reset()
	local X, Y = math.floor(Board.W / 2), math.floor(Board.H / 2)
	Snake = { { X, Y }, { X - 1, Y }, { X - 2, Y } }
	Direction = "right"
	Queued = nil
	Score = 0
	Alive = true
	Paused = false
	PlaceApple()
	DrawAll()
end

local function Opposite(A, B)
	return Directions[A][1] == -Directions[B][1] and Directions[A][2] == -Directions[B][2]
end

local function Step()
	if (Queued and not Opposite(Queued, Direction)) then Direction = Queued end
	Queued = nil
	local Head = Snake[1]
	local Delta = Directions[Direction]
	local X, Y = Head[1] + Delta[1], Head[2] + Delta[2]
	if (X < 1 or Y < 1 or X > Board.W or Y > Board.H or Occupied(X, Y)) then
		Alive = false
		if (Score > Best) then
			Best = Score
			SaveBest()
		end
		DrawStatus("Game over - R retry ")
		return
	end
	table.insert(Snake, 1, { X, Y })
	Cell(Head[1], Head[2], colors.green)
	Cell(X, Y, colors.brown)
	if (X == Apple[1] and Y == Apple[2]) then
		Score = Score + 1
		PlaceApple()
		Cell(Apple[1], Apple[2], colors.red)
		DrawStatus()
	else
		local Tail = table.remove(Snake)
		Cell(Tail[1], Tail[2], colors.lime)
	end
end

math.randomseed(os.epoch("utc"))
LoadBest()
Reset()

local Timer = os.startTimer(Speed)
while (true) do
	local Event, A = os.pullEvent()
	if (Event == "timer" and A == Timer) then
		if (Alive and not Paused) then Step() end
		Timer = os.startTimer(math.max(.05, Speed - Score * .003))
	elseif (Event == "key") then
		if (KeyMap[A]) then
			Queued = KeyMap[A]
		elseif (A == keys.p and Alive) then
			Paused = not Paused
			DrawStatus(Paused and "Paused " or nil)
		elseif (A == keys.r and not Alive) then
			Reset()
		elseif (A == keys.q) then
			break
		end
	elseif (Event == "term_resize") then
		W, H = term.getSize()
		Board.W, Board.H = W, H - Top
		Reset()
	end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
