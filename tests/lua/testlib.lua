-- Test helpers for scripts that run on harness computers. Sets up the BlockOS library API
-- (as boot.lua does, without starting the desktop) and records PASS/FAIL lines in results.txt.

local Loaded = {}
_G.BlockOS = _G.BlockOS or { Root = "/blockos" }
if (not BlockOS.Require) then
	function BlockOS.Load(Path, ...)
		local Fn, Err = loadfile(Path, nil, _G)
		if (not Fn) then error(Err, 2) end
		return Fn(...)
	end
	function BlockOS.Require(Name)
		if (Loaded[Name]) then return Loaded[Name] end
		local Path = (Name:sub(1, 7) == "server/") and ("/blockos/" .. Name .. ".lua") or ("/blockos/lib/" .. Name .. ".lua")
		local Module = BlockOS.Load(Path)
		if (Name ~= "ui") then Loaded[Name] = Module end
		return Module
	end
end

local T = { Failed = 0 }

local function Record(Line)
	local Handle = fs.open("/results.txt", "a")
	Handle.writeLine(Line)
	Handle.close()
	print(Line)
end

function T.Check(Name, Condition, Detail)
	if (Condition) then
		Record("PASS " .. Name)
	else
		T.Failed = T.Failed + 1
		Record("FAIL " .. Name .. (Detail ~= nil and (": " .. tostring(Detail)) or ""))
	end
	return Condition
end

function T.Describe(Err)
	if (type(Err) == "table") then return tostring(Err.Code) .. " " .. tostring(Err.Message) end
	return tostring(Err)
end

-- Expects Fn's second return value to be an error with Code.
function T.ExpectError(Name, Code, Result, Err)
	return T.Check(Name, Result == nil and type(Err) == "table" and Err.Code == Code,
		"expected " .. Code .. ", got " .. (Result ~= nil and "success" or T.Describe(Err)))
end

function T.Run(Fn)
	local Ok, Err = pcall(Fn)
	if (not Ok) then T.Check("script finished without error", false, Err) end
	local Handle = fs.open("/harness_done", "w")
	Handle.close()
end

-- Sends a command to the test admin helper running beside the server (tests/server_startup.lua).
function T.Admin(Server, Command, Timeout)
	peripheral.find("modem", function(Side) if (not rednet.isOpen(Side)) then rednet.open(Side) end end)
	rednet.send(Server, Command, "blockcloud-test/admin")
	local Sender, Reply
	repeat
		Sender, Reply = rednet.receive("blockcloud-test/admin", Timeout or 10)
	until Sender == nil or Sender == Server
	return Reply
end

function T.WriteFile(Path, Data)
	local Handle = fs.open(Path, "wb")
	Handle.write(Data)
	Handle.close()
end

function T.ReadFile(Path)
	local Handle = fs.open(Path, "rb")
	if (not Handle) then return nil end
	local Data = Handle.readAll()
	Handle.close()
	return Data
end

return T
