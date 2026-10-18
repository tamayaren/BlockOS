-- Network: finds nearby BlockOS computers over rednet and places them on a map using GPS.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Presence = BlockOS.Require("presence")

local Page = Ui.Page.new()
local Settings = Config.Settings()

local ScanSeconds = 3
local RescanSeconds = 30
local RelocateSeconds = 60
local Scales = { 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }
-- Terminal cells are about one and a half times taller than they are wide.
local CellAspect = 1.5

local State = {
	Computers = {},
	Self = nil,
	Status = "idle",
	Message = nil,
	Selected = nil,
	Scale = nil,
	ScanTimer = nil
}
local Markers = {}
local Build

local function Distance(Entry)
	if (not (State.Self and Entry.Position)) then return math.huge end
	return (Presence.Bearing(State.Self, Entry.Position))
end

local function Sorted()
	local List = {}
	for _, Entry in pairs(State.Computers) do
		table.insert(List, Entry)
	end
	table.sort(List, function(A, B)
		local DA, DB = Distance(A), Distance(B)
		if (DA ~= DB) then return DA < DB end
		return A.ID < B.ID
	end)
	return List
end

local function FormatDistance(Blocks)
	if (Blocks == math.huge) then return "?" end
	if (Blocks < 1000) then return string.format("%dm", math.floor(Blocks + .5)) end
	return string.format("%.1fkm", Blocks / 1000)
end

local function Scan()
	if (State.Status ~= "idle") then return end
	if (not Presence.OpenModems()) then
		State.Message = "No modem attached"
		Build()
		return
	end
	State.Message = nil
	if (not Presence.LocatedAt or os.clock() - Presence.LocatedAt > RelocateSeconds) then
		State.Status = "locating"
		Page:Draw()
		Presence.Locate(2)
	end
	State.Self = Presence.Position
	State.Computers = {}
	State.Status = "scanning"
	Presence.Scan()
	State.ScanTimer = os.startTimer(ScanSeconds)
	Build()
end

local function StatusText()
	if (State.Status == "locating") then return "Locating with GPS..." end
	if (State.Status == "scanning") then return "Scanning..." end
	if (State.Message) then return State.Message end
	local Count = 0
	for _ in pairs(State.Computers) do Count = Count + 1 end
	local Text = (Count == 1) and "1 computer nearby" or (Count .. " computers nearby")
	if (State.Self) then
		return Text .. string.format(" \7 you %d, %d, %d", State.Self.X, State.Self.Y, State.Self.Z)
	end
	return Text .. " \7 no GPS"
end

local function DetailText()
	local Entry = State.Selected and State.Computers[State.Selected]
	if (not Entry) then
		return Settings.NetworkVisible ~= false and "Select a computer for details." or "This computer is hidden from others."
	end
	local Parts = { "#" .. Entry.ID .. " " .. Presence.Name(Entry) }
	if (Entry.User) then table.insert(Parts, Entry.User) end
	if (State.Self and Entry.Position) then
		local Blocks, Direction = Presence.Bearing(State.Self, Entry.Position)
		table.insert(Parts, FormatDistance(Blocks) .. " " .. Direction)
		local Rise = Entry.Position.Y - State.Self.Y
		table.insert(Parts, "y" .. ((Rise >= 0) and "+" or "") .. Rise)
	elseif (Entry.Position) then
		table.insert(Parts, string.format("%d, %d, %d", Entry.Position.X, Entry.Position.Y, Entry.Position.Z))
	else
		table.insert(Parts, "no GPS")
	end
	return table.concat(Parts, " \7 ")
end

-- The point the map is centred on: this computer, or the middle of everyone else.
local function MapCentre()
	if (State.Self) then return State.Self end
	local SumX, SumZ, Count = 0, 0, 0
	for _, Entry in pairs(State.Computers) do
		if (Entry.Position) then
			SumX = SumX + Entry.Position.X
			SumZ = SumZ + Entry.Position.Z
			Count = Count + 1
		end
	end
	if (Count == 0) then return nil end
	return { X = SumX / Count, Y = 0, Z = SumZ / Count }
end

local function FitScale(Centre, W, H)
	local Needed = 1
	for _, Entry in pairs(State.Computers) do
		if (Entry.Position) then
			local DX = math.abs(Entry.Position.X - Centre.X) / math.max(1, W / 2 - 2)
			local DZ = math.abs(Entry.Position.Z - Centre.Z) / math.max(1, (H / 2 - 1) * CellAspect)
			Needed = math.max(Needed, DX, DZ)
		end
	end
	for _, Scale in ipairs(Scales) do
		if (Scale >= Needed) then return Scale end
	end
	return Scales[#Scales]
end

local function Zoom(Step)
	local Current = State.Scale or State.FittedScale or 1
	local Index = 1
	for Position, Scale in ipairs(Scales) do
		if (Scale <= Current) then Index = Position end
	end
	State.Scale = Scales[math.max(1, math.min(#Scales, Index + Step))]
end

local function DrawMap(Self, T, Th)
	local W, H = Self.W, Self.H
	Gfx.Fill(T, Self.X, Self.Y, W, H, Th.Panel)
	Markers = {}
	local Centre = MapCentre()
	if (not Centre) then
		local Hint = "No GPS signal. Build a GPS cluster (four computers running gps host) to see where everyone is."
		if (State.Message) then
			Hint = "Attach a wireless or ender modem to find nearby computers."
		end
		local Lines = Gfx.Wrap(Hint, W - 2)
		local Top = Self.Y + math.max(0, math.floor((H - #Lines) / 2))
		for Row, Line in ipairs(Lines) do
			if (Top + Row - 1 < Self.Y + H) then
				Gfx.Center(T, Top + Row - 1, Line, Th.SubText, Th.Panel, Self.X, W)
			end
		end
		return
	end
	State.FittedScale = FitScale(Centre, W, H)
	local Scale = State.Scale or State.FittedScale
	local MidX = Self.X + math.floor(W / 2)
	local MidY = Self.Y + math.floor(H / 2)
	for Row = 0, H - 1 do
		for Column = 0, W - 1 do
			if ((Self.X + Column - MidX) % 6 == 0 and (Self.Y + Row - MidY) % 3 == 0) then
				Gfx.Write(T, Self.X + Column, Self.Y + Row, "+", Th.Border, Th.Panel)
			end
		end
	end
	Gfx.Write(T, Self.X, Self.Y, "\24N", Th.SubText, Th.Panel)
	local Legend = "\140\140\140\140\140\140 " .. FormatDistance(Scale * 6)
	Gfx.Write(T, Self.X, Self.Y + H - 1, Legend, Th.SubText, Th.Panel)

	local function Plot(Position, Char, Fg, Bg, Label, ID)
		local X = MidX + math.floor((Position.X - Centre.X) / Scale + .5)
		local Y = MidY + math.floor((Position.Z - Centre.Z) / (Scale * CellAspect) + .5)
		local Outside = X < Self.X or X >= Self.X + W or Y < Self.Y or Y >= Self.Y + H
		X = math.max(Self.X, math.min(Self.X + W - 1, X))
		Y = math.max(Self.Y, math.min(Self.Y + H - 1, Y))
		Gfx.Write(T, X, Y, Outside and "\4" or Char, Outside and Th.SubText or Fg, Bg or Th.Panel)
		if (Label and X + 2 + #Label <= Self.X + W) then
			Gfx.Write(T, X + 1, Y, " " .. Label, Th.SubText, Th.Panel)
		end
		if (ID) then table.insert(Markers, { X = X, Y = Y, ID = ID }) end
	end

	for _, Entry in ipairs(Sorted()) do
		if (Entry.Position) then
			local Selected = Entry.ID == State.Selected
			Plot(Entry.Position, Entry.Turtle and "T" or "\7", Selected and Th.AccentFg or Th.Text, Selected and Th.Accent or nil, Gfx.Truncate(Presence.Name(Entry), 10), Entry.ID)
		end
	end
	if (State.Self) then
		Plot(State.Self, "\2", Th.Accent, nil, "You")
	end
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	Page:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
	Page:Add(Ui.Button.new({ X = 1, Y = 1, W = 6, Text = "Scan", Style = "primary", OnClick = Scan }))
	Page:Add(Ui.Label.new({ X = 8, Y = 1, W = W - 14, Text = StatusText, Fg = "SubText", Bg = "Panel" }))
	Page:Add(Ui.Button.new({ X = W - 5, Y = 1, W = 3, Text = "-", Bg = "Panel", OnClick = function() Zoom(1) end }))
	Page:Add(Ui.Button.new({ X = W - 2, Y = 1, W = 3, Text = "+", Bg = "Panel", OnClick = function() Zoom(-1) end }))

	local BodyH = math.max(3, H - 3)
	local ListW = (W >= 38) and 16 or 0
	local MapW = W - ((ListW > 0) and ListW + 1 or 0)
	Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = MapW, H = BodyH,
		OnDraw = DrawMap,
		OnEvent = function(Self, Name, A, B, C)
			if (Name == "mouse_click") then
				for _, Marker in ipairs(Markers) do
					if (math.abs(Marker.X - B) <= 1 and Marker.Y == C) then
						State.Selected = Marker.ID
						Build()
						return true
					end
				end
			elseif (Name == "mouse_scroll") then
				Zoom(A)
				return true
			end
			return false
		end
	}))
	if (ListW > 0) then
		local Items = {}
		local Selected = 0
		for Index, Entry in ipairs(Sorted()) do
			table.insert(Items, {
				Text = Presence.Name(Entry), ID = Entry.ID,
				Icon = Entry.Turtle and "T" or "\7", IconFg = Entry.Position and "Accent" or "SubText",
				Right = FormatDistance(Distance(Entry))
			})
			if (Entry.ID == State.Selected) then Selected = Index end
		end
		local List = Page:Add(Ui.List.new({ X = MapW + 2, Y = 2, W = ListW, H = BodyH, Items = Items, Bg = "Panel" }))
		List.Selected = Selected
		List.OnSelect = function(_, _, Item)
			if (Item) then State.Selected = Item.ID end
		end
		if (#Items == 0 and State.Status == "idle") then
			Page:Add(Ui.Label.new({ X = MapW + 3, Y = 3, W = ListW - 2, H = 4, Fg = "SubText", Bg = "Panel", Text = "No other computers answered." }))
		end
	end

	Page:Add(Ui.Label.new({ X = 1, Y = H - 1, W = W, Text = DetailText }))
	Page:Add(Ui.Toggle.new({
		X = 1, Y = H, Value = Settings.NetworkVisible ~= false,
		OnChange = function(_, Value)
			Settings.NetworkVisible = Value
			Config.Save("settings")
		end
	}))
	Page:Add(Ui.Label.new({ X = 6, Y = H, W = W - 5, Text = "Let other computers find this one", Fg = "SubText" }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A, B, C)
	if (Name == "rednet_message" and C == Presence.Protocol) then
		local Entry = Presence.Parse(A, B)
		if (not Entry or A == os.getComputerID()) then return false end
		State.Computers[Entry.ID] = Entry
		Build()
		return true
	elseif (Name == "timer" and A == State.ScanTimer) then
		State.ScanTimer = nil
		State.Status = "idle"
		Build()
		return true
	elseif (Name == "peripheral" or Name == "peripheral_detach") then
		Build()
		return true
	end
	return false
end

Page:SetInterval(RescanSeconds, function()
	Scan()
	return false
end)

Page:Resize()
Scan()
Page:Run()
