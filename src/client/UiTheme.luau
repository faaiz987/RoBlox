--!strict
--[[
	UiTheme
	-------
	One palette, so the title screen, the credits panel and every options modal
	paint the same game. The modal itself takes its theme as an argument (see
	OptionsMenu.create), which is exactly why the colours live in a module: a
	second host -- the mid-run options overlay -- must be able to build the same
	panel without copying hex codes, and a palette change must land in both.

	Structural shape matches `OptionsMenu.Theme`.
]]

local UiTheme = {
	Backdrop = Color3.fromRGB(6, 7, 11),
	Panel = Color3.fromRGB(20, 22, 30),
	PanelLight = Color3.fromRGB(34, 37, 48),

	-- The options modal's own surface ramp, lightest at the top of the stack: a
	-- panel that reads as a window (Surface), cards laid on it (Row), the bind
	-- buttons on those (Chip). The three are far enough apart in value that every
	-- layer is legible on a screen that is already dimmed by the scrim -- painting
	-- all of them near-black is what made the modal look like one gray slab.
	Surface = Color3.fromRGB(46, 52, 68),
	Row = Color3.fromRGB(66, 74, 96),
	Chip = Color3.fromRGB(92, 103, 132),
	RowStroke = Color3.fromRGB(120, 132, 162),

	Ink = Color3.fromRGB(236, 240, 247),
	Muted = Color3.fromRGB(150, 158, 174),
	Accent = Color3.fromRGB(255, 214, 108),
	Danger = Color3.fromRGB(255, 128, 118),
	Stroke = Color3.fromRGB(74, 80, 96),
	Slash = Color3.fromRGB(228, 236, 245),
	Parry = Color3.fromRGB(255, 214, 108),
	Dodge = Color3.fromRGB(160, 214, 255),
}

return UiTheme
