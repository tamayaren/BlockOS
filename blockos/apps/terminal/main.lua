-- Terminal: an interactive CraftOS shell inside a BlockOS window.

local Args = { ... }

if (Args[1] and fs.isDir(Args[1])) then
	shell.setDir(Args[1])
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.lime)
print("BlockOS " .. (BlockOS.Version or "") .. " Terminal")
term.setTextColor(colors.lightGray)
print("Type 'help' for commands and 'exit' to close.")
term.setTextColor(colors.white)

shell.run("/rom/programs/shell.lua")
