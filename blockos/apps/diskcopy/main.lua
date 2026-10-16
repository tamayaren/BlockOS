-- DiskCopy: duplicate, back up, restore, erase and label floppy disks, or make an installer disk.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Config = BlockOS.Require("config")

local Page = Ui.Page.new()
local Drives = {}
local Progress = 0
local Status = "Insert a disk into a disk drive."
local Busy = false
local DriveList
local Build

local function ScanDrives()
	Drives = {}
	for _, Name in ipairs(peripheral.getNames()) do
		if (peripheral.getType(Name) == "drive") then
			local Entry = { Name = Name, Present = disk.isPresent(Name), HasData = disk.hasData(Name) }
			if (Entry.HasData) then
				Entry.Mount = "/" .. disk.getMountPath(Name)
				Entry.Label = disk.getLabel(Name)
				Entry.Free = fs.getFreeSpace(Entry.Mount)
				Entry.Capacity = fs.getCapacity and fs.getCapacity(Entry.Mount) or nil
			elseif (Entry.Present and disk.hasAudio(Name)) then
				Entry.Audio = disk.getAudioTitle(Name)
			end
			table.insert(Drives, Entry)
		end
	end
end

local function ListFiles(Root, Relative, Into, Exclude)
	Into = Into or {}
	local Dir = fs.combine(Root, Relative or "")
	for _, Name in ipairs(fs.list(Dir)) do
		local Child = fs.combine(Relative or "", Name)
		if (not (Exclude and Exclude[Child])) then
			if (fs.isDir(fs.combine(Root, Child))) then
				table.insert(Into, { Path = Child, Dir = true })
				ListFiles(Root, Child, Into, Exclude)
			else
				table.insert(Into, { Path = Child, Size = fs.getSize(fs.combine(Root, Child)) })
			end
		end
	end
	return Into
end

local function TreeSize(Files)
	local Total = 0
	for _, File in ipairs(Files) do
		Total = Total + (File.Size or 0)
	end
	return Total
end

local function SetProgress(Value, Text)
	Progress = Value
	Status = Text
	Page:Draw()
end

local function CopyTree(Source, Target, Exclude)
	local Files = ListFiles(Source, nil, nil, Exclude)
	local Size = TreeSize(Files)
	if (Size > fs.getFreeSpace(Target)) then
		return false, "Not enough space: needs " .. Gfx.FormatSize(Size) .. ", " .. Gfx.FormatSize(fs.getFreeSpace(Target)) .. " free."
	end
	local Done = 0
	for Index, File in ipairs(Files) do
		local Destination = fs.combine(Target, File.Path)
		if (File.Dir) then
			if (not fs.exists(Destination)) then fs.makeDir(Destination) end
		else
			if (fs.exists(Destination)) then fs.delete(Destination) end
			fs.copy(fs.combine(Source, File.Path), Destination)
			Done = Done + File.Size
		end
		SetProgress(Index / #Files, "Copying " .. File.Path)
		if (Index % 8 == 0) then sleep(0) end
	end
	return true, #Files .. " items, " .. Gfx.FormatSize(Done)
end

local function EraseMount(Mount)
	for _, Name in ipairs(fs.list(Mount)) do
		fs.delete(fs.combine(Mount, Name))
	end
end

local function SelectedDrive()
	local Item = DriveList and DriveList.Items[DriveList.Selected]
	return Item and Item.Drive
end

local function RequireDisk()
	local Drive = SelectedDrive()
	if (not Drive or not Drive.HasData) then
		Ui.Alert("DiskCopy", "Select a drive with a floppy disk in it.")
		return nil
	end
	return Drive
end

local function Run(Task)
	if (Busy) then return end
	Busy = true
	local Ok, Result, Detail = pcall(Task)
	Busy = false
	if (not Ok) then
		Status = "Error: " .. tostring(Result)
	elseif (Result == false) then
		Status = tostring(Detail)
	elseif (Result) then
		Status = tostring(Result)
		Progress = 1
	end
	ScanDrives()
	Build()
end

local Actions = {
	{ Text = "Duplicate", Task = function()
		local Source = RequireDisk()
		if (not Source) then return end
		local Targets, Names = {}, {}
		for _, Drive in ipairs(Drives) do
			if (Drive ~= Source and Drive.HasData) then
				table.insert(Targets, Drive)
				table.insert(Names, (Drive.Label or "Untitled") .. " (" .. Drive.Name .. ")")
			end
		end
		if (#Targets == 0) then
			Ui.Alert("Duplicate", "Insert a second disk into another drive.")
			return
		end
		local Index = Ui.Choose("Copy to", Names)
		if (not Index) then return end
		local Target = Targets[Index]
		if (not Ui.Confirm("Duplicate", "Erase \"" .. (Target.Label or "Untitled") .. "\" and copy \"" .. (Source.Label or "Untitled") .. "\" onto it?", "Duplicate")) then return end
		EraseMount(Target.Mount)
		local Ok, Text = CopyTree(Source.Mount, Target.Mount)
		if (Ok and Source.Label) then disk.setLabel(Target.Name, Source.Label) end
		return Ok and ("Duplicated: " .. Text) or false, Text
	end },
	{ Text = "Back Up", Task = function()
		local Source = RequireDisk()
		if (not Source) then return end
		local Name = (Source.Label or "disk"):gsub("[^%w%-_ ]", "") .. " " .. os.date("%Y-%m-%d %H%M")
		local Target = fs.combine("/home/Backups", Name)
		fs.makeDir(Target)
		local Ok, Text = CopyTree(Source.Mount, Target)
		return Ok and ("Backed up to /" .. Target) or false, Text
	end },
	{ Text = "Restore", Task = function()
		local Target = RequireDisk()
		if (not Target) then return end
		local Folder = Ui.PickFile({ Title = "Restore from folder", Dir = "/home/Backups", Folders = true })
		if (not Folder) then return end
		if (not Ui.Confirm("Restore", "Erase the disk and copy " .. Folder .. " onto it?", "Restore")) then return end
		EraseMount(Target.Mount)
		local Ok, Text = CopyTree(Folder, Target.Mount)
		return Ok and ("Restored: " .. Text) or false, Text
	end },
	{ Text = "Erase", Task = function()
		local Target = RequireDisk()
		if (not Target) then return end
		if (not Ui.Confirm("Erase Disk", "Permanently erase everything on \"" .. (Target.Label or "Untitled") .. "\"?", "Erase")) then return end
		EraseMount(Target.Mount)
		return "Disk erased"
	end },
	{ Text = "Label", Task = function()
		local Drive = SelectedDrive()
		if (not Drive or not Drive.Present) then return end
		local Label = Ui.Prompt("Label Disk", "New label:", Drive.Label or "")
		if (Label == nil) then return end
		disk.setLabel(Drive.Name, #Label > 0 and Label or nil)
		return "Label updated"
	end },
	{ Text = "Installer", Task = function()
		local Target = RequireDisk()
		if (not Target) then return end
		if (not Ui.Confirm("Installer Disk", "Write a BlockOS network installer to this disk? Any computer that boots it can install BlockOS.", "Write")) then return end
		local Repo = Config.Settings().UpdateURL or Config.Repo
		local Script = table.concat({
			"-- BlockOS installer disk",
			"term.clear() term.setCursorPos(1, 1)",
			"print(\"BlockOS installer disk\")",
			"write(\"Install BlockOS on this computer? (y/n) \")",
			"if (read():lower():sub(1, 1) ~= \"y\") then return end",
			"shell.run(\"wget\", \"run\", " .. string.format("%q", Repo .. "install.lua") .. ")"
		}, "\n")
		Config.WriteText(fs.combine(Target.Mount, "startup.lua"), Script .. "\n")
		disk.setLabel(Target.Name, "BlockOS Installer")
		return "Installer disk ready"
	end },
	{ Text = "Eject", Task = function()
		local Drive = SelectedDrive()
		if (Drive) then disk.eject(Drive.Name) end
	end }
}

function Build()
	Page:Clear()
	local W, H = Page.W, Page.H
	local Items = {}
	for _, Drive in ipairs(Drives) do
		local Text, Right
		if (Drive.HasData) then
			Text = (Drive.Label or "Untitled") .. "  " .. Drive.Mount
			Right = Drive.Capacity and (Gfx.FormatSize(Drive.Capacity - Drive.Free) .. " used") or (Gfx.FormatSize(Drive.Free) .. " free")
		elseif (Drive.Audio) then
			Text, Right = "\14 " .. Drive.Audio, "music"
		else
			Text, Right = "(empty)", ""
		end
		table.insert(Items, { Text = Drive.Name .. ": " .. Text, Icon = "\22", IconFg = Drive.HasData and "Accent" or "SubText", Right = Right, Drive = Drive })
	end
	local Selected = DriveList and DriveList.Selected or 1
	DriveList = Page:Add(Ui.List.new({ X = 1, Y = 1, W = W, H = math.max(3, H - 8), Bg = "Panel" }))
	DriveList:SetItems(Items)
	DriveList.Selected = math.min(math.max(Selected, 1), #Items)
	if (#Items == 0) then
		Page:Add(Ui.Label.new({ X = 2, Y = 2, W = W - 2, H = 2, Bg = "Panel", Fg = "SubText", Text = "No disk drives attached. Place a disk drive next to the computer." }))
	end
	local X, Y = 2, H - 6
	for _, Action in ipairs(Actions) do
		local Width = #Action.Text + 2
		if (X + Width > W + 1) then
			X = 2
			Y = Y + 2
		end
		Page:Add(Ui.Button.new({ X = X, Y = Y, W = Width, Text = Action.Text, Enabled = not Busy, OnClick = function() Run(Action.Task) end }))
		X = X + Width + 1
	end
	Page:Add(Ui.Progress.new({ X = 2, Y = H - 1, W = W - 2, Value = function() return Progress end }))
	Page:Add(Ui.Label.new({ X = 1, Y = H, W = W, Fg = "SubText", Text = function() return " " .. Status end }))
	Page:Invalidate()
end

function Page:OnLayout()
	Build()
end

function Page:OnEvent(Name)
	if (not Busy and (Name == "disk" or Name == "disk_eject" or Name == "peripheral" or Name == "peripheral_detach")) then
		ScanDrives()
		Progress = 0
		Build()
		return true
	end
	return false
end

ScanDrives()
Page:Run()
