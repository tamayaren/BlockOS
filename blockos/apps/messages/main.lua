-- Messages: Enchat-style chat rooms between BlockOS computers over rednet.
-- Rooms with a key are end-to-end encrypted; /dm opens a direct conversation.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Chat = BlockOS.Require("chat")

local Page = Ui.Page.new()
local ActiveID = nil
local Scroll = 0
local Rooms, Input, MessageView

local NickColors = { colors.red, colors.orange, colors.green, colors.cyan, colors.blue, colors.purple, colors.magenta, colors.brown }

local function NickColor(Nick)
	local Hash = 0
	for Index = 1, #Nick do
		Hash = (Hash * 17 + Nick:byte(Index)) % 251
	end
	return NickColors[Hash % #NickColors + 1]
end

local function Active()
	return ActiveID and Chat.Rooms[ActiveID]
end

local function RoomTitle(Room)
	if (Room.Target) then return "@" .. Room.Name:gsub("^@", "") end
	return "#" .. Room.Name
end

local function SetActive(ID)
	ActiveID = ID
	Scroll = 0
	local Room = Active()
	if (Room) then
		Room.Unread = 0
		BlockOS.SetTitle("Messages \7 " .. RoomTitle(Room))
	end
end

local function System(Text)
	local Room = Active()
	if (not Room) then return end
	table.insert(Room.Messages, { Kind = "system", Text = Text, Time = os.epoch("utc") })
end

local Refresh

local function JoinPrompt()
	local Name = Ui.Prompt("Join Room", "Room name:", "")
	if (not Name or #Name == 0) then return end
	Name = Name:gsub("^#", ""):gsub("%s+", "-"):lower()
	local Key = Ui.Prompt("Join Room", "Room key (leave empty for a public room):", "", "\7")
	if (Key == nil) then return end
	local Room = Chat.Join(Name, Key)
	SetActive(Room.ID)
	Refresh()
end

local Help = {
	"/join <room> [key]  join or create a room",
	"/leave              leave this room",
	"/nick <name>        change your nickname",
	"/me <action>        send an action",
	"/dm <computer id>   start a direct message",
	"/who                list people online",
	"/clear              clear this room's history"
}

local function RunCommand(Text)
	local Command, Rest = Text:match("^/(%S+)%s*(.*)$")
	Command = (Command or ""):lower()
	local Room = Active()
	if (Command == "join") then
		local Name, Key = Rest:match("^#?(%S+)%s*(.*)$")
		if (not Name) then
			JoinPrompt()
			return
		end
		local NewRoom = Chat.Join(Name:lower(), Key)
		SetActive(NewRoom.ID)
	elseif (Command == "leave") then
		if (Room) then
			Chat.Leave(Room.ID)
			SetActive(Chat.Order[1])
		end
	elseif (Command == "nick") then
		if (#Rest > 0) then
			Chat.SetNick(Rest:sub(1, 20))
			System("You are now known as " .. Rest:sub(1, 20))
			Chat.Presence()
		end
	elseif (Command == "me") then
		if (Room and #Rest > 0) then Chat.Send(Room.ID, Rest, "me") end
	elseif (Command == "dm") then
		local Target = tonumber(Rest)
		if (not Target or Target == os.getComputerID()) then
			System("Usage: /dm <computer id>")
			return
		end
		local NewRoom = Chat.Join("@" .. Target, nil, Target)
		SetActive(NewRoom.ID)
	elseif (Command == "who") then
		if (Room) then
			local Names = {}
			for _, User in ipairs(Chat.OnlineUsers(Room)) do
				table.insert(Names, User.Nick .. " (#" .. User.ID .. ")")
			end
			System((#Names > 0) and ("Online: " .. table.concat(Names, ", ")) or "Nobody else is here yet.")
		end
	elseif (Command == "clear") then
		if (Room) then
			Room.Messages = {}
			Chat.Save()
		end
	else
		for _, Line in ipairs(Help) do
			System(Line)
		end
	end
	Refresh()
end

local function Send(Text)
	Text = Text:gsub("^%s+", ""):gsub("%s+$", "")
	if (#Text == 0) then return end
	if (Text:sub(1, 1) == "/") then
		RunCommand(Text)
		return
	end
	local Room = Active()
	if (not Room) then return end
	local Ok, Err = Chat.Send(Room.ID, Text)
	if (not Ok) then
		System("Not sent: " .. tostring(Err))
	end
	Scroll = 0
	Refresh()
end

-- Builds wrapped display lines: each is a list of { Text, Color } segments.
local function RenderLines(Room, Width, Th)
	local Lines = {}
	for _, Message in ipairs(Room.Messages) do
		local Stamp = os.date("%H:%M", math.floor((Message.Time or 0) / 1000)) .. " "
		local Prefix, PrefixColor, Body, BodyColor
		if (Message.Kind == "system") then
			Prefix, PrefixColor, Body, BodyColor = "", Th.SubText, Message.Text, Th.SubText
		elseif (Message.Kind == "me") then
			Prefix, PrefixColor, Body, BodyColor = "* " .. Message.Nick .. " ", NickColor(Message.Nick), Message.Text, Th.Text
		else
			Prefix = Message.Nick .. ": "
			PrefixColor = Message.Self and Th.Accent or NickColor(Message.Nick)
			Body, BodyColor = Message.Text, Th.Text
		end
		if (Message.Failed) then
			Body = Body .. " (!)"
		end
		local Wrapped = Gfx.Wrap(Prefix .. Body, Width - #Stamp)
		for Index, Line in ipairs(Wrapped) do
			local Segments = { { Index == 1 and Stamp or string.rep(" ", #Stamp), Th.SubText } }
			if (Index == 1 and #Prefix > 0) then
				table.insert(Segments, { Line:sub(1, #Prefix), PrefixColor })
				table.insert(Segments, { Line:sub(#Prefix + 1), BodyColor })
			else
				table.insert(Segments, { Line, BodyColor })
			end
			table.insert(Lines, Segments)
		end
	end
	return Lines
end

function Refresh()
	local Items = {}
	local Selected = 0
	for Index, ID in ipairs(Chat.Order) do
		local Room = Chat.Rooms[ID]
		table.insert(Items, {
			Text = RoomTitle(Room),
			Icon = Room.Key and "\4" or " ",
			IconFg = colors.orange,
			Right = (Room.Unread > 0) and tostring(Room.Unread) or "",
			ID = ID
		})
		if (ID == ActiveID) then Selected = Index end
	end
	if (Rooms) then
		Rooms:SetItems(Items, true)
		Rooms.Selected = Selected
	end
	Page:Invalidate()
end

function Page:OnLayout(W, H)
	self:Clear()
	local SideW = (W >= 36) and 13 or 0
	Rooms = self:Add(Ui.List.new({ X = 1, Y = 1, W = SideW, H = H - 1, Bg = "Panel", SingleClick = true, Focusable = false, Visible = SideW > 0 }))
	Rooms.OnActivate = function(_, _, Item)
		SetActive(Item.ID)
		Refresh()
	end
	Rooms.OnContext = function(_, _, Item, X, Y)
		local Options = { "Join Room..." }
		if (Item) then
			table.insert(Options, "Leave " .. Item.Text)
		end
		local Choice = Ui.ContextMenu(X, Y, Options)
		if (Choice == 1) then
			JoinPrompt()
		elseif (Choice == 2) then
			Chat.Leave(Item.ID)
			SetActive(Chat.Order[1])
			Refresh()
		end
	end
	self:Add(Ui.Button.new({ X = 1, Y = H, W = math.max(SideW, 1), Text = "+ Join", Bg = "Panel", Visible = SideW > 0, OnClick = JoinPrompt }))
	local MainX = SideW + 1
	local MainW = W - SideW
	self:Add(Ui.Canvas.new({
		X = MainX, Y = 1, W = MainW, H = 1,
		OnDraw = function(Self, T, Th)
			local Room = Active()
			Gfx.Fill(T, Self.X, Self.Y, Self.W, 1, Th.Panel)
			if (not Room) then return end
			local Online = #Chat.OnlineUsers(Room)
			local Title = " " .. RoomTitle(Room) .. (Room.Key and " \4" or "")
			local Info = Room.Target and "direct " or (Online .. " online ")
			Gfx.Write(T, Self.X, Self.Y, Gfx.Truncate(Title, Self.W - #Info), Th.PanelFg, Th.Panel)
			Gfx.Write(T, Self.X + Self.W - #Info, Self.Y, Info, Th.SubText, Th.Panel)
		end,
		OnEvent = function(_, Name)
			if (Name ~= "mouse_click" or SideW > 0) then return false end
			local Names = {}
			for _, ID in ipairs(Chat.Order) do
				table.insert(Names, RoomTitle(Chat.Rooms[ID]))
			end
			table.insert(Names, "+ Join Room...")
			local Index = Ui.Choose("Rooms", Names)
			if (Index == #Names) then
				JoinPrompt()
			elseif (Index) then
				SetActive(Chat.Order[Index])
				Refresh()
			end
			return true
		end
	}))
	MessageView = self:Add(Ui.Canvas.new({
		X = MainX, Y = 2, W = MainW, H = H - 2,
		OnDraw = function(Self, T, Th)
			local Room = Active()
			if (not Chat.OpenModems()) then
				Gfx.Write(T, Self.X + 1, Self.Y, Gfx.Truncate("No modem attached. Attach a wireless or ender modem.", Self.W - 2), colors.red, Th.WindowBg)
			end
			if (not Room) then return end
			local Lines = RenderLines(Room, Self.W - 1, Th)
			local MaxScroll = math.max(0, #Lines - Self.H)
			Scroll = math.min(Scroll, MaxScroll)
			local First = #Lines - Self.H - Scroll + 1
			for Row = 1, Self.H do
				local Segments = Lines[First + Row - 1]
				if (Segments) then
					local X = Self.X + 1
					for _, Segment in ipairs(Segments) do
						Gfx.Write(T, X, Self.Y + Row - 1, Segment[1], Segment[2], Th.WindowBg)
						X = X + #Segment[1]
					end
				end
			end
			if (#Room.Messages == 0) then
				Gfx.Center(T, Self.Y + math.floor(Self.H / 2), "Say hello to " .. RoomTitle(Room), Th.SubText, Th.WindowBg, Self.X, Self.W)
			end
		end,
		OnEvent = function(_, Name, A)
			if (Name == "mouse_scroll") then
				Scroll = math.max(0, Scroll - A * 2)
				return true
			end
			return false
		end
	}))
	Input = self:Add(Ui.Input.new({ X = MainX, Y = H, W = MainW, Placeholder = "Message (/help for commands)", MaxLength = 400 }))
	Input.OnSubmit = function(Self, Value)
		Self:SetValue("")
		Send(Value)
	end
	self:SetFocus(Input)
	Refresh()
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_chat") then
		local Room = Active()
		if (Room and A == Room.ID and BlockOS.IsFocused()) then
			Room.Unread = 0
		end
		Refresh()
		return true
	elseif (Name == "peripheral" or Name == "peripheral_detach") then
		return true
	elseif (Name == "key" and (A == keys.pageUp or A == keys.pageDown)) then
		Scroll = math.max(0, Scroll + ((A == keys.pageUp) and 5 or -5))
		return true
	end
	return false
end

Chat.Load()
Chat.OpenModems()
if (not Chat.Nick) then
	local Nick = Ui.Prompt("Welcome to Messages", "Choose a nickname others will see:", Chat.GetNick())
	if (Nick and #Nick > 0) then
		Chat.SetNick(Nick:sub(1, 20))
	else
		Chat.SetNick(Chat.GetNick())
	end
end
SetActive(Chat.Order[1])
Page:SetInterval(15, function() return true end)
Page:Run()
