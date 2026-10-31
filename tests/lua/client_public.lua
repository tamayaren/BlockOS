-- A public server, as set up by default: computers use BlockDrive without pairing.
local T = dofile("/tests/testlib.lua")

T.Run(function()
	local Client = BlockOS.Require("cloud/client")
	local Drive = BlockOS.Require("cloud/drive")
	sleep(3)
	local Nodes = Client.Discover(2)
	local Node, Old
	for _, Found in ipairs(Nodes or {}) do
		if (Found.Hostname == "datacenter") then Node = Found end
		if (Found.Hostname == "oldserver") then Old = Found end
	end
	T.Check("public: new servers are public with read and write for visitors", Node and Node.Public == true and Node.Visitors == "write")
	T.Check("public: a server that already had paired computers stays private after updating", Old and Old.Public == false)

	local Server, Err = Client.Connect(Node)
	T.Check("public: connect without pairing", Server and Server.Permission == "write" and Server.Key == nil, T.Describe(Err))
	T.Check("public: visitor uploads", Drive.WriteText(Server, "Shared/hello.txt", "from a visitor") ~= nil)
	T.Check("public: visitor reads", Drive.ReadText(Server, "Shared/hello.txt") == "from a visitor")
	T.Check("public: visitor manages files", Drive.MakeDir(Server, "Shared/docs") ~= nil
		and Drive.Move(Server, "Shared/hello.txt", "Shared/docs/hello.txt") ~= nil)
	local R, E = Drive.List(Server, "../../blockos")
	T.ExpectError("public: visitors are still confined to the storage", "invalid_path", R, E)

	T.Admin(1, { Op = "set", Key = "Visitors", Value = "read" })
	local Hello = Client.Hello(Server)
	T.Check("public: read-only visitors", Hello and Hello.Permission == "read")
	R, E = Drive.WriteText(Server, "Shared/nope.txt", "x")
	T.ExpectError("public: read-only visitors cannot upload", "denied", R, E)
	T.Check("public: read-only visitors can read", Drive.ReadText(Server, "Shared/docs/hello.txt") == "from a visitor")

	-- Pairing still works on a public server and gives this computer its own permission.
	local Session = Client.StartPairing(Node, "Office")
	local Approval = T.Admin(1, { Op = "approve", Code = Session.Code, Permission = "write" })
	local Paired = Client.WaitPairing(Session, nil, 20)
	T.Check("public: optional pairing", Approval and Approval.Ok and Paired and Paired.Key ~= nil)
	T.Check("public: paired computer writes while visitors may only read", Drive.WriteText(Paired, "Shared/paired.txt", "signed") ~= nil)

	T.Admin(1, { Op = "set", Key = "Public", Value = false })
	R, E = Client.Request(1, "blockdrive", "list", { Path = "" })
	T.ExpectError("public: turning it private shuts visitors out", "not_paired", R, E)
	T.Check("public: paired computer unaffected", Drive.ReadText(Paired, "Shared/paired.txt") == "signed")
	T.Admin(1, { Op = "set", Key = "Public", Value = true })
	T.Admin(1, { Op = "set", Key = "Visitors", Value = "write" })
	-- Let the desktop computer run its GUI test against the public server.
	sleep(25)
end)
