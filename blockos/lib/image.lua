-- Text-mode images: .bimg (blit image, characters with text and background colours)
-- and .nfp (paintutils, background colours only). Images are { W, H, Rows = { { Text, Fg, Bg } } }.

local Image = {}

Image.Extensions = { bimg = true, nfp = true }

local function Extension(Path)
	return (tostring(Path):match("%.(%w+)$") or ""):lower()
end

function Image.IsImage(Path)
	return Image.Extensions[Extension(Path)] == true
end

local function Fit(Text, W, Filler)
	if (#Text >= W) then return Text:sub(1, W) end
	return Text .. string.rep(Filler, W - #Text)
end

function Image.new(W, H, Bg)
	local Rows = {}
	for Y = 1, H do
		Rows[Y] = { string.rep(" ", W), string.rep("f", W), string.rep(Bg or "0", W) }
	end
	return { W = W, H = H, Rows = Rows }
end

local function ParseBimg(Data)
	local Value = textutils.unserialise(Data or "")
	if (type(Value) ~= "table" or type(Value[1]) ~= "table") then return nil end
	local Frame = Value[1]
	local W = tonumber(Value.width) or 0
	local H = 0
	for _, Line in ipairs(Frame) do
		if (type(Line) ~= "table") then return nil end
		H = H + 1
		W = math.max(W, #tostring(Line[1] or ""))
	end
	if (W == 0 or H == 0) then return nil end
	local Rows = {}
	for Y, Line in ipairs(Frame) do
		Rows[Y] = {
			Fit(tostring(Line[1] or ""), W, " "),
			Fit(tostring(Line[2] or ""):lower():gsub("[^0-9a-f]", "f"), W, "f"),
			Fit(tostring(Line[3] or ""):lower():gsub("[^0-9a-f]", "0"), W, "0")
		}
	end
	return { W = W, H = H, Rows = Rows }
end

-- Transparent nfp pixels (spaces) become white.
local function ParseNfp(Data)
	local Lines = {}
	local W = 0
	for Line in ((Data or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		table.insert(Lines, Line)
		W = math.max(W, #Line)
	end
	while (#Lines > 0 and #Lines[#Lines] == 0) do
		table.remove(Lines)
	end
	if (W == 0 or #Lines == 0) then return nil end
	local Rows = {}
	for Y, Line in ipairs(Lines) do
		local Bg = Fit(Line:lower():gsub("[^0-9a-f]", "0"), W, "0")
		Rows[Y] = { string.rep(" ", W), string.rep("f", W), Bg }
	end
	return { W = W, H = #Lines, Rows = Rows }
end

function Image.Load(Path)
	if (not Path or not fs.exists(Path) or fs.isDir(Path)) then return nil, "File not found" end
	local Handle = fs.open(Path, "r")
	if (not Handle) then return nil, "Could not open file" end
	local Data = Handle.readAll()
	Handle.close()
	local Result
	if (Extension(Path) == "nfp") then
		Result = ParseNfp(Data)
	else
		Result = ParseBimg(Data)
	end
	if (not Result) then return nil, "Not a valid image" end
	return Result
end

-- .nfp keeps only background colours; everything else is written as .bimg.
function Image.Save(Path, Img, Title)
	local Text
	if (Extension(Path) == "nfp") then
		local Lines = {}
		for Y = 1, Img.H do
			Lines[Y] = Img.Rows[Y][3]
		end
		Text = table.concat(Lines, "\n")
	else
		local Frame = {}
		for Y = 1, Img.H do
			Frame[Y] = { Img.Rows[Y][1], Img.Rows[Y][2], Img.Rows[Y][3] }
		end
		Text = textutils.serialise({
			Frame,
			version = "1.0.0",
			animation = false,
			width = Img.W,
			height = Img.H,
			title = Title,
			creator = "Brocreate"
		})
	end
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Handle = fs.open(Path, "w")
	if (not Handle) then return false end
	Handle.write(Text)
	Handle.close()
	return true
end

-- Nearest-neighbour resample to W x H blit rows.
function Image.Scale(Img, W, H)
	if (Img.W == W and Img.H == H) then return Img.Rows end
	local Rows = {}
	for Y = 1, H do
		local Source = Img.Rows[math.min(Img.H, math.floor((Y - 1) * Img.H / H) + 1)]
		local Text, Fg, Bg = {}, {}, {}
		for X = 1, W do
			local SourceX = math.min(Img.W, math.floor((X - 1) * Img.W / W) + 1)
			Text[X] = Source[1]:sub(SourceX, SourceX)
			Fg[X] = Source[2]:sub(SourceX, SourceX)
			Bg[X] = Source[3]:sub(SourceX, SourceX)
		end
		Rows[Y] = { table.concat(Text), table.concat(Fg), table.concat(Bg) }
	end
	return Rows
end

return Image
