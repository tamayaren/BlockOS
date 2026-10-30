-- Retained-mode widget toolkit used by BlockOS apps.
-- A Page owns a buffered window; widgets are positioned in page-local coordinates.

local Gfx = BlockOS.Require("gfx")
local Theme = BlockOS.Require("theme")

local Ui = {}

Ui.Current = nil

local InputEvents = {
	mouse_click = true, mouse_drag = true, mouse_up = true, mouse_scroll = true,
	key = true, key_up = true, char = true, paste = true
}

local MouseEvents = { mouse_click = true, mouse_drag = true, mouse_up = true, mouse_scroll = true }

Ui.InputEvents = InputEvents

-- Modifier state shared by pages and dialogs, so a key released inside a dialog is not missed.
Ui.Modifiers = {}

local ModifierKeys = {
	[keys.leftCtrl] = "Ctrl", [keys.rightCtrl] = "Ctrl",
	[keys.leftShift] = "Shift", [keys.rightShift] = "Shift",
	[keys.leftAlt] = "Alt", [keys.rightAlt] = "Alt"
}

local function TrackModifiers(Name, Key)
	if ((Name == "key" or Name == "key_up") and ModifierKeys[Key]) then
		Ui.Modifiers[ModifierKeys[Key]] = Name == "key"
	end
end

local function Resolve(Value, Th, Fallback)
	if (type(Value) == "string") then
		return Th[Value] or Fallback
	end
	if (Value == nil) then return Fallback end
	return Value
end

Ui.Resolve = Resolve

local function Inside(Item, X, Y)
	return X >= Item.X and X < Item.X + Item.W and Y >= Item.Y and Y < Item.Y + Item.H
end

Ui.Inside = Inside

local function TextOf(Value)
	if (type(Value) == "function") then
		return tostring(Value())
	end
	return tostring(Value or "")
end

local function Class(Defaults)
	local NewClass = { Defaults = Defaults }
	NewClass.__index = NewClass
	function NewClass.new(Props)
		local Object = setmetatable(Props or {}, NewClass)
		for Key, Value in pairs(Defaults) do
			if (Object[Key] == nil) then
				Object[Key] = Value
			end
		end
		Object.Visible = Object.Visible ~= false
		if (Object.Init) then
			Object:Init()
		end
		return Object
	end
	return NewClass
end

--
-- Page
--

Ui.Page = {}
Ui.Page.__index = Ui.Page

function Ui.Page.new(Props)
	local Self = setmetatable(Props or {}, Ui.Page)
	Self.Parent = Self.Parent or term.current()
	Self.Widgets = {}
	Self.Intervals = {}
	Self.Dirty = true
	if (Self.X) then
		Self.Fixed = true
	else
		Self.X = 1
		Self.Y = 1
		Self.W, Self.H = Self.Parent.getSize()
	end
	Self.Buffer = window.create(Self.Parent, Self.X, Self.Y, Self.W, Self.H, false)
	return Self
end

function Ui.Page:Add(Item)
	table.insert(self.Widgets, Item)
	Item.Page = self
	self.Dirty = true
	return Item
end

function Ui.Page:Remove(Item)
	for Index, Other in ipairs(self.Widgets) do
		if (Other == Item) then
			table.remove(self.Widgets, Index)
			break
		end
	end
	if (self.Focus == Item) then self.Focus = nil end
	self.Dirty = true
end

function Ui.Page:Clear()
	self.Widgets = {}
	self.Focus = nil
	self.Captured = nil
	self.Dirty = true
end

function Ui.Page:SetFocus(Item)
	if (self.Focus == Item) then return end
	if (self.Focus and self.Focus.OnBlur) then self.Focus:OnBlur() end
	self.Focus = Item
	if (Item and Item.OnFocus) then Item:OnFocus() end
	self.Dirty = true
end

function Ui.Page:GetBg(Th)
	return Resolve(self.Bg, Th, Th.WindowBg)
end

function Ui.Page:Invalidate()
	self.Dirty = true
end

function Ui.Page:Resize()
	if (not self.Fixed) then
		self.W, self.H = self.Parent.getSize()
	end
	self.Buffer.reposition(self.X, self.Y, self.W, self.H)
	if (self.OnLayout) then
		self:OnLayout(self.W, self.H)
	end
	self.Dirty = true
end

function Ui.Page:Draw()
	local T = self.Buffer
	local Th = Theme.Get()
	T.setVisible(false)
	T.setCursorBlink(false)
	T.setBackgroundColor(self:GetBg(Th))
	T.clear()
	if (self.OnDraw) then
		self:OnDraw(T, Th)
	end
	for _, Item in ipairs(self.Widgets) do
		if (Item.Visible) then
			Item:Draw(T, Th, self)
		end
	end
	if (self.OnDrawOver) then
		self:OnDrawOver(T, Th)
	end
	local CursorX, CursorY, CursorColor
	if (self.Focus and self.Focus.Visible and self.Focus.CursorPos) then
		CursorX, CursorY, CursorColor = self.Focus:CursorPos(Th)
	end
	if (self.CursorOverride) then
		CursorX, CursorY, CursorColor = self:CursorOverride(Th)
	end
	T.setVisible(true)
	if (CursorX) then
		T.setCursorPos(CursorX, CursorY)
		T.setTextColor(CursorColor or Th.Text)
		T.setCursorBlink(true)
	end
	self.Dirty = false
end

function Ui.Page:WidgetAt(X, Y)
	for Index = #self.Widgets, 1, -1 do
		local Item = self.Widgets[Index]
		if (Item.Visible and Item.Event and Inside(Item, X, Y)) then
			return Item
		end
	end
	return nil
end

-- Routes an input event to widgets. Returns true when a widget consumed it.
function Ui.Page:Dispatch(Name, A, B, C)
	if (MouseEvents[Name]) then
		local X, Y = B - self.X + 1, C - self.Y + 1
		if (Name == "mouse_click") then
			local Item = self:WidgetAt(X, Y)
			self.Captured = Item
			if (Item and Item.Focusable) then
				self:SetFocus(Item)
			elseif (not Item or not Item.KeepFocus) then
				self:SetFocus(nil)
			end
			if (Item) then
				return Item:Event(self, Name, A, X, Y) ~= false
			end
			return false
		elseif (Name == "mouse_scroll") then
			local Item = self:WidgetAt(X, Y)
			if (Item) then
				return Item:Event(self, Name, A, X, Y) == true
			end
			return false
		end
		local Item = self.Captured
		if (Name == "mouse_up") then
			self.Captured = nil
		end
		if (Item) then
			return Item:Event(self, Name, A, X, Y) == true
		end
		return false
	end
	if (self.Focus and self.Focus.Visible and self.Focus.Event) then
		if (self.Focus:Event(self, Name, A, B, C)) then
			return true
		end
	end
	if (Name == "key" and A == keys.tab) then
		self:FocusNext()
		return true
	end
	return false
end

function Ui.Page:FocusNext()
	local Focusable = {}
	local Current = 0
	for _, Item in ipairs(self.Widgets) do
		if (Item.Visible and Item.Focusable) then
			table.insert(Focusable, Item)
			if (Item == self.Focus) then
				Current = #Focusable
			end
		end
	end
	if (#Focusable == 0) then return end
	self:SetFocus(Focusable[Current % #Focusable + 1])
end

function Ui.Page:SetInterval(Seconds, Callback)
	local Interval = { Seconds = Seconds, Callback = Callback }
	Interval.Timer = os.startTimer(Seconds)
	self.Intervals[Interval.Timer] = Interval
	return Interval
end

function Ui.Page:ClearInterval(Interval)
	if (not Interval) then return end
	self.Intervals[Interval.Timer] = nil
	os.cancelTimer(Interval.Timer)
end

-- Handles events that are not routed to widgets (timers, settings, custom events).
function Ui.Page:Background(Name, ...)
	if (Name == "timer") then
		local Id = ...
		local Interval = self.Intervals[Id]
		if (Interval) then
			self.Intervals[Id] = nil
			Interval.Timer = os.startTimer(Interval.Seconds)
			self.Intervals[Interval.Timer] = Interval
			if (Interval.Callback() ~= false) then
				self.Dirty = true
			end
			return
		end
	elseif (Name == "blockos_settings") then
		self.Dirty = true
	elseif (Name == "term_resize") then
		self:Resize()
	end
	if (self.OnEvent and self:OnEvent(Name, ...)) then
		self.Dirty = true
	end
end

function Ui.Page:Handle(Name, ...)
	TrackModifiers(Name, ...)
	if (Name == "terminate") then
		if (self.OnTerminate) then
			self:OnTerminate()
		else
			self.Running = false
		end
		return
	end
	if (InputEvents[Name]) then
		if (self:Dispatch(Name, ...)) then
			self.Dirty = true
		elseif (self.OnEvent and self:OnEvent(Name, ...)) then
			self.Dirty = true
		end
		return
	end
	self:Background(Name, ...)
end

function Ui.Page:Run()
	self.Running = true
	local Previous = Ui.Current
	Ui.Current = self
	self:Resize()
	self:Draw()
	while (self.Running) do
		local Event = table.pack(os.pullEventRaw())
		self:Handle(table.unpack(Event, 1, Event.n))
		if (self.Running and self.Dirty) then
			self:Draw()
		end
	end
	Ui.Current = Previous
end

function Ui.Page:Stop()
	self.Running = false
end

--
-- Widgets
--

Ui.Panel = Class({ X = 1, Y = 1, W = 1, H = 1, Bg = "Panel" })

function Ui.Panel:Draw(T, Th)
	Gfx.Fill(T, self.X, self.Y, self.W, self.H, Resolve(self.Bg, Th, Th.Panel))
end

Ui.Label = Class({ X = 1, Y = 1, H = 1, Text = "", Align = "left" })

function Ui.Label:Draw(T, Th, Page)
	local Text = TextOf(self.Text)
	local W = self.W or #Text
	local Bg = Resolve(self.Bg, Th, Page:GetBg(Th))
	local Fg = Resolve(self.Fg, Th, Th.Text)
	if (self.H > 1) then
		local Lines = Gfx.Wrap(Text, W)
		for Row = 1, self.H do
			Gfx.Write(T, self.X, self.Y + Row - 1, Gfx.Pad(Lines[Row] or "", W, self.Align), Fg, Bg)
		end
		return
	end
	Gfx.Write(T, self.X, self.Y, Gfx.Pad(Text, W, self.Align), Fg, Bg)
end

Ui.Button = Class({ X = 1, Y = 1, H = 1, Text = "Button", Style = "default", Enabled = true })

function Ui.Button:Init()
	self.W = self.W or #TextOf(self.Text) + 2
end

function Ui.Button:Colors(Th, Page)
	if (not self.Enabled) then
		return Th.ButtonBg, Th.SubText
	end
	if (self.Style == "primary") then
		return Resolve(self.Bg, Th, Th.Accent), Resolve(self.Fg, Th, Th.AccentFg)
	elseif (self.Style == "danger") then
		return colors.red, colors.white
	elseif (self.Style == "plain") then
		return Resolve(self.Bg, Th, Page:GetBg(Th)), Resolve(self.Fg, Th, Th.Accent)
	end
	return Resolve(self.Bg, Th, Th.ButtonBg), Resolve(self.Fg, Th, Th.ButtonFg)
end

function Ui.Button:Draw(T, Th, Page)
	local Bg, Fg = self:Colors(Th, Page)
	Gfx.Fill(T, self.X, self.Y, self.W, self.H, Bg)
	Gfx.Write(T, self.X, self.Y + math.floor((self.H - 1) / 2), Gfx.Pad(TextOf(self.Text), self.W, "center"), Fg, Bg)
end

function Ui.Button:Event(Page, Name, Button)
	if (Name == "mouse_click" and self.Enabled and self.OnClick) then
		self:OnClick(Button)
		return true
	end
	return Name == "mouse_click"
end

Ui.Input = Class({ X = 1, Y = 1, W = 10, H = 1, Value = "", Placeholder = "", Cursor = 1, Scroll = 0, Focusable = true })

function Ui.Input:Init()
	self.Value = tostring(self.Value)
	self.Cursor = #self.Value + 1
end

function Ui.Input:SetValue(Value)
	self.Value = tostring(Value or "")
	self.Cursor = #self.Value + 1
	self.Scroll = 0
	self.AllSelected = false
end

-- Highlights the whole value so the next typed text replaces it.
function Ui.Input:SelectAll()
	self.AllSelected = #self.Value > 0
end

function Ui.Input:ReplaceSelection()
	if (not self.AllSelected) then return end
	self.AllSelected = false
	self.Value = ""
	self.Cursor = 1
	self.Scroll = 0
end

function Ui.Input:Clamp()
	if (self.Cursor < 1) then self.Cursor = 1 end
	if (self.Cursor > #self.Value + 1) then self.Cursor = #self.Value + 1 end
	if (self.Cursor - 1 - self.Scroll >= self.W) then
		self.Scroll = self.Cursor - self.W
	end
	if (self.Cursor - 1 < self.Scroll) then
		self.Scroll = self.Cursor - 1
	end
end

function Ui.Input:Draw(T, Th, Page)
	self:Clamp()
	local Bg = Resolve(self.Bg, Th, Th.InputBg)
	local Fg = Resolve(self.Fg, Th, Th.InputFg)
	local Display = self.Value
	if (self.Mask) then
		Display = string.rep(self.Mask, #self.Value)
	end
	if (#Display == 0 and Page.Focus ~= self) then
		Gfx.Write(T, self.X, self.Y, Gfx.Pad(self.Placeholder, self.W), Th.SubText, Bg)
		return
	end
	local Visible = Display:sub(self.Scroll + 1, self.Scroll + self.W)
	Gfx.Write(T, self.X, self.Y, Gfx.Pad(Visible, self.W), Fg, Bg)
	if (self.AllSelected and Page.Focus == self) then
		Gfx.Write(T, self.X, self.Y, Visible, Th.AccentFg, Th.Accent)
	end
end

function Ui.Input:CursorPos(Th)
	self:Clamp()
	return self.X + self.Cursor - 1 - self.Scroll, self.Y, Resolve(self.Fg, Th, Th.InputFg)
end

function Ui.Input:Insert(Text)
	if (self.MaxLength and #self.Value + #Text > self.MaxLength) then
		Text = Text:sub(1, math.max(self.MaxLength - #self.Value, 0))
	end
	if (#Text == 0) then return end
	self.Value = self.Value:sub(1, self.Cursor - 1) .. Text .. self.Value:sub(self.Cursor)
	self.Cursor = self.Cursor + #Text
	if (self.OnChange) then self:OnChange(self.Value) end
end

function Ui.Input:Event(Page, Name, A, X)
	if (Name == "mouse_click") then
		self.AllSelected = false
		self.Cursor = X - self.X + self.Scroll + 1
		self:Clamp()
		return true
	elseif (Name == "char") then
		self:ReplaceSelection()
		self:Insert(A)
		return true
	elseif (Name == "paste") then
		self:ReplaceSelection()
		self:Insert((A:gsub("[\r\n]", "")))
		return true
	elseif (Name == "key") then
		if (self.AllSelected and (A == keys.backspace or A == keys.delete)) then
			self:ReplaceSelection()
			if (self.OnChange) then self:OnChange(self.Value) end
			return true
		elseif (A ~= keys.enter and A ~= keys.numPadEnter and A ~= keys.tab) then
			self.AllSelected = false
		end
		if (A == keys.backspace) then
			if (self.Cursor > 1) then
				self.Value = self.Value:sub(1, self.Cursor - 2) .. self.Value:sub(self.Cursor)
				self.Cursor = self.Cursor - 1
				if (self.OnChange) then self:OnChange(self.Value) end
			end
		elseif (A == keys.delete) then
			self.Value = self.Value:sub(1, self.Cursor - 1) .. self.Value:sub(self.Cursor + 1)
			if (self.OnChange) then self:OnChange(self.Value) end
		elseif (A == keys.left) then
			self.Cursor = self.Cursor - 1
		elseif (A == keys.right) then
			self.Cursor = self.Cursor + 1
		elseif (A == keys.home) then
			self.Cursor = 1
		elseif (A == keys["end"]) then
			self.Cursor = #self.Value + 1
		elseif (A == keys.enter or A == keys.numPadEnter) then
			if (self.OnSubmit) then self:OnSubmit(self.Value) end
		else
			return false
		end
		self:Clamp()
		return true
	end
	return false
end

Ui.List = Class({ X = 1, Y = 1, W = 10, H = 5, Selected = 0, Scroll = 0, Focusable = true })

function Ui.List:Init()
	self.Items = self.Items or {}
end

function Ui.List:SetItems(Items, KeepSelection)
	self.Items = Items
	if (not KeepSelection) then
		self.Selected = 0
		self.Scroll = 0
	end
	if (self.Selected > #Items) then self.Selected = #Items end
	self:EnsureVisible()
end

function Ui.List:EnsureVisible()
	local MaxScroll = math.max(#self.Items - self.H, 0)
	if (self.Selected > 0) then
		if (self.Selected <= self.Scroll) then
			self.Scroll = self.Selected - 1
		elseif (self.Selected > self.Scroll + self.H) then
			self.Scroll = self.Selected - self.H
		end
	end
	self.Scroll = math.max(0, math.min(self.Scroll, MaxScroll))
end

function Ui.List:Draw(T, Th, Page)
	local Bg = Resolve(self.Bg, Th, Page:GetBg(Th))
	local Fg = Resolve(self.Fg, Th, Th.Text)
	local Overflow = #self.Items > self.H
	local TextW = Overflow and self.W - 1 or self.W
	for Row = 1, self.H do
		local Index = Row + self.Scroll
		local Item = self.Items[Index]
		local Y = self.Y + Row - 1
		local RowBg, RowFg, SubFg = Bg, Fg, Th.SubText
		if (Item and Index == self.Selected) then
			RowBg = Th.Accent
			RowFg = Th.AccentFg
			SubFg = Th.AccentFg
		end
		Gfx.Fill(T, self.X, Y, TextW, 1, RowBg)
		if (Item) then
			if (self.RenderItem) then
				self:RenderItem(T, Th, Item, self.X, Y, TextW, Index == self.Selected, RowBg, RowFg)
			else
				local X = self.X
				if (Item.Icon) then
					Gfx.Write(T, X, Y, Item.Icon, (Index == self.Selected) and RowFg or Resolve(Item.IconFg, Th, RowFg), RowBg)
					X = X + #Item.Icon + 1
				end
				local Right = Item.Right and tostring(Item.Right) or ""
				local Space = self.X + TextW - X - (#Right > 0 and #Right + 1 or 0)
				Gfx.Write(T, X, Y, Gfx.Truncate(Item.Text or "", Space), (Index == self.Selected) and RowFg or Resolve(Item.Fg, Th, RowFg), RowBg)
				if (#Right > 0) then
					Gfx.Write(T, self.X + TextW - #Right, Y, Right, SubFg, RowBg)
				end
			end
		end
	end
	if (Overflow) then
		local Track = self.H
		local Thumb = math.max(1, math.floor(Track * self.H / #self.Items))
		local MaxScroll = #self.Items - self.H
		local ThumbY = math.floor((Track - Thumb) * self.Scroll / MaxScroll + .5)
		Gfx.Fill(T, self.X + self.W - 1, self.Y, 1, Track, Th.Border)
		Gfx.Fill(T, self.X + self.W - 1, self.Y + ThumbY, 1, Thumb, Th.SubText)
	end
end

function Ui.List:Select(Index)
	if (Index < 1 or Index > #self.Items) then return end
	self.Selected = Index
	self:EnsureVisible()
	if (self.OnSelect) then self:OnSelect(Index, self.Items[Index]) end
end

function Ui.List:Event(Page, Name, A, X, Y)
	if (Name == "mouse_click") then
		local Index = Y - self.Y + 1 + self.Scroll
		local Item = self.Items[Index]
		if (not Item) then
			if (A == 2 and self.OnContext) then self:OnContext(nil, nil, X, Y) end
			return true
		end
		local Now = os.clock()
		local Double = (self.LastClick == Index and Now - (self.LastTime or 0) < .5)
		self.LastClick = Index
		self.LastTime = Now
		if (Index ~= self.Selected) then
			self:Select(Index)
		end
		if (A == 2) then
			if (self.OnContext) then self:OnContext(Index, Item, X, Y) end
		elseif (Double or self.SingleClick) then
			self.LastClick = nil
			if (self.OnActivate) then self:OnActivate(Index, Item) end
		end
		return true
	elseif (Name == "mouse_scroll") then
		self.Scroll = math.max(0, math.min(self.Scroll + A, math.max(#self.Items - self.H, 0)))
		return true
	elseif (Name == "key") then
		if (A == keys.up) then
			self:Select(math.max(1, self.Selected - 1))
		elseif (A == keys.down) then
			self:Select(math.min(#self.Items, self.Selected + 1))
		elseif (A == keys.pageUp) then
			self:Select(math.max(1, self.Selected - self.H))
		elseif (A == keys.pageDown) then
			self:Select(math.min(#self.Items, self.Selected + self.H))
		elseif (A == keys.home) then
			self:Select(1)
		elseif (A == keys["end"]) then
			self:Select(#self.Items)
		elseif ((A == keys.enter or A == keys.numPadEnter) and self.Items[self.Selected]) then
			if (self.OnActivate) then self:OnActivate(self.Selected, self.Items[self.Selected]) end
		else
			return false
		end
		return true
	end
	return false
end

Ui.Toggle = Class({ X = 1, Y = 1, W = 4, H = 1, Value = false })

function Ui.Toggle:Draw(T, Th)
	if (self.Value) then
		Gfx.Fill(T, self.X, self.Y, 3, 1, Th.Accent)
		Gfx.Fill(T, self.X + 3, self.Y, 1, 1, colors.white)
	else
		Gfx.Fill(T, self.X, self.Y, 1, 1, colors.white)
		Gfx.Fill(T, self.X + 1, self.Y, 3, 1, Th.Dark and colors.black or colors.gray)
	end
end

function Ui.Toggle:Event(Page, Name)
	if (Name == "mouse_click") then
		self.Value = not self.Value
		if (self.OnChange) then self:OnChange(self.Value) end
		return true
	end
	return false
end

Ui.Checkbox = Class({ X = 1, Y = 1, H = 1, Value = false, Text = "" })

function Ui.Checkbox:Init()
	self.W = self.W or #self.Text + 4
end

function Ui.Checkbox:Draw(T, Th, Page)
	local Bg = Resolve(self.Bg, Th, Page:GetBg(Th))
	Gfx.Write(T, self.X, self.Y, self.Value and "[x]" or "[ ]", self.Value and Th.Accent or Th.SubText, Bg)
	Gfx.Write(T, self.X + 4, self.Y, Gfx.Truncate(self.Text, self.W - 4), Resolve(self.Fg, Th, Th.Text), Bg)
end

Ui.Checkbox.Event = Ui.Toggle.Event

Ui.Tabs = Class({ X = 1, Y = 1, W = 20, H = 1, Selected = 1 })

function Ui.Tabs:Init()
	self.Items = self.Items or {}
end

function Ui.Tabs:Draw(T, Th)
	local Count = #self.Items
	if (Count == 0) then return end
	local X = self.X
	for Index, Text in ipairs(self.Items) do
		local Width = math.floor(self.W * Index / Count) - math.floor(self.W * (Index - 1) / Count)
		local Bg = (Index == self.Selected) and Th.Accent or Th.ButtonBg
		local Fg = (Index == self.Selected) and Th.AccentFg or Th.ButtonFg
		Gfx.Write(T, X, self.Y, Gfx.Pad(Text, Width, "center"), Fg, Bg)
		X = X + Width
	end
end

function Ui.Tabs:Event(Page, Name, A, X)
	if (Name ~= "mouse_click") then return false end
	local Count = #self.Items
	local Offset = X - self.X
	for Index = 1, Count do
		if (Offset < math.floor(self.W * Index / Count)) then
			if (Index ~= self.Selected) then
				self.Selected = Index
				if (self.OnChange) then self:OnChange(Index, self.Items[Index]) end
			end
			return true
		end
	end
	return true
end

Ui.Progress = Class({ X = 1, Y = 1, W = 10, H = 1, Value = 0 })

function Ui.Progress:Draw(T, Th)
	local Value = math.max(0, math.min(1, TextOf(self.Value) + 0))
	local Filled = math.floor(self.W * Value + .5)
	Gfx.Fill(T, self.X, self.Y, self.W, self.H, Th.Border)
	Gfx.Fill(T, self.X, self.Y, Filled, self.H, Resolve(self.Color, Th, Th.Accent))
end

Ui.Canvas = Class({ X = 1, Y = 1, W = 1, H = 1 })

function Ui.Canvas:Draw(T, Th, Page)
	if (self.OnDraw) then self:OnDraw(T, Th, Page) end
end

function Ui.Canvas:Event(Page, Name, A, B, C)
	if (self.OnEvent) then
		return self:OnEvent(Name, A, B, C)
	end
	return false
end

function Ui.Canvas:CursorPos(Th)
	if (self.OnCursor) then return self:OnCursor(Th) end
	return nil
end

--
-- Modal dialogs. These block the calling coroutine but keep the
-- current page's timers and background events flowing.
--

local function AnimationsEnabled()
	local Ok, Config = pcall(BlockOS.Require, "config")
	return not (Ok and Config.Settings().Animations == false)
end

-- Grows a menu downwards over a few frames, keeping any events that arrive meanwhile.
local function Unroll(Modal, Pending)
	local FullH = Modal.H
	local Frames = 3
	for Frame = 1, Frames do
		local H = math.max(1, math.ceil(FullH * (1 - (1 - Frame / (Frames + 1)) ^ 2)))
		Modal.Buffer.reposition(Modal.X, Modal.Y, Modal.W, H)
		Modal:Draw()
		local Timer = os.startTimer(.05)
		while (true) do
			local Event = table.pack(os.pullEventRaw())
			if (Event[1] == "timer" and Event[2] == Timer) then break end
			table.insert(Pending, Event)
		end
	end
	Modal.Buffer.reposition(Modal.X, Modal.Y, Modal.W, FullH)
end

local function RunModal(Modal)
	local Previous = Ui.Current
	Ui.Current = Modal
	Modal.Running = true
	if (Modal.OnLayout) then Modal:OnLayout(Modal.W, Modal.H) end
	local Pending = {}
	if (Modal.Unroll and Modal.H > 1 and AnimationsEnabled()) then
		Unroll(Modal, Pending)
	end
	Modal:Draw()
	while (Modal.Running) do
		local Event = table.remove(Pending, 1) or table.pack(os.pullEventRaw())
		local Name = Event[1]
		TrackModifiers(Name, Event[2])
		if (Name == "terminate") then
			Modal.Running = false
		elseif (InputEvents[Name]) then
			local Outside = MouseEvents[Name] and Name == "mouse_click" and not Inside(Modal, Event[3], Event[4])
			if (Outside) then
				if (Modal.OnOutside) then Modal:OnOutside() end
			elseif (not Modal:Dispatch(table.unpack(Event, 1, Event.n)) and Modal.OnEvent) then
				Modal:OnEvent(table.unpack(Event, 1, Event.n))
			end
		elseif (Previous) then
			Previous:Background(table.unpack(Event, 1, Event.n))
			if (Previous.Dirty) then
				Previous:Draw()
			end
		end
		if (Modal.Running) then
			Modal:Draw()
		end
	end
	Modal.Buffer.setVisible(false)
	Ui.Current = Previous
	if (Previous) then
		Previous:Draw()
	end
	return Modal.Result
end

local function CreateModal(W, H, Parent)
	Parent = Parent or (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW, ScreenH = Parent.getSize()
	W = math.min(W, ScreenW)
	H = math.min(H, ScreenH)
	local X = math.floor((ScreenW - W) / 2) + 1
	local Y = math.floor((ScreenH - H) / 2) + 1
	return Ui.Page.new({ Parent = Parent, X = X, Y = Y, W = W, H = H, Bg = "MenuBg" })
end

local function DrawModalTitle(Modal, Title)
	function Modal:OnDraw(T, Th)
		Gfx.Fill(T, 1, 1, self.W, 1, Th.TitleBg)
		Gfx.Center(T, 1, Title, Th.TitleFg, Th.TitleBg)
	end
end

-- Shows a message with buttons; returns the index of the pressed button.
function Ui.Alert(Title, Message, Buttons)
	Buttons = Buttons or { "OK" }
	local Parent = (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW = Parent.getSize()
	local ButtonsW = 1
	for _, Text in ipairs(Buttons) do
		ButtonsW = ButtonsW + #Text + 3
	end
	local W = math.min(ScreenW - 2, math.max(26, #Title + 4, ButtonsW))
	local Lines = Gfx.Wrap(Message or "", W - 4)
	local Modal = CreateModal(W, #Lines + 5, Parent)
	DrawModalTitle(Modal, Title)
	for Index, Line in ipairs(Lines) do
		Modal:Add(Ui.Label.new({ X = 3, Y = Index + 2, W = W - 4, Text = Line, Fg = "MenuFg" }))
	end
	local X = Modal.W
	for Index = #Buttons, 1, -1 do
		local Text = Buttons[Index]
		X = X - #Text - 3
		Modal:Add(Ui.Button.new({
			X = X + 1, Y = Modal.H - 1, Text = Text,
			Style = (Index == #Buttons) and "primary" or "default",
			OnClick = function()
				Modal.Result = Index
				Modal.Running = false
			end
		}))
	end
	function Modal:OnEvent(Name, Key)
		if (Name == "key" and (Key == keys.enter or Key == keys.numPadEnter)) then
			self.Result = #Buttons
			self.Running = false
		end
	end
	return RunModal(Modal)
end

function Ui.Confirm(Title, Message, YesText, NoText)
	return Ui.Alert(Title, Message, { NoText or "Cancel", YesText or "OK" }) == 2
end

-- Asks for a line of text; returns nil when cancelled.
function Ui.Prompt(Title, Message, Default, Mask)
	local Parent = (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW = Parent.getSize()
	local W = math.min(ScreenW - 2, 32)
	local Lines = Gfx.Wrap(Message or "", W - 4)
	local Modal = CreateModal(W, #Lines + 7, Parent)
	DrawModalTitle(Modal, Title)
	for Index, Line in ipairs(Lines) do
		Modal:Add(Ui.Label.new({ X = 3, Y = Index + 2, W = W - 4, Text = Line, Fg = "MenuFg" }))
	end
	local Field = Modal:Add(Ui.Input.new({ X = 3, Y = #Lines + 4, W = W - 4, Value = Default or "", Mask = Mask }))
	Field:SelectAll()
	Field.OnSubmit = function()
		Modal.Result = Field.Value
		Modal.Running = false
	end
	Modal:Add(Ui.Button.new({
		X = W - 14, Y = Modal.H - 1, W = 8, Text = "Cancel",
		OnClick = function()
			Modal.Result = nil
			Modal.Running = false
		end
	}))
	Modal:Add(Ui.Button.new({
		X = W - 5, Y = Modal.H - 1, W = 4, Text = "OK", Style = "primary",
		OnClick = function()
			Modal.Result = Field.Value
			Modal.Running = false
		end
	}))
	Modal:SetFocus(Field)
	return RunModal(Modal)
end

-- Picks one entry from a list; returns index and item or nil.
function Ui.Choose(Title, Items, Selected)
	local Parent = (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW, ScreenH = Parent.getSize()
	local W = math.min(ScreenW - 2, 30)
	local H = math.min(ScreenH - 2, #Items + 5)
	local Modal = CreateModal(W, H, Parent)
	DrawModalTitle(Modal, Title)
	local Entries = {}
	for _, Item in ipairs(Items) do
		if (type(Item) == "table") then
			table.insert(Entries, Item)
		else
			table.insert(Entries, { Text = tostring(Item) })
		end
	end
	local Picker = Modal:Add(Ui.List.new({ X = 2, Y = 3, W = W - 2, H = H - 5, Items = Entries, Bg = "MenuBg" }))
	Picker.Selected = Selected or 1
	Picker:EnsureVisible()
	Picker.OnActivate = function(_, Index)
		Modal.Result = Index
		Modal.Running = false
	end
	Modal:Add(Ui.Button.new({
		X = W - 14, Y = H - 1, W = 8, Text = "Cancel",
		OnClick = function()
			Modal.Running = false
		end
	}))
	Modal:Add(Ui.Button.new({
		X = W - 5, Y = H - 1, W = 4, Text = "OK", Style = "primary",
		OnClick = function()
			if (Picker.Selected > 0) then Modal.Result = Picker.Selected end
			Modal.Running = false
		end
	}))
	Modal:SetFocus(Picker)
	local Index = RunModal(Modal)
	return Index, Index and Items[Index]
end

-- Pops up a menu at X, Y (in parent coordinates). Items may be strings, "-" separators,
-- or { Text = ..., Disabled = true }. Returns the chosen index or nil.
function Ui.ContextMenu(X, Y, Items)
	local Parent = (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW, ScreenH = Parent.getSize()
	local W = 4
	for _, Item in ipairs(Items) do
		local Text = type(Item) == "table" and Item.Text or Item
		W = math.max(W, #Text + 2)
	end
	local H = #Items
	X = math.max(1, math.min(X, ScreenW - W + 1))
	Y = math.max(1, math.min(Y, ScreenH - H + 1))
	local Modal = Ui.Page.new({ Parent = Parent, X = X, Y = Y, W = W, H = H, Bg = "MenuBg", Unroll = true })
	Modal.Hover = 0
	function Modal:OnDraw(T, Th)
		for Index, Item in ipairs(Items) do
			local Text = type(Item) == "table" and Item.Text or Item
			local Disabled = type(Item) == "table" and Item.Disabled
			if (Text == "-") then
				Gfx.Write(T, 1, Index, string.rep("\140", W), Th.MenuDim, Th.MenuBg)
			elseif (Index == self.Hover) then
				Gfx.Write(T, 1, Index, Gfx.Pad(" " .. Text, W), Th.AccentFg, Th.Accent)
			else
				Gfx.Write(T, 1, Index, Gfx.Pad(" " .. Text, W), Disabled and Th.MenuDim or Th.MenuFg, Th.MenuBg)
			end
		end
	end
	local function Selectable(Index)
		local Item = Items[Index]
		if (not Item) then return false end
		local Text = type(Item) == "table" and Item.Text or Item
		return Text ~= "-" and not (type(Item) == "table" and Item.Disabled)
	end
	function Modal:OnOutside()
		self.Running = false
	end
	function Modal:OnEvent(Name, A, MouseX, MouseY)
		if (Name == "mouse_click" or (Name == "mouse_up" and self.Dragged)) then
			local Index = MouseY - self.Y + 1
			if (Selectable(Index)) then
				self.Result = Index
				self.Running = false
			end
		elseif (Name == "mouse_drag") then
			local Index = MouseY - self.Y + 1
			self.Dragged = true
			if (Selectable(Index)) then self.Hover = Index end
		elseif (Name == "key") then
			if (A == keys.down or A == keys.up) then
				local Step = (A == keys.down) and 1 or -1
				for _ = 1, #Items do
					self.Hover = (self.Hover - 1 + Step) % #Items + 1
					if (Selectable(self.Hover)) then break end
				end
			elseif ((A == keys.enter or A == keys.numPadEnter) and Selectable(self.Hover)) then
				self.Result = self.Hover
				self.Running = false
			elseif (A == keys.backspace) then
				self.Running = false
			end
		end
	end
	return RunModal(Modal)
end

-- File chooser. Opts: Title, Dir, Save (ask for a file name), Extension, Folders (pick folder).
function Ui.PickFile(Opts)
	Opts = Opts or {}
	local Parent = (Ui.Current and Ui.Current.Parent) or term.current()
	local ScreenW, ScreenH = Parent.getSize()
	local W = math.min(ScreenW - 2, 40)
	local H = math.min(ScreenH - 2, 16)
	local Modal = CreateModal(W, H, Parent)
	local Dir = fs.combine(Opts.Dir or "home", "")
	if (not fs.isDir(Dir)) then Dir = "" end
	DrawModalTitle(Modal, Opts.Title or (Opts.Save and "Save As" or "Open"))
	local PathLabel = Modal:Add(Ui.Label.new({ X = 2, Y = 2, W = W - 2, Fg = "SubText" }))
	local Files = Modal:Add(Ui.List.new({ X = 2, Y = 3, W = W - 2, H = H - (Opts.Save and 6 or 5), Bg = "MenuBg" }))
	local NameField
	if (Opts.Save) then
		NameField = Modal:Add(Ui.Input.new({ X = 2, Y = H - 2, W = W - 2, Value = Opts.Name or "", Placeholder = "File name" }))
		NameField:SelectAll()
	end
	local function Refresh()
		PathLabel.Text = "/" .. Dir
		local Items = {}
		if (Dir ~= "") then
			table.insert(Items, { Text = "..", Icon = "\24", IconFg = "SubText", Up = true })
		end
		local Names = fs.list(Dir)
		table.sort(Names, function(A, B) return A:lower() < B:lower() end)
		for _, Name in ipairs(Names) do
			local Path = fs.combine(Dir, Name)
			if (fs.isDir(Path)) then
				table.insert(Items, { Text = Name, Icon = "\16", IconFg = colors.lightBlue, Path = Path, Dir = true })
			end
		end
		if (not Opts.Folders) then
			for _, Name in ipairs(Names) do
				local Path = fs.combine(Dir, Name)
				if (not fs.isDir(Path) and (not Opts.Extension or Name:sub(-#Opts.Extension) == Opts.Extension)) then
					table.insert(Items, { Text = Name, Icon = "\7", IconFg = "SubText", Path = Path })
				end
			end
		end
		Files:SetItems(Items)
	end
	local function Finish()
		if (Opts.Save) then
			if (#NameField.Value == 0) then return end
			Modal.Result = "/" .. fs.combine(Dir, NameField.Value)
		elseif (Opts.Folders) then
			Modal.Result = "/" .. Dir
		else
			local Item = Files.Items[Files.Selected]
			if (not Item or Item.Dir or Item.Up) then return end
			Modal.Result = "/" .. Item.Path
		end
		Modal.Running = false
	end
	Files.OnActivate = function(_, _, Item)
		if (Item.Up) then
			Dir = fs.getDir(Dir)
			Refresh()
		elseif (Item.Dir) then
			Dir = Item.Path
			Refresh()
		else
			Finish()
		end
	end
	Files.OnSelect = function(_, _, Item)
		if (NameField and Item and not Item.Dir and not Item.Up) then
			NameField:SetValue(fs.getName(Item.Path))
		end
	end
	if (NameField) then
		NameField.OnSubmit = Finish
	end
	Modal:Add(Ui.Button.new({
		X = W - 18, Y = H - 1, W = 8, Text = "Cancel",
		OnClick = function()
			Modal.Running = false
		end
	}))
	Modal:Add(Ui.Button.new({
		X = W - 9, Y = H - 1, W = 8, Text = Opts.Save and "Save" or (Opts.Folders and "Choose" or "Open"), Style = "primary",
		OnClick = Finish
	}))
	Refresh()
	Modal:SetFocus(NameField or Files)
	return RunModal(Modal)
end

return Ui
