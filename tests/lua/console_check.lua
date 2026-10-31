-- Pairs with a GUI server so the console has a pending request to show, then waits while the
-- harness clicks through the console. The run prints the server's final screen.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	sleep(3)
	local Nodes = Client.Discover(2)
	T.Check("console: GUI server discoverable", Nodes and #Nodes == 1)
	local Session = Client.StartPairing(Nodes[1], "Office PC")
	T.Check("console: pairing request sent", Session ~= nil)
	sleep(16)
	local Status = Client.Request(1, "core", "ping", {})
	T.Check("console: services still answer while the GUI is used", Status and Status.Node.Hostname == "datacenter")
end)
