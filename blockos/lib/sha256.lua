-- Pure Lua SHA-256 using the bit32 library available in CC: Tweaked.

local Band, Bor, Bxor, Bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local Rrotate, Rshift = bit32.rrotate, bit32.rshift

local Sha256 = {}

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function Preprocess(Message)
	local Length = #Message
	local Extra = 64 - ((Length + 9) % 64)
	if (Extra == 64) then Extra = 0 end
	local Bits = Length * 8
	local Suffix = {}
	for Index = 7, 0, -1 do
		Suffix[#Suffix + 1] = string.char(math.floor(Bits / 2 ^ (Index * 8)) % 256)
	end
	return Message .. "\128" .. string.rep("\0", Extra) .. table.concat(Suffix)
end

local function DigestBlock(Message, Start, Hash)
	local W = {}
	for Index = 0, 15 do
		local A, B, C, D = Message:byte(Start + Index * 4, Start + Index * 4 + 3)
		W[Index] = ((A * 256 + B) * 256 + C) * 256 + D
	end
	for Index = 16, 63 do
		local V0 = W[Index - 15]
		local S0 = Bxor(Rrotate(V0, 7), Rrotate(V0, 18), Rshift(V0, 3))
		local V1 = W[Index - 2]
		local S1 = Bxor(Rrotate(V1, 17), Rrotate(V1, 19), Rshift(V1, 10))
		W[Index] = Band(W[Index - 16] + S0 + W[Index - 7] + S1, 0xffffffff)
	end
	local A, B, C, D, E, F, G, H = Hash[1], Hash[2], Hash[3], Hash[4], Hash[5], Hash[6], Hash[7], Hash[8]
	for Index = 0, 63 do
		local S1 = Bxor(Rrotate(E, 6), Rrotate(E, 11), Rrotate(E, 25))
		local Ch = Bxor(Band(E, F), Band(Bnot(E), G))
		local Temp1 = H + S1 + Ch + K[Index + 1] + W[Index]
		local S0 = Bxor(Rrotate(A, 2), Rrotate(A, 13), Rrotate(A, 22))
		local Maj = Bxor(Band(A, B), Band(A, C), Band(B, C))
		local Temp2 = S0 + Maj
		H = G
		G = F
		F = E
		E = Band(D + Temp1, 0xffffffff)
		D = C
		C = B
		B = A
		A = Band(Temp1 + Temp2, 0xffffffff)
	end
	Hash[1] = Band(Hash[1] + A, 0xffffffff)
	Hash[2] = Band(Hash[2] + B, 0xffffffff)
	Hash[3] = Band(Hash[3] + C, 0xffffffff)
	Hash[4] = Band(Hash[4] + D, 0xffffffff)
	Hash[5] = Band(Hash[5] + E, 0xffffffff)
	Hash[6] = Band(Hash[6] + F, 0xffffffff)
	Hash[7] = Band(Hash[7] + G, 0xffffffff)
	Hash[8] = Band(Hash[8] + H, 0xffffffff)
end

-- Returns the raw 32-byte digest.
function Sha256.Digest(Message)
	Message = Preprocess(tostring(Message))
	local Hash = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	}
	for Start = 1, #Message, 64 do
		DigestBlock(Message, Start, Hash)
	end
	local Bytes = {}
	for Index = 1, 8 do
		local Value = Hash[Index]
		Bytes[#Bytes + 1] = string.char(
			math.floor(Value / 16777216) % 256,
			math.floor(Value / 65536) % 256,
			math.floor(Value / 256) % 256,
			Value % 256
		)
	end
	return table.concat(Bytes)
end

function Sha256.Hex(Message)
	return (Sha256.Digest(Message):gsub(".", function(Char)
		return string.format("%02x", Char:byte())
	end))
end

function Sha256.Hmac(Key, Message)
	if (#Key > 64) then Key = Sha256.Digest(Key) end
	Key = Key .. string.rep("\0", 64 - #Key)
	local Inner = Key:gsub(".", function(Char) return string.char(Bxor(Char:byte(), 0x36)) end)
	local Outer = Key:gsub(".", function(Char) return string.char(Bxor(Char:byte(), 0x5c)) end)
	return Sha256.Digest(Outer .. Sha256.Digest(Inner .. Message))
end

return Sha256
