-- Turtles: discover, pair with and remote-control turtles running the BlockOS agent.
-- On a turtle it can also drive the local turtle directly.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Protocol = "blockos_turtle"
local DataPath = "/blockos/data/turtles.dat"

local Page = Ui.Page.new()
local Known = Config.Read(DataPath) or {}
local Selected = nil
local Message = ""
local Seq = 0
local Build

local KeyActions = {
	[keys.w] = "forward", [keys.s] = "back", [keys.a] = "turnLeft", [keys.d] = "turnRight",
	[keys.r] = "up", [keys.f] = "down", [keys.q] = "dig", [keys.e] = "place", [keys.x] = "attack"
}

local function SaveKnown()
	local Stored = {}
	for ID, Entry in pairs(Known) do
		if (ID ~= "local") then
			Stored[ID] = { Label = Entry.Label }
		end
	end
	Config.Write(DataPath, Stored)
end

local function OpenModems()
	local Any = false
	for _, Side in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Side) == "modem") then
			if (not rednet.isOpen(Side)) then rednet.open(Side) end
			Any = true
		end
	end
	return Any
end

local function LocalStatus()
	local Inventory = {}
	for Slot = 1, 16 do
		local Detail = turtle.getItemDetail(Slot)
		if (Detail) then Inventory[Slot] = { Name = Detail.name, Count = Detail.count } end
	end
	return {
		Label = os.getComputerLabel() or "This turtle",
		ID = os.getComputerID(),
		Fuel = turtle.getFuelLevel(),
		FuelLimit = turtle.getFuelLimit(),
		Slot = turtle.getSelectedSlot(),
		Inventory = Inventory
	}
end

local function LocalRequest(Cmd, Args)
	local Reply = {}
	if (Cmd == "action") then
		local Fn = turtle[Args.Name]
		local Ok, Result, Detail = pcall(Fn)
		Reply.Ok = Ok and Result ~= false
		if (not Reply.Ok) then Reply.Error = tostring(Detail or Result or "failed") end
	elseif (Cmd == "select") then
		Reply.Ok = turtle.select(Args.Slot)
	elseif (Cmd == "refuel") then
		Reply.Ok = false
		for Slot = 1, 16 do
			if (turtle.getItemCount(Slot) > 0) then
				turtle.select(Slot)
				Reply.Ok = turtle.refuel() or Reply.Ok
			end
		end
		if (not Reply.Ok) then Reply.Error = "Nothing to burn" end
	elseif (Cmd == "run") then
		local Words = {}
		for Word in tostring(Args.Command):gmatch("%S+") do table.insert(Words, Word) end
		local Program = table.remove(Words, 1)
		Reply.Ok = BlockOS.Launch(Program or "", Words, { Hold = true }) ~= nil
		if (not Reply.Ok) then Reply.Error = "Program not found" end
	elseif (Cmd == "locate") then
		local X, Y, Z = gps.locate(1)
		Reply.Ok = X ~= nil
		Reply.Error = X and nil or "No GPS signal"
		if (X) then Known["local"].Position = { X = X, Y = Y, Z = Z } end
	else
		Reply.Ok = true
	end
	Reply.Status = LocalStatus()
	return Reply
end

local function Request(ID, Cmd, Args, Retried)
	if (ID == "local") then
		local Reply = LocalRequest(Cmd, Args or {})
		Known["local"].Status = Reply.Status
		return Reply
	end
	if (not OpenModems()) then return nil, "No modem attached" end
	Seq = Seq + 1
	local Mine = Seq
	rednet.send(ID, { Cmd = Cmd, Args = Args or {}, Seq = Mine }, Protocol)
	local Deadline = os.clock() + 4
	while (os.clock() < Deadline) do
		local Sender, Reply = rednet.receive(Protocol, math.max(.05, Deadline - os.clock()))
		if (Sender == ID and type(Reply) == "table" and Reply.Re == Mine) then
			if (Reply.Status and Known[ID]) then
				Known[ID].Status = Reply.Status
				Known[ID].Label = Reply.Status.Label
			end
			if (Reply.Error == "pin" and not Retried) then
				local Pin = Ui.Prompt("Pair Turtle", "Enter the PIN shown on turtle #" .. ID .. ":", "")
				if (not Pin) then return nil, "Not paired" end
				local Paired = Request(ID, "pair", { Pin = Pin }, true)
				if (not Paired or not Paired.Ok) then return nil, Paired and Paired.Error or "Pairing failed" end
				return Request(ID, Cmd, Args, true)
			end
			return Reply
		end
	end
	return nil, "Turtle #" .. ID .. " did not respond"
end

local function Send(Cmd, Args)
	if (not Selected) then return end
	local Reply, Err = Request(Selected, Cmd, Args)
	if (not Reply) then
		Message = Err
	elseif (not Reply.Ok) then
		Message = tostring(Reply.Error or "Failed")
	else
		Message = (Cmd == "action" and Args.Name or Cmd) .. ": ok"
	end
	Page:Invalidate()
end

local function Scan()
	if (not OpenModems()) then
		Message = "Attach a modem to find turtles"
		return
	end
	Message = "Scanning..."
	Page:Draw()
	local IDs = { rednet.lookup(Protocol) }
	for _, ID in ipairs(IDs) do
		Known[ID] = Known[ID] or { Label = "turtle-" .. ID }
	end
	SaveKnown()
	Message = #IDs .. " turtle(s) found"
	Build()
end

local function Status()
	local Entry = Selected and Known[Selected]
	return Entry and Entry.Status
end

local function BuildControls(X, Y, W, H)
	Page:Add(Ui.Canvas.new({
		X = X, Y = Y, W = W, H = 2,
		OnDraw = function(Self, T, Th)
			local Info = Status()
			local Entry = Known[Selected]
			local Title = (Entry and Entry.Label or "?") .. ((Selected ~= "local") and (" #" .. tostring(Selected)) or "")
			Gfx.Write(T, Self.X, Self.Y, Gfx.Truncate(Title, Self.W), Th.Text, Th.WindowBg)
			if (not Info) then
				Gfx.Write(T, Self.X, Self.Y + 1, "Press Refresh to connect", Th.SubText, Th.WindowBg)
				return
			end
			local Fuel = Info.Fuel
			if (Fuel == "unlimited") then
				Gfx.Write(T, Self.X, Self.Y + 1, "Fuel: unlimited", Th.SubText, Th.WindowBg)
			else
				local BarW = Self.W - 6
				local Ratio = (tonumber(Info.FuelLimit) or 0) > 0 and math.min(1, Fuel / Info.FuelLimit) or 0
				Gfx.Write(T, Self.X, Self.Y + 1, "Fuel ", Th.SubText, Th.WindowBg)
				Gfx.Fill(T, Self.X + 5, Self.Y + 1, BarW, 1, Th.Border)
				Gfx.Fill(T, Self.X + 5, Self.Y + 1, math.max(Fuel > 0 and 1 or 0, math.floor(BarW * Ratio)), 1, (Ratio < .1) and colors.red or colors.orange)
				Gfx.Write(T, Self.X + 6, Self.Y + 1, tostring(Fuel), colors.black, (Ratio > .1) and colors.orange or Th.Border)
			end
		end
	}))
	Page:Add(Ui.Canvas.new({
		X = X, Y = Y + 3, W = 16, H = 4,
		OnDraw = function(Self, T, Th)
			local Info = Status()
			for Slot = 1, 16 do
				local Column = (Slot - 1) % 4
				local Row = math.floor((Slot - 1) / 4)
				local Item = Info and Info.Inventory and Info.Inventory[Slot]
				local Active = Info and Info.Slot == Slot
				local Bg = Active and Th.Accent or Th.Panel
				local Text = Item and tostring(Item.Count) or ""
				Gfx.Write(T, Self.X + Column * 4, Self.Y + Row, Gfx.Pad(Text, 3, "center"), Active and Th.AccentFg or Th.PanelFg, Bg)
			end
		end,
		OnEvent = function(Self, Name, Button, MX, MY)
			if (Name ~= "mouse_click") then return false end
			local Column = math.floor((MX - Self.X) / 4)
			local Row = MY - Self.Y
			local Slot = Row * 4 + Column + 1
			if (Slot >= 1 and Slot <= 16) then
				Send("select", { Slot = Slot })
				local Info = Status()
				local Item = Info and Info.Inventory and Info.Inventory[Slot]
				if (Item) then Message = "Slot " .. Slot .. ": " .. Item.Count .. "x " .. Item.Name:gsub("^minecraft:", "") end
			end
			return true
		end
	}))
	local PadX = X + 17
	local Pad = {
		{ { "Up", "up" }, { "\30", "forward" }, { "Dig", "dig" } },
		{ { "\17", "turnLeft" }, { "\31", "back" }, { "\16", "turnRight" } },
		{ { "Dn", "down" }, { "Plc", "place" }, { "Atk", "attack" } }
	}
	if (W >= 29) then
		for Row, Buttons in ipairs(Pad) do
			for Column, Entry in ipairs(Buttons) do
				local Action = Entry[2]
				Page:Add(Ui.Button.new({
					X = PadX + (Column - 1) * 4, Y = Y + 3 + Row - 1, W = 3, Text = Entry[1],
					Style = (Row == 1 and Column == 2) and "primary" or "default",
					OnClick = function() Send("action", { Name = Action }) end
				}))
			end
		end
	end
	local Row2 = Y + 8
	local Extra = {
		{ "\24Dig", "digUp" }, { "\25Dig", "digDown" }, { "\24Plc", "placeUp" }, { "\25Plc", "placeDown" }, { "Suck", "suck" }, { "Drop", "drop" }
	}
	local BX = X
	for _, Entry in ipairs(Extra) do
		if (BX + #Entry[1] + 1 <= X + W) then
			local Action = Entry[2]
			Page:Add(Ui.Button.new({ X = BX, Y = Row2, Text = Entry[1], W = #Entry[1] + 1, OnClick = function() Send("action", { Name = Action }) end }))
			BX = BX + #Entry[1] + 2
		end
	end
	local Bottom = Y + H - 1
	Page:Add(Ui.Button.new({ X = X, Y = Bottom, Text = " Refresh ", OnClick = function() Send("status") end }))
	Page:Add(Ui.Button.new({ X = X + 10, Y = Bottom, Text = " Fuel ", OnClick = function() Send("refuel") end }))
	Page:Add(Ui.Button.new({ X = X + 17, Y = Bottom, Text = " Run ", Style = "primary", OnClick = function()
		local Command = Ui.Prompt("Run on Turtle", "Program and arguments (e.g. excavate 3, tunnel 10):", "")
		if (Command and #Command > 0) then Send("run", { Command = Command }) end
	end }))
	if (X + 29 <= X + W) then
		Page:Add(Ui.Button.new({ X = X + 23, Y = Bottom, Text = " Stop ", Style = "danger", OnClick = function() Send("stop") end }))
	end
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local SideW = (W >= 40) and 14 or 0
	local Items = {}
	local Index = 0
	local IDs = {}
	for ID in pairs(Known) do
		if (ID ~= "local") then table.insert(IDs, ID) end
	end
	table.sort(IDs)
	if (Known["local"]) then table.insert(IDs, 1, "local") end
	for _, ID in ipairs(IDs) do
		local Entry = Known[ID]
		table.insert(Items, { Text = Entry.Label or tostring(ID), Icon = "\4", IconFg = colors.lime, ID = ID })
		if (ID == Selected) then Index = #Items end
	end
	local List = Page:Add(Ui.List.new({ X = 1, Y = 1, W = SideW, H = H - 2, Bg = "Panel", SingleClick = true, Focusable = false, Visible = SideW > 0 }))
	List:SetItems(Items)
	List.Selected = Index
	List.OnActivate = function(_, _, Item)
		Selected = Item.ID
		Message = ""
		Build()
		Send("status")
	end
	List.OnContext = function(_, _, Item, X, Y)
		if (not Item or Item.ID == "local") then return end
		local Choice = Ui.ContextMenu(X, Y, { "Forget" })
		if (Choice == 1) then
			Known[Item.ID] = nil
			if (Selected == Item.ID) then Selected = nil end
			SaveKnown()
			Build()
		end
	end
	Page:Add(Ui.Button.new({ X = 1, Y = H - 1, W = math.max(SideW, 1), Text = "Scan", Bg = "Panel", Visible = SideW > 0, OnClick = Scan }))
	local MainX = SideW + 2
	local MainW = W - SideW - 2
	if (SideW == 0) then
		Page:Add(Ui.Button.new({ X = 1, Y = 1, W = W, Text = "\31 " .. (Selected and Known[Selected] and Known[Selected].Label or "Choose a turtle"), Bg = "Panel", OnClick = function()
			local Names = { "Scan for turtles" }
			for _, Item in ipairs(Items) do table.insert(Names, Item.Text) end
			local Choice = Ui.Choose("Turtles", Names)
			if (Choice == 1) then
				Scan()
			elseif (Choice) then
				Selected = Items[Choice - 1].ID
				Build()
				Send("status")
			end
		end }))
	end
	local TopY = (SideW == 0) and 3 or 1
	if (Selected and Known[Selected]) then
		BuildControls(MainX, TopY, MainW, H - TopY - 1)
	else
		Page:Add(Ui.Label.new({
			X = MainX, Y = TopY + 1, W = MainW, H = 6, Fg = "SubText",
			Text = "Select a turtle, or press Scan.\n\nOn each turtle, install BlockOS and choose \"Turtle Agent\". Turtles show a PIN for pairing.\n\nKeys: WASD move, R/F up/down, Q dig, E place, X attack."
		}))
	end
	Page:Add(Ui.Label.new({ X = 1, Y = H, W = W, Bg = "Panel", Fg = "SubText", Text = function() return " " .. Message end }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name, A, B, C)
	if (Name == "key" and Selected and KeyActions[A]) then
		Send("action", { Name = KeyActions[A] })
		return true
	elseif (Name == "rednet_message" and C == Protocol and type(B) == "table" and B.Event == "job_done") then
		if (Known[A]) then Known[A].Status = B.Status end
		Message = "Turtle #" .. A .. " finished its job"
		BlockOS.Notify("Turtles", Message, { AppID = "turtles" })
		return true
	end
	return false
end

if (turtle) then
	Known["local"] = { Label = "This turtle", Status = LocalStatus() }
	Selected = "local"
end
Page:Run()
