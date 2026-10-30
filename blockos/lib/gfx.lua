-- Low-level drawing helpers shared by the window manager and apps.

local Gfx = {}

Gfx.Hex = {}
for Index = 0, 15 do
	Gfx.Hex[2 ^ Index] = string.format("%x", Index)
end

function Gfx.ToBlit(Color)
	return Gfx.Hex[Color] or "0"
end

function Gfx.Write(T, X, Y, Text, Fg, Bg)
	Text = tostring(Text)
	if (Fg) then T.setTextColor(Fg) end
	if (Bg) then T.setBackgroundColor(Bg) end
	T.setCursorPos(X, Y)
	T.write(Text)
end

function Gfx.Fill(T, X, Y, W, H, Bg, Fg, Char)
	if (W <= 0 or H <= 0) then return end
	Char = Char or " "
	local Row = string.rep(Char, W)
	local FgRow = string.rep(Gfx.ToBlit(Fg or colors.white), W)
	local BgRow = string.rep(Gfx.ToBlit(Bg), W)
	for Line = Y, Y + H - 1 do
		T.setCursorPos(X, Line)
		T.blit(Row, FgRow, BgRow)
	end
end

function Gfx.Truncate(Text, W)
	Text = tostring(Text)
	if (W <= 0) then return "" end
	if (#Text <= W) then return Text end
	if (W <= 2) then return Text:sub(1, W) end
	return Text:sub(1, W - 2) .. ".."
end

function Gfx.Pad(Text, W, Align)
	Text = Gfx.Truncate(Text, W)
	local Space = W - #Text
	if (Align == "center") then
		local Left = math.floor(Space / 2)
		return string.rep(" ", Left) .. Text .. string.rep(" ", Space - Left)
	elseif (Align == "right") then
		return string.rep(" ", Space) .. Text
	end
	return Text .. string.rep(" ", Space)
end

function Gfx.Center(T, Y, Text, Fg, Bg, X, W)
	if (not X) then
		X = 1
		W = T.getSize()
	end
	Text = Gfx.Truncate(Text, W)
	Gfx.Write(T, X + math.floor((W - #Text) / 2), Y, Text, Fg, Bg)
end

-- Splits text into lines no wider than W, keeping explicit newlines.
function Gfx.Wrap(Text, W)
	local Lines = {}
	W = math.max(W, 1)
	for Paragraph in (tostring(Text) .. "\n"):gmatch("(.-)\n") do
		local Line = ""
		for Word in Paragraph:gmatch("%S+") do
			while (#Word > W) do
				if (#Line > 0) then
					table.insert(Lines, Line)
					Line = ""
				end
				table.insert(Lines, Word:sub(1, W))
				Word = Word:sub(W + 1)
			end
			if (#Line == 0) then
				Line = Word
			elseif (#Line + 1 + #Word <= W) then
				Line = Line .. " " .. Word
			else
				table.insert(Lines, Line)
				Line = Word
			end
		end
		table.insert(Lines, Line)
	end
	return Lines
end

-- Draws a drop shadow to the right and below a rectangle.
function Gfx.Shadow(T, X, Y, W, H, Color)
	Color = Color or colors.gray
	Gfx.Fill(T, X + W, Y + 1, 1, H, Color)
	Gfx.Fill(T, X + 1, Y + H, W, 1, Color)
end

function Gfx.FormatSize(Bytes)
	if (Bytes >= 1048576) then
		return string.format("%.1f MB", Bytes / 1048576)
	elseif (Bytes >= 1024) then
		return string.format("%.1f KB", Bytes / 1024)
	end
	return string.format("%d B", Bytes)
end

-- 3x5 digits for large clocks.
Gfx.Font = {
	["0"] = { "###", "# #", "# #", "# #", "###" },
	["1"] = { " # ", "## ", " # ", " # ", "###" },
	["2"] = { "###", "  #", "###", "#  ", "###" },
	["3"] = { "###", "  #", " ##", "  #", "###" },
	["4"] = { "# #", "# #", "###", "  #", "  #" },
	["5"] = { "###", "#  ", "###", "  #", "###" },
	["6"] = { "###", "#  ", "###", "# #", "###" },
	["7"] = { "###", "  #", "  #", " # ", " # " },
	["8"] = { "###", "# #", "###", "# #", "###" },
	["9"] = { "###", "# #", "###", "  #", "###" },
	[":"] = { " ", "#", " ", "#", " " },
	["."] = { " ", " ", " ", " ", "#" }
}

function Gfx.BigWidth(Text)
	local Width = 0
	for Index = 1, #Text do
		local Glyph = Gfx.Font[Text:sub(Index, Index)]
		Width = Width + (Glyph and #Glyph[1] or 1) + 1
	end
	return Width - 1
end

-- Calls Plot(X, Y) for every filled cell of Text drawn in the large font.
function Gfx.EachBigCell(X, Y, Text, Plot)
	for Index = 1, #Text do
		local Glyph = Gfx.Font[Text:sub(Index, Index)]
		if (Glyph) then
			for Row = 1, 5 do
				local Line = Glyph[Row]
				for Column = 1, #Line do
					if (Line:sub(Column, Column) == "#") then
						Plot(X + Column - 1, Y + Row - 1)
					end
				end
			end
			X = X + #Glyph[1] + 1
		else
			X = X + 2
		end
	end
end

-- Scales the whole palette towards black; Level 1 restores the normal colours.
function Gfx.SetFade(T, Level)
	if (not T.setPaletteColor or not term.nativePaletteColor) then return false end
	for Index = 0, 15 do
		local Color = 2 ^ Index
		local R, G, B = term.nativePaletteColor(Color)
		T.setPaletteColor(Color, R * Level, G * Level, B * Level)
	end
	return true
end

return Gfx
