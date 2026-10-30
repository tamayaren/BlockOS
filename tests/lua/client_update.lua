-- Software Update for Server Edition against a local test channel: server 1 follows a channel
-- with the next release and must install it, restart and keep its data; server 3 follows a
-- channel that serves a desktop manifest and must refuse it.
local T = dofile("/tests/testlib.lua")
local Versions = dofile("/tests/versions.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	sleep(3)
	local Before = T.Admin(1, { Op = "inspect" })
	T.Check("update: starts on " .. Versions.Server, Before and Before.Version == Versions.Server, Before and Before.Version)
	T.Admin(1, { Op = "update" })
	T.Admin(3, { Op = "update" })
	-- Server 1 installs, then restarts by itself about 10 seconds later. The update replaces
	-- startup.lua (removing this test's helper), so tests/run.py checks its disk afterwards.
	local Version
	local Deadline = os.clock() + 60
	while (os.clock() < Deadline and Version ~= Versions.Next) do
		sleep(3)
		local Ping = Client.Request(1, "core", "ping", {}, { Retries = 0 })
		Version = Ping and Ping.Node.Version
	end
	T.Check("update: answers as " .. Versions.Next, Version == Versions.Next, Version)
	sleep(15)
	local Other = T.Admin(3, { Op = "inspect" })
	T.Check("update: desktop manifest refused", Other and Other.Version == Versions.Server and Other.Log:find("not this edition", 1, true) ~= nil)
end)
