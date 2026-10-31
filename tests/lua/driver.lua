-- Drives the real BlockOS desktop from a test: reads the screen through BlockOS.Capture and
-- queues ordinary mouse and keyboard events, the same ones a player's input produces.
local D = {}

function D.Screen()
	local Lines = {}
	for Y, Line in ipairs(BlockOS.Capture().Lines) do Lines[Y] = Line[1] end
	return Lines
end

-- Finds Text on screen (plain match); Last picks the lowest occurrence.
function D.Find(Text, Last)
	local FoundX, FoundY
	for Y, Line in ipairs(D.Screen()) do
		local X = Line:find(Text, 1, true)
		if (X) then
			FoundX, FoundY = X, Y
			if (not Last) then break end
		end
	end
	return FoundX, FoundY
end

function D.Wait(Text, Timeout, Last)
	local Deadline = os.clock() + (Timeout or 10)
	while (os.clock() < Deadline) do
		if (BlockOS.Capture) then
			local X, Y = D.Find(Text, Last)
			if (X) then return X, Y end
		end
		sleep(.2)
	end
	return nil
end

function D.Match(Pattern)
	for _, Line in ipairs(D.Screen()) do
		local Found = Line:match(Pattern)
		if (Found) then return Found end
	end
end

function D.Click(X, Y, Button)
	os.queueEvent("mouse_click", Button or 1, X, Y)
	os.queueEvent("mouse_up", Button or 1, X, Y)
	sleep(.3)
end

function D.DoubleClick(X, Y)
	os.queueEvent("mouse_click", 1, X, Y)
	os.queueEvent("mouse_up", 1, X, Y)
	os.queueEvent("mouse_click", 1, X, Y)
	os.queueEvent("mouse_up", 1, X, Y)
	sleep(.3)
end

function D.Key(Key, Ctrl)
	if (Ctrl) then os.queueEvent("key", keys.leftCtrl, false) end
	os.queueEvent("key", Key, false)
	os.queueEvent("key_up", Key)
	if (Ctrl) then os.queueEvent("key_up", keys.leftCtrl) end
	sleep(.2)
end

function D.Type(Text)
	for Char in Text:gmatch(".") do os.queueEvent("char", Char) end
	sleep(.2)
end

function D.Dump(Path)
	local Handle = fs.open(Path, "a")
	Handle.writeLine("----")
	for _, Line in ipairs(D.Screen()) do Handle.writeLine("|" .. Line:gsub("[%c\128-\255]", "*") .. "|") end
	Handle.close()
end

return D
