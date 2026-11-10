-- Animated backgrounds for the lock screen: Horizon, a mountain range drifting under a sky that
-- follows the time of day, and the original ASCII plasma with selectable colour palettes.

local Config = BlockOS.Require("config")

local Screensaver = {}

-- The first style is the default.
Screensaver.Styles = {
	{ ID = "horizon", Name = "Horizon" },
	{ ID = "plasma", Name = "Plasma" }
}

local Density = { " ", ".", ":", "-", "=", "+", "*", "#", "%", "@" }

-- Shades run from the background colour up to the brightest highlight.
Screensaver.Palettes = {
	{ ID = "accent", Name = "Accent Colour" },
	{ ID = "aurora", Name = "Aurora", Shades = { colors.black, colors.gray, colors.blue, colors.purple, colors.magenta, colors.cyan, colors.lightBlue, colors.white }, High = colors.blue },
	{ ID = "sunset", Name = "Sunset", Shades = { colors.black, colors.purple, colors.red, colors.orange, colors.yellow, colors.white }, High = colors.red },
	{ ID = "forest", Name = "Forest", Shades = { colors.black, colors.gray, colors.green, colors.lime, colors.yellow, colors.white }, High = colors.green },
	{ ID = "ocean", Name = "Ocean", Shades = { colors.black, colors.blue, colors.cyan, colors.lightBlue, colors.white }, High = colors.blue },
	{ ID = "ember", Name = "Ember", Shades = { colors.black, colors.brown, colors.red, colors.orange, colors.yellow }, High = colors.brown },
	{ ID = "mono", Name = "Monochrome", Shades = { colors.black, colors.gray, colors.lightGray, colors.white }, High = colors.gray }
}

local AccentShades = {
	[colors.blue] = { colors.black, colors.gray, colors.blue, colors.cyan, colors.lightBlue, colors.white },
	[colors.purple] = { colors.black, colors.gray, colors.purple, colors.magenta, colors.pink, colors.white },
	[colors.magenta] = { colors.black, colors.purple, colors.magenta, colors.pink, colors.white },
	[colors.red] = { colors.black, colors.brown, colors.red, colors.orange, colors.pink, colors.white },
	[colors.orange] = { colors.black, colors.brown, colors.orange, colors.yellow, colors.white },
	[colors.yellow] = { colors.black, colors.brown, colors.orange, colors.yellow, colors.white },
	[colors.green] = { colors.black, colors.gray, colors.green, colors.lime, colors.yellow, colors.white },
	[colors.cyan] = { colors.black, colors.gray, colors.cyan, colors.lightBlue, colors.white }
}

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

-- Seconds of animation time per frame; both styles drift very slowly.
Screensaver.Speed = .012

function Screensaver.Get(ID)
	for _, Entry in ipairs(Screensaver.Palettes) do
		if (Entry.ID == ID) then return Entry end
	end
	return Screensaver.Palettes[1]
end

function Screensaver.Style(ID)
	ID = ID or Config.Settings().LockStyle
	for _, Entry in ipairs(Screensaver.Styles) do
		if (Entry.ID == ID) then return Entry end
	end
	return Screensaver.Styles[1]
end

-- Returns the shade list and highlight background for a palette ID.
function Screensaver.Colours(ID)
	local Entry = Screensaver.Get(ID or Config.Settings().LockColors)
	if (Entry.Shades) then
		return Entry.Shades, Entry.High
	end
	local Accent = Config.Settings().Accent or colors.blue
	local Shades = AccentShades[Accent] or AccentShades[colors.blue]
	local High = Accent
	if (Accent == colors.yellow) then High = colors.orange end
	return Shades, High
end

local function RenderPlasma(Canvas, Time, ID)
	local W, H = Canvas.W, Canvas.H
	local Shades, High = Screensaver.Colours(ID)
	local HighHex, BaseHex = Hex[High], Hex[Shades[1]]
	local Columns, Rows, Diagonal = {}, {}, {}
	for X = 1, W do
		Columns[X] = math.sin(X / 5 + Time)
	end
	for Y = 1, H do
		Rows[Y] = math.sin(Y / 2.5 - Time * .7)
	end
	for Index = 1, W + H do
		Diagonal[Index] = math.sin(Index / 7 + Time * 1.3)
	end
	for Y = 1, H do
		local Chars, Fg, Bg = Canvas.Chars[Y], Canvas.Fg[Y], Canvas.Bg[Y]
		for X = 1, W do
			local Value = (Columns[X] + Rows[Y] + Diagonal[X + Y] + 3) / 6
			local CharIndex = math.max(1, math.min(#Density, math.floor(Value * #Density) + 1))
			local ShadeIndex = math.max(1, math.min(#Shades, math.floor(Value * #Shades) + 1))
			Chars[X] = Density[CharIndex]
			Fg[X] = Hex[Shades[ShadeIndex]]
			Bg[X] = (Value > .78) and HighHex or BaseHex
		end
	end
end

--
-- Horizon
--

-- Sky bands run from the top of the screen down to the horizon; each phase lasts until its hour.
local Phases = {
	{ Until = 4.75, Sky = { colors.black, colors.black, colors.black, colors.black, colors.black }, Far = colors.gray, Snow = colors.lightGray, Mid = colors.blue, Near = colors.black, Stars = true },
	{ Until = 5.75, Sky = { colors.black, colors.black, colors.blue, colors.purple, colors.magenta }, Far = colors.gray, Snow = colors.pink, Mid = colors.blue, Near = colors.black, Stars = true },
	{ Until = 6.75, Sky = { colors.blue, colors.purple, colors.magenta, colors.red, colors.orange }, Far = colors.gray, Snow = colors.pink, Mid = colors.brown, Near = colors.black },
	{ Until = 8.5, Sky = { colors.lightBlue, colors.lightBlue, colors.lightBlue, colors.pink, colors.orange }, Far = colors.lightGray, Snow = colors.white, Mid = colors.cyan, Near = colors.green, Clouds = colors.white },
	{ Until = 16.5, Sky = { colors.blue, colors.lightBlue, colors.lightBlue, colors.lightBlue, colors.lightBlue }, Far = colors.lightGray, Snow = colors.white, Mid = colors.cyan, Near = colors.green, Clouds = colors.white },
	{ Until = 17.75, Sky = { colors.blue, colors.lightBlue, colors.pink, colors.orange, colors.red }, Far = colors.magenta, Snow = colors.pink, Mid = colors.purple, Near = colors.gray, Clouds = colors.pink },
	{ Until = 18.75, Sky = { colors.blue, colors.purple, colors.magenta, colors.red, colors.orange }, Far = colors.purple, Snow = colors.pink, Mid = colors.gray, Near = colors.black },
	{ Until = 19.75, Sky = { colors.black, colors.black, colors.blue, colors.purple, colors.magenta }, Far = colors.gray, Snow = colors.lightGray, Mid = colors.blue, Near = colors.black, Stars = true }
}

local DarkSky = { [colors.black] = true, [colors.blue] = true, [colors.purple] = true }
local StarChars = { ".", ".", "+", "*", "\7" }

local function PhaseAt(Hour)
	for _, Phase in ipairs(Phases) do
		if (Hour < Phase.Until) then return Phase end
	end
	return Phases[1]
end

-- A sawtooth mountain profile: 1 at every whole number, 0 halfway between.
local function Peak(Value)
	return math.abs((Value % 1) * 2 - 1)
end

-- The hour of day the sky follows, from the clock the user picked in Settings.
function Screensaver.Hour()
	local Game = Config.Settings().ClockSource == "game"
	local Ok, Value = pcall(os.time, Game and "ingame" or "local")
	if (Ok and type(Value) == "number") then return Value % 24 end
	return 12
end

-- Stars and clouds are scattered once per canvas size so they hold still between frames.
local function Scatter(Canvas)
	local State = 7
	local function Rand(Max)
		State = (State * 1103515245 + 12345) % 2147483648
		return math.floor(State / 65536) % Max
	end
	local W, H = Canvas.W, Canvas.H
	local Stars = {}
	for Index = 1, math.floor(W * H / 16) do
		local X, Y = Rand(W) + 1, Rand(H) + 1
		Stars[Y] = Stars[Y] or {}
		Stars[Y][X] = { Char = StarChars[Rand(#StarChars) + 1], Beat = Index, Bright = Rand(3) ~= 0 }
	end
	local Clouds = {}
	for Index = 1, math.max(2, math.floor(W / 16)) do
		Clouds[Index] = { X = Rand(W + 24), Y = Rand(math.max(1, math.floor(H * .22))) + 2, Length = Rand(6) + 6, Pace = Rand(3) + 1 }
	end
	Canvas.Stars, Canvas.Clouds = Stars, Clouds
end

-- Draws the scene at half-cell width and third-cell height, then packs it into block characters.
local function BuildHorizon(Canvas, Scene, Tick, Hour)
	local W, H = Canvas.W, Canvas.H
	local SubW, SubH = W * 2, H * 3
	local Phase = PhaseAt(Hour)
	local Horizon = math.floor(SubH * .64)
	local SkyRows = math.max(1, math.ceil(Horizon / 3))

	-- Ridge tops per half-cell column, as the first filled sub-row. Nearer ridges drift faster.
	local FarTop, SnowEnd, MidTop, NearTop = {}, {}, {}, {}
	local SnowLine = SubH * .56
	for Column = 1, SubW do
		local Far = Column + math.floor(Tick / 4)
		local Mid = Column + math.floor(Tick / 2) + 40
		local Near = Column + Tick
		local Top = math.floor(SubH * (.74 - .30 * (.6 * Peak(Far / 58) + .28 * Peak(Far / 23 + .37) + .12 * Peak(Far / 9 + .11))) + .5)
		FarTop[Column] = Top
		SnowEnd[Column] = (Top < SnowLine) and (Top + math.min(3, math.floor((SnowLine - Top) / 2) + 1)) or Top
		MidTop[Column] = math.floor(SubH * (.82 - .20 * (.65 * Peak(Mid / 41) + .35 * Peak(Mid / 15 + .2))) + .5)
		NearTop[Column] = math.floor(SubH * (.87 - .05 * math.sin(Near / 17) - .03 * math.sin(Near / 5.3 + 1)) + .5)
	end

	-- The sun by day and a crescent moon by night, on an arc that starts and ends at the horizon.
	local Radius = math.max(2.6, SubH / 20)
	local DiscX, DiscY, DiscColor, Bite
	local Day = (Hour - 5.75) / 13
	local Night = ((Hour - 19) % 24) / 10.5
	if (Day > 0 and Day < 1) then
		DiscX = SubW * (.12 + .76 * Day)
		DiscY = Horizon - math.sin(math.pi * Day) * (Horizon - Radius - 4)
		DiscColor = colors.yellow
	elseif (Night < 1) then
		DiscX = SubW * (.12 + .76 * Night)
		DiscY = Horizon - math.sin(math.pi * Night) * (Horizon - Radius - 4)
		DiscColor, Bite = colors.white, true
	end
	local Reach = Radius * Radius

	local FarColor, SnowColor, MidColor, NearColor = Phase.Far, Phase.Snow, Phase.Mid, Phase.Near
	-- Colour of one sub-cell: the nearest ridge covering it, else the sun or moon, else the sky.
	local function Sample(Column, Row, Sky)
		if (Row >= NearTop[Column]) then return NearColor end
		if (Row >= MidTop[Column]) then return MidColor end
		if (Row >= FarTop[Column]) then
			return (Row < SnowEnd[Column]) and SnowColor or FarColor
		end
		if (DiscX) then
			local DX, DY = Column - DiscX, Row - DiscY
			if (DX * DX + DY * DY <= Reach) then
				if (not Bite) then return DiscColor end
				local BX, BY = DX - Radius * .7, DY + Radius * .3
				if (BX * BX + BY * BY > Reach * .8) then return DiscColor end
			end
		end
		return Sky
	end

	local function Layer(Column, Row)
		if (Row >= NearTop[Column]) then return 3 end
		if (Row >= MidTop[Column]) then return 2 end
		if (Row >= FarTop[Column]) then return 1 end
		return 0
	end

	local CloudCells = {}
	if (Phase.Clouds) then
		for _, Cloud in ipairs(Canvas.Clouds) do
			local Left = (Cloud.X + math.floor(Tick * Cloud.Pace / 12)) % (W + 24) - 12
			for X = Left, Left + Cloud.Length do
				CloudCells[Cloud.Y * 1024 + X] = true
				if (X >= Left + 2 and X <= Left + Cloud.Length - 3) then
					CloudCells[(Cloud.Y - 1) * 1024 + X] = true
				end
			end
		end
	end

	local Solid = { [1] = FarColor, [2] = MidColor, [3] = NearColor }
	for Y = 1, H do
		local Chars, Fg, Bg = Scene.Chars[Y], Scene.Fg[Y], Scene.Bg[Y]
		local Band = math.min(5, math.floor((Y - 1) * 5 / SkyRows) + 1)
		local Sky = Phase.Sky[Band]
		-- The last row of a band is dithered into the next one.
		local NextSky = Phase.Sky[math.min(5, math.floor(Y * 5 / SkyRows) + 1)]
		local Top, Bottom = Y * 3 - 2, Y * 3
		local StarRow = Phase.Stars and DarkSky[Sky] and NextSky == Sky and Canvas.Stars[Y]
		local NearDisc = DiscX and Bottom >= DiscY - Radius - 1 and Top <= DiscY + Radius + 1
		for X = 1, W do
			local Left, Right = X * 2 - 1, X * 2
			local Kind = Layer(Left, Top)
			local Uniform = Kind == Layer(Left, Bottom) and Kind == Layer(Right, Top) and Kind == Layer(Right, Bottom)
			if (Uniform and Kind == 1) then
				Uniform = Top >= SnowEnd[Left] and Top >= SnowEnd[Right]
			elseif (Uniform and Kind == 0 and NearDisc) then
				Uniform = Right < DiscX - Radius - 1 or Left > DiscX + Radius + 1
			end
			if (not Uniform) then
				local Last = Sample(Right, Bottom, Sky)
				local Cells = {
					Sample(Left, Top, Sky), Sample(Right, Top, Sky),
					Sample(Left, Top + 1, Sky), Sample(Right, Top + 1, Sky),
					Sample(Left, Bottom, Sky)
				}
				-- Block characters hold two colours: the bottom-right sub-cell's, and the commonest other.
				local Bits, Other, OtherCount, Counts = 0, Last, 0, {}
				for Index = 1, 5 do
					local Color = Cells[Index]
					if (Color ~= Last) then
						Bits = Bits + 2 ^ (Index - 1)
						local Count = (Counts[Color] or 0) + 1
						Counts[Color] = Count
						if (Count > OtherCount) then
							Other, OtherCount = Color, Count
						end
					end
				end
				Chars[X] = string.char(128 + Bits)
				Fg[X] = Hex[Other]
				Bg[X] = Hex[Last]
			elseif (Kind > 0) then
				Chars[X], Fg[X], Bg[X] = " ", Hex[colors.white], Hex[Solid[Kind]]
			elseif (CloudCells[Y * 1024 + X]) then
				Chars[X], Fg[X], Bg[X] = " ", Hex[colors.white], Hex[Phase.Clouds]
			else
				local Star = StarRow and StarRow[X]
				if (Star and (Star.Beat + math.floor(Tick / 6)) % 7 ~= 0) then
					Chars[X], Fg[X] = Star.Char, Hex[Star.Bright and colors.white or colors.lightGray]
				elseif (NextSky ~= Sky) then
					Chars[X], Fg[X] = "\127", Hex[NextSky]
				else
					Chars[X], Fg[X] = " ", Hex[colors.white]
				end
				Bg[X] = Hex[Sky]
			end
		end
	end
end

local function RenderHorizon(Canvas, Time, Hour)
	local W, H = Canvas.W, Canvas.H
	local Scene = Canvas.Scene
	if (not Scene) then
		Scene = Screensaver.NewCanvas(W, H)
		Canvas.Scene = Scene
		Scatter(Canvas)
	end
	-- The scene only changes when the nearest ridge moves on by half a cell, twice a second or so.
	local Tick = math.floor(Time * 16)
	Hour = Hour or Screensaver.Hour()
	local Key = Tick .. ":" .. math.floor(Hour * 30)
	if (Scene.Key ~= Key) then
		BuildHorizon(Canvas, Scene, Tick, Hour)
		Scene.Key = Key
	end
	for Y = 1, H do
		local Chars, Fg, Bg = Canvas.Chars[Y], Canvas.Fg[Y], Canvas.Bg[Y]
		local FromChars, FromFg, FromBg = Scene.Chars[Y], Scene.Fg[Y], Scene.Bg[Y]
		for X = 1, W do
			Chars[X], Fg[X], Bg[X] = FromChars[X], FromFg[X], FromBg[X]
		end
	end
end

-- Renders one frame into Canvas.Chars/Fg/Bg (rows of per-cell blit characters).
-- ID is the plasma palette, Style the background and Hour the time of day; each defaults to the user's setting.
-- Canvas.AutoInk is set when the backdrop is bright in places, so text on it should pick its own contrast.
function Screensaver.Render(Canvas, Time, ID, Style, Hour)
	if (Screensaver.Style(Style).ID == "plasma") then
		Canvas.AutoInk = false
		RenderPlasma(Canvas, Time, ID)
	else
		Canvas.AutoInk = true
		RenderHorizon(Canvas, Time, Hour)
	end
end

function Screensaver.NewCanvas(W, H)
	local Canvas = { W = W, H = H, Chars = {}, Fg = {}, Bg = {} }
	for Y = 1, H do
		Canvas.Chars[Y], Canvas.Fg[Y], Canvas.Bg[Y] = {}, {}, {}
	end
	return Canvas
end

function Screensaver.Blit(T, Canvas, X, Y)
	X, Y = X or 1, Y or 1
	for Row = 1, Canvas.H do
		T.setCursorPos(X, Y + Row - 1)
		T.blit(table.concat(Canvas.Chars[Row]), table.concat(Canvas.Fg[Row]), table.concat(Canvas.Bg[Row]))
	end
end

return Screensaver
