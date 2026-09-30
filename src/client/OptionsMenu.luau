--!strict
--[[
	OptionsMenu (ModuleScript)
	--------------------------
	The options modal behind [ OPTIONS ] on the main menu: one tab today, "Controls
	/ Keybinds", with a row per combat action and live rebinding.

	Why a ModuleScript and not another LocalScript: only one script can own the
	modal, and MainMenuUI has to open it. Rojo maps a bare `*.luau` to a
	ModuleScript, so `script.Parent.OptionsMenu` is requireable, while a
	`.client.luau` sibling would have become a second LocalScript with no way to
	talk to this one.

	It owns nothing but its own widgets: the bind store, the duplicate rules and the
	display names all live in KeybindManager, so adding a fourth action is one line
	there and one row here -- and `layoutFor` grows the panel to match, so a fifth
	action cannot push a row through the status line.

		modal = OptionsMenu.create(parentGui, THEME, playSound, onVisibilityChanged?)
		modal.open() / modal.close() / modal.isOpen() / modal.isCapturing()

	Two hosts build one of these: MainMenuUI behind [ OPTIONS ] on the title
	screen, and OptionsOverlay mid-run. The optional fourth argument fires the
	instant the modal opens or closes (not when its fade finishes), which is how a
	host claims and gives back the cursor.

	Rebinding: click a bind chip -- or anywhere on its row, which is the same hit
	target wearing a quieter hat -- and the next key or mouse button becomes the
	bind. Escape cancels. A duplicate is refused with a reason instead of silently
	stealing the other action's key.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local KeybindManager = require(Shared:WaitForChild("KeybindManager"))

type Input = Enum.UserInputType | Enum.KeyCode

-- The shared store's own action names, so a row's action flows into
-- KeybindManager without a cast and a fourth action needs no edit here.
type ActionName = KeybindManager.ActionName

export type Theme = {
	Backdrop: Color3,
	Panel: Color3,
	PanelLight: Color3,
	Ink: Color3,
	Muted: Color3,
	Accent: Color3,
	Danger: Color3,
	Stroke: Color3,
	Slash: Color3,
	Parry: Color3,
	Dodge: Color3,
	-- The modal's surface ramp, lightest at the top of the stack (see UiTheme).
	-- Optional on purpose: a host whose theme module is an older revision still
	-- renders a legible panel, falling back to the panel colours it does have --
	-- the same defensive shape as ACTIONS above.
	Surface: Color3?,
	Row: Color3?,
	Chip: Color3?,
	RowStroke: Color3?,
}

export type Modal = {
	root: Frame,
	open: () -> (),
	close: () -> (),
	isOpen: () -> boolean,
	-- True while a row is waiting for the player's next key. A host that binds the
	-- same key it uses to open the panel must stand down while this is true, or
	-- that key could never be bound to an action.
	isCapturing: () -> boolean,
}

type Row = {
	card: Frame,
	chip: TextButton,
	glyph: TextLabel,
	caption: TextLabel,
	outline: UIStroke,
	dot: Frame,
	accent: Color3,
}

local OptionsMenu = {}

local PANEL_W = 620
local PAD = 24

-- Rows, and everything below them ------------------------------------------
local ROW_H = 56
local ROW_GAP = 8
local ROWS_TOP = 122

--[[
	The panel is exactly as tall as its content: the row stack's own height plus a
	fixed ladder of gaps down to the footer hint. Every vertical below the header
	comes from here, so the layout follows the action list instead of a hand-typed
	height that a fourth action would overlap.
]]
local function layoutFor(count: number): {
	panelH: number,
	rowsH: number,
	statusY: number,
	dividerY: number,
	buttonsY: number,
	hintY: number,
}
	local rowsH = count * ROW_H + math.max(count - 1, 0) * ROW_GAP
	local statusY = ROWS_TOP + rowsH + 6
	local dividerY = statusY + 28
	local buttonsY = dividerY + 16
	local hintY = buttonsY + 38
	return {
		panelH = hintY + 28,
		rowsH = rowsH,
		statusY = statusY,
		dividerY = dividerY,
		buttonsY = buttonsY,
		hintY = hintY,
	}
end

-- Fallback keeps the modal renderable if the shared module is ever an older
-- revision than this script.
local FALLBACK_ACTIONS: { ActionName } = { "Attack", "Parry", "Dodge" }

local ACTIONS: { ActionName } = if typeof(KeybindManager.Actions) == "table"
	then KeybindManager.Actions
	else FALLBACK_ACTIONS

-- ---------------------------------------------------------------------------
-- Widget helpers (same idioms as PerkUI / CombatHUD)
-- ---------------------------------------------------------------------------

local function corner(parent: Instance, radius: number): UICorner
	local cornerInstance = Instance.new("UICorner")
	cornerInstance.CornerRadius = UDim.new(0, radius)
	cornerInstance.Parent = parent
	return cornerInstance
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local strokeInstance = Instance.new("UIStroke")
	strokeInstance.Color = color
	strokeInstance.Thickness = thickness
	strokeInstance.Transparency = transparency
	strokeInstance.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	strokeInstance.Parent = parent
	return strokeInstance
end

local function newText(
	parent: Instance,
	name: string,
	position: UDim2,
	size: UDim2,
	font: Enum.Font,
	textSize: number,
	color: Color3
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextSize = textSize
	label.TextColor3 = color
	label.Text = ""
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function ghostButton(
	parent: Instance,
	theme: Theme,
	name: string,
	position: UDim2,
	size: UDim2,
	text: string
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = size
	-- The chips' fill, one step quieter: a secondary button has to read as a
	-- surface on the panel, not as a hole in it.
	button.BackgroundColor3 = theme.Chip or theme.PanelLight
	button.BackgroundTransparency = 0.35
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.TextColor3 = theme.Ink
	button.Text = text
	button.Parent = parent
	corner(button, 8)
	local outline = stroke(button, theme.Stroke, 1, 0.5)

	local base = button.BackgroundTransparency
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundTransparency = base - 0.22 }):Play()
		TweenService:Create(outline, TweenInfo.new(0.12), { Transparency = 0.1 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.16), { BackgroundTransparency = base }):Play()
		TweenService:Create(outline, TweenInfo.new(0.16), { Transparency = 0.5 }):Play()
	end)
	return button
end

-- ---------------------------------------------------------------------------
-- Factory
-- ---------------------------------------------------------------------------

function OptionsMenu.create(
	parent: Instance,
	theme: Theme,
	playSound: ((soundId: string, volume: number, pitch: number) -> ())?,
	onVisibilityChanged: ((open: boolean) -> ())?
): Modal
	local function sound(soundId: string, volume: number, pitch: number)
		if playSound then
			playSound(soundId, volume, pitch)
		end
	end

	-- One size for this host's action list, read everywhere below.
	local layout = layoutFor(#ACTIONS)

	--[[
		The three surfaces of the panel, resolved once: the window, the cards laid
		on it and the bind buttons on those. Each is a clear step above the one
		behind it, because a modal whose every layer is near-black reads as a single
		gray slab -- most of all over a scrim that already dimmed the screen.
	]]
	local surface = theme.Surface or theme.Panel
	local rowFill = theme.Row or theme.PanelLight
	local chipFill = theme.Chip or theme.Panel
	local rowStroke = theme.RowStroke or theme.Stroke

	-- Responsive scale, so the modal still fits a small viewport.
	local root = Instance.new("Frame")
	root.Name = "OptionsModal"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = parent

	local fit = Instance.new("UIScale")
	fit.Parent = root

	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = theme.Backdrop
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	-- Deliberately not `Active`: a click that lands on the scrim must reach
	-- UserInputService unprocessed, or the left mouse button could never be bound.
	scrim.Active = false
	scrim.Parent = root

	-- A CanvasGroup, not a Frame: `GroupTransparency` -- the modal's open/close
	-- fade -- exists only on CanvasGroup. The click catcher lives on `root`,
	-- outside this group, and the panel's own rows and footer fit inside it, so
	-- the group's clipping changes nothing on screen.
	--
	-- The group is the fade mask only; what it fades is the plain Frame below it.
	-- That split is deliberate: a gradient parented to a CanvasGroup tints
	-- everything the group renders, so the sheen has to live on a frame that owns
	-- nothing but its own background.
	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, layout.panelH)
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.GroupTransparency = 1
	panel.Parent = root
	corner(panel, 16)

	--[[
		White on purpose. A UIGradient's colours combine with the fill underneath
		it: painting this frame the ramp's own dark end as well would darken the
		panel twice, which is how it used to end up as one near-black slab. White
		lets the ramp supply the exact colours it names, and it stays opaque, so the
		scrim behind the modal shows through nothing.
	]]
	local surfaceFrame = Instance.new("Frame")
	surfaceFrame.Name = "Surface"
	surfaceFrame.Size = UDim2.fromScale(1, 1)
	surfaceFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	surfaceFrame.BorderSizePixel = 0
	surfaceFrame.Parent = panel
	corner(surfaceFrame, 16)
	stroke(surfaceFrame, rowStroke, 1, 0.45)

	local sheen = Instance.new("UIGradient")
	sheen.Rotation = 90
	sheen.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, surface),
		ColorSequenceKeypoint.new(1, Color3.new(
			surface.R * 0.82,
			surface.G * 0.82,
			surface.B * 0.82
		)),
	})
	sheen.Transparency = NumberSequence.new(0)
	sheen.Parent = surfaceFrame

	local pop = Instance.new("UIScale")
	pop.Scale = 1
	pop.Parent = panel

	-- Header ------------------------------------------------------------------
	local title = newText(
		panel,
		"Title",
		UDim2.fromOffset(PAD, 22),
		UDim2.fromOffset(420, 36),
		Enum.Font.GothamBlack,
		26,
		theme.Ink
	)
	title.Text = "OPTIONS"
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0.55

	local hint = newText(
		panel,
		"Hint",
		UDim2.fromOffset(PANEL_W - PAD - 280, 30),
		UDim2.fromOffset(280, 18),
		Enum.Font.GothamMedium,
		12,
		theme.Muted
	)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Text = "Rebinds apply instantly and last this session"

	-- Tab strip ---------------------------------------------------------------
	local tab = Instance.new("Frame")
	tab.Name = "Tab"
	tab.Position = UDim2.fromOffset(PAD, 64)
	tab.Size = UDim2.fromOffset(196, 28)
	tab.BackgroundColor3 = theme.PanelLight
	tab.BackgroundTransparency = 0.25
	tab.BorderSizePixel = 0
	tab.Parent = panel
	corner(tab, 8)
	stroke(tab, theme.Accent, 1, 0.35)

	local tabLabel = newText(
		tab,
		"TabLabel",
		UDim2.fromScale(0, 0),
		UDim2.fromScale(1, 1),
		Enum.Font.GothamBold,
		12,
		theme.Accent
	)
	tabLabel.TextXAlignment = Enum.TextXAlignment.Center
	tabLabel.TextYAlignment = Enum.TextYAlignment.Center
	tabLabel.Text = "CONTROLS / KEYBINDS"

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromOffset(PAD, 108)
	divider.Size = UDim2.new(1, -PAD * 2, 0, 1)
	divider.BackgroundColor3 = theme.Stroke
	divider.BackgroundTransparency = 0.55
	divider.BorderSizePixel = 0
	divider.Parent = panel

	-- Rows --------------------------------------------------------------------
	local rowsRoot = Instance.new("Frame")
	rowsRoot.Name = "Rows"
	rowsRoot.Position = UDim2.fromOffset(PAD, ROWS_TOP)
	rowsRoot.Size = UDim2.new(1, -PAD * 2, 0, 0)
	rowsRoot.AutomaticSize = Enum.AutomaticSize.Y
	rowsRoot.BackgroundTransparency = 1
	rowsRoot.Parent = panel

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Vertical
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, ROW_GAP)
	rowLayout.Parent = rowsRoot

	local ACCENTS: { [string]: Color3 } = {
		Attack = theme.Slash,
		Parry = theme.Parry,
		Dodge = theme.Dodge,
		-- Near-white on purpose: this row's glyph has to stay legible on the bind
		-- chip behind it, and the muted gray it used to use vanished into it.
		Options = theme.Ink,
	}

	local rows: { [ActionName]: Row } = {}
	-- The action currently waiting for an input, if any.
	local captured: ActionName? = nil

	-- Forward declarations: the chips, the catcher and the input listener all close
	-- over these before their bodies exist below.
	local assign: (ActionName, Input) -> ()
	local cancelCapture: (boolean?) -> ()

	local status = newText(
		panel,
		"Status",
		UDim2.fromOffset(PAD, layout.statusY),
		UDim2.new(1, -PAD * 2, 0, 20),
		Enum.Font.GothamMedium,
		12,
		theme.Muted
	)

	local function setStatus(message: string, isError: boolean)
		status.Text = message
		status.TextColor3 = if isError then theme.Danger else theme.Muted
	end

	-- Iterated by index, never with `in ACTIONS`: generalized iteration widens a
	-- union of string literals to `string`, which is not an ActionName.
	local function refresh()
		for index = 1, #ACTIONS do
			local action: ActionName = ACTIONS[index]
			local row = rows[action]
			if not row then
				continue
			end
			local isCapture = captured == action
			row.glyph.Text = if isCapture then "PRESS A KEY..." else KeybindManager:Label(action)
			row.glyph.TextColor3 = if isCapture then theme.Ink else row.accent
			row.caption.Text = if isCapture then "ESC CANCELS" else "CLICK TO CHANGE"
			row.caption.TextColor3 = if isCapture then theme.Accent else theme.Ink
			row.caption.TextTransparency = if isCapture then 0 else 0.35
			row.chip.BackgroundTransparency = if isCapture then 0 else 0.05
			row.outline.Color = if isCapture then theme.Accent else rowStroke
			row.outline.Transparency = if isCapture then 0.02 else 0.5
			row.dot.BackgroundTransparency = if isCapture then 0 else 0.25
			row.card.BackgroundTransparency = if isCapture then 0.08 else 0.2
		end
	end

	--[[
		The catcher: an invisible click target over the whole modal, live only while
		capturing. It makes "press the left mouse button" a deliberate, unambiguous
		gesture -- the click binds and is swallowed in the same act, so no button
		underneath fires by accident.
	]]
	local catcher = Instance.new("TextButton")
	catcher.Name = "CaptureCatcher"
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.ZIndex = 20
	catcher.Visible = false
	catcher.Parent = root
	catcher.MouseButton1Click:Connect(function()
		-- Annotated, not inferred: Luau widens a singleton union in an inferred local,
		-- so `local action = captured` would arrive here as a plain `string`.
		local action: ActionName? = captured
		if action then
			assign(action, Enum.UserInputType.MouseButton1)
		end
	end)

	--[[
		Arms a capture for one action. Shared by the chip and the row's hit target,
		so both gestures run the same state machine; clicking the armed row again is
		its own cancel, which is why a misclick needs no trip to the status line.
	]]
	local function beginCapture(action: ActionName)
		if captured == action then
			cancelCapture(false)
			return
		end
		sound("rbxasset://sounds/electronicpingshort.wav", 0.16, 1.2)
		captured = action
		catcher.Visible = true
		refresh()
		local display = KeybindManager.DisplayNames[action] or action
		setStatus(`Press any key or mouse button for {display}  ·  ESC cancels`, false)
	end

	for order = 1, #ACTIONS do
		local action: ActionName = ACTIONS[order]
		local accent = ACCENTS[action] or theme.Accent

		local card = Instance.new("Frame")
		card.Name = `Row_{action}`
		card.LayoutOrder = order
		card.Size = UDim2.new(1, 0, 0, ROW_H)
		card.BackgroundColor3 = rowFill
		card.BackgroundTransparency = 0.2
		card.BorderSizePixel = 0
		card.Parent = rowsRoot
		corner(card, 10)
		stroke(card, rowStroke, 1, 0.75)

		--[[
			The row's own hit target, created first so everything painted after it --
			the accent tick, the two labels, the bind chip -- draws above it. A click
			that lands anywhere but the chip still opens the same capture, because
			"click the row to change it" is the gesture a player tries first.
		]]
		local hit = Instance.new("TextButton")
		hit.Name = "RowHit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.Parent = card

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.new(0, 14, 0.5, 0)
		dot.Size = UDim2.fromOffset(4, 22)
		dot.BackgroundColor3 = accent
		dot.BackgroundTransparency = 0.25
		dot.BorderSizePixel = 0
		dot.Parent = card
		corner(dot, 2)

		local nameLabel = newText(
			card,
			"Name",
			UDim2.fromOffset(28, 9),
			UDim2.new(1, -210, 0, 20),
			Enum.Font.GothamBold,
			15,
			theme.Ink
		)
		nameLabel.Text = KeybindManager.DisplayNames[action] or action

		local descLabel = newText(
			card,
			"Description",
			UDim2.fromOffset(28, 29),
			UDim2.new(1, -210, 0, 18),
			Enum.Font.GothamMedium,
			12,
			theme.Muted
		)
		descLabel.Text = KeybindManager.Descriptions[action] or ""

		local chip = Instance.new("TextButton")
		chip.Name = "Bind"
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.Position = UDim2.new(1, -12, 0.5, 0)
		chip.Size = UDim2.fromOffset(160, 36)
		chip.BackgroundColor3 = chipFill
		chip.BackgroundTransparency = 0.05
		chip.BorderSizePixel = 0
		chip.AutoButtonColor = false
		chip.Text = ""
		chip.Parent = card
		corner(chip, 8)
		local outline = stroke(chip, rowStroke, 1, 0.5)

		local chipPad = Instance.new("UIPadding")
		chipPad.PaddingLeft = UDim.new(0, 8)
		chipPad.PaddingRight = UDim.new(0, 8)
		chipPad.Parent = chip

		-- Two lines, because one glyph reads as a label and a label reads as "not
		-- mine to touch": the key on top, what clicking it does underneath.
		local glyph = Instance.new("TextLabel")
		glyph.Name = "Glyph"
		glyph.Position = UDim2.fromOffset(0, 1)
		glyph.Size = UDim2.new(1, 0, 0, 19)
		glyph.BackgroundTransparency = 1
		glyph.Font = Enum.Font.GothamBold
		glyph.TextScaled = true
		glyph.TextColor3 = accent
		glyph.Text = ""
		glyph.Parent = chip

		local caption = Instance.new("TextLabel")
		caption.Name = "Caption"
		caption.Position = UDim2.fromOffset(0, 20)
		caption.Size = UDim2.new(1, 0, 0, 14)
		caption.BackgroundTransparency = 1
		caption.Font = Enum.Font.GothamBold
		caption.TextSize = 10
		-- Ink at a transparency, not the muted gray: this caption is the thing that
		-- tells a player the chip is a button, so it has to survive the chip fill.
		caption.TextColor3 = theme.Ink
		caption.TextTransparency = 0.35
		caption.Text = "CLICK TO CHANGE"
		caption.Parent = chip

		-- One hover state for the whole row: the card lifts and the bind outline takes
		-- the action's colour, whether the mouse arrived over the chip or the row.
		local function hover(on: boolean)
			if captured == action then
				return
			end
			TweenService:Create(card, TweenInfo.new(0.12), { BackgroundTransparency = if on then 0.02 else 0.2 }):Play()
			TweenService:Create(outline, TweenInfo.new(0.12), { Color = if on then accent else rowStroke, Transparency = if on then 0.1 else 0.5 }):Play()
		end

		hit.MouseEnter:Connect(function()
			hover(true)
		end)
		hit.MouseLeave:Connect(function()
			hover(false)
		end)
		hit.Activated:Connect(function()
			beginCapture(action)
		end)
		chip.MouseEnter:Connect(function()
			hover(true)
		end)
		chip.MouseLeave:Connect(function()
			hover(false)
		end)
		chip.Activated:Connect(function()
			beginCapture(action)
		end)

		rows[action] = {
			card = card,
			chip = chip,
			glyph = glyph,
			caption = caption,
			outline = outline,
			dot = dot,
			accent = accent,
		}
	end

	-- Status + footer ---------------------------------------------------------
	status.Text = "Click a bind -- or a whole row -- to change it."

	local footerDivider = Instance.new("Frame")
	footerDivider.Name = "FooterDivider"
	footerDivider.Position = UDim2.fromOffset(PAD, layout.dividerY)
	footerDivider.Size = UDim2.new(1, -PAD * 2, 0, 1)
	footerDivider.BackgroundColor3 = theme.Stroke
	footerDivider.BackgroundTransparency = 0.65
	footerDivider.BorderSizePixel = 0
	footerDivider.Parent = panel

	local restore = ghostButton(
		panel,
		theme,
		"RestoreDefaults",
		UDim2.fromOffset(PAD, layout.buttonsY),
		UDim2.fromOffset(176, 34),
		"RESTORE DEFAULTS"
	)

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Position = UDim2.fromOffset(PANEL_W - PAD - 104, layout.buttonsY)
	closeButton.Size = UDim2.fromOffset(104, 34)
	closeButton.BackgroundColor3 = theme.Accent
	closeButton.BackgroundTransparency = 0
	closeButton.BorderSizePixel = 0
	closeButton.AutoButtonColor = false
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 13
	closeButton.TextColor3 = theme.Backdrop
	closeButton.Text = "CLOSE"
	closeButton.Parent = panel
	corner(closeButton, 8)

	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.12), { BackgroundTransparency = 0.15 }):Play()
	end)
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.16), { BackgroundTransparency = 0 }):Play()
	end)

	local footerHint = newText(
		panel,
		"FooterHint",
		UDim2.fromOffset(PAD, layout.hintY),
		UDim2.new(1, -PAD * 2, 0, 16),
		Enum.Font.GothamMedium,
		11,
		theme.Muted
	)
	footerHint.TextXAlignment = Enum.TextXAlignment.Center
	footerHint.Text = "ESC to close  ·  rebinds are kept for this session"

	-- ---------------------------------------------------------------------------
	-- Rebinding
	-- ---------------------------------------------------------------------------

	function assign(action: ActionName, input: Input)
		local ok, err = KeybindManager:SetBind(action, input)
		if ok then
			captured = nil
			catcher.Visible = false
			refresh()
			local display = KeybindManager.DisplayNames[action] or action
			setStatus(`{display} bound to {KeybindManager:KeyName(input)}.`, false)
			sound("rbxasset://sounds/electronicpingshort.wav", 0.2, 1.45)
		else
			-- Keep capturing: the player is one key away from a valid choice.
			setStatus(err or "That input cannot be bound.", true)
			sound("rbxasset://sounds/electronicpingshort.wav", 0.2, 0.8)
		end
	end

	function cancelCapture(silent: boolean?)
		if not captured then
			return
		end
		captured = nil
		catcher.Visible = false
		refresh()
		if not silent then
			setStatus("Rebinding canceled.", false)
			sound("rbxasset://sounds/electronicpingshort.wav", 0.14, 0.9)
		end
	end

	local closeSerial = 0

	local function open()
		if root.Visible then
			return
		end
		closeSerial += 1
		captured = nil
		catcher.Visible = false
		root.Visible = true
		-- Announced on intent, not on the end of the fade: a host that hands the
		-- cursor over must not wait 0.24s while the panel is already on screen.
		if onVisibilityChanged then
			onVisibilityChanged(true)
		end
		scrim.BackgroundTransparency = 0.72
		panel.GroupTransparency = 1
		panel.Position = UDim2.new(0.5, 0, 0.5, 22)
		pop.Scale = 0.97
		setStatus("Click a bind -- or a whole row -- to change it.", false)
		refresh()

		TweenService:Create(scrim, TweenInfo.new(0.22), { BackgroundTransparency = 0.45 }):Play()
		TweenService:Create(panel, TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
			Position = UDim2.new(0.5, 0, 0.5, 0),
		}):Play()
		TweenService:Create(pop, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end

	local function close()
		if not root.Visible then
			return
		end
		cancelCapture(true)
		if onVisibilityChanged then
			onVisibilityChanged(false)
		end
		closeSerial += 1
		local serial = closeSerial
		TweenService:Create(scrim, TweenInfo.new(0.18), { BackgroundTransparency = 1 }):Play()
		local out = TweenService:Create(panel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			GroupTransparency = 1,
			Position = UDim2.new(0.5, 0, 0.5, 16),
		})
		out.Completed:Connect(function()
			if closeSerial == serial then
				root.Visible = false
			end
		end)
		out:Play()
	end

	-- One listener per modal, and it only acts while the modal is up.
	UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
		if not root.Visible then
			return
		end

		-- Annotated, not inferred: Luau widens a singleton union in an inferred local,
		-- so `local action = captured` would arrive here as a plain `string`.
		local action: ActionName? = captured
		if action then
			if input.KeyCode == Enum.KeyCode.Escape then
				cancelCapture(false)
				return
			end
			-- A key is unambiguous here: the player is explicitly choosing one.
			-- UI-processed keys are still accepted, otherwise a focused button
			-- would make Space and Enter unbindable.
			if input.KeyCode ~= Enum.KeyCode.None then
				assign(action, input.KeyCode)
				return
			end
			-- Left click arrives through the catcher; these two do not.
			if
				input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3
			then
				assign(action, input.UserInputType)
			end
			return
		end

		if input.KeyCode == Enum.KeyCode.Escape then
			close()
		end
	end)

	restore.Activated:Connect(function()
		sound("rbxasset://sounds/electronicpingshort.wav", 0.18, 1.1)
		cancelCapture(true)
		local changed = KeybindManager:RestoreDefaults()
		refresh()
		setStatus((if changed then "Restored the default controls." else "Defaults were already in place."), false)
	end)

	closeButton.Activated:Connect(function()
		sound("rbxasset://sounds/electronicpingshort.wav", 0.16, 0.95)
		close()
	end)

	-- Keep the modal inside small viewports.
	local camera = workspace.CurrentCamera
	local function fitToViewport()
		local viewport = camera.ViewportSize
		fit.Scale = math.clamp(math.min(viewport.X / (PANEL_W + 80), viewport.Y / (layout.panelH + 80)), 0.62, 1)
	end

	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToViewport)
	fitToViewport()
	refresh()

	return {
		root = root,
		open = open,
		close = close,
		isOpen = function(): boolean
			return root.Visible
		end,
		isCapturing = function(): boolean
			return captured ~= nil
		end,
	}
end

return OptionsMenu
