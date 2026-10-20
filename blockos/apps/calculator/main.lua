-- Calculator: a basic four-function calculator for BlockOS.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")

local Page = Ui.Page.new()
local Display = "0"
local Stored = nil
local Operator = nil
local Fresh = true

local Layout = {
	{ "C", "+/-", "%", "/" },
	{ "7", "8", "9", "*" },
	{ "4", "5", "6", "-" },
	{ "1", "2", "3", "+" },
	{ "0", ".", "<", "=" }
}

local function Format(Value)
	if (Value ~= Value or Value == math.huge or Value == -math.huge) then return "Error" end
	if (Value == math.floor(Value) and math.abs(Value) < 1e15) then
		return string.format("%d", Value)
	end
	return string.format("%.10g", Value)
end

local function Apply(A, B, Op)
	if (Op == "+") then return A + B end
	if (Op == "-") then return A - B end
	if (Op == "*") then return A * B end
	if (Op == "/") then return A / B end
	return B
end

local function Press(Key)
	local Value = tonumber(Display) or 0
	if (Key:match("^%d$")) then
		if (Fresh or Display == "0") then
			Display = Key
		elseif (#Display < 15) then
			Display = Display .. Key
		end
		Fresh = false
	elseif (Key == ".") then
		if (Fresh) then
			Display = "0."
		elseif (not Display:find(".", 1, true)) then
			Display = Display .. "."
		end
		Fresh = false
	elseif (Key == "C") then
		Display, Stored, Operator, Fresh = "0", nil, nil, true
	elseif (Key == "<") then
		Display = Fresh and "0" or Display:sub(1, -2)
		if (Display == "" or Display == "-") then Display = "0" end
	elseif (Key == "+/-") then
		Display = Format(-Value)
	elseif (Key == "%") then
		Display = Format(Value / 100)
		Fresh = true
	elseif (Key == "=") then
		if (Operator and Stored) then
			Display = Format(Apply(Stored, Value, Operator))
		end
		Stored, Operator, Fresh = nil, nil, true
	else
		if (Operator and Stored and not Fresh) then
			Value = Apply(Stored, Value, Operator)
			Display = Format(Value)
		end
		Stored, Operator, Fresh = Value, Key, true
	end
	Page:Invalidate()
end

local function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 1, W = W, H = 3,
		OnDraw = function(Self, T, Th)
			Gfx.Fill(T, Self.X, Self.Y, Self.W, Self.H, Th.Panel)
			local Pending = (Stored and Operator) and (Format(Stored) .. " " .. Operator) or ""
			Gfx.Write(T, Self.X, Self.Y, Gfx.Pad(Pending, Self.W - 1, "right"), Th.SubText, Th.Panel)
			Gfx.Write(T, Self.X, Self.Y + 1, Gfx.Pad(Display, Self.W - 1, "right"), Th.PanelFg, Th.Panel)
		end
	}))
	local CellW = math.max(3, math.floor(W / 4))
	local CellH = math.max(1, math.floor((H - 3) / #Layout))
	for Row, Keys in ipairs(Layout) do
		for Column, Key in ipairs(Keys) do
			local Style = "default"
			if (Column == 4) then Style = "primary" end
			Page:Add(Ui.Button.new({
				X = (Column - 1) * CellW + 1,
				Y = 4 + (Row - 1) * CellH,
				W = (Column == 4) and (W - CellW * 3) or (CellW - 1),
				H = math.max(1, CellH - (CellH > 1 and 1 or 0)),
				Text = Key,
				Style = Style,
				OnClick = function() Press(Key) end
			}))
		end
	end
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A)
	if (Name == "char") then
		if (A:match("^[%d%.%+%-%*/%%=]$")) then
			Press(A)
			return true
		elseif (A == "c") then
			Press("C")
			return true
		end
	elseif (Name == "key") then
		if (A == keys.enter or A == keys.numPadEnter) then
			Press("=")
			return true
		elseif (A == keys.backspace) then
			Press("<")
			return true
		elseif (A == keys.delete) then
			Press("C")
			return true
		end
	end
	return false
end

Page:Run()
