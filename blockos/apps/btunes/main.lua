-- bTunes: plays YouTube, DFPWM links and files on disk through every attached speaker.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Dfpwm = require("cc.audio.dfpwm")

local Args = { ... }

local LibraryPath = "/blockos/data/music.dat"
local ChunkSize = 16 * 1024
local BytesPerSecond = 6000
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
	Levels = {},
	Tick = 0,
	Error = nil
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

local function UpdateLevels(Buffer)
	local Segments = 32
	local Size = math.max(1, math.floor(#Buffer / Segments))
	Player.Levels = {}
	for Segment = 0, Segments - 1 do
		local Sum = 0
		local Count = 0
		for Index = Segment * Size + 1, math.min(#Buffer, (Segment + 1) * Size), 64 do
			Sum = Sum + math.abs(Buffer[Index])
			Count = Count + 1
		end
		table.insert(Player.Levels, Count > 0 and math.min(1, (Sum / Count) / 64) or 0)
	end
	Player.Tick = 0
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
			UpdateLevels(Player.Buffer)
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

local function Visualizer(Y, H)
	Page:Add(Ui.Canvas.new({
		X = 1, Y = Y, W = Page.W, H = H,
		OnDraw = function(Self, T, Th)
			local Count = #Player.Levels
			for Column = 0, Self.W - 1 do
				local Level = 0
				if (Count > 0 and Player.State == "playing") then
					local Index = (Column + Player.Tick) % Count + 1
					Level = Player.Levels[Index] * (.6 + .4 * math.abs(math.sin(Column * .7 + Player.Tick)))
				end
				local Height = math.floor(Level * Self.H + .5)
				for Row = 1, Height do
					local Color = (Row > Self.H * .7) and colors.red or ((Row > Self.H * .4) and colors.orange or Th.Accent)
					Gfx.Write(T, Self.X + Column, Self.Y + Self.H - Row, " ", Th.Text, Color)
				end
			end
			if (Count == 0 or Player.State ~= "playing") then
				Gfx.Center(T, Self.Y + math.floor(Self.H / 2), (#Speakers() == 0) and "Attach a speaker to play music" or "\14 bTunes", Th.SubText, Th.WindowBg, Self.X, Self.W)
			end
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
	Player.Tick = Player.Tick + 1
	return Player.State ~= "stopped" or Tab == 5
end)

if (Args[1] and fs.exists(Args[1])) then
	PlayList({ { Name = fs.getName(Args[1]), Path = Args[1] } }, 1)
end
Page:Run()
Stop()
