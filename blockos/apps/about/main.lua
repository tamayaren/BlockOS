-- About BlockOS: version and hardware summary.

local Ui = BlockOS.Require("ui")
local Gfx = BlockOS.Require("gfx")
local Logo = BlockOS.Require("logo")
local Config = BlockOS.Require("config")

local Page = Ui.Page.new()

local function Facts()
	local Free = fs.getFreeSpace("/")
	local Capacity = fs.getCapacity and fs.getCapacity("/")
	return {
		{ "Version", Config.Version() },
		{ "Computer", (os.getComputerLabel() or "Unnamed") .. " #" .. os.getComputerID() },
		{ "Host", _HOST or os.version() },
		{ "Storage", Gfx.FormatSize(Free) .. " free" .. (Capacity and (" of " .. Gfx.FormatSize(Capacity)) or "") },
		{ "Type", (turtle and "Turtle" or (pocket and "Pocket" or "Computer")) .. (term.isColor() and " (Advanced)" or "") }
	}
end

function Page:OnLayout(W, H)
	self:Clear()
	self:Add(Ui.Button.new({
		X = math.floor((W - 20) / 2) + 1, Y = H - 1, W = 20, Text = "Software Update...", Style = "primary",
		OnClick = function() BlockOS.Launch("settings", { "update" }) end
	}))
end

function Page:OnDraw(T, Th)
	local LogoW, LogoH = Logo.Size(Logo.Small)
	Logo.Draw(T, math.floor((self.W - LogoW) / 2) + 1, 2, Logo.Small)
	Gfx.Center(T, LogoH + 3, "BlockOS", Th.Text, Th.WindowBg)
	local Y = LogoH + 5
	for _, Fact in ipairs(Facts()) do
		if (Y >= self.H - 1) then break end
		Gfx.Write(T, 2, Y, Gfx.Pad(Fact[1], 9, "right"), Th.SubText, Th.WindowBg)
		Gfx.Write(T, 12, Y, Gfx.Truncate(Fact[2], self.W - 12), Th.Text, Th.WindowBg)
		Y = Y + 1
	end
end

Page:Run()
