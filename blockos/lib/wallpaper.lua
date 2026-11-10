-- Procedural ASCII wallpapers rendered to blit rows, or a picture saved from Brocreate.

local Image = BlockOS.Require("image")

local Wallpaper = {}

Wallpaper.List = {
	{ ID = "overworld", Name = "Overworld" },
	{ ID = "mountain", Name = "Mountain" },
	{ ID = "night", Name = "Starry Night" },
	{ ID = "nether", Name = "Nether" },
	{ ID = "ocean", Name = "Ocean" },
	{ ID = "dusk", Name = "Dusk" },
	{ ID = "deepslate", Name = "Deepslate" },
	{ ID = "cave", Name = "Cave" },
	{ ID = "theend", Name = "The End" },
	{ ID = "grid", Name = "Grid" },
	{ ID = "solid", Name = "Solid Colour" }
}

-- Wallpapers that use the chosen colour.
Wallpaper.Coloured = { grid = true, solid = true }

-- Extra Settings entry, offered once Settings.WallpaperImage is set.
Wallpaper.Picture = { ID = "picture", Name = "Picture" }

-- Bumped when a picture file changes so cached renders are redrawn.
Wallpaper.Revision = 0

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

-- One ASCII peak: "/" and "\" slopes, a lit left face, a shaded right face and a snow cap.
-- Rock and Snow are { lit, shaded } colour pairs.
local function Peak(Canvas, Rand, ApexX, ApexY, BaseY, Rock, Snow)
	local SnowRows = math.max(2, math.floor((BaseY - ApexY) * .38))
	for Y = ApexY, BaseY do
		local Depth = Y - ApexY
		-- The ridge wanders a little on its way down from the summit.
		local Ridge = ApexX + math.floor(math.sin(Depth * .8) * math.min(Depth, 3) * .5 + .5)
		for X = ApexX - Depth, ApexX + Depth + 1 do
			local Lit = X <= Ridge
			-- The snow line is ragged, and reaches lower on the lit side.
			local Snowy = Depth < SnowRows + (Lit and 1 or 0) - ((X + Depth) % 3 == 0 and 1 or 0)
			local Pair = Snowy and Snow or Rock
			local Color = Lit and Pair[1] or Pair[2]
			if (X == ApexX - Depth) then
				Set(Canvas, X, Y, "/", Color)
			elseif (X == ApexX + Depth + 1) then
				Set(Canvas, X, Y, "\\", Color)
			else
				local Char = " "
				if (X == Ridge and Depth > 0) then
					Char = (Depth % 2 == 0) and "\\" or "/"
				elseif (Rand(7) == 0) then
					Char = Lit and "." or "'"
				end
				Set(Canvas, X, Y, Char, Lit and Pair[2] or colors.black, Color)
			end
		end
	end
end

function Renderers.mountain(W, H)
	local Canvas = NewCanvas(W, H, colors.lightBlue)
	local Rand = Random(2000)
	local BaseY = math.floor(H * .72)
	-- Deep blue overhead, and a pink dawn glow low between the peaks.
	for Y = 1, BaseY do
		local Band = (Y <= H * .12) and colors.blue or ((Y >= BaseY - 2) and colors.pink or colors.lightBlue)
		for X = 1, W do
			Set(Canvas, X, Y, " ", nil, Band)
		end
	end
	-- A hazy range first, then the main peaks in front of it: { X, summit height } as fractions.
	local Haze = { { colors.cyan, colors.blue }, { colors.white, colors.lightGray } }
	local Stone = { { colors.lightGray, colors.gray }, { colors.white, colors.lightGray } }
	for _, Spot in ipairs({ { .1, .44 }, { .5, .34 }, { .88, .42 } }) do
		Peak(Canvas, Rand, math.floor(W * Spot[1]), math.floor(H * Spot[2]), BaseY, Haze[1], Haze[2])
	end
	for _, Spot in ipairs({ { .72, .26 }, { 0, .5 }, { 1, .46 }, { .3, .16 } }) do
		Peak(Canvas, Rand, math.floor(W * Spot[1]), math.max(2, math.floor(H * Spot[2])), BaseY, Stone[1], Stone[2])
	end
	-- Clouds drift in front of the summits.
	for _ = 1, math.max(2, math.floor(W / 18)) do
		local CloudX, CloudY = Rand(W) + 1, Rand(math.max(1, math.floor(H * .2))) + math.floor(H * .12) + 2
		local Length = Rand(5) + 5
		for X = CloudX, CloudX + Length do
			Set(Canvas, X, CloudY, (X == CloudX) and "(" or ((X == CloudX + Length) and ")" or "_"), colors.lightGray, colors.white)
		end
		for X = CloudX + 2, CloudX + Length - 2 do
			Set(Canvas, X, CloudY - 1, " ", nil, colors.white)
		end
	end
	-- Pines along the foot of the mountains, then a meadow with a small lake.
	local LakeX, LakeY = W * .68, BaseY + (H - BaseY) * .5 + 1
	for X = 1, W do
		local TreeTop = BaseY + math.floor(math.sin(X / 6) + .5)
		for Y = TreeTop, H do
			if (Y <= TreeTop + 1) then
				Set(Canvas, X, Y, (Rand(3) ~= 0) and "\30" or " ", colors.lime, colors.green)
			elseif (((X - LakeX) / (W * .16)) ^ 2 + ((Y - LakeY) / 1.4) ^ 2 < 1) then
				Set(Canvas, X, Y, (Rand(3) == 0) and "~" or " ", colors.white, colors.lightBlue)
			else
				Set(Canvas, X, Y, (Rand(5) == 0) and "\"" or " ", colors.green, colors.lime)
			end
		end
	end
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

function Renderers.dusk(W, H)
	local Canvas = NewCanvas(W, H, colors.black)
	local Rand = Random(21)
	local Bands = { colors.black, colors.black, colors.blue, colors.purple, colors.magenta }
	for Y = 1, H do
		local Band = Bands[math.min(#Bands, math.floor(Y / H * #Bands * .9) + 1)]
		for X = 1, W do
			Set(Canvas, X, Y, " ", nil, Band)
		end
	end
	for _ = 1, math.floor(W * H / 40) do
		Set(Canvas, Rand(W) + 1, Rand(math.max(1, math.floor(H * .35))) + 1, (Rand(3) == 0) and "+" or ".", colors.lightGray)
	end
	for X = W - 9, W - 7 do
		Set(Canvas, X, 3, " ", nil, colors.white)
	end
	Set(Canvas, W - 8, 4, " ", nil, colors.lightGray)
	local Phase = Rand(100) / 10
	for X = 1, W do
		local Height = math.floor(H * .78 + math.sin(X / 6 + Phase) * 2 + math.sin(X / 2.3) * .6 + .5)
		for Y = Height, H do
			Set(Canvas, X, Y, (Y == Height and Rand(3) == 0) and "\"" or " ", colors.gray, colors.black)
		end
	end
	return Finish(Canvas)
end

function Renderers.deepslate(W, H)
	local Canvas = NewCanvas(W, H, colors.gray)
	local Rand = Random(64)
	for Y = 1, H do
		for X = 1, W do
			local Offset = (math.floor((Y - 1) / 2) % 2) * 4
			if ((X + Offset) % 8 == 0 or Y % 2 == 0 and Rand(3) == 0) then
				Set(Canvas, X, Y, (Rand(2) == 0) and "_" or " ", colors.black, colors.gray)
			end
			if (Rand(9) == 0) then
				Set(Canvas, X, Y, ({ ".", ":", "'" })[Rand(3) + 1], colors.black)
			end
		end
	end
	for _ = 1, math.max(2, math.floor(W * H / 180)) do
		local OreX, OreY = Rand(W - 2) + 1, Rand(H - 1) + 1
		local Ore = ({ colors.cyan, colors.red, colors.lightBlue, colors.lime })[Rand(4) + 1]
		Set(Canvas, OreX, OreY, "\7", Ore)
		Set(Canvas, OreX + 1, OreY, ".", Ore)
	end
	return Finish(Canvas)
end

function Renderers.cave(W, H)
	local Canvas = NewCanvas(W, H, colors.black)
	local Rand = Random(31)
	for X = 1, W do
		local Ceiling = math.floor(2 + math.sin(X / 4) * 1.5 + math.sin(X / 1.7) * .7 + .5)
		local Floor = math.floor(H * .72 + math.sin(X / 5 + 1) * 1.6 + .5)
		for Y = 1, H do
			if (Y <= Ceiling or Y >= Floor) then
				Set(Canvas, X, Y, (Rand(5) == 0) and ":" or " ", colors.lightGray, colors.gray)
			end
		end
		if (Rand(9) == 0) then
			Set(Canvas, X, Ceiling + 1, "'", colors.gray)
		end
	end
	local PoolX = math.floor(W * .55)
	for X = PoolX, math.min(W, PoolX + math.floor(W / 5)) do
		Set(Canvas, X, H - 1, (Rand(3) == 0) and "~" or " ", colors.yellow, colors.orange)
		Set(Canvas, X, H, " ", nil, colors.red)
	end
	for _ = 1, math.max(3, math.floor(W / 8)) do
		Set(Canvas, Rand(W) + 1, H - Rand(3), "\7", ({ colors.cyan, colors.red, colors.yellow })[Rand(3) + 1])
	end
	Set(Canvas, 4, math.floor(H * .6), "i", colors.yellow)
	return Finish(Canvas)
end

function Renderers.theend(W, H)
	local Canvas = NewCanvas(W, H, colors.black)
	local Rand = Random(77)
	for _ = 1, math.floor(W * H / 25) do
		Set(Canvas, Rand(W) + 1, Rand(H) + 1, ".", (Rand(3) == 0) and colors.purple or colors.gray)
	end
	local Center = math.floor(W / 2)
	local Top = math.floor(H * .7)
	for Y = Top, H do
		local Half = math.floor((W * .45) * (1 - (Y - Top) / (H - Top + 2)))
		for X = Center - Half, Center + Half do
			Set(Canvas, X, Y, (Rand(4) == 0) and "." or " ", colors.brown, (Y == Top) and colors.yellow or colors.white)
		end
	end
	for _ = 1, 3 do
		local PlantX = Center + Rand(math.floor(W * .6)) - math.floor(W * .3)
		local Height = Rand(4) + 3
		for Y = Top - Height, Top - 1 do
			Set(Canvas, PlantX, Y, " ", nil, colors.purple)
		end
		Set(Canvas, PlantX, Top - Height - 1, " ", nil, colors.magenta)
	end
	for _, Pillar in ipairs({ math.floor(W * .2), math.floor(W * .8) }) do
		for Y = Top - 5, Top - 1 do
			Set(Canvas, Pillar, Y, " ", nil, colors.gray)
		end
		Set(Canvas, Pillar, Top - 6, "\7", colors.pink, colors.black)
	end
	return Finish(Canvas)
end

function Renderers.grid(W, H, Color)
	local Canvas = NewCanvas(W, H, Color)
	local Dot = colors.lightGray
	if (Color == colors.white or Color == colors.lightGray) then
		Dot = colors.gray
	elseif (Color == colors.black) then
		Dot = colors.gray
	end
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

-- Stretches the picture to fill the screen; falls back to the solid colour if it cannot be read.
function Renderers.picture(W, H, Color, ImagePath)
	local Img = Image.Load(ImagePath)
	if (not Img) then return Renderers.solid(W, H, Color) end
	return Image.Scale(Img, W, H)
end

function Wallpaper.Invalidate()
	Wallpaper.Revision = Wallpaper.Revision + 1
end

local CacheKey, CacheRows

function Wallpaper.Render(Name, W, H, Color, ImagePath)
	local Key = table.concat({ tostring(Name), W, H, tostring(Color), tostring(ImagePath), Wallpaper.Revision }, ":")
	if (Key == CacheKey) then return CacheRows end
	local Renderer = Renderers[Name] or Renderers.overworld
	CacheRows = Renderer(W, H, Color or colors.cyan, ImagePath)
	CacheKey = Key
	return CacheRows
end

function Wallpaper.Draw(T, X, Y, W, H, Name, Color, ImagePath)
	local Rows = Renderers[Name] and Renderers[Name](W, H, Color or colors.cyan, ImagePath) or Renderers.overworld(W, H)
	for Row = 1, H do
		T.setCursorPos(X, Y + Row - 1)
		T.blit(Rows[Row][1], Rows[Row][2], Rows[Row][3])
	end
end

return Wallpaper
