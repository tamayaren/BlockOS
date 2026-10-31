-- After the harness clicks through the first-boot setup wizard, the server must be running.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Found
	local Deadline = os.clock() + 30
	while (os.clock() < Deadline and not Found) do
		for _, Node in ipairs(Client.Discover(2) or {}) do
			if (Node.Hostname == "wizard") then Found = Node end
		end
	end
	T.Check("setup: wizard finishes and the server starts", Found ~= nil)
end)
