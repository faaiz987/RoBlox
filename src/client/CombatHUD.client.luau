--!strict
--[[
	CombatHUD (LocalScript)
	-----------------------
	A clean, always-on readout of the controls and their cooldowns:

		[LMB]        Slash Combo
		[F]          Parry / Block (0.2s Window)
		[Shift / Q]  Dodge Dash

	The key chips show the player's live binds (KeybindManager), so a rebind in the
	options menu lands here the moment it is made instead of going stale.

	Parry and Dodge dim with a shrinking bar + countdown while they recharge,
	driven by the client-local `CB_ParryReadyAt` / `CB_DodgeReadyAt` attributes
	that CombatController writes on use. Attack has no cooldown, so its badge is
	static.

	Rebuilt purely from code -- no Studio instances required -- and placed
	bottom-centre so it never fights the mobile control buttons.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local KeybindManager = require(Shared:WaitForChild("KeybindManager"))

local ATTR = CombatConfig.Attributes
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local PALETTE = {
	Panel = Color3.fromRGB(16, 18, 24),
	Stroke = Color3.fromRGB(74, 80, 96),
	Ink = Color3.fromRGB(236, 240, 247),
	Muted = Color3.fromRGB(150, 158, 174),
	Cooldown = Color3.fromRGB(255, 128, 118),
	Slash = Color3.fromRGB(228, 236, 245),
	Parry = Color3.fromRGB(255, 214, 108),
	Dodge = Color3.fromRGB(160, 214, 255),
}

type BadgeKind = "attack" | "parry" | "dodge"

type Badge = {
	kind: BadgeKind,
	root: Frame,
	key: TextLabel,
	title: TextLabel,
	subtitle: TextLabel,
	fill: Frame?,
	baseSubtitle: string,
	accent: Color3,
	-- Absolute os.clock() time the action is ready again (0 = ready now).
	readyAt: number,
	duration: number,
}

-- ---------------------------------------------------------------------------
-- Root layout
-- ---------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "CombatHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 15
gui.Parent = playerGui

local bar = Instance.new("Frame")
bar.Name = "Controls"
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.new(0.5, 0, 1, -18)
bar.AutomaticSize = Enum.AutomaticSize.X
bar.Size = UDim2.fromOffset(0, 58)
bar.BackgroundTransparency = 1
bar.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
layout.Padding = UDim.new(0, 10)
layout.Parent = bar

-- ---------------------------------------------------------------------------
-- Helpers
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

local function attrNumber(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

-- ---------------------------------------------------------------------------
-- Badge factory
-- ---------------------------------------------------------------------------

local badges: { Badge } = {}

local function newBadge(kind: BadgeKind, keyText: string, titleText: string, subtitleText: string, accent: Color3): Badge
	local root = Instance.new("Frame")
	root.Name = `Badge_{kind}`
	root.Size = UDim2.fromOffset(184, 58)
	root.BackgroundColor3 = PALETTE.Panel
	root.BackgroundTransparency = 0.15
	root.BorderSizePixel = 0
	root.Parent = bar
	corner(root, 10)
	stroke(root, PALETTE.Stroke, 1, 0.45)

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 34, 44)),
		ColorSequenceKeypoint.new(1, PALETTE.Panel),
	})
	gradient.Parent = root

	local chip = Instance.new("Frame")
	chip.Name = "Key"
	chip.Position = UDim2.fromOffset(8, 11)
	chip.Size = UDim2.fromOffset(48, 36)
	chip.BackgroundColor3 = Color3.fromRGB(10, 11, 15)
	chip.BackgroundTransparency = 0.1
	chip.BorderSizePixel = 0
	chip.Parent = root
	corner(chip, 8)
	stroke(chip, accent, 1, 0.35)

	local key = Instance.new("TextLabel")
	key.Name = "Glyph"
	key.Size = UDim2.fromScale(1, 1)
	key.BackgroundTransparency = 1
	key.Font = Enum.Font.GothamBold
	key.TextScaled = true
	key.TextColor3 = accent
	key.Text = keyText
	key.Parent = chip

	local textWidth = 184 - 48 - 24
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(64, 11)
	title.Size = UDim2.fromOffset(textWidth, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = PALETTE.Ink
	title.Text = titleText
	title.Parent = root

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromOffset(64, 30)
	subtitle.Size = UDim2.fromOffset(textWidth, 16)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextColor3 = PALETTE.Muted
	subtitle.Text = subtitleText
	subtitle.Parent = root

	local fill: Frame? = nil
	if kind ~= "attack" then
		local track = Instance.new("Frame")
		track.Name = "CooldownTrack"
		track.Position = UDim2.fromOffset(8, 51)
		track.Size = UDim2.new(1, -16, 0, 4)
		track.BackgroundColor3 = Color3.fromRGB(8, 9, 12)
		track.BackgroundTransparency = 0.2
		track.BorderSizePixel = 0
		track.Parent = root
		corner(track, 3)

		local fillFrame = Instance.new("Frame")
		fillFrame.Name = "CooldownFill"
		fillFrame.AnchorPoint = Vector2.new(0, 0.5)
		fillFrame.Position = UDim2.fromScale(0, 0.5)
		fillFrame.Size = UDim2.fromScale(1, 1)
		fillFrame.BackgroundColor3 = accent
		fillFrame.BorderSizePixel = 0
		fillFrame.Parent = track
		corner(fillFrame, 3)
		fill = fillFrame
	end

	local badge: Badge = {
		kind = kind,
		root = root,
		key = key,
		title = title,
		subtitle = subtitle,
		fill = fill,
		baseSubtitle = subtitleText,
		accent = accent,
		readyAt = 0,
		duration = 1,
	}
	table.insert(badges, badge)
	return badge
end

newBadge("attack", "LMB", "Slash Combo", "3-hit stance combo", PALETTE.Slash)
newBadge("parry", "F", "Parry / Block", "0.2s Window", PALETTE.Parry)
newBadge("dodge", "Shift/Q", "Dodge Dash", "Directional i-frames", PALETTE.Dodge)

-- ---------------------------------------------------------------------------
-- Live key glyphs
--   The binds are KeybindManager's to own: a rebind in the options menu has to
--   show up here without a relog, so the chips are painted from the manager and
--   repainted whenever a bind changes.
-- ---------------------------------------------------------------------------

-- The shared store's own action names, so a badge's action flows into
-- KeybindManager without a cast.
type ActionName = KeybindManager.ActionName

local GLYPH_ACTION: { [BadgeKind]: ActionName } = {
	attack = "Attack",
	parry = "Parry",
	dodge = "Dodge",
}

local function syncBindLabels()
	for _, badge in badges do
		-- Annotated, not inferred: Luau widens a singleton union in an inferred local.
		local action: ActionName? = GLYPH_ACTION[badge.kind]
		if action then
			badge.key.Text = KeybindManager:ShortLabel(action)
		end
	end
end

syncBindLabels()
KeybindManager.OnBindChanged.Event:Connect(syncBindLabels)

-- ---------------------------------------------------------------------------
-- Live cooldown readout
-- ---------------------------------------------------------------------------

local function badgeById(kind: BadgeKind): Badge?
	for _, badge in badges do
		if badge.kind == kind then
			return badge
		end
	end
	return nil
end

local parryBadge = badgeById("parry")
local dodgeBadge = badgeById("dodge")

-- Pull the client-local ready timestamps (written by CombatController on use).
local function syncReadyTimes()
	if parryBadge then
		parryBadge.readyAt = attrNumber(ATTR.ParryReadyAt, 0)
		parryBadge.duration = math.max(attrNumber(ATTR.ParryCooldown, CombatConfig.Timings.ParryCooldown), 0.05)
	end
	if dodgeBadge then
		dodgeBadge.readyAt = attrNumber(ATTR.DodgeReadyAt, 0)
		dodgeBadge.duration = math.max(attrNumber(ATTR.DodgeCooldown, CombatConfig.Timings.DodgeCooldown), 0.05)
	end
end

local function renderBadge(badge: Badge)
	if badge.kind == "attack" then
		return
	end

	local remaining = math.max(0, badge.readyAt - os.clock())
	local ratio = math.clamp(remaining / badge.duration, 0, 1)
	local cooling = remaining > 0.05

	if badge.fill then
		badge.fill.Size = UDim2.fromScale(ratio, 1)
		badge.fill.BackgroundColor3 = PALETTE.Cooldown
	end

	-- Dim the badge while it recharges, then snap back the instant it is ready.
	local dim = 0.4 * ratio
	badge.root.BackgroundTransparency = 0.15 + 0.35 * ratio
	badge.key.TextTransparency = dim
	badge.title.TextTransparency = dim
	badge.subtitle.TextTransparency = dim

	if cooling then
		badge.subtitle.Text = string.format("Ready in %.1fs", remaining)
		badge.subtitle.TextColor3 = PALETTE.Cooldown
	else
		badge.subtitle.Text = badge.baseSubtitle
		badge.subtitle.TextColor3 = PALETTE.Muted
	end
end

RunService.Heartbeat:Connect(function()
	syncReadyTimes()
	for _, badge in badges do
		renderBadge(badge)
	end
end)

-- React the moment an attribute flips, so the HUD never lags a frame behind.
player:GetAttributeChangedSignal(ATTR.ParryReadyAt):Connect(syncReadyTimes)
player:GetAttributeChangedSignal(ATTR.DodgeReadyAt):Connect(syncReadyTimes)

syncReadyTimes()
for _, badge in badges do
	renderBadge(badge)
end

print("[CombatHUD] Control hints online.")
