--!strict
--[[
	CombatController (LocalScript)
	-----------------------------
	Everything the player *feels*:

	  * Keybinds   -- Left Click: slash, F: parry / guard, Q or Shift: dodge.
	  * Camera     -- trauma shake, FOV punches and swing roll, bound to render on
	                  top of the default camera script.
	  * Sword      -- poses every katana in the world from replicated CombatFx, so
	                  the local player and every observer see the same cut.
	  * Telegraphs -- draws the enemy windup ring above each enemy from attributes.
	  * Character  -- dodge dash impulses, double jump, guard stance, hit recoil.

	The client never decides damage. It predicts motion for feel and lets the
	server arbitrate results.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ATTR = CombatConfig.Attributes
local POSES = CombatConfig.Poses
local FXCFG = CombatConfig.Fx
local CAMERA_CFG = CombatConfig.Camera
local RIG = CombatConfig.RigParts
local NAMES = Remotes.Names
local TAG = CombatConfig.Tags.Enemy

type Pose = { x: number, y: number, z: number }

--[[
	Structural mirror of Remotes.FxPayload.
	The client resolves shared modules by waiting on replication, so local shapes
	keep this file fully typed without depending on analysis-time resolution.
]]
type Fx = {
	action: string,
	player: Player?,
	target: Instance?,
	position: Vector3?,
	direction: Vector3?,
	amount: number?,
	stepIndex: number?,
	stepKind: string?,
	stepName: string?,
	shadow: boolean?,
	attackSpeed: number?,
}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local ACTIONS = {
	Attack = "CB_Attack",
	Parry = "CB_Parry",
	Dodge = "CB_Dodge",
}

local attackRemote = Remotes.client(NAMES.Attack)
local parryRemote = Remotes.client(NAMES.Parry)
local dodgeRemote = Remotes.client(NAMES.Dodge)
local fxRemote = Remotes.client(NAMES.CombatFx)

-- ---------------------------------------------------------------------------
-- Local state
-- ---------------------------------------------------------------------------

local state = {
	attackLockUntil = 0,
	comboIndex = 0,
	comboExpiresAt = 0,
	dodgeCooldownUntil = 0,
	parryCooldownUntil = 0,
	guarding = false,
	parryHeld = false,
	airJumpsUsed = 0,
	predictedSwings = 0,
}

local trailSerial: { [Model]: number } = {}

local function now(): number
	return os.clock()
end

local function attrNumber(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

local function attrBool(name: string): boolean
	return player:GetAttribute(name) == true
end

local function flat(vector: Vector3): Vector3
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	if horizontal.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return horizontal.Unit
end

local function myCharacter(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") then
		return character, humanoid, root
	end
	return character, humanoid, nil
end

-- ---------------------------------------------------------------------------
-- Camera FX: trauma shake + FOV punch + swing roll
-- ---------------------------------------------------------------------------

local shakeRng = Random.new(DateTime.now().UnixTimestampMillis % 2 ^ 31)
local trauma = 0
local fovKick = 0
local rollKick = 0
local baseFov = camera.FieldOfView

local function addTrauma(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)
end

local function addFov(degrees: number)
	fovKick += degrees
end

local function addRoll(degrees: number)
	rollKick += degrees
end

RunService:BindToRenderStep("CB_CameraFx", Enum.RenderPriority.Camera.Value + 1, function(deltaTime: number)
	-- FOV spring returns to the player's own setting, never a hard-coded default.
	local targetFov = baseFov + fovKick
	if math.abs(camera.FieldOfView - targetFov) > 0.01 then
		camera.FieldOfView = camera.FieldOfView + (targetFov - camera.FieldOfView) * CombatConfig.smooth(deltaTime, 18)
	end
	fovKick *= math.exp(-CAMERA_CFG.FovRecovery * deltaTime)
	if math.abs(fovKick) < 0.01 then
		fovKick = 0
	end

	if math.abs(rollKick) > 0.01 then
		camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, math.rad(rollKick))
		rollKick *= math.exp(-9 * deltaTime)
	else
		rollKick = 0
	end

	if trauma > 0 then
		trauma = math.max(0, trauma - CAMERA_CFG.ShakeDecay * deltaTime)
		local amplitude = trauma * trauma
		local shake = CFrame.Angles(
			math.rad(shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeDegrees * amplitude),
			math.rad(shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeDegrees * amplitude),
			math.rad(shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeDegrees * amplitude)
		) * CFrame.new(
			shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeOffset * amplitude,
			shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeOffset * amplitude,
			0
		)
		camera.CFrame = camera.CFrame * shake
	end
end)

local blur = Instance.new("BlurEffect")
blur.Name = "CB_DashBlur"
blur.Size = 0
blur.Parent = Lighting

local function blurPulse(size: number, duration: number)
	TweenService:Create(blur, TweenInfo.new(duration * 0.35), { Size = size }):Play()
	task.delay(duration * 0.35, function()
		TweenService:Create(blur, TweenInfo.new(duration * 0.65), { Size = 0 }):Play()
	end)
end

-- ---------------------------------------------------------------------------
-- Sounds and sparks
-- ---------------------------------------------------------------------------

local function playOneShot(soundId: string, volume: number, pitch: number, parent: Instance?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch
	sound.RollOffMaxDistance = 200
	if parent then
		sound.Parent = parent
		sound:Play()
		Debris:AddItem(sound, 6)
	else
		-- An unparented Sound can still be played locally (position-less 2D audio).
		SoundService:PlayLocalSound(sound)
		Debris:AddItem(sound, 6)
	end
end

local function sparkBurst(position: Vector3, color: Color3, count: number, speed: number)
	local anchor = Instance.new("Part")
	anchor.Name = "CB_Spark"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Lifetime = NumberRange.new(0.18, 0.38)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.LightEmission = 0.7
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = anchor
	emitter:Emit(count)
	Debris:AddItem(anchor, 1.2)
end

-- ---------------------------------------------------------------------------
-- Screen feedback (flash + damage vignette)
-- ---------------------------------------------------------------------------

local overlay = Instance.new("ScreenGui")
overlay.Name = "CB_CombatFx"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.DisplayOrder = 40
overlay.Parent = player:WaitForChild("PlayerGui")

local function newFullscreenFrame(name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = overlay
	return frame
end

local parryFlash = newFullscreenFrame("ParryFlash", Color3.fromRGB(255, 246, 214), 1)
local hurtVignette = newFullscreenFrame("HurtVignette", Color3.fromRGB(140, 18, 24), 1)
local riposteFrame = newFullscreenFrame("Riposte", Color3.fromRGB(255, 214, 108), 1)

local function flash(frame: Frame, peak: number, duration: number)
	frame.BackgroundTransparency = 1 - peak
	TweenService:Create(frame, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

-- ---------------------------------------------------------------------------
-- Sword posing (every character, driven by replicated FX)
-- ---------------------------------------------------------------------------

type SwordRig = {
	model: Model,
	shoulder: Motor6D?,
	baseC0: CFrame?,
	trail: Trail?,
}

local swords: { [Model]: SwordRig } = {}

local function findShoulder(character: Model): Motor6D?
	for _, name in RIG.ShoulderJointNames do
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Name == name then
				return descendant
			end
		end
	end
	return nil
end

local function getSword(character: Model): SwordRig?
	local cached = swords[character]
	if cached and cached.model.Parent == character then
		return cached
	end

	local model = character:FindFirstChild(RIG.KatanaName)
	if not model or not model:IsA("Model") then
		return nil
	end
	local blade = model:FindFirstChild("Blade")
	local trail = blade and blade:FindFirstChild("SlashTrail")
	local shoulder = findShoulder(character)

	local rig: SwordRig = {
		model = model,
		shoulder = shoulder,
		baseC0 = if shoulder then shoulder.C0 else nil,
		trail = if trail and trail:IsA("Trail") then trail else nil,
	}
	swords[character] = rig
	return rig
end

local function poseCFrame(pose: Pose, alpha: number): CFrame
	return CFrame.Angles(math.rad(pose.x * alpha), math.rad(pose.y * alpha), math.rad(pose.z * alpha))
end

local function setTrailEnabled(rig: SwordRig, enabled: boolean, duration: number?)
	if not rig.trail then
		return
	end
	rig.trail.Enabled = enabled
	if enabled and duration then
		task.delay(duration, function()
			if rig.trail then
				rig.trail.Enabled = false
			end
		end)
	end
end

-- Windup -> impact -> recovery, timed off the shared combo data.
local function playSwing(character: Model, stepIndex: number, attackSpeed: number, color: Color3?)
	local rig = getSword(character)
	if not rig or not rig.shoulder or not rig.baseC0 then
		return
	end

	local serial = (trailSerial[character] or 0) + 1
	trailSerial[character] = serial
	local baseC0 = rig.baseC0
	local shoulder = rig.shoulder

	local step = CombatConfig.getComboStep(stepIndex)
	local speed = math.max(attackSpeed, 0.2)
	local windup = step.windup / speed
	local recovery = step.recovery / speed

	local windupPose: Pose = if step.kind == "Heavy"
		then POSES.HeavyWindup
		elseif stepIndex % 2 == 0 then POSES.SlashAlternate
		else POSES.SlashWindup
	local impactPose: Pose = if step.kind == "Heavy" then POSES.HeavyImpact else POSES.SlashImpact

	if rig.trail and color then
		rig.trail.Color = ColorSequence.new(color)
	end

	task.spawn(function()
		local startedAt = now()
		while true do
			if trailSerial[character] ~= serial then
				return
			end
			local alpha = math.clamp((now() - startedAt) / windup, 0, 1)
			shoulder.C0 = baseC0 * poseCFrame(windupPose, alpha)
			if alpha >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end

		shoulder.C0 = baseC0 * poseCFrame(impactPose, 1)
		setTrailEnabled(rig, true, math.min(0.14, recovery))

		local impactAt = now()
		while true do
			if trailSerial[character] ~= serial then
				return
			end
			local alpha = math.clamp((now() - impactAt) / recovery, 0, 1)
			shoulder.C0 = baseC0 * poseCFrame(impactPose, 1 - alpha)
			if alpha >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end

		if trailSerial[character] == serial then
			shoulder.C0 = baseC0
		end
	end)
end

-- Guard / riposte poses for the local player, driven by input feel.
local function holdGuardPose(pose: Pose)
	local character = player.Character
	if not character then
		return
	end
	local rig = getSword(character)
	if rig and rig.shoulder and rig.baseC0 then
		rig.shoulder.C0 = rig.baseC0 * poseCFrame(pose, 1)
	end
end

-- ---------------------------------------------------------------------------
-- Enemy telegraph UI (client-local, attribute driven)
-- ---------------------------------------------------------------------------

type TelegraphUi = {
	highlight: Highlight,
	billboard: BillboardGui,
	bar: Frame,
	label: TextLabel,
	active: boolean,
	startedAt: number,
	duration: number,
	flashUntil: number,
}

local telegraphs: { [Model]: TelegraphUi } = {}

local function buildTelegraph(model: Model)
	local highlight = Instance.new("Highlight")
	highlight.Name = "CB_Telegraph"
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CB_TelegraphLabel"
	billboard.Size = UDim2.fromOffset(150, 34)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 90
	billboard.Enabled = false
	billboard.Parent = model

	local label = Instance.new("TextLabel")
	label.Name = "Warning"
	label.Size = UDim2.new(1, 0, 0.6, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = CombatConfig.Telegraph.ParryableColor
	label.TextStrokeTransparency = 0.35
	label.Text = ""
	label.Parent = billboard

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.fromScale(0.5, 0.66)
	track.Size = UDim2.fromScale(0.92, 0.16)
	track.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = billboard

	local bar = Instance.new("Frame")
	bar.Name = "Fill"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = CombatConfig.Telegraph.ParryableColor
	bar.BorderSizePixel = 0
	bar.Parent = track

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = bar

	telegraphs[model] = {
		highlight = highlight,
		billboard = billboard,
		bar = bar,
		label = label,
		active = false,
		startedAt = 0,
		duration = 1,
		flashUntil = 0,
	}
end

local function teardownTelegraph(model: Model)
	local ui = telegraphs[model]
	if not ui then
		return
	end
	ui.highlight:Destroy()
	ui.billboard:Destroy()
	telegraphs[model] = nil
end

local function watchEnemy(model: Model)
	if telegraphs[model] then
		return
	end
	buildTelegraph(model)

	local archetypeId = model:GetAttribute(ATTR.Archetype)
	local archetype = if typeof(archetypeId) == "string" then CombatConfig.getEnemyArchetype(archetypeId) else nil
	local ui = telegraphs[model]
	if ui and archetype then
		ui.duration = archetype.windup
	end

	model:GetAttributeChangedSignal(ATTR.TelegraphEnds):Connect(function()
		local current = telegraphs[model]
		if not current then
			return
		end
		local endsAt = model:GetAttribute(ATTR.TelegraphEnds)
		if typeof(endsAt) == "number" then
			local parryable = model:GetAttribute(ATTR.TelegraphParryable) ~= false
			local color = if parryable then CombatConfig.Telegraph.ParryableColor else CombatConfig.Telegraph.UnparryableColor
			current.active = true
			current.startedAt = workspace:GetServerTimeNow()
			current.duration = math.max(endsAt - current.startedAt, 0.15)
			current.highlight.FillColor = color
			current.highlight.OutlineColor = color
			current.highlight.FillTransparency = 0.82
			current.highlight.OutlineTransparency = 0.15
			current.label.TextColor3 = color
			current.bar.BackgroundColor3 = color
			current.label.Text = tostring(model:GetAttribute(ATTR.TelegraphLabel) or "")
			current.billboard.Enabled = true
			playOneShot(
				if parryable then CombatConfig.Telegraph.ParryableSound else CombatConfig.Telegraph.UnparryableSound,
				0.35,
				if parryable then 1 else 1.4,
				model:FindFirstChild("HumanoidRootPart")
			)
		else
			current.active = false
			current.billboard.Enabled = false
			current.highlight.FillTransparency = 1
			current.highlight.OutlineTransparency = 1
			-- White clash-tell frame: the blade is already moving.
			current.flashUntil = workspace:GetServerTimeNow() + 0.12
			current.highlight.FillColor = Color3.fromRGB(255, 255, 255)
			current.highlight.FillTransparency = 0.55
			current.highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
			current.highlight.OutlineTransparency = 0.1
		end
	end)
end

RunService.Heartbeat:Connect(function()
	local serverNow = workspace:GetServerTimeNow()
	local stale: { Model }? = nil
	for model, ui in telegraphs do
		if model.Parent == nil then
			stale = stale or {}
			table.insert(stale, model)
		elseif ui.active then
			local remaining = math.max(0, ui.startedAt + ui.duration - serverNow)
			local progress = 1 - math.clamp(remaining / ui.duration, 0, 1)
			ui.bar.Size = UDim2.fromScale(progress, 1)
			ui.highlight.FillTransparency = 0.9 - progress * 0.55
		elseif ui.flashUntil > 0 and serverNow > ui.flashUntil then
			ui.flashUntil = 0
			ui.highlight.FillTransparency = 1
			ui.highlight.OutlineTransparency = 1
		end
	end
	-- Never mutate the table we are iterating.
	if stale then
		for _, model in stale do
			teardownTelegraph(model)
		end
	end
end)

for _, model in CollectionService:GetTagged(TAG) do
	watchEnemy(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(function(model: Instance)
	if model:IsA("Model") then
		watchEnemy(model)
	end
end)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model: Instance)
	if model:IsA("Model") then
		teardownTelegraph(model)
	end
end)

-- ---------------------------------------------------------------------------
-- Character helpers
-- ---------------------------------------------------------------------------

local function dodgeDash(direction: Vector3)
	local character, humanoid, root = myCharacter()
	if not character or not humanoid or not root then
		return
	end

	local shadow = attrBool(ATTR.ShadowDash)
	local speed = (if shadow then 1.2 else 1) * CombatConfig.Player.DashSpeed
	root.AssemblyLinearVelocity = Vector3.new(
		direction.X * speed,
		math.max(root.AssemblyLinearVelocity.Y * 0.35, -10),
		direction.Z * speed
	)

	local color = if shadow then FXCFG.ShadowDashColor else FXCFG.DodgeColor
	local trail = Instance.new("Trail")
	trail.Name = "CB_DashTrail"
	trail.Lifetime = if shadow then 0.45 else 0.25
	trail.MinLength = 0.2
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if shadow then 0.1 else 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 1.6, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -1.6, 0)
	bottom.Parent = root
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Parent = root
	Debris:AddItem(trail, 0.6)
	Debris:AddItem(top, 0.6)
	Debris:AddItem(bottom, 0.6)

	if shadow then
		sparkBurst(root.Position, color, 18, 14)
	end
	playOneShot(FXCFG.DodgeWhoosh, 0.45, 1.2, root)
	addFov(9)
	addRoll(-2.5)
	blurPulse(if shadow then 20 else 12, 0.35)
end

local function swingLunge(stepIndex: number)
	local _, _, root = myCharacter()
	if not root then
		return
	end
	local step = CombatConfig.getComboStep(stepIndex)
	local look = flat(root.CFrame.LookVector)
	root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + look * step.lunge * 1.6
end

-- ---------------------------------------------------------------------------
-- Input: attack / parry / guard / dodge
-- ---------------------------------------------------------------------------

local function submitAttack()
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		return
	end

	local character, humanoid, root = myCharacter()
	if not character or not humanoid or not root then
		return
	end

	local timestamp = now()
	if timestamp < state.attackLockUntil then
		return
	end

	local stepIndex: number
	if timestamp <= state.comboExpiresAt and state.comboIndex < #CombatConfig.Combo.Steps then
		stepIndex = state.comboIndex + 1
	else
		stepIndex = 1
	end

	local speed = attrNumber(ATTR.AttackSpeed, 1)
	local step = CombatConfig.getComboStep(stepIndex)
	local windup = step.windup / speed
	local recovery = step.recovery / speed

	state.comboIndex = stepIndex
	state.attackLockUntil = timestamp + windup + recovery
	state.comboExpiresAt = state.attackLockUntil + CombatConfig.Timings.ComboTimeout

	state.guarding = false
	-- Bounded: a rejected request must never leave the counter stuck above zero.
	state.predictedSwings = math.min(state.predictedSwings + 1, 3)

	-- Predict the swing locally so the blade moves on the same frame as the click.
	playSwing(character, stepIndex, speed)
	swingLunge(stepIndex)
	playOneShot(step.swingSound, 0.5, 1, root)
	addTrauma(step.shake * 0.55)
	addFov(step.fovKick * 0.7)
	addRoll(if step.kind == "Heavy" then -3.5 else -1.5)

	attackRemote:FireServer(stepIndex)

	-- Local impact beat, so a whiff still lands in the hand. The Hit FX adds more
	-- when the blade actually connects.
	task.delay(windup, function()
		addTrauma(step.shake * 0.5)
		addFov(step.fovKick * 0.5)
		addRoll(if step.kind == "Heavy" then -2.5 else -1)
		playOneShot(step.hitSound, 0.3, if step.kind == "Heavy" then 0.85 else 1.15, root)
	end)
end

local function submitParry()
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		return
	end

	local _, humanoid, root = myCharacter()
	if not humanoid or not root then
		return
	end

	local timestamp = now()
	if timestamp < state.parryCooldownUntil or timestamp < state.attackLockUntil then
		return
	end

	local window = attrNumber(ATTR.ParryWindow, CombatConfig.Timings.ParryWindow)
	-- Mirror the server's post-perk cooldown so local feedback never lies.
	state.parryCooldownUntil = timestamp + attrNumber(ATTR.ParryCooldown, CombatConfig.Timings.ParryCooldown)
	state.guarding = false

	holdGuardPose(POSES.ParryGuard)
	addFov(-2.5)
	addRoll(2)
	playOneShot(FXCFG.ParryClashAccent, 0.25, 1.6, root)

	parryRemote:FireServer("Parry")

	-- Hold past the window and the stance settles into a guard.
	task.delay(window, function()
		if state.parryHeld then
			state.guarding = true
			parryRemote:FireServer("Guard")
		end
	end)

	task.delay(window + 0.2, function()
		if not state.parryHeld and not state.guarding then
			holdGuardPose({ x = 0, y = 0, z = 0 })
		end
	end)
end

local function releaseGuard()
	state.parryHeld = false
	if state.guarding then
		state.guarding = false
		parryRemote:FireServer("Unguard")
	end
	holdGuardPose({ x = 0, y = 0, z = 0 })
end

local function submitDodge()
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		return
	end

	local character, humanoid, root = myCharacter()
	if not character or not humanoid or not root then
		return
	end

	-- Air dodges are allowed; the i-frames are the point.
	local timestamp = now()
	if timestamp < state.dodgeCooldownUntil then
		return
	end
	local cooldown = attrNumber(ATTR.DodgeCooldown, CombatConfig.Timings.DodgeCooldown)
	state.dodgeCooldownUntil = timestamp + cooldown

	local direction = if humanoid.MoveDirection.Magnitude > 0.1 then flat(humanoid.MoveDirection) else flat(root.CFrame.LookVector) * -1
	dodgeDash(direction)
	dodgeRemote:FireServer(direction)
end

ContextActionService:BindAction(ACTIONS.Attack, function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		submitAttack()
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

ContextActionService:BindAction(ACTIONS.Parry, function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		state.parryHeld = true
		submitParry()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		releaseGuard()
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.KeyCode.F, Enum.KeyCode.ButtonL2)

ContextActionService:BindAction(ACTIONS.Dodge, function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		submitDodge()
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.KeyCode.Q, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL1)

ContextActionService:SetTitle(ACTIONS.Attack, "Slash")
ContextActionService:SetTitle(ACTIONS.Parry, "Parry")
ContextActionService:SetTitle(ACTIONS.Dodge, "Dodge")
ContextActionService:SetPosition(ACTIONS.Dodge, UDim2.new(1, -110, 1, -170))

-- ---------------------------------------------------------------------------
-- Double jump
-- ---------------------------------------------------------------------------

local function bindDoubleJump(humanoid: Humanoid)
	state.airJumpsUsed = 0
	humanoid.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType)
		if
			newState == Enum.HumanoidStateType.Landed
			or newState == Enum.HumanoidStateType.Running
			or newState == Enum.HumanoidStateType.RunningNoPhysics
			or newState == Enum.HumanoidStateType.Seated
			or newState == Enum.HumanoidStateType.GettingUp
		then
			state.airJumpsUsed = 0
		end
	end)
end

UserInputService.JumpRequest:Connect(function()
	local character, humanoid, root = myCharacter()
	if not character or not humanoid or not root then
		return
	end

	local extraJumps = attrNumber(ATTR.ExtraJumps, 0)
	if extraJumps <= 0 or state.airJumpsUsed >= extraJumps then
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
		return
	end

	state.airJumpsUsed += 1
	root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 54, root.AssemblyLinearVelocity.Z)
	playOneShot(FXCFG.DodgeWhoosh, 0.3, 1.5, root)
	addFov(4)
	addRoll(-1.5)
end)

local function bindCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		bindDoubleJump(humanoid)
	end
	-- Warm the sword cache so the first swing never hitches.
	task.delay(0.5, function()
		getSword(character)
	end)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

-- ---------------------------------------------------------------------------
-- Replicated FX
-- ---------------------------------------------------------------------------

local function findCharacter(playerOrModel: unknown): Model?
	if typeof(playerOrModel) == "Instance" then
		local instance = playerOrModel :: Instance
		if instance:IsA("Player") then
			return instance.Character
		end
		if instance:IsA("Model") then
			return instance
		end
	end
	return nil
end

fxRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local fx = payload :: Fx
	local action = fx.action
	local isMine = fx.player == player
	local character = findCharacter(fx.player)

	if action == "Swing" then
		local stepIndex = fx.stepIndex or 1
		if isMine and state.predictedSwings > 0 then
			state.predictedSwings -= 1 -- already predicted locally
		elseif character then
			playSwing(character, stepIndex, fx.attackSpeed or 1)
		end
	elseif action == "Hit" then
		local heavy = fx.stepKind == "Heavy"
		if fx.position then
			sparkBurst(fx.position, if heavy then Color3.fromRGB(255, 176, 96) else FXCFG.SlashColor, if heavy then 26 else 14, if heavy then 26 else 18)
		end
		if isMine then
			addTrauma(if heavy then 0.55 else 0.22)
			addFov(if heavy then 2.5 else 1)
			addRoll(if heavy then -2 else -0.8)
			if heavy then
				blurPulse(6, 0.18)
			end
			playOneShot(if heavy then "rbxasset://sounds/impact_water.mp3" else "rbxasset://sounds/snap.mp3", 0.5, 1, nil)
		end
	elseif action == "ParrySuccess" then
		if fx.position then
			sparkBurst(fx.position, FXCFG.ParryColor, 34, 30)
		end
		flash(parryFlash, 0.6, 0.35)
		playOneShot(FXCFG.ParryClash, 0.7, 1, nil)
		if isMine then
			addTrauma(0.85)
			addFov(-5)
			addRoll(6)
			blurPulse(9, 0.22)
			if (fx.amount or 0) > 0 then
				flash(riposteFrame, 0.35, 0.5)
			end
			holdGuardPose(POSES.ParryRiposte)
			task.delay(0.25, function()
				if not state.guarding then
					holdGuardPose({ x = 0, y = 0, z = 0 })
				end
			end)
		end
	elseif action == "Blocked" then
		if fx.position then
			sparkBurst(fx.position, Color3.fromRGB(180, 200, 255), 12, 12)
		end
		playOneShot(FXCFG.BlockThud, 0.55, 1, nil)
		if isMine then
			addTrauma(0.35)
			addFov(2)
		end
	elseif action == "Evaded" then
		if fx.position then
			sparkBurst(fx.position, FXCFG.DodgeColor, 10, 8)
		end
		if isMine then
			addFov(4)
			addRoll(-3)
		end
	elseif action == "PlayerHit" then
		local _, _, root = myCharacter()
		if fx.position then
			sparkBurst(fx.position, Color3.fromRGB(220, 60, 70), 16, 16)
		end
		-- Recoil is applied locally: the client owns its own character's motion.
		if isMine then
			if root and fx.direction then
				root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + fx.direction * 26
			end
			flash(hurtVignette, 0.45, 0.5)
			addTrauma(0.7)
			addFov(6)
			addRoll(-5)
			blurPulse(10, 0.25)
			playOneShot("rbxasset://sounds/uuhhh.mp3", 0.5, 1, root)
		end
	elseif action == "EnemyDied" then
		if fx.position then
			sparkBurst(fx.position, Color3.fromRGB(190, 60, 70), 22, 18)
		end
		local _, _, root = myCharacter()
		if root and fx.position and (fx.position - root.Position).Magnitude < 45 then
			addTrauma(0.18)
		end
	elseif action == "PoiseBreak" then
		if fx.position then
			sparkBurst(fx.position, Color3.fromRGB(255, 232, 168), 24, 22)
		end
	elseif action == "PlayerDied" and isMine then
		flash(hurtVignette, 0.7, 0.8)
		addTrauma(1)
		addFov(8)
	elseif action == "Parry" then
		if not isMine and character then
			local rig = getSword(character)
			if rig and rig.shoulder and rig.baseC0 then
				rig.shoulder.C0 = rig.baseC0 * poseCFrame(POSES.ParryGuard, 1)
				task.delay(0.35, function()
					if rig.baseC0 then
						rig.shoulder.C0 = rig.baseC0
					end
				end)
			end
		end
	elseif action == "Dodge" then
		if not isMine and character and character.PrimaryPart then
			sparkBurst(character.PrimaryPart.Position, if fx.shadow then FXCFG.ShadowDashColor else FXCFG.DodgeColor, 12, 10)
		end
	end
end)

print("[CombatController] Blade in hand.")
