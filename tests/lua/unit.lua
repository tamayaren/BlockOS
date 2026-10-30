-- Unit tests for the shared BlockCloud libraries, run inside CC: Tweaked.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Codec = BlockOS.Require("cloud/codec")
	local Path = BlockOS.Require("cloud/path")
	local Auth = BlockOS.Require("cloud/auth")
	local Protocol = BlockOS.Require("cloud/protocol")

	-- Codec
	local Value = { 1, 2.5, -3, "x", true, false, Nested = { A = "b", [10] = "ten", Deep = { {} } }, Binary = "\0\1\255\n" }
	local Encoded = Codec.Encode(Value)
	local Decoded = Codec.Decode(Encoded)
	T.Check("codec round trip", Codec.Encode(Decoded) == Encoded and Decoded.Binary == "\0\1\255\n" and Decoded.Nested[10] == "ten" and Decoded[2] == 2.5)
	T.Check("codec is canonical", Codec.Encode({ B = 1, A = 2, [3] = 3 }) == Codec.Encode({ [3] = 3, A = 2, B = 1 }))
	local Bad = 0
	for _, Text in ipairs({ "", "x", "s5:ab", "t", "ti1;", "i;", "s-1:", "tF", "TT", "s99999999999:", "f1e400;", ("t"):rep(40) }) do
		if (Codec.Decode(Text) == nil) then Bad = Bad + 1 end
	end
	T.Check("codec rejects malformed input", Bad == 12, Bad)
	T.Check("codec refuses functions", not pcall(Codec.Encode, { print }))
	T.Check("adler32 known value", Codec.Adler32("Wikipedia") == 300286872, Codec.Adler32("Wikipedia"))
	T.Check("adler32 incremental", Codec.Adler32("pedia", Codec.Adler32("Wiki")) == Codec.Adler32("Wikipedia"))
	T.Check("hex round trip", Codec.FromHex(Codec.ToHex("\0\127\255")) == "\0\127\255" and Codec.FromHex("zz") == nil)

	-- Paths
	local Good = { [""] = "", ["Shared"] = "Shared", ["/Shared/docs/"] = "Shared/docs", ["Shared//a/./b.txt"] = "Shared/a/b.txt", ["Shared\\x"] = "Shared/x" }
	local GoodOk = true
	for Input, Expected in pairs(Good) do
		if (Path.Normalize(Input) ~= Expected) then GoodOk = false end
	end
	T.Check("path normalisation", GoodOk)
	local Escapes = { "..", "../x", "Shared/../..", "Shared/../../blockos", "a/../../b", "..\\..\\rom", ".blockcloud/tmp",
		"Shared/.BlockCloud", "a\0b", "a:b", "a*b", " lead", "trail ", ("a/"):rep(30) .. "x", ("x"):rep(300), 5, nil }
	local Rejected = 0
	for Index = 1, 17 do
		if (Path.Normalize(Escapes[Index]) == nil) then Rejected = Rejected + 1 end
	end
	T.Check("path escapes rejected", Rejected == 17, Rejected .. "/17")
	T.Check("path resolve stays in root", Path.Resolve("/blockcloud/storage", "Shared/a.txt") == "/blockcloud/storage/Shared/a.txt"
		and Path.Resolve("/blockcloud/storage", "") == "/blockcloud/storage"
		and Path.Resolve("/blockcloud/storage", "../storage2/x") == nil)
	T.Check("storage root validation", Path.ValidRoot("/blockcloud/storage") and not Path.ValidRoot("/") and not Path.ValidRoot("/rom/x")
		and not Path.ValidRoot("/blockos/data") and Path.ValidRoot("disk/blockcloud"))
	T.Check("valid names", Path.ValidName("notes.txt") and not Path.ValidName("a/b") and not Path.ValidName("..") and not Path.ValidName(""))
	T.Check("within", Path.Within("a", "a/b") and Path.Within("a", "a") and not Path.Within("a", "ab") and Path.Within("", "x"))

	-- Auth
	local Code = Auth.PairingCode()
	T.Check("pairing code format", #Code == 8 and not Code:find("[^23456789ABCDEFGHJKMNPQRSTUVWXYZ]"), Code)
	T.Check("pairing codes differ", Auth.PairingCode() ~= Code)
	T.Check("code cleaning", Auth.CleanCode("ab cd-ef9h") == "ABCDEF9H")
	local Key = Auth.DeriveKey(Code, "req", "aa", "bb")
	T.Check("key derivation is stable", Key == Auth.DeriveKey(Code, "req", "aa", "bb") and Key ~= Auth.DeriveKey(Code, "req", "aa", "bc"))
	local Keys = Auth.Keys(Codec.ToHex(Key))
	local Sig = Auth.Sign(Keys, "hello")
	T.Check("signatures verify", Auth.Verify(Keys, "hello", Sig) and not Auth.Verify(Keys, "hellp", Sig) and not Auth.Verify(Keys, "hello", nil))
	local Plain = ("The quick brown fox \0\255 "):rep(20)
	local Cipher = Auth.Crypt(Keys.Enc, "nonce", Plain)
	-- RFC 7539 section 2.4.2 test vector.
	local RfcKey = ""
	for Byte = 0, 31 do RfcKey = RfcKey .. string.char(Byte) end
	local RfcPlain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
	local RfcCipher = Auth.ChaCha20(RfcKey, "\0\0\0\0\0\0\0\74\0\0\0\0", 1, RfcPlain)
	local RfcHex = Codec.ToHex(RfcCipher)
	T.Check("chacha20 matches RFC 7539", RfcHex:sub(1, 32) == "6e2e359a2568f98041ba0728dd0d6981"
		and RfcHex:sub(-24) == "5be6b40b8eedf2785e42874d" and #RfcCipher == #RfcPlain, RfcHex)
	T.Check("cipher round trip", Cipher ~= Plain and Auth.Crypt(Keys.Enc, "nonce", Cipher) == Plain and #Cipher == #Plain)

	-- Protocol envelopes
	for _, Encrypt in ipairs({ false, true }) do
		local Label = Encrypt and " (encrypted)" or ""
		local Msg = Protocol.Seal({ K = "req", ID = "abc123", Svc = "blockdrive", Op = "list", Cl = "c1" }, { Path = "Shared" }, Keys, Encrypt)
		T.Check("envelope valid" .. Label, Protocol.Valid(Msg))
		local Opened = Protocol.Open(Msg, Keys)
		T.Check("envelope opens" .. Label, type(Opened) == "table" and Opened.Path == "Shared")
		T.Check("encrypted body hides content" .. Label, (not Encrypt) or not Msg.B:find("Shared", 1, true))
		local Tampered = {}
		for K, V in pairs(Msg) do Tampered[K] = V end
		Tampered.Op = "delete"
		local _, Err = Protocol.Open(Tampered, Keys)
		T.Check("tampered header rejected" .. Label, Err == "bad_signature")
		Tampered.Op = Msg.Op
		Tampered.B = Msg.B:sub(1, -2) .. "x"
		_, Err = Protocol.Open(Tampered, Keys)
		T.Check("tampered body rejected" .. Label, Err == "bad_signature")
		local Other = Auth.Keys(Codec.ToHex(Auth.DeriveKey("WRONGKEY", "req", "aa", "bb")))
		_, Err = Protocol.Open(Msg, Other)
		T.Check("wrong key rejected" .. Label, Err == "bad_signature")
	end
	local Old = Protocol.Seal({ K = "req", ID = "old", Svc = "core", Op = "ping", T = os.epoch("utc") - 600000 }, {}, nil)
	T.Check("stale request detected", not Protocol.Fresh(Old))
	T.Check("protocol names are namespaced", Protocol.Name("blockdrive") == "blockcloud/svc/blockdrive" and Protocol.ServiceOf("blockos_chat") == nil)

	-- Speed on this machine, for the docs.
	local Start = os.epoch("utc")
	local Data = ("x"):rep(8192)
	Auth.Sign(Keys, Data)
	local SignMs = os.epoch("utc") - Start
	Start = os.epoch("utc")
	Auth.Crypt(Keys.Enc, "n", Data)
	T.Check("8 KB chunk sign " .. SignMs .. " ms, encrypt " .. (os.epoch("utc") - Start) .. " ms", true)
end)
