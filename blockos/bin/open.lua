-- open: opens a file, folder or app the same way Finder does.

local Target = ...
if (not Target) then
	print("Usage: open <file | folder | app id>")
	return
end

local Path = shell.resolve(Target)
if (fs.exists(Path)) then
	BlockOS.Open("/" .. Path)
elseif (not BlockOS.Launch(Target)) then
	printError("Nothing called " .. Target)
end
