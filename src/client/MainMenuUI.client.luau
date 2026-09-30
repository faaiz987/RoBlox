--!strict
--[[
	MainMenuUI (LocalScript)
	------------------------
	The front door: a title card, three nav buttons, and the options modal behind
	them.

		[ PLAY ]     tween the menu away -> give the camera and the cursor back,
		             switch the CombatHUD on, and tell the server to start wave 1.
		[ OPTIONS ]  the Controls / Keybinds modal (see OptionsMenu).
		[ CREDITS ]  a small static panel.

	While the menu is up the ScreenGui carries `CB_Menu = true` -- the contract
	CombatController already reads to hand the cursor over -- so no combat input can
	fire behind the title screen and the mouse cannot be recaptured by the camera
	lock's repair loop. The same flag is what the menu clears on PLAY.

	The run itself stays server-authoritative: the client only ever *asks* for the
	start (Remotes: StartWave). If the channel is missing, or another player already
	started the run, the menu steps aside the moment the first WaveState broadcast
	arrives.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

-- Sibling module: `assert` because `script.Parent` is typed optional, and this
-- script cannot do its job without the modal.
local clientFolder = script.Parent
assert(clientFolder, "MainMenuUI must live inside a folder")
local OptionsMenu = require(clientFolder:WaitForChild("OptionsMenu"))

local ATTR = CombatConfig.Attributes
local LOCK = CombatConfig.Camera.Lock

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

type WavePayload = {
	phase: string,
	wave: number,
	enemiesRemaining: number,
	enemiesTotal: number,
	endsAt: number?,
	announcement: string?,
}

type CreditsModal = {
	open: () -> (),
	close: () -> (),
	isOpen: () -> boolean,
}

-- ---------------------------------------------------------------------------
-- Theme
-- ---------------------------------------------------------------------------

local THEME = {
	Backdrop = Color3.fromRGB(6, 7, 11),
	Panel = Color3.fromRGB(20, 22, 30),
	PanelLight = Color3.fromRGB(34, 37, 48),
	Ink = Color3.fromRGB(236, 240, 247),
	Muted = Color3.fromRGB(150, 158, 174),
	Accent = Color3.fromRGB(255, 214, 108),
	Danger = Color3.fromRGB(255, 128, 118),
	Stroke = Color3.fromRGB(74, 80, 96),
	Slash = Color3.fromRGB(228, 236, 245),
	Parry = Color3.fromRGB(255, 214, 108),
	Dodge = Color3.fromRGB(160, 214, 255),
}

local GUI_NAMES = { CombatHUD = true, PerkUI = true }

-- ---------------------------------------------------------------------------
-- Local state
-- ---------------------------------------------------------------------------

local menuVisible = true
local dismissing = false
local frozenCamera: CFrame? = nil

-- Forward declaration: the nav buttons and the wave listener are wired up before
-- the body below exists.
local dismiss: (signalServer: boolean) -> ()

-- ---------------------------------------------------------------------------
-- Small helpers (mirrors the PerkUI / CombatHUD idioms)
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

local function playSound(soundId: string, volume: number, pitch: number)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch
	SoundService:PlayLocalSound(sound)
	Debris:AddItem(sound, 4)
end

local function navSound()
	playSound("rbxasset://sounds/electronicpingshort.wav", 0.18, 1.25)
end

-- ---------------------------------------------------------------------------
-- Root
-- ---------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "MainMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 40
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
-- Freeing the cursor for a menu is CombatController's contract: any ScreenGui
-- flagged with this attribute hands the mouse back and suppresses combat input.
gui:SetAttribute(LOCK.MenuAttribute, true)

-- A CanvasGroup, not a Frame: `GroupTransparency` -- how the whole title screen
-- fades out on PLAY -- exists only on CanvasGroup, and assigning it to a Frame
-- throws at runtime. The modals are parented to the ScreenGui, not to this, so
-- nothing is nested inside the group.
local menuRoot = Instance.new("CanvasGroup")
menuRoot.Name = "Root"
menuRoot.Size = UDim2.fromScale(1, 1)
menuRoot.Position = UDim2.fromScale(0, 0)
menuRoot.BackgroundTransparency = 1
menuRoot.Parent = gui

local rootScale = Instance.new("UIScale")
rootScale.Parent = menuRoot

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = THEME.Backdrop
backdrop.BackgroundTransparency = 0.15
backdrop.BorderSizePixel = 0
backdrop.Parent = menuRoot

local backdropSheen = Instance.new("UIGradient")
backdropSheen.Rotation = 40
backdropSheen.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(26, 30, 40)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(12, 14, 20)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 7, 11)),
})
backdropSheen.Parent = backdrop

-- A soft accent bloom behind the title, so the glass panels have something to sit on.
local bloom = Instance.new("Frame")
bloom.Name = "Bloom"
bloom.Position = UDim2.fromOffset(-140, -180)
bloom.Size = UDim2.fromOffset(760, 620)
bloom.BackgroundColor3 = THEME.Accent
bloom.BackgroundTransparency = 0.94
bloom.BorderSizePixel = 0
bloom.Parent = backdrop
corner(bloom, 300)

local bloomFade = Instance.new("UIGradient")
bloomFade.Rotation = 45
bloomFade.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})
bloomFade.Parent = bloom

-- Content ---------------------------------------------------------------------
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.fromScale(1, 1)
content.BackgroundTransparency = 1
content.Parent = menuRoot

local contentFit = Instance.new("UIScale")
contentFit.Parent = content

local LEFT = 96

local eyebrow = newText(content, "Eyebrow", UDim2.fromOffset(LEFT, 206), UDim2.fromOffset(700, 18), Enum.Font.GothamBold, 12, THEME.Muted)
eyebrow.Text = "W A V E   D E F E N S E   ·   K E N J U T S U   R O G U E L I K E"

local title = newText(content, "Title", UDim2.fromOffset(LEFT - 4, 228), UDim2.fromOffset(900, 76), Enum.Font.GothamBlack, 58, THEME.Ink)
title.Text = "RISK OF BLOX"
title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
title.TextStrokeTransparency = 0.6

local rule = Instance.new("Frame")
rule.Name = "Rule"
rule.Position = UDim2.fromOffset(LEFT + 2, 312)
rule.Size = UDim2.fromOffset(148, 3)
rule.BackgroundColor3 = THEME.Accent
rule.BorderSizePixel = 0
rule.Parent = content
corner(rule, 2)

local ruleTrail = Instance.new("Frame")
ruleTrail.Name = "RuleTrail"
ruleTrail.Position = UDim2.fromOffset(LEFT + 158, 313)
ruleTrail.Size = UDim2.fromOffset(226, 1)
ruleTrail.BackgroundColor3 = THEME.Stroke
ruleTrail.BackgroundTransparency = 0.5
ruleTrail.BorderSizePixel = 0
ruleTrail.Parent = content

local tagline = newText(content, "Tagline", UDim2.fromOffset(LEFT + 2, 328), UDim2.fromOffset(620, 22), Enum.Font.GothamMedium, 15, THEME.Muted)
tagline.Text = "Three waves of steel. One window to answer them."

-- Nav buttons -----------------------------------------------------------------
local navRoot = Instance.new("Frame")
navRoot.Name = "Nav"
navRoot.Position = UDim2.fromOffset(LEFT - 4, 386)
navRoot.Size = UDim2.fromOffset(288, 0)
navRoot.AutomaticSize = Enum.AutomaticSize.Y
navRoot.BackgroundTransparency = 1
navRoot.Parent = content

local navLayout = Instance.new("UIListLayout")
navLayout.FillDirection = Enum.FillDirection.Vertical
navLayout.SortOrder = Enum.SortOrder.LayoutOrder
navLayout.Padding = UDim.new(0, 10)
navLayout.Parent = navRoot

local function newNavButton(order: number, label: string, caption: string, accent: Color3, onClick: () -> ())
	local button = Instance.new("TextButton")
	button.Name = `Nav_{label}`
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(288, 54)
	button.BackgroundColor3 = THEME.Panel
	button.BackgroundTransparency = 0.24
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.Text = ""
	button.Parent = navRoot
	corner(button, 12)
	local outline = stroke(button, THEME.Stroke, 1, 0.6)

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.AnchorPoint = Vector2.new(0, 0.5)
	tick.Position = UDim2.new(0, 12, 0.5, 0)
	tick.Size = UDim2.fromOffset(3, 20)
	tick.BackgroundColor3 = accent
	tick.BackgroundTransparency = 0.6
	tick.BorderSizePixel = 0
	tick.Parent = button
	corner(tick, 2)

	local labelText = newText(button, "Label", UDim2.fromOffset(28, 7), UDim2.fromOffset(200, 24), Enum.Font.GothamBold, 19, THEME.Ink)
	labelText.Text = label

	local captionText = newText(button, "Caption", UDim2.fromOffset(28, 30), UDim2.fromOffset(210, 16), Enum.Font.GothamMedium, 12, THEME.Muted)
	captionText.Text = caption

	local chevron = newText(button, "Chevron", UDim2.new(1, -30, 0, 0), UDim2.fromOffset(20, 54), Enum.Font.GothamBold, 20, THEME.Muted)
	chevron.TextXAlignment = Enum.TextXAlignment.Right
	chevron.TextYAlignment = Enum.TextYAlignment.Center
	chevron.Text = ">"

	local function hover(on: boolean)
		TweenService:Create(button, TweenInfo.new(0.14), { BackgroundTransparency = (if on then 0.04 else 0.24) }):Play()
		TweenService:Create(outline, TweenInfo.new(0.14), { Transparency = (if on then 0.12 else 0.6), Color = (if on then accent else THEME.Stroke) }):Play()
		TweenService:Create(tick, TweenInfo.new(0.14), { BackgroundTransparency = (if on then 0 else 0.6) }):Play()
		TweenService:Create(labelText, TweenInfo.new(0.14), { TextColor3 = (if on then accent else THEME.Ink) }):Play()
		TweenService:Create(scale, TweenInfo.new(0.16), { Scale = (if on then 1.02 else 1) }):Play()
	end

	button.MouseEnter:Connect(function()
		hover(true)
		if menuVisible then
			playSound("rbxasset://sounds/electronicpingshort.wav", 0.09, 1.6)
		end
	end)
	button.MouseLeave:Connect(function()
		hover(false)
	end)
	button.Activated:Connect(function()
		if dismissing then
			return
		end
		navSound()
		onClick()
	end)
end

-- ---------------------------------------------------------------------------
-- Modals
-- ---------------------------------------------------------------------------

local optionsModal = OptionsMenu.create(gui, THEME, playSound)

local function newCreditsModal(): CreditsModal
	local root = Instance.new("Frame")
	root.Name = "CreditsModal"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = gui

	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = THEME.Backdrop
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.Active = false
	scrim.Parent = root

	-- CanvasGroup so the fade has a GroupTransparency to tween; every child sits
	-- inside the panel, so the group's clipping changes nothing.
	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(520, 348)
	panel.BackgroundColor3 = THEME.Panel
	panel.BackgroundTransparency = 0.04
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Parent = root
	corner(panel, 16)
	stroke(panel, THEME.Stroke, 1, 0.4)

	local sheen = Instance.new("UIGradient")
	sheen.Rotation = 90
	sheen.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.PanelLight),
		ColorSequenceKeypoint.new(1, THEME.Panel),
	})
	sheen.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	sheen.Parent = panel

	local pop = Instance.new("UIScale")
	pop.Scale = 1
	pop.Parent = panel

	local heading = newText(panel, "Heading", UDim2.fromOffset(28, 22), UDim2.fromOffset(300, 34), Enum.Font.GothamBlack, 24, THEME.Ink)
	heading.Text = "CREDITS"

	local subheading = newText(panel, "Subheading", UDim2.fromOffset(30, 56), UDim2.fromOffset(420, 16), Enum.Font.GothamMedium, 11, THEME.Muted)
	subheading.Text = "R I S K   O F   B L O X"

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromOffset(28, 84)
	divider.Size = UDim2.new(1, -56, 0, 1)
	divider.BackgroundColor3 = THEME.Stroke
	divider.BackgroundTransparency = 0.55
	divider.BorderSizePixel = 0
	divider.Parent = panel

	local LINES = {
		{ "DESIGN & CODE", "Risk of Blox team" },
		{ "COMBAT FEEL", "Ghost of Tsushima study" },
		{ "ENGINE", "Roblox · Luau · Rojo" },
		{ "SOUND", "Roblox stock library" },
	}

	for index, line in LINES do
		local y = 100 + (index - 1) * 42
		local key = newText(panel, `Key{index}`, UDim2.fromOffset(28, y), UDim2.fromOffset(180, 16), Enum.Font.GothamBold, 11, THEME.Muted)
		key.Text = line[1]
		local value = newText(panel, `Value{index}`, UDim2.fromOffset(28, y + 16), UDim2.fromOffset(440, 20), Enum.Font.GothamMedium, 14, THEME.Ink)
		value.Text = line[2]
	end

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Position = UDim2.fromOffset(28, 288)
	closeButton.Size = UDim2.fromOffset(120, 36)
	closeButton.BackgroundColor3 = THEME.Accent
	closeButton.BorderSizePixel = 0
	closeButton.AutoButtonColor = false
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 13
	closeButton.TextColor3 = THEME.Backdrop
	closeButton.Text = "CLOSE"
	closeButton.Parent = panel
	corner(closeButton, 8)

	local hint = newText(panel, "Hint", UDim2.fromOffset(160, 296), UDim2.fromOffset(340, 20), Enum.Font.GothamMedium, 11, THEME.Muted)
	hint.Text = "ESC closes this panel"

	local serial = 0

	local function open()
		if root.Visible then
			return
		end
		serial += 1
		root.Visible = true
		scrim.BackgroundTransparency = 0.72
		panel.GroupTransparency = 1
		panel.Position = UDim2.new(0.5, 0, 0.5, 22)
		pop.Scale = 0.97
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
		serial += 1
		local current = serial
		TweenService:Create(scrim, TweenInfo.new(0.18), { BackgroundTransparency = 1 }):Play()
		local out = TweenService:Create(panel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			GroupTransparency = 1,
			Position = UDim2.new(0.5, 0, 0.5, 16),
		})
		out.Completed:Connect(function()
			if serial == current then
				root.Visible = false
			end
		end)
		out:Play()
	end

	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.12), { BackgroundTransparency = 0.15 }):Play()
	end)
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.16), { BackgroundTransparency = 0 }):Play()
	end)
	closeButton.Activated:Connect(function()
		navSound()
		close()
	end)

	return {
		open = open,
		close = close,
		isOpen = function(): boolean
			return root.Visible
		end,
	}
end

local credits = newCreditsModal()

newNavButton(1, "PLAY", "Begin wave one", THEME.Accent, function()
	dismiss(true)
end)

newNavButton(2, "OPTIONS", "Controls & keybinds", THEME.Dodge, function()
	credits.close()
	optionsModal.open()
end)

newNavButton(3, "CREDITS", "Who made this", THEME.Muted, function()
	optionsModal.close()
	credits.open()
end)

-- Footer ----------------------------------------------------------------------
local footerLeft = newText(content, "FooterLeft", UDim2.new(0, LEFT, 1, -32), UDim2.fromOffset(420, 16), Enum.Font.GothamMedium, 11, THEME.Muted)
footerLeft.Text = "RISK OF BLOX · EARLY BUILD"

local footerRight = newText(content, "FooterRight", UDim2.new(1, -LEFT - 440, 1, -32), UDim2.fromOffset(440, 16), Enum.Font.GothamMedium, 11, THEME.Muted)
footerRight.TextXAlignment = Enum.TextXAlignment.Right
footerRight.Text = "SESSION KEYBINDS · REBIND IN OPTIONS"

-- ---------------------------------------------------------------------------
-- Post effects: blur + grade the world behind the menu
-- ---------------------------------------------------------------------------

local blur = Instance.new("BlurEffect")
blur.Name = "CB_MenuBlur"
blur.Size = 0
blur.Parent = Lighting

local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "CB_MenuGrade"
grade.Saturation = 0
grade.Contrast = 0
grade.Brightness = 0
grade.Parent = Lighting

TweenService:Create(blur, TweenInfo.new(0.5), { Size = 26 }):Play()
TweenService:Create(grade, TweenInfo.new(0.5), { Saturation = -0.35, Contrast = 0.12, Brightness = -0.04 }):Play()

local function removeMenuEffects()
	TweenService:Create(blur, TweenInfo.new(0.35), { Size = 0 }):Play()
	TweenService:Create(grade, TweenInfo.new(0.35), { Saturation = 0, Contrast = 0, Brightness = 0 }):Play()
	task.delay(0.5, function()
		blur:Destroy()
		grade:Destroy()
	end)
end

-- ---------------------------------------------------------------------------
-- Cursor + camera
-- ---------------------------------------------------------------------------

local function freeCursor()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function lockCursor()
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = not LOCK.HideCursor
end

-- Frames the local body from behind and holds that pose: a menu background has to
-- sit still, or the eye reads the drift as a bug.
local function freezeCamera()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local focus = root.Position + Vector3.new(0, 2.6, 0)
		local eye = root.Position - root.CFrame.LookVector * 9 + Vector3.new(0, 2.2, 0)
		frozenCamera = CFrame.lookAt(eye, focus)
	end
	camera.CameraType = Enum.CameraType.Scriptable
end

local function releaseCamera()
	frozenCamera = nil
	-- Back to the default third-person camera; CombatController re-asserts the
	-- mouse lock on its own repair loop.
	camera.CameraType = Enum.CameraType.Custom
end

freeCursor()
freezeCamera()

-- A respawn mid-menu frames the new body; the camera is Scriptable so nothing else
-- would move it there.
player.CharacterAdded:Connect(function()
	if menuVisible then
		frozenCamera = nil
	end
end)

RunService.RenderStepped:Connect(function()
	if not menuVisible then
		return
	end
	-- The default camera script claims CameraType again the moment a character
	-- spawns, so the freeze is re-asserted rather than set once.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	if not frozenCamera then
		freezeCamera()
	end
	local frozen = frozenCamera
	if frozen and camera.CFrame ~= frozen then
		camera.CFrame = frozen
	end
end)

-- ---------------------------------------------------------------------------
-- HUD visibility
-- ---------------------------------------------------------------------------

-- The HUD scripts have no enable API of their own, so the menu owns their
-- ScreenGuis while it is up: a control readout behind a title screen reads as
-- clutter, and its key glyphs would be wrong before the player has pressed PLAY.
local function syncHudGui(child: Instance)
	if child:IsA("ScreenGui") and GUI_NAMES[child.Name] then
		child.Enabled = not menuVisible
	end
end

local function syncHud()
	for _, child in playerGui:GetChildren() do
		syncHudGui(child)
	end
end

syncHud()
playerGui.ChildAdded:Connect(syncHudGui)

-- ---------------------------------------------------------------------------
-- Starting the run
-- ---------------------------------------------------------------------------

--[[
	Resolves a channel defensively: the registry first (it waits for replication and
	creates a placeholder of last resort), then the replicated folder by name.
	Returns nil instead of throwing -- a missing start channel must degrade to "the
	wave manager starts the run itself", never to a menu that dies on a click.
]]
local function resolveRemote(primary: unknown, fallbacks: { string }): RemoteEvent?
	local names: { string } = {}
	if typeof(primary) == "string" then
		table.insert(names, primary)
	end
	for _, name in fallbacks do
		table.insert(names, name)
	end

	for _, name in names do
		local ok, resolved = pcall(function()
			return Remotes.client(name)
		end)
		if ok and typeof(resolved) == "Instance" then
			local instance = resolved :: any
			if instance:IsA("RemoteEvent") then
				return instance
			end
		end
	end

	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = ReplicatedStorage:WaitForChild("Remotes", 5)
	end
	if folder then
		for _, name in names do
			local found: Instance? = folder:FindFirstChild(name)
			if found and found:IsA("RemoteEvent") then
				return found
			end
		end
	end
	return nil
end

local startWaveRemote = resolveRemote(Remotes.Names.StartWave, { "StartWave" })

local function requestStart()
	local remote = startWaveRemote
	if not remote then
		remote = resolveRemote(Remotes.Names.StartWave, { "StartWave" })
		startWaveRemote = remote
	end
	if remote then
		remote:FireServer()
	else
		warn("[MainMenuUI] No StartWave channel: the wave manager will start the run on its own.")
	end
end

-- ---------------------------------------------------------------------------
-- Handing over to the game
-- ---------------------------------------------------------------------------

dismiss = function(signalServer: boolean)
	if dismissing then
		return
	end
	dismissing = true

	-- Fire first: the server opens with its own intermission, so the arena warms up
	-- while the title screen is still sliding away.
	if signalServer then
		requestStart()
	end
	optionsModal.close()
	credits.close()
	playSound("rbxasset://sounds/electronicpingshort.wav", 0.22, 0.9)

	task.spawn(function()
		local exit = TweenService:Create(menuRoot, TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			GroupTransparency = 1,
			Position = UDim2.fromOffset(-28, 0),
		})
		TweenService:Create(rootScale, TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Scale = 1.04 }):Play()
		exit:Play()
		exit.Completed:Wait()

		menuVisible = false
		gui.Enabled = false
		-- Clearing the flag returns the cursor to CombatController's lock loop.
		gui:SetAttribute(LOCK.MenuAttribute, false)
		releaseCamera()
		lockCursor()
		removeMenuEffects()
		syncHud()
	end)
end

-- Late join / respawn / lobby timeout: the run is already going, so the menu has
-- no business holding the player back. One mechanism covers every case.
local waveRemote = resolveRemote(Remotes.Names.WaveState, { "WaveState" })
if waveRemote then
	waveRemote.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) ~= "table" then
			return
		end
		local data = payload :: WavePayload
		if data.phase ~= "Idle" and menuVisible and not dismissing then
			dismiss(false)
		end
	end)
end

local currentWave = player:GetAttribute(ATTR.Wave)
if typeof(currentWave) == "number" and currentWave > 0 then
	dismiss(false)
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if not gui.Enabled or input.KeyCode ~= Enum.KeyCode.Escape then
		return
	end
	-- The options modal owns Escape while it is up (cancel capture, then close).
	if optionsModal.isOpen() then
		return
	end
	if credits.isOpen() then
		credits.close()
	end
end)

-- ---------------------------------------------------------------------------
-- Responsive fit
-- ---------------------------------------------------------------------------

local function fitToViewport()
	local viewport = camera.ViewportSize
	contentFit.Scale = math.clamp(math.min(viewport.X / 1440, viewport.Y / 810), 0.6, 1)
end

camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToViewport)
fitToViewport()

print("[MainMenuUI] Risk of Blox title screen online.")
