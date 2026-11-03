-- Serves a folder of .ccmd pages the way a ccinternet core serves a domain, so sites can be
-- browsed and previewed before they are uploaded. Used by Savannah (local:// addresses) and CCDream.

local Ccmd = BlockOS.Require("ccinternet/ccmd")
local Protocol = BlockOS.Require("ccinternet/protocol")

local Site = {}
Site.__index = Site

Site.MaxFiles = 256
Site.MaxDepth = 8

local function ReadFile(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil end
	local Handle = fs.open(Path, "rb")
	if (not Handle) then return nil end
	local Data = Handle.readAll() or ""
	Handle.close()
	return Data
end

Site.ReadFile = ReadFile

-- Builds a small .ccmd page: a coloured title, a message and optional links { { Text, Url } }.
function Site.Message(Title, Message, Colour, Links)
	local Lines = {
		"--", "title: " .. tostring(Title):gsub("\n", " "), "location: /", "--",
		"<br/>",
		"<p alignment=\"center\">",
		"{" .. (Colour or "red") .. "}" .. Ccmd.Escape(Title) .. "{/}",
		"</p>",
		"<br/>",
		"<p alignment=\"center\">",
		Ccmd.Escape(Message or ""),
		"</p>"
	}
	if (Links and #Links > 0) then
		Lines[#Lines + 1] = "<br/>"
		Lines[#Lines + 1] = "<p alignment=\"center\">"
		local Parts = {}
		for _, Link in ipairs(Links) do
			Parts[#Parts + 1] = "[" .. Ccmd.Escape(Link[1]) .. "](" .. tostring(Link[2]):gsub("[%(%)%s]", "") .. ")"
		end
		Lines[#Lines + 1] = table.concat(Parts, "   ")
		Lines[#Lines + 1] = "</p>"
	end
	return table.concat(Lines, "\n")
end

-- The folder a page belongs to: the nearest folder (the page's own, or one above it) holding a
-- page with "location: /". Falls back to the page's own folder.
function Site.FindRoot(Path)
	Path = "/" .. fs.combine(Path, "")
	local Dir = fs.isDir(Path) and Path or "/" .. fs.getDir(Path)
	local Start = Dir
	for _ = 1, Site.MaxDepth do
		if (fs.isDir(Dir)) then
			for _, Name in ipairs(fs.list(Dir)) do
				local Full = fs.combine(Dir, Name)
				if (Name:lower():match("%.ccmd$") and not fs.isDir(Full)) then
					local Meta = Ccmd.ParseFrontMatter(ReadFile(Full) or "")
					if (Meta and Meta.location and Protocol.NormalizePath(Meta.location) == "/") then
						return "/" .. fs.combine(Dir, "")
					end
				end
			end
		end
		if (Dir == "/" or Dir == "/home" or Dir == "") then break end
		Dir = "/" .. fs.getDir(Dir)
	end
	return Start
end

function Site.New(Root)
	return setmetatable({ Root = "/" .. fs.combine(Root, "") }, Site)
end

-- Every file of the site as { Path = "/sub/file.ccmd", Full = "/real/path", Size }.
function Site:Files()
	local Files = {}
	local function Walk(Dir, Prefix, Depth)
		if (Depth > Site.MaxDepth or #Files >= Site.MaxFiles) then return end
		local Names = fs.list(Dir)
		table.sort(Names, function(A, B) return A:lower() < B:lower() end)
		for _, Name in ipairs(Names) do
			local Full = fs.combine(Dir, Name)
			if (fs.isDir(Full)) then
				if (Name:sub(1, 1) ~= ".") then Walk(Full, Prefix .. Name .. "/", Depth + 1) end
			elseif (#Files < Site.MaxFiles) then
				Files[#Files + 1] = { Path = Prefix .. Name, Full = "/" .. Full, Size = fs.getSize(Full) }
			end
		end
	end
	if (fs.isDir(self.Root)) then Walk(self.Root, "/", 1) end
	return Files
end

-- Maps page locations to files by reading every page's front matter. Cached until Refresh.
-- Returns Routes ({ [location] = path }), Pages ({ Path, Location, Title, Error }) and Conflicts.
function Site:Routes()
	if (self.Cache) then return self.Cache.Routes, self.Cache.Pages, self.Cache.Conflicts end
	local Routes, Pages, Conflicts = {}, {}, {}
	for _, File in ipairs(self:Files()) do
		if (File.Path:lower():match("%.ccmd$")) then
			local Meta, _, Problem = Ccmd.ParseFrontMatter(ReadFile(File.Full) or "")
			local Info = { Path = File.Path, Full = File.Full, Title = Meta and Meta.title, Error = Problem }
			local Location = Meta and Meta.location and Protocol.NormalizePath(Meta.location)
			if (Location) then
				Info.Location = Location
				if (Routes[Location]) then
					Conflicts[#Conflicts + 1] = Location
				else
					Routes[Location] = File.Path
				end
			end
			Pages[#Pages + 1] = Info
		end
	end
	self.Cache = { Routes = Routes, Pages = Pages, Conflicts = Conflicts }
	return Routes, Pages, Conflicts
end

function Site:Refresh()
	self.Cache = nil
end

-- Real path of a site path, or nil when it would leave the site.
function Site:RealPath(Path)
	local Clean = Protocol.NormalizePath(Path)
	if (not Clean) then return nil end
	return "/" .. fs.combine(self.Root, Clean)
end

-- Site path ("/sub/page.ccmd") of a real path inside the site, or nil.
function Site:SitePath(Full)
	Full = "/" .. fs.combine(Full, "")
	local Root = self.Root == "/" and "/" or self.Root .. "/"
	if (Full == self.Root) then return "/" end
	if (Full:sub(1, #Root) ~= Root) then return nil end
	return "/" .. Full:sub(#Root + 1)
end

-- The address of a file in the site: its location for pages, else its path.
function Site:Address(Full)
	local Path = self:SitePath(Full)
	if (not Path) then return nil end
	local Meta = Ccmd.ParseFrontMatter(ReadFile(Full) or "")
	local Location = Meta and Meta.location and Protocol.NormalizePath(Meta.location)
	return Location or Path
end

-- Finds the file for a request path: a page location first, then a file path, then a folder's index.ccmd.
function Site:Resolve(Path)
	local Routes = self:Routes()
	local Clean = Protocol.NormalizePath(Path)
	if (not Clean) then return nil end
	if (Routes[Clean]) then return Routes[Clean] end
	local Real = self:RealPath(Clean)
	if (Real and fs.exists(Real)) then
		if (not fs.isDir(Real)) then return Clean end
		local Index = (Clean == "/" and "" or Clean) .. "/index.ccmd"
		if (fs.exists(self:RealPath(Index))) then return Index end
	end
	return nil
end

function Site:Read(Path)
	local Real = self:RealPath(Path)
	return Real and ReadFile(Real)
end

local function Page(Status, Source)
	return { Status = Status, Headers = { ["Content-Type"] = "text/ccmd" }, Body = Source }
end

-- Answers a request like a core would. Url is a parsed URL; Base is the address prefix
-- ("local://mysite") used in generated links.
function Site:Request(Method, Url, Body, Base)
	Base = Base or ""
	if (Method == "POST") then
		return Page(200, Site.Message("Sent!", "This is a local preview, so the form was not sent anywhere. Upload the site to a ccinternet core to receive form submissions.", "lime", { { "Back to the site", Base .. "/" } }))
	end
	local File = self:Resolve(Url.Path)
	local Data = File and self:Read(File)
	if (not Data) then
		local Missing = self:Resolve("/404")
		local Custom = Missing and self:Read(Missing)
		if (Custom) then return Page(404, Custom) end
		return Page(404, Site.Message("Page not found", Url.Path .. " is not a page or file of this site.\n\nPages get their address from the location line of their front matter.", "red", { { "Home page", Base .. "/" } }))
	end
	return { Status = 200, Headers = { ["Content-Type"] = Protocol.ContentType(File), ["Content-Length"] = #Data }, Body = Data }
end

return Site
