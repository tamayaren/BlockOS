-- BlockCloud wire encoding: a canonical, length-prefixed serialisation that is safe to parse
-- (no load(), unlike textutils.unserialise), plus hex helpers and an incremental Adler-32.
-- Canonical means the same table always encodes to the same bytes, so encodings can be signed.

local Codec = {}

Codec.MaxDepth = 24

local function KeyOrder(A, B)
	local TA, TB = type(A), type(B)
	if (TA ~= TB) then return TA < TB end
	return A < B
end

local function EncodeInto(Value, Out, Depth)
	local Kind = type(Value)
	if (Kind == "nil") then
		Out[#Out + 1] = "n"
	elseif (Kind == "boolean") then
		Out[#Out + 1] = Value and "T" or "F"
	elseif (Kind == "number") then
		if (Value ~= Value or Value == math.huge or Value == -math.huge) then
			error("cannot encode " .. tostring(Value), 0)
		end
		if (Value == math.floor(Value) and math.abs(Value) < 2 ^ 53) then
			Out[#Out + 1] = string.format("i%d;", Value)
		else
			Out[#Out + 1] = string.format("f%.17g;", Value)
		end
	elseif (Kind == "string") then
		Out[#Out + 1] = "s" .. #Value .. ":"
		Out[#Out + 1] = Value
	elseif (Kind == "table") then
		if (Depth >= Codec.MaxDepth) then error("table nested too deeply", 0) end
		local Keys = {}
		for Key in pairs(Value) do
			local KeyKind = type(Key)
			if (KeyKind ~= "string" and KeyKind ~= "number") then
				error("cannot encode a " .. KeyKind .. " key", 0)
			end
			Keys[#Keys + 1] = Key
		end
		table.sort(Keys, KeyOrder)
		Out[#Out + 1] = "t"
		for _, Key in ipairs(Keys) do
			EncodeInto(Key, Out, Depth + 1)
			EncodeInto(Value[Key], Out, Depth + 1)
		end
		Out[#Out + 1] = "e"
	else
		error("cannot encode a " .. Kind, 0)
	end
end

function Codec.Encode(Value)
	local Out = {}
	EncodeInto(Value, Out, 0)
	return table.concat(Out)
end

-- Returns Value, NextIndex; errors on malformed input.
local function DecodeAt(Text, Index, Depth)
	local Tag = Text:sub(Index, Index)
	if (Tag == "n") then
		return nil, Index + 1
	elseif (Tag == "T") then
		return true, Index + 1
	elseif (Tag == "F") then
		return false, Index + 1
	elseif (Tag == "i" or Tag == "f") then
		local Finish = Text:find(";", Index + 1, true)
		if (not Finish or Finish - Index > 32) then error("bad number", 0) end
		local Number = tonumber(Text:sub(Index + 1, Finish - 1))
		if (not Number or Number ~= Number or Number == math.huge or Number == -math.huge) then error("bad number", 0) end
		return Number, Finish + 1
	elseif (Tag == "s") then
		local Colon = Text:find(":", Index + 1, true)
		if (not Colon or Colon - Index > 12) then error("bad string", 0) end
		local Length = tonumber(Text:sub(Index + 1, Colon - 1))
		if (not Length or Length < 0 or Colon + Length > #Text) then error("bad string", 0) end
		return Text:sub(Colon + 1, Colon + Length), Colon + Length + 1
	elseif (Tag == "t") then
		if (Depth >= Codec.MaxDepth) then error("table nested too deeply", 0) end
		local Result = {}
		Index = Index + 1
		while (Text:sub(Index, Index) ~= "e") do
			if (Index > #Text) then error("unterminated table", 0) end
			local Key, Value
			Key, Index = DecodeAt(Text, Index, Depth + 1)
			if (type(Key) ~= "string" and type(Key) ~= "number") then error("bad key", 0) end
			Value, Index = DecodeAt(Text, Index, Depth + 1)
			Result[Key] = Value
		end
		return Result, Index + 1
	end
	error("bad tag at " .. Index, 0)
end

-- Returns the decoded value, or nil and an error message.
function Codec.Decode(Text)
	if (type(Text) ~= "string") then return nil, "not a string" end
	local Ok, Value, Index = pcall(DecodeAt, Text, 1, 0)
	if (not Ok) then return nil, Value end
	if (Index ~= #Text + 1) then return nil, "trailing data" end
	return Value
end

function Codec.ToHex(Text)
	return (Text:gsub(".", function(Char) return string.format("%02x", Char:byte()) end))
end

function Codec.FromHex(Text)
	if (type(Text) ~= "string" or #Text % 2 ~= 0 or Text:find("[^%x]")) then return nil end
	return (Text:gsub("%x%x", function(Pair) return string.char(tonumber(Pair, 16)) end))
end

-- Adler-32 over Text, continuing from a previous checksum (1 for a fresh start).
function Codec.Adler32(Text, Previous)
	Previous = Previous or 1
	local A, B = Previous % 65536, math.floor(Previous / 65536)
	local Length = #Text
	for Start = 1, Length, 256 do
		local Bytes = { Text:byte(Start, math.min(Start + 255, Length)) }
		for Index = 1, #Bytes do
			A = A + Bytes[Index]
			B = B + A
		end
		A = A % 65521
		B = B % 65521
	end
	return B * 65536 + A
end

return Codec
