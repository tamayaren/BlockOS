-- Glass surfaces: a frosted, blurred copy of whatever is already drawn behind a panel.
-- A pane holds one background row per line; text written on it picks colours that stay readable.
-- With Settings.Material set to "solid" the same pane API paints plain theme colours instead.

local Config = BlockOS.Require("config")

local Glass = {}

-- Bars smear a little; panels smear widely, so they settle into a few calm patches of colour.
local BarRadius = 3
local PanelRadiusX, PanelRadiusY = 8, 3
local MaxSlots = 32

local Hex, FromByte = {}, {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
	FromByte[string.byte(Hex[2 ^ Index])] = 2 ^ Index
end

local LightColours = {
	[colors.white] = true, [colors.lightGray] = true, [colors.yellow] = true, [colors.lime] = true,
	[colors.lightBlue] = true, [colors.pink] = true, [colors.cyan] = true, [colors.orange] = true
}

-- Frosting: light glass lifts dark colours a step, dark glass sinks light ones.
local Tints = {
	light = {
		[colors.black] = colors.gray, [colors.gray] = colors.lightGray, [colors.blue] = colors.lightBlue,
		[colors.purple] = colors.magenta, [colors.green] = colors.lime, [colors.brown] = colors.orange,
		[colors.red] = colors.orange, [colors.magenta] = colors.pink, [colors.cyan] = colors.lightBlue
	},
	dark = {
		[colors.white] = colors.lightGray, [colors.lightGray] = colors.gray, [colors.lightBlue] = colors.blue,
		[colors.lime] = colors.green, [colors.yellow] = colors.orange, [colors.orange] = colors.brown,
		[colors.pink] = colors.magenta, [colors.magenta] = colors.purple, [colors.cyan] = colors.blue
	}
}

-- A neighbouring shade of each colour, for texture drawn on top of glass.
local Streaks = {
	[colors.white] = colors.lightGray, [colors.lightGray] = colors.white, [colors.gray] = colors.lightGray,
	[colors.black] = colors.gray, [colors.blue] = colors.cyan, [colors.lightBlue] = colors.white,
	[colors.cyan] = colors.lightBlue, [colors.green] = colors.lime, [colors.lime] = colors.green,
	[colors.yellow] = colors.orange, [colors.orange] = colors.yellow, [colors.red] = colors.orange,
	[colors.brown] = colors.orange, [colors.purple] = colors.magenta, [colors.magenta] = colors.pink,
	[colors.pink] = colors.magenta
}

-- Blit-character lookups used with gsub over a background row.
local ContrastOf, DimOf, StreakOf = {}, {}, {}
for Color, Code in pairs(Hex) do
	ContrastOf[Code] = Hex[LightColours[Color] and colors.black or colors.white]
	DimOf[Code] = Hex[LightColours[Color] and colors.gray or colors.lightGray]
	StreakOf[Code] = Hex[Streaks[Color]]
end

-- Per-colour lookups that swap to a contrasting colour where text would vanish into the glass.
local Inks = {}

local function InkOf(Color)
	local Ink = Inks[Color]
	if (Ink) then return Ink end
	Ink = {}
	local Own = Hex[Color]
	for _, Code in pairs(Hex) do
		Ink[Code] = (Code == Own) and ContrastOf[Code] or Own
	end
	Inks[Color] = Ink
	return Ink
end

local Pane = {}
Pane.__index = Pane

-- Paints the pane's background; Texture "streak" colours Char a shade off each cell.
function Pane:Fill(T, Char, Texture, First, Last)
	local Chars = string.rep(Char or " ", self.W)
	for Y = First or 1, Last or self.H do
		local Bg = self.Rows[Y]
		if (Bg) then
			local Fg
			if (self.Solid) then
				Fg = string.rep(Hex[(Texture == "streak") and self.Dim or self.Fg], self.W)
			else
				Fg = Bg:gsub(".", (Texture == "streak") and StreakOf or ContrastOf)
			end
			T.setCursorPos(self.OX, self.OY + Y - 1)
			T.blit(Chars, Fg, Bg)
		end
	end
end

-- Writes text at pane-local X, Y. Fg is a colour, "dim", or nil for the standard text colour.
-- SolidFg replaces Fg on a solid pane, for theme colours that have no glass equivalent.
function Pane:Write(T, X, Y, Text, Fg, SolidFg)
	local Row = self.Rows[Y]
	if (not Row or X < 1 or X > self.W) then return end
	Text = tostring(Text):sub(1, self.W - X + 1)
	if (#Text == 0) then return end
	local Bg = Row:sub(X, X + #Text - 1)
	local FgRow
	if (self.Solid) then
		local Color = SolidFg or Fg
		if (Color == "dim") then
			Color = self.Dim
		elseif (not Color) then
			Color = self.Fg
		end
		FgRow = string.rep(Hex[Color], #Text)
	elseif (Fg == "dim") then
		FgRow = Bg:gsub(".", DimOf)
	elseif (Fg) then
		FgRow = Bg:gsub(".", InkOf(Fg))
	else
		FgRow = Bg:gsub(".", ContrastOf)
	end
	T.setCursorPos(self.OX + X - 1, self.OY + Y - 1)
	T.blit(Text, FgRow, Bg)
end

local function NewPane(X, Y, W, H, Rows)
	return setmetatable({ X = X, Y = Y, W = W, H = H, OX = X, OY = Y, Rows = Rows }, Pane)
end

function Glass.Enabled()
	return Config.Settings().Material ~= "solid"
end

-- A plain pane: Bg everywhere, Fg for text and Dim for secondary text.
function Glass.Solid(X, Y, W, H, Bg, Fg, Dim)
	local Row = string.rep(Hex[Bg], W)
	local Rows = {}
	for Line = 1, H do
		Rows[Line] = Row
	end
	local Result = NewPane(X, Y, W, H, Rows)
	Result.Solid, Result.Fg, Result.Dim = true, Fg, Dim or Fg
	return Result
end

local Cache, CacheSize = {}, 0

-- Most common colour within RadiusX columns of every cell of a row; ties keep the cell's own colour.
local function SmearRow(Line, First, Last, RadiusX)
	local Bytes = { string.byte(Line, 1, -1) }
	local Length = #Bytes
	local Out = {}
	for Column = First, Last do
		local Centre = math.max(1, math.min(Length, Column))
		local Best, BestCount = Bytes[Centre], 0
		local Counts = {}
		for Sample = math.max(1, Centre - RadiusX), math.min(Length, Centre + RadiusX) do
			local Byte = Bytes[Sample]
			local Count = (Counts[Byte] or 0) + 1
			Counts[Byte] = Count
			if (Count > BestCount or (Count == BestCount and Byte == Bytes[Centre])) then
				Best, BestCount = Byte, Count
			end
		end
		Out[Column - First + 1] = Best
	end
	return Out
end

-- Samples what T currently shows behind X, Y, W, H and returns a blurred, tinted pane.
-- Slot names a cache entry, so an unchanged backdrop is not blurred again; returns nil if T cannot be read.
function Glass.Pane(T, X, Y, W, H, Slot)
	if (not T.getLine or W < 1 or H < 1) then return nil end
	local _, ScreenH = T.getSize()
	local RadiusX, RadiusY = PanelRadiusX, PanelRadiusY
	if (H == 1) then RadiusX, RadiusY = BarRadius, 1 end
	local Mode = (Config.Settings().Theme == "dark") and "dark" or "light"
	local First, Last = math.max(1, Y - RadiusY), math.min(ScreenH, Y + H - 1 + RadiusY)
	local Sources, Parts = {}, { Mode, X, Y, W, H }
	for Line = First, Last do
		local _, _, Bg = T.getLine(Line)
		Sources[Line] = Bg
		Parts[#Parts + 1] = Bg
	end
	if (First > Last) then return nil end
	local Key = table.concat(Parts, ":")
	local Cached = Slot and Cache[Slot]
	if (Cached and Cached.Key == Key) then
		return NewPane(X, Y, W, H, Cached.Rows)
	end

	-- Smear along each row first, then down each column.
	local Smeared = {}
	for Line = First, Last do
		Smeared[Line] = SmearRow(Sources[Line], X, X + W - 1, RadiusX)
	end
	local Tint = Tints[Mode]
	local Rows = {}
	for Line = 1, H do
		local Centre = math.max(First, math.min(Last, Y + Line - 1))
		local Own = Smeared[Centre]
		local Out = {}
		for Column = 1, W do
			local Best, BestCount = Own[Column], 0
			local Counts = {}
			for Sample = math.max(First, Centre - RadiusY), math.min(Last, Centre + RadiusY) do
				local Byte = Smeared[Sample][Column]
				local Count = (Counts[Byte] or 0) + 1
				Counts[Byte] = Count
				if (Count > BestCount or (Count == BestCount and Byte == Own[Column])) then
					Best, BestCount = Byte, Count
				end
			end
			local Color = FromByte[Best] or colors.black
			Out[Column] = Hex[Tint[Color] or Color]
		end
		Rows[Line] = table.concat(Out)
	end
	if (Slot) then
		if (not Cache[Slot]) then
			if (CacheSize >= MaxSlots) then
				Cache, CacheSize = {}, 0
			end
			CacheSize = CacheSize + 1
		end
		Cache[Slot] = { Key = Key, Rows = Rows }
	end
	return NewPane(X, Y, W, H, Rows)
end

-- Glass when the material allows it, otherwise the solid pane described by Bg, Fg and Dim.
function Glass.Surface(T, X, Y, W, H, Slot, Bg, Fg, Dim)
	local Result = Glass.Enabled() and Glass.Pane(T, X, Y, W, H, Slot) or nil
	return Result or Glass.Solid(X, Y, W, H, Bg, Fg, Dim)
end

return Glass
