-- Finder integration for BlockCloud, kept apart from Finder itself so Finder only needs a few
-- guarded calls. On Server Edition it adds the storage folder and logs; on the desktop it adds
-- a BlockDrive section listing paired servers, which open in the BlockDrive app.

local Link = {}

local function ClientInstalled()
	return fs.exists("/blockos/apps/blockdrive/main.lua") and fs.exists("/blockos/lib/cloud/client.lua")
end

-- Extra sidebar entries. Path entries are browsed in Finder; Launch entries open an app.
function Link.Places()
	if (BlockOS.Edition == "server") then
		local Server = BlockOS.Require("server/config")
		local Settings = Server.Settings()
		return {
			{ Text = "BlockCloud", Header = true },
			{ Text = "Storage", Path = "/" .. fs.combine(Settings.StorageRoot, ""), Icon = "\15", IconFg = colors.cyan },
			{ Text = "Logs", Path = "/blockos/data/cloud/logs", Icon = "\7", IconFg = colors.lightGray }
		}
	end
	if (not ClientInstalled()) then return {} end
	local Client = BlockOS.Require("cloud/client")
	local Items = { { Text = "BlockDrive", Header = true } }
	for _, Server in ipairs(Client.List()) do
		table.insert(Items, { Text = Client.Title(Server), Launch = { "blockdrive", { Server.NodeID } }, Icon = "\15", IconFg = colors.cyan })
	end
	if (#Items == 1) then
		table.insert(Items, { Text = "Add Server", Launch = { "blockdrive", { "add" } }, Icon = "+", IconFg = colors.cyan })
	end
	return Items
end

function Link.CanUpload()
	if (BlockOS.Edition == "server" or not ClientInstalled()) then return false end
	return #BlockOS.Require("cloud/client").List() > 0
end

-- Opens BlockDrive ready to upload a local file.
function Link.Upload(Path)
	BlockOS.Launch("blockdrive", { "upload", Path })
end

return Link
