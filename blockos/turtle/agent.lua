-- BlockOS Turtle Agent: lets paired BlockOS computers drive this turtle over rednet.
-- Standalone so it also runs on basic turtles that only have the agent installed.

local Protocol = "blockos_turtle"
local ConfigPath = "/blockos/data/agent.dat"
-- Scripts sent from the Turtles app are saved here before they run.
local ScriptDir = "/blockos/data/scripts"

local function ReadConfig()
	if (not fs.exists(ConfigPath)) then return {} end
	local Handle = fs.open(ConfigPath, "r")
	local Data = textutils.unserialise(Handle.readAll() or "") or {}
	Handle.close()
	return Data
end

local function WriteConfig(Data)
	local Handle = fs.open(ConfigPath, "w")
	Handle.write(textutils.serialise(Data))
	Handle.close()
end

local Config = ReadConfig()
Config.Trusted = Config.Trusted or {}
if (not Config.Pin) then
	Config.Pin = tostring(math.random(1000, 9999))
	WriteConfig(Config)
end

local Color = term.isColor()
local Job = nil
local LastAction = "Waiting for commands"
local Controller = nil
local Position = nil

local Actions = {
	forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down,
	turnLeft = turtle.turnLeft, turnRight = turtle.turnRight,
	dig = turtle.dig, digUp = turtle.digUp, digDown = turtle.digDown,
	place = turtle.place, placeUp = turtle.placeUp, placeDown = turtle.placeDown,
	attack = turtle.attack, attackUp = turtle.attackUp, attackDown = turtle.attackDown,
	suck = turtle.suck, suckUp = turtle.suckUp, suckDown = turtle.suckDown,
	drop = turtle.drop, dropUp = turtle.dropUp, dropDown = turtle.dropDown,
	detect = turtle.detect, detectUp = turtle.detectUp, detectDown = turtle.detectDown,
	inspect = turtle.inspect, inspectUp = turtle.inspectUp, inspectDown = turtle.inspectDown
}

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

local function SetColor(Fg, Bg)
	if (not Color) then return end
	if (Fg) then term.setTextColor(Fg) end
	if (Bg) then term.setBackgroundColor(Bg) end
end

local function Draw()
	if (Job) then return end
	local W, H = term.getSize()
	SetColor(colors.white, colors.black)
	term.clear()
	SetColor(colors.black, colors.lime)
	term.setCursorPos(1, 1)
	term.clearLine()
	term.write(" BlockOS Turtle Agent")
	SetColor(colors.white, colors.black)
	local Fuel = turtle.getFuelLevel()
	local Lines = {
		"Label:  " .. (os.getComputerLabel() or "(none)"),
		"ID:     " .. os.getComputerID(),
		"Fuel:   " .. tostring(Fuel) .. (Fuel ~= "unlimited" and (" / " .. tostring(turtle.getFuelLimit())) or ""),
		"Slot:   " .. turtle.getSelectedSlot(),
		"Pair PIN: " .. Config.Pin,
		"",
		"Last:   " .. LastAction
	}
	for Index, Line in ipairs(Lines) do
		term.setCursorPos(2, Index + 2)
		term.write(Line:sub(1, W - 2))
	end
	SetColor(colors.gray)
	term.setCursorPos(2, H)
	term.write((OpenModems() and "Listening on rednet" or "No modem attached!"):sub(1, W - 2))
end

local function Inventory()
	local Items = {}
	for Slot = 1, 16 do
		local Detail = turtle.getItemDetail(Slot)
		if (Detail) then
			Items[Slot] = { Name = Detail.name, Count = Detail.count }
		end
	end
	return Items
end

local function Status()
	return {
		Label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
		ID = os.getComputerID(),
		Fuel = turtle.getFuelLevel(),
		FuelLimit = turtle.getFuelLimit(),
		Slot = turtle.getSelectedSlot(),
		Inventory = Inventory(),
		Position = Position,
		Busy = Job and Job.Name or nil,
		Last = LastAction
	}
end

local function StartJob(Command, Name)
	Job = {
		Name = Name or Command,
		Co = coroutine.create(function()
			SetColor(colors.white, colors.black)
			term.clear()
			term.setCursorPos(1, 1)
			print("Running: " .. Command)
			shell.run(Command)
		end)
	}
	LastAction = "Job: " .. Job.Name
	local Ok, Filter = coroutine.resume(Job.Co)
	if (not Ok or coroutine.status(Job.Co) == "dead") then
		Job = nil
	else
		Job.Filter = Filter
	end
end

local function Handle(Sender, Message)
	if (type(Message) ~= "table" or type(Message.Cmd) ~= "string") then return end
	local Args = type(Message.Args) == "table" and Message.Args or {}
	local Reply = { Re = Message.Seq }
	if (Message.Cmd == "pair") then
		if (tostring(Args.Pin) == Config.Pin) then
			Config.Trusted[Sender] = true
			WriteConfig(Config)
			Reply.Ok = true
			LastAction = "Paired with #" .. Sender
		else
			Reply.Error = "Wrong PIN"
		end
	elseif (not Config.Trusted[Sender]) then
		Reply.Error = "pin"
	elseif (Job and Message.Cmd ~= "status" and Message.Cmd ~= "stop") then
		Reply.Error = "Busy running " .. Job.Name
	elseif (Message.Cmd == "status") then
		Reply.Ok = true
	elseif (Message.Cmd == "action") then
		local Fn = Actions[Args.Name]
		if (Job) then
			Reply.Error = "Busy running " .. Job.Name
		elseif (not Fn) then
			Reply.Error = "Unknown action"
		else
			local Ok, Result, Detail = pcall(Fn)
			Reply.Ok = Ok and Result ~= false
			Reply.Result = Detail or Result
			if (not Ok or Result == false) then
				Reply.Error = tostring(Detail or Result or "failed")
			end
			LastAction = Args.Name .. (Reply.Ok and "" or (" (" .. tostring(Reply.Error) .. ")"))
		end
	elseif (Message.Cmd == "select") then
		Reply.Ok = turtle.select(math.max(1, math.min(16, tonumber(Args.Slot) or 1)))
	elseif (Message.Cmd == "refuel") then
		local Total = 0
		for Slot = 1, 16 do
			if (turtle.getItemCount(Slot) > 0) then
				turtle.select(Slot)
				if (turtle.refuel(Args.Count)) then Total = Total + 1 end
			end
		end
		Reply.Ok = Total > 0
		Reply.Error = (Total == 0) and "Nothing to burn" or nil
		LastAction = "Refuel"
	elseif (Message.Cmd == "run") then
		if (Job) then
			Reply.Error = "Busy running " .. Job.Name
		else
			StartJob(tostring(Args.Command or ""))
			Reply.Ok = true
		end
	elseif (Message.Cmd == "script") then
		local Name = fs.getName(tostring(Args.Name or "script.lua")):gsub("[^%w%._%-]", "")
		if (#Name == 0) then Name = "script.lua" end
		local Path = fs.combine(ScriptDir, Name)
		if (not fs.exists(ScriptDir)) then fs.makeDir(ScriptDir) end
		local Handle = type(Args.Source) == "string" and fs.open(Path, "w")
		if (not Handle) then
			Reply.Error = "Cannot save script"
		else
			Handle.write(Args.Source)
			Handle.close()
			local Extra = tostring(Args.Args or ""):gsub("^%s+", ""):gsub("%s+$", "")
			StartJob("/" .. Path .. ((#Extra > 0) and (" " .. Extra) or ""), Name .. ((#Extra > 0) and (" " .. Extra) or ""))
			Reply.Ok = true
		end
	elseif (Message.Cmd == "stop") then
		if (Job) then
			LastAction = "Stopped " .. Job.Name
			Job = nil
		end
		Reply.Ok = true
	elseif (Message.Cmd == "locate") then
		local X, Y, Z = gps.locate(1)
		Position = X and { X = X, Y = Y, Z = Z } or nil
		Reply.Ok = Position ~= nil
		Reply.Error = Position and nil or "No GPS signal"
	else
		Reply.Error = "Unknown command"
	end
	Controller = Sender
	Reply.Status = Status()
	rednet.send(Sender, Reply, Protocol)
end

OpenModems()
pcall(rednet.host, Protocol, os.getComputerLabel() or ("turtle-" .. os.getComputerID()))
Draw()

while (true) do
	local Event = table.pack(os.pullEventRaw())
	local Name = Event[1]
	if (Name == "terminate" and not Job) then
		SetColor(colors.white, colors.black)
		term.clear()
		term.setCursorPos(1, 1)
		print("BlockOS Turtle Agent stopped.")
		break
	end
	if (Name == "rednet_message" and Event[4] == Protocol) then
		Handle(Event[2], Event[3])
	elseif (Job and (Job.Filter == nil or Job.Filter == Name or Name == "terminate")) then
		local Ok, Filter = coroutine.resume(Job.Co, table.unpack(Event, 1, Event.n))
		if (not Ok or coroutine.status(Job.Co) == "dead") then
			LastAction = Ok and ("Finished " .. Job.Name) or ("Job failed: " .. tostring(Filter))
			Job = nil
			if (Controller) then
				rednet.send(Controller, { Event = "job_done", Status = Status() }, Protocol)
			end
		else
			Job.Filter = Filter
		end
	elseif (Name == "peripheral" or Name == "peripheral_detach") then
		OpenModems()
	end
	Draw()
end
