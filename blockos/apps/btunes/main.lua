-- bTunes: plays YouTube, DFPWM links and files on disk through every attached speaker.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Dfpwm = require("cc.audio.dfpwm")

local Args = { ... }

local LibraryPath = "/blockos/data/music.dat"
local ChunkSize = 16 * 1024
local BytesPerSecond = 6000
local SampleRate = 48000
-- Community server that converts YouTube audio to DFPWM (the same one Minux and iPod use).
local DefaultServer = "https://ipod-2to6magyna-uc.a.run.app/"
local ApiVersion = "2.1"

local Library = Config.Read(LibraryPath) or { Tracks = {} }
local Page = Ui.Page.new()
local Tab = 1
local Build
local SearchField

local Search = {
	Query = "",
	Results = {},
	State = "idle",
	RequestUrl = nil,
	Error = nil
}
-- Title lookups for pasted YouTube links, keyed by request URL.
local Lookups = {}

local Player = {
	Queue = {},
	Index = 0,
	State = "stopped",
	Volume = 1,
	Shuffle = false,
	Repeat = false,
	Bytes = 0,
	Total = 0,
	-- Decoded chunks with the clock times the speakers play them, newest last.
	Timeline = {},
	AudioEnd = nil,
	Error = nil
}

local Visual = {
	Modes = { "Bars", "Mirror", "Wave" },
	Window = 1024,
	Count = 0,
	Wanted = 16,
	-- FFT tables, built once.
	Hann = {},
	Reverse = {},
	Cos = {},
	Sin = {},
	-- First FFT bin of each band; band N ends where band N + 1 starts.
	Edges = {},
	Bands = {},
	Peaks = {},
	Wave = nil
}

local function Speakers()
	local List = {}
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "speaker") then
			table.insert(List, { Name = Name, Device = peripheral.wrap(Name) })
		end
	end
	return List
end

local function SaveLibrary()
	Config.Write(LibraryPath, Library)
end

local function Server()
	local Url = Library.Server or DefaultServer
	if (Url:sub(-1) ~= "/") then Url = Url .. "/" end
	return Url
end

local function StreamUrl(ID)
	return Server() .. "?v=" .. ApiVersion .. "&id=" .. textutils.urlEncode(ID)
end

local function SearchUrl(Query)
	return Server() .. "?v=" .. ApiVersion .. "&search=" .. textutils.urlEncode(Query)
end

-- Returns the video ID of a YouTube link, or nil for anything else.
local function YouTubeID(Link)
	if (not Link:match("youtube%.com") and not Link:match("youtu%.be")) then return nil end
	return Link:match("youtu%.be/([%w_%-]+)") or Link:match("[?&]v=([%w_%-]+)") or Link:match("/shorts/([%w_%-]+)") or Link:match("/live/([%w_%-]+)")
end

local function IsYouTubePlaylist(Link)
	return (Link:match("youtube%.com") and Link:match("[?&]list=") and not YouTubeID(Link)) and true or false
end

local function FormatTime(Seconds)
	Seconds = math.max(0, math.floor(Seconds))
	return string.format("%d:%02d", math.floor(Seconds / 60), Seconds % 60)
end

local function CloseHandle()
	if (Player.Handle) then
		pcall(Player.Handle.close)
		Player.Handle = nil
	end
end

local function Stop()
	Player.State = "stopped"
	Player.Buffer = nil
	Player.Pending = nil
	Player.RequestUrl = nil
	Player.Timeline = {}
	Player.AudioEnd = nil
	CloseHandle()
	for _, Speaker in ipairs(Speakers()) do
		pcall(Speaker.Device.stop)
	end
end

local Play

local function TrackEnded()
	CloseHandle()
	Player.Buffer = nil
	local Next = Player.Index + 1
	if (Player.Shuffle and #Player.Queue > 1) then
		repeat
			Next = math.random(1, #Player.Queue)
		until Next ~= Player.Index
	end
	if (Next > #Player.Queue) then
		if (not Player.Repeat) then
			Player.State = "stopped"
			return
		end
		Next = 1
	end
	Play(Next)
end

-- Remembers when a chunk the speakers just accepted will be heard, so the visualizer follows the sound.
local function Schedule(Samples)
	local Start = math.max(os.clock(), Player.AudioEnd or 0)
	Player.AudioEnd = Start + #Samples / SampleRate
	table.insert(Player.Timeline, { Samples = Samples, Start = Start, End = Player.AudioEnd })
	while (#Player.Timeline > 3) do
		table.remove(Player.Timeline, 1)
	end
end

-- Pushes decoded audio to speakers until one of them is full.
local function Feed()
	while (Player.State == "playing") do
		if (not Player.Buffer) then
			local Chunk = Player.Handle and Player.Handle.read(ChunkSize)
			if (not Chunk or #Chunk == 0) then
				TrackEnded()
				return
			end
			Player.Bytes = Player.Bytes + #Chunk
			Player.Buffer = Player.Decoder(Chunk)
			Player.Pending = {}
			for _, Speaker in ipairs(Speakers()) do
				Player.Pending[Speaker.Name] = Speaker.Device
			end
			if (next(Player.Pending) == nil) then
				Player.Error = "No speaker attached"
				Stop()
				return
			end
		end
		for Name, Device in pairs(Player.Pending) do
			if (Device.playAudio(Player.Buffer, Player.Volume)) then
				Player.Pending[Name] = nil
			end
		end
		if (next(Player.Pending) ~= nil) then return end
		Schedule(Player.Buffer)
		Player.Buffer = nil
	end
end

local function StartStream(Handle, Total)
	Player.Handle = Handle
	Player.Total = Total or 0
	Player.Bytes = 0
	Player.Decoder = Dfpwm.make_decoder()
	Player.State = "playing"
	Player.Error = nil
	Feed()
end

function Play(Index)
	Stop()
	local Track = Player.Queue[Index]
	if (not Track) then return end
	Player.Index = Index
	Player.Error = nil
	BlockOS.SetTitle("bTunes \7 " .. Track.Name)
	if (Track.Path) then
		local Handle = fs.open(Track.Path, "rb")
		if (not Handle) then
			Player.Error = "Cannot open " .. Track.Path
			return
		end
		StartStream(Handle, fs.getSize(Track.Path))
		return
	end
	if (not http) then
		Player.Error = "HTTP is disabled"
		return
	end
	local Url = Track.ID and StreamUrl(Track.ID) or Track.Url
	Player.State = "loading"
	Player.RequestUrl = Url
	http.request({ url = Url, binary = true })
end

local function PlayList(Tracks, Start)
	Player.Queue = Tracks
	Play(Start or 1)
end

local function TogglePause()
	if (Player.State == "playing") then
		Player.State = "paused"
	elseif (Player.State == "paused") then
		Player.State = "playing"
		Feed()
	elseif (Player.State == "stopped" and #Player.Queue > 0) then
		Play(math.max(1, Player.Index))
	end
end

local function Previous()
	if (#Player.Queue == 0) then return end
	if (Player.Bytes > BytesPerSecond * 3) then
		Play(Player.Index)
	else
		Play(math.max(1, Player.Index - 1))
	end
end

local function ResultTrack(Item)
	return { Name = tostring(Item.name or "Untitled"), Artist = Item.artist and tostring(Item.artist) or nil, ID = tostring(Item.id) }
end

local function RunSearch(Query)
	Query = (Query or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if (#Query == 0) then return end
	if (not http) then
		Search.Error = "HTTP is disabled"
		Build()
		return
	end
	Search.Query = Query
	Search.Results = {}
	Search.Error = nil
	Search.State = "searching"
	Search.RequestUrl = SearchUrl(Query)
	http.request(Search.RequestUrl)
	Build()
end

local function SearchDone(Handle)
	local Body = Handle.readAll()
	pcall(Handle.close)
	Search.State = "idle"
	local Parsed, Results = pcall(textutils.unserialiseJSON, Body or "")
	if (not Parsed or type(Results) ~= "table") then
		Search.Error = "The YouTube server sent an unexpected reply"
		return
	end
	Search.Results = {}
	for _, Item in ipairs(Results) do
		if (type(Item) == "table" and Item.id) then
			local Entry = { Name = tostring(Item.name or "Untitled"), Artist = Item.artist and tostring(Item.artist) or nil }
			if (Item.type == "playlist" and type(Item.playlist_items) == "table") then
				Entry.Tracks = {}
				for _, Song in ipairs(Item.playlist_items) do
					if (type(Song) == "table" and Song.id) then table.insert(Entry.Tracks, ResultTrack(Song)) end
				end
			else
				Entry.ID = tostring(Item.id)
			end
			table.insert(Search.Results, Entry)
		end
	end
	if (#Search.Results == 0) then Search.Error = "No results for \"" .. Search.Query .. "\"" end
end

-- Asks the server for the real title of a pasted YouTube link.
local function LookupTitle(Track)
	if (not http) then return end
	local Url = SearchUrl("https://youtu.be/" .. Track.ID)
	Lookups[Url] = Track
	http.request(Url)
end

local function LookupDone(Track, Handle)
	local Body = Handle.readAll()
	pcall(Handle.close)
	local Parsed, Results = pcall(textutils.unserialiseJSON, Body or "")
	if (not Parsed or type(Results) ~= "table" or type(Results[1]) ~= "table") then return end
	local Match = Results[1]
	for _, Item in ipairs(Results) do
		if (type(Item) == "table" and tostring(Item.id) == Track.ID) then Match = Item end
	end
	if (not Match.name) then return end
	Track.Name = tostring(Match.name)
	Track.Artist = Match.artist and tostring(Match.artist) or nil
	SaveLibrary()
end

-- The tracks a search result stands for: one song, or every song of a playlist.
local function ResultTracks(Entry)
	if (Entry.Tracks) then return Entry.Tracks end
	return { { Name = Entry.Name, Artist = Entry.Artist, ID = Entry.ID } }
end

local function LocalFiles()
	local Files = {}
	local Folders = { "/home/Music", "/home/Downloads" }
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "drive" and disk.hasData(Name)) then
			table.insert(Folders, "/" .. disk.getMountPath(Name))
		end
	end
	for _, Folder in ipairs(Folders) do
		if (fs.isDir(Folder)) then
			for _, Name in ipairs(fs.list(Folder)) do
				if (Name:lower():match("%.dfpwm$")) then
					table.insert(Files, { Name = Name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""), Path = fs.combine(Folder, Name), Where = Folder })
				end
			end
		end
	end
	return Files
end

local function TrackList(Y, H, Tracks, Removable)
	local Items = {}
	for Index, Track in ipairs(Tracks) do
		local Playing = Player.Queue[Player.Index] == Track and Player.State ~= "stopped"
		local Source = Track.Path and "disk" or (Track.ID and "yt" or "web")
		table.insert(Items, { Text = Track.Name, Icon = Playing and "\16" or "\14", IconFg = Playing and "Accent" or "SubText", Right = Source, Index = Index })
	end
	local List = Page:Add(Ui.List.new({ X = 1, Y = Y, W = Page.W, H = H, Items = Items }))
	List.OnActivate = function(_, Index) PlayList(Tracks, Index) end
	List.OnContext = function(_, Index, Item, X, CY)
		if (not Item) then return end
		local Options = { "Play", "Play Next" }
		if (Removable) then
			table.insert(Options, "Rename")
			table.insert(Options, "Remove")
		end
		local Choice = Options[Ui.ContextMenu(X, CY, Options) or 0]
		if (Choice == "Play") then
			PlayList(Tracks, Index)
		elseif (Choice == "Play Next") then
			table.insert(Player.Queue, math.min(#Player.Queue + 1, Player.Index + 1), Tracks[Index])
		elseif (Choice == "Rename") then
			local Name = Ui.Prompt("Rename", "Track name:", Tracks[Index].Name)
			if (Name and #Name > 0) then
				Tracks[Index].Name = Name
				SaveLibrary()
				Build()
			end
		elseif (Choice == "Remove") then
			table.remove(Tracks, Index)
			SaveLibrary()
			Build()
		end
	end
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = 2, Y = Y + 1, W = Page.W - 2, H = 2, Fg = "SubText",
			Text = Removable and "Your library is empty. Find songs in Search or add a link in Add." or "No .dfpwm files in Music, Downloads or disks." }))
	end
end

local function BuildSearch(Y, H)
	local W = Page.W
	SearchField = Page:Add(Ui.Input.new({ X = 1, Y = Y, W = W - 9, Placeholder = "Search YouTube or paste a link" }))
	SearchField:SetValue(Search.Query)
	SearchField.OnSubmit = function(_, Value) RunSearch(Value) end
	Page:Add(Ui.Button.new({ X = W - 8, Y = Y, W = 9, Text = "Search", Style = "primary", OnClick = function() RunSearch(SearchField.Value) end }))
	local Items = {}
	for Index, Entry in ipairs(Search.Results) do
		local Text = Entry.Name
		if (Entry.Artist and #Entry.Artist > 0) then Text = Text .. " \7 " .. Entry.Artist end
		table.insert(Items, { Text = Text, Icon = Entry.Tracks and "\19" or "\14", IconFg = "SubText", Right = Entry.Tracks and (#Entry.Tracks .. " songs") or "yt", Index = Index })
	end
	local List = Page:Add(Ui.List.new({ X = 1, Y = Y + 1, W = W, H = H - 1, Items = Items }))
	List.OnActivate = function(_, Index)
		local Entry = Search.Results[Index]
		if (not Entry) then return end
		if (Entry.Tracks) then
			PlayList(Entry.Tracks, 1)
			return
		end
		-- Queue the other songs too so next/previous keep working.
		local Queue = {}
		local Start = 1
		for Other, Result in ipairs(Search.Results) do
			if (Result.ID) then
				table.insert(Queue, ResultTracks(Result)[1])
				if (Other == Index) then Start = #Queue end
			end
		end
		PlayList(Queue, Start)
	end
	List.OnContext = function(_, Index, Item, X, CY)
		if (not Item) then return end
		local Entry = Search.Results[Index]
		local Options = { "Play", "Play Next", "Add to Library" }
		local Choice = Options[Ui.ContextMenu(X, CY, Options) or 0]
		if (Choice == "Play") then
			PlayList(ResultTracks(Entry), 1)
		elseif (Choice == "Play Next") then
			for Offset, Track in ipairs(ResultTracks(Entry)) do
				table.insert(Player.Queue, math.min(#Player.Queue + 1, Player.Index + Offset), Track)
			end
		elseif (Choice == "Add to Library") then
			for _, Track in ipairs(ResultTracks(Entry)) do
				table.insert(Library.Tracks, Track)
			end
			SaveLibrary()
			BlockOS.Notify("bTunes", "Added " .. Entry.Name .. " to your library")
		end
	end
	local Message = Search.Error
	if (Search.State == "searching") then
		Message = "Searching..."
	elseif (#Items == 0 and not Message) then
		Message = "Type a song, artist or YouTube link and press Enter."
	end
	if (Message) then
		Page:Add(Ui.Label.new({ X = 2, Y = Y + 2, W = W - 2, H = 2, Fg = "SubText", Text = Message }))
	end
	Page:SetFocus(SearchField)
end

local function NowPlaying(Y)
	local W = Page.W
	Page:Add(Ui.Canvas.new({
		X = 1, Y = Y, W = W, H = 3,
		OnDraw = function(Self, T, Th)
			Gfx.Fill(T, Self.X, Self.Y, Self.W, 3, Th.Panel)
			local Track = Player.Queue[Player.Index]
			local Title = Track and Track.Name or "Not playing"
			if (Player.State == "loading") then Title = "Loading " .. Title .. "..." end
			if (Player.Error) then Title = Player.Error end
			Gfx.Write(T, Self.X + 1, Self.Y, Gfx.Truncate(Title, Self.W - 2), Player.Error and colors.red or Th.PanelFg, Th.Panel)
			local Elapsed = Player.Bytes / BytesPerSecond
			local Total = Player.Total / BytesPerSecond
			local Times = FormatTime(Elapsed) .. "/" .. (Total > 0 and FormatTime(Total) or "--:--")
			local BarW = Self.W - #Times - 3
			local Filled = (Total > 0) and math.floor(BarW * math.min(1, Elapsed / Total)) or 0
			Gfx.Fill(T, Self.X + 1, Self.Y + 1, BarW, 1, Th.Border)
			Gfx.Fill(T, Self.X + 1, Self.Y + 1, Filled, 1, Th.Accent)
			Gfx.Write(T, Self.X + BarW + 2, Self.Y + 1, Times, Th.SubText, Th.Panel)
		end
	}))
	local Controls = {
		{ Text = "\171", Action = Previous },
		{ Text = function() return (Player.State == "playing") and "\149\149" or "\16" end, Action = TogglePause },
		{ Text = "\187", Action = function() if (#Player.Queue > 0) then TrackEnded() end end },
		{ Text = "\143", Action = Stop }
	}
	local X = 2
	for _, Control in ipairs(Controls) do
		Page:Add(Ui.Button.new({ X = X, Y = Y + 2, W = 4, Text = Control.Text, Bg = "Panel", OnClick = Control.Action }))
		X = X + 4
	end
	Page:Add(Ui.Button.new({ X = X + 1, Y = Y + 2, W = 3, Text = function() return Player.Shuffle and "S*" or "S" end, Bg = "Panel", OnClick = function() Player.Shuffle = not Player.Shuffle end }))
	Page:Add(Ui.Button.new({ X = X + 4, Y = Y + 2, W = 3, Text = function() return Player.Repeat and "R*" or "R" end, Bg = "Panel", OnClick = function() Player.Repeat = not Player.Repeat end }))
	local VolumeX = W - 12
	if (VolumeX > X + 8) then
		Page:Add(Ui.Button.new({ X = VolumeX, Y = Y + 2, W = 2, Text = "-", Bg = "Panel", OnClick = function() Player.Volume = math.max(0, Player.Volume - .25) end }))
		Page:Add(Ui.Canvas.new({
			X = VolumeX + 2, Y = Y + 2, W = 6, H = 1,
			OnDraw = function(Self, T, Th)
				local Filled = math.floor(Player.Volume / 3 * Self.W + .5)
				Gfx.Fill(T, Self.X, Self.Y, Self.W, 1, Th.Border)
				Gfx.Fill(T, Self.X, Self.Y, Filled, 1, Th.Accent)
			end
		}))
		Page:Add(Ui.Button.new({ X = VolumeX + 8, Y = Y + 2, W = 2, Text = "+", Bg = "Panel", OnClick = function() Player.Volume = math.min(3, Player.Volume + .25) end }))
	end
end

--
-- Visualizer
--

local function BuildTables()
	local N = Visual.Window
	local Bits = math.floor(math.log(N, 2) + .5)
	for Index = 0, N - 1 do
		local Reversed, Value = 0, Index
		for _ = 1, Bits do
			Reversed = Reversed * 2 + Value % 2
			Value = math.floor(Value / 2)
		end
		Visual.Reverse[Index + 1] = Reversed + 1
		Visual.Hann[Index + 1] = .5 - .5 * math.cos(2 * math.pi * Index / (N - 1))
	end
	for Index = 0, N / 2 - 1 do
		Visual.Cos[Index + 1] = math.cos(2 * math.pi * Index / N)
		Visual.Sin[Index + 1] = -math.sin(2 * math.pi * Index / N)
	end
end

-- Splits roughly 50 Hz to 12 kHz into Count bands spaced evenly in pitch, each at least one bin wide.
local function BuildBands(Count)
	if (#Visual.Reverse == 0) then BuildTables() end
	Visual.Count = Count
	local MaxBin = math.floor(12000 * Visual.Window / SampleRate)
	Visual.Edges = { 1 }
	for Band = 1, Count do
		Visual.Edges[Band + 1] = math.max(Visual.Edges[Band] + 1, math.floor(MaxBin ^ (Band / Count) + .5))
	end
	Visual.Bands, Visual.Peaks = {}, {}
end

-- The samples the speakers are playing right now and where they start.
local function Audible()
	local Now = os.clock()
	for _, Chunk in ipairs(Player.Timeline) do
		if (Now >= Chunk.Start and Now < Chunk.End) then
			local Offset = math.floor((Now - Chunk.Start) * SampleRate) + 1
			return Chunk.Samples, math.max(1, math.min(Offset, #Chunk.Samples - Visual.Window + 1))
		end
	end
	return nil
end

-- Power of each FFT bin (0 is DC) for a Hann-windowed slice of the audio.
local function Spectrum(Samples, Offset)
	local N = Visual.Window
	local Re, Im = {}, {}
	for Index = 1, N do
		local Target = Visual.Reverse[Index]
		Re[Target] = (Samples[Offset + Index - 1] or 0) * Visual.Hann[Index]
		Im[Target] = 0
	end
	local Size = 2
	while (Size <= N) do
		local Half = Size / 2
		local Step = N / Size
		for Start = 1, N, Size do
			for K = 0, Half - 1 do
				local Cos, Sin = Visual.Cos[K * Step + 1], Visual.Sin[K * Step + 1]
				local A, B = Start + K, Start + K + Half
				local TRe = Re[B] * Cos - Im[B] * Sin
				local TIm = Re[B] * Sin + Im[B] * Cos
				Re[B], Im[B] = Re[A] - TRe, Im[A] - TIm
				Re[A], Im[A] = Re[A] + TRe, Im[A] + TIm
			end
		end
		Size = Size * 2
	end
	local Power = {}
	for Bin = 0, N / 2 - 1 do
		Power[Bin] = Re[Bin + 1] * Re[Bin + 1] + Im[Bin + 1] * Im[Bin + 1]
	end
	return Power
end

-- Loudness of one band from 0 to 1 over a 54 dB range, from its loudest bin.
local function BandLevel(Power, Band)
	local Loudest = 0
	for Bin = Visual.Edges[Band], Visual.Edges[Band + 1] - 1 do
		if ((Power[Bin] or 0) > Loudest) then Loudest = Power[Bin] end
	end
	-- A full-scale sine through a Hann window peaks at a quarter of the window length.
	local Amplitude = math.sqrt(Loudest) / (Visual.Window / 4)
	local Decibels = 20 * math.log(Amplitude / 128 + 1e-9, 10)
	return math.max(0, math.min(1, (Decibels + 54) / 54))
end

-- Moves every band towards the audio playing now: bars jump up and fall back slowly.
-- Returns false once everything has settled, so idle frames are not redrawn.
local function Analyze()
	if (Visual.Count ~= Visual.Wanted) then BuildBands(Visual.Wanted) end
	local Samples, Offset = Audible()
	if (Player.State ~= "playing" and Player.State ~= "paused") then Samples = nil end
	Visual.Wave = Samples and { Samples = Samples, Offset = Offset } or nil
	local Moving = Samples ~= nil
	local Power = Samples and Spectrum(Samples, Offset)
	for Band = 1, Visual.Count do
		local Target = Power and BandLevel(Power, Band) or 0
		local Current = Visual.Bands[Band] or 0
		Current = (Target > Current) and Target or math.max(Target, Current - .07)
		Visual.Bands[Band] = Current
		local Peak = Visual.Peaks[Band] or 0
		Visual.Peaks[Band] = (Current >= Peak) and Current or math.max(Current, Peak - .025)
		if (Current > 0 or Visual.Peaks[Band] > 0) then Moving = true end
	end
	return Moving
end

-- Teletext characters split a cell into 2x3 pixels; Bits sets them (1, 2 top row, 4, 8 middle, 16, 32 bottom).
-- The sixth bit cannot be drawn directly, so those cells swap colours instead.
local function Pixels(Bits, On, Off)
	if (Bits >= 32) then
		return string.char(128 + 63 - Bits), Off, On
	end
	return string.char(128 + Bits), On, Off
end

-- Thirds of a cell filled from the bottom (Up) or from the top.
local Thirds = {
	Up = { 0, 48, 60, 63 },
	Down = { 0, 3, 15, 63 }
}
-- A single third, counted from the bottom.
local Slices = { 48, 12, 3 }

local function BarColor(Fraction)
	if (Fraction > .88) then return colors.red end
	if (Fraction > .7) then return colors.orange end
	if (Fraction > .45) then return colors.yellow end
	return colors.lime
end

local function DrawBars(T, Th, X, Y, W, H)
	local Count = Visual.Count
	local Bg = Th.WindowBg
	local BarW = math.max(1, math.floor(W / Count) - 1)
	local Left = X + math.floor((W - Count * (BarW + 1) + 1) / 2)
	for Band = 1, Count do
		local Filled = math.floor((Visual.Bands[Band] or 0) * H * 3 + .5)
		local Peak = math.floor((Visual.Peaks[Band] or 0) * H * 3 + .5)
		local Column = Left + (Band - 1) * (BarW + 1)
		for Row = 1, H do
			local Part = math.max(0, math.min(3, Filled - (Row - 1) * 3))
			local Char, Fg, CellBg = Pixels(Thirds.Up[Part + 1], BarColor(Row / H), Bg)
			local PeakRow = math.ceil(Peak / 3)
			if (Part == 0 and Peak > Filled and PeakRow == Row) then
				Char, Fg, CellBg = Pixels(Slices[Peak - (Row - 1) * 3], Th.Text, Bg)
			end
			Gfx.Write(T, Column, Y + H - Row, string.rep(Char, BarW), Fg, CellBg)
		end
	end
end

-- Low notes in the middle spreading outwards, reflected above and below a centre line.
local function DrawMirror(T, Th, X, Y, W, H)
	local Bg = Th.WindowBg
	local Half = math.floor(H / 2)
	local Center = X + math.floor(W / 2)
	for Column = X, X + W - 1 do
		local Band = math.min(Visual.Count, math.floor(math.abs(Column - Center) * Visual.Count / math.max(1, W / 2)) + 1)
		local Level = Visual.Bands[Band] or 0
		local Filled = math.floor(Level * Half * 3 + .5)
		local Color = (Level > .75) and colors.white or ((Level > .45) and colors.lightBlue or Th.Accent)
		for Row = 1, Half do
			local Part = math.max(0, math.min(3, Filled - (Row - 1) * 3))
			local Char, Fg, CellBg = Pixels(Thirds.Up[Part + 1], Color, Bg)
			Gfx.Write(T, Column, Y + Half - Row, Char, Fg, CellBg)
			Char, Fg, CellBg = Pixels(Thirds.Down[Part + 1], Color, Bg)
			Gfx.Write(T, Column, Y + H - Half + Row - 1, Char, Fg, CellBg)
		end
		if (H % 2 == 1) then
			Gfx.Write(T, Column, Y + Half, (Filled > 0) and " " or "\140", Th.Border, (Filled > 0) and Color or Bg)
		end
	end
end

-- An oscilloscope trace of the samples playing now, joined into a line at 2x3 pixels per cell.
local function DrawWave(T, Th, X, Y, W, H)
	local PixelW, PixelH = W * 2, H * 3
	local Lit = {}
	local Wave = Visual.Wave
	local Previous
	for Pixel = 1, PixelW do
		local Value = 0
		if (Wave) then
			Value = Wave.Samples[Wave.Offset + math.floor((Pixel - 1) * Visual.Window / PixelW)] or 0
		end
		local Height = math.max(1, math.min(PixelH, math.floor((.5 - Value / 256) * (PixelH - 1) + 1.5)))
		local From, To = Height, Height
		if (Previous) then
			From, To = math.min(Previous, Height), math.max(Previous, Height)
		end
		for PY = From, To do
			Lit[(PY - 1) * PixelW + Pixel] = true
		end
		Previous = Height
	end
	for Row = 1, H do
		for Column = 1, W do
			local Bits = 0
			for SubY = 0, 2 do
				for SubX = 0, 1 do
					if (Lit[((Row - 1) * 3 + SubY) * PixelW + (Column - 1) * 2 + SubX + 1]) then
						Bits = Bits + 2 ^ (SubY * 2 + SubX)
					end
				end
			end
			local Char, Fg, CellBg = Pixels(Bits, Wave and Th.Accent or Th.Border, Th.WindowBg)
			Gfx.Write(T, X + Column - 1, Y + Row - 1, Char, Fg, CellBg)
		end
	end
end

local Drawers = { DrawBars, DrawMirror, DrawWave }

local function Visualizer(Y, H)
	local Mode = Library.Visual or 1
	Page:Add(Ui.Tabs.new({
		X = 1, Y = Y, W = Page.W, Items = Visual.Modes, Selected = Mode,
		OnChange = function(_, Index)
			Library.Visual = Index
			SaveLibrary()
			Build()
		end
	}))
	Visual.Wanted = math.max(4, math.min(24, math.floor(Page.W / 2)))
	Page:Add(Ui.Canvas.new({
		X = 1, Y = Y + 1, W = Page.W, H = H - 1,
		OnDraw = function(Self, T, Th)
			if (Visual.Count ~= Visual.Wanted) then BuildBands(Visual.Wanted) end
			Drawers[Mode](T, Th, Self.X, Self.Y, Self.W, Self.H)
			if (Player.State == "stopped" or #Speakers() == 0) then
				Gfx.Center(T, Self.Y + math.floor(Self.H / 2) - 1, (#Speakers() == 0) and "Attach a speaker to play music" or "\14 bTunes", Th.SubText, Th.WindowBg, Self.X, Self.W)
			end
		end,
		OnEvent = function(_, Name)
			if (Name ~= "mouse_click") then return false end
			Library.Visual = Mode % #Visual.Modes + 1
			SaveLibrary()
			Build()
			return true
		end
	}))
end

local function BuildAdd(Y)
	local FieldW = Page.W - 9
	Page:Add(Ui.Label.new({ X = 2, Y = Y, Text = "Name" }))
	local Name = Page:Add(Ui.Input.new({ X = 8, Y = Y, W = FieldW, Placeholder = "Track name" }))
	Page:Add(Ui.Label.new({ X = 2, Y = Y + 2, Text = "URL" }))
	local Url = Page:Add(Ui.Input.new({ X = 8, Y = Y + 2, W = FieldW, Placeholder = "YouTube or .dfpwm link" }))
	Page:Add(Ui.Label.new({ X = 2, Y = Y + 4, W = Page.W - 2, H = 2, Fg = "SubText", Text = "Paste a YouTube video or a link to DFPWM audio. Playlists open in Search." }))
	local function Track()
		local Link = Url.Value:gsub("^%s+", ""):gsub("%s+$", "")
		if (not Link:match("^https?://")) then
			Ui.Alert("bTunes", "Enter an http(s) link.")
			return nil
		end
		if (IsYouTubePlaylist(Link)) then
			Tab = 2
			RunSearch(Link)
			return nil
		end
		local ID = YouTubeID(Link)
		if (ID) then
			if (#Name.Value > 0) then return { Name = Name.Value, ID = ID } end
			local Entry = { Name = "YouTube " .. ID, ID = ID }
			LookupTitle(Entry)
			return Entry
		end
		local Title = (#Name.Value > 0) and Name.Value or (Link:match("([^/]+)%.%w+$") or Link)
		return { Name = Title, Url = Link }
	end
	Page:Add(Ui.Button.new({ X = 2, Y = Y + 7, Text = " Play Now ", OnClick = function()
		local Entry = Track()
		if (Entry) then PlayList({ Entry }, 1) end
	end }))
	Page:Add(Ui.Button.new({ X = 14, Y = Y + 7, Text = " Add to Library ", Style = "primary", OnClick = function()
		local Entry = Track()
		if (not Entry) then return end
		table.insert(Library.Tracks, Entry)
		SaveLibrary()
		Name:SetValue("")
		Url:SetValue("")
		Tab = 1
		Build()
	end }))
	Page:Add(Ui.Button.new({ X = math.max(32, Page.W - 8), Y = Y + 7, Text = " Server ", OnClick = function()
		local Value = Ui.Prompt("YouTube Server", "Streaming server URL:", Server())
		if (not Value) then return end
		Value = Value:gsub("^%s+", ""):gsub("%s+$", "")
		Library.Server = (#Value > 0 and Value ~= DefaultServer) and Value or nil
		SaveLibrary()
	end }))
	Page:SetFocus(Url)
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Page:Add(Ui.Tabs.new({
		X = 1, Y = 1, W = W, Items = { "Library", "Search", "Files", "Add", "Visual" }, Selected = Tab,
		OnChange = function(_, Index)
			Tab = Index
			Build()
		end
	}))
	local BodyH = H - 4
	if (Tab == 1) then
		TrackList(2, BodyH, Library.Tracks, true)
	elseif (Tab == 2) then
		BuildSearch(2, BodyH)
	elseif (Tab == 3) then
		local Files = LocalFiles()
		TrackList(2, BodyH - 1, Files, false)
		Page:Add(Ui.Button.new({ X = W - 9, Y = H - 3, W = 9, Text = "Open...", OnClick = function()
			local Path = Ui.PickFile({ Dir = "/home/Music", Extension = ".dfpwm" })
			if (Path) then PlayList({ { Name = fs.getName(Path), Path = Path } }, 1) end
		end }))
	elseif (Tab == 4) then
		BuildAdd(3)
	else
		Visualizer(2, BodyH)
	end
	NowPlaying(H - 2)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A, B)
	if (Name == "speaker_audio_empty") then
		if (Player.State == "playing") then Feed() end
		return false
	elseif (Name == "http_success" and A == Player.RequestUrl) then
		Player.RequestUrl = nil
		local Headers = B.getResponseHeaders and B.getResponseHeaders() or {}
		StartStream(B, tonumber(Headers["Content-Length"] or Headers["content-length"] or 0))
		return true
	elseif (Name == "http_failure" and A == Player.RequestUrl) then
		Player.RequestUrl = nil
		Player.State = "stopped"
		Player.Error = "Could not load track"
		return true
	elseif ((Name == "http_success" or Name == "http_failure") and Lookups[A]) then
		local Track = Lookups[A]
		Lookups[A] = nil
		if (Name == "http_success") then
			LookupDone(Track, B)
			Build()
		end
		return true
	elseif (Name == "http_success" and A == Search.RequestUrl) then
		Search.RequestUrl = nil
		SearchDone(B)
		if (Tab == 2) then Build() end
		return true
	elseif (Name == "http_failure" and A == Search.RequestUrl) then
		Search.RequestUrl = nil
		Search.State = "idle"
		Search.Error = "Search failed: " .. tostring(B or "no connection")
		if (Tab == 2) then Build() end
		return true
	elseif (Name == "peripheral" or Name == "peripheral_detach" or Name == "disk" or Name == "disk_eject") then
		if (Tab == 3) then Build() end
		return true
	elseif (Name == "blockos_open" and A) then
		PlayList({ { Name = fs.getName(A), Path = A } }, 1)
		return true
	elseif (Name == "key" and A == keys.space and not (Page.Focus and Page.Focus.Value)) then
		TogglePause()
		return true
	end
	return false
end

function Page:OnTerminate()
	Stop()
	self:Stop()
end

Page:SetInterval(.25, function()
	return Player.State ~= "stopped"
end)

Page:SetInterval(.1, function()
	return Tab == 5 and Analyze()
end)

if (Args[1] and fs.exists(Args[1])) then
	PlayList({ { Name = fs.getName(Args[1]), Path = Args[1] } }, 1)
end
Page:Run()
Stop()
