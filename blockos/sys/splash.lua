-- Boot screen: the logo on black with a progress bar that fills over one to two seconds.

local Gfx = BlockOS.Require("gfx")
local Logo = BlockOS.Require("logo")

local Splash = {}

function Splash.Run(T)
	T = T or term.current()
	Gfx.SetFade(T, 1)
	local W, H = T.getSize()
	local Art = (W >= 20 and H >= 12) and Logo.Big or Logo.Small
	local LogoW, LogoH = Logo.Size(Art)
	local BarW = math.min(20, W - 6)
	local BarX = math.floor((W - BarW) / 2) + 1
	local LogoY = math.max(1, math.floor((H - LogoH - 3) / 2))
	local BarY = math.min(H, LogoY + LogoH + 2)
	T.setBackgroundColor(colors.black)
	T.clear()
	T.setCursorBlink(false)
	Logo.Draw(T, math.floor((W - LogoW) / 2) + 1, LogoY, Art)

	local Duration = 1 + math.random()
	local Started = os.clock()
	-- A few uneven pauses make the bar feel like it is really loading.
	local Stalls = { math.random() * .6 + .1, math.random() * .5 + .4 }
	while (true) do
		local Progress = math.min(1, (os.clock() - Started) / Duration)
		local Shown = Progress
		for _, Stall in ipairs(Stalls) do
			if (Progress > Stall and Progress < Stall + .08) then Shown = Stall end
		end
		local Filled = math.floor(BarW * Shown + .5)
		Gfx.Write(T, BarX, BarY, string.rep(" ", Filled), colors.white, colors.white)
		Gfx.Write(T, BarX + Filled, BarY, string.rep(" ", BarW - Filled), colors.gray, colors.gray)
		if (Progress >= 1) then break end
		sleep(.05)
	end
	sleep(.2)
	for Step = 4, 0, -1 do
		Gfx.SetFade(T, Step / 5)
		sleep(.05)
	end
	T.setBackgroundColor(colors.black)
	T.clear()
end

return Splash
