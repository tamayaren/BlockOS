-- ccinternet wire protocol: URLs, a safe data encoding, chunked rednet messages and a client helper.
-- Vendored from https://github.com/tamayaren/ccinternet (lib/protocol.lua), shared by Savannah and CCDream.

local Protocol = {}

Protocol.Name = "ccinternet"        -- rednet protocol
Protocol.DefaultHost = "ccinternet" -- hostname browsers look up by default
Protocol.Version = 1
Protocol.ChunkSize = 16384
Protocol.MaxParts = 64              -- 1 MB per message
Protocol.MaxPending = 32
Protocol.PendingTimeout = 30

Protocol.StatusText = {
	[200] = "OK", [301] = "Moved Permanently", [302] = "Found", [303] = "See Other",
	[400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
	[409] = "Conflict", [413] = "Too Large", [429] = "Too Many Requests",
	[500] = "Server Error", [503] = "Unavailable", [507] = "Out of Space"
}

Protocol.ContentTypes = {
	ccmd = "text/ccmd", txt = "text/plain", lua = "text/plain", md = "text/plain",
	nft = "image/nft", bimg = "image/bimg", nfp = "image/nfp"
}

function Protocol.ContentType(Path)
	local Extension = (tostring(Path):match("%.(%w+)$") or ""):lower()
	return Protocol.ContentTypes[Extension] or "application/octet-stream"
end

------------------------------------------------------------------------
-- URLs
------------------------------------------------------------------------

function Protocol.Escape(Text)
	return (tostring(Text):gsub("[^%w%-%._~/]", function(Char)
		return string.format("%%%02X", Char:byte())
	end))
end

function Protocol.Unescape(Text)
	return (tostring(Text):gsub("+", " "):gsub("%%(%x%x)", function(Hex)
		return string.char(tonumber(Hex, 16))
	end))
end

function Protocol.EncodeQuery(Params)
	local Keys = {}
	for Key in pairs(Params) do Keys[#Keys + 1] = tostring(Key) end
	table.sort(Keys)
	local Parts = {}
	for _, Key in ipairs(Keys) do
		local Value = Params[Key]
		if (type(Value) ~= "table") then
			Parts[#Parts + 1] = Protocol.Escape(Key):gsub("/", "%%2F") .. "=" .. Protocol.Escape(tostring(Value)):gsub("/", "%%2F")
		end
	end
	return table.concat(Parts, "&")
end

function Protocol.DecodeQuery(Query)
	local Params = {}
	for Pair in tostring(Query or ""):gmatch("[^&]+") do
		local Key, Value = Pair:match("^([^=]*)=?(.*)$")
		if (Key and Key ~= "") then Params[Protocol.Unescape(Key)] = Protocol.Unescape(Value) end
	end
	return Params
end

-- Collapses "." and ".." segments. Returns nil when the path escapes the root.
function Protocol.NormalizePath(Path)
	local Parts = {}
	for Segment in tostring(Path or ""):gmatch("[^/\\]+") do
		if (Segment == "..") then
			if (#Parts == 0) then return nil end
			Parts[#Parts] = nil
		elseif (Segment ~= ".") then
			Parts[#Parts + 1] = Segment
		end
	end
	return "/" .. table.concat(Parts, "/")
end

-- Parses an absolute URL, or a relative one against Base (a parsed URL).
-- Without a scheme or base, "example.com/page" is read as ccmd://example.com/page.
function Protocol.ParseUrl(Url, Base)
	Url = tostring(Url or ""):gsub("^%s+", ""):gsub("%s+$", "")
	Url = Url:gsub("#.*$", "")
	local Scheme, Rest = Url:match("^(%a[%w+%.%-]*)://(.*)$")
	local Host, Path, Query
	if (Scheme) then
		Host, Rest = Rest:match("^([^/%?]*)(.*)$")
	elseif (Base and Base.Scheme) then
		Scheme, Host = Base.Scheme, Base.Host
		if (Url:sub(1, 1) == "/") then
			Rest = Url
		elseif (Url:sub(1, 1) == "?" or Url == "") then
			Rest = Base.Path .. Url
		else
			Rest = Base.Path:gsub("[^/]*$", "") .. Url
		end
	else
		Scheme = "ccmd"
		Host, Rest = Url:match("^([^/%?]*)(.*)$")
	end
	Path, Query = Rest:match("^([^%?]*)%??(.*)$")
	Path = Protocol.NormalizePath(Protocol.Unescape((Path or ""):gsub("+", "%%2B")))
	if (not Path) then return nil, "Bad path" end
	return {
		Scheme = Scheme:lower(),
		Host = (Host or ""):lower(),
		Path = Path,
		Query = Query or "",
		Params = Protocol.DecodeQuery(Query)
	}
end

function Protocol.FormatUrl(Parsed)
	local Path = Parsed.Path or "/"
	if (Path == "/") then Path = "" end
	local Text = Parsed.Scheme .. "://" .. (Parsed.Host or "") .. Protocol.Escape(Path)
	if (Parsed.Query and Parsed.Query ~= "") then Text = Text .. "?" .. Parsed.Query end
	return Text
end

-- Builds a URL from parts, e.g. Protocol.Url("domain", "manage", "/", { domain = "x" }).
function Protocol.Url(Scheme, Host, Path, Params)
	return Protocol.FormatUrl({ Scheme = Scheme, Host = Host, Path = Path or "/", Query = Params and Protocol.EncodeQuery(Params) or "" })
end

------------------------------------------------------------------------
-- Data encoding: a small length-prefixed format for nested tables of strings, numbers and booleans.
-- Unlike textutils.unserialise it never runs code, so it is safe on input from other computers.
------------------------------------------------------------------------

local function EncodeValue(Value, Out, Depth)
	local Kind = type(Value)
	if (Kind == "string") then
		Out[#Out + 1] = "s" .. #Value .. ":" .. Value
	elseif (Kind == "number") then
		Out[#Out + 1] = "n" .. string.format("%.17g", Value) .. ";"
	elseif (Kind == "boolean") then
		Out[#Out + 1] = Value and "T" or "F"
	elseif (Kind == "table") then
		if (Depth > 16) then error("Table nested too deeply", 0) end
		Out[#Out + 1] = "{"
		for Key, Item in pairs(Value) do
			local KeyKind = type(Key)
			if ((KeyKind == "string" or KeyKind == "number") and type(Item) ~= "function") then
				EncodeValue(Key, Out, Depth + 1)
				EncodeValue(Item, Out, Depth + 1)
			end
		end
		Out[#Out + 1] = "}"
	else
		Out[#Out + 1] = "N"
	end
end

function Protocol.Encode(Value)
	local Out = {}
	EncodeValue(Value, Out, 0)
	return table.concat(Out)
end

function Protocol.Decode(Text)
	if (type(Text) ~= "string") then return nil, "Not a string" end
	local Pos = 1
	local Length = #Text

	local function Read(Depth)
		if (Depth > 17) then error("Too deep", 0) end
		local Tag = Text:sub(Pos, Pos)
		Pos = Pos + 1
		if (Tag == "s") then
			local Size, Next = Text:match("^(%d+):()", Pos)
			if (not Size) then error("Bad string", 0) end
			Size = tonumber(Size)
			if (Next + Size - 1 > Length) then error("Truncated string", 0) end
			Pos = Next + Size
			return Text:sub(Next, Next + Size - 1)
		elseif (Tag == "n") then
			local Number, Next = Text:match("^([^;]+);()", Pos)
			Number = tonumber(Number)
			if (not Number) then error("Bad number", 0) end
			Pos = Next
			return Number
		elseif (Tag == "T") then
			return true
		elseif (Tag == "F") then
			return false
		elseif (Tag == "N") then
			return nil
		elseif (Tag == "{") then
			local Result = {}
			while (true) do
				if (Pos > Length) then error("Unclosed table", 0) end
				if (Text:sub(Pos, Pos) == "}") then
					Pos = Pos + 1
					return Result
				end
				local Key = Read(Depth + 1)
				local Value = Read(Depth + 1)
				if (Key ~= nil) then Result[Key] = Value end
			end
		end
		error("Bad tag", 0)
	end

	local Ok, Value = pcall(Read, 0)
	if (not Ok) then return nil, Value end
	if (Pos <= Length) then return nil, "Trailing data" end
	return Value
end

------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------

-- Splits a request or response into rednet messages.
-- Head is a small table ({ Method, Url, Headers } or { Status, Headers }); Body is a string, a table or nil.
function Protocol.Pack(Type, Id, Head, Body)
	local Kind, Data = "nil", ""
	if (type(Body) == "string") then
		Kind, Data = "string", Body
	elseif (type(Body) == "table") then
		Kind, Data = "table", Protocol.Encode(Body)
	end
	local Parts = math.max(1, math.ceil(#Data / Protocol.ChunkSize))
	local Messages = {}
	for Part = 1, Parts do
		Messages[Part] = {
			CCI = Protocol.Version,
			Type = Type,
			Id = Id,
			Part = Part,
			Parts = Parts,
			Kind = Part == 1 and Kind or nil,
			Head = Part == 1 and Head or nil,
			Data = Data:sub((Part - 1) * Protocol.ChunkSize + 1, Part * Protocol.ChunkSize)
		}
	end
	return Messages
end

function Protocol.Send(Recipient, Type, Id, Head, Body)
	for _, Message in ipairs(Protocol.Pack(Type, Id, Head, Body)) do
		rednet.send(Recipient, Message, Protocol.Name)
	end
end

local Assembler = {}
Assembler.__index = Assembler

-- Collects message parts. Feed returns the finished message { Sender, Type, Id, Head, Body } once all parts arrived.
function Protocol.Assembler(Clock)
	return setmetatable({ Pending = {}, Count = 0, Clock = Clock or os.clock }, Assembler)
end

local function Valid(Message)
	return type(Message) == "table" and Message.CCI == Protocol.Version
		and (Message.Type == "request" or Message.Type == "response")
		and type(Message.Id) == "number" and type(Message.Part) == "number" and type(Message.Parts) == "number"
		and type(Message.Data) == "string" and Message.Parts >= 1 and Message.Parts <= Protocol.MaxParts
		and Message.Part >= 1 and Message.Part <= Message.Parts and Message.Part % 1 == 0
end

local function Finish(Sender, First, Data)
	local Body
	if (First.Kind == "string") then
		Body = Data
	elseif (First.Kind == "table") then
		Body = Protocol.Decode(Data)
	end
	return { Sender = Sender, Type = First.Type, Id = First.Id, Head = type(First.Head) == "table" and First.Head or {}, Body = Body }
end

function Assembler:Feed(Sender, Message)
	if (not Valid(Message)) then return nil end
	if (Message.Parts == 1) then return Finish(Sender, Message, Message.Data) end
	local Key = tostring(Sender) .. ":" .. Message.Type .. ":" .. Message.Id
	local Entry = self.Pending[Key]
	if (not Entry) then
		self:Prune()
		if (self.Count >= Protocol.MaxPending) then return nil end
		Entry = { Parts = {}, Received = 0, Total = Message.Parts }
		self.Pending[Key] = Entry
		self.Count = self.Count + 1
	end
	Entry.Time = self.Clock()
	if (Message.Parts ~= Entry.Total) then return nil end
	if (not Entry.Parts[Message.Part]) then
		Entry.Parts[Message.Part] = Message.Data
		Entry.Received = Entry.Received + 1
	end
	if (Message.Part == 1) then Entry.First = Message end
	if (Entry.Received < Entry.Total or not Entry.First) then return nil end
	self.Pending[Key] = nil
	self.Count = self.Count - 1
	return Finish(Sender, Entry.First, table.concat(Entry.Parts))
end

-- Progress of a pending message: received parts, total parts.
function Assembler:Progress(Sender, Type, Id)
	local Entry = self.Pending[tostring(Sender) .. ":" .. Type .. ":" .. Id]
	if (not Entry) then return 0, 0 end
	return Entry.Received, Entry.Total
end

function Assembler:Prune()
	local Now = self.Clock()
	for Key, Entry in pairs(self.Pending) do
		if (Now - Entry.Time > Protocol.PendingTimeout) then
			self.Pending[Key] = nil
			self.Count = self.Count - 1
		end
	end
end

------------------------------------------------------------------------
-- Client side
------------------------------------------------------------------------

-- Opens every attached modem for rednet. Returns how many were opened.
function Protocol.OpenModems()
	local Count = 0
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "modem") then
			if (not rednet.isOpen(Name)) then pcall(rednet.open, Name) end
			if (rednet.isOpen(Name)) then Count = Count + 1 end
		end
	end
	return Count
end

local NextId = 0

-- Sends a request to a server computer and waits for the whole response.
-- Returns { Status, Headers, Body } or nil and an error message.
-- Options: Timeout (seconds without data, default 10), OnProgress(Received, Total).
function Protocol.Request(Server, Method, Url, Headers, Body, Options)
	Options = Options or {}
	NextId = NextId + 1
	local Id = (os.getComputerID() * 1000003 + NextId * 7919 + math.random(0, 999)) % 2147483647
	Protocol.Send(Server, "request", Id, { Method = Method, Url = Url, Headers = Headers or {} }, Body)
	local Collector = Protocol.Assembler()
	local Timeout = Options.Timeout or 10
	local Timer = os.startTimer(Timeout)
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "rednet_message" and A == Server and C == Protocol.Name and type(B) == "table" and B.Id == Id and B.Type == "response") then
			os.cancelTimer(Timer)
			Timer = os.startTimer(Timeout)
			local Full = Collector:Feed(A, B)
			if (Full) then
				os.cancelTimer(Timer)
				local Head = Full.Head
				return { Status = tonumber(Head.Status) or 500, Headers = type(Head.Headers) == "table" and Head.Headers or {}, Body = Full.Body }
			elseif (Options.OnProgress) then
				Options.OnProgress(Collector:Progress(A, "response", Id))
			end
		elseif (Event == "timer" and A == Timer) then
			return nil, "The server did not answer"
		end
	end
end

-- A transport sends a request and returns a response table (or nil, error).
-- This one talks to a core over rednet, looking it up by hostname the first time.
function Protocol.NetworkTransport(Hostname)
	local Transport = { Hostname = Hostname or Protocol.DefaultHost }
	function Transport.Find(Force)
		if (Transport.Server and not Force) then return Transport.Server end
		if (Protocol.OpenModems() == 0) then return nil, "No modem attached" end
		Transport.Server = rednet.lookup(Protocol.Name, Transport.Hostname)
		if (not Transport.Server) then return nil, "Could not find the server \"" .. Transport.Hostname .. "\"" end
		return Transport.Server
	end
	function Transport.Send(Method, Url, Headers, Body, Options)
		local Server, Problem = Transport.Find()
		if (not Server) then return nil, Problem end
		local Response, Error = Protocol.Request(Server, Method, Url, Headers, Body, Options)
		if (not Response) then
			-- The core may have moved or been renamed; look it up once more.
			Server = Transport.Find(true)
			if (Server) then Response, Error = Protocol.Request(Server, Method, Url, Headers, Body, Options) end
		end
		return Response, Error
	end
	return Transport
end

return Protocol
