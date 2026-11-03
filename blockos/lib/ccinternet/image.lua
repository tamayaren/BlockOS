-- Text-mode images used by .ccmd pages: .nft (cc.image.nft), .bimg (BlockOS / blit image) and .nfp (paintutils).
-- Every format becomes { W, H, Rows = { { Text, Fg, Bg } } }. A space in Bg means transparent.
-- Vendored from https://github.com/tamayaren/ccinternet (lib/image.lua), shared by Savannah and CCDream.

local Image = {}

Image.Extensions = { nft = true, bimg = true, nfp = true }

local function Pad(Text, Width, Filler)
	if (#Text >= Width) then return Text:sub(1, Width) end
	return Text .. string.rep(Filler, Width - #Text)
end

local function Hex(Text, Fallback)
	return (Text:lower():gsub("[^0-9a-f ]", Fallback))
end

function Image.Kind(Path)
	local Extension = (tostring(Path or ""):match("%.(%w+)$") or ""):lower()
	if (Image.Extensions[Extension]) then return Extension end
	return nil
end

local function Finish(Rows)
	local W = 0
	for _, Row in ipairs(Rows) do
		if (#Row[1] > W) then W = #Row[1] end
	end
	if (W == 0 or #Rows == 0) then return nil end
	for _, Row in ipairs(Rows) do
		Row[1] = Pad(Row[1], W, " ")
		Row[2] = Pad(Row[2], W, "0")
		Row[3] = Pad(Row[3], W, " ")
	end
	return { W = W, H = #Rows, Rows = Rows }
end

function Image.ParseNft(Data)
	local Rows = {}
	for Line in ((Data or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		local Text, Fg, Bg = {}, {}, {}
		local Foreground, Background = "0", "f"
		local Pos = 1
		while (Pos <= #Line) do
			local Char = Line:sub(Pos, Pos)
			if (Char == "\30") then
				Background = Hex(Line:sub(Pos + 1, Pos + 1), "f")
				Pos = Pos + 2
			elseif (Char == "\31") then
				Foreground = Hex(Line:sub(Pos + 1, Pos + 1), "0")
				Pos = Pos + 2
			else
				Text[#Text + 1] = Char
				Fg[#Fg + 1] = Foreground
				Bg[#Bg + 1] = Background
				Pos = Pos + 1
			end
		end
		Rows[#Rows + 1] = { table.concat(Text), table.concat(Fg), table.concat(Bg) }
	end
	while (#Rows > 0 and #Rows[#Rows][1] == 0) do Rows[#Rows] = nil end
	return Finish(Rows)
end

function Image.ParseNfp(Data)
	local Rows = {}
	for Line in ((Data or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		local Bg = Hex(Line, " ")
		Rows[#Rows + 1] = { string.rep(" ", #Bg), string.rep("0", #Bg), Bg }
	end
	while (#Rows > 0 and #Rows[#Rows][1] == 0) do Rows[#Rows] = nil end
	return Finish(Rows)
end

function Image.ParseBimg(Data, Unserialise)
	Unserialise = Unserialise or (textutils and textutils.unserialise)
	if (not Unserialise) then return nil end
	local Ok, Value = pcall(Unserialise, Data or "")
	if (not Ok or type(Value) ~= "table" or type(Value[1]) ~= "table") then return nil end
	local Rows = {}
	for _, Line in ipairs(Value[1]) do
		if (type(Line) ~= "table") then return nil end
		local Text = tostring(Line[1] or "")
		Rows[#Rows + 1] = {
			Text,
			Hex(Pad(tostring(Line[2] or ""), #Text, "0"), "0"),
			Hex(Pad(tostring(Line[3] or ""), #Text, "f"), "f")
		}
	end
	return Finish(Rows)
end

-- Parses image data. Kind is "nft", "bimg" or "nfp" (or a path to take the extension from).
function Image.Parse(Data, Kind)
	Kind = Image.Extensions[Kind] and Kind or Image.Kind(Kind)
	if (Kind == "nft") then return Image.ParseNft(Data) end
	if (Kind == "nfp") then return Image.ParseNfp(Data) end
	if (Kind == "bimg") then return Image.ParseBimg(Data) end
	return nil
end

-- Draws an image on a terminal-like target. Transparent pixels use Background (default black).
function Image.Draw(Picture, Target, X, Y, Background)
	Background = Background or "f"
	for Index, Row in ipairs(Picture.Rows) do
		Target.setCursorPos(X, Y + Index - 1)
		Target.blit(Row[1], Row[2], (Row[3]:gsub(" ", Background)))
	end
end

return Image
