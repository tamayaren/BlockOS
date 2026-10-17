-- Login / lock screen drawn straight over a slow ASCII plasma, without a panel.
-- Used by the desktop for logging in and locking.

local Gfx = BlockOS.Require("gfx")
local Users = BlockOS.Require("users")
local Config = BlockOS.Require("config")
local Logo = BlockOS.Require("logo")
local Screensaver = BlockOS.Require("screensaver")

local Login = {}
Login.__index = Login

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

local PowerItems = { { Text = "Restart", Action = "restart" }, { Text = "Shut Down", Action = "shutdown" } }

function Login.new(T, Opts)
	local Self = setmetatable({}, Login)
	Self.T = T
	Self.Opts = Opts or {}
	Self.User = Users.Primary()
	Self.Password = ""
	Self.Message = nil
	Self.Frame = math.random(0, 2000)
	Self.Shake = 0
	Self.Buttons = {}
	Self.PowerOpen = false
	return Self
end

function Login:Start()
	self.Timer = os.startTimer(.1)
	self:Draw()
end

-- Writes text onto the canvas, keeping the plasma's background colour unless Bg is given.
local function Put(Canvas, X, Y, Text, Fg, Bg)
	if (Y < 1 or Y > Canvas.H) then return end
	for Index = 1, #Text do
		local Column = X + Index - 1
		if (Column >= 1 and Column <= Canvas.W) then
			Canvas.Chars[Y][Column] = Text:sub(Index, Index)
			Canvas.Fg[Y][Column] = Hex[Fg]
			if (Bg) then Canvas.Bg[Y][Column] = Hex[Bg] end
		end
	end
end

-- Clears the plasma characters behind a block of text so it stays readable.
local function Clear(Canvas, X, Y, W)
	Put(Canvas, X, Y, string.rep(" ", W), colors.white)
end

local function PutCentered(Canvas, Y, Text, Fg, Bg)
	local X = math.floor((Canvas.W - #Text) / 2) + 1
	Clear(Canvas, X - 1, Y, #Text + 2)
	Put(Canvas, X, Y, Text, Fg, Bg)
	return X
end

local function PutLogo(Canvas, X, Y, Art)
	for Row, Line in ipairs(Art) do
		for Column = 1, #Line do
			local Entry = Logo.Legend[Line:sub(Column, Column)]
			if (Entry) then
				Put(Canvas, X + Column - 1, Y + Row - 1, Entry[1], Entry[2], Entry[3])
			end
		end
	end
end

local function ClockText()
	local Settings = Config.Settings()
	if (Settings.Clock24) then
		return os.date("%H:%M"), nil
	end
	return (os.date("%I:%M"):gsub("^0", "")), os.date("%p")
end

function Login:Draw()
	local T = self.T
	local W, H = T.getSize()
	if (not self.Canvas or self.Canvas.W ~= W or self.Canvas.H ~= H) then
		self.Canvas = Screensaver.NewCanvas(W, H)
	end
	local Canvas = self.Canvas
	Screensaver.Render(Canvas, self.Frame * Screensaver.Speed)

	local Time, Suffix = ClockText()
	local Y = 2
	PutCentered(Canvas, Y, os.date("%A, %B %d"), colors.white)
	if (H >= 17 and W >= 24) then
		local BigW = Gfx.BigWidth(Time)
		local BigX = math.floor((W - BigW) / 2) + 1
		Gfx.EachBigCell(BigX, Y + 2, Time, function(X, CellY)
			Put(Canvas, X, CellY, " ", colors.white, colors.white)
		end)
		if (Suffix) then
			Put(Canvas, BigX + BigW + 1, Y + 6, Suffix, colors.white)
		end
		Y = Y + 8
	else
		PutCentered(Canvas, Y + 1, Time .. (Suffix and (" " .. Suffix) or ""), colors.white)
		Y = Y + 3
	end

	local Offset = 0
	if (self.Shake > 0) then
		Offset = (self.Shake % 2 == 0) and 1 or -1
	end
	local LogoW, LogoH = Logo.Size(Logo.Small)
	local BottomSpace = 5
	local LogoY = math.max(Y, H - BottomSpace - LogoH - 1)
	if (LogoY + LogoH + 4 <= H) then
		PutLogo(Canvas, math.floor((W - LogoW) / 2) + 1, LogoY, Logo.Small)
		Y = LogoY + LogoH
	end

	local Name = self.User and self.User.Name or "Guest"
	PutCentered(Canvas, Y, Name, colors.white)
	Y = Y + 2

	self.Buttons = {}
	local NeedsPassword = self.User and self.User.HasPassword
	local FieldW = math.min(20, W - 6)
	local FieldX = math.floor((W - FieldW - 3) / 2) + 1 + Offset
	if (NeedsPassword) then
		local Masked = string.rep("\7", #self.Password)
		if (#Masked > FieldW - 2) then Masked = Masked:sub(-(FieldW - 2)) end
		local Text = (#self.Password == 0) and " Enter Password" or (" " .. Masked)
		Put(Canvas, FieldX, Y, Gfx.Pad(Text, FieldW), (#self.Password == 0) and colors.lightGray or colors.white, colors.gray)
	else
		Put(Canvas, FieldX, Y, Gfx.Pad("Click to log in", FieldW, "center"), colors.white, colors.gray)
	end
	Put(Canvas, FieldX + FieldW, Y, " \26 ", colors.white, colors.gray)
	table.insert(self.Buttons, { X = FieldX, Y = Y, W = FieldW + 3, Action = "submit" })
	self.FieldX, self.FieldY, self.FieldW = FieldX, Y, FieldW

	if (self.Message) then
		PutCentered(Canvas, Y + 1, self.Message, colors.red)
	end

	-- Power button: a small circle in the bottom-right corner that opens a menu.
	local PowerX, PowerY = W - 2, H - 1
	Clear(Canvas, PowerX - 1, PowerY, 3)
	Put(Canvas, PowerX, PowerY, "\7", self.PowerOpen and colors.lightGray or colors.white)
	table.insert(self.Buttons, { X = PowerX - 1, Y = PowerY, W = 3, Action = "power" })
	if (self.PowerOpen) then
		local MenuW = 11
		local MenuX = W - MenuW
		local MenuY = PowerY - #PowerItems - 1
		for Index, Item in ipairs(PowerItems) do
			Put(Canvas, MenuX, MenuY + Index - 1, Gfx.Pad(" " .. Item.Text, MenuW), colors.black, colors.white)
			table.insert(self.Buttons, { X = MenuX, Y = MenuY + Index - 1, W = MenuW, Action = Item.Action })
		end
	end

	Screensaver.Blit(T, Canvas)
	if (NeedsPassword and not self.PowerOpen) then
		T.setCursorPos(FieldX + math.min(#self.Password, FieldW - 2) + 1, Y)
		T.setTextColor(colors.white)
		T.setCursorBlink(true)
	else
		T.setCursorBlink(false)
	end
end

function Login:Submit()
	if (not self.User) then return true end
	if (not self.User.HasPassword or Users.Verify(self.User.Name, self.Password)) then
		self.T.setCursorBlink(false)
		return true
	end
	self.Password = ""
	self.Message = "Incorrect password"
	self.Shake = 6
	return false
end

function Login:Power(Action)
	self.PowerOpen = false
	if (self.Opts.OnPower) then
		self.Opts.OnPower(Action)
	elseif (Action == "restart") then
		os.reboot()
	else
		os.shutdown()
	end
end

-- Feeds one event. Returns true once the user is authenticated.
function Login:Event(Name, A, B, C)
	if (Name == "timer" and A == self.Timer) then
		self.Frame = self.Frame + 1
		if (self.Shake > 0) then self.Shake = self.Shake - 1 end
		self.Timer = os.startTimer(.1)
		self:Draw()
		return false
	elseif (Name == "char") then
		if (#self.Password < 64) then
			self.Password = self.Password .. A
		end
		self.Message = nil
	elseif (Name == "paste") then
		self.Password = (self.Password .. A):sub(1, 64)
	elseif (Name == "key") then
		if (A == keys.backspace) then
			self.Password = self.Password:sub(1, -2)
		elseif (A == keys.enter or A == keys.numPadEnter) then
			if (self:Submit()) then return true end
		end
	elseif (Name == "mouse_click") then
		local Hit = nil
		for _, Button in ipairs(self.Buttons) do
			if (B >= Button.X and B < Button.X + Button.W and C == Button.Y) then
				Hit = Button
			end
		end
		if (not Hit) then
			self.PowerOpen = false
		elseif (Hit.Action == "power") then
			self.PowerOpen = not self.PowerOpen
		elseif (Hit.Action == "submit") then
			self.PowerOpen = false
			if (self:Submit()) then return true end
		else
			self:Power(Hit.Action)
		end
	else
		return false
	end
	self:Draw()
	return false
end

function Login:Stop()
	if (self.Timer) then
		os.cancelTimer(self.Timer)
		self.Timer = nil
	end
end

-- Blocks until login succeeds.
function Login.Run(T)
	local Screen = Login.new(T)
	if (Config.Settings().AutoLogin) then
		return true
	end
	Screen:Start()
	while (true) do
		local Event = table.pack(os.pullEventRaw())
		if (Event[1] ~= "terminate" and Screen:Event(table.unpack(Event, 1, Event.n))) then
			Screen:Stop()
			return true
		end
	end
end

return Login
