-- Breakout: bounce the ball off your paddle and clear every brick.
-- Arrow keys, A/D or the mouse move the paddle, Space launches, P pauses, Q quits.

local W, H = term.getSize()
local Top = 2
local Speed = .05
local BrickW = 4
local BestPath = "/blockos/data/breakout.dat"
local RowColors = { colors.red, colors.orange, colors.yellow, colors.lime, colors.cyan, colors.lightBlue, colors.purple, colors.magenta }

local Bricks, BrickTop, BrickCols, BrickX, Left
local Paddle, Ball, Score, Lives, Level, State
local Best = 0
local Held = {}

local KeyMap = {
	[keys.left] = "left", [keys.a] = "left",
	[keys.right] = "right", [keys.d] = "right"
}

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

-- Bricks are BrickW cells wide, the last one a gap; Bricks[Row][Column] holds { Color, Hits, Points }.
local function BuildLevel()
	BrickCols = math.max(1, math.floor((W - 1) / BrickW))
	BrickX = math.floor((W - BrickCols * BrickW + 1) / 2) + 1
	BrickTop = Top + 2
	local Rows = math.max(2, math.min(3 + Level, #RowColors, math.floor((H - Top) / 2) - 1))
	Bricks = {}
	Left = 0
	for Row = 1, Rows do
		Bricks[Row] = {}
		for Column = 1, BrickCols do
			-- From level 3 the top row needs two hits.
			local Hits = (Level >= 3 and Row == 1) and 2 or 1
			Bricks[Row][Column] = { Color = RowColors[Row], Hits = Hits, Points = (Rows - Row + 1) * 10 }
			Left = Left + 1
		end
	end
end

local function Serve()
	State = "serve"
	Ball = { X = Paddle.X + Paddle.W / 2, Y = H - .5, DX = 0, DY = 0 }
end

local function NewPaddle()
	local PaddleW = math.max(5, 11 - Level)
	Paddle = { X = math.floor((W - PaddleW) / 2) + 1, W = PaddleW }
end

local function Reset()
	Score = 0
	Lives = 3
	Level = 1
	NewPaddle()
	BuildLevel()
	Serve()
end

local function BallSpeed()
	return math.min(.9, .45 + Level * .05)
end

-- Sends the ball off at an angle; -1 is far left, 1 is far right.
local function Launch(Angle)
	local Radians = Angle * math.rad(60)
	local Pace = BallSpeed()
	-- Cells are taller than they are wide, so sideways speed is stretched to look even.
	Ball.DX = math.sin(Radians) * Pace * 1.5
	Ball.DY = -math.cos(Radians) * Pace
	State = "play"
end

local function BrickAt(X, Y)
	local Row = Y - BrickTop + 1
	if (Row < 1 or Row > #Bricks) then return nil end
	local Offset = X - BrickX
	if (Offset < 0) then return nil end
	local Column = math.floor(Offset / BrickW) + 1
	if (Column > BrickCols) then return nil end
	return Bricks[Row][Column] and Row, Column
end

local function HitBrick(Row, Column)
	local Brick = Bricks[Row][Column]
	Brick.Hits = Brick.Hits - 1
	if (Brick.Hits > 0) then return end
	Bricks[Row][Column] = nil
	Score = Score + Brick.Points * Level
	Left = Left - 1
end

local function LoseBall()
	Lives = Lives - 1
	if (Lives > 0) then
		Serve()
		return
	end
	State = "over"
	if (Score > Best) then
		Best = Score
		SaveBest()
	end
end

local function MoveBall()
	local Steps = math.max(1, math.ceil(math.max(math.abs(Ball.DX), math.abs(Ball.DY)) / .5))
	for _ = 1, Steps do
		local NX = Ball.X + Ball.DX / Steps
		if (NX < 1) then
			NX, Ball.DX = 2 - NX, math.abs(Ball.DX)
		elseif (NX >= W + 1) then
			NX, Ball.DX = 2 * (W + 1) - NX - .01, -math.abs(Ball.DX)
		end
		local Row, Column = BrickAt(math.floor(NX), math.floor(Ball.Y))
		if (Row) then
			HitBrick(Row, Column)
			Ball.DX = -Ball.DX
		else
			Ball.X = NX
		end
		local NY = Ball.Y + Ball.DY / Steps
		if (NY < Top) then
			NY, Ball.DY = 2 * Top - NY, math.abs(Ball.DY)
		end
		Row, Column = BrickAt(math.floor(Ball.X), math.floor(NY))
		if (Row) then
			HitBrick(Row, Column)
			Ball.DY = -Ball.DY
		elseif (Ball.DY > 0 and math.floor(NY) >= H and math.floor(Ball.Y) < H) then
			local Cell = math.floor(Ball.X)
			if (Cell >= Paddle.X - 1 and Cell <= Paddle.X + Paddle.W) then
				local Offset = (Ball.X - (Paddle.X + Paddle.W / 2)) / (Paddle.W / 2 + 1)
				Ball.Y = H - .01
				Launch(math.max(-1, math.min(1, Offset)))
			else
				Ball.Y = NY
			end
		else
			Ball.Y = NY
		end
		if (Ball.Y >= H + 1) then
			LoseBall()
			return
		end
		if (Left == 0) then
			Level = Level + 1
			NewPaddle()
			BuildLevel()
			Serve()
			return
		end
	end
end

local function MovePaddle(Delta)
	Paddle.X = math.max(1, math.min(W - Paddle.W + 1, Paddle.X + Delta))
	if (State == "serve") then Ball.X = Paddle.X + Paddle.W / 2 end
end

local function CenterPaddle(X)
	MovePaddle(X - math.floor(Paddle.W / 2) - Paddle.X)
end

local function Tick()
	if (State == "paused" or State == "over") then return end
	if (Held.left) then MovePaddle(-1) end
	if (Held.right) then MovePaddle(1) end
	if (State == "play") then MoveBall() end
end

local function Draw()
	local Chars, Fgs, Bgs = {}, {}, {}
	for Y = 1, H do
		Chars[Y], Fgs[Y], Bgs[Y] = {}, {}, {}
		for X = 1, W do
			Chars[Y][X], Fgs[Y][X], Bgs[Y][X] = " ", "0", "f"
		end
	end
	local function Set(X, Y, Char, Fg, Bg)
		if (X < 1 or Y < 1 or X > W or Y > H) then return end
		Chars[Y][X] = Char
		if (Fg) then Fgs[Y][X] = Hex[Fg] end
		if (Bg) then Bgs[Y][X] = Hex[Bg] end
	end
	local function Text(X, Y, Value, Fg, Bg)
		for Index = 1, #Value do
			Set(X + Index - 1, Y, Value:sub(Index, Index), Fg, Bg)
		end
	end
	for X = 1, W do
		Set(X, 1, " ", colors.white, colors.gray)
	end
	Text(2, 1, "Score " .. Score .. "  Level " .. Level .. "  " .. string.rep("\3", Lives), colors.white, colors.gray)
	local BestText = "Best " .. Best
	Text(W - #BestText, 1, BestText, colors.lightGray, colors.gray)
	for Row, Columns in ipairs(Bricks) do
		for Column = 1, BrickCols do
			local Brick = Columns[Column]
			if (Brick) then
				local X = BrickX + (Column - 1) * BrickW
				local Color = (Brick.Hits > 1) and colors.lightGray or Brick.Color
				for Offset = 0, BrickW - 2 do
					Set(X + Offset, BrickTop + Row - 1, " ", nil, Color)
				end
			end
		end
	end
	for X = Paddle.X, Paddle.X + Paddle.W - 1 do
		Set(X, H, "\140", colors.lightGray, colors.white)
	end
	Set(math.floor(Ball.X), math.floor(Ball.Y), "\7", colors.white)
	local Message
	if (State == "serve") then
		Message = "Space to launch"
	elseif (State == "paused") then
		Message = "Paused - P to resume"
	elseif (State == "over") then
		Message = "Game over - R to retry, Q to quit"
	end
	if (Message) then
		Text(math.floor((W - #Message) / 2) + 1, math.floor((H + BrickTop + #Bricks) / 2), Message, colors.white, colors.black)
	end
	for Y = 1, H do
		term.setCursorPos(1, Y)
		term.blit(table.concat(Chars[Y]), table.concat(Fgs[Y]), table.concat(Bgs[Y]))
	end
end

math.randomseed(os.epoch("utc"))
LoadBest()
Reset()
Draw()

local Timer = os.startTimer(Speed)
while (true) do
	local Event, A, B = os.pullEvent()
	if (Event == "timer" and A == Timer) then
		Tick()
		Draw()
		Timer = os.startTimer(Speed)
	elseif (Event == "key") then
		if (KeyMap[A]) then
			Held[KeyMap[A]] = true
		elseif (A == keys.space or A == keys.up or A == keys.w) then
			if (State == "serve") then Launch((math.random() - .5) * .6) end
		elseif (A == keys.p and (State == "play" or State == "paused")) then
			State = (State == "paused") and "play" or "paused"
		elseif (A == keys.r and State == "over") then
			Reset()
		elseif (A == keys.q) then
			break
		end
	elseif (Event == "key_up" and KeyMap[A]) then
		Held[KeyMap[A]] = nil
	elseif (Event == "mouse_click" or Event == "mouse_drag") then
		if (State ~= "paused" and State ~= "over") then CenterPaddle(B) end
		if (Event == "mouse_click" and State == "serve") then Launch((math.random() - .5) * .6) end
	elseif (Event == "term_resize") then
		W, H = term.getSize()
		NewPaddle()
		BuildLevel()
		Serve()
	end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
