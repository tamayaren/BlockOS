-- Runs a program inside a desktop window and optionally waits before the window closes.

local Args = { ... }
local Hold = table.remove(Args, 1) == "hold"
local Path = table.remove(Args, 1)

local Ok
if (shell.execute) then
	Ok = shell.execute(Path, table.unpack(Args))
else
	Ok = shell.run(Path, table.unpack(Args))
end

if (Hold or not Ok) then
	term.setTextColor(colors.lightGray)
	print()
	print(Ok and "Process finished." or "Process exited with an error.")
	write("Press any key to close this window.")
	os.pullEvent("key")
end
