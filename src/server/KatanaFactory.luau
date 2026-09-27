--!strict
--[[
	KatanaFactory (server module)
	----------------------------
	Builds the blade strapped to every fighter's right hand -- players and enemies
	alike -- so hitboxes, poses and trails all agree on what a "sword" is.

	The model is created once and replicates normally. Posing is owned by whoever
	animates that character:
	  * enemies -> EnemyAI drives the shoulder joint on the server
	  * players -> every client poses the sword from replicated CombatFx events
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local KatanaFactory = {}

export type Katana = {
	model: Model,
	handle: BasePart,
	blade: BasePart,
	-- Wide coloured ribbon; the swing tell everyone reads.
	trail: Trail,
	-- Thin white core inside the ribbon, which is what sells the "glowing blade".
	coreTrail: Trail?,
	grip: Motor6D,
	hand: BasePart,
	-- Motor6D that lifts the whole arm; nil for exotic custom rigs.
	shoulder: Motor6D?,
	-- Shoulder rest pose, captured so posers can always lerp back home.
	baseShoulderC0: CFrame?,
}

local RIG = CombatConfig.RigParts
local TRAIL_CFG = CombatConfig.Trail
local TRAIL_COLOR = CombatConfig.Fx.SlashColor

type Pose = CombatConfig.Vector3Pose

-- Local frame of the katana, measured from the grip (handle origin, +Y = blade):
--   handle  y 0.00 (length 1.3)   guard y 0.70   blade y 0.70 -> 4.00
local GUARD_OFFSET = CFrame.new(0, 0.7, 0)
local BLADE_OFFSET = CFrame.new(0, 2.35, 0)
local GRIP_OFFSET = CFrame.new(0, 0.3, -0.1) * CFrame.Angles(math.rad(180), 0, 0)
local BLADE_HILT_LOCAL = Vector3.new(0, -1.65, 0)
local BLADE_TIP_LOCAL = Vector3.new(0, 1.65, 0)

local cache = {} :: { [Model]: Katana }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CastShadow = false
	return part
end

local function newMotor(name: string, part0: BasePart, part1: BasePart, c0: CFrame): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = CFrame.new()
	motor.Parent = part0
	return motor
end

local function findByName(parent: Instance, names: { string }): Instance?
	for _, name in names do
		local found = parent:FindFirstChild(name)
		if found then
			return found
		end
	end
	return nil
end

local function newAttachment(name: string, point: Vector3, parent: Instance): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = point
	attachment.Parent = parent
	return attachment
end

--[[
	Resolves the shoulder joint lazily, caching it on the katana the first time it
	is found. A rig whose arms replicate a frame late therefore still animates
	instead of being stuck with a nil joint forever.
]]
local function resolveShoulder(katana: Katana): Motor6D?
	if katana.shoulder and katana.shoulder.Parent then
		return katana.shoulder
	end
	local character = katana.model.Parent
	if not character or not character:IsA("Model") then
		return nil
	end
	local shoulder = KatanaFactory.findShoulderJoint(character)
	if shoulder then
		katana.shoulder = shoulder
		katana.baseShoulderC0 = shoulder.C0
	end
	return katana.shoulder
end

-- ---------------------------------------------------------------------------
-- Blade glow
--   A katana carries two ribbons across its edge: a wide coloured one and a thin
--   white core. Both sit inert until a swing switches them on -- so 34 idle
--   enemies cost nothing -- and both are repaired on demand, which means a blade
--   built by an older revision still ends up glowing.
-- ---------------------------------------------------------------------------

-- Applies the shared ribbon look. `color` nil keeps whatever the blade had.
local function applyTrailLook(trail: Trail, color: Color3?, width: number, transparency: number)
	trail.Lifetime = TRAIL_CFG.Lifetime
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.LightEmission = TRAIL_CFG.LightEmission
	if color then
		trail.Color = ColorSequence.new(color)
	end
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, width),
		NumberSequenceKeypoint.new(1, width * 0.15),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, transparency),
		NumberSequenceKeypoint.new(1, 1),
	})
end

--[[
	Adds the white core ribbon if it is missing.
	The clone keeps the hilt/tip attachments, so both ribbons sweep the same arc.
]]
local function ensureCoreTrail(katana: Katana): Trail?
	local existing = katana.coreTrail
	if existing and existing.Parent then
		return existing
	end

	local found: Instance? = katana.blade:FindFirstChild("SlashTrailCore")
	if not found then
		local clone = katana.trail:Clone()
		clone.Name = "SlashTrailCore"
		clone.Enabled = false
		clone.Parent = katana.blade
		found = clone
	end
	if not found:IsA("Trail") then
		return nil
	end

	applyTrailLook(found, TRAIL_CFG.CoreColor, TRAIL_CFG.CoreWidthScale, TRAIL_CFG.CoreTransparency)
	katana.coreTrail = found
	return found
end

-- Brings an adopted or freshly built blade up to the current glow spec.
local function ensureGlow(katana: Katana)
	if katana.trail.Parent then
		applyTrailLook(katana.trail, nil, 1, 0.25)
	end
	ensureCoreTrail(katana)
end

-- ---------------------------------------------------------------------------
-- Rig discovery
-- ---------------------------------------------------------------------------

-- The hand that should carry the sword (R15 "RightHand" or R6 "Right Arm").
function KatanaFactory.findHand(character: Model): BasePart?
	local found = findByName(character, RIG.HandNames)
	if found and found:IsA("BasePart") then
		return found
	end
	return nil
end

--[[
	The shoulder joint used for swing poses.
	Name order wins over depth: R6 parents the joint to the Torso, R15 attaches it
	to the upper arm, so a plain descendant scan is the rig-agnostic answer.
]]
function KatanaFactory.findShoulderJoint(character: Model): Motor6D?
	for _, name in RIG.ShoulderJointNames do
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Name == name then
				return descendant
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function describe(model: Model, hand: BasePart): Katana?
	local handle = model:FindFirstChild("Handle")
	local blade = model:FindFirstChild("Blade")
	local trail = blade and blade:FindFirstChild("SlashTrail")
	local core = blade and blade:FindFirstChild("SlashTrailCore")
	local grip = hand:FindFirstChild(RIG.KatanaGripName)
	if not (handle and handle:IsA("BasePart") and blade and blade:IsA("BasePart")) then
		return nil
	end
	if not (trail and trail:IsA("Trail") and grip and grip:IsA("Motor6D")) then
		return nil
	end
	local character = model.Parent
	local shoulder = if character then KatanaFactory.findShoulderJoint(character) else nil
	local katana: Katana = {
		model = model,
		handle = handle,
		blade = blade,
		trail = trail,
		coreTrail = if core and core:IsA("Trail") then core else nil,
		grip = grip,
		hand = hand,
		shoulder = shoulder,
		baseShoulderC0 = if shoulder then shoulder.C0 else nil,
	}
	-- Adopted blades are repaired here: an older revision shipped one ribbon only.
	ensureGlow(katana)
	return katana
end

--[[
	Attaches a katana to `character` if it does not already have one.
	Returns nil when the character has no right hand (exotic custom rig).
]]
function KatanaFactory.attach(character: Model): Katana?
	local cached = cache[character]
	if cached and cached.model.Parent == character then
		return cached
	end

	local existing = character:FindFirstChild(RIG.KatanaName)
	if existing and existing:IsA("Model") then
		local hand = KatanaFactory.findHand(character)
		if hand then
			local described = describe(existing, hand)
			if described then
				cache[character] = described
				return described
			end
		end
		existing:Destroy()
	end

	local hand = KatanaFactory.findHand(character)
	if not hand then
		-- Rigs can replicate limb-by-limb; give the right hand a bounded moment
		-- before giving up, so the blade is never left unattached.
		for _, handName in RIG.HandNames do
			local part = character:WaitForChild(handName, 2)
			if part and part:IsA("BasePart") then
				hand = part
				break
			end
		end
	end
	if not hand then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = RIG.KatanaName

	local handle = newPart("Handle", Vector3.new(0.28, 1.3, 0.28), Color3.fromRGB(26, 24, 30), Enum.Material.Fabric)
	local guard = newPart("Guard", Vector3.new(0.74, 0.1, 0.74), Color3.fromRGB(72, 62, 44), Enum.Material.Metal)
	local blade = newPart("Blade", Vector3.new(0.14, 3.3, 0.4), Color3.fromRGB(216, 226, 238), Enum.Material.Metal)
	blade.Reflectance = 0.14
	blade.Material = Enum.Material.Metal

	-- Assemble in the katana's own frame first so nothing pops on the first frame.
	handle.CFrame = hand.CFrame * GRIP_OFFSET
	guard.CFrame = handle.CFrame * GUARD_OFFSET
	blade.CFrame = handle.CFrame * BLADE_OFFSET

	guard.Parent = model
	blade.Parent = model
	handle.Parent = model
	model.PrimaryPart = handle
	model.Parent = character

	local grip = newMotor(RIG.KatanaGripName, hand, handle, GRIP_OFFSET)
	newMotor("GuardJoint", handle, guard, GUARD_OFFSET)
	newMotor("BladeJoint", handle, blade, BLADE_OFFSET)

	local hiltAttachment = newAttachment("Hilt", BLADE_HILT_LOCAL, blade)
	local tipAttachment = newAttachment("Tip", BLADE_TIP_LOCAL, blade)

	local trail = Instance.new("Trail")
	trail.Name = "SlashTrail"
	trail.Attachment0 = hiltAttachment
	trail.Attachment1 = tipAttachment
	applyTrailLook(trail, TRAIL_COLOR, 1, 0.25)
	trail.Enabled = false
	trail.Parent = blade

	local shoulder = KatanaFactory.findShoulderJoint(character)
	local katana: Katana = {
		model = model,
		handle = handle,
		blade = blade,
		trail = trail,
		coreTrail = nil,
		grip = grip,
		hand = hand,
		shoulder = shoulder,
		baseShoulderC0 = if shoulder then shoulder.C0 else nil,
	}
	-- Mints the hot core ribbon, so a fresh blade is already glowing on swing one.
	ensureGlow(katana)
	cache[character] = katana
	return katana
end

-- Cached katana for a character, attaching one on demand.
function KatanaFactory.get(character: Model): Katana?
	return KatanaFactory.attach(character)
end

--[[
	Repairs the grip weld if it is missing or malformed (e.g. a partially
	replicated rig). Safe to call repeatedly; a healthy weld is left untouched.
]]
function KatanaFactory.ensureWeld(character: Model): boolean
	local cached = cache[character]
	if not cached or cached.model.Parent ~= character then
		cached = KatanaFactory.attach(character)
	end
	if not cached then
		return false
	end
	local katana: Katana = cached

	local hand = KatanaFactory.findHand(character) or katana.hand
	local existing = hand:FindFirstChild(RIG.KatanaGripName)
	if existing and existing:IsA("Motor6D") and existing.Part0 == hand and existing.Part1 == katana.handle then
		katana.grip = existing
		return true
	end
	if existing then
		existing:Destroy()
	end

	katana.grip = newMotor(RIG.KatanaGripName, hand, katana.handle, GRIP_OFFSET)
	return true
end

-- Turns both blade ribbons on/off (server side, replicates to everyone).
function KatanaFactory.setTrail(katana: Katana, enabled: boolean)
	if katana.trail.Parent ~= nil then
		katana.trail.Enabled = enabled
	end
	local core = katana.coreTrail
	if core and core.Parent ~= nil then
		core.Enabled = enabled
	end
end

-- Recolours the ribbon, e.g. purple while the Shadow Dash is active.
function KatanaFactory.setTrailColor(katana: Katana, color: Color3)
	katana.trail.Color = ColorSequence.new(color)
end

--[[
	One-shot swing glow: switch the ribbons on now, switch them off after
	`duration`. Every server-side swing routes through here, and the delayed
	switch-off is what guarantees an idle blade is dark after a dropped code path.
]]
function KatanaFactory.pulseTrail(katana: Katana, duration: number, color: Color3?)
	if color then
		KatanaFactory.setTrailColor(katana, color)
	end
	KatanaFactory.setTrail(katana, true)
	if duration <= 0 then
		return
	end
	local blade = katana.blade
	task.delay(duration, function()
		-- The blade may already be destroyed by a kill/despawn tween.
		if blade.Parent ~= nil then
			KatanaFactory.setTrail(katana, false)
		end
	end)
end

-- Exposed so other systems can repair a blade they adopted from the DataModel.
KatanaFactory.ensureGlow = ensureGlow

-- ---------------------------------------------------------------------------
-- Posing API shared by EnemyAI (enemies) and the swing scheduler (players)
-- ---------------------------------------------------------------------------

--[[
	Poses the arm around the real shoulder joint.
	`pose` is in degrees and is applied on top of the captured rest C0, so the
	rotation always pivots where the rig's own joint is -- R6 and R15 both work.
]]
function KatanaFactory.poseArm(katana: Katana, pose: Pose)
	local shoulder = resolveShoulder(katana)
	local base = katana.baseShoulderC0
	if not shoulder or not base then
		return
	end
	shoulder.C0 = base * CombatConfig.poseToCFrame(pose)
end

--[[
	Blends towards a pose (t is 0..1).
	Angles are scaled before being converted so multi-turn windups (150 deg+) sweep
	through a single continuous arc instead of taking a slerp shortcut.
]]
function KatanaFactory.blendArm(katana: Katana, pose: Pose, t: number)
	local shoulder = resolveShoulder(katana)
	local base = katana.baseShoulderC0
	if not shoulder or not base then
		return
	end
	local alpha = math.clamp(t, 0, 1)
	shoulder.C0 = base * CFrame.Angles(math.rad(pose.x * alpha), math.rad(pose.y * alpha), math.rad(pose.z * alpha))
end

-- Restores the shoulder rest pose.
function KatanaFactory.resetArm(katana: Katana)
	local shoulder = resolveShoulder(katana)
	if shoulder and katana.baseShoulderC0 then
		shoulder.C0 = katana.baseShoulderC0
	end
end

--[[
	TweenService-driven arm pose, used as the procedural fallback when no arm
	animation asset is available. Returns the live Tween so callers can cancel it.
	Works against the rig's own C0, so R6 and R15 behave identically.
]]
function KatanaFactory.tweenArm(
	katana: Katana,
	pose: Pose,
	duration: number,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?
): Tween?
	local shoulder = resolveShoulder(katana)
	local base = katana.baseShoulderC0
	if not shoulder or not base then
		return nil
	end
	local tween = TweenService:Create(
		shoulder,
		TweenInfo.new(
			math.max(duration, 0.01),
			easingStyle or Enum.EasingStyle.Quad,
			easingDirection or Enum.EasingDirection.Out
		),
		{ C0 = base * CombatConfig.poseToCFrame(pose) }
	)
	tween:Play()
	return tween
end

-- Full swing beat: windup pose, then recovery back to rest.
function KatanaFactory.swingArm(katana: Katana, windup: Pose, recovery: number, windupDuration: number)
	KatanaFactory.tweenArm(katana, windup, windupDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	task.delay(math.max(windupDuration, 0.01), function()
		if katana.model.Parent == nil then
			return
		end
		KatanaFactory.tweenArm(katana, { x = 0, y = 0, z = 0 }, math.max(recovery, 0.01), Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	end)
end

-- Drops the cache entry when a character is destroyed.
function KatanaFactory.forget(character: Model)
	cache[character] = nil
end

return KatanaFactory
