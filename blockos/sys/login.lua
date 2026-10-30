-- Login / lock screen with an animated ASCII plasma background.
-- Used standalone at boot and embedded by the desktop for locking.

local Gfx = BlockOS.Require("gfx")
local Users = BlockOS.Require("users")
local Config = BlockOS.Require("config")
local Logo = BlockOS.Require("logo")

local Login = {}
Login.__index = Login

local Density = { " ", ".", ":", "-", "=", "+", "*", "#", "%", "@" }
local Shades = {
	colors.black, colors.gray, colors.blue, colors.purple, colors.magenta, colors.cyan, colors.lightBlue, colors.white
}

local Hex = {}
for Index = 0, 15 do
	Hex[2 ^ Index] = string.format("%x", Index)
end

function Login.new(T, Opts)
	local Self = setmetatable({}, Login)
	Self.T = T
	Self.Opts = Opts or {}
	Self.User = Users.Primary()
	Self.Password = ""
	Self.Message = nil
	Self.Frame = 0
	Self.Shake = 0
	Self.Buttons = {}
	return Self
end

function Login:Start()
	self.Timer = os.startTimer(.1)
	self:Draw()
end

function Login:DrawBackground()
	local T = self.T
	local W, H = T.getSize()
	local Time = self.Frame / 6
	local Columns, Rows, Diagonal = {}, {}, {}
	for X = 1, W do
		Columns[X] = math.sin(X / 5 + Time)
	end
	for Y = 1, H do
		Rows[Y] = math.sin(Y / 2.5 - Time * .7)
	end
	for Index = 1, W + H do
		Diagonal[Index] = math.sin(Index / 7 + Time * 1.3)
	end
	for Y = 1, H do
		local Chars, Fg, Bg = {}, {}, {}
		for X = 1, W do
			local Value = (Columns[X] + Rows[Y] + Diagonal[X + Y] + 3) / 6
			local CharIndex = math.max(1, math.min(#Density, math.floor(Value * #Density) + 1))
			local ShadeIndex = math.max(1, math.min(#Shades, math.floor(Value * #Shades) + 1))
			Chars[X] = Density[CharIndex]
			Fg[X] = Hex[Shades[ShadeIndex]]
			Bg[X] = (Value > .78) and Hex[colors.blue] or Hex[colors.black]
		end
		T.setCursorPos(1, Y)
		T.blit(table.concat(Chars), table.concat(Fg), table.concat(Bg))
	end
end

function Login:Draw()
	local T = self.T
	local W, H = T.getSize()
	if (T.setVisible) then T.setVisible(false) end
	self:DrawBackground()
	local Settings = Config.Settings()
	local Clock = os.date(Settings.Clock24 and "%H:%M" or "%I:%M %p")
	Gfx.Center(T, 2, Clock, colors.white, colors.black)
	Gfx.Center(T, 3, os.date("%A, %B %d"), colors.lightGray, colors.black)

	local PanelW, PanelH = math.min(28, W - 2), 10
	local Offset = 0
	if (self.Shake > 0) then
		Offset = (self.Shake % 2 == 0) and 1 or -1
	end
	local PanelX = math.floor((W - PanelW) / 2) + 1 + Offset
	local PanelY = math.max(5, math.floor((H - PanelH) / 2) + 1)
	Gfx.Fill(T, PanelX, PanelY, PanelW, PanelH, colors.gray)
	local LogoW = Logo.Size(Logo.Small)
	Logo.Draw(T, PanelX + math.floor((PanelW - LogoW) / 2) + 1, PanelY + 1, Logo.Small)

	local Name = self.User and self.User.Name or "Guest"
	Gfx.Center(T, PanelY + 6, Name, colors.white, colors.gray, PanelX, PanelW)

	local FieldX, FieldY, FieldW = PanelX + 2, PanelY + 8, PanelW - 7
	local NeedsPassword = self.User and self.User.HasPassword
	self.Buttons = {}
	if (NeedsPassword) then
		local Masked = string.rep("\7", #self.Password)
		if (#Masked > FieldW - 1) then Masked = Masked:sub(-(FieldW - 1)) end
		if (#self.Password == 0) then
			Gfx.Write(T, FieldX, FieldY, Gfx.Pad(" Password", FieldW), colors.lightGray, colors.lightGray)
			Gfx.Write(T, FieldX, FieldY, " Password", colors.gray, colors.lightGray)
		else
			Gfx.Write(T, FieldX, FieldY, Gfx.Pad(" " .. Masked, FieldW), colors.black, colors.lightGray)
		end
	else
		Gfx.Write(T, FieldX, FieldY, Gfx.Pad("Click to log in", FieldW, "center"), colors.white, colors.gray)
	end
	local GoX = FieldX + FieldW + 1
	Gfx.Write(T, GoX, FieldY, " \26 ", colors.white, colors.blue)
	table.insert(self.Buttons, { X = FieldX, Y = FieldY, W = FieldW + 4, Action = "submit" })

	if (self.Message) then
		Gfx.Center(T, PanelY + PanelH, " " .. self.Message .. " ", colors.white, colors.red)
	end

	local Restart, Shutdown = " Restart ", " Shut Down "
	local TotalW = #Restart + #Shutdown + 2
	local ButtonX = math.floor((W - TotalW) / 2) + 1
	Gfx.Write(T, ButtonX, H - 1, Restart, colors.white, colors.gray)
	table.insert(self.Buttons, { X = ButtonX, Y = H - 1, W = #Restart, Action = "restart" })
	Gfx.Write(T, ButtonX + #Restart + 2, H - 1, Shutdown, colors.white, colors.gray)
	table.insert(self.Buttons, { X = ButtonX + #Restart + 2, Y = H - 1, W = #Shutdown, Action = "shutdown" })

	if (T.setVisible) then T.setVisible(true) end
	if (NeedsPassword) then
		T.setCursorPos(FieldX + math.min(#self.Password, FieldW - 1) + 1, FieldY)
		T.setTextColor(colors.black)
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
		for _, Button in ipairs(self.Buttons) do
			if (B >= Button.X and B < Button.X + Button.W and C == Button.Y) then
				if (Button.Action == "submit") then
					if (self:Submit()) then return true end
				elseif (Button.Action == "restart") then
					os.reboot()
				elseif (Button.Action == "shutdown") then
					os.shutdown()
				end
			end
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
