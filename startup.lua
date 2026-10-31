-- Boots BlockOS when it is installed: Server Edition if present, otherwise the desktop.

if (fs.exists("/blockos/server/boot.lua")) then
	shell.run("/blockos/server/boot.lua")
elseif (fs.exists("/blockos/boot.lua")) then
	shell.run("/blockos/boot.lua")
end
