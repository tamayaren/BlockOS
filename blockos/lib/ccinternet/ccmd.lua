-- .ccmd parser: turns page source into a document tree that any browser can lay out.
-- Pure Lua with no CC: Tweaked APIs, so it can also run outside the game.
-- Vendored from https://github.com/tamayaren/ccinternet (lib/ccmd.lua), shared by Savannah and CCDream.

local Ccmd = {}

Ccmd.Version = 1

-- Colour names map to blit characters ("0" white .. "f" black).
local ColourNames = {
	white = "0", orange = "1", magenta = "2", lightblue = "3", yellow = "4", lime = "5",
	pink = "6", gray = "7", grey = "7", lightgray = "8", lightgrey = "8", silver = "8",
	cyan = "9", purple = "a", blue = "b", brown = "c", green = "d", red = "e", black = "f"
}

Ccmd.Defaults = {
	Background = "f",
	TextColor = "0",
	LinkColor = "3",
	TopbarColor = "7",
	TopbarTextColor = "0",
	HeaderColor = "7",
	InputColor = "8",
	InputTextColor = "f",
	ButtonColor = "b",
	ButtonTextColor = "0",
	InputWidth = 20
}

-- Tags the parser understands. Anything else that looks like a tag stays as text.
local Containers = { topbar = true, p = true, table = true, button = true }
local Voids = { br = true, img = true, input = true }
local Known = { topbar = true, p = true, table = true, button = true, br = true, img = true, input = true, form = true }

local InputTypes = { text = true, password = true, file = true, hidden = true }

-- Returns the blit character for a colour name, or nil when it is not a colour.
function Ccmd.Colour(Name)
	if (type(Name) ~= "string") then return nil end
	local Key = Name:lower():gsub("[%s_%-]", "")
	if (ColourNames[Key]) then return ColourNames[Key] end
	if (Key:match("^[0-9a-f]$")) then return Key end
	return nil
end

-- Escapes text so it shows literally inside a page (used for server-generated pages).
function Ccmd.Escape(Text)
	Text = tostring(Text or "")
	Text = Text:gsub("[\\%[%]{}<]", "\\%0")
	Text = Text:gsub("\n#", "\n\\#")
	if (Text:sub(1, 1) == "#") then Text = "\\" .. Text end
	return Text
end

-- Makes a value safe to put inside a quoted attribute.
function Ccmd.Attribute(Text)
	return (tostring(Text or ""):gsub("[\"\n\r>]", ""))
end

local function Trim(Text)
	return (Text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function SplitLines(Source)
	local Lines = {}
	Source = Source:gsub("\r\n?", "\n")
	for Line in (Source .. "\n"):gmatch("(.-)\n") do
		Lines[#Lines + 1] = Line
	end
	return Lines
end

local function IsComment(Line)
	return Line:match("^%s*#") ~= nil
end

local function ParseAttributes(Text)
	local Attributes = {}
	local Pos = 1
	while (Pos <= #Text) do
		local A, B, Key, Value = Text:find("^%s*([%a_][%w_%-]*)%s*=%s*\"(.-)\"", Pos)
		if (not A) then A, B, Key, Value = Text:find("^%s*([%a_][%w_%-]*)%s*=%s*'(.-)'", Pos) end
		if (not A) then A, B, Key, Value = Text:find("^%s*([%a_][%w_%-]*)%s*=%s*([^%s\"']+)", Pos) end
		if (not A) then
			A, B, Key = Text:find("^%s*([%a_][%w_%-]*)", Pos)
			Value = "true"
		end
		if (not A) then break end
		Attributes[Key:lower()] = Value
		Pos = B + 1
	end
	return Attributes
end

-- Reads the front matter. Returns the metadata table, the index of the first body line and an error.
function Ccmd.ParseFrontMatter(Source)
	local Lines = type(Source) == "table" and Source or SplitLines(Source or "")
	local Index = 1
	while (Lines[Index] and (Trim(Lines[Index]) == "" or IsComment(Lines[Index]))) do
		Index = Index + 1
	end
	if (not Lines[Index] or not Trim(Lines[Index]):match("^%-%-%-?$")) then
		return nil, Index, "Missing front matter (the page must start with --)"
	end
	local Meta = {}
	Index = Index + 1
	while (Lines[Index]) do
		local Line = Trim(Lines[Index])
		if (Line:match("^%-%-%-?$")) then
			if (not Meta.title or Meta.title == "") then return Meta, Index + 1, "Front matter needs a title" end
			if (not Meta.location or Meta.location == "") then return Meta, Index + 1, "Front matter needs a location" end
			return Meta, Index + 1, nil
		end
		if (Line ~= "" and not IsComment(Line)) then
			local Key, Value = Line:match("^([%w_%-]+)%s*:%s*(.-)$")
			if (Key) then Meta[Key:lower()] = Value end
		end
		Index = Index + 1
	end
	return nil, Index, "Front matter is never closed (add a -- line)"
end

-- Parses inline markup: [text](url) links, {colour}...{/} and {colour on colour}...{/} spans, \ escapes.
-- Returns a list of spans { Text, Fg, Bg, Href } where Fg/Bg are blit characters or nil.
function Ccmd.ParseInline(Text)
	local Spans = {}
	local Stack = {}
	local Buffer = {}
	local Pos = 1

	local function Current()
		return Stack[#Stack] or {}
	end

	local function Flush()
		if (#Buffer == 0) then return end
		local Style = Current()
		local Value = table.concat(Buffer)
		Buffer = {}
		local Last = Spans[#Spans]
		if (Last and not Last.Href and Last.Fg == Style.Fg and Last.Bg == Style.Bg) then
			Last.Text = Last.Text .. Value
		else
			Spans[#Spans + 1] = { Text = Value, Fg = Style.Fg, Bg = Style.Bg }
		end
	end

	while (Pos <= #Text) do
		local Char = Text:sub(Pos, Pos)
		if (Char == "\\" and Pos < #Text) then
			Buffer[#Buffer + 1] = Text:sub(Pos + 1, Pos + 1)
			Pos = Pos + 2
		elseif (Char == "[") then
			local A, B, Label, Href = Text:find("^%[([^%]]*)%]%(([^%)]*)%)", Pos)
			if (A) then
				Flush()
				local Style = Current()
				Spans[#Spans + 1] = { Text = Label:gsub("\\(.)", "%1"), Href = Trim(Href), Fg = Style.Fg, Bg = Style.Bg, Link = true }
				Pos = B + 1
			else
				Buffer[#Buffer + 1] = Char
				Pos = Pos + 1
			end
		elseif (Char == "{") then
			local A, B, Inner = Text:find("^{([^{}]*)}", Pos)
			local Handled = false
			if (A) then
				Inner = Trim(Inner)
				if (Inner == "/") then
					Flush()
					Stack[#Stack] = nil
					Handled = true
				else
					local FgName, BgName = Inner:match("^(.-)%s+on%s+(.-)$")
					local Fg, Bg
					if (FgName) then
						Fg, Bg = Ccmd.Colour(FgName), Ccmd.Colour(BgName)
						if (FgName == "" or BgName == "") then Fg = nil end
					else
						Fg = Ccmd.Colour(Inner)
						Bg = Current().Bg
					end
					if (Fg and (Bg or not FgName)) then
						Flush()
						Stack[#Stack + 1] = { Fg = Fg, Bg = Bg }
						Handled = true
					end
				end
			end
			if (Handled) then
				Pos = B + 1
			else
				Buffer[#Buffer + 1] = Char
				Pos = Pos + 1
			end
		else
			Buffer[#Buffer + 1] = Char
			Pos = Pos + 1
		end
	end
	Flush()
	return Spans
end

-- Removes the indentation shared by every non-blank line.
local function Dedent(Lines)
	local Common
	for _, Line in ipairs(Lines) do
		if (Trim(Line) ~= "") then
			local Indent = #Line:match("^[ \t]*")
			if (not Common or Indent < Common) then Common = Indent end
		end
	end
	if (Common and Common > 0) then
		for Index, Line in ipairs(Lines) do
			Lines[Index] = Line:sub(Common + 1)
		end
	end
	return Lines
end

local function Alignment(Attributes)
	local Value = (Attributes.alignment or Attributes.align or "left"):lower()
	if (Value == "centre") then Value = "center" end
	if (Value ~= "center" and Value ~= "right") then Value = "left" end
	return Value
end

local function SplitCells(Line)
	Line = Trim(Line)
	local Cells = {}
	local Buffer = {}
	local Pos = 1
	if (Line:sub(1, 1) == "|") then Pos = 2 end
	while (Pos <= #Line) do
		local Char = Line:sub(Pos, Pos)
		if (Char == "\\" and Line:sub(Pos + 1, Pos + 1) == "|") then
			Buffer[#Buffer + 1] = "|"
			Pos = Pos + 2
		elseif (Char == "|") then
			Cells[#Cells + 1] = Trim(table.concat(Buffer))
			Buffer = {}
			Pos = Pos + 1
		else
			Buffer[#Buffer + 1] = Char
			Pos = Pos + 1
		end
	end
	local Rest = Trim(table.concat(Buffer))
	if (Rest ~= "") then Cells[#Cells + 1] = Rest end
	return Cells
end

local function ParseTable(Inner, Attributes)
	local Rows = {}
	for _, Line in ipairs(SplitLines(Inner)) do
		if (Trim(Line):sub(1, 1) == "|") then
			Rows[#Rows + 1] = SplitCells(Line)
		end
	end
	local Block = {
		Type = "table",
		HeaderColor = Ccmd.Colour(Attributes["header-color"]) or Ccmd.Defaults.HeaderColor,
		HeaderTextColor = Ccmd.Colour(Attributes["header-text-color"]),
		TextColor = Ccmd.Colour(Attributes["text-color"]),
		Color = Ccmd.Colour(Attributes.color),
		Align = {},
		Header = nil,
		Rows = {}
	}
	local Start = 1
	local Separator = Rows[2]
	local IsSeparator = Separator ~= nil and #Separator > 0
	if (Separator) then
		for _, Cell in ipairs(Separator) do
			if (not Cell:match("^:?%-+:?$")) then IsSeparator = false end
		end
	end
	if (IsSeparator) then
		for Column, Cell in ipairs(Separator) do
			local Left, Right = Cell:sub(1, 1) == ":", Cell:sub(-1) == ":"
			Block.Align[Column] = (Left and Right) and "center" or (Right and "right") or "left"
		end
		Block.Header = {}
		for Column, Cell in ipairs(Rows[1]) do
			Block.Header[Column] = Ccmd.ParseInline(Cell)
		end
		Start = 3
	end
	for Index = Start, #Rows do
		local Row = {}
		for Column, Cell in ipairs(Rows[Index]) do
			Row[Column] = Ccmd.ParseInline(Cell)
		end
		Block.Rows[#Block.Rows + 1] = Row
	end
	local Columns = Block.Header and #Block.Header or 0
	for _, Row in ipairs(Block.Rows) do
		if (#Row > Columns) then Columns = #Row end
	end
	Block.Columns = Columns
	return Block
end

local function TextLines(Inner, KeepBlank)
	local Lines = SplitLines(Inner)
	if (KeepBlank) then
		while (Lines[1] and Trim(Lines[1]) == "") do table.remove(Lines, 1) end
		while (Lines[#Lines] and Trim(Lines[#Lines]) == "") do table.remove(Lines) end
		Dedent(Lines)
	end
	local Result = {}
	for _, Line in ipairs(Lines) do
		Line = Line:gsub("%s+$", "")
		if (not KeepBlank) then Line = Line:gsub("^%s+", "") end
		if (KeepBlank or Line ~= "") then
			Result[#Result + 1] = Ccmd.ParseInline((Line:gsub("\t", "    ")))
		end
	end
	return Result
end

-- Parses a whole page. Always returns a document; problems are listed in Doc.Errors.
function Ccmd.Parse(Source)
	local Lines = SplitLines(Source or "")
	local Doc = {
		Meta = {},
		Title = "Untitled",
		Location = "/",
		Blocks = {},
		Inputs = {},
		Forms = {},
		Errors = {}
	}

	local Meta, BodyStart, Problem = Ccmd.ParseFrontMatter(Lines)
	if (Problem) then Doc.Errors[#Doc.Errors + 1] = Problem end
	if (not Meta) then
		Meta = {}
		BodyStart = 1
	end
	Doc.Meta = Meta
	Doc.Title = Meta.title and Meta.title ~= "" and Meta.title or Doc.Title
	Doc.Location = Meta.location and Meta.location ~= "" and Meta.location or Doc.Location
	Doc.Background = Ccmd.Colour(Meta.background) or Ccmd.Defaults.Background
	Doc.TextColor = Ccmd.Colour(Meta["text-color"]) or Ccmd.Defaults.TextColor
	Doc.LinkColor = Ccmd.Colour(Meta["link-color"]) or Ccmd.Defaults.LinkColor

	-- Drop comment lines and turn \# at the start of a line into #.
	local Body = {}
	for Index = BodyStart, #Lines do
		local Line = Lines[Index]
		if (not IsComment(Line)) then
			Body[#Body + 1] = (Line:gsub("^(%s*)\\#", "%1#"))
		end
	end
	local Text = table.concat(Body, "\n")
	local Lower = Text:lower()

	local Target = Doc.Blocks
	local CurrentForm = nil

	local function AddText(Chunk)
		local Result = TextLines(Chunk, false)
		if (#Result > 0) then
			Target[#Target + 1] = { Type = "text", Align = "left", Lines = Result }
		end
	end

	local Pos = 1
	local TextStart = 1
	while (Pos <= #Text) do
		local Start = Text:find("<", Pos, true)
		if (not Start) then break end
		local A, B, Slash, Name, AttrStart, AttrEnd, SelfClose = Lower:find("^<(/?)([%a][%w%-]*)()[^<>]-()(/?)>", Start)
		if (A and Known[Name]) then
			AddText(Text:sub(TextStart, Start - 1))
			local Attributes = ParseAttributes(Text:sub(AttrStart, AttrEnd - 1))
			local Closing = Slash == "/"
			local Next = B + 1
			if (Closing) then
				if (Name == "form" and CurrentForm) then
					Target = Doc.Blocks
					CurrentForm = nil
				else
					Doc.Errors[#Doc.Errors + 1] = "Unexpected </" .. Name .. ">"
				end
			elseif (Name == "form") then
				if (CurrentForm) then
					Doc.Errors[#Doc.Errors + 1] = "Forms cannot be nested"
				else
					local Method = (Attributes.method or "POST"):upper()
					if (Method ~= "GET") then Method = "POST" end
					CurrentForm = { Type = "form", Action = Attributes.action, Method = Method, Blocks = {}, Index = #Doc.Forms + 1 }
					Doc.Forms[#Doc.Forms + 1] = CurrentForm
					Doc.Blocks[#Doc.Blocks + 1] = CurrentForm
					Target = CurrentForm.Blocks
				end
			elseif (Containers[Name] and SelfClose ~= "/") then
				local CloseA, CloseB = Lower:find("</%s*" .. Name .. "%s*>", B + 1)
				local Inner
				if (CloseA) then
					Inner = Text:sub(B + 1, CloseA - 1)
					Next = CloseB + 1
				else
					Doc.Errors[#Doc.Errors + 1] = "<" .. Name .. "> is never closed"
					Inner = Text:sub(B + 1)
					Next = #Text + 1
				end
				if (Name == "topbar") then
					local Layout = (Attributes.layout or "horizontal"):lower()
					Doc.Topbar = {
						Color = Ccmd.Colour(Attributes.color) or Ccmd.Defaults.TopbarColor,
						TextColor = Ccmd.Colour(Attributes["text-color"]) or Ccmd.Defaults.TopbarTextColor,
						Layout = Layout == "vertical" and "vertical" or "horizontal",
						Items = TextLines(Inner, false)
					}
				elseif (Name == "p") then
					Inner = Inner:gsub("<[bB][rR]%s*/?>", "\n")
					Target[#Target + 1] = {
						Type = "text",
						Align = Alignment(Attributes),
						TextColor = Ccmd.Colour(Attributes["text-color"]),
						Color = Ccmd.Colour(Attributes.color),
						Lines = TextLines(Inner, true)
					}
				elseif (Name == "table") then
					Target[#Target + 1] = ParseTable(Inner, Attributes)
				elseif (Name == "button") then
					Attributes.text = Attributes.text or Trim(Inner)
					Name = "button"
				end
			end
			if (Name == "button" and not Closing) then
				local Block = {
					Type = "button",
					Text = Attributes.text or "Submit",
					Name = Attributes.name,
					Value = Attributes.value,
					Href = Attributes.href,
					Align = Alignment(Attributes),
					Color = Ccmd.Colour(Attributes.color) or Ccmd.Defaults.ButtonColor,
					TextColor = Ccmd.Colour(Attributes["text-color"]) or Ccmd.Defaults.ButtonTextColor,
					Form = CurrentForm and CurrentForm.Index or nil
				}
				Target[#Target + 1] = Block
			elseif (not Closing and Voids[Name]) then
				if (Name == "br") then
					Target[#Target + 1] = { Type = "break" }
				elseif (Name == "img") then
					if (Attributes.src and Attributes.src ~= "") then
						Target[#Target + 1] = { Type = "image", Src = Attributes.src, Alt = Attributes.alt, Align = Alignment(Attributes) }
					else
						Doc.Errors[#Doc.Errors + 1] = "<img> needs a src"
					end
				elseif (Name == "input") then
					local Kind = (Attributes.type or "text"):lower()
					if (not InputTypes[Kind]) then Kind = "text" end
					local Input = {
						Type = "input",
						Kind = Kind,
						Name = Attributes.name or ("input" .. (#Doc.Inputs + 1)),
						Label = Attributes.label,
						Value = Attributes.value,
						Placeholder = Attributes.placeholder,
						Width = math.max(1, math.min(tonumber(Attributes.width) or Ccmd.Defaults.InputWidth, 200)),
						Color = Ccmd.Colour(Attributes.color) or Ccmd.Defaults.InputColor,
						TextColor = Ccmd.Colour(Attributes["text-color"]) or Ccmd.Defaults.InputTextColor,
						Form = CurrentForm and CurrentForm.Index or nil,
						Id = #Doc.Inputs + 1
					}
					Doc.Inputs[#Doc.Inputs + 1] = Input
					Target[#Target + 1] = Input
				end
			end
			Pos = Next
			TextStart = Next
		else
			Pos = Start + 1
		end
	end
	AddText(Text:sub(TextStart))
	if (CurrentForm) then Doc.Errors[#Doc.Errors + 1] = "<form> is never closed" end
	return Doc
end

-- Collects the fields a form would submit. State maps input Id -> value typed by the user.
-- Button is the button block that was pressed (its name/value is included when set).
function Ccmd.FormFields(Doc, FormIndex, State, Button)
	local Fields = {}
	for _, Input in ipairs(Doc.Inputs) do
		if (Input.Form == FormIndex) then
			local Value = State and State[Input.Id]
			if (Value == nil) then Value = Input.Value or "" end
			Fields[Input.Name] = Value
		end
	end
	if (Button and Button.Name) then Fields[Button.Name] = Button.Value or Button.Text end
	return Fields
end

return Ccmd
