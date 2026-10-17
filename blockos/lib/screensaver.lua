-- Animated ASCII plasma used behind the lock screen, with selectable colour palettes.

local Config = BlockOS.Require("config")

local Screensaver = {}

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

-- Seconds of animation time per frame; the plasma drifts very slowly.
Screensaver.Speed = .012

function Screensaver.Get(ID)
	for _, Entry in ipairs(Screensaver.Palettes) do
		if (Entry.ID == ID) then return Entry end
	end
	return Screensaver.Palettes[1]
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

-- Renders one frame into Canvas.Chars/Fg/Bg (rows of per-cell blit characters).
function Screensaver.Render(Canvas, Time, ID)
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
