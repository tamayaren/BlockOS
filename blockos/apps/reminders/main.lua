-- Reminders: smart lists, custom lists, due times and priorities.
-- Quick entry: "Buy bread !! @ tomorrow 9:00" sets priority 2 and a due time.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Schedule = BlockOS.Require("schedule")

local Page = Ui.Page.new()
local Data = Schedule.Load()
local Current = { Kind = "smart", ID = "today" }
local Build

local Smart = {
	{ ID = "today", Name = "Today", Icon = "\15", Color = colors.blue },
	{ ID = "scheduled", Name = "Scheduled", Icon = "\4", Color = colors.red },
	{ ID = "all", Name = "All", Icon = "\7", Color = colors.gray },
	{ ID = "done", Name = "Completed", Icon = "x", Color = colors.green }
}

local function EndOfToday()
	local Now = Schedule.Now()
	local Today = os.date("!*t", Now)
	return Now - (Today.hour * 3600 + Today.min * 60 + Today.sec) + 86399
end

local function Matches(Reminder)
	if (Current.Kind == "list") then
		return Reminder.List == Current.ID and not Reminder.Done
	end
	if (Current.ID == "done") then return Reminder.Done end
	if (Reminder.Done) then return false end
	if (Current.ID == "today") then
		return Reminder.Due ~= nil and Reminder.Due <= EndOfToday()
	elseif (Current.ID == "scheduled") then
		return Reminder.Due ~= nil
	end
	return true
end

local function Visible()
	local Result = {}
	for _, Reminder in ipairs(Data.Reminders) do
		if (Matches(Reminder)) then
			table.insert(Result, Reminder)
		end
	end
	table.sort(Result, function(A, B)
		if ((A.Due ~= nil) ~= (B.Due ~= nil)) then return A.Due ~= nil end
		if (A.Due and B.Due and A.Due ~= B.Due) then return A.Due < B.Due end
		if ((A.Priority or 0) ~= (B.Priority or 0)) then return (A.Priority or 0) > (B.Priority or 0) end
		return A.ID < B.ID
	end)
	return Result
end

local function CountFor(Kind, ID)
	local Saved = Current
	Current = { Kind = Kind, ID = ID }
	local Count = #Visible()
	Current = Saved
	return Count
end

local function CurrentName()
	if (Current.Kind == "list") then return Current.ID end
	for _, Entry in ipairs(Smart) do
		if (Entry.ID == Current.ID) then return Entry.Name end
	end
	return ""
end

local function QuickAdd(Text)
	Text = Text:gsub("^%s+", ""):gsub("%s+$", "")
	if (#Text == 0) then return end
	local Due
	local Title, DueText = Text:match("^(.-)%s*@%s*(.+)$")
	if (Title) then
		Due = Schedule.ParseDue(DueText)
		if (not Due) then
			Ui.Alert("Reminders", "Could not understand \"" .. DueText .. "\". Try \"in 10m\", \"14:30\", \"tomorrow 9:00\" or \"2026-11-02 08:00\".")
			return
		end
		Text = Title
	end
	local Bangs = Text:match("(!+)%s*$")
	local Priority = 0
	if (Bangs) then
		Priority = math.min(3, #Bangs)
		Text = Text:gsub("%s*!+%s*$", "")
	end
	if (not Due and Current.Kind == "smart" and Current.ID == "today") then
		Due = EndOfToday() - 59
	end
	Schedule.AddReminder({
		Title = Text,
		Due = Due,
		Priority = Priority,
		List = (Current.Kind == "list") and Current.ID or (Data.Lists[1] or "Personal")
	})
end

local function EditMenu(Reminder, X, Y)
	local Options = { Reminder.Done and "Mark Incomplete" or "Mark Complete", "Rename...", "Set Due...", "Clear Due", "Priority...", "Move to List...", "Notes...", "-", "Delete" }
	local Choice = Options[Ui.ContextMenu(X, Y, Options) or 0]
	if (Choice == "Mark Complete" or Choice == "Mark Incomplete") then
		Reminder.Done = not Reminder.Done
	elseif (Choice == "Rename...") then
		Reminder.Title = Ui.Prompt("Rename", "Title:", Reminder.Title) or Reminder.Title
	elseif (Choice == "Set Due...") then
		local Text = Ui.Prompt("Due", "When? (in 10m, 14:30, tomorrow 9:00)", "")
		local Due = Text and Schedule.ParseDue(Text)
		if (Due) then
			Reminder.Due = Due
			Reminder.Notified = false
		elseif (Text) then
			Ui.Alert("Due", "That time was not understood.")
		end
	elseif (Choice == "Clear Due") then
		Reminder.Due = nil
	elseif (Choice == "Priority...") then
		local Index = Ui.Choose("Priority", { "None", "Low (!)", "Medium (!!)", "High (!!!)" }, (Reminder.Priority or 0) + 1)
		if (Index) then Reminder.Priority = Index - 1 end
	elseif (Choice == "Move to List...") then
		local Index = Ui.Choose("Move to", Data.Lists)
		if (Index) then Reminder.List = Data.Lists[Index] end
	elseif (Choice == "Notes...") then
		Reminder.Notes = Ui.Prompt("Notes", Reminder.Title, Reminder.Notes or "") or Reminder.Notes
	elseif (Choice == "Delete") then
		Schedule.RemoveReminder(Reminder.ID)
		Build()
		return
	end
	Schedule.Save()
	Build()
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local SideW = (W >= 36) and 14 or 0
	local Sidebar = Page:Add(Ui.List.new({ X = 1, Y = 1, W = SideW, H = H - 1, Bg = "Panel", SingleClick = true, Focusable = false, Visible = SideW > 0 }))
	local Entries = {}
	local Selected = 0
	for _, Entry in ipairs(Smart) do
		table.insert(Entries, { Text = Entry.Name, Icon = Entry.Icon, IconFg = Entry.Color, Right = tostring(CountFor("smart", Entry.ID)), Kind = "smart", ID = Entry.ID })
		if (Current.Kind == "smart" and Current.ID == Entry.ID) then Selected = #Entries end
	end
	table.insert(Entries, { Text = "My Lists", Header = true })
	for _, Name in ipairs(Data.Lists) do
		table.insert(Entries, { Text = Name, Icon = "\7", IconFg = colors.orange, Right = tostring(CountFor("list", Name)), Kind = "list", ID = Name })
		if (Current.Kind == "list" and Current.ID == Name) then Selected = #Entries end
	end
	Sidebar:SetItems(Entries)
	Sidebar.Selected = Selected
	Sidebar.OnActivate = function(_, _, Item)
		if (Item.Header) then return end
		Current = { Kind = Item.Kind, ID = Item.ID }
		Build()
	end
	Sidebar.OnContext = function(_, _, Item, X, Y)
		local Options = { "New List..." }
		if (Item and Item.Kind == "list") then
			table.insert(Options, "Rename List...")
			table.insert(Options, "Delete List")
		end
		local Choice = Options[Ui.ContextMenu(X, Y, Options) or 0]
		if (Choice == "New List...") then
			local Name = Ui.Prompt("New List", "Name:", "")
			if (Name and #Name > 0) then
				table.insert(Data.Lists, Name)
				Schedule.Save()
				Current = { Kind = "list", ID = Name }
			end
		elseif (Choice == "Rename List...") then
			local Name = Ui.Prompt("Rename List", "Name:", Item.ID)
			if (Name and #Name > 0) then
				for Index, Existing in ipairs(Data.Lists) do
					if (Existing == Item.ID) then Data.Lists[Index] = Name end
				end
				for _, Reminder in ipairs(Data.Reminders) do
					if (Reminder.List == Item.ID) then Reminder.List = Name end
				end
				Current = { Kind = "list", ID = Name }
				Schedule.Save()
			end
		elseif (Choice == "Delete List") then
			if (Ui.Confirm("Delete List", "Delete \"" .. Item.ID .. "\" and its reminders?", "Delete")) then
				for Index = #Data.Lists, 1, -1 do
					if (Data.Lists[Index] == Item.ID) then table.remove(Data.Lists, Index) end
				end
				for Index = #Data.Reminders, 1, -1 do
					if (Data.Reminders[Index].List == Item.ID) then table.remove(Data.Reminders, Index) end
				end
				Current = { Kind = "smart", ID = "all" }
				Schedule.Save()
			end
		end
		Build()
	end
	Page:Add(Ui.Button.new({ X = 1, Y = H, W = math.max(SideW, 1), Text = "+ List", Bg = "Panel", Visible = SideW > 0, OnClick = function()
		local Name = Ui.Prompt("New List", "Name:", "")
		if (Name and #Name > 0) then
			table.insert(Data.Lists, Name)
			Schedule.Save()
			Current = { Kind = "list", ID = Name }
			Build()
		end
	end }))

	local MainX = SideW + 2
	local MainW = W - SideW - 2
	local Items = Visible()
	Page:Add(Ui.Label.new({ X = MainX, Y = 1, W = MainW - 4, Text = CurrentName(), Fg = "Accent" }))
	Page:Add(Ui.Label.new({ X = MainX + MainW - 4, Y = 1, W = 4, Text = tostring(#Items), Fg = "SubText", Align = "right" }))
	local List = Page:Add(Ui.List.new({ X = MainX, Y = 3, W = MainW, H = H - 4 }))
	local Rows = {}
	for _, Reminder in ipairs(Items) do
		table.insert(Rows, { Reminder = Reminder })
	end
	List:SetItems(Rows)
	List.RenderItem = function(_, T, Th, Item, X, Y, Width, IsSelected, RowBg, RowFg)
		local Reminder = Item.Reminder
		local Box = Reminder.Done and "\7" or "o"
		Gfx.Write(T, X, Y, Box, Reminder.Done and Th.Accent or Th.SubText, RowBg)
		local Bang = string.rep("!", Reminder.Priority or 0)
		local Due = Reminder.Due and Schedule.FormatDue(Reminder.Due) or ""
		local Overdue = Reminder.Due and not Reminder.Done and Reminder.Due < Schedule.Now()
		local TitleW = Width - 2 - #Due - 1
		local Title = (#Bang > 0 and (Bang .. " ") or "") .. Reminder.Title .. (Reminder.Notes and " \26" or "")
		Gfx.Write(T, X + 2, Y, Gfx.Truncate(Title, TitleW), IsSelected and RowFg or (Reminder.Done and Th.SubText or Th.Text), RowBg)
		if (#Due > 0) then
			Gfx.Write(T, X + Width - #Due, Y, Due, IsSelected and RowFg or (Overdue and colors.red or Th.SubText), RowBg)
		end
	end
	List.OnActivate = function(_, _, Item)
		Item.Reminder.Done = not Item.Reminder.Done
		Schedule.Save()
		Build()
	end
	List.OnContext = function(_, _, Item, X, Y)
		if (Item) then EditMenu(Item.Reminder, X, Y) end
	end
	if (#Rows == 0) then
		Page:Add(Ui.Label.new({ X = MainX, Y = 4, W = MainW, H = 2, Text = "No reminders. Type below to add one.", Fg = "SubText" }))
	end
	local Entry = Page:Add(Ui.Input.new({ X = MainX, Y = H, W = MainW, Placeholder = "+ New reminder  (!! priority, @ in 10m)" }))
	Entry.OnSubmit = function(Self, Value)
		QuickAdd(Value)
		Self:SetValue("")
		Build()
	end
	Page:SetFocus(Entry)
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name)
	if (Name == "blockos_schedule") then
		if (not (self.Focus and self.Focus.Value and #self.Focus.Value > 0)) then
			Build()
		end
		return true
	end
	return false
end

Page:Run()
