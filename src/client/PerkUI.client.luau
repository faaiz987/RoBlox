--!strict
--[[
	PerkUI (LocalScript)
	--------------------
	The post-wave ritual: three cards, one choice.

	  * `PerkChoice`  -> fades in the card overlay, rolls the cards in with a stagger
	  * card click    -> tells the server, hides the overlay, shows a grant toast
	  * `WaveState`   -> wave banner, enemy counter and intermission countdown
	  * `CB_Perks`    -> the owned-perk chip row (server-confirmed, never optimistic)

	While the overlay is open the client flags `CB_ChoiceOpen` on the local player so
	CombatController refuses attack / parry / dodge input.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local PerkDatabase = require(Shared:WaitForChild("PerkDatabase"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ATTR = CombatConfig.Attributes
local NAMES = Remotes.Names

type Card = {
	id: string,
	title: string,
	description: string,
	flavor: string,
	glyph: string,
	imageId: string,
	rarity: string,
	color: Color3,
}

type ChoicePayload = { wave: number, cards: { Card } }

type WavePayload = {
	phase: string,
	wave: number,
	enemiesRemaining: number,
	enemiesTotal: number,
	endsAt: number?,
	announcement: string?,
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local choiceRemote = Remotes.client(NAMES.PerkChoice)
local grantedRemote = Remotes.client(NAMES.PerkGranted)
local waveRemote = Remotes.client(NAMES.WaveState)

--[[
	The perk-select remote, resolved lazily and re-resolved on every pick.

	`Remotes.client` is authoritative (it waits for replication, then creates a
	placeholder of last resort), but it *errors* when it cannot resolve -- and a card
	click is the worst possible place for an error, because that is the exact click
	that has to hide the overlay. So: try the registry, then the replicated folder by
	name, and hand back nil rather than throwing.
]]
local selectPerkRemote: RemoteEvent? = nil

-- The registry name is "SelectPerk"; earlier builds of the place shipped it as
-- "SelectPerkEvent". Both are accepted so a stale Studio copy still picks perks.
local SELECT_NAMES = { NAMES.SelectPerk, "SelectPerkEvent" }

local function resolveSelectPerk(): RemoteEvent?
	local cached = selectPerkRemote
	if cached and cached.Parent then
		return cached
	end

	local resolved: RemoteEvent? = nil
	local ok = pcall(function()
		resolved = Remotes.client(NAMES.SelectPerk)
	end)

	if not ok or not resolved then
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			folder = ReplicatedStorage:WaitForChild("Remotes", 5)
		end
		if folder then
			for _, name in SELECT_NAMES do
				local found: Instance? = folder:FindFirstChild(name)
				if not found and name == NAMES.SelectPerk then
					found = folder:WaitForChild(name, 5)
				end
				if found and found:IsA("RemoteEvent") then
					resolved = found
					break
				end
			end
		end
	end

	if resolved then
		selectPerkRemote = resolved
	end
	return resolved
end

--[[
	Hands the cursor back and forth between the choice UI and the combat camera.
	`CB_ChoiceOpen` is the contract CombatController reads for its mouse lock, and
the mouse behavior is flipped right here as well, so the very next frame is
	already correct even before that loop ticks.
]]
local function setChoiceCursor(open: boolean)
	player:SetAttribute(ATTR.ChoiceOpen, open)
	UserInputService.MouseBehavior = if open then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
	-- Ignored while the mouse is locked; required the moment it is not.
	UserInputService.MouseIconEnabled = true
end

local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(186, 196, 208),
	Rare = Color3.fromRGB(112, 186, 255),
	Mythic = Color3.fromRGB(255, 206, 96),
}

local PALETTE = {
	Backdrop = Color3.fromRGB(6, 7, 11),
	Panel = Color3.fromRGB(20, 22, 30),
	PanelLight = Color3.fromRGB(34, 37, 48),
	Ink = Color3.fromRGB(236, 240, 247),
	Muted = Color3.fromRGB(150, 158, 174),
	Accent = Color3.fromRGB(255, 214, 108),
	Health = Color3.fromRGB(214, 68, 74),
}

-- ---------------------------------------------------------------------------
-- Root layout
-- ---------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PerkUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui.Parent = playerGui

-- The card overlay lives on its own ScreenGui so a picked perk can hide the
-- whole choice UI with a single `Enabled = false` (the HUD above stays put).
local choiceGui = Instance.new("ScreenGui")
choiceGui.Name = "PerkChoiceGui"
choiceGui.ResetOnSpawn = false
choiceGui.IgnoreGuiInset = true
choiceGui.DisplayOrder = 30
choiceGui.Enabled = false
choiceGui.Parent = playerGui

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

local function newText(parent: Instance, name: string, size: UDim2, font: Enum.Font, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextSize = textSize
	label.TextColor3 = color
	label.Text = ""
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = parent
	return label
end

-- ---------------------------------------------------------------------------
-- HUD: wave banner, enemy counter, perk chips, health
-- ---------------------------------------------------------------------------

local hud = Instance.new("Frame")
hud.Name = "Hud"
hud.BackgroundTransparency = 1
hud.Size = UDim2.fromScale(1, 1)
hud.Parent = gui

local waveLabel = Instance.new("TextLabel")
waveLabel.Name = "WaveLabel"
waveLabel.AnchorPoint = Vector2.new(0.5, 0)
waveLabel.Position = UDim2.new(0.5, 0, 0, 18)
waveLabel.Size = UDim2.fromOffset(520, 42)
waveLabel.BackgroundTransparency = 1
waveLabel.Font = Enum.Font.GothamBlack
waveLabel.TextSize = 30
waveLabel.TextColor3 = PALETTE.Ink
waveLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
waveLabel.TextStrokeTransparency = 0.4
waveLabel.Text = ""
waveLabel.Parent = hud

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.AnchorPoint = Vector2.new(0.5, 0)
statusLabel.Position = UDim2.new(0.5, 0, 0, 58)
statusLabel.Size = UDim2.fromOffset(520, 22)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 16
statusLabel.TextColor3 = PALETTE.Muted
statusLabel.Text = ""
statusLabel.Parent = hud

local announceLabel = Instance.new("TextLabel")
announceLabel.Name = "Announce"
announceLabel.AnchorPoint = Vector2.new(0.5, 0.5)
announceLabel.Position = UDim2.fromScale(0.5, 0.32)
announceLabel.Size = UDim2.fromOffset(900, 90)
announceLabel.BackgroundTransparency = 1
announceLabel.Font = Enum.Font.GothamBlack
announceLabel.TextSize = 64
announceLabel.TextColor3 = PALETTE.Accent
announceLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
announceLabel.TextStrokeTransparency = 0.35
announceLabel.TextTransparency = 1
announceLabel.Text = ""
announceLabel.Parent = hud

local perksBar = Instance.new("Frame")
perksBar.Name = "Perks"
perksBar.AnchorPoint = Vector2.new(0.5, 1)
perksBar.Position = UDim2.new(0.5, 0, 1, -62)
perksBar.Size = UDim2.fromOffset(720, 30)
perksBar.BackgroundTransparency = 1
perksBar.Parent = hud

local perksLayout = Instance.new("UIListLayout")
perksLayout.FillDirection = Enum.FillDirection.Horizontal
perksLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
perksLayout.VerticalAlignment = Enum.VerticalAlignment.Center
perksLayout.Padding = UDim.new(0, 8)
perksLayout.Parent = perksBar

local healthTrack = Instance.new("Frame")
healthTrack.Name = "HealthTrack"
healthTrack.AnchorPoint = Vector2.new(0.5, 1)
healthTrack.Position = UDim2.new(0.5, 0, 1, -26)
healthTrack.Size = UDim2.fromOffset(340, 14)
healthTrack.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
healthTrack.BackgroundTransparency = 0.25
healthTrack.BorderSizePixel = 0
healthTrack.Parent = hud
corner(healthTrack, 7)
stroke(healthTrack, Color3.fromRGB(70, 74, 88), 1, 0.5)

local healthFill = Instance.new("Frame")
healthFill.Name = "Fill"
healthFill.Size = UDim2.fromScale(1, 1)
healthFill.BackgroundColor3 = PALETTE.Health
healthFill.BorderSizePixel = 0
healthFill.Parent = healthTrack
corner(healthFill, 7)

local healthText = Instance.new("TextLabel")
healthText.Name = "Value"
healthText.AnchorPoint = Vector2.new(0.5, 0)
healthText.Position = UDim2.fromScale(0.5, 1)
healthText.Size = UDim2.fromOffset(340, 18)
healthText.BackgroundTransparency = 1
healthText.Font = Enum.Font.GothamBold
healthText.TextSize = 13
healthText.TextColor3 = PALETTE.Muted
healthText.Text = "100 / 100"
healthText.Parent = hud

-- ---------------------------------------------------------------------------
-- Perk choice overlay
-- ---------------------------------------------------------------------------

local overlay = Instance.new("Frame")
overlay.Name = "Choice"
overlay.Size = UDim2.fromScale(1, 1)
overlay.BackgroundColor3 = PALETTE.Backdrop
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Visible = false
overlay.Parent = choiceGui

local overlayGradient = Instance.new("UIGradient")
overlayGradient.Rotation = 90
overlayGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(4, 5, 8)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 20, 34)),
})
overlayGradient.Parent = overlay

local overlayTitle = Instance.new("TextLabel")
overlayTitle.Name = "Title"
overlayTitle.AnchorPoint = Vector2.new(0.5, 0)
overlayTitle.Position = UDim2.new(0.5, 0, 0, 90)
overlayTitle.Size = UDim2.fromOffset(900, 54)
overlayTitle.BackgroundTransparency = 1
overlayTitle.Font = Enum.Font.GothamBlack
overlayTitle.TextSize = 42
overlayTitle.TextColor3 = PALETTE.Accent
overlayTitle.Text = "CHOOSE YOUR PATH"
overlayTitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
overlayTitle.TextStrokeTransparency = 0.5
overlayTitle.Parent = overlay

local overlaySubtitle = Instance.new("TextLabel")
overlaySubtitle.Name = "Subtitle"
overlaySubtitle.AnchorPoint = Vector2.new(0.5, 0)
overlaySubtitle.Position = UDim2.new(0.5, 0, 0, 136)
overlaySubtitle.Size = UDim2.fromOffset(900, 24)
overlaySubtitle.BackgroundTransparency = 1
overlaySubtitle.Font = Enum.Font.GothamMedium
overlaySubtitle.TextSize = 17
overlaySubtitle.TextColor3 = PALETTE.Muted
overlaySubtitle.Text = "Wave cleared. Claim one boon before the next assault."
overlaySubtitle.Parent = overlay

local cardRow = Instance.new("Frame")
cardRow.Name = "Cards"
cardRow.AnchorPoint = Vector2.new(0.5, 0.5)
cardRow.Position = UDim2.fromScale(0.5, 0.56)
cardRow.Size = UDim2.fromOffset(880, 400)
cardRow.BackgroundTransparency = 1
cardRow.Parent = overlay

local cardLayout = Instance.new("UIListLayout")
cardLayout.FillDirection = Enum.FillDirection.Horizontal
cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
cardLayout.VerticalAlignment = Enum.VerticalAlignment.Center
cardLayout.Padding = UDim.new(0, 26)
cardLayout.Parent = cardRow

-- ---------------------------------------------------------------------------
-- Shared UI helpers (declared before any closure that uses them)
-- ---------------------------------------------------------------------------

local function playLocalSound(soundId: string, volume: number, pitch: number)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch
	SoundService:PlayLocalSound(sound)
	task.delay(5, function()
		sound:Destroy()
	end)
end

local announceToken = 0

-- Big centre-screen callout: wave starts, clears and perk grants.
local function announce(text: string, color: Color3)
	announceToken += 1
	local token = announceToken
	announceLabel.Text = text
	announceLabel.TextColor3 = color
	announceLabel.TextTransparency = 1
	TweenService:Create(announceLabel, TweenInfo.new(0.22), { TextTransparency = 0 }):Play()
	task.delay(1.8, function()
		if announceToken ~= token then
			return
		end
		TweenService:Create(announceLabel, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
	end)
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

type CardUi = {
	root: TextButton,
	scale: UIScale,
	strokeInstance: UIStroke,
	accent: Frame,
	glyph: TextLabel,
	icon: ImageLabel,
	title: TextLabel,
	rarity: TextLabel,
	description: TextLabel,
	flavor: TextLabel,
	footer: TextLabel,
	selectedId: string?,
	index: number,
}

--[[
	The selected-card flourish, in one place.
	The click handler is deliberately thin: everything it calls is a local declared
	*above* it, which is what removes the whole class of "attempt to call a nil
	value" failures the card click used to produce.
]]
local function animateCardPick(ui: CardUi, card: Card)
	-- Card data comes from the server, so the palette is validated rather than
	-- trusted: a malformed card may look plain, but it can never throw on click.
	local accent = if typeof(card.color) == "Color3" then card.color else PALETTE.Accent

	TweenService:Create(ui.scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 }):Play()
	TweenService:Create(
		ui.root,
		TweenInfo.new(0.18),
		{ BackgroundColor3 = accent:Lerp(PALETTE.Ink, 0.2) }
	):Play()
	playLocalSound(CombatConfig.Fx.PerkSelect, 0.6, 1.2)
end

local cards: { CardUi } = {}
local choiceOpen = false
local picking = false
local currentCards: { Card } = {}

--[[	Single exit path for the choice overlay.

	It is a *defined* local here -- never a forward declaration, never an assignment
	parked after the card loop -- because the click handler below closes over it, and
	a nil value at that call site is exactly the crash this file used to ship. Hiding
	is instant: a pick must never strand the overlay over the arena.
]]
local function closeChoice(chosen: Card?)
	choiceOpen = false
	picking = false

	-- Cursor back to the combat camera before anything else touches the GUI.
	setChoiceCursor(false)

	-- One switch drops every card and the backdrop, so nothing is left mid-tween on
	-- a hidden ScreenGui and the next wave opens from a clean slate.
	choiceGui.Enabled = false
	overlay.Visible = false
	overlay.BackgroundTransparency = 1

	for _, ui in cards do
		ui.root.Active = false
		ui.root.Selectable = false
		ui.root.Visible = false
		ui.root.BackgroundTransparency = 0
		ui.root.BackgroundColor3 = PALETTE.Panel
		ui.root.Position = UDim2.fromOffset(0, 26)
		ui.scale.Scale = 1
	end

	if chosen then
		local accent = if typeof(chosen.color) == "Color3" then chosen.color else PALETTE.Accent
		-- The HUD lives on its own ScreenGui, so the toast survives the hide.
		announce(`{string.upper(chosen.title)} CLAIMED`, accent)
	end
end

local function buildCard(index: number): CardUi
	local root = Instance.new("TextButton")
	root.Name = `Card{index}`
	root.Size = UDim2.fromOffset(250, 360)
	root.BackgroundColor3 = PALETTE.Panel
	root.AutoButtonColor = false
	root.Text = ""
	root.Position = UDim2.fromOffset(0, 26)
	root.Parent = cardRow
	corner(root, 16)
	local cardStroke = stroke(root, Color3.fromRGB(60, 66, 82), 1.5, 0.35)

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, PALETTE.PanelLight),
		ColorSequenceKeypoint.new(1, PALETTE.Panel),
	})
	gradient.Parent = root

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(1, 0, 0, 4)
	accent.BackgroundColor3 = PALETTE.Accent
	accent.BorderSizePixel = 0
	accent.Parent = root

	local glyph = newText(root, "Glyph", UDim2.fromOffset(250, 74), Enum.Font.GothamBlack, 54, PALETTE.Ink)
	glyph.Position = UDim2.fromOffset(0, 24)
	glyph.TextXAlignment = Enum.TextXAlignment.Center

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Position = UDim2.fromOffset(95, 26)
	icon.Size = UDim2.fromOffset(60, 60)
	icon.Image = ""
	icon.Visible = false
	icon.Parent = root

	local title = newText(root, "Title", UDim2.new(1, -28, 0, 30), Enum.Font.GothamBold, 21, PALETTE.Ink)
	title.Position = UDim2.fromOffset(14, 100)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextWrapped = true

	local rarity = newText(root, "Rarity", UDim2.new(1, -28, 0, 18), Enum.Font.GothamBold, 12, PALETTE.Muted)
	rarity.Position = UDim2.fromOffset(14, 132)
	rarity.TextXAlignment = Enum.TextXAlignment.Center

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromOffset(60, 160)
	divider.Size = UDim2.new(1, -120, 0, 1)
	divider.BackgroundColor3 = Color3.fromRGB(72, 78, 94)
	divider.BackgroundTransparency = 0.4
	divider.BorderSizePixel = 0
	divider.Parent = root

	local description = newText(root, "Description", UDim2.new(1, -36, 0, 110), Enum.Font.GothamMedium, 15, PALETTE.Ink)
	description.Position = UDim2.fromOffset(18, 174)
	description.TextXAlignment = Enum.TextXAlignment.Center
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.TextWrapped = true

	local flavor = newText(root, "Flavor", UDim2.new(1, -36, 0, 60), Enum.Font.GothamMedium, 13, PALETTE.Muted)
	flavor.Position = UDim2.fromOffset(18, 274)
	flavor.TextXAlignment = Enum.TextXAlignment.Center
	flavor.TextYAlignment = Enum.TextYAlignment.Top
	flavor.TextWrapped = true

	local footer = newText(root, "Footer", UDim2.new(1, -28, 0, 20), Enum.Font.GothamBold, 13, PALETTE.Accent)
	footer.Position = UDim2.fromOffset(14, 330)
	footer.TextXAlignment = Enum.TextXAlignment.Center
	footer.Text = "SELECT"

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = root

	local ui: CardUi = {
		root = root,
		scale = scale,
		strokeInstance = cardStroke,
		accent = accent,
		glyph = glyph,
		icon = icon,
		title = title,
		rarity = rarity,
		description = description,
		flavor = flavor,
		footer = footer,
		selectedId = nil,
		index = index,
	}

	root.MouseEnter:Connect(function()
		if picking then
			return
		end
		TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Scale = 1.05 }):Play()
		TweenService:Create(root, TweenInfo.new(0.18), { Position = UDim2.fromOffset(0, 16) }):Play()
		cardStroke.Transparency = 0
	end)

	root.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(root, TweenInfo.new(0.18), { Position = UDim2.fromOffset(0, 26) }):Play()
		cardStroke.Transparency = 0.35
	end)

	-- Activated fires for both mouse and touch, unlike MouseButton1Click.
	root.Activated:Connect(function()
		if picking or not choiceOpen then
			return
		end
		local card = currentCards[index]
		if not card then
			return
		end
		picking = true

		-- Kill duplicate triggers immediately: a double-tap must not send two picks.
		for _, other in cards do
			other.root.Active = false
			other.root.Selectable = false
		end

		--[[
			The pick, in three guarded beats:
			  1. local feedback (sound + card pop) -- every target is a local defined above
			  2. server intent -- a missing remote warns instead of taking the click down
			  3. instant teardown + cursor handback, which runs even if 1 or 2 blew up
		]]
		local ok, err = pcall(function()
			animateCardPick(ui, card)

			local remote = resolveSelectPerk()
			if remote then
				remote:FireServer(card.id)
			else
				warn("[PerkUI] SelectPerk remote unavailable; the perk was not sent to the server.")
			end
		end)
		if not ok then
			warn(`[PerkUI] card pick failed: {err}`)
		end

		-- Unconditional: the overlay must never survive a click.
		closeChoice(card)
	end)

	return ui
end

for index = 1, 3 do
	table.insert(cards, buildCard(index))
end

-- ---------------------------------------------------------------------------
-- Choice lifecycle
-- ---------------------------------------------------------------------------

local function openChoice(payload: ChoicePayload)
	currentCards = payload.cards
	choiceOpen = true
	picking = false
	-- Frees the cursor for the cards and tells the camera to stop mouse-looking.
	setChoiceCursor(true)

	overlaySubtitle.Text = `Wave {payload.wave} cleared. Claim one boon before the next assault.`
	choiceGui.Enabled = true
	overlay.Visible = true
	overlay.BackgroundTransparency = 0.08

	for index, ui in cards do
		local card = payload.cards[index]
		if card then
			ui.selectedId = card.id
			ui.root.Visible = true
			ui.root.Active = true
			ui.root.Selectable = true
			ui.root.BackgroundColor3 = PALETTE.Panel
			ui.title.Text = card.title
			ui.rarity.Text = string.upper(card.rarity)
			ui.rarity.TextColor3 = RARITY_COLORS[card.rarity] or PALETTE.Muted
			ui.description.Text = card.description
			ui.flavor.Text = card.flavor
			ui.accent.BackgroundColor3 = card.color
			ui.strokeInstance.Color = card.color
			ui.strokeInstance.Transparency = 0.45
			ui.glyph.TextColor3 = card.color

			if card.imageId ~= "" then
				ui.icon.Image = card.imageId
				ui.icon.Visible = true
				ui.glyph.Visible = false
			else
				ui.icon.Visible = false
				ui.glyph.Visible = true
				ui.glyph.Text = card.glyph
			end

			ui.scale.Scale = 0.7
			ui.root.Position = UDim2.fromOffset(0, 44)
			TweenService:Create(ui.scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		else
			ui.root.Visible = false
		end
	end

	-- Staggered rise so the three options read one after another.
	for index, ui in cards do
		task.delay((index - 1) * 0.08, function()
			if choiceOpen then
				TweenService:Create(ui.root, TweenInfo.new(0.32, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
					Position = UDim2.fromOffset(0, 26),
				}):Play()
			end
		end)
	end

	playLocalSound(CombatConfig.Fx.WaveClear, 0.5, 1.1)
end

choiceRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: ChoicePayload
	if typeof(data.cards) ~= "table" or #data.cards == 0 then
		return
	end
	openChoice(data)
end)

grantedRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: { perk: { title: string }? }
	local perk = data.perk
	if perk and perk.title then
		announce(`{string.upper(perk.title)} ACQUIRED`, PALETTE.Accent)
	end
end)

-- ---------------------------------------------------------------------------
-- HUD updates
-- ---------------------------------------------------------------------------

local chipsByName: { [string]: Frame } = {}

local function renderPerkChips()
	for _, chip in chipsByName do
		chip:Destroy()
	end
	table.clear(chipsByName)

	for _, id in PerkDatabase.decode(player:GetAttribute(ATTR.Perks) :: string?) do
		local perk = PerkDatabase.get(id)
		if perk then
			local chip = Instance.new("Frame")
			chip.Name = perk.id
			chip.Size = UDim2.fromOffset(150, 28)
			chip.BackgroundColor3 = PALETTE.Panel
			chip.BackgroundTransparency = 0.15
			chip.BorderSizePixel = 0
			chip.Parent = perksBar
			corner(chip, 8)
			stroke(chip, perk.color, 1, 0.35)

			local glyph = newText(chip, "Glyph", UDim2.fromOffset(24, 28), Enum.Font.GothamBold, 15, perk.color)
			glyph.Position = UDim2.fromOffset(8, 0)
			glyph.TextXAlignment = Enum.TextXAlignment.Center
			glyph.TextYAlignment = Enum.TextYAlignment.Center
			glyph.Text = perk.glyph

			local label = newText(chip, "Name", UDim2.new(1, -34, 1, 0), Enum.Font.GothamBold, 12, PALETTE.Ink)
			label.Position = UDim2.fromOffset(30, 0)
			label.TextYAlignment = Enum.TextYAlignment.Center
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Text = string.upper(perk.title)

			chipsByName[perk.id] = chip
		end
	end
end

local wavePayload: WavePayload? = nil

local function renderStatus()
	local payload = wavePayload
	if not payload then
		return
	end

	if payload.phase == "PerkChoice" then
		waveLabel.Text = `WAVE {payload.wave} CLEARED`
		statusLabel.Text = "Choose a perk to continue"
	elseif payload.phase == "Wave" then
		waveLabel.Text = `WAVE {payload.wave}`
		statusLabel.Text = `ENEMIES {payload.enemiesRemaining} / {payload.enemiesTotal}`
	else
		waveLabel.Text = if payload.wave > 0 then `WAVE {payload.wave} COMPLETE` else "GET READY"
		statusLabel.Text = "Intermission"
	end
end

waveRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: WavePayload
	wavePayload = data

	renderStatus()

	if data.announcement and data.announcement ~= "" then
		announce(
			data.announcement,
			if data.phase == "PerkChoice" then PALETTE.Accent else Color3.fromRGB(236, 240, 247)
		)
	end
end)

-- Countdown + local health mirror, both driven off replicated state.
RunService.Heartbeat:Connect(function()
	local payload = wavePayload
	if payload and payload.endsAt then
		local remaining = math.max(0, payload.endsAt - workspace:GetServerTimeNow())
		if payload.phase == "Intermission" and remaining > 0 then
			statusLabel.Text = `NEXT WAVE IN {math.ceil(remaining)}`
		elseif payload.phase == "PerkChoice" and remaining > 0 then
			statusLabel.Text = `Choose a perk to continue -- {math.ceil(remaining)}s`
		end
	end
end)

local function watchHealth(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	local function refresh()
		local ratio = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
		healthFill.Size = UDim2.fromScale(ratio, 1)
		healthFill.BackgroundColor3 = PALETTE.Health:Lerp(PALETTE.Accent, 1 - ratio)
		healthText.Text = `{math.ceil(humanoid.Health)} / {math.ceil(humanoid.MaxHealth)}`
	end

	refresh()
	humanoid.HealthChanged:Connect(refresh)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh)
end

if player.Character then
	watchHealth(player.Character)
end
player.CharacterAdded:Connect(watchHealth)

player:GetAttributeChangedSignal(ATTR.Perks):Connect(renderPerkChips)
renderPerkChips()
renderStatus()

print("[PerkUI] Cards ready.")
