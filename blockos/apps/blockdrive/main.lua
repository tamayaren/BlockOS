-- BlockDrive: browse and manage files on BlockCloud servers in the Data Center.
-- Network operations run as background tasks so the window stays responsive.
-- Args: <NodeID> opens a server, "add" starts pairing, "upload" <path> uploads a local file.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Client = BlockOS.Require("cloud/client")
local Drive = BlockOS.Require("cloud/drive")
local Path = BlockOS.Require("cloud/path")
local Protocol = BlockOS.Require("cloud/protocol")
local Tasks = BlockOS.Load("/blockos/lib/cloud/tasks.lua")

local Args = { ... }
local Page = Ui.Page.new()
local Build

-- Everything the window shows lives here (CC limits how many locals a file may have).
local S = {
	Mode = "browse",
	Server = nil,
	Remote = "",
	Entries = nil,
	Info = nil,
	Back = {},
	Forward = {},
	Status = nil,
	Error = nil,
	Progress = nil,
	Busy = 0,
	Found = nil,
	Pairing = nil,
	Editor = nil,
	Pending = nil,
	Clipboard = nil
}

local Act = {}
local View = {}

Act.ManifestUrl = "https://raw.githubusercontent.com/tamayaren/BlockOS/server/blockdrive-manifest.cfg"
Act.EditLimit = 64 * 1024

local function Say(Text)
	S.Status, S.Error = Text, nil
	Page:Invalidate()
end

local function Fail(Err)
	S.Error = Protocol.Describe(Err)
	S.Progress = nil
	Page:Invalidate()
end

-- Runs Fn in the background; OnDone(Result, Err) runs back in the app when it finishes.
-- A nil Label runs quietly, leaving the status bar alone.
local function Run(Label, Fn, OnDone)
	S.Busy = S.Busy + 1
	if (Label) then S.Status, S.Error = Label, nil end
	Tasks.Spawn(Label, Fn, function(Ok, Result, Err)
		S.Busy = S.Busy - 1
		S.Progress = nil
		if (not Ok) then
			Fail({ Code = "internal", Message = tostring(Result) })
		elseif (OnDone) then
			OnDone(Result, Err)
		end
		Build()
	end)
	Build()
end

local function Progress(Verb, Name)
	return function(Done, Total)
		S.Progress = Total > 0 and Done / Total or 1
		S.Status = Verb .. " " .. Name .. " " .. math.floor(S.Progress * 100) .. "%"
		Page:Invalidate()
	end
end

local function Breadcrumb()
	if (not S.Server) then return "BlockDrive" end
	local Text = "BlockDrive \26 " .. Client.Title(S.Server)
	for _, Part in ipairs(Path.Split(S.Remote)) do
		Text = Text .. " \26 " .. Part
	end
	return Text
end

local function Writable()
	return S.Server and S.Server.Permission == "write"
end

--
-- Browsing
--

-- Quiet reloads (after an upload or a change) keep the message about what just happened.
function Act.Load(Quiet)
	local Server, Remote = S.Server, S.Remote
	if (not Server) then return end
	Run(not Quiet and "Loading..." or nil, function()
		local Listing, Err = Drive.List(Server, Remote)
		if (Listing and not S.Info) then S.Info = Drive.Info(Server) end
		return Listing, Err
	end, function(Listing, Err)
		if (S.Server ~= Server or S.Remote ~= Remote) then return end
		if (not Listing) then
			S.Entries = nil
			Fail(Err)
			if (Err and Err.Code == "not_found" and Remote ~= "") then
				S.Remote = Path.Parent(Remote)
				Act.Load()
			end
			return
		end
		S.Entries = Listing.Entries
		if (Quiet and not S.Error) then return end
		S.Status = #Listing.Entries .. " items  \7  " .. Gfx.FormatSize(Listing.Free or 0) .. " free" .. (Listing.ReadOnly and "  \7  read only" or "")
	end)
end

function Act.Open(Server, Remote, SkipHistory)
	if (S.Server and not SkipHistory and (S.Server ~= Server or S.Remote ~= Remote)) then
		table.insert(S.Back, { S.Server, S.Remote })
		S.Forward = {}
	end
	if (S.Server ~= Server) then S.Info = nil end
	S.Server, S.Remote, S.Mode = Server, Remote or "", "browse"
	S.Entries = nil
	BlockOS.SetTitle("BlockDrive \7 " .. Client.Title(Server))
	Act.Load(S.Status ~= nil and S.Status:find("^Paired") ~= nil)
end

function Act.History(From, To)
	local Entry = table.remove(From)
	if (not Entry) then return end
	table.insert(To, { S.Server, S.Remote })
	Act.Open(Entry[1], Entry[2], true)
end

function Act.Up()
	if (S.Server and S.Remote ~= "") then Act.Open(S.Server, Path.Parent(S.Remote)) end
end

function Act.Activate(Entry)
	local Remote = Path.Join(S.Remote, Entry.Name)
	if (Entry.Dir) then
		Act.Open(S.Server, Remote)
	elseif (Drive.IsText(Entry.Name) and Entry.Size <= Act.EditLimit) then
		Act.Edit(Remote)
	else
		Act.Download(Entry)
	end
end

--
-- File operations
--

function Act.Download(Entry)
	local Remote = Path.Join(S.Remote, Entry.Name)
	local Target = Ui.PickFile({ Title = "Download To", Save = true, Dir = fs.exists("/home/Downloads") and "/home/Downloads" or "/", Name = Entry.Name })
	if (not Target) then return end
	if (fs.exists(Target) and not Ui.Confirm("Download", fs.getName(Target) .. " already exists on this computer. Replace it?", "Replace")) then return end
	local Server = S.Server
	Run("Downloading " .. Entry.Name .. "...", function()
		return Drive.Download(Server, Remote, Target, { OnProgress = Progress("Downloading", Entry.Name) })
	end, function(Size, Err)
		if (not Size) then return Fail(Err) end
		Say("Downloaded " .. Entry.Name .. " to " .. Target)
		if (BlockOS.Notify) then BlockOS.Notify("BlockDrive", "Downloaded " .. Entry.Name, { Sound = false }) end
	end)
end

function Act.Upload(LocalPath)
	if (not Writable()) then return Fail({ Code = "denied" }) end
	LocalPath = LocalPath or Ui.PickFile({ Title = "Upload", Dir = fs.exists("/home") and "/home" or "/" })
	if (not LocalPath or not fs.exists(LocalPath) or fs.isDir(LocalPath)) then return end
	local Name = fs.getName(LocalPath)
	if (not Path.ValidName(Name)) then return Fail({ Code = "invalid_name" }) end
	local Remote = Path.Join(S.Remote, Name)
	local Overwrite = false
	for _, Entry in ipairs(S.Entries or {}) do
		if (Entry.Name == Name) then
			if (Entry.Dir or not Ui.Confirm("Upload", Name .. " already exists here. Replace it?", "Replace")) then return end
			Overwrite = true
		end
	end
	local Server, Folder = S.Server, S.Remote
	Run("Uploading " .. Name .. "...", function()
		return Drive.Upload(Server, LocalPath, Remote, { Overwrite = Overwrite, OnProgress = Progress("Uploading", Name) })
	end, function(Entry, Err)
		if (not Entry) then return Fail(Err) end
		Say("Uploaded " .. Name)
		if (S.Server == Server and S.Remote == Folder) then Act.Load(true) end
	end)
end

-- Runs a quick operation and reloads the folder afterwards.
local function Change(Label, Fn)
	if (not Writable()) then return Fail({ Code = "denied" }) end
	local Server = S.Server
	Run(Label, function() return Fn(Server) end, function(Result, Err)
		if (Result == nil) then return Fail(Err) end
		Say("Done")
		Act.Load(true)
	end)
end

function Act.NewFolder()
	local Name = Ui.Prompt("New Folder", "Name:", "untitled folder")
	if (not Name or Name == "") then return end
	if (not Path.ValidName(Name)) then return Fail({ Code = "invalid_name" }) end
	Change("Creating " .. Name .. "...", function(Server) return Drive.MakeDir(Server, Path.Join(S.Remote, Name)) end)
end

function Act.NewText()
	local Name = Ui.Prompt("New Text File", "Name:", "untitled.txt")
	if (not Name or Name == "") then return end
	if (not Path.ValidName(Name)) then return Fail({ Code = "invalid_name" }) end
	local Remote = Path.Join(S.Remote, Name)
	Change("Creating " .. Name .. "...", function(Server)
		return Drive.WriteText(Server, Remote, "", { Overwrite = false })
	end)
end

function Act.Rename(Entry)
	local Name = Ui.Prompt("Rename", "New name:", Entry.Name)
	if (not Name or Name == "" or Name == Entry.Name) then return end
	Change("Renaming...", function(Server) return Drive.Rename(Server, Path.Join(S.Remote, Entry.Name), Name) end)
end

function Act.Duplicate(Entry)
	local Base, Extension = Entry.Name:match("^(.-)(%.[^%.]*)$")
	if (not Base or Base == "" or Entry.Dir) then Base, Extension = Entry.Name, "" end
	local Taken = {}
	for _, Other in ipairs(S.Entries or {}) do Taken[Other.Name] = true end
	local Index, Name = 1, Base .. " copy" .. Extension
	while (Taken[Name]) do
		Index = Index + 1
		Name = Base .. " copy " .. Index .. Extension
	end
	Change("Copying...", function(Server) return Drive.Copy(Server, Path.Join(S.Remote, Entry.Name), Path.Join(S.Remote, Name)) end)
end

-- Move or copy to another folder on the same server, typed as a path like Shared/docs.
function Act.Relocate(Entry, Copy)
	local Folder = Ui.Prompt(Copy and "Copy To" or "Move To", "Folder on " .. Client.Title(S.Server) .. ":", S.Remote)
	if (not Folder) then return end
	local Target = Path.Normalize(Folder)
	if (not Target) then return Fail({ Code = "invalid_path" }) end
	local From, To = Path.Join(S.Remote, Entry.Name), Path.Join(Target, Entry.Name)
	Change(Copy and "Copying..." or "Moving...", function(Server)
		return (Copy and Drive.Copy or Drive.Move)(Server, From, To)
	end)
end

function Act.Delete(Entry)
	if (not Ui.Confirm("Delete", "Delete \"" .. Entry.Name .. "\" from " .. Client.Title(S.Server) .. "? This cannot be undone.", "Delete")) then return end
	Change("Deleting...", function(Server) return Drive.Delete(Server, Path.Join(S.Remote, Entry.Name)) end)
end

function Act.GetInfo(Entry)
	local Lines = {
		"Kind: " .. (Entry.Dir and "Folder" or "File"),
		"Where: " .. Client.Title(S.Server) .. "/" .. S.Remote
	}
	if (not Entry.Dir) then table.insert(Lines, "Size: " .. Gfx.FormatSize(Entry.Size)) end
	if (Entry.Modified and Entry.Modified > 0) then
		table.insert(Lines, "Modified: " .. os.date("%Y-%m-%d %H:%M", math.floor(Entry.Modified / 1000)))
	end
	Ui.Alert(Entry.Name, table.concat(Lines, "\n"))
end

function Act.ServerInfo()
	local Server = S.Server
	if (not Server) then return end
	Run("Asking " .. Client.Title(Server) .. "...", function() return Drive.Info(Server) end, function(Info, Err)
		if (not Info) then return Fail(Err) end
		S.Info = Info
		Say("")
		Ui.Alert(Client.Title(Server), table.concat({
			"Hostname: " .. tostring(Server.Hostname) .. " (computer #" .. Server.ComputerID .. ")",
			"Access: " .. (Info.Permission == "write" and "read and write" or "read only"),
			"Free: " .. Gfx.FormatSize(Info.Free) .. (Info.Capacity and (" of " .. Gfx.FormatSize(Info.Capacity)) or ""),
			"Used: " .. Gfx.FormatSize(Info.Used or 0) .. ((Info.Quota or 0) > 0 and (" (quota " .. Gfx.FormatSize(Info.Quota) .. ")") or ""),
			"Encryption: " .. (Server.Encrypt and "on" or "off")
		}, "\n"))
	end)
end

function Act.Forget()
	local Server = S.Server
	if (not Server or not Ui.Confirm("Forget Server", "Unpair from " .. Client.Title(Server) .. "? You will need the administrator to pair again.", "Forget")) then return end
	Run("Unpairing...", function() Client.Forget(Server.NodeID, true) return true end, function()
		S.Server, S.Entries, S.Remote = nil, nil, ""
		os.queueEvent("blockcloud_paired")
		Say("Forgot " .. Client.Title(Server))
	end)
end

--
-- Text editor for remote files
--

function Act.Edit(Remote)
	local Server = S.Server
	Run("Opening " .. Path.Name(Remote) .. "...", function()
		return Drive.ReadText(Server, Remote, { OnProgress = Progress("Opening", Path.Name(Remote)) })
	end, function(Text, Err)
		if (not Text) then return Fail(Err) end
		local Lines = {}
		for Line in (Text .. "\n"):gmatch("(.-)\n") do table.insert(Lines, Line) end
		if (#Lines > 1 and Lines[#Lines] == "" and Text:sub(-1) == "\n") then table.remove(Lines) end
		S.Editor = {
			Server = Server, Remote = Remote, Lines = #Lines > 0 and Lines or { "" }, X = 1, Y = 1, Top = 0, Left = 0,
			Modified = false, ReadOnly = Server.Permission ~= "write", TrailingNewline = Text:sub(-1) == "\n"
		}
		S.Mode = "edit"
		Say(S.Editor.ReadOnly and "Read only" or "Ctrl+S saves to " .. Client.Title(Server))
	end)
end

function Act.Save(Then)
	local Editor = S.Editor
	if (not Editor or Editor.ReadOnly) then return end
	local Text = table.concat(Editor.Lines, "\n") .. (Editor.TrailingNewline and "\n" or "")
	Run("Saving " .. Path.Name(Editor.Remote) .. "...", function()
		return Drive.WriteText(Editor.Server, Editor.Remote, Text, { OnProgress = Progress("Saving", Path.Name(Editor.Remote)) })
	end, function(Entry, Err)
		if (not Entry) then return Fail(Err) end
		Editor.Modified = false
		BlockOS.SetCloseHandler(false)
		Say("Saved " .. Path.Name(Editor.Remote) .. " to " .. Client.Title(Editor.Server))
		if (Then) then Then() end
	end)
end

function Act.CloseEditor()
	local Editor = S.Editor
	if (Editor and Editor.Modified) then
		local Choice = Ui.Alert("Unsaved changes", "Save changes to " .. Path.Name(Editor.Remote) .. "?", { "Cancel", "Discard", "Save" })
		if (Choice == 3) then
			Act.Save(Act.CloseEditor)
			return
		elseif (Choice ~= 2) then
			return
		end
	end
	BlockOS.SetCloseHandler(false)
	S.Editor, S.Mode = nil, "browse"
	Act.Load()
end

function Act.EditKey(Editor, Name, A)
	local Lines = Editor.Lines
	local Line = Lines[Editor.Y]
	local function Edited()
		if (not Editor.Modified) then BlockOS.SetCloseHandler(true) end
		Editor.Modified = true
	end
	if (Name == "char" or Name == "paste") then
		if (Editor.ReadOnly) then return true end
		local Text = A:gsub("[\r\n]", "")
		Lines[Editor.Y] = Line:sub(1, Editor.X - 1) .. Text .. Line:sub(Editor.X)
		Editor.X = Editor.X + #Text
		Edited()
		return true
	end
	if (Name ~= "key") then return false end
	if (Ui.Modifiers.Ctrl and A == keys.s) then
		Act.Save()
	elseif (A == keys.left) then
		if (Editor.X > 1) then Editor.X = Editor.X - 1 elseif (Editor.Y > 1) then Editor.Y = Editor.Y - 1 Editor.X = #Lines[Editor.Y] + 1 end
	elseif (A == keys.right) then
		if (Editor.X <= #Line) then Editor.X = Editor.X + 1 elseif (Editor.Y < #Lines) then Editor.Y = Editor.Y + 1 Editor.X = 1 end
	elseif (A == keys.up and Editor.Y > 1) then
		Editor.Y = Editor.Y - 1
	elseif (A == keys.down and Editor.Y < #Lines) then
		Editor.Y = Editor.Y + 1
	elseif (A == keys.home) then
		Editor.X = 1
	elseif (A == keys["end"]) then
		Editor.X = #Line + 1
	elseif (A == keys.pageUp) then
		Editor.Y = math.max(1, Editor.Y - 10)
	elseif (A == keys.pageDown) then
		Editor.Y = math.min(#Lines, Editor.Y + 10)
	elseif (Editor.ReadOnly) then
		return false
	elseif (A == keys.enter or A == keys.numPadEnter) then
		local Indent = Line:match("^[ \t]*")
		Lines[Editor.Y] = Line:sub(1, Editor.X - 1)
		table.insert(Lines, Editor.Y + 1, Indent .. Line:sub(Editor.X))
		Editor.Y, Editor.X = Editor.Y + 1, #Indent + 1
		Edited()
	elseif (A == keys.backspace) then
		if (Editor.X > 1) then
			Lines[Editor.Y] = Line:sub(1, Editor.X - 2) .. Line:sub(Editor.X)
			Editor.X = Editor.X - 1
		elseif (Editor.Y > 1) then
			Editor.X = #Lines[Editor.Y - 1] + 1
			Lines[Editor.Y - 1] = Lines[Editor.Y - 1] .. Line
			table.remove(Lines, Editor.Y)
			Editor.Y = Editor.Y - 1
		end
		Edited()
	elseif (A == keys.delete) then
		if (Editor.X <= #Line) then
			Lines[Editor.Y] = Line:sub(1, Editor.X - 1) .. Line:sub(Editor.X + 1)
		elseif (Editor.Y < #Lines) then
			Lines[Editor.Y] = Line .. table.remove(Lines, Editor.Y + 1)
		end
		Edited()
	elseif (A == keys.tab) then
		Lines[Editor.Y] = Line:sub(1, Editor.X - 1) .. "\t" .. Line:sub(Editor.X)
		Editor.X = Editor.X + 1
		Edited()
	else
		return false
	end
	Editor.X = math.min(Editor.X, #Lines[Editor.Y] + 1)
	return true
end

function View.Editor(X, Y, W, H)
	local Editor = S.Editor
	Page:Add(Ui.Panel.new({ X = 1, Y = 1, W = Page.W, H = 1, Bg = "Panel" }))
	Page:Add(Ui.Button.new({ X = 1, Y = 1, Text = " \17 Files ", Bg = "Panel", OnClick = Act.CloseEditor }))
	Page:Add(Ui.Label.new({ X = 11, Y = 1, W = Page.W - 19, Bg = "Panel", Fg = "PanelFg",
		Text = function() return Path.Name(Editor.Remote) .. (Editor.Modified and " *" or "") .. (Editor.ReadOnly and " (read only)" or "") end }))
	Page:Add(Ui.Button.new({ X = Page.W - 6, Y = 1, W = 6, Text = "Save", Style = "primary", Enabled = not Editor.ReadOnly, OnClick = function() Act.Save() end }))
	local Canvas = Page:Add(Ui.Canvas.new({
		X = 1, Y = 2, W = Page.W, H = Page.H - 2, Focusable = true,
		OnDraw = function(Self, T, Th)
			if (Editor.Y <= Editor.Top) then Editor.Top = Editor.Y - 1 end
			if (Editor.Y > Editor.Top + Self.H) then Editor.Top = Editor.Y - Self.H end
			if (Editor.X <= Editor.Left) then Editor.Left = Editor.X - 1 end
			if (Editor.X > Editor.Left + Self.W) then Editor.Left = Editor.X - Self.W end
			for Row = 1, Self.H do
				local Line = Editor.Lines[Editor.Top + Row]
				local Text = Line and Line:gsub("\t", " "):sub(Editor.Left + 1, Editor.Left + Self.W) or ""
				Gfx.Write(T, Self.X, Self.Y + Row - 1, Gfx.Pad(Text, Self.W), Line and Th.Text or Th.SubText, Th.WindowBg)
			end
		end,
		OnCursor = function(Self, Th)
			return Self.X + Editor.X - Editor.Left - 1, Self.Y + Editor.Y - Editor.Top - 1, Th.Text
		end,
		OnEvent = function(Self, Name, A, B, C)
			if (Name == "mouse_click") then
				Editor.Y = math.max(1, math.min(#Editor.Lines, C - Self.Y + 1 + Editor.Top))
				Editor.X = math.max(1, math.min(#Editor.Lines[Editor.Y] + 1, B - Self.X + 1 + Editor.Left))
				return true
			elseif (Name == "mouse_scroll") then
				Editor.Top = math.max(0, math.min(#Editor.Lines - 1, Editor.Top + A))
				Editor.Y = math.max(Editor.Top + 1, math.min(Editor.Y, Editor.Top + Self.H))
				Editor.X = math.min(Editor.X, #Editor.Lines[Editor.Y] + 1)
				return true
			end
			return Act.EditKey(Editor, Name, A)
		end
	}))
	Page:SetFocus(Canvas)
end

--
-- Pairing
--

function Act.Discover()
	S.Mode, S.Found = "add", nil
	Run("Looking for servers...", function() return Client.Discover(2) end, function(Nodes, Err)
		if (not Nodes) then return Fail(Err) end
		S.Found = Nodes
		Say(#Nodes == 0 and "No servers answered. Check the Data Center is on and in modem range." or (#Nodes .. " found"))
	end)
end

function Act.Pair(Node)
	if (Node.Paired) then
		Act.Open(Client.Get(Node.NodeID), "")
		return
	end
	local Name = Ui.Prompt("Pair with " .. Node.Name, "Name for this computer:", os.getComputerLabel() or ("Computer " .. os.getComputerID()))
	if (not Name or Name == "") then return end
	S.Pairing = { Node = Node, Cancelled = false }
	local Pairing = S.Pairing
	Run("Asking " .. Node.Name .. "...", function()
		local Session, Err = Client.StartPairing(Node, Name)
		if (not Session) then return nil, Err end
		Pairing.Session = Session
		S.Mode = "pair"
		S.Status = "Waiting for the administrator..."
		Build()
		return Client.WaitPairing(Session, function() return Pairing.Cancelled end)
	end, function(Server, Err)
		S.Pairing = nil
		if (not Server) then
			S.Mode = "add"
			return Fail(Err)
		end
		os.queueEvent("blockcloud_paired")
		Say("Paired with " .. Client.Title(Server) .. " (" .. (Server.Permission == "write" and "read and write" or "read only") .. ")")
		Act.Open(Server, "")
	end)
end

function View.Add(X, Y, W, H)
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Fg = "Accent", Text = "Add a BlockCloud server" }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 1, W = W, H = 2, Fg = "SubText", Text = "Servers in modem range. Pick one to ask its administrator for access." }))
	local Items = {}
	for _, Node in ipairs(S.Found or {}) do
		table.insert(Items, { Text = Node.Name .. " (" .. Node.Hostname .. ")", Right = Node.Paired and "paired" or (Node.Pairing and "" or "closed"), Icon = "\15", IconFg = colors.cyan, Node = Node })
	end
	local List = Page:Add(Ui.List.new({ X = X, Y = Y + 4, W = W, H = math.max(1, H - 6), Items = Items, Bg = "Panel" }))
	List.OnActivate = function(_, _, Item) Act.Pair(Item.Node) end
	Page:Add(Ui.Button.new({ X = X, Y = Y + H - 1, Text = " Search Again ", OnClick = Act.Discover }))
	Page:Add(Ui.Button.new({ X = X + 15, Y = Y + H - 1, Text = " Pair ", Style = "primary", OnClick = function()
		local Item = List.Items[List.Selected]
		if (Item) then Act.Pair(Item.Node) end
	end }))
end

function View.Pair(X, Y, W, H)
	local Pairing = S.Pairing
	local Session = Pairing and Pairing.Session
	if (not Session) then return end
	local Auth = BlockOS.Require("cloud/auth")
	Page:Add(Ui.Label.new({ X = X, Y = Y, W = W, Fg = "Accent", Text = "Pairing with " .. Pairing.Node.Name }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 2, W = W, H = 3, Text = "On the server console, open Pairing, approve this computer and type this code:" }))
	Page:Add(Ui.Canvas.new({ X = X, Y = Y + 6, W = W, H = 1, OnDraw = function(Self, T, Th)
		local Code = " " .. Auth.FormatCode(Session.Code) .. " "
		Gfx.Write(T, Self.X + math.floor((Self.W - #Code) / 2), Self.Y, Code, Th.AccentFg, Th.Accent)
	end }))
	Page:Add(Ui.Label.new({ X = X, Y = Y + 8, W = W, H = 2, Fg = "SubText", Text = "The code never travels over the network. It is only valid for this request." }))
	Page:Add(Ui.Button.new({ X = X, Y = Y + H - 1, Text = " Cancel ", OnClick = function()
		Pairing.Cancelled = true
		os.queueEvent("blockdrive_cancel")
	end }))
end

--
-- Updating the BlockDrive client itself
--

function Act.Update()
	local Updater = BlockOS.Require("updater")
	local Current = BlockOS.Require("config").ReadText("/blockos/apps/blockdrive/version.txt") or "0"
	Run("Checking for updates...", function()
		local Body, Err = Updater.Get(Act.ManifestUrl)
		local Manifest = Body and textutils.unserialise(Body)
		if (type(Manifest) ~= "table" or Manifest.Edition ~= "blockdrive" or type(Manifest.Files) ~= "table") then
			return nil, { Code = "invalid", Message = "Could not read the update manifest: " .. tostring(Err or "bad format") }
		end
		if (Updater.Compare(Current:gsub("%s", ""), Manifest.Version) >= 0) then return "BlockDrive " .. Current:gsub("%s", "") .. " is up to date." end
		local Base = Act.ManifestUrl:gsub("[^/]*$", "")
		local Files = {}
		for _, File in ipairs(Manifest.Files) do
			local Data, FileErr = Updater.Get(Base .. File)
			if (not Data) then return nil, { Code = "invalid", Message = File .. ": " .. tostring(FileErr) } end
			Files[File] = Data
		end
		-- Only write once every file arrived, so a failed download changes nothing.
		for File, Data in pairs(Files) do BlockOS.Require("config").WriteText("/" .. File, Data) end
		return "Updated to BlockDrive " .. Manifest.Version .. ". Reopen BlockDrive to use it."
	end, function(Message, Err)
		if (not Message) then return Fail(Err) end
		Say(Message)
	end)
end

--
-- Layout
--

local function SidebarItems()
	local Items = { { Text = "BlockDrive", Header = true } }
	for _, Server in ipairs(Client.List()) do
		local Online = Client.Online(Server)
		table.insert(Items, { Text = Client.Title(Server), Server = Server, Icon = "\7", IconFg = Online == nil and colors.gray or (Online and colors.lime or colors.red) })
		if (S.Server and S.Server.NodeID == Server.NodeID and S.Info) then
			for _, Share in ipairs(S.Info.Shares or {}) do
				table.insert(Items, { Text = " " .. Share, Server = Server, Remote = Share, Icon = "\16", IconFg = colors.lightBlue })
			end
		end
	end
	table.insert(Items, { Text = "Add Server", Add = true, Icon = "+", IconFg = "Accent" })
	return Items
end

function Act.FileMenu(Entry, X, Y)
	local Options
	if (not Entry) then
		Options = { { Text = "New Folder...", Disabled = not Writable() }, { Text = "New Text File...", Disabled = not Writable() },
			{ Text = "Upload File...", Disabled = not Writable() }, "-", { Text = "Refresh" }, { Text = "Server Info" } }
	else
		local Edit = not Entry.Dir and Drive.IsText(Entry.Name)
		Options = {
			{ Text = Edit and "Open in Editor" or "Open" }, { Text = "Download...", Disabled = Entry.Dir }, "-",
			{ Text = "Rename...", Disabled = not Writable() }, { Text = "Duplicate", Disabled = not Writable() },
			{ Text = "Move To...", Disabled = not Writable() }, { Text = "Copy To...", Disabled = not Writable() }, "-",
			{ Text = "Get Info" }, { Text = "Delete", Disabled = not Writable() }
		}
	end
	local Index = Ui.ContextMenu(X, Y, Options)
	local Choice = Index and Options[Index].Text
	local Actions = {
		["New Folder..."] = Act.NewFolder, ["New Text File..."] = Act.NewText, ["Upload File..."] = function() Act.Upload() end,
		["Refresh"] = Act.Load, ["Server Info"] = Act.ServerInfo, ["Open"] = function() Act.Activate(Entry) end,
		["Open in Editor"] = function() Act.Activate(Entry) end, ["Download..."] = function() Act.Download(Entry) end,
		["Rename..."] = function() Act.Rename(Entry) end, ["Duplicate"] = function() Act.Duplicate(Entry) end,
		["Move To..."] = function() Act.Relocate(Entry, false) end, ["Copy To..."] = function() Act.Relocate(Entry, true) end,
		["Get Info"] = function() Act.GetInfo(Entry) end, ["Delete"] = function() Act.Delete(Entry) end
	}
	if (Choice and Actions[Choice]) then Actions[Choice]() end
end

function Act.MainMenu(X, Y)
	local Options = { "Add Server...", { Text = "Server Info", Disabled = not S.Server }, { Text = "Forget Server...", Disabled = not S.Server }, "-", "Check for Updates", "About BlockDrive" }
	local Index = Ui.ContextMenu(X, Y, Options)
	if (Index == 1) then
		Act.Discover()
	elseif (Index == 2) then
		Act.ServerInfo()
	elseif (Index == 3) then
		Act.Forget()
	elseif (Index == 5) then
		Act.Update()
	elseif (Index == 6) then
		local Version = BlockOS.Require("config").ReadText("/blockos/apps/blockdrive/version.txt") or "?"
		Ui.Alert("BlockDrive", "BlockDrive " .. Version:gsub("%s", "") .. "\nNetwork storage on BlockCloud servers in the Data Center, over rednet.")
	end
end

function View.Browse(X, Y, W, H)
	local Items = {}
	if (not S.Server) then
		Page:Add(Ui.Label.new({ X = X + 1, Y = Y + 1, W = W - 2, H = 6, Fg = "SubText", Text = #Client.List() == 0
			and "No servers yet. Choose Add Server to find the Data Center and pair with it."
			or "Choose a server on the left." }))
		return
	end
	for _, Entry in ipairs(S.Entries or {}) do
		table.insert(Items, {
			Text = Entry.Name, Entry = Entry,
			Icon = Entry.Dir and "\16" or (Drive.IsText(Entry.Name) and "\7" or "\4"),
			IconFg = Entry.Dir and colors.lightBlue or colors.lightGray,
			Right = Entry.Dir and "--" or Gfx.FormatSize(Entry.Size)
		})
	end
	local Files = Page:Add(Ui.List.new({ X = X, Y = Y, W = W, H = H, Items = Items }))
	Files.OnActivate = function(_, _, Item) Act.Activate(Item.Entry) end
	Files.OnContext = function(_, _, Item, MX, MY) Act.FileMenu(Item and Item.Entry, MX, MY) end
	Page:SetFocus(Files)
	if (S.Entries and #S.Entries == 0) then
		Page:Add(Ui.Label.new({ X = X + 1, Y = Y + 1, W = W - 2, Fg = "SubText", Text = "This folder is empty." }))
	end
end

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	if (S.Mode == "edit" and S.Editor) then
		View.Editor()
	else
		local SideW = (W >= 40) and 14 or 0
		Page:Add(Ui.Panel.new({ X = 1, Y = 1, W = W, H = 1, Bg = "Panel" }))
		Page:Add(Ui.Button.new({ X = 1, Y = 1, W = 3, Text = "\17", Bg = "Panel", OnClick = function() Act.History(S.Back, S.Forward) end }))
		Page:Add(Ui.Button.new({ X = 4, Y = 1, W = 3, Text = "\16", Bg = "Panel", OnClick = function() Act.History(S.Forward, S.Back) end }))
		Page:Add(Ui.Button.new({ X = 7, Y = 1, W = 3, Text = "\24", Bg = "Panel", OnClick = Act.Up }))
		Page:Add(Ui.Label.new({ X = 11, Y = 1, W = W - 21, Bg = "Panel", Fg = "PanelFg", Text = Breadcrumb() }))
		Page:Add(Ui.Button.new({ X = W - 9, Y = 1, W = 3, Text = "\25", Bg = "Panel", OnClick = function() Act.Upload() end }))
		Page:Add(Ui.Button.new({ X = W - 6, Y = 1, W = 3, Text = "+", Bg = "Panel", OnClick = Act.NewFolder }))
		Page:Add(Ui.Button.new({ X = W - 3, Y = 1, W = 3, Text = "\15", Bg = "Panel", OnClick = function() Act.MainMenu(W - 3, 2) end }))
		local Sidebar = Page:Add(Ui.List.new({ X = 1, Y = 2, W = SideW, H = H - 2, Bg = "Panel", Focusable = false, SingleClick = true, Visible = SideW > 0 }))
		local SideItems = SidebarItems()
		Sidebar:SetItems(SideItems)
		for Index, Item in ipairs(SideItems) do
			if (Item.Server and S.Server and Item.Server.NodeID == S.Server.NodeID and (Item.Remote or "") == (S.Remote:match("^[^/]*") or "") and S.Mode == "browse") then Sidebar.Selected = Index end
			if (Item.Add and S.Mode ~= "browse") then Sidebar.Selected = Index end
		end
		Sidebar.RenderItem = function(_, T, Th, Item, X, Y, Width, Selected, RowBg, RowFg)
			if (Item.Header) then
				Gfx.Write(T, X, Y, Gfx.Pad(Item.Text, Width), Th.SubText, Th.Panel)
				return
			end
			Gfx.Write(T, X, Y, " " .. Item.Icon .. " " .. Gfx.Truncate(Item.Text, Width - 4), Selected and RowFg or Th.PanelFg, RowBg)
			if (not Selected) then Gfx.Write(T, X + 1, Y, Item.Icon, Ui.Resolve(Item.IconFg, Th, Th.PanelFg), RowBg) end
		end
		Sidebar.OnActivate = function(_, _, Item)
			if (Item.Add) then
				Act.Discover()
			elseif (Item.Server) then
				Act.Open(Item.Server, Item.Remote or "")
			end
		end
		local X, Y, CW, CH = SideW + 1, 2, W - SideW, H - 2
		if (SideW > 0) then X, CW = X + 1, CW - 1 end
		if (S.Mode == "add") then
			View.Add(X, Y + 1, CW - 1, CH - 1)
		elseif (S.Mode == "pair") then
			View.Pair(X, Y + 1, CW - 1, CH - 1)
		else
			View.Browse(X - (SideW > 0 and 1 or 0), Y, CW + (SideW > 0 and 1 or 0), CH)
		end
	end
	-- Status bar: a progress bar behind the text while transferring, errors in red.
	Page:Add(Ui.Canvas.new({ X = 1, Y = H, W = W, H = 1, OnDraw = function(Self, T, Th)
		local Text = Gfx.Pad(S.Error or S.Status or "", W, "center")
		local Filled = S.Progress and math.floor(W * S.Progress + .5) or 0
		local Fg = Gfx.ToBlit(S.Error and colors.red or Th.SubText)
		T.setCursorPos(1, H)
		T.blit(Text, Gfx.ToBlit(Th.AccentFg):rep(Filled) .. Fg:rep(W - Filled), Gfx.ToBlit(Th.Accent):rep(Filled) .. Gfx.ToBlit(Th.Panel):rep(W - Filled))
	end }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

-- Keyboard shortcuts in the browser, and getting events to background tasks.
function Page:OnEvent(Name, A, B, C)
	if (Name == "key" and S.Mode == "browse") then
		if (A == keys.backspace) then
			Act.Up()
			return true
		elseif (A == keys.f5) then
			Act.Load()
			return true
		end
	elseif (Name == "blockos_close") then
		Act.CloseEditor()
		if (not S.Editor) then BlockOS.Quit() end
		return true
	elseif (Name == "blockos_open" and A) then
		Act.Args({ A, B })
		return true
	elseif (Name == "rednet_message" and C == Protocol.Discover) then
		-- A server that restarted announces itself: reconnect if it was the one we are viewing.
		local Node = Client.HandleAnnounce(A, B)
		if (Node and S.Server and Node.NodeID == S.Server.NodeID and S.Error and S.Mode == "browse") then
			Act.Load()
		end
	elseif (Name == "blockcloud_client") then
		Build()
	end
	if (Name ~= "char" and Name ~= "key" and Name ~= "key_up" and Tasks.Dispatch(Name, A, B, C)) then
		return true
	end
	return false
end

-- Only while the current server is unreachable: a gentle check every 20 seconds.
Page:SetInterval(20, function()
	local Server = S.Server
	if (not Server or Client.Online(Server) ~= false or Tasks.Busy() or S.Mode ~= "browse") then return false end
	Tasks.Spawn("ping", function() return Client.Hello(Server) end, function(Ok, Result)
		if (Ok and Result and S.Server == Server) then Act.Load() end
	end)
	return false
end)

function Act.Args(List)
	if (List[1] == "add") then
		Act.Discover()
	elseif (List[1] == "upload" and List[2]) then
		local Servers = Client.List()
		if (#Servers == 0) then
			Act.Discover()
			return
		end
		local Index = 1
		if (#Servers > 1) then
			local Names = {}
			for _, Server in ipairs(Servers) do table.insert(Names, Client.Title(Server)) end
			Index = Ui.Choose("Upload to", Names)
			if (not Index) then return end
		end
		local Server = Servers[Index]
		local Info = Drive.Info(Server)
		local Folder = Ui.Prompt("Upload " .. fs.getName(List[2]), "Folder on " .. Client.Title(Server) .. ":", (Info and Info.Shares and Info.Shares[1]) or "")
		if (not Folder) then return end
		local Target = Path.Normalize(Folder)
		if (not Target) then return Fail({ Code = "invalid_path" }) end
		S.Server, S.Remote, S.Info = Server, Target, Info
		Act.Open(Server, Target, true)
		Act.Upload(List[2])
	elseif (List[1] and Client.Get(List[1])) then
		Act.Open(Client.Get(List[1]), List[2] or "")
	end
end

-- Open the requested server, or the only one, straight away.
if (#Args > 0) then
	Page:Resize()
	Act.Args(Args)
elseif (#Client.List() == 1) then
	Act.Open(Client.List()[1], "")
end
Page:Run()
