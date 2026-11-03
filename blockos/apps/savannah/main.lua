-- Savannah: the BlockOS web browser for ccinternet (https://github.com/tamayaren/ccinternet).
-- Tabs, favourites, history, find on page, local site previews (local://) and the built-in
-- savannah:// pages. Network requests run as background tasks so the window stays responsive.
-- Args: an address (ccmd://site.com, domain://) or a path to a local .ccmd page.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")
local Theme = BlockOS.Require("theme")
local Ccmd = BlockOS.Require("ccinternet/ccmd")
local Layout = BlockOS.Require("ccinternet/layout")
local Image = BlockOS.Require("ccinternet/image")
local Protocol = BlockOS.Require("ccinternet/protocol")
local Site = BlockOS.Require("ccinternet/site")
local Tasks = BlockOS.Load("/blockos/lib/tasks.lua")

local Args = { ... }
local Page = Ui.Page.new()

local C = {
	DataPath = "/blockos/data/savannah.dat",
	StartPage = "savannah://start",
	MaxHistory = 150,
	MaxTabHistory = 30,
	CachedPages = 8,
	MaxRedirects = 5,
	MaxUpload = 125000,
	MaxImages = 64,
	MaxField = 256,
	MaxMatches = 200,
	MessageTime = 3
}

-- Everything the window shows lives here (CC limits how many locals a file may have).
local S = {
	Tabs = {},
	Current = 1,
	Data = nil,
	Transport = nil,
	Sites = {},     -- local site key -> Site object
	Images = {},    -- absolute image URL -> picture | false
	ImageCount = 0,
	Find = nil,     -- { Query, Matches, Index } while the find bar is open
	Message = nil,
	MessageAt = 0,
	W = {}          -- widgets
}

local Nav = {}
local Internal = {}
local View = {}

--
-- Saved data: settings, favourites, history and known local sites.
--

local function DefaultHost()
	local Host = settings and settings.get("ccinternet.host")
	if (type(Host) == "string" and Host ~= "") then return Host end
	return Protocol.DefaultHost
end

local function LoadData()
	local Data = Config.Read(C.DataPath)
	if (type(Data) ~= "table") then Data = {} end
	if (type(Data.Host) ~= "string" or Data.Host == "") then Data.Host = DefaultHost() end
	if (type(Data.Home) ~= "string" or Data.Home == "") then Data.Home = C.StartPage end
	if (type(Data.Favourites) ~= "table") then
		Data.Favourites = {
			{ Title = "Domains", Url = "domain://" },
			{ Title = "Directory", Url = "domain://directory" }
		}
	end
	if (type(Data.History) ~= "table") then Data.History = {} end
	if (type(Data.Sites) ~= "table") then Data.Sites = {} end
	S.Data = Data
end

local function SaveData()
	Config.Write(C.DataPath, S.Data)
end

local function Say(Text)
	S.Message = Text
	S.MessageAt = os.clock()
	Page:Invalidate()
end

local function SafeUrl(Url)
	return (tostring(Url):gsub("[%(%)%s]", function(Char) return string.format("%%%02X", Char:byte()) end))
end

local function LinkSource(Text, Url)
	return "[" .. Ccmd.Escape((tostring(Text):gsub("[%[%]\n]", ""))) .. "](" .. SafeUrl(Url) .. ")"
end

--
-- Tabs
--

function Nav.Tab()
	return S.Tabs[S.Current]
end

function Nav.NewTabState()
	return { History = {}, Index = 0, Scroll = 0, State = {}, Title = "New Tab" }
end

function Nav.FavouriteIndex(Url)
	for Index, Entry in ipairs(S.Data.Favourites) do
		if (Entry.Url == Url) then return Index end
	end
	return nil
end

--
-- Requests
--

function Nav.LocalSite(Key)
	local Root = S.Data.Sites[Key]
	if (not Root) then return nil end
	if (not S.Sites[Key] or S.Sites[Key].Root ~= "/" .. fs.combine(Root, "")) then
		S.Sites[Key] = Site.New(Root)
	end
	return S.Sites[Key]
end

-- Picks a short name for a local folder, reusing the one it already has.
function Nav.SiteKey(Root)
	Root = "/" .. fs.combine(Root, "")
	for Key, Known in pairs(S.Data.Sites) do
		if ("/" .. fs.combine(Known, "") == Root) then return Key end
	end
	local Base = Root == "/" and "computer" or fs.getName(Root):lower():gsub("[^%w%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if (Base == "") then Base = "site" end
	local Key, Number = Base, 1
	while (S.Data.Sites[Key]) do
		Number = Number + 1
		Key = Base .. "-" .. Number
	end
	S.Data.Sites[Key] = Root
	SaveData()
	return Key
end

local function Response(Status, Source, Headers)
	Headers = Headers or {}
	Headers["Content-Type"] = Headers["Content-Type"] or "text/ccmd"
	return { Status = Status, Headers = Headers, Body = Source }
end

-- Sends one request (no redirects). May block, so it runs inside a task.
function Nav.Request(Parsed, Method, Body, Options)
	if (Parsed.Scheme == "savannah") then
		return Internal.Handle(Method, Parsed, Body)
	elseif (Parsed.Scheme == "local") then
		local Server = Nav.LocalSite(Parsed.Host)
		if (not Server or not fs.isDir(Server.Root)) then
			return Response(404, Site.Message("Folder not found", "Savannah no longer knows where the local site \"" .. Parsed.Host .. "\" is. Open one of its pages again from Finder or File > Open File.", "red"))
		end
		if (Options and Options.Refresh) then Server:Refresh() end
		return Server:Request(Method, Parsed, Body, "local://" .. Parsed.Host)
	elseif (Parsed.Scheme == "ccmd" or Parsed.Scheme == "domain") then
		return S.Transport.Send(Method, Protocol.FormatUrl(Parsed), { Accept = Options and Options.Accept or "text/ccmd" }, Body, Options)
	end
	return nil, Parsed.Scheme .. ":// addresses are not supported."
end

-- Requests a page and follows redirects. Returns the response, the final parsed URL and a problem.
function Nav.Fetch(Tab, Parsed, Method, Body)
	local Result, Problem
	for _ = 1, C.MaxRedirects + 1 do
		Result, Problem = Nav.Request(Parsed, Method, Body, {
			Refresh = true,
			OnProgress = function(Received, Total)
				if (Tab.Loading) then
					Tab.Loading.Received, Tab.Loading.Total = Received, Total
					Page:Invalidate()
				end
			end
		})
		if (not Result) then break end
		local Location = Result.Headers and Result.Headers.Location
		if (Result.Status < 300 or Result.Status >= 400 or type(Location) ~= "string") then break end
		local Next = Protocol.ParseUrl(Location, Parsed)
		if (not Next) then break end
		Parsed, Method, Body = Next, "GET", nil
	end
	return Result, Parsed, Problem
end

local function TextDocument(Title, Text)
	local Lines = {}
	for Line in (tostring(Text):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		Lines[#Lines + 1] = { { Text = (Line:gsub("\t", "    "):gsub("[%z\1-\8\11-\31]", "?")) } }
	end
	local Th = Theme.Get()
	return {
		Title = Title, Location = "/", Meta = {}, Inputs = {}, Forms = {}, Errors = {},
		Blocks = { { Type = "text", Align = "left", Lines = Lines } },
		Background = Gfx.ToBlit(Th.WindowBg), TextColor = Gfx.ToBlit(Th.Text), LinkColor = "3"
	}
end

function Nav.ConnectError(Url, Problem)
	Problem = tostring(Problem or "Unknown error")
	local Text
	if (Problem:find("No modem")) then
		Text = "Savannah can't open the page because this computer isn't connected to the internet.\n\nAttach a wireless or ender modem and try again."
	elseif (Problem:find("Could not find")) then
		Text = "Savannah can't find the ccinternet core named \"" .. S.Data.Host .. "\".\n\nCheck that the core is running and in range, or pick another server in Settings."
	elseif (Problem:find("did not answer")) then
		Text = "The server stopped answering.\n\nIt may be busy or out of range. Try again in a moment."
	else
		Text = Problem
	end
	return Site.Message("Can't open the page", Text, "red", { { "Try again", Url }, { "Settings", "savannah://settings" } })
end

-- Turns a response into a document.
function Nav.Interpret(Result, Parsed)
	local Type = (Result.Headers["Content-Type"] or ""):lower()
	local Name = Parsed.Path:match("[^/]*$")
	if (Name == "") then Name = Parsed.Host end
	if (type(Result.Body) ~= "string") then
		return Ccmd.Parse(Site.Message("Empty response", "The server sent nothing back (status " .. Result.Status .. ")."))
	end
	if (Type == "text/ccmd" or (Type == "" and Parsed.Path:lower():match("%.ccmd$"))) then
		return Ccmd.Parse(Result.Body)
	end
	local Kind = Type:match("^image/(%w+)")
	if (Kind and Image.Extensions[Kind]) then
		local Key = Protocol.FormatUrl(Parsed)
		S.Images[Key] = Image.Parse(Result.Body, Kind) or false
		local Doc = TextDocument(Name, "")
		Doc.Blocks = { { Type = "break" }, { Type = "image", Src = Key, Align = "center", Alt = Name } }
		return Doc
	end
	if (Type:match("^text/")) then return TextDocument(Result.Headers.Title or Name, Result.Body) end
	local Doc = Ccmd.Parse(Site.Message(Name, "This is a " .. Gfx.FormatSize(#Result.Body) .. " file (" .. (Type ~= "" and Type or "unknown type") .. ").", "yellow"))
	table.insert(Doc.Blocks, { Type = "break" })
	table.insert(Doc.Blocks, { Type = "button", Text = "Download", Href = "savannah://save", Align = "center", Color = "b", TextColor = "0" })
	return Doc
end

--
-- Showing pages
--

local function CollectImages(Blocks, Into)
	for _, Block in ipairs(Blocks) do
		if (Block.Type == "image") then Into[#Into + 1] = Block.Src end
		if (Block.Type == "form") then CollectImages(Block.Blocks, Into) end
	end
	return Into
end

function Nav.ImageKey(Tab, Src)
	local Parsed = Tab.Parsed and Protocol.ParseUrl(Src, Tab.Parsed)
	return Parsed and Protocol.FormatUrl(Parsed), Parsed
end

-- Lays the tab's page out for the current view size.
function Nav.Rebuild(Tab)
	if (not Tab.Doc or not S.ViewW) then return end
	Tab.Page = Layout.Build(Tab.Doc, S.ViewW, S.ViewH, {
		State = Tab.State,
		Focus = Tab.Focus,
		Images = function(Src)
			local Key = Nav.ImageKey(Tab, Src)
			if (not Key) then return false end
			return S.Images[Key]
		end
	})
	Tab.Built = S.ViewW .. "x" .. S.ViewH
	Tab.Scroll = math.max(0, math.min(Tab.Scroll, Tab.Page.MaxScroll))
	if (S.Find and Tab == Nav.Tab()) then Nav.FindMatches(false) end
	Page:Invalidate()
end

function Nav.UpdateTitle()
	local Tab = Nav.Tab()
	if (not Tab) then return end
	local Title = Tab.Loading and "Loading..." or (Tab.Doc and Tab.Title) or "Savannah"
	BlockOS.SetTitle(Title)
end

function Nav.LoadImages(Tab)
	if (Tab.ImageTask or not Tab.Doc) then return end
	local Pending, Seen = {}, {}
	for _, Src in ipairs(CollectImages(Tab.Doc.Blocks, {})) do
		local Key, Parsed = Nav.ImageKey(Tab, Src)
		if (Key and S.Images[Key] == nil and not Seen[Key]) then
			Seen[Key] = true
			Pending[#Pending + 1] = { Key = Key, Parsed = Parsed }
		end
	end
	if (#Pending == 0) then return end
	if (S.ImageCount + #Pending > C.MaxImages) then
		S.Images, S.ImageCount = {}, 0
	end
	local Task
	Task = Tasks.Spawn(function()
		for _, Item in ipairs(Pending) do
			local Ok, Result = pcall(Nav.Request, Item.Parsed, "GET", nil, { Accept = "image/*", Timeout = 5 })
			local Picture = false
			if (Ok and Result and Result.Status == 200 and type(Result.Body) == "string") then
				local Kind = (Result.Headers["Content-Type"] or ""):match("^image/(%w+)") or Item.Parsed.Path
				Picture = Image.Parse(Result.Body, Kind) or false
			end
			S.Images[Item.Key] = Picture
			S.ImageCount = S.ImageCount + 1
			Nav.Rebuild(Tab)
		end
	end, function()
		Tab.ImageTask = nil
	end)
	if (not Task.Done) then Tab.ImageTask = Task end
end

-- Puts a document in a tab. Keep holds the scroll position (reload, back and forward).
function Nav.Show(Tab, Doc, Result, Url, Scroll)
	Tab.Doc, Tab.Response, Tab.Url = Doc, Result, Url
	Tab.Parsed = Protocol.ParseUrl(Url)
	Tab.State, Tab.Focus, Tab.Selected = {}, nil, nil
	Tab.Scroll = Scroll or 0
	Tab.Title = Doc.Title or "Untitled"
	Tab.Status = Result and Result.Status or 0
	Tab.Problems = #Doc.Errors
	Nav.Rebuild(Tab)
	if (Scroll and Tab.Page) then Tab.Scroll = math.min(Scroll, Tab.Page.MaxScroll) end
	if (Tab == Nav.Tab()) then Nav.UpdateTitle() end
	Nav.LoadImages(Tab)
end

function Nav.Remember(Url, Title)
	local Scheme = Url:match("^(%a+)://")
	if (Scheme == "savannah") then return end
	local History = S.Data.History
	local Visits = 0
	for Index = #History, 1, -1 do
		if (History[Index].Url == Url) then
			Visits = History[Index].Visits or 1
			table.remove(History, Index)
		end
	end
	table.insert(History, 1, { Url = Url, Title = Title, Time = os.epoch("utc"), Visits = Visits + 1 })
	while (#History > C.MaxHistory) do table.remove(History) end
	SaveData()
end

function Nav.Finish(Tab, Result, Parsed, Problem, Opts)
	local Url = Protocol.FormatUrl(Parsed)
	local Doc
	if (not Result) then
		Doc = Ccmd.Parse(Nav.ConnectError(Url, Problem))
		Result = { Status = 0, Headers = {}, Body = nil }
	else
		Doc = Nav.Interpret(Result, Parsed)
	end
	if (Opts.Replace and Tab.History[Tab.Index]) then
		local Entry = Tab.History[Tab.Index]
		Entry.Url, Entry.Response, Entry.Title = Url, Result, Doc.Title
	else
		for Index = #Tab.History, Tab.Index + 1, -1 do Tab.History[Index] = nil end
		Tab.History[#Tab.History + 1] = { Url = Url, Response = Result, Title = Doc.Title, Scroll = 0 }
		while (#Tab.History > C.MaxTabHistory) do table.remove(Tab.History, 1) end
		Tab.Index = #Tab.History
		for Index = 1, #Tab.History - C.CachedPages do Tab.History[Index].Response = nil end
	end
	Nav.Show(Tab, Doc, Result, Url, Opts.Scroll)
	if (Result.Status > 0 and Result.Status < 400) then Nav.Remember(Url, Doc.Title) end
end

function Nav.Stop(Tab)
	if (Tab.Task) then
		Tasks.Cancel(Tab.Task)
		Tab.Task = nil
	end
	Tab.Loading = nil
	Nav.UpdateTitle()
	Page:Invalidate()
end

-- Opens an address in a tab. Opts: Method, Body, Absolute (ignore the current page),
-- Replace (reload in place) and Scroll.
function Nav.Go(Tab, Target, Opts)
	Opts = Opts or {}
	Target = tostring(Target or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if (Target == "") then return end
	if (Opts.Absolute or not Tab.Parsed) then
		local Path = Target:match("^file://(/.*)$") or Target
		if (not Path:find("://", 1, true) and Path:find("/", 1, true) and fs.exists(Path)) then
			Nav.OpenLocal(Tab, Path)
			return
		end
	end
	local Parsed = Protocol.ParseUrl(Target, (not Opts.Absolute) and Tab.Parsed or nil)
	if (not Parsed) then
		Say("That address could not be read")
		return
	end
	if (Parsed.Scheme == "savannah" and Parsed.Host == "save") then
		Nav.SavePage(Tab)
		return
	end
	Nav.Stop(Tab)
	if (Tab.History[Tab.Index]) then Tab.History[Tab.Index].Scroll = Tab.Scroll end
	Tab.Loading = { Received = 0, Total = 0, Started = os.clock(), Url = Protocol.FormatUrl(Parsed) }
	Tab.Focus, Tab.Selected = nil, nil
	Nav.UpdateTitle()
	local Task
	Task = Tasks.Spawn(function()
		return Nav.Fetch(Tab, Parsed, Opts.Method or "GET", Opts.Body)
	end, function(Ok, Result, Final, Problem)
		Tab.Task, Tab.Loading = nil, nil
		if (not Ok) then Result, Final, Problem = nil, Parsed, Result end
		Nav.Finish(Tab, Result, Final or Parsed, Problem, Opts)
		Nav.UpdateTitle()
		Page:Invalidate()
	end)
	if (not Task.Done) then Tab.Task = Task end
	Page:Invalidate()
end

function Nav.OpenLocal(Tab, Path)
	Path = "/" .. fs.combine(Path, "")
	if (fs.isDir(Path)) then
		local Root = Site.FindRoot(fs.combine(Path, "index.ccmd"))
		Nav.Go(Tab, "local://" .. Nav.SiteKey(Root) .. "/", { Absolute = true })
		return
	end
	local Root = Site.FindRoot(Path)
	local Key = Nav.SiteKey(Root)
	local Server = Nav.LocalSite(Key)
	Server:Refresh()
	local Address = Server:Address(Path) or "/"
	if (Server:Resolve(Address) ~= Server:SitePath(Path)) then Address = Server:SitePath(Path) or "/" end
	Nav.Go(Tab, "local://" .. Key .. Protocol.Escape(Address), { Absolute = true })
end

function Nav.GoHistory(Tab, Index)
	local Entry = Tab.History[Index]
	if (not Entry) then return end
	Nav.Stop(Tab)
	if (Tab.History[Tab.Index]) then Tab.History[Tab.Index].Scroll = Tab.Scroll end
	Tab.Index = Index
	if (Entry.Response) then
		local Parsed = Protocol.ParseUrl(Entry.Url)
		Nav.Show(Tab, Nav.Interpret(Entry.Response, Parsed), Entry.Response, Entry.Url, Entry.Scroll)
	else
		Nav.Go(Tab, Entry.Url, { Absolute = true, Replace = true, Scroll = Entry.Scroll })
	end
end

function Nav.Reload(Tab)
	if (Tab.Loading) then
		Nav.Stop(Tab)
		return
	end
	if (not Tab.Url) then return end
	if (Tab.Doc) then
		for _, Src in ipairs(CollectImages(Tab.Doc.Blocks, {})) do
			local Key = Nav.ImageKey(Tab, Src)
			if (Key) then S.Images[Key] = nil end
		end
	end
	Nav.Go(Tab, Tab.Url, { Absolute = true, Replace = true, Scroll = Tab.Scroll })
end

function Nav.OpenTab(Target, Background)
	local Tab = Nav.NewTabState()
	table.insert(S.Tabs, Tab)
	if (not Background) then S.Current = #S.Tabs end
	View.Relayout()
	Nav.Go(Tab, Target or C.StartPage, { Absolute = true })
	if (not Background and not Target) then Page:SetFocus(S.W.Address) end
	return Tab
end

function Nav.CloseTab(Index)
	local Tab = S.Tabs[Index or S.Current]
	if (not Tab) then return end
	Nav.Stop(Tab)
	if (Tab.ImageTask) then Tasks.Cancel(Tab.ImageTask) end
	table.remove(S.Tabs, Index or S.Current)
	if (#S.Tabs == 0) then
		BlockOS.Quit()
		Page:Stop()
		return
	end
	S.Current = math.max(1, math.min(S.Current, #S.Tabs))
	View.Relayout()
	Nav.UpdateTitle()
end

function Nav.SelectTab(Index)
	if (not S.Tabs[Index]) then return end
	S.Current = Index
	if (S.Find) then Nav.FindMatches(true) end
	Nav.UpdateTitle()
	Page:SetFocus(S.W.View)
	Page:Invalidate()
end

function Nav.ToggleFavourite(Tab)
	if (not Tab.Url or Tab.Url:match("^savannah://")) then return end
	local Index = Nav.FavouriteIndex(Tab.Url)
	if (Index) then
		table.remove(S.Data.Favourites, Index)
		Say("Removed from Favourites")
	else
		table.insert(S.Data.Favourites, { Title = Tab.Title or Tab.Url, Url = Tab.Url })
		Say("Added to Favourites")
	end
	SaveData()
end

function Nav.SavePage(Tab)
	local Body = Tab.Response and Tab.Response.Body
	if (type(Body) ~= "string") then
		Say("Nothing to save")
		return
	end
	local Name = Tab.Parsed and Tab.Parsed.Path:match("[^/]+$")
	if (not Name or Name == "") then
		Name = ((Tab.Parsed and Tab.Parsed.Host ~= "" and Tab.Parsed.Host) or "page"):gsub("[^%w%-]", "_") .. ".ccmd"
	elseif (not Name:find("%.")) then
		Name = Name .. ".ccmd"
	end
	if (not fs.exists("/home/Downloads")) then fs.makeDir("/home/Downloads") end
	local Path = Ui.PickFile({ Title = "Save Page As", Save = true, Dir = "/home/Downloads", Name = Name })
	if (not Path) then return end
	local Handle = fs.open(Path, "wb")
	if (not Handle) then
		Ui.Alert("Save", "Could not write " .. Path)
		return
	end
	Handle.write(Body)
	Handle.close()
	Say("Saved " .. fs.getName(Path))
end

--
-- Forms
--

-- Reads a local file or folder into { [relative path] = contents } for a file field.
local function ReadLocal(Path)
	local Files, Total, Count = {}, 0, 0
	local function Add(Full, Name)
		local Data = Site.ReadFile(Full)
		if (not Data) then return end
		Files[Name] = Data
		Total = Total + #Data
		Count = Count + 1
	end
	local function Walk(Dir, Prefix)
		for _, Name in ipairs(fs.list(Dir)) do
			local Full = fs.combine(Dir, Name)
			if (fs.isDir(Full)) then
				if (Name:sub(1, 1) ~= ".") then Walk(Full, Prefix .. Name .. "/") end
			else
				Add(Full, Prefix .. Name)
			end
		end
	end
	if (fs.isDir(Path)) then Walk(Path, "") else Add(Path, fs.getName(Path)) end
	if (Count == 0) then return nil, "There are no files there." end
	return Files, Total, Count
end

function Nav.Submit(Tab, FormIndex, Button)
	local Form = Tab.Doc and Tab.Doc.Forms[FormIndex]
	if (not Form) then return end
	local Fields = Ccmd.FormFields(Tab.Doc, FormIndex, Tab.State, Button)
	local Action = Form.Action or Tab.Url
	if (Form.Method == "GET") then
		local Parsed = Protocol.ParseUrl(Action, Tab.Parsed)
		if (not Parsed) then return end
		Parsed.Query = Protocol.EncodeQuery(Fields)
		Nav.Go(Tab, Protocol.FormatUrl(Parsed), { Absolute = true })
	else
		Nav.Go(Tab, Action, { Method = "POST", Body = Fields })
	end
end

function Nav.FocusInput(Tab, Input)
	Tab.Focus = Input and Input.Id or nil
	Nav.Rebuild(Tab)
	if (not Input) then return end
	local Region = Layout.InputRegion(Tab.Page, Input.Id)
	if (Region) then Tab.Scroll = Layout.ScrollTo(Tab.Page, Region.Y, Tab.Scroll) end
end

function Nav.NextField(Tab, Input, Wrap)
	local Found, First = false, nil
	for _, Other in ipairs(Tab.Doc.Inputs) do
		local Typable = Other.Form == Input.Form and (Other.Kind == "text" or Other.Kind == "password")
		if (Typable and not First) then First = Other end
		if (Found and Typable) then return Other end
		if (Other == Input) then Found = true end
	end
	if (Wrap and First ~= Input) then return First end
	return nil
end

function Nav.ChooseFiles(Tab, Input, X, Y)
	local Choice = Ui.ContextMenu(X, Y, { "Choose File...", "Choose Folder...", { Text = "Clear", Disabled = Tab.State[Input.Id] == nil } })
	local Path
	if (Choice == 1) then
		Path = Ui.PickFile({ Title = "Choose File", Dir = "/home" })
	elseif (Choice == 2) then
		Path = Ui.PickFile({ Title = "Choose Folder", Dir = "/home", Folders = true })
	elseif (Choice == 3) then
		Tab.State[Input.Id] = nil
	end
	if (Path) then
		local Files, Total, Count = ReadLocal(Path)
		if (not Files) then
			Ui.Alert("Upload", Total)
		elseif (Total > C.MaxUpload) then
			Ui.Alert("Upload", "That is " .. Gfx.FormatSize(Total) .. ". A site holds about " .. Gfx.FormatSize(C.MaxUpload) .. ".")
		else
			Tab.State[Input.Id] = Files
			Say(Count .. (Count == 1 and " file" or " files") .. " ready")
		end
	end
	Nav.Rebuild(Tab)
end

-- Follows a link, presses a button or starts editing a field. X, Y place menus.
function Nav.Activate(Tab, Region, NewTab, X, Y)
	if (Region.Kind == "link" or (Region.Kind == "button" and Region.Button.Href)) then
		local Href = Region.Href or Region.Button.Href
		if (NewTab) then
			local Parsed = Protocol.ParseUrl(Href, Tab.Parsed)
			if (Parsed) then
				Nav.OpenTab(Protocol.FormatUrl(Parsed), true)
				Say("Opened in a new tab")
			end
		else
			Nav.Go(Tab, Href)
		end
	elseif (Region.Kind == "button" and Region.Button.Form) then
		Nav.Submit(Tab, Region.Button.Form, Region.Button)
	elseif (Region.Kind == "input") then
		if (Region.Input.Kind == "file") then
			Nav.ChooseFiles(Tab, Region.Input, X or 2, Y or 2)
		else
			Nav.FocusInput(Tab, Region.Input)
		end
	end
end

-- Typing into the focused field. Returns true when handled.
function Nav.EditField(Tab, Name, A)
	local Input
	for _, Other in ipairs(Tab.Doc.Inputs) do
		if (Other.Id == Tab.Focus) then Input = Other end
	end
	if (not Input) then
		Tab.Focus = nil
		return false
	end
	local Value = Tab.State[Input.Id]
	if (type(Value) ~= "string") then Value = Input.Value or "" end
	if (Name == "char" or Name == "paste") then
		if (Ui.Modifiers.Ctrl) then return true end
		Value = (Value .. A:gsub("[\r\n]", "")):sub(1, C.MaxField)
	elseif (Name == "key") then
		if (A == keys.backspace) then
			Value = Value:sub(1, -2)
		elseif (A == keys.enter or A == keys.numPadEnter) then
			local Next = Nav.NextField(Tab, Input, false)
			if (Next) then
				Nav.FocusInput(Tab, Next)
			elseif (Input.Form) then
				Tab.Focus = nil
				Nav.Submit(Tab, Input.Form, nil)
			else
				Nav.FocusInput(Tab, nil)
			end
			return true
		elseif (A == keys.tab) then
			Nav.FocusInput(Tab, Nav.NextField(Tab, Input, true))
			return true
		elseif (A == keys.up or A == keys.down) then
			Nav.FocusInput(Tab, nil)
			return false
		else
			return true
		end
	else
		return false
	end
	Tab.State[Input.Id] = Value
	Nav.Rebuild(Tab)
	return true
end

--
-- Find on page
--

function Nav.FindMatches(Jump)
	local Find, Tab = S.Find, Nav.Tab()
	Find.Matches = {}
	local Query = Find.Query:lower()
	if (Query == "" or not Tab or not Tab.Page) then
		Find.Index = 0
		return
	end
	for Row, Line in ipairs(Tab.Page.Rows) do
		local Text = Line[1]:lower()
		local From = 1
		while (#Find.Matches < C.MaxMatches) do
			local Start, Finish = Text:find(Query, From, true)
			if (not Start) then break end
			Find.Matches[#Find.Matches + 1] = { Y = Row, X1 = Start, X2 = Finish }
			From = Finish + 1
		end
	end
	if (Jump or Find.Index > #Find.Matches or Find.Index < 1) then
		Find.Index = #Find.Matches > 0 and 1 or 0
		if (Jump) then Nav.FindStep(0) end
	end
end

function Nav.FindStep(Step)
	local Find, Tab = S.Find, Nav.Tab()
	if (not Find or #Find.Matches == 0) then return end
	Find.Index = (Find.Index - 1 + Step) % #Find.Matches + 1
	local Match = Find.Matches[Find.Index]
	Tab.Scroll = Layout.ScrollTo(Tab.Page, Match.Y, Tab.Scroll)
	Page:Invalidate()
end

function Nav.OpenFind()
	if (not S.Find) then
		S.Find = { Query = "", Matches = {}, Index = 0 }
		View.Relayout()
	end
	Page:SetFocus(S.W.FindField)
	S.W.FindField:SelectAll()
end

function Nav.CloseFind()
	S.Find = nil
	View.Relayout()
end

--
-- Built-in savannah:// pages
--

-- Wraps a built-in page. Leading spaces become non-breaking spaces so paragraphs keep
-- their margin (ccmd removes indentation shared by every line of a paragraph).
function Internal.Source(Title, Body)
	local Th = Theme.Get()
	for Index, Line in ipairs(Body) do
		Body[Index] = Line:gsub("^( +)", function(Spaces) return string.rep("\160", #Spaces) end)
	end
	return table.concat({
		"--", "title: " .. Title, "location: /",
		"background: " .. (Th.Dark and "black" or "white"),
		"text-color: " .. (Th.Dark and "white" or "black"),
		"link-color: " .. (Th.Dark and "lightBlue" or "blue"),
		"--",
		table.concat(Body, "\n")
	}, "\n")
end

local function Heading(Body, Text)
	Body[#Body + 1] = "<br/>"
	Body[#Body + 1] = "<p text-color=\"gray\">"
	Body[#Body + 1] = " " .. Ccmd.Escape(Text)
	Body[#Body + 1] = "</p>"
end

local function ShortUrl(Url)
	return (Url:gsub("^ccmd://", ""))
end

function Internal.Start()
	local Body = {
		"<br/>",
		"<p alignment=\"center\">",
		"{orange}\15{/} {yellow}Savannah{/}",
		"{gray}Browse the ccinternet{/}",
		"</p>"
	}
	Heading(Body, "Favourites")
	Body[#Body + 1] = "<p>"
	if (#S.Data.Favourites == 0) then
		Body[#Body + 1] = "  {gray}Press * in the toolbar to add the page you are on.{/}"
	end
	for _, Entry in ipairs(S.Data.Favourites) do
		Body[#Body + 1] = "  {orange}\4{/} " .. LinkSource(Entry.Title, Entry.Url)
	end
	Body[#Body + 1] = "</p>"
	local Frequent = {}
	for _, Entry in ipairs(S.Data.History) do
		if (not Nav.FavouriteIndex(Entry.Url)) then Frequent[#Frequent + 1] = Entry end
	end
	table.sort(Frequent, function(A, B) return (A.Visits or 1) > (B.Visits or 1) end)
	if (#Frequent > 0) then
		Heading(Body, "Frequently Visited")
		Body[#Body + 1] = "<p>"
		for Index = 1, math.min(6, #Frequent) do
			local Entry = Frequent[Index]
			Body[#Body + 1] = "  {gray}\7{/} " .. LinkSource(Entry.Title or Entry.Url, Entry.Url) .. " {gray}" .. Ccmd.Escape(ShortUrl(Entry.Url)) .. "{/}"
		end
		Body[#Body + 1] = "</p>"
	end
	Heading(Body, "Explore")
	Body[#Body + 1] = "<p>"
	Body[#Body + 1] = "  " .. LinkSource("Every site", "domain://directory") .. "   " .. LinkSource("Get a domain", "domain://") .. "   " .. LinkSource("History", "savannah://history")
	Body[#Body + 1] = "</p>"
	return Internal.Source("Start Page", Body)
end

function Internal.Favourites()
	local Body = { "<br/>", "<p alignment=\"center\">", "{orange}\4{/} Favourites", "</p>", "<br/>", "<p>" }
	if (#S.Data.Favourites == 0) then
		Body[#Body + 1] = " {gray}No favourites yet. Press * in the toolbar to add the page you are on.{/}"
	end
	for Index, Entry in ipairs(S.Data.Favourites) do
		Body[#Body + 1] = " " .. LinkSource(Entry.Title, Entry.Url) .. "  {gray}" .. Ccmd.Escape(ShortUrl(Entry.Url)) .. "{/}  " .. LinkSource("Remove", "savannah://favourites?remove=" .. Index)
	end
	Body[#Body + 1] = "</p>"
	return Internal.Source("Favourites", Body)
end

function Internal.History()
	local Body = { "<br/>", "<p alignment=\"center\">", "History", "</p>" }
	local Day
	if (#S.Data.History == 0) then
		Body[#Body + 1] = "<br/>"
		Body[#Body + 1] = "<p alignment=\"center\">"
		Body[#Body + 1] = "{gray}Pages you visit show up here.{/}"
		Body[#Body + 1] = "</p>"
	end
	for _, Entry in ipairs(S.Data.History) do
		local Seconds = math.floor((Entry.Time or 0) / 1000)
		local Date = os.date("%A %d %B", Seconds)
		if (Date ~= Day) then
			if (Day) then Body[#Body + 1] = "</p>" end
			Heading(Body, Date)
			Body[#Body + 1] = "<p>"
			Day = Date
		end
		Body[#Body + 1] = " {gray}" .. os.date("%H:%M", Seconds) .. "{/} " .. LinkSource(Entry.Title or Entry.Url, Entry.Url) .. " {gray}" .. Ccmd.Escape(ShortUrl(Entry.Url)) .. "{/}"
	end
	if (Day) then
		Body[#Body + 1] = "</p>"
		Body[#Body + 1] = "<br/>"
		Body[#Body + 1] = "<button text=\"Clear History\" href=\"savannah://history?clear=yes\" color=\"red\" text-color=\"white\"/>"
	end
	return Internal.Source("History", Body)
end

function Internal.Settings(Message)
	local A = Ccmd.Attribute
	local Body = { "<br/>", "<p alignment=\"center\">", "Settings", "</p>", "<br/>" }
	if (Message) then
		Body[#Body + 1] = "<p alignment=\"center\">"
		Body[#Body + 1] = "{lime}" .. Ccmd.Escape(Message) .. "{/}"
		Body[#Body + 1] = "</p>"
		Body[#Body + 1] = "<br/>"
	end
	local Rest = {
		"<form action=\"savannah://settings\" method=\"POST\">",
		"<input name=\"host\" label=\" Server name\" width=\"22\" value=\"" .. A(S.Data.Host) .. "\" placeholder=\"" .. Protocol.DefaultHost .. "\"/>",
		"<p text-color=\"gray\">",
		" The ccinternet core to use. Keep ccinternet unless",
		" you were told the name of another internet.",
		"</p>",
		"<br/>",
		"<input name=\"home\" label=\" Home page  \" width=\"22\" value=\"" .. A(S.Data.Home) .. "\" placeholder=\"" .. C.StartPage .. "\"/>",
		"<br/>",
		"<button text=\"Save\" alignment=\"center\"/>",
		"</form>",
		"<br/>",
		"<p text-color=\"gray\">",
		" Local sites Savannah knows about:",
		"</p>",
		"<p>"
	}
	for _, Line in ipairs(Rest) do Body[#Body + 1] = Line end
	local Keys = {}
	for Key in pairs(S.Data.Sites) do Keys[#Keys + 1] = Key end
	table.sort(Keys)
	if (#Keys == 0) then Body[#Body + 1] = " {gray}None yet. Open a .ccmd page from Finder.{/}" end
	for _, Key in ipairs(Keys) do
		Body[#Body + 1] = " " .. LinkSource(Key, "local://" .. Key .. "/") .. " {gray}" .. Ccmd.Escape(S.Data.Sites[Key]) .. "{/} " .. LinkSource("Forget", "savannah://settings?forget=" .. Key)
	end
	Body[#Body + 1] = "</p>"
	return Internal.Source("Settings", Body)
end

local function Redirect(Url)
	return { Status = 303, Headers = { Location = Url }, Body = nil }
end

function Internal.Handle(Method, Parsed, Body)
	local Name = Parsed.Host ~= "" and Parsed.Host or "start"
	local Params = Parsed.Params
	if (Name == "start") then
		return Response(200, Internal.Start())
	elseif (Name == "favourites" or Name == "bookmarks") then
		local Index = tonumber(Params.remove)
		if (Index and S.Data.Favourites[Index]) then
			table.remove(S.Data.Favourites, Index)
			SaveData()
			return Redirect("savannah://favourites")
		end
		return Response(200, Internal.Favourites())
	elseif (Name == "history") then
		if (Params.clear) then
			S.Data.History = {}
			SaveData()
			return Redirect("savannah://history")
		end
		return Response(200, Internal.History())
	elseif (Name == "settings") then
		if (Method == "POST" and type(Body) == "table") then
			local Host = type(Body.host) == "string" and Body.host:gsub("^%s+", ""):gsub("%s+$", "") or ""
			local Home = type(Body.home) == "string" and Body.home:gsub("^%s+", ""):gsub("%s+$", "") or ""
			S.Data.Host = Host ~= "" and Host or Protocol.DefaultHost
			S.Data.Home = Home ~= "" and Home or C.StartPage
			S.Transport = Protocol.NetworkTransport(S.Data.Host)
			SaveData()
			return Redirect("savannah://settings?saved=yes")
		end
		if (Params.forget and S.Data.Sites[Params.forget]) then
			S.Data.Sites[Params.forget] = nil
			S.Sites[Params.forget] = nil
			SaveData()
			return Redirect("savannah://settings")
		end
		return Response(200, Internal.Settings(Params.saved and "Settings saved."))
	elseif (Name == "source") then
		local Target = Params.url and Protocol.ParseUrl(Params.url)
		if (not Target or Target.Scheme == "savannah") then
			return Response(400, Site.Message("No source", "There is no page source to show."))
		end
		local Result, Problem = Nav.Request(Target, "GET", nil, {})
		if (not Result) then return Response(502, Nav.ConnectError(Params.url, Problem)) end
		return { Status = 200, Headers = { ["Content-Type"] = "text/plain", Title = "Source of " .. ShortUrl(Params.url) }, Body = tostring(Result.Body or "") }
	end
	return Response(404, Site.Message("Not found", "savannah://" .. Name .. " is not a Savannah page.", "red", { { "Start Page", C.StartPage } }))
end

--
-- Drawing
--

function View.DisplayUrl(Tab)
	local Url = (Tab.Loading and Tab.Loading.Url) or Tab.Url or ""
	if (Url == C.StartPage or Url == C.StartPage .. "/") then return "" end
	local Source = Url:match("^savannah://source%?(.*)$")
	if (Source) then return "Source: " .. ShortUrl(Protocol.DecodeQuery(Source).url or "") end
	return ShortUrl(Url)
end

function View.Progress(Tab)
	local Loading = Tab.Loading
	if (not Loading) then return nil end
	if (Loading.Total and Loading.Total > 0) then return 0.2 + 0.8 * Loading.Received / Loading.Total end
	local Time = os.clock() - Loading.Started
	return 0.1 + 0.7 * (1 - math.exp(-Time / 2))
end

function View.DrawAddress(Self, T, Th, P)
	if (P.Focus == Self) then
		Ui.Input.Draw(Self, T, Th, P)
		return
	end
	local Tab = Nav.Tab()
	local Text = View.DisplayUrl(Tab)
	local Fg = Th.InputFg
	if (Text == "") then
		Text, Fg = "Enter an address", Th.SubText
	elseif (#Text > Self.W - 2) then
		Text = "\171" .. Text:sub(-(Self.W - 3))
	end
	local Line = Gfx.Pad(Text, Self.W, "center")
	local Progress = View.Progress(Tab)
	local Filled = Progress and math.floor(Self.W * Progress + .5) or 0
	Gfx.Write(T, Self.X, Self.Y, Line, Fg, Th.InputBg)
	if (Filled > 0) then
		Gfx.Write(T, Self.X, Self.Y, Line:sub(1, Filled), Th.AccentFg, Th.Accent)
	end
end

function View.DrawTabs(Self, T, Th)
	local Count = #S.Tabs
	local X = Self.X
	for Index, Tab in ipairs(S.Tabs) do
		local Width = math.floor(Self.W * Index / Count) - math.floor(Self.W * (Index - 1) / Count)
		local Active = Index == S.Current
		local Bg = Active and Th.WindowBg or Th.Panel
		local Fg = Active and Th.Text or Th.SubText
		local Label = Tab.Loading and "Loading..." or Tab.Title or "New Tab"
		Gfx.Write(T, X, Self.Y, Gfx.Pad(" " .. Label, Width - 2), Fg, Bg)
		Gfx.Write(T, X + Width - 2, Self.Y, "\215 ", Active and Th.Text or Th.SubText, Bg)
		if (Index > 1) then Gfx.Write(T, X, Self.Y, "\149", Th.Border, Bg) end
		X = X + Width
	end
end

function View.TabsEvent(Self, Name, A, X)
	if (Name ~= "mouse_click") then return Name == "mouse_scroll" end
	local Count = #S.Tabs
	local Offset = X - Self.X
	for Index = 1, Count do
		local Right = math.floor(Self.W * Index / Count)
		if (Offset < Right) then
			if (A == 3 or Offset >= Right - 2) then
				Nav.CloseTab(Index)
			else
				Nav.SelectTab(Index)
			end
			return true
		end
	end
	return true
end

local function Blit(T, X, Y, Text, Fg, Bg)
	T.setCursorPos(X, Y)
	T.blit(Text, Fg, Bg)
end

-- Repaints part of a content row with new colours (selection and find highlights).
local function Mark(T, Self, P, Scroll, Y, X1, X2, Fg, Bg)
	local Row = P.Rows[Y]
	local ScreenY = Y - Scroll
	if (not Row or ScreenY < 1 or ScreenY > P.ViewH) then return end
	X1, X2 = math.max(1, X1), math.min(P.ViewW, X2)
	if (X2 < X1) then return end
	local Text = Row[1]:sub(X1, X2)
	Blit(T, Self.X + P.ViewX + X1 - 2, Self.Y + P.ViewY + ScreenY - 2, Text, string.rep(Fg, #Text), string.rep(Bg, #Text))
end

function View.DrawPage(Self, T, Th)
	local Tab = Nav.Tab()
	if (Tab.Doc and Tab.Built ~= S.ViewW .. "x" .. S.ViewH) then Nav.Rebuild(Tab) end
	local P = Tab.Page
	local Region
	if (not P) then
		Gfx.Fill(T, Self.X, Self.Y, Self.W, Self.H, Th.WindowBg)
	else
		local Blank = { string.rep(" ", P.ViewW), string.rep("0", P.ViewW), string.rep(P.Background, P.ViewW) }
		for Y = 1, P.ViewH do
			local Row = P.Rows[Tab.Scroll + Y] or Blank
			Blit(T, Self.X + P.ViewX - 1, Self.Y + P.ViewY + Y - 2, Row[1], Row[2], Row[3])
		end
		if (S.Find) then
			for Index, Match in ipairs(S.Find.Matches) do
				local Current = Index == S.Find.Index
				Mark(T, Self, P, Tab.Scroll, Match.Y, Match.X1, Match.X2, "f", Current and "1" or "4")
			end
		end
		Region = Tab.Selected and P.Regions[Tab.Selected]
		if (Region) then Mark(T, Self, P, Tab.Scroll, Region.Y, Region.X1, Region.X2, "f", "4") end
		if (P.Bar) then
			for Index, Row in ipairs(P.Bar.Rows) do
				Blit(T, Self.X, Self.Y + Index - 1, Row[1], Row[2], Row[3])
			end
		end
		if (P.MaxScroll > 0) then
			local Track = P.ViewH
			local Thumb = math.max(1, math.floor(Track * Track / #P.Rows))
			local ThumbY = math.floor((Track - Thumb) * Tab.Scroll / P.MaxScroll + .5)
			Gfx.Fill(T, Self.X + Self.W - 1, Self.Y + P.ViewY - 1 + ThumbY, 1, Thumb, Th.SubText)
		end
	end
	-- Status pill in the bottom-left corner, like a link preview.
	local Status
	if (Tab.Loading) then
		Status = "Loading " .. View.DisplayUrl(Tab) .. (Tab.Loading.Total > 1 and (" " .. Tab.Loading.Received .. "/" .. Tab.Loading.Total) or "")
	elseif (S.Message and os.clock() - S.MessageAt < C.MessageTime) then
		Status = S.Message
	elseif (Region and (Region.Href or (Region.Button and Region.Button.Href))) then
		local Parsed = Protocol.ParseUrl(Region.Href or Region.Button.Href, Tab.Parsed)
		Status = Parsed and ShortUrl(Protocol.FormatUrl(Parsed))
	elseif (Tab.Problems and Tab.Problems > 0 and Tab.Url and Tab.Url:match("^local://")) then
		Status = Tab.Problems .. (Tab.Problems == 1 and " problem" or " problems") .. " on this page"
	end
	if (Status) then
		Status = " " .. Gfx.Truncate(Status, Self.W - 4) .. " "
		Gfx.Write(T, Self.X, Self.Y + Self.H - 1, Status, Th.PanelFg or Th.Text, Th.Panel)
	end
end

function View.PageCursor(Self)
	local Tab = Nav.Tab()
	local P = Tab.Page
	if (not Tab.Focus or not P) then return nil end
	local Region = Layout.InputRegion(P, Tab.Focus)
	if (not Region) then return nil end
	local X, Y = Layout.RegionPosition(P, Region, Tab.Scroll)
	if (not X) then return nil end
	local Value = Tab.State[Region.Input.Id]
	if (Value == nil) then Value = Region.Input.Value end
	local Shown, Placeholder = Layout.InputText(Region.Input, Value)
	local Offset = Placeholder and 0 or math.min(#Shown, Region.X2 - Region.X1 + 1)
	local Column = math.min(X + Offset, P.ViewX + P.ViewW - 1)
	local Colour = 2 ^ (tonumber(Region.Input.TextColor, 16) or 15)
	return Self.X + Column - 1, Self.Y + Y - 1, Colour
end

function View.Scroll(Tab, By)
	if (not Tab.Page) then return end
	Tab.Scroll = math.max(0, math.min(Tab.Page.MaxScroll, Tab.Scroll + By))
end

function View.SelectRegion(Tab, Step)
	local Regions = Tab.Page and Tab.Page.Regions
	if (not Regions or #Regions == 0) then return end
	local Index = (Tab.Selected or (Step > 0 and 0 or #Regions + 1)) + Step
	if (Index < 1) then Index = #Regions end
	if (Index > #Regions) then Index = 1 end
	Tab.Selected = Index
	Tab.Scroll = Layout.ScrollTo(Tab.Page, Regions[Index].Y, Tab.Scroll)
end

function View.LinkMenu(Tab, Region, X, Y)
	local Href = Region.Href or (Region.Button and Region.Button.Href)
	local Parsed = Href and Protocol.ParseUrl(Href, Tab.Parsed)
	if (not Parsed) then return end
	local Url = Protocol.FormatUrl(Parsed)
	local Options = { "Open Link", "Open Link in New Tab", "-", "Add Link to Favourites", "Copy Link" }
	local Choice = Options[Ui.ContextMenu(X, Y, Options) or 0]
	if (Choice == "Open Link") then
		Nav.Go(Tab, Url, { Absolute = true })
	elseif (Choice == "Open Link in New Tab") then
		Nav.OpenTab(Url, true)
		Say("Opened in a new tab")
	elseif (Choice == "Add Link to Favourites") then
		if (not Nav.FavouriteIndex(Url)) then
			table.insert(S.Data.Favourites, { Title = Region.Kind == "button" and Region.Button.Text or Url, Url = Url })
			SaveData()
		end
		Say("Added to Favourites")
	elseif (Choice == "Copy Link") then
		BlockOS.TextClipboard = Url
		Say("Link copied")
	end
end

function View.PageMenu(Tab, X, Y)
	local Options = {
		{ Text = "Back", Disabled = Tab.Index <= 1 },
		{ Text = "Forward", Disabled = Tab.Index >= #Tab.History },
		{ Text = Tab.Loading and "Stop" or "Reload" },
		"-",
		{ Text = "View Source", Disabled = not Tab.Url or Tab.Url:match("^savannah://") ~= nil },
		{ Text = "Save Page As...", Disabled = not (Tab.Response and Tab.Response.Body) },
		{ Text = "Find on Page..." }
	}
	local Index = Ui.ContextMenu(X, Y, Options)
	local Choice = Index and Options[Index].Text
	if (Choice == "Back") then
		Nav.GoHistory(Tab, Tab.Index - 1)
	elseif (Choice == "Forward") then
		Nav.GoHistory(Tab, Tab.Index + 1)
	elseif (Choice == "Reload" or Choice == "Stop") then
		Nav.Reload(Tab)
	elseif (Choice == "View Source") then
		View.ViewSource(Tab)
	elseif (Choice == "Save Page As...") then
		Nav.SavePage(Tab)
	elseif (Choice == "Find on Page...") then
		Nav.OpenFind()
	end
end

function View.ViewSource(Tab)
	if (not Tab.Url or Tab.Url:match("^savannah://")) then return end
	Nav.OpenTab("savannah://source?" .. Protocol.EncodeQuery({ url = Tab.Url }))
end

function View.PageEvent(Self, Name, A, B, C)
	local Tab = Nav.Tab()
	if (Name == "mouse_click") then
		local P = Tab.Page
		local Region = P and Layout.Hit(P, B - Self.X + 1, C - Self.Y + 1, Tab.Scroll)
		if (A == 2) then
			if (Region and (Region.Kind == "link" or (Region.Kind == "button" and Region.Button.Href))) then
				View.LinkMenu(Tab, Region, B, C)
			else
				View.PageMenu(Tab, B, C)
			end
		elseif (Region) then
			if (Tab.Focus and (Region.Kind ~= "input" or Region.Input.Id ~= Tab.Focus)) then Nav.FocusInput(Tab, nil) end
			Tab.Selected = nil
			Nav.Activate(Tab, Region, A == 3, B, C)
		else
			Tab.Selected = nil
			if (Tab.Focus) then Nav.FocusInput(Tab, nil) end
		end
		return true
	elseif (Name == "mouse_scroll") then
		View.Scroll(Tab, A * 3)
		return true
	elseif (not Tab.Doc) then
		return false
	end
	if (Tab.Focus and (Name == "char" or Name == "paste" or Name == "key")) then
		if (Nav.EditField(Tab, Name, A)) then return true end
	end
	if (Name == "char" and A == " " and not Ui.Modifiers.Ctrl) then
		View.Scroll(Tab, S.ViewH - 1)
		return true
	elseif (Name ~= "key" or Ui.Modifiers.Ctrl) then
		return false
	end
	local Height = Tab.Page and Tab.Page.ViewH or S.ViewH
	if (A == keys.up) then View.Scroll(Tab, -1)
	elseif (A == keys.down) then View.Scroll(Tab, 1)
	elseif (A == keys.pageUp) then View.Scroll(Tab, 1 - Height)
	elseif (A == keys.pageDown) then View.Scroll(Tab, Height - 1)
	elseif (A == keys.home) then View.Scroll(Tab, -math.huge)
	elseif (A == keys["end"]) then View.Scroll(Tab, math.huge)
	elseif (A == keys.tab) then View.SelectRegion(Tab, Ui.Modifiers.Shift and -1 or 1)
	elseif ((A == keys.enter or A == keys.numPadEnter) and Tab.Selected and Tab.Page and Tab.Page.Regions[Tab.Selected]) then
		local Region = Tab.Page.Regions[Tab.Selected]
		local X, Y = Layout.RegionPosition(Tab.Page, Region, Tab.Scroll)
		Tab.Selected = nil
		Nav.Activate(Tab, Region, false, X and (Self.X + X - 1), Y and (Self.Y + Y - 1))
	elseif (A == keys.backspace) then Nav.GoHistory(Tab, Tab.Index - 1)
	else
		return false
	end
	return true
end

--
-- Menus and shortcuts
--

function View.Menu()
	local Tab = Nav.Tab()
	local IsFavourite = Tab.Url and Nav.FavouriteIndex(Tab.Url)
	local IsInternal = not Tab.Url or Tab.Url:match("^savannah://") ~= nil
	local Options = {
		{ Text = "New Tab", Key = "tab" },
		{ Text = "Open File...", Key = "open" },
		{ Text = "Save Page As...", Key = "save", Disabled = not (Tab.Response and Tab.Response.Body) },
		"-",
		{ Text = IsFavourite and "Remove from Favourites" or "Add to Favourites", Key = "fav", Disabled = IsInternal },
		{ Text = "Favourites", Key = "favourites" },
		{ Text = "History", Key = "history" },
		"-",
		{ Text = "Find on Page...", Key = "find" },
		{ Text = "View Source", Key = "source", Disabled = IsInternal },
		"-",
		{ Text = "Home", Key = "home" },
		{ Text = "Set as Home Page", Key = "sethome", Disabled = not Tab.Url },
		{ Text = "Settings", Key = "settings" },
		{ Text = "Close Tab", Key = "close" }
	}
	if (Tab.Url and Tab.Url:match("^local://") and Tab.Parsed) then
		table.insert(Options, 4, { Text = "Edit Page", Key = "edit" })
	end
	local W = Page.W
	local Index = Ui.ContextMenu(W - 22, 2, Options)
	local Key = Index and Options[Index].Key
	if (Key == "tab") then
		Nav.OpenTab()
	elseif (Key == "open") then
		local Path = Ui.PickFile({ Title = "Open File", Dir = "/home" })
		if (Path) then Nav.OpenLocal(Tab, Path) end
	elseif (Key == "save") then
		Nav.SavePage(Tab)
	elseif (Key == "edit") then
		View.EditPage(Tab)
	elseif (Key == "fav") then
		Nav.ToggleFavourite(Tab)
	elseif (Key == "favourites") then
		Nav.Go(Tab, "savannah://favourites", { Absolute = true })
	elseif (Key == "history") then
		Nav.Go(Tab, "savannah://history", { Absolute = true })
	elseif (Key == "find") then
		Nav.OpenFind()
	elseif (Key == "source") then
		View.ViewSource(Tab)
	elseif (Key == "home") then
		Nav.Go(Tab, S.Data.Home, { Absolute = true })
	elseif (Key == "sethome") then
		S.Data.Home = Tab.Url
		SaveData()
		Say("Home page set")
	elseif (Key == "settings") then
		Nav.Go(Tab, "savannah://settings", { Absolute = true })
	elseif (Key == "close") then
		Nav.CloseTab()
	end
end

-- Opens the file behind a local page in CCDream (or Editor when CCDream is not installed).
function View.EditPage(Tab)
	local Server = Nav.LocalSite(Tab.Parsed.Host)
	local File = Server and Server:Resolve(Tab.Parsed.Path)
	local Real = File and Server:RealPath(File)
	if (not Real) then
		Say("No file for this page")
		return
	end
	local Apps = BlockOS.Require("apps")
	BlockOS.Launch(Apps.Get("ccdream") and "ccdream" or "editor", { Real })
end

local Shortcuts = {
	[keys.l] = function() Page:SetFocus(S.W.Address) end,
	[keys.t] = function() Nav.OpenTab() end,
	[keys.n] = function() Nav.OpenTab() end,
	[keys.w] = function() Nav.CloseTab() end,
	[keys.r] = function() Nav.Reload(Nav.Tab()) end,
	[keys.f] = function() Nav.OpenFind() end,
	[keys.d] = function() Nav.ToggleFavourite(Nav.Tab()) end,
	[keys.s] = function() Nav.SavePage(Nav.Tab()) end,
	[keys.o] = function()
		local Path = Ui.PickFile({ Title = "Open File", Dir = "/home" })
		if (Path) then Nav.OpenLocal(Nav.Tab(), Path) end
	end,
	[keys.u] = function() View.ViewSource(Nav.Tab()) end,
	[keys.h] = function() Nav.Go(Nav.Tab(), "savannah://history", { Absolute = true }) end,
	[keys.left] = function() Nav.GoHistory(Nav.Tab(), Nav.Tab().Index - 1) end,
	[keys.right] = function() Nav.GoHistory(Nav.Tab(), Nav.Tab().Index + 1) end,
	[keys.tab] = function() Nav.SelectTab(S.Current % #S.Tabs + 1) end,
	[keys.q] = function()
		BlockOS.Quit()
		Page:Stop()
	end
}
for Number = 1, 9 do
	Shortcuts[keys[({ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" })[Number]]] = function()
		Nav.SelectTab(Number == 9 and #S.Tabs or Number)
	end
end

--
-- Window layout
--

local function ToolButton(X, Text, OnClick, Enabled)
	return Ui.Button.new({ X = X, Y = 1, W = 3, Text = Text, Bg = "Panel", Fg = "PanelFg", OnClick = OnClick, Enabled = Enabled })
end

function Page:OnLayout(W, H)
	self:Clear()
	local Tab = Nav.Tab()
	local Top = #S.Tabs > 1 and 3 or 2
	local Bottom = S.Find and 1 or 0
	S.ViewW, S.ViewH = W, math.max(1, H - Top + 1 - Bottom)
	self:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
	S.W.Back = self:Add(ToolButton(1, "\17", function() Nav.GoHistory(Nav.Tab(), Nav.Tab().Index - 1) end))
	S.W.Forward = self:Add(ToolButton(4, "\16", function() Nav.GoHistory(Nav.Tab(), Nav.Tab().Index + 1) end))
	S.W.Address = self:Add(Ui.Input.new({ X = 8, Y = 1, W = math.max(6, W - 20), Placeholder = "Enter an address" }))
	S.W.Address.Draw = View.DrawAddress
	S.W.Address.OnFocus = function(Self)
		Self:SetValue(Nav.Tab().Url or "")
		if (Self.Value == C.StartPage or Self.Value == C.StartPage .. "/") then Self:SetValue("") end
		Self:SelectAll()
		Self.JustFocused = true
	end
	S.W.Address.Event = function(Self, P, Name, ...)
		if (Name == "mouse_click" and Self.JustFocused) then
			Self.JustFocused = false
			return true
		end
		Self.JustFocused = false
		return Ui.Input.Event(Self, P, Name, ...)
	end
	S.W.Address.OnSubmit = function(Self)
		local Value = Self.Value
		self:SetFocus(S.W.View)
		Nav.Go(Nav.Tab(), Value, { Absolute = true })
	end
	S.W.Reload = self:Add(ToolButton(W - 11, "@", function() Nav.Reload(Nav.Tab()) end))
	S.W.Star = self:Add(ToolButton(W - 8, "*", function() Nav.ToggleFavourite(Nav.Tab()) end))
	self:Add(ToolButton(W - 5, "+", function() Nav.OpenTab() end))
	self:Add(ToolButton(W - 2, "=", function() View.Menu() end))
	if (Top == 3) then
		self:Add(Ui.Canvas.new({ X = 1, Y = 2, W = W, H = 1, OnDraw = View.DrawTabs, OnEvent = View.TabsEvent }))
	end
	S.W.View = self:Add(Ui.Canvas.new({
		X = 1, Y = Top, W = W, H = S.ViewH, Focusable = true, KeepFocus = true,
		OnDraw = View.DrawPage, OnEvent = View.PageEvent, OnCursor = View.PageCursor
	}))
	if (S.Find) then
		local Y = H
		self:Add(Ui.Panel.new({ X = 1, Y = Y, W = W, H = 1, Bg = "Panel" }))
		self:Add(Ui.Label.new({ X = 2, Y = Y, Text = "Find", Bg = "Panel", Fg = "PanelFg" }))
		S.W.FindField = self:Add(Ui.Input.new({ X = 7, Y = Y, W = math.max(4, W - 28), Value = S.Find.Query, Placeholder = "Search this page" }))
		S.W.FindField.OnChange = function(Self)
			S.Find.Query = Self.Value
			Nav.FindMatches(true)
		end
		S.W.FindField.OnSubmit = function() Nav.FindStep(Ui.Modifiers.Shift and -1 or 1) end
		self:Add(Ui.Label.new({
			X = W - 20, Y = Y, W = 9, Bg = "Panel", Fg = "SubText", Align = "right",
			Text = function()
				if (S.Find.Query == "") then return "" end
				if (#S.Find.Matches == 0) then return "No match" end
				return S.Find.Index .. " of " .. #S.Find.Matches
			end
		}))
		self:Add(ToolButton(W - 10, "\30", function() Nav.FindStep(-1) end)).Y = Y
		self:Add(ToolButton(W - 7, "\31", function() Nav.FindStep(1) end)).Y = Y
		self:Add(Ui.Button.new({ X = W - 4, Y = Y, W = 4, Text = "\215", Bg = "Panel", Fg = "PanelFg", OnClick = function() Nav.CloseFind() end }))
	end
	if (Tab and Tab.Doc) then Nav.Rebuild(Tab) end
	self:SetFocus(S.W.View)
end

function View.Relayout()
	local Focus = Page.Focus
	local WasFind = Focus and Focus == S.W.FindField
	Page:OnLayout(Page.W, Page.H)
	if (WasFind and S.Find) then Page:SetFocus(S.W.FindField) end
end

local BaseDraw = Page.Draw
function Page:Draw()
	local Tab = Nav.Tab()
	if (Tab and S.W.Back) then
		S.W.Back.Enabled = Tab.Index > 1
		S.W.Forward.Enabled = Tab.Index < #Tab.History
		S.W.Reload.Text = Tab.Loading and "\215" or "@"
		local Favourite = Tab.Url and Nav.FavouriteIndex(Tab.Url)
		S.W.Star.Fg = Favourite and "Accent" or "PanelFg"
	end
	BaseDraw(self)
end

-- Background events also reach here while a dialog is open, so requests keep running.
local BaseBackground = Page.Background
function Page:Background(Name, ...)
	if (Tasks.Dispatch(Name, ...)) then self.Dirty = true end
	BaseBackground(self, Name, ...)
end

local BaseHandle = Page.Handle
function Page:Handle(Name, A, ...)
	if (Name == "key" and Ui.Modifiers.Ctrl and not Ui.Modifiers.Shift and Shortcuts[A]) then
		local Address = self.Focus == S.W.Address or self.Focus == S.W.FindField
		if (not (Address and (A == keys.left or A == keys.right))) then
			Shortcuts[A]()
			self.Dirty = true
			return
		end
	end
	if (Name == "char" and Ui.Modifiers.Ctrl) then return end
	BaseHandle(self, Name, A, ...)
end

function Page:OnEvent(Name, A)
	if (Name == "blockos_open" and A) then
		Nav.OpenTab(A)
		return true
	elseif (Name == "blockos_settings" and Theme.Get().Dark ~= S.Dark) then
		S.Dark = Theme.Get().Dark
		for _, Tab in ipairs(S.Tabs) do
			if (Tab.Url and Tab.Url:match("^savannah://") and not Tab.Loading) then Nav.Reload(Tab) end
		end
		return true
	end
	return false
end

-- Redraws while something animates (the loading bar) or a message is showing.
Page:SetInterval(0.25, function()
	for _, Tab in ipairs(S.Tabs) do
		if (Tab.Loading) then return true end
	end
	if (S.Message and os.clock() - S.MessageAt < C.MessageTime + 0.3) then return true end
	return false
end)

LoadData()
S.Dark = Theme.Get().Dark
S.Transport = Protocol.NetworkTransport(S.Data.Host)
math.randomseed(os.epoch("utc") + os.getComputerID())
S.Tabs[1] = Nav.NewTabState()
View.Relayout()
Nav.Go(S.Tabs[1], Args[1] or S.Data.Home, { Absolute = true })
Page:Run()
