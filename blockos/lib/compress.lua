-- Lossless compression for system files and installed apps (DEFLATE: LZ77 with Huffman codes).
-- Packed files start with Compress.Magic and are unpacked whenever something opens them to read,
-- so programs, the shell and the editor all see the original text. This file must stay unpacked.

local Compress = {}

Compress.Magic = "\27BLZ\1"
Compress.Enabled = true
-- Files this small already sit at the 500 bytes CC charges for any file.
Compress.MinSize = 512

local MagicSize = #Compress.Magic
local HeaderSize = MagicSize + 4
local Window = 32768
local MaxChain = 48
local LazyBelow = 32

local Byte, Char, Unpack = string.byte, string.char, table.unpack or unpack
local Floor, Min = math.floor, math.min

local Dirs = { apps = true, lib = true, sys = true, bin = true, userapps = true }
local Extensions = { lua = true, cfg = true, txt = true }
local AlwaysRaw = { ["blockos/lib/compress.lua"] = true }

local LenBase = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LenExtra = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DistBase = { [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DistExtra = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local LengthOrder = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--
-- Unpacking
--

-- Canonical Huffman table for Lengths[0 .. Count - 1]: how many codes of each length, and the symbols in code order.
local function BuildTree(Lengths, Count)
	local Counts, Offsets, Symbols = {}, {}, {}
	for Length = 0, 15 do
		Counts[Length] = 0
	end
	for Symbol = 0, Count - 1 do
		Counts[Lengths[Symbol]] = Counts[Lengths[Symbol]] + 1
	end
	Counts[0] = 0
	Offsets[1] = 0
	for Length = 1, 14 do
		Offsets[Length + 1] = Offsets[Length] + Counts[Length]
	end
	for Symbol = 0, Count - 1 do
		local Length = Lengths[Symbol]
		if (Length ~= 0) then
			Symbols[Offsets[Length]] = Symbol
			Offsets[Length] = Offsets[Length] + 1
		end
	end
	return { Counts, Symbols }
end

local FixedLit, FixedDist

local function FixedTrees()
	if (not FixedLit) then
		local Lengths = {}
		for Symbol = 0, 287 do
			Lengths[Symbol] = (Symbol < 144 and 8) or (Symbol < 256 and 9) or (Symbol < 280 and 7) or 8
		end
		FixedLit = BuildTree(Lengths, 288)
		for Symbol = 0, 29 do
			Lengths[Symbol] = 5
		end
		FixedDist = BuildTree(Lengths, 30)
	end
	return FixedLit, FixedDist
end

local function Inflate(Data, Pos)
	local Buffer, Held = 0, 0
	local Out, Size = {}, 0

	local function Bits(Need)
		while (Held < Need) do
			local Value = Byte(Data, Pos)
			if (not Value) then error("Compressed data ends early", 0) end
			Pos = Pos + 1
			Buffer = Buffer + Value * 2 ^ Held
			Held = Held + 8
		end
		local Scale = 2 ^ Need
		local Value = Buffer % Scale
		Buffer = (Buffer - Value) / Scale
		Held = Held - Need
		return Value
	end

	local function Decode(Tree)
		local Counts, Symbols = Tree[1], Tree[2]
		local Code, First, Index = 0, 0, 0
		for Length = 1, 15 do
			if (Held == 0) then
				Buffer = Byte(Data, Pos)
				if (not Buffer) then error("Compressed data ends early", 0) end
				Pos = Pos + 1
				Held = 8
			end
			local Bit = Buffer % 2
			Buffer = (Buffer - Bit) / 2
			Held = Held - 1
			Code = Code + Bit
			local Count = Counts[Length]
			if (Code - Count < First) then
				return Symbols[Index + Code - First]
			end
			Index = Index + Count
			First = (First + Count) * 2
			Code = Code * 2
		end
		error("Compressed data is damaged", 0)
	end

	local function DynamicTrees()
		local LitCount, DistCount, OrderCount = Bits(5) + 257, Bits(5) + 1, Bits(4) + 4
		local Lengths = {}
		for Symbol = 0, 18 do
			Lengths[Symbol] = 0
		end
		for Index = 1, OrderCount do
			Lengths[LengthOrder[Index]] = Bits(3)
		end
		local Order = BuildTree(Lengths, 19)
		Lengths = {}
		local Index = 0
		while (Index < LitCount + DistCount) do
			local Symbol = Decode(Order)
			if (Symbol < 16) then
				Lengths[Index] = Symbol
				Index = Index + 1
			else
				local Value, Repeat = 0, 0
				if (Symbol == 16) then
					if (Index == 0) then error("Compressed data is damaged", 0) end
					Value, Repeat = Lengths[Index - 1], Bits(2) + 3
				elseif (Symbol == 17) then
					Repeat = Bits(3) + 3
				else
					Repeat = Bits(7) + 11
				end
				if (Index + Repeat > LitCount + DistCount) then error("Compressed data is damaged", 0) end
				for _ = 1, Repeat do
					Lengths[Index] = Value
					Index = Index + 1
				end
			end
		end
		local DistLengths = {}
		for Symbol = 0, DistCount - 1 do
			DistLengths[Symbol] = Lengths[LitCount + Symbol]
		end
		return BuildTree(Lengths, LitCount), BuildTree(DistLengths, DistCount)
	end

	local Final
	repeat
		Final = Bits(1)
		local Kind = Bits(2)
		if (Kind == 0) then
			Buffer, Held = 0, 0
			local Length = Byte(Data, Pos) + Byte(Data, Pos + 1) * 256
			Pos = Pos + 4
			for Index = Pos, Pos + Length - 1 do
				Size = Size + 1
				Out[Size] = Byte(Data, Index)
			end
			Pos = Pos + Length
		elseif (Kind == 3) then
			error("Compressed data is damaged", 0)
		else
			local Lit, Dist
			if (Kind == 1) then
				Lit, Dist = FixedTrees()
			else
				Lit, Dist = DynamicTrees()
			end
			while (true) do
				local Symbol = Decode(Lit)
				if (Symbol < 256) then
					Size = Size + 1
					Out[Size] = Symbol
				elseif (Symbol == 256) then
					break
				else
					Symbol = Symbol - 257
					local Length = LenBase[Symbol] + Bits(LenExtra[Symbol])
					Symbol = Decode(Dist)
					local From = Size - (DistBase[Symbol] + Bits(DistExtra[Symbol]))
					if (From < 0) then error("Compressed data is damaged", 0) end
					for Index = 1, Length do
						Out[Size + Index] = Out[From + Index]
					end
					Size = Size + Length
				end
			end
		end
	until (Final == 1)

	local Parts = {}
	for Index = 1, Size, 1024 do
		Parts[#Parts + 1] = Char(Unpack(Out, Index, Min(Index + 1023, Size)))
	end
	return table.concat(Parts)
end

--
-- Packing
--

local LenCode, DistCode

-- Symbol lookups: LenCode[3 .. 258], DistCode[1 .. 256] for near distances and [257 .. 512] by (Distance - 1) / 128.
local function CodeTables()
	if (LenCode) then return end
	LenCode, DistCode = {}, {}
	for Code = 0, 28 do
		for Length = LenBase[Code], (Code == 28 and 258) or (LenBase[Code + 1] - 1) do
			LenCode[Length] = Code
		end
	end
	LenCode[258] = 28
	for Code = 0, 29 do
		for Distance = DistBase[Code], (Code == 29 and Window) or (DistBase[Code + 1] - 1) do
			if (Distance <= 256) then
				DistCode[Distance] = Code
			elseif ((Distance - 1) % 128 == 0) then
				DistCode[257 + (Distance - 1) / 128] = Code
			end
		end
	end
end

-- Code lengths for Freq[0 .. Count - 1], none longer than MaxBits.
local function CodeLengths(Freq, Count, MaxBits)
	local Lengths = {}
	local Leaves = {}
	for Symbol = 0, Count - 1 do
		Lengths[Symbol] = 0
		if (Freq[Symbol] > 0) then
			Leaves[#Leaves + 1] = Symbol
		end
	end
	if (#Leaves == 0) then return Lengths end
	if (#Leaves == 1) then
		Lengths[Leaves[1]] = 1
		return Lengths
	end
	local Weights = {}
	for _, Symbol in ipairs(Leaves) do
		Weights[Symbol] = Freq[Symbol]
	end
	while (true) do
		table.sort(Leaves, function(A, B)
			if (Weights[A] ~= Weights[B]) then return Weights[A] < Weights[B] end
			return A < B
		end)
		-- Nodes 1 .. #Leaves are the sorted leaves; merged nodes follow, already in weight order.
		local Total = #Leaves
		local Weight, Parent = {}, {}
		for Index, Symbol in ipairs(Leaves) do
			Weight[Index] = Weights[Symbol]
		end
		local Leaf, Merged, Next = 1, Total + 1, Total + 1
		local function Take()
			if (Leaf <= Total and (Merged >= Next or Weight[Leaf] <= Weight[Merged])) then
				Leaf = Leaf + 1
				return Leaf - 1
			end
			Merged = Merged + 1
			return Merged - 1
		end
		for _ = 1, Total - 1 do
			local A = Take()
			local B = Take()
			Weight[Next] = Weight[A] + Weight[B]
			Parent[A], Parent[B] = Next, Next
			Next = Next + 1
		end
		local Depth = { [Next - 1] = 0 }
		local Deepest = 0
		for Node = Next - 2, 1, -1 do
			Depth[Node] = Depth[Parent[Node]] + 1
			if (Node <= Total and Depth[Node] > Deepest) then Deepest = Depth[Node] end
		end
		if (Deepest <= MaxBits) then
			for Index, Symbol in ipairs(Leaves) do
				Lengths[Symbol] = Depth[Index]
			end
			return Lengths
		end
		-- Too deep: flatten the weights and try again.
		for _, Symbol in ipairs(Leaves) do
			Weights[Symbol] = Floor((Weights[Symbol] + 1) / 2)
		end
	end
end

-- Canonical codes for Lengths, bit-reversed so they can be written low bit first.
local function Codes(Lengths, Count)
	local Counts, Next, Result = {}, {}, {}
	for Length = 0, 15 do
		Counts[Length] = 0
	end
	for Symbol = 0, Count - 1 do
		Counts[Lengths[Symbol]] = Counts[Lengths[Symbol]] + 1
	end
	Counts[0] = 0
	local Code = 0
	for Length = 1, 15 do
		Code = (Code + Counts[Length - 1]) * 2
		Next[Length] = Code
	end
	for Symbol = 0, Count - 1 do
		local Length = Lengths[Symbol]
		if (Length ~= 0) then
			local Value, Reversed = Next[Length], 0
			Next[Length] = Value + 1
			for _ = 1, Length do
				Reversed = Reversed * 2 + Value % 2
				Value = Floor(Value / 2)
			end
			Result[Symbol] = Reversed
		end
	end
	return Result
end

local function Deflate(Data)
	CodeTables()
	local Size = #Data
	local Bytes = {}
	for Index = 1, Size do
		Bytes[Index] = Byte(Data, Index)
	end

	-- LZ77: Tokens holds a literal byte or a match length, Distances 0 or the match distance.
	local Head, Prev = {}, {}
	local Tokens, Distances, Count = {}, {}, 0
	local LitFreq, DistFreq = {}, {}
	for Symbol = 0, 285 do
		LitFreq[Symbol] = 0
	end
	for Symbol = 0, 29 do
		DistFreq[Symbol] = 0
	end
	LitFreq[256] = 1

	local function Longest(Pos)
		local Candidate = Head[Bytes[Pos] * 65536 + Bytes[Pos + 1] * 256 + Bytes[Pos + 2]]
		local Best, BestDistance = 2, 0
		local Limit = Min(258, Size - Pos + 1)
		local Chain = MaxChain
		while (Candidate and Chain > 0 and Pos - Candidate <= Window) do
			if (Bytes[Candidate + Best] == Bytes[Pos + Best]) then
				local Length = 3
				while (Length < Limit and Bytes[Candidate + Length] == Bytes[Pos + Length]) do
					Length = Length + 1
				end
				if (Length > Best) then
					Best, BestDistance = Length, Pos - Candidate
					if (Length >= Limit) then break end
				end
			end
			Candidate = Prev[Candidate]
			Chain = Chain - 1
		end
		-- A far three-byte match costs more than three literals.
		if (Best == 3 and BestDistance > 4096) then Best = 2 end
		return Best, BestDistance
	end

	local Pos, Length, Distance, Pending = 1, 2, 0, false
	while (Pos <= Size) do
		if (not Pending) then
			Length = 2
			if (Pos + 2 <= Size) then Length, Distance = Longest(Pos) end
		end
		Pending = false
		if (Pos + 2 <= Size) then
			local Key = Bytes[Pos] * 65536 + Bytes[Pos + 1] * 256 + Bytes[Pos + 2]
			Prev[Pos] = Head[Key]
			Head[Key] = Pos
		end
		local NextLength, NextDistance = 2, 0
		if (Length >= 3 and Length < LazyBelow and Pos + 3 <= Size) then
			NextLength, NextDistance = Longest(Pos + 1)
		end
		Count = Count + 1
		if (Length < 3 or NextLength > Length) then
			-- A literal, also when the match starting one byte later is longer.
			local Value = Bytes[Pos]
			Tokens[Count], Distances[Count] = Value, 0
			LitFreq[Value] = LitFreq[Value] + 1
			Pos = Pos + 1
			if (NextLength > Length) then
				Length, Distance, Pending = NextLength, NextDistance, true
			end
		else
			Tokens[Count], Distances[Count] = Length, Distance
			local Code = LenCode[Length] + 257
			LitFreq[Code] = LitFreq[Code] + 1
			Code = (Distance <= 256) and DistCode[Distance] or DistCode[257 + Floor((Distance - 1) / 128)]
			DistFreq[Code] = DistFreq[Code] + 1
			for Index = Pos + 1, Min(Pos + Length - 1, Size - 2) do
				local Key = Bytes[Index] * 65536 + Bytes[Index + 1] * 256 + Bytes[Index + 2]
				Prev[Index] = Head[Key]
				Head[Key] = Index
			end
			Pos = Pos + Length
		end
	end

	local LitLengths = CodeLengths(LitFreq, 286, 15)
	local DistLengths = CodeLengths(DistFreq, 30, 15)
	local LitCodes, DistCodes = Codes(LitLengths, 286), Codes(DistLengths, 30)
	local LitCount, DistCount = 286, 30
	while (LitCount > 257 and LitLengths[LitCount - 1] == 0) do
		LitCount = LitCount - 1
	end
	while (DistCount > 1 and DistLengths[DistCount - 1] == 0) do
		DistCount = DistCount - 1
	end

	-- Run-length codes for the two length tables: Runs holds a symbol, ExtraBits and Extras its extra bits.
	local All = {}
	for Symbol = 0, LitCount - 1 do
		All[#All + 1] = LitLengths[Symbol]
	end
	for Symbol = 0, DistCount - 1 do
		All[#All + 1] = DistLengths[Symbol]
	end
	local Runs, ExtraBits, Extras = {}, {}, {}
	local OrderFreq = {}
	for Symbol = 0, 18 do
		OrderFreq[Symbol] = 0
	end
	local function Run(Symbol, Bits, Extra)
		Runs[#Runs + 1] = Symbol
		ExtraBits[#Runs], Extras[#Runs] = Bits, Extra
		OrderFreq[Symbol] = OrderFreq[Symbol] + 1
	end
	local Index = 1
	while (Index <= #All) do
		local Value = All[Index]
		local Repeat = 1
		while (All[Index + Repeat] == Value) do
			Repeat = Repeat + 1
		end
		Index = Index + Repeat
		if (Value == 0) then
			while (Repeat >= 11) do
				local Step = Min(Repeat, 138)
				Run(18, 7, Step - 11)
				Repeat = Repeat - Step
			end
			if (Repeat >= 3) then
				Run(17, 3, Repeat - 3)
				Repeat = 0
			end
		else
			Run(Value, 0, 0)
			Repeat = Repeat - 1
			while (Repeat >= 3) do
				local Step = Min(Repeat, 6)
				Run(16, 2, Step - 3)
				Repeat = Repeat - Step
			end
		end
		for _ = 1, Repeat do
			Run(Value, 0, 0)
		end
	end
	local OrderLengths = CodeLengths(OrderFreq, 19, 7)
	local OrderCodes = Codes(OrderLengths, 19)
	local OrderCount = 19
	while (OrderCount > 4 and OrderLengths[LengthOrder[OrderCount]] == 0) do
		OrderCount = OrderCount - 1
	end

	local Out, Written = {}, 0
	local Buffer, Held = 0, 0
	local function Put(Value, Bits)
		Buffer = Buffer + Value * 2 ^ Held
		Held = Held + Bits
		while (Held >= 8) do
			local Low = Buffer % 256
			Written = Written + 1
			Out[Written] = Low
			Buffer = (Buffer - Low) / 256
			Held = Held - 8
		end
	end

	Put(1, 1)
	Put(2, 2)
	Put(LitCount - 257, 5)
	Put(DistCount - 1, 5)
	Put(OrderCount - 4, 4)
	for Position = 1, OrderCount do
		Put(OrderLengths[LengthOrder[Position]], 3)
	end
	for Position = 1, #Runs do
		local Symbol = Runs[Position]
		Put(OrderCodes[Symbol], OrderLengths[Symbol])
		if (ExtraBits[Position] > 0) then Put(Extras[Position], ExtraBits[Position]) end
	end
	for Position = 1, Count do
		local Value, Far = Tokens[Position], Distances[Position]
		if (Far == 0) then
			Put(LitCodes[Value], LitLengths[Value])
		else
			local Code = LenCode[Value]
			Put(LitCodes[Code + 257], LitLengths[Code + 257])
			if (LenExtra[Code] > 0) then Put(Value - LenBase[Code], LenExtra[Code]) end
			Code = (Far <= 256) and DistCode[Far] or DistCode[257 + Floor((Far - 1) / 128)]
			Put(DistCodes[Code], DistLengths[Code])
			if (DistExtra[Code] > 0) then Put(Far - DistBase[Code], DistExtra[Code]) end
		end
	end
	Put(LitCodes[256], LitLengths[256])
	if (Held > 0) then Put(0, 8 - Held) end

	local Parts = {}
	for Position = 1, Written, 1024 do
		Parts[#Parts + 1] = Char(Unpack(Out, Position, Min(Position + 1023, Written)))
	end
	return table.concat(Parts)
end

Compress.Deflate = Deflate
Compress.Inflate = function(Data) return Inflate(Data, 1) end

function Compress.IsPacked(Data)
	return type(Data) == "string" and Data:sub(1, MagicSize) == Compress.Magic
end

-- The packed form of Text, or nil when packing would not make it smaller.
function Compress.Pack(Text)
	if (#Text < Compress.MinSize or #Text >= 2 ^ 32) then return nil end
	local Ok, Body = pcall(Deflate, Text)
	if (not Ok or HeaderSize + #Body >= #Text) then return nil end
	local Size = #Text
	local Packed = Compress.Magic .. Char(Size % 256, Floor(Size / 256) % 256, Floor(Size / 65536) % 256, Floor(Size / 16777216)) .. Body
	-- Never hand back something that does not unpack to exactly the original.
	local Same, Back = pcall(Compress.Unpack, Packed)
	if (not Same or Back ~= Text) then return nil end
	return Packed
end

-- The original text of packed Data; anything else comes back unchanged.
function Compress.Unpack(Data)
	if (not Compress.IsPacked(Data)) then return Data end
	local A, B, C, D = Byte(Data, MagicSize + 1, HeaderSize)
	local Text = Inflate(Data, HeaderSize + 1)
	if (not D or #Text ~= A + B * 256 + C * 65536 + D * 16777216) then
		error("Compressed data is damaged", 0)
	end
	return Text
end

--
-- Files
--

local function RawOpen(Path, Mode)
	return (rawget(fs, "BlockOSRawOpen") or fs.open)(Path, Mode)
end

local function ReadRaw(Path)
	local Handle = RawOpen(Path, "rb")
	if (not Handle) then return nil end
	local Data = Handle.readAll() or ""
	Handle.close()
	return Data
end

local function WriteRaw(Path, Data, Mode)
	local Handle = RawOpen(Path, Mode)
	if (not Handle) then return false end
	Handle.write(Data)
	Handle.close()
	return true
end

-- Whether the file at Path is stored packed.
function Compress.IsPackedFile(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return false end
	local Handle = RawOpen(Path, "rb")
	if (not Handle) then return false end
	local Start = Handle.read(MagicSize)
	Handle.close()
	return Start == Compress.Magic
end

-- System files and apps are packed; boot files, user data and anything else are left alone.
function Compress.Eligible(Path)
	local Clean = fs.combine(Path, "")
	local Top = Clean:match("^blockos/([^/]+)/")
	if (not Top or not Dirs[Top] or AlwaysRaw[Clean]) then return false end
	return Extensions[Clean:match("%.(%w+)$") or ""] == true
end

-- Reads a whole file, unpacking it when needed.
function Compress.Read(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil end
	local Data = ReadRaw(Path)
	if (not Data) then return nil end
	return Compress.Unpack(Data)
end

-- Writes Text to Path, packed when compression is on and As (the file's final path, default Path) is eligible.
function Compress.Write(Path, Text, As)
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then
		fs.makeDir(Dir)
	end
	local Packed = Compress.Enabled and Compress.Eligible(As or Path) and Compress.Pack(Text)
	if (Packed) then return WriteRaw(Path, Packed, "wb") end
	return WriteRaw(Path, Text, "w")
end

-- Swaps new contents in through a temporary file, so a crash never leaves half a file behind.
local function Replace(Path, Data)
	local Temp = Path .. ".tmp"
	if (fs.exists(Temp)) then fs.delete(Temp) end
	if (fs.getFreeSpace(Path) > #Data + 1024 and WriteRaw(Temp, Data, "wb")) then
		fs.delete(Path)
		fs.move(Temp, Path)
		return true
	end
	if (fs.exists(Temp)) then fs.delete(Temp) end
	return false
end

local function Walk(Dir, Into)
	if (not fs.isDir(Dir)) then return Into end
	for _, Name in ipairs(fs.list(Dir)) do
		local Path = fs.combine(Dir, Name)
		if (fs.isDir(Path)) then
			Walk(Path, Into)
		elseif (Compress.Eligible(Path)) then
			Into[#Into + 1] = Path
		end
	end
	return Into
end

local function EachFile(OnProgress, Visit)
	local Files = {}
	for Name in pairs(Dirs) do
		Walk(fs.combine("blockos", Name), Files)
	end
	table.sort(Files)
	local Changed, Saved = 0, 0
	for Index, Path in ipairs(Files) do
		if (OnProgress) then OnProgress(Index - 1, #Files, Path) end
		local Before = fs.getSize(Path)
		if (Visit(Path, Before)) then
			Changed = Changed + 1
			Saved = Saved + Before - fs.getSize(Path)
			-- Packing is slow enough that a long run has to yield between files.
			sleep(0)
		end
	end
	if (OnProgress) then OnProgress(#Files, #Files, "") end
	return Changed, Saved
end

-- Packs every eligible file that is not packed yet. Returns how many changed and the bytes saved.
function Compress.Compact(OnProgress)
	return EachFile(OnProgress, function(Path, Size)
		if (Size < Compress.MinSize or Compress.IsPackedFile(Path)) then return false end
		local Text = ReadRaw(Path)
		local Packed = Text and Compress.Pack(Text)
		return Packed and Replace(Path, Packed) or false
	end)
end

-- Unpacks every packed file, as long as there is room for it. Saved comes back negative.
function Compress.Expand(OnProgress)
	return EachFile(OnProgress, function(Path)
		if (not Compress.IsPackedFile(Path)) then return false end
		local Ok, Text = pcall(Compress.Read, Path)
		return Ok and Text and Replace(Path, Text) or false
	end)
end

-- Bytes on disk and bytes unpacked for everything Compact looks after.
function Compress.Usage()
	local Stored, Original = 0, 0
	EachFile(nil, function(Path, Size)
		Stored = Stored + Size
		if (Compress.IsPackedFile(Path)) then
			local Handle = RawOpen(Path, "rb")
			Handle.read(MagicSize)
			local A, B, C, D = Byte(Handle.read(4) or "", 1, 4)
			Handle.close()
			Size = D and (A + B * 256 + C * 65536 + D * 16777216) or Size
		end
		Original = Original + Size
		return false
	end)
	return Stored, Original
end

--
-- Transparent reads
--

-- A read handle over text already in memory, shaped like the ones fs.open returns.
local function TextHandle(Text, Binary)
	local Pos, Closed = 1, false
	local Handle = {}
	local function Check()
		if (Closed) then error("attempt to use a closed file", 3) end
	end
	function Handle.read(Count)
		Check()
		if (Pos > #Text) then return nil end
		if (Count == nil) then
			Pos = Pos + 1
			if (Binary) then return Byte(Text, Pos - 1) end
			return Text:sub(Pos - 1, Pos - 1)
		end
		local Part = Text:sub(Pos, Pos + Count - 1)
		Pos = Pos + #Part
		return Part
	end
	function Handle.readLine(WithTrailing)
		Check()
		if (Pos > #Text) then return nil end
		local Stop = Text:find("\n", Pos, true)
		local Line = Text:sub(Pos, (Stop or #Text + 1) - (WithTrailing and 0 or 1))
		Pos = (Stop or #Text) + 1
		return Line
	end
	function Handle.readAll()
		Check()
		if (Pos > #Text and #Text > 0) then return nil end
		local Rest = Text:sub(Pos)
		Pos = #Text + 1
		return Rest
	end
	function Handle.seek(Whence, Offset)
		Check()
		Whence, Offset = Whence or "cur", Offset or 0
		local Target
		if (Whence == "set") then
			Target = Offset
		elseif (Whence == "cur") then
			Target = Pos - 1 + Offset
		elseif (Whence == "end") then
			Target = #Text + Offset
		else
			error("bad argument #1 to 'seek' (invalid option '" .. tostring(Whence) .. "')", 2)
		end
		if (Target < 0) then return nil, "Position is negative" end
		Pos = Target + 1
		return Target
	end
	function Handle.close()
		Check()
		Closed = true
	end
	return Handle
end

-- Makes fs.open unpack packed files: reads see the original text, and a file opened to append or
-- update is unpacked on disk first. Writes go straight through, so an edited file is saved as-is.
function Compress.Hook()
	if (rawget(fs, "BlockOSRawOpen")) then return end
	local Open = fs.open
	rawset(fs, "BlockOSRawOpen", Open)
	fs.open = function(Path, Mode, ...)
		if (type(Path) ~= "string" or type(Mode) ~= "string" or Mode:sub(1, 1) == "w") then
			return Open(Path, Mode, ...)
		end
		local Clean = fs.combine(Path, "")
		if (Clean:sub(1, 4) == "rom/" or not fs.exists(Clean) or fs.isDir(Clean) or not Compress.IsPackedFile(Clean)) then
			return Open(Path, Mode, ...)
		end
		local Ok, Text = pcall(Compress.Read, Clean)
		if (not Ok) then return nil, "/" .. Clean .. ": " .. tostring(Text) end
		if (Mode == "r" or Mode == "rb") then
			return TextHandle(Text, Mode == "rb")
		end
		if (not Replace(Clean, Text)) then return nil, "/" .. Clean .. ": Out of space" end
		return Open(Path, Mode, ...)
	end
end

return Compress
