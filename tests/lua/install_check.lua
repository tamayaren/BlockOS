-- Checks freshly installed servers from the network: each must boot Server Edition on its own,
-- announce itself and answer, without any test code installed on it.
local T = dofile("/tests/testlib.lua")
local Versions = dofile("/tests/versions.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Expected = { rack1 = 1, converted = 2, updated = 3 }
	local Found = {}
	local Deadline = os.clock() + 40
	while (os.clock() < Deadline) do
		for _, Node in ipairs(Client.Discover(2) or {}) do Found[Node.Hostname] = Node end
		if (Found.rack1 and Found.converted and Found.updated) then break end
	end
	for Name, ID in pairs(Expected) do
		local Node = Found[Name]
		T.Check("install: " .. Name .. " boots Server Edition and announces", Node and Node.ComputerID == ID and Node.Version == Versions.Server,
			Node and (Node.ComputerID .. " " .. Node.Version) or "not found")
	end
	local Ping = Found.rack1 and Client.Request(Found.rack1.ComputerID, "core", "ping", {})
	T.Check("install: services answer", Ping and Ping.Node.Hostname == "rack1")
	local Pair = Found.converted and Client.StartPairing(Found.converted, "Checker")
	T.Check("install: converted server accepts pairing", Pair ~= nil)
end)
