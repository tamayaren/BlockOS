-- Boots BlockOS when it is installed.

if (fs.exists("/blockos/boot.lua")) then
	shell.run("/blockos/boot.lua")
end
