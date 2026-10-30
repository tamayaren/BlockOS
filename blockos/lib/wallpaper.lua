-- Procedural ASCII wallpapers rendered to blit rows.

local Wallpaper = {}

Wallpaper.List = {
	{ ID = "overworld", Name = "Overworld" },
	{ ID = "night", Name = "Starry Night" },
	{ ID = "nether", Name = "Nether" },
	{ ID = "ocean", Name = "Ocean" },
	{ ID = "grid", Name = "Grid" },
	{ ID = "solid", Name = "Solid Colour" }
}

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

local function Random(Seed)
	local State = Seed
	return function(Max)
		State = (State * 1103515245 + 12345) % 2147483648
		return State % Max
	end
end

local function NewCanvas(W, H, Bg)
	local Canvas = { W = W, H = H, Chars = {}, Fg = {}, Bg = {} }
	for Y = 1, H do
		Canvas.Chars[Y] = {}
		Canvas.Fg[Y] = {}
		Canvas.Bg[Y] = {}
		for X = 1, W do
			Canvas.Chars[Y][X] = " "
			Canvas.Fg[Y][X] = Hex[colors.white]
			Canvas.Bg[Y][X] = Hex[Bg]
		end
	end
	return Canvas
end

local function Set(Canvas, X, Y, Char, Fg, Bg)
	if (X < 1 or Y < 1 or X > Canvas.W or Y > Canvas.H) then return end
	if (Char) then Canvas.Chars[Y][X] = Char end
	if (Fg) then Canvas.Fg[Y][X] = Hex[Fg] end
	if (Bg) then Canvas.Bg[Y][X] = Hex[Bg] end
end

local function Finish(Canvas)
	local Rows = {}
	for Y = 1, Canvas.H do
		Rows[Y] = {
			table.concat(Canvas.Chars[Y]),
			table.concat(Canvas.Fg[Y]),
			table.concat(Canvas.Bg[Y])
		}
	end
	return Rows
end

local function Terrain(Canvas, Rand, Base, Amplitude, Grass, Dirt, Stone, Speck)
	local W, H = Canvas.W, Canvas.H
	local Phase = Rand(100) / 10
	for X = 1, W do
		local Height = math.floor(Base + math.sin(X / 7 + Phase) * Amplitude + math.sin(X / 3.1 + Phase * 2) * Amplitude * .4 + .5)
		for Y = Height, H do
			if (Y == Height) then
				Set(Canvas, X, Y, (Rand(4) == 0) and "\"" or " ", Speck, Grass)
			elseif (Y < Height + 3) then
				Set(Canvas, X, Y, (Rand(5) == 0) and "." or " ", colors.orange, Dirt)
			else
				Set(Canvas, X, Y, (Rand(6) == 0) and ":" or " ", colors.lightGray, Stone)
			end
		end
	end
end

local Renderers = {}

function Renderers.overworld(W, H)
	local Canvas = NewCanvas(W, H, colors.lightBlue)
	local Rand = Random(42)
	for _ = 1, math.max(2, math.floor(W / 14)) do
		local CloudX, CloudY = Rand(W) + 1, Rand(math.max(1, math.floor(H / 3))) + 2
		local Length = Rand(6) + 5
		for X = CloudX, CloudX + Length do
			Set(Canvas, X, CloudY, " ", nil, colors.white)
		end
		for X = CloudX + 2, CloudX + Length - 2 do
			Set(Canvas, X, CloudY - 1, " ", nil, colors.white)
		end
	end
	for Y = 3, 4 do
		for X = W - 8, W - 5 do
			Set(Canvas, X, Y, " ", nil, colors.yellow)
		end
	end
	Terrain(Canvas, Rand, H * .62, 2.2, colors.lime, colors.brown, colors.gray, colors.green)
	return Finish(Canvas)
end

function Renderers.night(W, H)
	local Canvas = NewCanvas(W, H, colors.black)
	local Rand = Random(7)
	for _ = 1, math.floor(W * H / 18) do
		local Star = ({ ".", ".", "+", "*", "\7" })[Rand(5) + 1]
		Set(Canvas, Rand(W) + 1, Rand(math.floor(H * .7)) + 1, Star, (Rand(3) == 0) and colors.yellow or colors.white)
	end
	for Y = 3, 4 do
		for X = 6, 9 do
			Set(Canvas, X, Y, " ", nil, colors.lightGray)
		end
	end
	Set(Canvas, 7, 3, " ", nil, colors.white)
	Terrain(Canvas, Rand, H * .7, 1.8, colors.green, colors.gray, colors.black, colors.lime)
	return Finish(Canvas)
end

function Renderers.nether(W, H)
	local Canvas = NewCanvas(W, H, colors.red)
	local Rand = Random(13)
	for Y = 1, H do
		for X = 1, W do
			local Wave = math.sin(X / 4 + Y / 3) + math.sin(X / 9 - Y / 2)
			if (Wave > 1.1) then
				Set(Canvas, X, Y, (Rand(3) == 0) and "~" or " ", colors.yellow, colors.orange)
			elseif (Wave < -1.2) then
				Set(Canvas, X, Y, (Rand(4) == 0) and "#" or " ", colors.red, colors.brown)
			elseif (Rand(14) == 0) then
				Set(Canvas, X, Y, "'", colors.orange)
			end
		end
	end
	return Finish(Canvas)
end

function Renderers.ocean(W, H)
	local Canvas = NewCanvas(W, H, colors.blue)
	local Rand = Random(99)
	for Y = 1, H do
		local Band = (Y < H * .35) and colors.lightBlue or ((Y < H * .7) and colors.cyan or colors.blue)
		for X = 1, W do
			local Char = (math.sin(X / 3 + Y * 1.7) > .6) and "~" or " "
			Set(Canvas, X, Y, Char, (Band == colors.blue) and colors.cyan or colors.white, Band)
		end
	end
	for _ = 1, math.floor(W / 8) do
		Set(Canvas, Rand(W) + 1, H - Rand(3), "\"", colors.lime)
	end
	return Finish(Canvas)
end

function Renderers.grid(W, H, Color)
	local Canvas = NewCanvas(W, H, Color)
	local Dot = (Color == colors.white or Color == colors.lightGray) and colors.gray or colors.lightGray
	for Y = 1, H, 2 do
		for X = 1, W, 4 do
			Set(Canvas, X, Y, "+", Dot)
		end
	end
	return Finish(Canvas)
end

function Renderers.solid(W, H, Color)
	return Finish(NewCanvas(W, H, Color))
end

local CacheKey, CacheRows

function Wallpaper.Render(Name, W, H, Color)
	local Key = table.concat({ tostring(Name), W, H, tostring(Color) }, ":")
	if (Key == CacheKey) then return CacheRows end
	local Renderer = Renderers[Name] or Renderers.overworld
	CacheRows = Renderer(W, H, Color or colors.cyan)
	CacheKey = Key
	return CacheRows
end

function Wallpaper.Draw(T, X, Y, W, H, Name, Color)
	local Rows = Renderers[Name] and Renderers[Name](W, H, Color or colors.cyan) or Renderers.overworld(W, H)
	for Row = 1, H do
		T.setCursorPos(X, Y + Row - 1)
		T.blit(Rows[Row][1], Rows[Row][2], Rows[Row][3])
	end
end

return Wallpaper
