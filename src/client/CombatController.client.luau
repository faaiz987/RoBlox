--!strict
--[[
	CombatController (LocalScript)
	-----------------------------
	Everything the player *feels*:

  * Keybinds   -- rebindable, and owned by KeybindManager: Left Click: slash,
                  F: parry / guard, Shift or Q: dodge.
  * Camera     -- mouse-look lock (no right-click hold) plus trauma shake, FOV
                  punches and swing roll, bound to render on top of the default
                  camera script. The cursor is freed for the perk overlay / menus.
  * Animations -- authored slash clips via Humanoid.Animator when they are
                  configured, then Roblox's own stock sword clips, and otherwise a
                  procedural frame override (CombatConfig.Procedural): each beat's
                  joint offset is driven on RunService.PreSimulation -- after the
                  Animator has run -- while the default idle/tool layers are held at
                  zero weight, so an attack or parry always renders on screen.
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
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Animations = require(Shared:WaitForChild("Animations"))
local KeybindManager = require(Shared:WaitForChild("KeybindManager"))

local ATTR = CombatConfig.Attributes
local FXCFG = CombatConfig.Fx
local CAMERA_CFG = CombatConfig.Camera
local LOCK_CFG = CAMERA_CFG.Lock
local TRAIL_CFG = CombatConfig.Trail
local RIG = CombatConfig.RigParts
local NAMES = Remotes.Names
local TAG = CombatConfig.Tags.Enemy
-- Procedural animation data: the pose each beat tweens onto the shoulder's rest C0
-- (see CombatConfig.Procedural), read here so a swing and its authored-clip
-- equivalent can never disagree.
local PROCEDURAL = CombatConfig.Procedural
local PARRY_BEAT = PROCEDURAL.Parry
local POSE_FLIP = PROCEDURAL.Flip

type Pose = { x: number, y: number, z: number }

--[[
	Joints the arm rig can drive.
	A Motor6D carries its offset on C0; the newer AnimationConstraint joint that
	the avatar joint upgrade swaps in carries the same information on Transform.
	Every read and write below goes through jointOffset / setJointOffset, so a rig
	of either generation can be posed.
]]
type JointKind = Motor6D | AnimationConstraint

-- One in-flight interpolation: the frame driver walks `from` -> `to` over
-- `duration` and re-asserts the result after the Animator has run.
type JointDrive = {
	from: CFrame,
	to: CFrame,
	startedAt: number,
	duration: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection,
}

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
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local ACTIONS = {
	Attack = "CB_Attack",
	Parry = "CB_Parry",
	Dodge = "CB_Dodge",
}

-- Verbose input trace, so a click can be followed in the Studio console from
-- input to animation. Flip to false to silence it.
local INPUT_DEBUG = true

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
	-- While `now()` is below this, the parry stance owns itself: its own timer eases
	-- the blade home (0.1s later on a clash), so releasing the key early cannot cut
	-- the block short.
	parryStanceUntil = 0,
	-- Bumped by every parry and every clash: a stale timer from an older stance must
	-- never move the arm of a newer one.
	parrySerial = 0,
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
-- Camera: mouse-look lock
--   The mouse turns the camera with no right-click hold (MouseBehavior.LockCenter
--   is exactly the "mouse look" mode the default camera script reads deltas from).
--   The cursor is handed back the moment a menu wants it: the perk overlay flags
--   itself through CB_ChoiceOpen, and any future menu can opt in by setting
--   `CB_Menu = true` on its ScreenGui.
-- ---------------------------------------------------------------------------

local function menuIsOpen(): boolean
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		return true
	end
	-- A dead or absent character has nothing to aim: free the cursor instead.
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid or humanoid.Health <= 0 then
		return true
	end
	-- The Roblox menu and any focused TextBox own the cursor while they are up.
	if GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() ~= nil then
		return true
	end
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("ScreenGui") and gui.Enabled and gui:GetAttribute(LOCK_CFG.MenuAttribute) == true then
			return true
		end
	end
	return false
end

-- Converges mouse behavior onto the mode the current context wants.
local function applyCameraLock()
	local locked = not menuIsOpen()
	local desired = if locked then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
	if UserInputService.MouseBehavior ~= desired then
		UserInputService.MouseBehavior = desired
	end

	local wantIcon = (not locked) or (not LOCK_CFG.HideCursor)
	if UserInputService.MouseIconEnabled ~= wantIcon then
		UserInputService.MouseIconEnabled = wantIcon
	end
end

-- Combat framing: classic third person, tight zoom so the duel stays in frame.
local function applyCameraSetup()
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMinZoomDistance = LOCK_CFG.MinZoom
	player.CameraMaxZoomDistance = LOCK_CFG.MaxZoom
end

local lockClock = 0

RunService.Heartbeat:Connect(function(deltaTime: number)
	-- Re-asserted on a slow timer: the engine resets MouseBehavior on state changes
	-- (respawn, menu, chat) and a single write would not survive those.
	lockClock += deltaTime
	if lockClock >= LOCK_CFG.RepairInterval then
		lockClock = 0
		applyCameraLock()
	end
end)

-- Menu transitions are instant: a click must never land on a locked camera.
player:GetAttributeChangedSignal(ATTR.ChoiceOpen):Connect(applyCameraLock)

applyCameraSetup()
applyCameraLock()

-- ---------------------------------------------------------------------------
-- Camera FX: trauma shake + FOV punch + swing roll
-- ---------------------------------------------------------------------------

local shakeRng = Random.new(DateTime.now().UnixTimestampMillis % 2 ^ 31)
local trauma = 0
local fovKick = 0
local rollKick = 0
local baseFov = camera.FieldOfView

--[[
	Camera kicks all route through these three helpers, which is why the global feel
	multipliers live here: ShakeScale / FovScale / RollScale dial the entire camera
	language from one place instead of needing every call site retuned.
]]
local function addTrauma(amount: number)
	trauma = math.clamp(trauma + amount * CAMERA_CFG.ShakeScale, 0, 1)
end

local function addFov(degrees: number)
	fovKick += degrees * CAMERA_CFG.FovScale
end

local function addRoll(degrees: number)
	rollKick += degrees * CAMERA_CFG.RollScale
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
			-- Roll reads as nausea far sooner than pitch/yaw do, so it is damped.
			math.rad(shakeRng:NextNumber(-1, 1) * CAMERA_CFG.MaxShakeDegrees * amplitude * CAMERA_CFG.ShakeRollDamping)
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

--[[
	The mid-air jump's signature: a flat shockwave at the feet, a breath of upward
	drift and a small outward scatter. Purely local -- the server never hears about
	it -- and everything here dies on its own, so a chain of air jumps cannot pile
	parts up in the workspace.
]]
local function airJumpPuff(root: BasePart)
	-- The feet, not the root: a HumanoidRootPart floats about two studs up the body
	-- on both R6 and R15, and a puff from the chest reads as a bug.
	local position = root.Position - Vector3.new(0, 2, 0)

	local disc = Instance.new("Part")
	disc.Name = "CB_AirJumpRing"
	-- A cylinder's axis runs along X, so this stands it up as a flat disc.
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.1, 3.2, 3.2)
	disc.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	disc.Material = Enum.Material.Neon
	disc.Color = FXCFG.AirJumpColor
	disc.Transparency = 0.25
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.Anchored = true
	disc.CastShadow = false
	disc.Parent = workspace

	TweenService:Create(disc, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.1, 6.2, 6.2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(disc, 0.5)

	-- Drift rising off the kick: the one particle shape that says "pushed off"
	-- rather than "hit", which keeps the jump from reading as an impact.
	local drift = Instance.new("ParticleEmitter")
	drift.Name = "CB_AirJumpDrift"
	drift.Color = ColorSequence.new(FXCFG.AirJumpColor)
	drift.Lifetime = NumberRange.new(0.25, 0.45)
	drift.Speed = NumberRange.new(6, 13)
	drift.SpreadAngle = Vector2.new(24, 24)
	drift.Acceleration = Vector3.new(0, 14, 0)
	drift.Rate = 0
	drift.LightEmission = 0.8
	drift.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	drift.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	drift.Parent = disc
	drift:Emit(14)

	-- Plus the outward sparks every other hit in the game already speaks.
	sparkBurst(position, FXCFG.AirJumpColor, 10, 14)
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
	shoulder: JointKind?,
	baseOffset: CFrame?,
	trail: Trail?,
	-- White core ribbon inside the coloured one; created locally if the server's
	-- blade replicated before the glow upgrade.
	coreTrail: Trail?,
}

-- Mirrors KatanaFactory's grip frame so a client-side repair weld lines up.
local GRIP_OFFSET = CFrame.new(0, 0.3, -0.1) * CFrame.Angles(math.rad(180), 0, 0)

local swords: { [Model]: SwordRig } = {}

--[[
	Joint offset accessors.
	A Motor6D is posed through C0; an AnimationConstraint has no C0/C1 pair, only
	its Transform, which is also the property the Animator writes. Both are read
	and written through these two functions so every pose in this file works on a
	rig of either generation.
]]
local function jointOffset(joint: JointKind): CFrame
	return if joint:IsA("Motor6D") then joint.C0 else joint.Transform
end

local function setJointOffset(joint: JointKind, offset: CFrame)
	if joint:IsA("Motor6D") then
		joint.C0 = offset
	else
		joint.Transform = offset
	end
end

local function findJoint(character: Model, names: { string }): JointKind?
	for _, name in names do
		for _, descendant in character:GetDescendants() do
			if (descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint")) and descendant.Name == name then
				return descendant
			end
		end
	end
	return nil
end

--[[
	getRightShoulder(character)
	---------------------------
	The joint that carries the sword arm, newest rig convention first:

	  1. R15 / Rthro -- RightUpperArm.RightShoulder
	  2. R6           -- Torso["Right Shoulder"]
	  3. Any Motor6D or AnimationConstraint with "shoulder" in its name, for a
	     custom or tool rig that names its joints its own way.

	Returns nil on a rig with no shoulder at all; every caller treats that as
	"nothing to pose" and keeps the blade-only feedback instead.
]]
local function getRightShoulder(character: Model): JointKind?
	local rightUpperArm = character:FindFirstChild("RightUpperArm")
	if rightUpperArm then
		local joint = rightUpperArm:FindFirstChild("RightShoulder")
		if joint and (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) then
			return joint
		end
	end

	local torso = character:FindFirstChild("Torso")
	if torso then
		local joint = torso:FindFirstChild("Right Shoulder")
		if joint and (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) then
			return joint
		end
	end

	for _, name in RIG.ShoulderJointNames do
		for _, descendant in character:GetDescendants() do
			if (descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint")) and descendant.Name == name then
				return descendant
			end
		end
	end

	for _, descendant in character:GetDescendants() do
		if
			(descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint"))
			and string.find(string.lower(descendant.Name), "shoulder", 1, true)
		then
			return descendant
		end
	end
	return nil
end

local function findShoulder(character: Model): JointKind?
	return getRightShoulder(character)
end

--[[
	The arm rig every swing pose is built from.

	Deliberately independent of the katana: arms are what a player *sees* attack, so a
	character whose blade has not replicated yet -- or a rig with no sword at all --
	still swings. Joints resolve lazily, and each keeps the rest C0 captured at
	resolve time, so repeated poses can never drift away from the idle stance.
]]
--[[
	A joint paired with the rest offset it was born with.
	Every pose is written to the joint's own offset -- C0 on a Motor6D, Transform on
	an AnimationConstraint -- never to `Motor6D.Transform` on a Motor6D: the default
	`Animate` script and every playing track own that property and rewrite it each
	frame, so a script pose written there never survives to render.
]]
type PoseJoint = {
	joint: JointKind,
	-- Captured once, when the rig is first resolved; poses multiply onto it and can
	-- therefore never drift away from the idle stance.
	rest: CFrame,
}

type ArmRig = {
	shoulder: PoseJoint?,
	elbow: PoseJoint?,
	waist: PoseJoint?,
	wrist: PoseJoint?,
}

local armRigs: { [Model]: ArmRig } = {}

--[[
	Active arm override state, all per character.

	  armHolds      -- the joint offset this system last wrote. Re-asserted after
	                   the Animator every frame for as long as an action owns the
	                   rig, so a pose can never be half-overwritten by an idle or
	                   a locomotion track.
	  armDrives     -- joints currently interpolating towards a beat.
	  armSuppressed -- idle/tool tracks, with the weight to hand back when the
	                   action ends.
	  armOverride   -- which action owns the rig, and when the override expires
	                   (a safety net; normal paths end explicitly).
]]
local armHolds: { [Model]: { [JointKind]: CFrame } } = {}
local armDrives: { [Model]: { [JointKind]: JointDrive } } = {}
local armSuppressed: { [Model]: { [AnimationTrack]: number } } = {}
local armOverride: { [Model]: { serial: number, expiresAt: number } } = {}

--[[
	Track names that fight a script pose.
	The default `Animate` script keeps an idle (and a tool grip) playing under an
	attack, and those tracks write the very same joints -- the arm ends up halfway
	between the two poses. Their weight is held at zero for the duration of an
	action instead. Add "walk"/"run" here if a swing is ever read mid-stride.
]]
local SUPPRESSED_TRACK_PARTS = { "idle", "tool" }

-- Captures a joint's rest offset (nil-safe, so a rig without an elbow is fine).
local function poseJoint(joint: JointKind?): PoseJoint?
	if not joint then
		return nil
	end
	return { joint = joint, rest = jointOffset(joint) }
end

local function getArmRig(character: Model): ArmRig?
	local cached = armRigs[character]
	if cached then
		local held = cached.shoulder
		if held and held.joint.Parent then
			return cached
		end
	end

	local shoulder = findShoulder(character)
	if not shoulder then
		return nil
	end

	local rig: ArmRig = {
		shoulder = poseJoint(shoulder),
		elbow = poseJoint(findJoint(character, RIG.ElbowJointNames)),
		waist = poseJoint(findJoint(character, RIG.WaistJointNames)),
		wrist = poseJoint(findJoint(character, RIG.WristJointNames)),
	}
	armRigs[character] = rig
	return rig
end

local function findHand(character: Model): BasePart?
	for _, name in RIG.HandNames do
		local found = character:FindFirstChild(name)
		if found and found:IsA("BasePart") then
			return found
		end
	end
	return nil
end

--[[
	Ensures the katana is welded to the right hand. The server normally builds
	this Motor6D; this local repair only fires if the weld is genuinely missing
	(partial replication), so the blade is never left floating.
]]
local function ensureKatanaWeld(character: Model)
	local model = character:FindFirstChild(RIG.KatanaName)
	if not model or not model:IsA("Model") then
		return
	end
	local handle = model:FindFirstChild("Handle")
	local hand = findHand(character)
	if not handle or not handle:IsA("BasePart") or not hand then
		return
	end

	local existing = hand:FindFirstChild(RIG.KatanaGripName)
	if existing and existing:IsA("Motor6D") and existing.Part0 == hand and existing.Part1 == handle then
		return
	end
	if existing then
		existing:Destroy()
	end

	local weld = Instance.new("Motor6D")
	weld.Name = RIG.KatanaGripName
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = GRIP_OFFSET
	weld.C1 = CFrame.new()
	weld.Parent = hand
end

--[[
	Local repair for the blade's core ribbon.
	Only the server owns the katana, but a missing ribbon is pure presentation: the
	client may build its own copy without touching server state.
]]
local function ensureClientCoreTrail(blade: BasePart, trail: Trail): Trail?
	local found = blade:FindFirstChild("SlashTrailCore")
	if found and found:IsA("Trail") then
		return found
	end
	if not trail.Attachment0 or not trail.Attachment1 then
		return nil
	end

	local clone = trail:Clone()
	clone.Name = "SlashTrailCore"
	clone.Lifetime = TRAIL_CFG.Lifetime
	clone.LightEmission = TRAIL_CFG.LightEmission
	clone.Color = ColorSequence.new(TRAIL_CFG.CoreColor)
	clone.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, TRAIL_CFG.CoreTransparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	clone.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, TRAIL_CFG.CoreWidthScale),
		NumberSequenceKeypoint.new(1, TRAIL_CFG.CoreWidthScale * 0.15),
	})
	clone.Enabled = false
	clone.Parent = blade
	return clone
end

--[[
	Resolves the sword rig for a character.
	A rig is only memoized once its shoulder joint is known, so a character whose
	arms replicate a frame late is re-resolved on the next swing instead of being
	frozen in a permanently un-posable state.
]]
local function getSword(character: Model): SwordRig?
	local cached = swords[character]
	if cached and cached.model.Parent == character and cached.shoulder and cached.baseOffset then
		return cached
	end

	local model = character:FindFirstChild(RIG.KatanaName)
	if not model or not model:IsA("Model") then
		return nil
	end
	local blade = model:FindFirstChild("Blade")
	local trail = blade and blade:FindFirstChild("SlashTrail")
	local shoulder = findShoulder(character)

	local primary: Trail? = if trail and trail:IsA("Trail") then trail else nil
	local core: Trail? = nil
	if primary and blade and blade:IsA("BasePart") then
		core = ensureClientCoreTrail(blade, primary)
	end

	local rig: SwordRig = {
		model = model,
		shoulder = shoulder,
		baseOffset = if shoulder then jointOffset(shoulder) else nil,
		trail = primary,
		coreTrail = core,
	}
	if shoulder and rig.baseOffset then
		swords[character] = rig
	end
	return rig
end

local function poseCFrame(pose: Pose, alpha: number): CFrame
	-- `POSE_FLIP` is the one-line mirror fix for a rig whose shoulder axes run the
	-- other way; it is 1/1/1 unless a rig needed flipping.
	return CFrame.Angles(
		math.rad(pose.x * alpha * POSE_FLIP.x),
		math.rad(pose.y * alpha * POSE_FLIP.y),
		math.rad(pose.z * alpha * POSE_FLIP.z)
	)
end

local REST_POSE: Pose = { x = 0, y = 0, z = 0 }
local SWING_RIG = CombatConfig.SwingRig

type JointTarget = { joint: JointKind, goal: CFrame }

--[[
	Joint targets for one beat of a swing.
	The shoulder takes the beat's pose (already in the shoulder's own frame); the
	forearm fold, wrist snap and torso turn come from CombatConfig.SwingRig, because
	the pose tables carry no forearm or torso information -- without them a clip-less
	swing reads as one stiff bone. Rigs without those joints simply produce fewer
	targets. Every goal is `rest * offset`, so a pose is always relative to the rig's
	own rest stance and can never accumulate drift.
]]
local function swingBeat(rig: ArmRig, pose: Pose, phase: string, alternate: boolean): { JointTarget }
	local targets: { JointTarget } = {}

	-- Shoulder
	local shoulder = rig.shoulder
	if shoulder then
		table.insert(targets, { joint = shoulder.joint, goal = shoulder.rest * poseCFrame(pose, 1) })
	end

	-- Elbow
	local elbow = rig.elbow
	if elbow then
		local fold = if phase == "Windup"
			then SWING_RIG.ElbowFold
			elseif phase == "Impact" then SWING_RIG.ElbowExtend
			elseif phase == "Guard" then SWING_RIG.ElbowGuard
			else 0
		if alternate then fold *= 0.75 end
		table.insert(targets, { joint = elbow.joint, goal = elbow.rest * CFrame.Angles(math.rad(fold), 0, 0) })
	end

	-- Wrist
	local wrist = rig.wrist
	if wrist then
		local flick = if phase == "Windup"
			then SWING_RIG.WristFlick
			elseif phase == "Impact" then SWING_RIG.WristSnap
			else 0
		if alternate then flick *= -1 end
		table.insert(targets, { joint = wrist.joint, goal = wrist.rest * CFrame.Angles(math.rad(flick), 0, 0) })
	end

	-- Waist
	local waist = rig.waist
	if waist then
		local turn = if phase == "Windup"
			then SWING_RIG.WaistBack
			elseif phase == "Impact" then SWING_RIG.WaistThrough
			else 0
		if alternate then turn *= -1 end
		table.insert(targets, { joint = waist.joint, goal = waist.rest * CFrame.Angles(0, math.rad(turn), 0) })
	end

	return targets
end

--[[
	Snaps a beat into place and parks the frame override on it.
	The impact frame must never be interpolated through, so a snap also cancels the
	joint's drive. The hold is what makes the snap stick: it is re-asserted after
	the Animator every frame for as long as an action owns the rig.
]]
local function applyArmTargets(character: Model, targets: { JointTarget })
	local holds = armHolds[character]
	if not holds then
		holds = {}
		armHolds[character] = holds
	end
	local drives = armDrives[character]
	for _, target in targets do
		if drives then
			drives[target.joint] = nil
		end
		holds[target.joint] = target.goal
		setJointOffset(target.joint, target.goal)
	end
end

--[[
	Starts a joint drive: the frame loop walks the joint from wherever it is now to
	`goal` over `duration`, and the joint's hold follows the interpolated value so
	the same pose can be re-asserted after the Animator runs. Interpolation lives
	here rather than in TweenService because a tween's write has no defined order
	against the animation step; this has.
]]
local function driveJoint(
	character: Model,
	joint: JointKind,
	goal: CFrame,
	duration: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection
)
	local holds = armHolds[character]
	if not holds then
		holds = {}
		armHolds[character] = holds
	end
	holds[joint] = goal

	local drives = armDrives[character]
	if duration <= 0.01 then
		if drives then
			drives[joint] = nil
		end
		setJointOffset(joint, goal)
		return
	end
	if not drives then
		drives = {}
		armDrives[character] = drives
	end
	drives[joint] = {
		from = jointOffset(joint),
		to = goal,
		startedAt = now(),
		duration = duration,
		style = style,
		direction = direction,
	}
end

-- Animated beat; throws nothing, so a rig without an elbow still swings.
local function tweenArmTargets(
	character: Model,
	targets: { JointTarget },
	duration: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection
)
	for _, target in targets do
		driveJoint(character, target.joint, target.goal, duration, style, direction)
	end
end

--[[
	Switches both blade ribbons on/off.
	`serial` is the swing that owns the ribbon: a newer cut cancels the older
	switch-off, so a fast combo cannot leave a blade burning while it idles.
]]
local function setTrailEnabled(rig: SwordRig, enabled: boolean, duration: number?, serial: number?)
	local function apply(state: boolean)
		local trail = rig.trail
		if trail and trail.Parent then
			trail.Enabled = state
		end
		local core = rig.coreTrail
		if core and core.Parent then
			core.Enabled = state
		end
	end

	apply(enabled)

	if enabled and duration and duration > 0 then
		task.delay(duration, function()
			if serial == nil or trailSerial[rig.model] == serial then
				apply(false)
			end
		end)
	end
end

-- Drops every in-flight drive for a character. The joints stay where they are:
-- the next beat drives from the live pose, exactly like a cancelled Tween did.
local function cancelArmTween(character: Model)
	armDrives[character] = nil
end

--[[
	Hands the default rig layers their weight back.
	Called from the end of every action, and from the frame loop when an override
	runs past its safety window without one.
]]
local function endArmOverride(character: Model, serial: number?)
	local current = armOverride[character]
	if serial ~= nil and (not current or current.serial ~= serial) then
		return
	end
	armOverride[character] = nil
	armDrives[character] = nil
	armHolds[character] = nil

	local saved = armSuppressed[character]
	if not saved then
		return
	end
	armSuppressed[character] = nil
	for track, weight in saved do
		pcall(function()
			if track.IsPlaying then
				track:AdjustWeight(weight, 0)
			end
		end)
	end
end

--[[
	Weights the default rig layers out of the way.
	The `Animate` script keeps its idle (and its tool grip) playing under an attack,
	and those tracks write the same joints a pose does -- so the arm ends up halfway
	between the two. Zeroing their weight leaves the procedural pose (or an Action4
	clip) as the only thing driving the arm, and the weight each track had is kept
	so resuming hands back exactly what the rig was doing.
]]
local function suppressIdleTracks(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	local saved = armSuppressed[character]
	if not saved then
		saved = {}
		armSuppressed[character] = saved
	end

	for _, track in animator:GetPlayingAnimationTracks() do
		local name = string.lower(track.Name)
		local fights = false
		for _, part in SUPPRESSED_TRACK_PARTS do
			if string.find(name, part, 1, true) then
				fights = true
				break
			end
		end
		if fights then
			if saved[track] == nil then
				-- `WeightCurrent`, not `Weight`: an AnimationTrack has no `Weight` member, and
				-- reading it here would throw outside the pcall below and abort the override.
				saved[track] = track.WeightCurrent
			end
			if track.WeightCurrent > 0 then
				pcall(function()
					track:AdjustWeight(0, 0)
				end)
			end
		end
	end
end

--[[
	Starts an override and returns the serial that owns it.
	`lifetime` bounds an override that may outlive its own callbacks -- a safety net
	for an interrupted action, not the normal exit; nil means it runs until something
	ends it (a guard stance is held for as long as the key is down). Deferred
	callbacks pass the serial back to `endArmOverride`, so a stale timer can never
	steal the arm from a newer action.
]]
local function beginArmOverride(character: Model, lifetime: number?): number
	local current = armOverride[character]
	local serial = if current then current.serial + 1 else 1
	armOverride[character] = {
		serial = serial,
		expiresAt = if lifetime then now() + lifetime else math.huge,
	}
	suppressIdleTracks(character)
	return serial
end

-- The serial that currently owns a character's arm, if any.
local function armOverrideToken(character: Model): number?
	local current = armOverride[character]
	return if current then current.serial else nil
end

--[[
	Easing curves the beats use, evaluated per frame by the driver.
	Quad and Quart are the only styles the pose tables ask for; anything else falls
	back to a cubic out, close enough that a beat can be retimed without touching
	this table.
]]
local function easeAlpha(style: Enum.EasingStyle, direction: Enum.EasingDirection, alpha: number): number
	local t = math.clamp(alpha, 0, 1)
	if direction == Enum.EasingDirection.InOut then
		if t < 0.5 then
			return 0.5 * easeAlpha(style, Enum.EasingDirection.In, t * 2)
		end
		return 0.5 + 0.5 * easeAlpha(style, Enum.EasingDirection.Out, (t - 0.5) * 2)
	end
	local x = if direction == Enum.EasingDirection.In then t else 1 - t
	local eased = if style == Enum.EasingStyle.Linear
		then x
		elseif style == Enum.EasingStyle.Quart then x * x * x * x
		else x * x
	return if direction == Enum.EasingDirection.In then eased else 1 - eased
end

--[[
	The frame override itself.
	PreSimulation runs after the Animator has evaluated the frame and before that
	frame is simulated and drawn, which is the one window where a script-written
	joint offset is guaranteed to be the last word on the frame. Every held joint is
	re-asserted here for as long as an action owns the rig, and a beat's walk towards
	its goal is computed here too, so nothing can land on the wrong side of the
	Animator.
]]
RunService.PreSimulation:Connect(function()
	local timestamp = now()
	for character, holds in armHolds do
		local drives = armDrives[character]
		for joint, hold in holds do
			if joint.Parent then
				local drive = drives and drives[joint]
				if drive then
					local alpha = math.clamp((timestamp - drive.startedAt) / drive.duration, 0, 1)
					hold = drive.from:Lerp(drive.to, easeAlpha(drive.style, drive.direction, alpha))
					holds[joint] = hold
					if alpha >= 1 then
						drives[joint] = nil
					end
				end
				setJointOffset(joint, hold)
			end
		end

		local claim = armOverride[character]
		if claim then
			suppressIdleTracks(character)
			if timestamp >= claim.expiresAt then
				endArmOverride(character, claim.serial)
			end
		end
	end
end)

--[[
	Snaps every joint of a character's rig back onto its captured rest offset.
	Used where an authored clip takes over the arms (the clip owns the rotation, so a
	leftover procedural pose must not stack under it) and when a body dies, because
	the rig is cached per character and a stale pose would otherwise outlive the swing
	that wrote it. The rest offset becomes the held pose, so the override keeps
	re-asserting it while the clip plays.
]]
local function restoreArmPose(character: Model)
	cancelArmTween(character)
	local rig = armRigs[character]
	if not rig then
		return
	end
	local slots: { PoseJoint? } = { rig.shoulder, rig.elbow, rig.waist, rig.wrist }
	local targets: { JointTarget } = {}
	for _, slot in slots do
		if slot then
			table.insert(targets, { joint = slot.joint, goal = slot.rest })
		end
	end
	applyArmTargets(character, targets)
end

--[[
	Resolves a blade endpoint for the arc Beam, current name first.
	The server owns the katana, but the arc is pure presentation: a blade built by
	an older revision carries the legacy names, and both are accepted so no second
	attachment is ever minted next to a live one.
]]
local function ensureBladeAttachment(blade: BasePart, names: { string }, y: number): Attachment
	for _, name in names do
		local found = blade:FindFirstChild(name)
		if found and found:IsA("Attachment") then
			return found
		end
	end
	local created = Instance.new("Attachment")
	created.Name = names[1]
	created.Position = Vector3.new(0, y, 0)
	created.Parent = blade
	return created
end

--[[
	Paints a temporary slash ribbon across the blade for this swing.
	Falls back to a Beam between the hilt and tip so the cut is obvious even if
	the katana's built-in Trail is missing.
]]
local function spawnSlashArc(character: Model, color: Color3?)
	local model = character:FindFirstChild(RIG.KatanaName)
	if not model or not model:IsA("Model") then
		return
	end
	local bladeInstance = model:FindFirstChild("Blade")
	if not bladeInstance or not bladeInstance:IsA("BasePart") then
		return
	end
	local blade = bladeInstance :: BasePart

	local hilt = ensureBladeAttachment(blade, RIG.HiltAttachmentNames, -1.65)
	local tip = ensureBladeAttachment(blade, RIG.TipAttachmentNames, 1.65)

	local beam = Instance.new("Beam")
	beam.Name = "CB_SlashArc"
	beam.Attachment0 = hilt
	beam.Attachment1 = tip
	beam.FaceCamera = true
	beam.LightEmission = 0.65
	beam.Width0 = 0.5
	beam.Width1 = 1.1
	beam.Color = ColorSequence.new(color or FXCFG.SlashColor)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.6),
	})
	beam.Parent = blade
	Debris:AddItem(beam, 0.22)
end

--[[
	One swing, beats written to C0: out -> hold -> back (see CombatConfig.Procedural).

	An authored clip (CombatConfig.Animations + the shared Animations module) drives
	the arms when one is configured. Otherwise the swing is procedural: the shoulder
	takes the beat's pose, the forearm folds and drives from CombatConfig.SwingRig, and
	the torso turns away then through it. Works on R6 (shoulder only) and R15 (shoulder
	+ elbow + wrist + waist). The blade's ribbons and arc fire on the beat the hitbox
	resolves either way.
]]
local function playSwing(character: Model, stepIndex: number, attackSpeed: number, color: Color3?)
	local serial = (trailSerial[character] or 0) + 1
	trailSerial[character] = serial

	local step = CombatConfig.getComboStep(stepIndex)
	local speed = math.max(attackSpeed, 0.2)
	local windup = math.max(step.windup / speed, 0.02)
	local recovery = math.max(step.recovery / speed, 0.02)

	local sword = getSword(character)
	if sword and sword.trail and color then
		sword.trail.Color = ColorSequence.new(color)
	end

	--[[
		The blade's ribbons belong to the cut, not to the stance: switched on as the
		blade starts travelling and off again the moment the arm eases home, so an
		idle sword is always dark. `serial` keeps a newer cut authoritative over an
		older one's delayed switch-off.
	]]
	local function ribbon(enabled: boolean, duration: number?)
		if sword then
			setTrailEnabled(sword, enabled, duration, serial)
		end
	end

	-- Ribbon + arc, fired on the beat the blade would connect. The finisher's camera
	-- kick rides this beat too: it belongs on the slam, not on the click.
	local function impactBlade()
		ribbon(true, math.min(0.16, recovery))
		spawnSlashArc(character, color)
		if step.kind == "Heavy" and character == player.Character then
			addFov(step.fovKick * 0.7)
			addRoll(-3.5)
		end
	end

	-- A held guard stance yields the instant a swing starts.
	Animations.stop(character, "Guard", 0.08)

	--[[
		The whole action owns the rig from here: the default idle/tool layers are
		weighted out, and the safety window outlives the beat timeline so even an
		interrupted swing hands the rig back on its own.
	]]
	local overrideToken = beginArmOverride(character, windup + recovery + 0.75)

	--[[
		1. A clip owns the arms when one resolves: the authored clip first, then
		Roblox's own stock sword slash, which requires no asset ownership and loads
		for every account. Both play at Action4 -- above every layer the default
		`Animate` script uses -- so the swing takes over idle and locomotion rather
		than blending with them. `restoreArmPose` drops any procedural pose left on
		the shoulder, or the two rotations would stack.
	]]
	local clipKey = if step.kind == "Heavy"
		then "Heavy"
		elseif stepIndex % 2 == 0 then "Slash2"
		else "Slash1"
	local stockKey = if step.kind == "Heavy" then "StockHeavy" else "StockSlash"
	local clipSpeed = math.clamp(speed, 0.4, 3)
	local track = Animations.play(character, clipKey, "Player", 0.08, clipSpeed, 1, Enum.AnimationPriority.Action4)
	local playingKey = clipKey
	if not track then
		track = Animations.play(character, stockKey, "Stock", 0.08, clipSpeed, 1, Enum.AnimationPriority.Action4)
		playingKey = stockKey
	end
	if track then
		restoreArmPose(character)
		task.delay(windup, function()
			if trailSerial[character] == serial then
				impactBlade()
			end
		end)
		task.delay(windup + recovery, function()
			Animations.stop(character, playingKey, 0.16)
			endArmOverride(character, overrideToken)
		end)
		return
	end

	-- 2. Procedural fallback: no clip authored or loadable at all. Shoulder +
	-- forearm + torso beats, held on each joint's own offset and re-asserted after
	-- the Animator every frame, so the default Animate script cannot overwrite the
	-- pose on the frame it is written.
	local armRig = getArmRig(character)
	if not armRig then
		-- No posable joints at all: still flash a blade arc so the cut reads.
		spawnSlashArc(character, color)
		endArmOverride(character, overrideToken)
		return
	end

	local beat = PROCEDURAL.Combo[stepIndex] or PROCEDURAL.Combo[1]
	local alternate = step.kind ~= "Heavy" and stepIndex % 2 == 0
	local outTime = math.max(beat.out / speed, 0.02)
	local holdTime = math.max(beat.hold / speed, 0.01)
	local backTime = math.max(beat.back / speed, 0.05)
	local heavy = step.kind == "Heavy"

	-- Ribbon off, arm home, rest pose snapped once the tween lands.
	local function easeHome()
		ribbon(false)
		tweenArmTargets(
			character,
			swingBeat(armRig, REST_POSE, "Rest", false),
			backTime,
			Enum.EasingStyle.Quart,
			Enum.EasingDirection.Out
		)
		task.delay(backTime + 0.02, function()
			if trailSerial[character] == serial then
				applyArmTargets(character, swingBeat(armRig, REST_POSE, "Rest", false))
				endArmOverride(character, overrideToken)
			end
		end)
	end

	cancelArmTween(character)

	if not heavy then
		--[[
			Light slash: accelerate into the cut pose, park it through the impact (so
			the blade is inside the target when the hitbox resolves), then ease home.
			The pose is the cut: the impact beat only re-aims the forearm, wrist and
			torso, never the shoulder, so the blade never jumps mid-swing.
		]]
		local impactAt = math.max(windup, outTime)
		local holdEnds = math.max(outTime + holdTime, impactAt)

		ribbon(true, holdEnds + 0.06)
		tweenArmTargets(
			character,
			swingBeat(armRig, beat.pose, "Windup", alternate),
			outTime,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		)

		task.delay(impactAt, function()
			if trailSerial[character] ~= serial then
				return
			end
			cancelArmTween(character)
			applyArmTargets(character, swingBeat(armRig, beat.pose, "Impact", alternate))
			impactBlade()
		end)

		task.delay(holdEnds, function()
			if trailSerial[character] ~= serial then
				return
			end
			cancelArmTween(character)
			easeHome()
		end)
		return
	end

	--[[
		Heavy finisher: raise the blade overhead, hold the top of the arc for the
		wind-up pause, then slam. The slam is scheduled to land on the server's windup
		-- 0.06s of travel, punch and all -- and never before the raise is up.
	]]
	local raisePose: Pose = beat.raise or beat.pose
	local slamTime = math.max((beat.slam or 0.06) / speed, 0.02)
	local slamStarts = math.max(outTime + holdTime, windup - slamTime)
	local slamEnds = slamStarts + slamTime

	tweenArmTargets(
		character,
		swingBeat(armRig, raisePose, "Windup", false),
		outTime,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)

	task.delay(slamStarts, function()
		if trailSerial[character] ~= serial then
			return
		end
		ribbon(true, slamTime + 0.14)
		cancelArmTween(character)
		tweenArmTargets(
			character,
			swingBeat(armRig, beat.pose, "Impact", false),
			slamTime,
			Enum.EasingStyle.Quart,
			Enum.EasingDirection.In
		)
	end)

	task.delay(slamEnds, function()
		if trailSerial[character] ~= serial then
			return
		end
		cancelArmTween(character)
		applyArmTargets(character, swingBeat(armRig, beat.pose, "Impact", false))
		impactBlade()
		easeHome()
	end)
end

--[[
	Parry / guard stance, driven by input feel.
	A configured "Guard" clip owns the arms when one exists -- a procedural pose
	must not run beside it, or the two fight over the same joints. Otherwise the
	stance is driven in over `duration`: 0.05s for a parry, because the window is
	only 0.2s long and the blade has to be up before it opens.
]]
local function poseGuard(character: Model, pose: Pose, duration: number)
	-- No expiry: a guard lasts as long as the key is held, and the settle that
	-- ends the stance is what ends the override.
	beginArmOverride(character, nil)

	local track = Animations.play(character, "Guard", "Player", 0.12, 1, 1, Enum.AnimationPriority.Action4)
	if track then
		restoreArmPose(character)
		return
	end

	local rig = getArmRig(character)
	if not rig then
		return
	end
	-- The stance always wins over an in-flight swing tween.
	cancelArmTween(character)
	tweenArmTargets(
		character,
		swingBeat(rig, pose, "Guard", false),
		duration,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)
end

--[[
	Eases the sword arm home and ends the stance's ownership of the rig.
	`duration` is the settle time -- the parry spec calls for 0.15s, a swing uses its
	own recovery -- and the rest pose is snapped at the end, so an interrupted drive
	can never leave the shoulder fractionally off its rest offset.
]]
local function settleToRest(character: Model, duration: number)
	-- Captured now: if a newer action claims the rig before this settle lands, the
	-- deferred end below is discarded instead of stealing that action's arm.
	local token = armOverrideToken(character)
	local rig = getArmRig(character)
	if not rig then
		endArmOverride(character, token)
		return
	end
	Animations.stop(character, "Guard", 0.15)
	cancelArmTween(character)
	tweenArmTargets(
		character,
		swingBeat(rig, REST_POSE, "Rest", false),
		duration,
		Enum.EasingStyle.Quart,
		Enum.EasingDirection.Out
	)
	task.delay(math.max(duration, 0.01) + 0.02, function()
		local live = armRigs[character]
		if live and live.shoulder and live.shoulder.joint.Parent then
			applyArmTargets(character, swingBeat(live, REST_POSE, "Rest", false))
		end
		endArmOverride(character, token)
	end)
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
		if INPUT_DEBUG then
			print("[CombatController][Input] attack refused: perk overlay is open")
		end
		return
	end

	local character, humanoid, root = myCharacter()
	if not character or not humanoid or not root then
		if INPUT_DEBUG then
			print("[CombatController][Input] attack refused: no live character")
		end
		return
	end

	local timestamp = now()
	if timestamp < state.attackLockUntil then
		if INPUT_DEBUG then
			print("[CombatController][Input] attack refused: still recovering")
		end
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
	-- A swing takes the arm over from any parry stance still holding it: without this
	-- the stance's window timer would cancel the cut and drag the blade home mid-swing.
	state.parrySerial += 1
	state.parryStanceUntil = 0
	-- Bounded: a rejected request must never leave the counter stuck above zero.
	state.predictedSwings = math.min(state.predictedSwings + 1, 3)

	if INPUT_DEBUG then
		print(`[CombatController][Input] [LMB] slash {stepIndex} "{step.name}" ({step.kind}) at speed {string.format("%.2f", speed)}`)
	end

	-- Predict the swing locally so the blade moves on the same frame as the click.
	playSwing(character, stepIndex, speed)
	swingLunge(stepIndex)
	playOneShot(step.swingSound, 0.5, 1, root)
	addTrauma(step.shake * 0.55)
	if step.kind == "Heavy" then
		-- The finisher's FOV punch belongs to the slam, not to the click: playSwing
		-- fires it with the impact pose (see impactBlade).
		addRoll(-3.5)
	else
		addFov(step.fovKick * 0.7)
		addRoll(-1.5)
	end

	attackRemote:FireServer(stepIndex)

	-- Local impact beat, so a whiff still lands in the hand. The Hit FX adds more
	-- when the blade actually connects.
	task.delay(windup, function()
		addTrauma(step.shake * 0.5)
		if step.kind ~= "Heavy" then
			addFov(step.fovKick * 0.5)
		end
		addRoll(if step.kind == "Heavy" then -2.5 else -1)
		playOneShot(step.hitSound, 0.3, if step.kind == "Heavy" then 0.85 else 1.15, root)
	end)
end

local function submitParry()
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		if INPUT_DEBUG then
			print("[CombatController][Input] parry refused: perk overlay is open")
		end
		return
	end

	local character, humanoid, root = myCharacter()
	if not humanoid or not root then
		if INPUT_DEBUG then
			print("[CombatController][Input] parry refused: no live character")
		end
		return
	end

	local timestamp = now()
	if timestamp < state.parryCooldownUntil then
		if INPUT_DEBUG then
			print("[CombatController][Input] parry refused: on cooldown")
		end
		return
	end
	if timestamp < state.attackLockUntil then
		if INPUT_DEBUG then
			print("[CombatController][Input] parry refused: mid-swing")
		end
		return
	end

	local window = attrNumber(ATTR.ParryWindow, CombatConfig.Timings.ParryWindow)
	-- Mirror the server's post-perk cooldown so local feedback never lies.
	state.parryCooldownUntil = timestamp + attrNumber(ATTR.ParryCooldown, CombatConfig.Timings.ParryCooldown)
	player:SetAttribute(ATTR.ParryReadyAt, state.parryCooldownUntil)
	state.guarding = false

	--[[
		The stance: tweened in fast (0.05s), held for the whole window, then either
		extended by a clash or eased home over 0.15s. `parrySerial` is what keeps the
		window's timer and a clash's timer mutually exclusive.
	]]
	state.parryStanceUntil = timestamp + math.max(window, PARRY_BEAT.out + PARRY_BEAT.hold)
	state.parrySerial += 1
	local serial = state.parrySerial

	if INPUT_DEBUG then
		print(`[CombatController][Input] [F] parry stance up: window {string.format("%.2f", window)}s`)
	end

	if character then
		poseGuard(character, PARRY_BEAT.pose, PARRY_BEAT.out)
	end
	addFov(-2.5)
	addRoll(2)
	playOneShot(FXCFG.ParryClashAccent, 0.25, 1.6, root)

	parryRemote:FireServer("Parry")

	-- Window expired without a clash: a held key settles into the guard, a tap eases
	-- the blade back down.
	task.delay(window, function()
		if serial ~= state.parrySerial then
			return
		end
		if state.parryHeld then
			state.guarding = true
			state.parryStanceUntil = math.huge
			parryRemote:FireServer("Guard")
			return
		end
		state.parryStanceUntil = 0
		if character then
			settleToRest(character, PARRY_BEAT.back)
		end
	end)
end

local function releaseGuard()
	state.parryHeld = false
	if state.guarding then
		state.guarding = false
		-- The held guard owns the stance for as long as it lasts, so releasing it is
		-- what ends that ownership: without this the blade would stay raised.
		state.parryStanceUntil = 0
		parryRemote:FireServer("Unguard")
	end

	local character = player.Character
	if not character then
		return
	end
	-- Inside the window (or a clash's extra 0.1s) the stance owns itself: its own
	-- timer eases the blade home, so releasing the key early cannot cut it short.
	if now() < state.parryStanceUntil then
		return
	end
	settleToRest(character, PARRY_BEAT.back)
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
	player:SetAttribute(ATTR.DodgeReadyAt, state.dodgeCooldownUntil)
	if INPUT_DEBUG then
		print("[CombatController][Input] [Q/Shift] dodge")
	end

	local direction = if humanoid.MoveDirection.Magnitude > 0.1 then flat(humanoid.MoveDirection) else flat(root.CFrame.LookVector) * -1
	dodgeDash(direction)
	dodgeRemote:FireServer(direction)
end

--[[
	Input: combat actions.
	Every route goes through ContextActionService (so the touch buttons keep
	working), and which key or mouse button an action answers to is owned by
	KeybindManager -- a rebind in the options menu re-binds these actions live, with
	no restart and no second listener to keep in sync. `GetInputs` hands back the
	player's bind plus the static extras (Q for dodge, the gamepad shoulder
	buttons), so the shipped controls never disappear.
]]
local function inputLabel(input: InputObject?): string
	if not input then
		return "?"
	end
	if input.KeyCode ~= Enum.KeyCode.None then
		return input.KeyCode.Name
	end
	return input.UserInputType.Name
end

local function onAttackAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	-- The menu owns the cursor: clicking PLAY must never also swing the sword.
	if menuIsOpen() then
		return Enum.ContextActionResult.Pass
	end
	if INPUT_DEBUG then
		print(`[CombatController][Input] [{inputLabel(inputObject)}] attack`)
	end
	submitAttack()
	return Enum.ContextActionResult.Pass
end

local function onParryAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		if menuIsOpen() then
			return Enum.ContextActionResult.Pass
		end
		if INPUT_DEBUG then
			print(`[CombatController][Input] [{inputLabel(inputObject)}] parry`)
		end
		state.parryHeld = true
		submitParry()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		-- Released unconditionally: a guard let down is always safe, and a key the
		-- menu swallowed on the way down must not stay held.
		if INPUT_DEBUG then
			print(`[CombatController][Input] [{inputLabel(inputObject)}] released ({inputState.Name})`)
		end
		releaseGuard()
	end
	return Enum.ContextActionResult.Pass
end

local function onDodgeAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if menuIsOpen() then
		return Enum.ContextActionResult.Pass
	end
	if INPUT_DEBUG then
		print(`[CombatController][Input] [{inputLabel(inputObject)}] dodge`)
	end
	submitDodge()
	return Enum.ContextActionResult.Pass
end

local keybindsBound = false

local function bindKeybinds()
	if keybindsBound then
		ContextActionService:UnbindAction(ACTIONS.Attack)
		ContextActionService:UnbindAction(ACTIONS.Parry)
		ContextActionService:UnbindAction(ACTIONS.Dodge)
		keybindsBound = false
	end

	-- A rebind mid-guard would strand the stance on a key that no longer exists.
	if state.parryHeld then
		releaseGuard()
	end

	ContextActionService:BindAction(ACTIONS.Attack, onAttackAction, true, table.unpack(KeybindManager:GetInputs("Attack")))
	ContextActionService:BindAction(ACTIONS.Parry, onParryAction, true, table.unpack(KeybindManager:GetInputs("Parry")))
	ContextActionService:BindAction(ACTIONS.Dodge, onDodgeAction, true, table.unpack(KeybindManager:GetInputs("Dodge")))

	ContextActionService:SetTitle(ACTIONS.Attack, "Slash")
	ContextActionService:SetTitle(ACTIONS.Parry, "Parry")
	ContextActionService:SetTitle(ACTIONS.Dodge, "Dodge")
	ContextActionService:SetPosition(ACTIONS.Dodge, UDim2.new(1, -110, 1, -170))
	keybindsBound = true
end

bindKeybinds()
-- Fires with the action that changed, or with nothing after a bulk reset; either
-- way the cheapest correct answer is to rebuild all three bindings.
KeybindManager.OnBindChanged.Event:Connect(bindKeybinds)

-- ---------------------------------------------------------------------------
-- Air jump (the "double jump")
-- ---------------------------------------------------------------------------

--[[
	Faster than this and the body is still climbing on the previous boost.
	JumpRequest is documented to fire twice for a single press, and the engine's
	auto-hop keeps requesting while the key is held; either one would otherwise
	spend the air jump on the same frame the ground jump left. Nothing deliberate
	happens while the body is climbing this fast -- gravity has it near the apex by
	the time the player's second tap lands. That is about the first seventh of a
	second of the hop, and a request refused here costs nothing -- the allowance is
	only spent by a jump that actually fires, so an early tap can simply be repeated.
]]
local AIR_JUMP_MAX_RISE = 26

-- Refills the allowance the moment the feet touch something: landing, running
-- again, sitting, standing up. Everything that means "grounded".
local function bindAirJumpAllowance(humanoid: Humanoid)
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

	--[[
		Both airborne states count. The Humanoid sits in `Jumping` for the first
		frames of a hop before settling into `Freefall`, and a player who taps twice
		quickly is asking for the second jump while still in the first of those. Being
		on the ground is never in question here: a grounded JumpRequest is the engine's
		own jump, and the allowance only refills on landing.
	]]
	local humanoidState = humanoid:GetState()
	if humanoidState ~= Enum.HumanoidStateType.Freefall and humanoidState ~= Enum.HumanoidStateType.Jumping then
		return
	end
	if root.AssemblyLinearVelocity.Y > AIR_JUMP_MAX_RISE then
		return
	end

	-- Base allowance plus every perk that granted one, folded server-side.
	local extraJumps = attrNumber(ATTR.ExtraJumps, CombatConfig.Player.AirJumps)
	if extraJumps <= 0 or state.airJumpsUsed >= extraJumps then
		return
	end

	state.airJumpsUsed += 1
	root.AssemblyLinearVelocity = Vector3.new(
		root.AssemblyLinearVelocity.X,
		CombatConfig.Player.AirJumpImpulse,
		root.AssemblyLinearVelocity.Z
	)
	airJumpPuff(root)
	playOneShot(FXCFG.DodgeWhoosh, 0.3, 1.5, root)
	addFov(4)
	addRoll(-1.5)
end)

local function bindCharacter(character: Model)
	-- Fresh body, fresh combat camera framing.
	applyCameraSetup()
	applyCameraLock()

	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		bindAirJumpAllowance(humanoid)
		-- A body must not keep the last swing's pose on its shoulder after death,
		-- nor the default idle layers weighted out.
		humanoid.Died:Once(function()
			restoreArmPose(character)
			endArmOverride(character)
		end)
	end
	-- Warm the sword cache and repair the grip weld if replication was partial.
	task.delay(0.5, function()
		ensureKatanaWeld(character)
		getSword(character)
		-- The stock fallback clips are Roblox assets that stream on first use:
		-- start them here so a swing never spends its windup waiting on one.
		Animations.track(character, "StockSlash", "Stock", Enum.AnimationPriority.Action4)
		Animations.track(character, "StockHeavy", "Stock", Enum.AnimationPriority.Action4)
	end)
	task.delay(2, function()
		ensureKatanaWeld(character)
		getSword(character)
	end)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

player.CharacterRemoving:Connect(function(character: Model)
	-- Tracks, rigs and swing serials all belong to the body they were bound to.
	endArmOverride(character)
	Animations.forget(character)
	swords[character] = nil
	armRigs[character] = nil
	armDrives[character] = nil
	armHolds[character] = nil
	armSuppressed[character] = nil
	armOverride[character] = nil
	trailSerial[character] = nil
end)

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
			-- The clash owns the stance from here: the window's own timer must not ease
			-- the block home underneath the extra hold.
			state.parrySerial += 1
			state.parryStanceUntil = now() + PARRY_BEAT.successHold
			-- A perfect read shortens the cooldown server-side; mirror it locally
			-- so the HUD's parry badge flips back to ready on time.
			state.parryCooldownUntil = math.min(state.parryCooldownUntil, now() + 0.12)
			player:SetAttribute(ATTR.ParryReadyAt, state.parryCooldownUntil)
			addTrauma(0.85)
			addFov(-5)
			addRoll(6)
			blurPulse(9, 0.22)
			if (fx.amount or 0) > 0 then
				flash(riposteFrame, 0.35, 0.5)
			end
			-- Hold the block 0.1s longer, then ease home over 0.15s. A key still held
			-- settles into the guard instead of dropping the stance.
			task.delay(PARRY_BEAT.successHold, function()
				if state.parryHeld then
					-- A key still held keeps the block, and the server has to hear about it:
					-- the clash cancelled the window timer that would normally send this.
					state.guarding = true
					state.parryStanceUntil = math.huge
					parryRemote:FireServer("Guard")
					return
				end
				state.parryStanceUntil = 0
				if character then
					settleToRest(character, PARRY_BEAT.back)
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
			-- The same stance the local player gets, so a parry reads identically
			-- from either side of a blade.
			poseGuard(character, PARRY_BEAT.pose, PARRY_BEAT.out)
			task.delay(PARRY_BEAT.hold, function()
				settleToRest(character, PARRY_BEAT.back)
			end)
		end
	elseif action == "Dodge" then
		if not isMine and character and character.PrimaryPart then
			sparkBurst(character.PrimaryPart.Position, if fx.shadow then FXCFG.ShadowDashColor else FXCFG.DodgeColor, 12, 10)
		end
	end
end)

print("[CombatController] Blade in hand.")
