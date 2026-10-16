-- The BlockOS logo: an ASCII grass block with a bite taken out of its side.

local Logo = {}

-- Each letter maps to { Char, Fg, Bg }; spaces are transparent.
local Legend = {
	G = { " ", colors.lime, colors.green },
	g = { "\"", colors.lime, colors.green },
	v = { "'", colors.lime, colors.green },
	D = { " ", colors.orange, colors.brown },
	d = { ".", colors.orange, colors.brown },
	o = { ":", colors.lightGray, colors.brown },
	x = { "'", colors.orange, colors.brown }
}

Logo.Big = {
	"GgGGGvGGGGgGGGvG",
	"GGDGGGGDGGGvG   ",
	"DdDDGDDDDdDD    ",
	"DDDoDDDxDDDD    ",
	"DdDDDDoDDDDdD   ",
	"DDDdDDDDDoDDDDdD",
	"DoDDDxDDDDDDdDDD"
}

Logo.Small = {
	"GvGGgG  ",
	"DDdDD   ",
	"DoDDxD  ",
	"DDDdDDo "
}

Logo.Text = {
	" ____  _            _     ___  ____  ",
	"| __ )| | ___   ___| | __/ _ \\/ ___| ",
	"|  _ \\| |/ _ \\ / __| |/ / | | \\___ \\ ",
	"| |_) | | (_) | (__|   <| |_| |___) |",
	"|____/|_|\\___/ \\___|_|\\_\\\\___/|____/ "
}

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

function Logo.Size(Art)
	Art = Art or Logo.Big
	return #Art[1], #Art
end

function Logo.Draw(T, X, Y, Art)
	Art = Art or Logo.Big
	for Row, Line in ipairs(Art) do
		for Column = 1, #Line do
			local Entry = Legend[Line:sub(Column, Column)]
			if (Entry) then
				T.setCursorPos(X + Column - 1, Y + Row - 1)
				T.blit(Entry[1], Hex[Entry[2]], Hex[Entry[3]])
			end
		end
	end
end

-- Draws the logo with rows revealed up to Progress (0..1), used for intro animations.
function Logo.DrawPartial(T, X, Y, Progress, Art)
	Art = Art or Logo.Big
	local Visible = math.floor(#Art * Progress + .5)
	local Partial = {}
	for Row = #Art - Visible + 1, #Art do
		Partial[#Partial + 1] = Art[Row]
	end
	Logo.Draw(T, X, Y + #Art - Visible, Partial)
end

function Logo.DrawText(T, X, Y, Fg)
	if (Fg) then T.setTextColor(Fg) end
	for Row, Line in ipairs(Logo.Text) do
		T.setCursorPos(X, Y + Row - 1)
		T.write(Line)
	end
end

return Logo
