-- Colour roles for light and dark appearance, resolved from settings on each call.

local Config = BlockOS.Require("config")

local Theme = {}

local Palettes = {
	light = {
		TopbarBg = colors.white,
		TopbarFg = colors.black,
		TopbarDim = colors.gray,
		DockBg = colors.lightGray,
		DockFg = colors.gray,
		WindowBg = colors.white,
		Panel = colors.lightGray,
		PanelFg = colors.black,
		Text = colors.black,
		SubText = colors.gray,
		Border = colors.lightGray,
		TitleBg = colors.lightGray,
		TitleFg = colors.black,
		TitleIdleBg = colors.lightGray,
		TitleIdleFg = colors.gray,
		InputBg = colors.lightGray,
		InputFg = colors.black,
		ButtonBg = colors.lightGray,
		ButtonFg = colors.black,
		MenuBg = colors.white,
		MenuFg = colors.black,
		MenuDim = colors.lightGray,
		Shadow = colors.gray,
		Dark = false
	},
	dark = {
		TopbarBg = colors.gray,
		TopbarFg = colors.white,
		TopbarDim = colors.lightGray,
		DockBg = colors.gray,
		DockFg = colors.lightGray,
		WindowBg = colors.black,
		Panel = colors.gray,
		PanelFg = colors.white,
		Text = colors.white,
		SubText = colors.lightGray,
		Border = colors.gray,
		TitleBg = colors.gray,
		TitleFg = colors.white,
		TitleIdleBg = colors.gray,
		TitleIdleFg = colors.lightGray,
		InputBg = colors.gray,
		InputFg = colors.white,
		ButtonBg = colors.gray,
		ButtonFg = colors.white,
		MenuBg = colors.gray,
		MenuFg = colors.white,
		MenuDim = colors.lightGray,
		Shadow = colors.black,
		Dark = true
	}
}

Theme.Accents = {
	colors.blue, colors.purple, colors.magenta, colors.red,
	colors.orange, colors.yellow, colors.green, colors.cyan
}

function Theme.Get()
	local Settings = Config.Settings()
	local Base = Palettes[Settings.Theme] or Palettes.light
	local Result = {}
	for Key, Value in pairs(Base) do
		Result[Key] = Value
	end
	Result.Accent = Settings.Accent or colors.blue
	Result.AccentFg = colors.white
	if (Result.Accent == colors.yellow or Result.Accent == colors.cyan) then
		Result.AccentFg = colors.black
	end
	Result.Close = colors.red
	Result.Minimize = colors.yellow
	Result.Zoom = colors.lime
	return Result
end

return Theme
