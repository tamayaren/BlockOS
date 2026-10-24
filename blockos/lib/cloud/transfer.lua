-- Chunked BlockDrive transfers. Files move in chunks of a few KB, each acknowledged by the
-- server and retried on loss; the whole file is checked with Adler-32 at the end. Downloads are
-- written to a temporary file and moved into place only when complete and verified.

local Client = BlockOS.Require("cloud/client")
local Codec = BlockOS.Require("cloud/codec")
local Protocol = BlockOS.Require("cloud/protocol")

local Transfer = {}

Transfer.ChunkTimeout = 4
Transfer.ChunkRetries = 3

local function Checksum(Data)
	local Sum = 1
	for Start = 1, #Data, 65536 do
		Sum = Codec.Adler32(Data:sub(Start, Start + 65535), Sum)
		if (#Data > 65536) then sleep(0) end
	end
	return Sum
end

function Transfer.ReadLocal(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil, Protocol.Error("local_io", "Cannot read " .. Path) end
	local Handle = fs.open(Path, "rb")
	if (not Handle) then return nil, Protocol.Error("local_io", "Cannot read " .. Path) end
	local Data = Handle.readAll() or ""
	Handle.close()
	return Data
end

-- Writes Data to Path through a temporary file, so an existing file is replaced in one step.
function Transfer.WriteLocal(Path, Data)
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Temp = Path .. ".part"
	local Handle = fs.open(Temp, "wb")
	if (not Handle) then return nil, Protocol.Error("local_io", "Cannot write " .. Path) end
	Handle.write(Data)
	Handle.close()
	if (fs.getSize(Temp) ~= #Data) then
		fs.delete(Temp)
		return nil, Protocol.Error("local_io", "Not enough space on this computer for " .. fs.getName(Path))
	end
	local Backup = Path .. ".old"
	if (fs.exists(Path)) then
		if (fs.exists(Backup)) then fs.delete(Backup) end
		fs.move(Path, Backup)
	end
	local Ok = pcall(fs.move, Temp, Path)
	if (not Ok) then
		if (fs.exists(Backup)) then fs.move(Backup, Path) end
		return nil, Protocol.Error("local_io", "Cannot write " .. Path)
	end
	if (fs.exists(Backup)) then fs.delete(Backup) end
	return true
end

local function Chunk(Server, Op, Args)
	return Client.Call(Server, "blockdrive", Op, Args, { Timeout = Transfer.ChunkTimeout, Retries = Transfer.ChunkRetries })
end

local function SendOnce(Server, Remote, Data, Sum, Opts)
	local Begin, Err = Client.Call(Server, "blockdrive", "upload_begin", { Path = Remote, Size = #Data, Sum = Sum, Overwrite = Opts.Overwrite })
	if (not Begin) then return nil, Err end
	local Size = Begin.ChunkSize
	local Count = math.ceil(#Data / Size)
	local Index = 1
	while (Index <= Count) do
		local Part = Data:sub((Index - 1) * Size + 1, Index * Size)
		local Ack, ChunkErr = Chunk(Server, "upload_chunk", { Transfer = Begin.Transfer, Index = Index, Data = Part, Sum = Codec.Adler32(Part) })
		if (not Ack) then
			if (ChunkErr.Code ~= "transfer_lost") then
				Client.Call(Server, "blockdrive", "upload_abort", { Transfer = Begin.Transfer }, { Retries = 0, Timeout = 1 })
			end
			return nil, ChunkErr
		end
		Index = tonumber(Ack.Next) or (Index + 1)
		if (Opts.OnProgress) then Opts.OnProgress(math.min(#Data, (Index - 1) * Size), #Data) end
		if (Opts.Cancelled and Opts.Cancelled()) then
			Client.Call(Server, "blockdrive", "upload_abort", { Transfer = Begin.Transfer }, { Retries = 0, Timeout = 1 })
			return nil, Protocol.Error("invalid", "Cancelled")
		end
	end
	return Client.Call(Server, "blockdrive", "upload_commit", { Transfer = Begin.Transfer }, { Timeout = 5 })
end

-- Uploads Source ({ Path = local file } or { Data = string }) to Remote.
-- Opts: Overwrite, OnProgress(done, total), Cancelled(). Returns the remote entry or nil, err.
function Transfer.Upload(Server, Remote, Source, Opts)
	Opts = Opts or {}
	local Data, Err = Source.Data, nil
	if (not Data) then
		Data, Err = Transfer.ReadLocal(Source.Path)
		if (not Data) then return nil, Err end
	end
	local Sum = Checksum(Data)
	local Result
	-- If the server restarts mid-upload the staged data is gone; start over once.
	for _ = 1, 2 do
		Result, Err = SendOnce(Server, Remote, Data, Sum, Opts)
		if (Result or not Err or (Err.Code ~= "transfer_lost" and Err.Code ~= "checksum")) then break end
	end
	return Result, Err
end

local function FetchOnce(Server, Remote, Opts)
	local Begin, Err = Client.Call(Server, "blockdrive", "download_begin", { Path = Remote }, { Timeout = 6 })
	if (not Begin) then return nil, Err end
	local Parts = {}
	local Received = 0
	for Index = 1, Begin.Chunks do
		local Piece, ChunkErr = Chunk(Server, "download_chunk", { Transfer = Begin.Transfer, Index = Index })
		if (not Piece) then return nil, ChunkErr end
		if (type(Piece.Data) ~= "string" or Codec.Adler32(Piece.Data) ~= Piece.Sum) then
			Client.Call(Server, "blockdrive", "download_end", { Transfer = Begin.Transfer }, { Retries = 0, Timeout = 1 })
			return nil, Protocol.Error("checksum")
		end
		Parts[Index] = Piece.Data
		Received = Received + #Piece.Data
		if (Opts.OnProgress) then Opts.OnProgress(Received, Begin.Size) end
		if (Opts.Cancelled and Opts.Cancelled()) then
			Client.Call(Server, "blockdrive", "download_end", { Transfer = Begin.Transfer }, { Retries = 0, Timeout = 1 })
			return nil, Protocol.Error("invalid", "Cancelled")
		end
	end
	Client.Call(Server, "blockdrive", "download_end", { Transfer = Begin.Transfer }, { Retries = 0, Timeout = 2 })
	local Data = table.concat(Parts)
	if (#Data ~= Begin.Size or Checksum(Data) ~= Begin.Sum) then return nil, Protocol.Error("checksum") end
	return Data
end

-- Downloads Remote. With Opts.Path the file is saved there; otherwise the data is returned.
-- Opts: Path, OnProgress(done, total), Cancelled().
function Transfer.Download(Server, Remote, Opts)
	Opts = Opts or {}
	local Data, Err
	for _ = 1, 2 do
		Data, Err = FetchOnce(Server, Remote, Opts)
		if (Data or (Err.Code ~= "transfer_lost" and Err.Code ~= "checksum" and Err.Code ~= "changed")) then break end
	end
	if (not Data) then return nil, Err end
	if (Opts.Path) then
		local Ok, WriteErr = Transfer.WriteLocal(Opts.Path, Data)
		if (not Ok) then return nil, WriteErr end
		return #Data
	end
	return Data
end

return Transfer
