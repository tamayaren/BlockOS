-- bpm: the BlockOS package manager on the command line.

local Apps = BlockOS.Require("apps")
local Config = BlockOS.Require("config")
local Updater = BlockOS.Require("updater")

local Args = { ... }
local Command = Args[1]

local function Usage()
	print("Usage:")
	print("  bpm list                  installed apps")
	print("  bpm search [query]        search app catalogs")
	print("  bpm get <id>              install from a catalog")
	print("  bpm pastebin <code> [name] install from Pastebin")
	print("  bpm url <url> [name]      install from a URL")
	print("  bpm remove <id>           uninstall an app")
	print("  bpm update                update BlockOS")
end

local function Catalog()
	local Entries = {}
	for _, Url in ipairs(Config.Settings().Repositories) do
		local Body = Updater.Get(Url)
		local Data = Body and textutils.unserialise(Body)
		if (type(Data) == "table" and type(Data.Apps) == "table") then
			for _, Entry in ipairs(Data.Apps) do
				Entry.Base = Url
				table.insert(Entries, Entry)
			end
		else
			printError("Could not load " .. Url)
		end
	end
	return Entries
end

local function InstallSource(Meta, Source)
	local App = Apps.Install(Meta, Source)
	print("Installed " .. App.Name .. " (" .. App.ID .. ")")
end

if (Command == "list") then
	for _, App in ipairs(Apps.List(true)) do
		print((App.System and "  " or "* ") .. App.ID .. "  " .. App.Name .. (App.Version and (" " .. App.Version) or ""))
	end
	print("* = installed by you")
elseif (Command == "search") then
	local Query = (Args[2] or ""):lower()
	for _, Entry in ipairs(Catalog()) do
		if (Query == "" or Entry.Name:lower():find(Query, 1, true) or Entry.ID:find(Query, 1, true)) then
			print(Entry.ID .. " - " .. Entry.Name .. ": " .. (Entry.Description or ""))
		end
	end
elseif (Command == "get" and Args[2]) then
	for _, Entry in ipairs(Catalog()) do
		if (Entry.ID == Args[2]) then
			local Source, Err
			if (Entry.Source.Type == "pastebin") then
				Source, Err = Apps.FetchPastebin(Entry.Source.Code)
			elseif (Entry.Source.Type == "url") then
				local Url = Entry.Source.Url
				if (not Url:match("^https?://")) then Url = Entry.Base:gsub("[^/]*$", "") .. Url end
				Source, Err = Apps.Fetch(Url)
			elseif (Entry.Source.Type == "rom") then
				Source = "shell.run(" .. string.format("%q", Entry.Source.Program) .. ", ...)\n"
			end
			if (not Source) then
				printError(Err or "Download failed")
				return
			end
			InstallSource({
				ID = Entry.ID, Name = Entry.Name, Description = Entry.Description, Version = Entry.Version,
				StoreID = Entry.ID, Icon = Entry.Icon, Mode = Entry.Mode, Width = Entry.Width, Height = Entry.Height, Source = Entry.Source
			}, Source)
			return
		end
	end
	printError("No app with ID " .. Args[2])
elseif ((Command == "pastebin" or Command == "url") and Args[2]) then
	local Source, Err
	if (Command == "pastebin") then
		Source, Err = Apps.FetchPastebin(Args[2])
	else
		Source, Err = Apps.Fetch(Args[2])
	end
	if (not Source) then
		printError(Err or "Download failed")
		return
	end
	local Name = Args[3] or Args[2]:match("([%w_%-]+)%.?%w*$") or "App"
	InstallSource({ Name = Name, Description = "Installed with bpm", Source = { Type = Command, Code = Args[2], Url = Args[2] } }, Source)
elseif (Command == "remove" and Args[2]) then
	if (Apps.Uninstall(Args[2])) then
		print("Removed " .. Args[2])
	else
		printError("No installed app with ID " .. Args[2])
	end
elseif (Command == "update") then
	print("Checking " .. Updater.Base())
	local Manifest, Err = Updater.Check()
	if (not Manifest) then
		printError(Err)
		return
	end
	if (not Manifest.Newer) then
		print("BlockOS " .. Config.Version() .. " is up to date.")
		return
	end
	print("Updating to " .. Manifest.Version .. "...")
	local Ok, ApplyErr = Updater.Apply(Manifest, function(Done, Total)
		local _, Y = term.getCursorPos()
		term.setCursorPos(1, Y)
		term.clearLine()
		write(Done .. "/" .. Total)
	end)
	print()
	if (Ok) then
		print("Done. Restart to finish.")
	else
		printError(ApplyErr)
	end
else
	Usage()
end
