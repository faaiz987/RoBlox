--!strict
--[[
	RigAnimationPack
	----------------
	Bakes this game's swing and stride into real `KeyframeSequence` assets, attaches
	them to a rig, and reports the content ids.

	An animation *asset id* only exists once a KeyframeSequence has been uploaded to
	Roblox -- Studio's Animation Editor can do that, and Open Cloud can with an API
	key; a script cannot. So the pack does everything up to the upload: it authors
	the sequence, registers it with `KeyframeSequenceProvider` (which makes it
	loadable immediately, for this session), stores a copy under
	`ReplicatedStorage.AnimSaves` and prints the ids. Publishing one of those stored
	sequences from the Animation Editor turns a session id into a permanent
	`rbxassetid://`, and that number is what belongs in `CombatConfig.Animations`.

	The poses are not invented here. The three sword clips are the exact numbers
	`CombatController` writes to `Motor6D.Transform` (`CombatConfig.Poses` plus
	`CombatConfig.SwingRig`) interpolated over the same windup/impact/recovery beats,
	and the walk and run cycles reuse the amplitudes the enemy stride runs at. These
	clips are the *baked* form of the procedural animation, so a rig wearing them
	moves the way the game already moves -- and an R6 rig simply gets fewer poses
	(no elbow, knee or wrist joints) instead of an error.

	Usage, from the Studio command bar:

		local rig = workspace.Rig
		local pack = require(game.ReplicatedStorage.Shared.RigAnimationPack)
		pack.install(rig)   -- author + attach + print ids
		pack.preview(rig)   -- walk, run, slash, repeat (play mode)

	Nothing here runs on its own; it is a tool the rig owner calls, so it is inert
	in a live game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local Animations = require(ReplicatedStorage.Shared.Animations)

local RigAnimationPack = {}

export type RigKind = "R6" | "R15"
export type Source = "baked" | "stock"

-- Prefix on the authored KeyframeSequences, so re-running replaces them.
local PREFIX = "CB_Pack_"

-- Attribute tagging the `Animation` instances this pack attached. Ownership is
-- tracked by attribute rather than by name on purpose: `Animations` resolves a key
-- by finding a child named *exactly* the alias, so the name has to stay clean.
local OWNER = "CB_PackKey"

-- One frame at 30fps: the impact beat is a deliberate snap, never a tween.
local SNAP = 0.034

local IDENTITY = CFrame.new()

--[[
	Roblox's own clips, copied from the stock `Animate` script's `animNames` table
	(devforum 140425). These are permanent ids owned by Roblox -- nothing to publish
	-- but the R15 set drives R15 joints only, which is why the baked clips exist.
	R6 ships a single locomotion clip; the stock script plays it for both walk and
	run and leans on `speed` to tell them apart.
]]
RigAnimationPack.STOCK = {
	R15 = {
		Walk = "rbxassetid://507777826",
		Run = "rbxassetid://507767714",
		Idle = "rbxassetid://507766388",
		Jump = "rbxassetid://507765000",
		Fall = "rbxassetid://507767968",
		-- The stock sword tool's own swing, at `Action` priority.
		Slash1 = "rbxassetid://522635514",
		Slash2 = "rbxassetid://522638767",
		Heavy = "rbxassetid://522635514",
	},
	R6 = {
		Walk = "rbxassetid://180426354",
		Run = "rbxassetid://180426354",
	},
} :: { [RigKind]: { [string]: string } }

-- ---------------------------------------------------------------------------
-- Rig introspection
-- ---------------------------------------------------------------------------

--[[
	The joint that carries each logical slot, per rig type. R6 rigs have neither
	forearms, shins nor wrists: a clip that drives those slots simply produces fewer
	poses there. Entries are part names first (that is what a `Pose` is named after)
	with the hostile-rig joint names as a fallback.
]]
local SLOTS: { [string]: { string } } = {
	Torso = { "UpperTorso", "Torso" },
	Head = { "Head" },
	RightArm = { "RightUpperArm", "Right Arm", "RightShoulder", "Right Shoulder" },
	LeftArm = { "LeftUpperArm", "Left Arm", "LeftShoulder", "Left Shoulder" },
	RightForearm = { "RightLowerArm", "Right Elbow", "RightElbow" },
	LeftForearm = { "LeftLowerArm", "Left Elbow", "LeftElbow" },
	RightHand = { "RightHand", "Right Wrist", "RightWrist" },
	LeftHand = { "LeftHand", "Left Wrist", "LeftWrist" },
	RightLeg = { "RightUpperLeg", "Right Leg", "Right Hip", "RightHip" },
	LeftLeg = { "LeftUpperLeg", "Left Leg", "Left Hip", "LeftHip" },
	RightShin = { "RightLowerLeg", "Right Knee", "RightKnee" },
	LeftShin = { "LeftLowerLeg", "Left Knee", "LeftKnee" },
	RightFoot = { "RightFoot" },
	LeftFoot = { "LeftFoot" },
}

-- A pose is a joint's `Transform`: the rotation an animation track writes, expressed
-- in that joint's own frame. Identity means "the rig's rest pose".
export type JointPose = { [string]: CFrame }

type Beat = { t: number, pose: JointPose }

type Clip = {
	key: string,
	length: number,
	loop: boolean,
	priority: Enum.AnimationPriority,
	frames: { Beat },
}

export type Report = {
	rig: Model,
	kind: RigKind,
	source: Source,
	-- key -> content id bound to the rig right now (permanent for stock clips).
	ids: { [string]: string },
	-- key -> true when the id is a Roblox-owned asset that will never expire.
	permanent: { [string]: boolean },
	sequences: { [string]: KeyframeSequence },
	animations: { [string]: Animation },
	-- Slots this rig has no joint for; those poses were dropped, not faked.
	missing: { string },
}

local function degrees(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

-- CombatConfig stores poses as { x, y, z } degrees; this is the same conversion the
-- client's `poseCFrame` does, kept local so the two cannot drift apart silently.
local function poseCFrame(pose: { x: number, y: number, z: number }): CFrame
	return degrees(pose.x, pose.y, pose.z)
end

-- Interpolates two poses; slots present in only one of them blend from rest.
local function mix(a: JointPose, b: JointPose, alpha: number): JointPose
	local out: JointPose = {}
	for slot, transform in a do
		out[slot] = transform:Lerp(b[slot] or IDENTITY, alpha)
	end
	for slot, transform in b do
		if out[slot] == nil then
			out[slot] = (a[slot] or IDENTITY):Lerp(transform, alpha)
		end
	end
	return out
end

-- Keeps `factor` of a pose's rotation, measured from rest. Used to reach a windup
-- with the same ease the client's Quad tween gives it.
local function scaled(pose: JointPose, factor: number): JointPose
	local out: JointPose = {}
	for slot, transform in pose do
		out[slot] = transform:Lerp(IDENTITY, 1 - factor)
	end
	return out
end

--[[
	The rest pose over the same joints as `pose`. A clip has to *key* its return to
	rest: dropping the slot instead would leave the last authored rotation frozen on
	the rig for the tail of the track, because a KeyframeSequence only interpolates
	the poses it carries.
]]
local function restOf(pose: JointPose): JointPose
	local out: JointPose = {}
	for slot in pose do
		out[slot] = IDENTITY
	end
	return out
end

--[[
	Locates a rig in Workspace. Skips anything without a Humanoid, and skips
	anything without joints -- a loose model of parts cannot be animated.
]]
function RigAnimationPack.findRig(): Model?
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
			if child:FindFirstChildWhichIsA("Motor6D", true) then
				return child
			end
		end
	end
	return nil
end

local function rigKindOf(model: Model): RigKind
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
		return "R6"
	end
	return "R15"
end

-- Indexes the rig's joints by part name and by joint name, then resolves every slot
-- that this rig actually has.
local function slotIndex(model: Model): ({ [string]: Motor6D }, { string })
	local byName: { [string]: Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			local motor: Motor6D = descendant
			local part1 = motor.Part1
			if part1 then
				byName[part1.Name] = motor
				byName[motor.Name] = motor
			end
		end
	end

	local slots: { [string]: Motor6D } = {}
	local missing: { string } = {}
	for slot, names in SLOTS do
		local found: Motor6D? = nil
		for _, name in names do
			local candidate = byName[name]
			if candidate then
				found = candidate
				break
			end
		end
		if found then
			slots[slot] = found
		else
			table.insert(missing, slot)
		end
	end
	return slots, missing
end

-- ---------------------------------------------------------------------------
-- Clip poses
-- ---------------------------------------------------------------------------

--[[
	One beat of the sword swing, expressed the way the client expresses it: the
	shoulder takes the shared pose table, the forearm folds from `SwingRig`, the torso
	turns on the waist joint, the wrist flicks. `alternate` reproduces the mirrored
	second cut, exactly as `swingBeat` does -- a clip that disagreed with the
	procedural swing would make the combo read differently depending on whether an
	id is configured.
]]
local function swingBeat(stepIndex: number, phase: string): JointPose
	local pose = CombatConfig.getComboStep(stepIndex)
	local alternate = pose.kind ~= "Heavy" and stepIndex % 2 == 0
	local rig = CombatConfig.SwingRig
	local poses = CombatConfig.Poses

	local shoulder: { x: number, y: number, z: number }
	if pose.kind == "Heavy" then
		shoulder = if phase == "Windup" then poses.HeavyWindup else poses.HeavyImpact
	elseif phase == "Windup" then
		shoulder = if alternate then poses.SlashAlternate else poses.SlashWindup
	else
		shoulder = poses.SlashImpact
	end

	local fold = if phase == "Windup" then rig.ElbowFold else rig.ElbowExtend
	if alternate then
		fold *= 0.75
	end

	local flick = if phase == "Windup" then rig.WristFlick else rig.WristSnap
	if alternate then
		flick *= -1
	end

	local turn = if phase == "Windup" then rig.WaistBack else rig.WaistThrough
	if alternate then
		turn *= -1
	end

	return {
		RightArm = poseCFrame(shoulder),
		RightForearm = degrees(fold, 0, 0),
		RightHand = degrees(flick, 0, 0),
		Torso = degrees(0, turn, 0),
	}
end

--[[
	One sample of a locomotion cycle. The offsets and amplitudes mirror the enemy
	stride (`STRIDE_LAYOUT`: hips at 36 degrees, the off arm at half that) so a rig
	that plays the Walk clip and an enemy that runs its procedural stride step at the
	same rate. Hips lead, the arms counter-swing, knees only ever fold backwards.
]]
local function stridePose(
	phase: number,
	amplitude: number,
	lean: number,
	armOut: number,
	torsoScale: number
): JointPose
	local a = phase * math.pi * 2

	local function side(offset: number, out: number)
		local b = a + offset
		local swing = math.sin(b) * amplitude
		-- 0 at foot contact, 1 through the swing: the leg that is travelling.
		local lift = math.max(0, math.sin(b - math.pi * 0.5))
		return {
			leg = degrees(swing, 0, 0),
			shin = degrees(6 + lift * amplitude * 1.1, 0, 0),
			arm = degrees(-swing * 0.5, 0, out),
			forearm = degrees(14 + lift * amplitude * 0.45, 0, 0),
			foot = degrees(-lift * 9, 0, 0),
		}
	end

	local right = side(0, armOut)
	local left = side(math.pi, -armOut)
	local yaw = math.sin(a) * 4

	return {
		-- R6 carries the whole upper body -- legs included -- on its Torso joint, so a
		-- lean that reads well on a spine would drag the feet off the floor there.
		Torso = degrees(lean * torsoScale, yaw * torsoScale, 0),
		Head = degrees(-lean * 0.5, -yaw * torsoScale, 0),
		RightLeg = right.leg,
		RightShin = right.shin,
		RightFoot = right.foot,
		LeftLeg = left.leg,
		LeftShin = left.shin,
		LeftFoot = left.foot,
		RightArm = right.arm,
		RightForearm = right.forearm,
		LeftArm = left.arm,
		LeftForearm = left.forearm,
	}
end

--[[
	A held guard: blade up in front of the face, with a shallow breath so the loop
	does not read as a frozen pose. The sword arm is the client's guard beat verbatim
	(`ParryGuard` + `ElbowGuard`); the off arm and the wide stance are additive, since
	`holdGuardPose` only ever drives the sword arm.
]]
local function guardPose(phase: number): JointPose
	local sway = math.sin(phase * math.pi * 2) * 2
	return {
		Torso = degrees(0, sway, 0),
		Head = degrees(0, -sway, 0),
		RightArm = poseCFrame(CombatConfig.Poses.ParryGuard),
		RightForearm = degrees(CombatConfig.SwingRig.ElbowGuard, 0, 0),
		LeftArm = degrees(26, 16, -12 + sway),
		LeftForearm = degrees(48, 0, 0),
		RightLeg = degrees(-6, 0, 4),
		LeftLeg = degrees(8, 0, -4),
	}
end

-- ---------------------------------------------------------------------------
-- Clip assembly
-- ---------------------------------------------------------------------------

-- Evenly spaced samples of a cycle, with a closing frame so the loop lands on the
-- same pose it left from.
local function cycleFrames(build: (number) -> JointPose, length: number, samples: number): { Beat }
	local frames: { Beat } = {}
	for index = 0, samples - 1 do
		local phase = index / samples
		table.insert(frames, { t = phase * length, pose = build(phase) })
	end
	table.insert(frames, { t = length, pose = build(0) })
	return frames
end

--[[
	Bakes one combo step. The beats are the client's: a windup eased in over the
	step's `windup` window, a one-frame snap onto the impact, then a Quart-style decay
	home across `recovery`. `Animations.play` scales the clip by attack speed while
	`playSwing` divides the same two windows by it, so the impact stays on the frame
	the hitbox fires.
]]
local function slashClip(key: string, stepIndex: number): Clip
	local step = CombatConfig.getComboStep(stepIndex)
	local windup = math.max(step.windup, 0.02)
	local recovery = math.max(step.recovery, 0.02)
	local wind = swingBeat(stepIndex, "Windup")
	local impact = swingBeat(stepIndex, "Impact")
	local rest = restOf(wind)

	return {
		key = key,
		length = windup + recovery,
		loop = false,
		priority = Enum.AnimationPriority.Action,
		frames = {
			{ t = 0, pose = rest },
			{ t = windup * 0.45, pose = scaled(wind, 0.65) },
			{ t = windup, pose = wind },
			{ t = windup + SNAP, pose = impact },
			{ t = windup + recovery * 0.28, pose = mix(impact, rest, 0.4) },
			{ t = windup + recovery * 0.55, pose = mix(impact, rest, 0.7) },
			{ t = windup + recovery, pose = rest },
		},
	}
end

-- The riposte the guard pose does not cover: a short draw away, then the counter.
local function parryClip(): Clip
	local guard = guardPose(0)
	local riposte: JointPose = {
		Torso = degrees(0, CombatConfig.SwingRig.WaistThrough * 0.6, 0),
		Head = degrees(0, -8, 0),
		RightArm = poseCFrame(CombatConfig.Poses.ParryRiposte),
		RightForearm = degrees(CombatConfig.SwingRig.ElbowExtend, 0, 0),
		RightHand = degrees(CombatConfig.SwingRig.WristSnap, 0, 0),
		LeftArm = degrees(14, -10, -8),
		LeftForearm = degrees(30, 0, 0),
	}
	return {
		key = "Parry",
		length = 0.34,
		loop = false,
		priority = Enum.AnimationPriority.Action,
		frames = {
			{ t = 0, pose = scaled(guard, 0.6) },
			{ t = 0.08, pose = scaled(guard, 0.85) },
			{ t = 0.2, pose = riposte },
			{ t = 0.34, pose = restOf(mix(guard, riposte, 1)) },
		},
	}
end

local function clips(kind: RigKind): { Clip }
	local torso = if kind == "R6" then 0.4 else 1
	return {
		{
			key = "Walk",
			length = 1,
			loop = true,
			priority = Enum.AnimationPriority.Movement,
			frames = cycleFrames(function(phase)
				return stridePose(phase, 36, -2, 5, torso)
			end, 1, 8),
		},
		{
			key = "Run",
			length = 0.62,
			loop = true,
			priority = Enum.AnimationPriority.Movement,
			frames = cycleFrames(function(phase)
				return stridePose(phase, 52, -13, 7, torso)
			end, 0.62, 10),
		},
		slashClip("Slash1", 1),
		slashClip("Slash2", 2),
		slashClip("Heavy", 3),
		{
			key = "Guard",
			length = 1.2,
			loop = true,
			priority = Enum.AnimationPriority.Action,
			frames = cycleFrames(guardPose, 1.2, 6),
		},
		parryClip(),
	}
end

-- ---------------------------------------------------------------------------
-- KeyframeSequence authoring
-- ---------------------------------------------------------------------------

--[[
	Turns a clip into the asset the Animation Editor publishes. A `Pose` is named
	after the joint's *part* (`Motor6D.Part1`), and its `CFrame` is the joint's
	`Transform` -- the same channel `CombatController` writes when it swings
	procedurally, which is what makes the clip and the code agree.
	Returns nil when the rig has no joint the clip could drive.
]]
local function buildSequence(clip: Clip, slots: { [string]: Motor6D }): KeyframeSequence?
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = PREFIX .. clip.key
	sequence.Loop = clip.loop
	sequence.Priority = clip.priority

	local posed = 0
	local previous = -1
	for index, beat in clip.frames do
		local keyframe = Instance.new("Keyframe")
		keyframe.Name = string.format("%s_%02d", clip.key, index)

		local wrote = false
		for slot, transform in beat.pose do
			local motor = slots[slot]
			local part1 = if motor then motor.Part1 else nil
			if motor and part1 then
				local pose = Instance.new("Pose")
				pose.Name = part1.Name
				pose.CFrame = transform
				pose.Parent = keyframe
				wrote = true
			end
		end

		-- Keyframes have to advance in time: beats that a short `recovery` squeezes
		-- together are nudged a millisecond apart instead of colliding.
		if wrote then
			local time = math.max(beat.t, previous + 0.001)
			keyframe.Time = time
			keyframe.Parent = sequence
			previous = time
			posed += 1
		else
			keyframe:Destroy()
		end
	end

	if posed < 2 then
		sequence:Destroy()
		return nil
	end
	return sequence
end

-- Registering gives a session-scoped content id: the sequence plays on this rig
-- immediately, but it is not a permanent asset until it is published.
local function register(sequence: KeyframeSequence): string?
	local ok, id = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

--[[
	Keeps a copy of every authored sequence where the Animation Editor looks for a
	rig's animations (`ReplicatedStorage.AnimSaves.<rig>`). This is the drop that
	lets you open the rig in the editor and hit Publish.
]]
local function store(sequences: { [string]: KeyframeSequence }, rigName: string)
	local saves = ReplicatedStorage:FindFirstChild("AnimSaves")
	if not saves then
		saves = Instance.new("Folder")
		saves.Name = "AnimSaves"
		saves.Parent = ReplicatedStorage
	end

	local existing = saves:FindFirstChild(rigName)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = rigName
	for key, sequence in sequences do
		local copy = sequence:Clone()
		copy.Name = key
		copy.Parent = folder
	end
	folder.Parent = saves
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

export type Options = {
	-- "baked" (default) authors this game's own clips for any rig type;
	-- "stock" attaches Roblox's R15 clips -- permanent ids, R15 rigs only.
	source: Source?,
	-- Keep the authored sequences in ReplicatedStorage.AnimSaves. Default true.
	store: boolean?,
	-- Print the id report. Default true.
	announce: boolean?,
}

-- The name `Animations` resolves a key by, so an attached `Animation` is picked up
-- with no config change at all.
local function aliasFor(key: string): string
	local aliases = CombatConfig.Animations.Aliases[key]
	if aliases and aliases[1] then
		return aliases[1]
	end
	return key
end

-- Drops the clips a previous install bound, so re-running is idempotent.
local function clear(rig: Model)
	local holders: { Instance } = { rig }
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(holders, humanoid)
	end
	for _, holder in holders do
		for _, child in holder:GetChildren() do
			if child:IsA("Animation") and child:GetAttribute(OWNER) ~= nil then
				child:Destroy()
			end
		end
	end
end

--[[
	Authors the rig's clips, binds them to the rig and returns the report.

	Every clip is attached as an `Animation` instance named after its
	`CombatConfig.Animations.Aliases` entry, which is the resolution path
	`Animations.track` already walks. That means the rig animates with an empty
	config: paste a published id into `CombatConfig.Animations` only when the id
	should drive player characters too (the pack cannot pre-attach instances to a
	character Roblox creates).
]]
function RigAnimationPack.install(rig: Model?, options: Options?): Report?
	local model = rig or RigAnimationPack.findRig()
	if not model then
		warn("[RigAnimationPack] no rig found: pass one in, e.g. install(workspace.Rig)")
		return nil
	end

	local opts = options or {}
	local source: Source = opts.source or "baked"
	local kind = rigKindOf(model)
	local slots, missing = slotIndex(model)

	clear(model)
	local report: Report = {
		rig = model,
		kind = kind,
		source = source,
		ids = {},
		permanent = {},
		sequences = {},
		animations = {},
		missing = missing,
	}

	local stock = RigAnimationPack.STOCK[kind]
	for _, clip in clips(kind) do
		local id: string? = nil
		if source == "stock" then
			id = stock[clip.key]
		else
			local sequence = buildSequence(clip, slots)
			if sequence then
				report.sequences[clip.key] = sequence
				id = register(sequence)
			end
		end
		if not id then
			continue
		end

		report.ids[clip.key] = id
		report.permanent[clip.key] = source == "stock"

		local animation = Instance.new("Animation")
		-- The name is the alias, unprefixed: that is the string `Animations` searches
		-- for when the config carries no id.
		animation.Name = aliasFor(clip.key)
		animation.AnimationId = id
		animation:SetAttribute(OWNER, clip.key)
		animation:SetAttribute("CB_SessionOnly", not report.permanent[clip.key])
		-- Parented to the rig: `Animations` searches aliases recursively from the
		-- model, so this is all the wiring the animator needs.
		animation.Parent = model
		report.animations[clip.key] = animation
	end

	if source == "baked" and opts.store ~= false and next(report.sequences) ~= nil then
		store(report.sequences, model.Name)
	end

	if opts.announce ~= false then
		RigAnimationPack.report(report)
	end
	return report
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local function summary(report: Report): { [string]: string }
	local lines: { [string]: string } = {}
	for key, id in report.ids do
		lines[key] = string.format('	%s = "%s",', key, id)
	end
	return lines
end

--[[
	Prints what happened in the order it matters: what is live now, what needs one
	publish click, and the exact table rows to paste once you have permanent ids.
]]
function RigAnimationPack.report(report: Report)
	local ids = summary(report)
	local permanent: { string } = {}
	local session: { string } = {}
	for key, isPermanent in report.permanent do
		local line = ids[key]
		if line then
			table.insert(if isPermanent then permanent else session, line)
		end
	end
	table.sort(permanent)
	table.sort(session)

	print(`[RigAnimationPack] {report.kind} rig "{report.rig.Name}" -- source: {report.source}`)
	if #report.missing > 0 then
		print(`  this rig has no joints for: {table.concat(report.missing, ", ")} (those poses were dropped)`)
	end
	if #permanent > 0 then
		print("  permanent ids (Roblox-owned, safe to commit):")
		for _, line in permanent do
			print(line)
		end
	end
	if #session > 0 then
		print("  session ids (live now, expire with this session):")
		for _, line in session do
			print(line)
		end
		print("  -> to make one permanent: open the rig in the Animation Editor, select the clip")
		print("     under ReplicatedStorage.AnimSaves, Publish to Roblox, then paste the id it")
		print("     gives you here and into CombatConfig.Animations.")
	end
	if #permanent + #session == 0 then
		warn("  nothing was bound: no id resolved and no pose could be authored for this rig")
	end
end

-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------

-- Plays each installed clip in turn so the rig can be eyeballed. Run it in play
-- mode: the animator only reports a track length once the engine is running.
function RigAnimationPack.preview(rig: Model?, hold: number?)
	local model = rig or RigAnimationPack.findRig()
	if not model then
		warn("[RigAnimationPack] no rig found to preview")
		return
	end
	local seconds = hold or 1.4
	local order = { "Walk", "Run", "Slash1", "Slash2", "Heavy", "Guard" }

	task.spawn(function()
		for _, key in order do
			local track = Animations.play(model, key, "Player", 0.15, 1, 1)
			if not track then
				print(`[RigAnimationPack] {key}: no clip loaded, skipping`)
			else
				print(`[RigAnimationPack] {key}: playing {seconds}s`)
				task.wait(seconds)
				Animations.stop(model, key, 0.15)
			end
			task.wait(0.1)
		end
		print("[RigAnimationPack] preview done")
	end)
end

return RigAnimationPack
