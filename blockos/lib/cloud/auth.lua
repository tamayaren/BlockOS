-- BlockCloud authentication primitives built on the BlockOS SHA-256 library:
-- random IDs and nonces, pairing codes, key derivation, HMAC signatures and optional
-- ChaCha20 encryption. See docs/BLOCKCLOUD.md for what these do and do not protect against.

local Sha256 = BlockOS.Require("sha256")
local Codec = BlockOS.Require("cloud/codec")
local Config = BlockOS.Require("config")

local Auth = {}

Auth.PoolPath = "/blockos/data/cloud/entropy.dat"
-- No 0/O, 1/I/L: codes are read off one screen and typed into another.
Auth.Alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
Auth.CodeLength = 8

local Pool = nil
local Counter = 0

-- Mixes whatever unpredictability CC: Tweaked offers into a persisted pool: wall-clock and CPU
-- time, the computer ID, Java identity hashes of fresh tables, math.random, and the previous pool.
function Auth.Stir(Extra)
	if (not Pool) then
		local Saved = Config.ReadText(Auth.PoolPath)
		Pool = (Saved and Codec.FromHex(Saved)) or ""
	end
	Counter = Counter + 1
	Pool = Sha256.Digest(table.concat({
		Pool, tostring(os.epoch and os.epoch("utc") or 0), tostring(os.clock()), tostring(os.getComputerID()),
		tostring({}), tostring({}), tostring(math.random(0, 2 ^ 30)), tostring(Counter), tostring(Extra or "")
	}, "|"))
end

local function SavePool()
	Config.WriteText(Auth.PoolPath, Codec.ToHex(Sha256.Hmac(Pool, "persist")))
end

function Auth.RandomBytes(Count)
	Auth.Stir()
	local Out = {}
	local Total = 0
	local Block = 0
	while (Total < Count) do
		Block = Block + 1
		local Bytes = Sha256.Hmac(Pool, "out|" .. Counter .. "|" .. Block)
		Out[#Out + 1] = Bytes
		Total = Total + #Bytes
	end
	if (Counter % 8 == 1) then SavePool() end
	return table.concat(Out):sub(1, Count)
end

function Auth.RandomHex(Bytes)
	return Codec.ToHex(Auth.RandomBytes(Bytes))
end

-- A fresh one-time pairing code such as "K7QM2X9D". Rejection sampling keeps it uniform.
function Auth.PairingCode()
	local Chars = {}
	while (#Chars < Auth.CodeLength) do
		for Byte in Auth.RandomBytes(16):gmatch(".") do
			local Value = Byte:byte()
			if (Value < 31 * 8 and #Chars < Auth.CodeLength) then
				local Index = Value % 31 + 1
				Chars[#Chars + 1] = Auth.Alphabet:sub(Index, Index)
			end
		end
	end
	return table.concat(Chars)
end

function Auth.FormatCode(Code)
	return Code:sub(1, 4) .. "-" .. Code:sub(5)
end

-- Accepts what an admin types: any case, with or without the dash or spaces.
function Auth.CleanCode(Text)
	return (tostring(Text or ""):upper():gsub("[^%w]", ""))
end

-- The pairing secret both sides compute from the code. The code itself never goes over the air.
function Auth.DeriveKey(Code, RequestID, ClientNonce, ServerNonce)
	return Sha256.Hmac(Code, "blockcloud-pair|" .. RequestID .. "|" .. ClientNonce .. "|" .. ServerNonce)
end

-- Lets the server tell a mistyped code from the right one when the admin approves.
function Auth.CodeCheck(Code, ClientNonce)
	return Codec.ToHex(Sha256.Hmac(Code, "blockcloud-check|" .. ClientNonce))
end

-- Proof sent with an approval, so the client knows the real server (holding the code) approved it.
function Auth.ApprovalProof(Key, RequestID, ClientID, Permission)
	return Codec.ToHex(Sha256.Hmac(Key, "approved|" .. RequestID .. "|" .. ClientID .. "|" .. Permission))
end

local KeyCache = {}

-- Separate signing and encryption keys derived from one pairing key (raw bytes or hex).
function Auth.Keys(Master)
	if (#Master == 64 and not Master:find("[^%x]")) then Master = Codec.FromHex(Master) end
	local Cached = KeyCache[Master]
	if (Cached) then return Cached end
	local Keys = { Mac = Sha256.Hmac(Master, "blockcloud-mac"), Enc = Sha256.Hmac(Master, "blockcloud-enc") }
	KeyCache[Master] = Keys
	return Keys
end

function Auth.Sign(Keys, Text)
	return Codec.ToHex(Sha256.Hmac(Keys.Mac, Text):sub(1, 16))
end

function Auth.Verify(Keys, Text, Signature)
	if (type(Signature) ~= "string" or #Signature ~= 32) then return false end
	local Expected = Auth.Sign(Keys, Text)
	local Diff = 0
	for Index = 1, 32 do
		if (Expected:byte(Index) ~= Signature:byte(Index)) then Diff = Diff + 1 end
	end
	return Diff == 0
end

local Bxor, Band, Rshift, Lrotate = bit32.bxor, bit32.band, bit32.rshift, bit32.lrotate

local function Words(Bytes, Count)
	local Result = {}
	for Index = 1, Count do
		local A, B, C, D = Bytes:byte(Index * 4 - 3, Index * 4)
		Result[Index] = A + B * 256 + C * 65536 + D * 16777216
	end
	return Result
end

local function Quarter(S, A, B, C, D)
	S[A] = (S[A] + S[B]) % 4294967296; S[D] = Lrotate(Bxor(S[D], S[A]), 16)
	S[C] = (S[C] + S[D]) % 4294967296; S[B] = Lrotate(Bxor(S[B], S[C]), 12)
	S[A] = (S[A] + S[B]) % 4294967296; S[D] = Lrotate(Bxor(S[D], S[A]), 8)
	S[C] = (S[C] + S[D]) % 4294967296; S[B] = Lrotate(Bxor(S[B], S[C]), 7)
end

-- ChaCha20 (RFC 7539) with a 32-byte key and 12-byte nonce, starting at block Counter.
-- XORs Text with the keystream, so the same call encrypts and decrypts.
function Auth.ChaCha20(Key, Nonce, Counter, Text)
	local K, N = Words(Key, 8), Words(Nonce, 3)
	local Out = {}
	local Length = #Text
	local Block = 0
	local State, Work = {}, {}
	for Start = 1, Length, 64 do
		State[1], State[2], State[3], State[4] = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
		for Index = 1, 8 do State[Index + 4] = K[Index] end
		State[13] = (Counter + Block) % 4294967296
		State[14], State[15], State[16] = N[1], N[2], N[3]
		for Index = 1, 16 do Work[Index] = State[Index] end
		for _ = 1, 10 do
			Quarter(Work, 1, 5, 9, 13)
			Quarter(Work, 2, 6, 10, 14)
			Quarter(Work, 3, 7, 11, 15)
			Quarter(Work, 4, 8, 12, 16)
			Quarter(Work, 1, 6, 11, 16)
			Quarter(Work, 2, 7, 12, 13)
			Quarter(Work, 3, 8, 9, 14)
			Quarter(Work, 4, 5, 10, 15)
		end
		local Plain = { Text:byte(Start, math.min(Start + 63, Length)) }
		local Chars = {}
		local Position = 1
		for Index = 1, 16 do
			local Word = (Work[Index] + State[Index]) % 4294967296
			for _ = 1, 4 do
				local Byte = Plain[Position]
				if (not Byte) then break end
				Chars[Position] = Bxor(Byte, Band(Word, 255))
				Word = Rshift(Word, 8)
				Position = Position + 1
			end
		end
		Block = Block + 1
		Out[Block] = string.char(table.unpack(Chars))
	end
	return table.concat(Out)
end

-- Encrypts or decrypts a message body. Nonce is any string unique to the message.
function Auth.Crypt(Key, Nonce, Text)
	return Auth.ChaCha20(Key, Sha256.Digest(Nonce):sub(1, 12), 1, Text)
end

function Auth.HashPassword(Password, Salt)
	return Sha256.Hex("blockcloud-admin|" .. Salt .. "|" .. Password)
end

return Auth
