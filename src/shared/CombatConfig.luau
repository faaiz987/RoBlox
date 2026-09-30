--!strict
--[[
	CombatConfig
	------------
	Single source of truth for every number that decides how the sword feels.

	Design pillars (Ghost of Tsushima inspired):
	  * Lethal & fast -- light slashes are quick, the heavy finisher is a commitment.
	  * Readable danger -- enemies telegraph every swing, players answer with Parry or Dodge.
	  * Rewarding defense -- a parry stuns the attacker and opens a lethal counter window.

	Everything here is data only: no Instances, no services, no side effects.
	Server and client both require this so timings can never drift apart.
]]

local CombatConfig = {}

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

export type ComboKind = "Slash" | "Heavy"

export type ComboStep = {
	id: string,
	name: string,
	kind: ComboKind,
	damage: number,
	-- Forward reach of the hitbox, in studs (measured from the attacker's root).
	reach: number,
	-- Lateral half-width of the hitbox, in studs.
	radius: number,
	-- Half-angle of the damage cone, in degrees.
	halfAngle: number,
	-- Seconds between the input and the hitbox applying damage.
	windup: number,
	-- Seconds of lockout after the hitbox resolves (before the next input).
	recovery: number,
	-- Studs of forward lunge the attacker slides during the swing.
	lunge: number,
	-- Poise removed from each victim. 100+ breaks any poise in the game.
	poiseDamage: number,
	-- Backward knockback impulse applied to victims.
	knockback: number,
	-- Camera shake trauma (0-1) for the attacker.
	shake: number,
	shakeDuration: number,
	-- Field-of-view kick in degrees (positive pushes out, negative pulls in).
	fovKick: number,
	swingSound: string,
	hitSound: string,
}

export type EnemyArchetype = {
	id: string,
	label: string,
	health: number,
	damage: number,
	moveSpeed: number,
	-- Distance from the target at which the enemy plants its feet and swings.
	attackRange: number,
	-- Half-angle of the enemy's damage cone, in degrees.
	attackHalfAngle: number,
	-- Seconds of visible windup before the blade lands.
	windup: number,
	-- Seconds of recovery after the swing.
	recovery: number,
	-- Unparryable "flash" attacks must be dodged, never parried.
	unparryable: boolean,
	poise: number,
	poiseRegen: number,
	-- Chunkier enemies hit harder, resist knockback and glow differently.
	knockbackResist: number,
	-- Palette. The body reads as a shadow made of cloth; the trim and eyes carry
	-- the archetype's glow so a pack is still readable at a distance.
	bodyColor: Color3,
	accentColor: Color3,
	-- Arms and legs: one step darker than the torso.
	limbColor: Color3,
	-- Emissive eyes (Neon material).
	eyeColor: Color3,
	-- Emissive trim / katana ribbon colour.
	glowColor: Color3,
	bodyMaterial: Enum.Material,
}

export type Stats = {
	maxHealth: number,
	damageMultiplier: number,
	-- 1.0 = base. 1.3 = every combat animation is 30% faster.
	attackSpeed: number,
	parryWindow: number,
	parryCooldown: number,
	parryStun: number,
	counterWindow: number,
	counterDamageMultiplier: number,
	dodgeCooldown: number,
	dodgeInvincibility: number,
	dodgeDuration: number,
	dodgeSpeed: number,
	comboTimeout: number,
	blockReduction: number,
	lifestealPerParry: number,
	instantPoiseBreak: boolean,
	shadowDash: boolean,
	extraJumps: number,
}

export type Vector3Pose = { x: number, y: number, z: number }

-- One clip-less procedural beat: where the sword arm lands and how long each phase
-- lasts. The client drives it through TweenService onto the shoulder's rest C0.
export type ProceduralBeat = {
	id: string,
	-- Where the shoulder lands for the cut, in degrees on top of its rest C0.
	pose: Vector3Pose,
	-- Seconds to accelerate into the pose.
	out: number,
	-- Seconds the pose is parked (at least) before the arm eases home.
	hold: number,
	-- Seconds to ease home afterwards.
	back: number,
	-- Heavy only: the overhead raise, and the slam that follows it.
	raise: Vector3Pose?,
	slam: number?,
	-- Heavy only: FOV kick in degrees, fired on the slam beat.
	fovKick: number?,
}

-- A parry beat adds the clash extension: how much longer the block is held when
-- the incoming blade is caught inside the window.
export type ParryBeat = ProceduralBeat & { successHold: number }

-- ---------------------------------------------------------------------------
-- Core timings (the numbers the brief pins down)
-- ---------------------------------------------------------------------------

CombatConfig.Timings = {
	-- Active parry window opened by pressing Parry (F).
	ParryWindow = 0.2,
	ParryCooldown = 0.55,
	-- Enemy hit during the parry window is stunned for this long.
	ParryStun = 1.5,
	-- After a parry, the victim takes bonus damage for this long (counter-attack).
	CounterWindow = 1.5,
	-- Dodge cooldown, in seconds.
	DodgeCooldown = 1.0,
	-- Damage is fully negated during the first slice of a dash.
	DodgeInvincibility = 0.25,
	DodgeDuration = 0.34,
	-- Time allowed between combo inputs before the stance resets to slash 1.
	ComboTimeout = 1.2,
}

-- ---------------------------------------------------------------------------
-- Player baseline
-- ---------------------------------------------------------------------------

CombatConfig.Player = {
	MaxHealth = 100,
	WalkSpeed = 18,
	-- Dash impulse speed for the dodge, in studs/second.
	DashSpeed = 92,
	-- Health restored to every living player when a wave is cleared.
	WaveClearHeal = 0.2,
	LifestealPerParry = 0,

	--[[
		Mid-air jumps every player gets before any perk is picked. One means the
		double jump is a base ability rather than a card the player has to be offered,
		which is what it always wanted to be; the DoubleJump perk now stacks a second
		air jump on top of it (see PerkDatabase).
	]]
	AirJumps = 1,
	-- Upward impulse of that mid-air jump, in studs/second: a touch over the stock
	-- jump power, so the second kick reads as the stronger one.
	AirJumpImpulse = 54,
}

CombatConfig.Block = {
	-- Damage taken while guarding (holding Parry after the window closes).
	DamageReduction = 0.65,
	WalkSpeedMultiplier = 0.45,
}

-- ---------------------------------------------------------------------------
-- Stance combo: slash, slash, heavy finisher
-- ---------------------------------------------------------------------------

CombatConfig.Combo = {
	Timeout = CombatConfig.Timings.ComboTimeout,
	Steps = {
		{
			id = "slash1",
			name = "Rising Cut",
			kind = "Slash",
			damage = 12,
			reach = 8.5,
			radius = 4,
			halfAngle = 65,
			windup = 0.12,
			recovery = 0.16,
			lunge = 3,
			poiseDamage = 14,
			knockback = 8,
			shake = 0.28,
			shakeDuration = 0.16,
			fovKick = 1.5,
			swingSound = "rbxasset://sounds/swordslash.wav",
			hitSound = "rbxasset://sounds/snap.mp3",
		},
		{
			id = "slash2",
			name = "Crossed Steel",
			kind = "Slash",
			damage = 14,
			reach = 9,
			radius = 4.5,
			halfAngle = 75,
			windup = 0.14,
			recovery = 0.19,
			lunge = 4,
			poiseDamage = 16,
			knockback = 10,
			shake = 0.38,
			shakeDuration = 0.18,
			fovKick = 2,
			swingSound = "rbxasset://sounds/swordslash.wav",
			hitSound = "rbxasset://sounds/snap.mp3",
		},
		{
			id = "heavy",
			name = "Heaven's Fall",
			kind = "Heavy",
			damage = 34,
			reach = 10.5,
			radius = 6,
			halfAngle = 95,
			windup = 0.3,
			recovery = 0.45,
			lunge = 6,
			poiseDamage = 100,
			knockback = 28,
			shake = 1,
			shakeDuration = 0.4,
			fovKick = 7,
			swingSound = "rbxasset://sounds/swordlunge.wav",
			hitSound = "rbxasset://sounds/impact_water.mp3",
		},
	} :: { ComboStep },
}

-- ---------------------------------------------------------------------------
-- Enemy archetypes
-- ---------------------------------------------------------------------------

CombatConfig.Enemies = {
	Ronin = {
		id = "Ronin",
		label = "Ronin",
		health = 60,
		damage = 14,
		moveSpeed = 11,
		attackRange = 7.5,
		attackHalfAngle = 70,
		windup = 1,
		recovery = 0.65,
		unparryable = false,
		poise = 40,
		poiseRegen = 8,
		knockbackResist = 0,
		bodyColor = Color3.fromRGB(38, 40, 50),
		accentColor = Color3.fromRGB(196, 148, 82),
		limbColor = Color3.fromRGB(29, 30, 38),
		eyeColor = Color3.fromRGB(255, 58, 62),
		glowColor = Color3.fromRGB(255, 74, 74),
		bodyMaterial = Enum.Material.Fabric,
	} :: EnemyArchetype,

	Brute = {
		id = "Brute",
		label = "Oni Brute",
		health = 140,
		damage = 26,
		moveSpeed = 8,
		attackRange = 9,
		attackHalfAngle = 80,
		windup = 1.25,
		recovery = 0.95,
		unparryable = false,
		poise = 90,
		poiseRegen = 5,
		knockbackResist = 0.65,
		bodyColor = Color3.fromRGB(54, 34, 36),
		accentColor = Color3.fromRGB(214, 96, 62),
		limbColor = Color3.fromRGB(40, 25, 27),
		eyeColor = Color3.fromRGB(255, 84, 54),
		glowColor = Color3.fromRGB(255, 96, 48),
		bodyMaterial = Enum.Material.Slate,
	} :: EnemyArchetype,

	Shinobi = {
		id = "Shinobi",
		label = "Shinobi",
		health = 45,
		damage = 18,
		moveSpeed = 16,
		attackRange = 8.5,
		attackHalfAngle = 60,
		-- Unparryable flash cut: tighter window, forces a dodge.
		windup = 0.7,
		recovery = 0.5,
		unparryable = true,
		poise = 25,
		poiseRegen = 12,
		knockbackResist = 0.2,
		bodyColor = Color3.fromRGB(26, 30, 40),
		accentColor = Color3.fromRGB(126, 208, 244),
		limbColor = Color3.fromRGB(20, 24, 32),
		eyeColor = Color3.fromRGB(255, 58, 62),
		glowColor = Color3.fromRGB(126, 208, 244),
		bodyMaterial = Enum.Material.Fabric,
	} :: EnemyArchetype,
}

-- Enemy attack telegraph presentation, read by the client.
CombatConfig.Telegraph = {
	ParryableColor = Color3.fromRGB(255, 176, 72),
	UnparryableColor = Color3.fromRGB(255, 74, 74),
	ParryableLabel = "PARRY OR DODGE",
	UnparryableLabel = "DODGE!",
	ParryableSound = "rbxasset://sounds/unsheath.mp3",
	UnparryableSound = "rbxasset://sounds/electronicpingshort.wav",
}

-- ---------------------------------------------------------------------------
-- Replicated attribute contract
--   Writer column = the single authority for that attribute (avoids write races).
-- ---------------------------------------------------------------------------

CombatConfig.Attributes = {
	-- Written by CombatServer (players)
	ParryActive = "CB_ParryActive",
	ParryUntil = "CB_ParryUntil",
	InvulnerableUntil = "CB_InvulnerableUntil",
	Blocking = "CB_Blocking",
	CounterUntil = "CB_CounterUntil",
	Perks = "CB_Perks",
	ExtraJumps = "CB_ExtraJumps",
	ShadowDash = "CB_ShadowDash",
	AttackSpeed = "CB_AttackSpeed",
	ParryWindow = "CB_ParryWindow",
	ParryCooldown = "CB_ParryCooldown",
	DodgeCooldown = "CB_DodgeCooldown",
	Lifesteal = "CB_Lifesteal",
	InstantPoiseBreak = "CB_InstantPoiseBreak",
	BlockReduction = "CB_BlockReduction",
	DamageMultiplier = "CB_DamageMultiplier",

	-- Written by WaveManager (players) and EnemyAI (enemies)
	Wave = "CB_Wave",

	-- Written by the client for its own input gating and HUD (never replicated).
	ChoiceOpen = "CB_ChoiceOpen",
	-- Absolute os.clock() timestamps when dodge / parry are ready again.
	DodgeReadyAt = "CB_DodgeReadyAt",
	ParryReadyAt = "CB_ParryReadyAt",

	-- Written by EnemyAI (enemies)
	Archetype = "CB_Archetype",
	Poise = "CB_Poise",
	MaxPoise = "CB_MaxPoise",
	StunnedUntil = "CB_StunnedUntil",
	StaggeredUntil = "CB_StaggeredUntil",
	Knockback = "CB_Knockback",
	KnockbackDir = "CB_KnockbackDir",
	TelegraphEnds = "CB_TelegraphEnds",
	TelegraphParryable = "CB_TelegraphParryable",
	TelegraphLabel = "CB_TelegraphLabel",
}

CombatConfig.Tags = {
	Enemy = "CB_WaveEnemy",
}

-- ---------------------------------------------------------------------------
-- Arena / spawning
-- ---------------------------------------------------------------------------

CombatConfig.Arena = {
	-- Height of an enemy's root so its feet land on the arena floor.
	RigRootY = 3,
	-- Wave enemies appear on a ring between these distances from a defendant.
	SpawnMinDistance = 44,
	SpawnMaxDistance = 62,
	-- Hard ceiling so a late wave cannot melt the server.
	MaxAlive = 34,
	-- Geometry, read by EnvironmentSetup when it builds the stage. The floor must
	-- out-reach SpawnMaxDistance or enemies would spawn off the edge.
	Radius = 78,
	BoundaryRadius = 70,
	TileSize = 12,
	WallHeight = 14,
}

--[[
	Rig lookup, in preference order. The game supports R6 and R15 avatars:
	server and client must agree on which joint carries the sword.
]]
CombatConfig.RigParts = {
	HandNames = { "RightHand", "Right Arm" },
	ShoulderJointNames = { "RightShoulder", "Right Shoulder" },
	ElbowJointNames = { "RightElbow", "Right Elbow" },
	WaistJointNames = { "Waist", "RootJoint" },
	WristJointNames = { "RightWrist", "Right Wrist" }, -- 👈 ADD THIS LINE
	KatanaName = "Katana",
	KatanaGripName = "KatanaGrip",
	-- Blade ribbon endpoints, current name first; the rest are adopted so a blade
	-- built by an older revision keeps its attachments instead of gaining clones.
	HiltAttachmentNames = { "HiltAttachment", "Hilt" },
	TipAttachmentNames = { "TipAttachment", "Tip" },
}

--[[
	Procedural swing rig.
	The pose tables above only carry shoulder angles, which on their own make a stiff
	"one-bone" attack. These numbers are what turn that into a cut: the forearm folds
	on the windup and drives out on the impact, and the torso turns away and then
	through the swing. Flip a sign here if a rig reads backwards.
]]
CombatConfig.SwingRig = {
	ElbowFold = 58,
	ElbowExtend = -6,
	ElbowGuard = 74,
	WaistBack = -14,
	WaistThrough = 18,
	WristFlick = -45, -- 👈 ADD THIS LINE (Flicks hand back on windup)
	WristSnap = 35,   -- 👈 ADD THIS LINE (Snaps hand forward on impact)
}

-- ---------------------------------------------------------------------------
-- Enemy pose data (degrees) -- shared so server + client animate identically.
--   Angles are applied to the shoulder joint C0, pivoting on the real joint.
--   Player poses are not here: they are tuned per beat and live in
--   `CombatConfig.Procedural`, so one table owns the sword arm.
-- ---------------------------------------------------------------------------

CombatConfig.Poses = {
	-- Enemy windups are deliberately huge so the tell is unmissable.
	EnemyWindup = { x = 158, y = 0, z = -16 } :: Vector3Pose,
	EnemyUnparryableWindup = { x = 208, y = 0, z = 22 } :: Vector3Pose,
	EnemyStrike = { x = 30, y = 0, z = 10 } :: Vector3Pose,
	EnemyStagger = { x = -54, y = 0, z = 30 } :: Vector3Pose,
	EnemyStun = { x = -34, y = 0, z = 14 } :: Vector3Pose,
}

--[[
	Procedural arm & sword animation.
	---------------------------------
	Every swing and parry a rig gets with no authored clip and no asset id: a small
	number of beats (`out` -> `hold` -> `back`) tweened onto the shoulder joint's
	captured rest C0, plus the forearm fold / wrist snap / torso turn from
	`CombatConfig.SwingRig`.

	Why C0 and not `Motor6D.Transform`: the default `Animate` script -- and every
	playing AnimationTrack -- writes `Transform` on these joints every frame, so a
	script that poses `Transform` is overwritten before it can render. C0 composes
	*under* the animation instead, which is why a swing stays visible over an idle or
	walk cycle, and why the angle written here is the same angle a baked clip carries.

	Angles are degrees per axis: X = pitch (raises the blade through the shoulder's own
	axis), Y = yaw (carries it across the body), Z = roll (blade twist). Timings are
	nominal: `out` + `hold` is matched against the combo step's server windup, so the
	blade is still parked in the cut the moment the hitbox resolves. Flip a sign with
	`Flip` if a rig reads mirrored.
]]
CombatConfig.Procedural = {
	-- One-line mirror fix, applied to every procedural pose.
	Flip = { x = 1, y = 1, z = 1 } :: Vector3Pose,

	-- Indexed by combo step, exactly like `Combo.Steps`.
	Combo = {
		{
			id = "slash1",
			-- Slash 1 -- light, right to left.
			pose = { x = -45, y = 60, z = -30 } :: Vector3Pose,
			out = 0.08,
			hold = 0.05,
			back = 0.12,
		},
		{
			id = "slash2",
			-- Slash 2 -- light, left to right.
			pose = { x = -30, y = -70, z = 40 } :: Vector3Pose,
			out = 0.08,
			hold = 0.05,
			back = 0.12,
		},
		{
			id = "heavy",
			-- Slash 3 -- overhead finisher: raise, pause at the top of the arc, slam.
			raise = { x = 110, y = 0, z = 0 } :: Vector3Pose,
			pose = { x = -80, y = 0, z = 0 } :: Vector3Pose,
			out = 0.1, -- the raise
			hold = 0.15, -- the visible wind-up pause
			slam = 0.06, -- the cut itself: it lands on the server's windup
			back = 0.2,
			fovKick = 7,
		},
	} :: { ProceduralBeat },

	-- Parry / block: the blade is held across the chest and face for the whole parry
	-- window. A clash extends the hold by `successHold` before easing home.
	Parry = {
		pose = { x = -10, y = 45, z = 85 } :: Vector3Pose,
		out = 0.05,
		hold = CombatConfig.Timings.ParryWindow,
		successHold = 0.1,
		back = 0.15,
	} :: ParryBeat,
}

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Animation assets
--   Every id is optional. An empty string means "no clip authored yet", and the
--   caller falls back to the procedural Motor6D posing instead of trying to load
--   a dead asset -- so the game animates correctly the moment it is synced.
--
--   To fill a slot: add the `Animation` instance to the rig (named after one of the
--   aliases below) or paste a published `rbxassetid://`. `RigAnimationPack`
--   authors and previews rig clips; `RigAnimationPack.STOCK` lists Roblox's own
--   walk / run / sword ids for rigs that can use them, and `Stock` below is the
--   runtime fallback a player's swing reaches for when a slot is empty.
-- ---------------------------------------------------------------------------

CombatConfig.Animations = {
	-- R15 clips. R15 clips cannot drive an R6 rig: those rigs use PlayerR6 and then
	-- fall back to the procedural swing.
	Player = {
		Slash1 = "",
		Slash2 = "",
		Heavy = "",
		Guard = "",
		Parry = "",
		-- Locomotion. The default `Animate` script owns walk/run, so nothing plays
		-- these yet; they are here so a clip authored for a rig can be wired in one
		-- line once it has a permanent id.
		Walk = "",
		Run = "",
	} :: { [string]: string },

	-- Optional R6 variants, used when the local avatar is R6.
	PlayerR6 = {
		Slash1 = "",
		Slash2 = "",
		Heavy = "",
		Guard = "",
		Parry = "",
		Walk = "",
		Run = "",
	} :: { [string]: string },

	--[[
		Stock fallback clips.
		Roblox's own sword swings: they need no asset ownership and load for every
		account, so a rig with nothing authored still animates. Keys are prefixed so
		they can never collide with an authored slot (the Animations cache is keyed by
		name, not by scope), and R15 clips cannot drive an R6 rig, so each rig type
		carries its own ids. CombatController plays these at
		AnimationPriority.Action4, above the default `Animate` layers.
	]]
	Stock = {
		R15 = {
			StockSlash = "rbxassetid://507770238",
			StockHeavy = "rbxassetid://507770453",
		},
		R6 = {
			-- Only one stock slash exists for R6; the finisher reuses it.
			StockSlash = "rbxassetid://129961376",
			StockHeavy = "rbxassetid://129961376",
		},
	} :: { [string]: { [string]: string } },

	-- Enemy clips. The wave rigs are R6 and script-driven, so these are additive:
	-- when they are empty EnemyAI plays its procedural stride instead.
	Enemy = {
		Walk = "",
		Run = "",
		Windup = "",
		Strike = "",
		Stagger = "",
	} :: { [string]: string },

	-- When no id is configured, an `Animation` instance carrying one of these names
	-- under the character is used instead -- the drag-and-drop way to ship anims.
	Aliases = {
		Slash1 = { "Slash1", "SlashA", "RisingCut" },
		Slash2 = { "Slash2", "SlashB", "CrossedSteel" },
		Heavy = { "Heavy", "Slash3", "HeavensFall", "Finisher" },
		Guard = { "Guard", "Block", "ParryGuard" },
		Parry = { "Parry", "Riposte" },
		Walk = { "Walk", "WalkAnim" },
		Run = { "Run", "RunAnim", "Sprint" },
		Windup = { "Windup", "WindUp", "Telegraph" },
		Strike = { "Strike", "Attack", "EnemySlash" },
		Stagger = { "Stagger", "Hit", "Impact" },
	} :: { [string]: { string } },

	-- Default blend in/out for a combat track, in seconds.
	FadeTime = 0.08,
}

-- Katana ribbon presentation; KatanaFactory owns the instances.
CombatConfig.Trail = {
	-- Seconds a blade segment lingers: long enough to read, short enough to snap.
	Lifetime = 0.16,
	-- 1 feeds the ribbon into Bloom, which is what makes the blade read as glowing.
	LightEmission = 1,
	-- Thin white core drawn inside the coloured ribbon.
	CoreColor = Color3.fromRGB(255, 255, 255),
	CoreWidthScale = 0.4,
	CoreTransparency = 0.2,
}

CombatConfig.Fx = {
	SlashColor = Color3.fromRGB(228, 236, 245),
	ParryColor = Color3.fromRGB(255, 214, 108),
	ShadowDashColor = Color3.fromRGB(88, 34, 122),
	DodgeColor = Color3.fromRGB(160, 214, 255),
	-- The mid-air jump's puff, and the DoubleJump perk's card colour.
	AirJumpColor = Color3.fromRGB(150, 224, 255),
	HitSpark = "rbxasset://textures/particles/sparkles_main.dds",
	-- Stock client sounds: swap for uploaded asset ids for final polish.
	ParryClash = "rbxasset://sounds/swordslash.wav",
	ParryClashAccent = "rbxasset://sounds/electronicpingshort.wav",
	DodgeWhoosh = "rbxasset://sounds/action_falling.mp3",
	BlockThud = "rbxasset://sounds/impact_water.mp3",
	EnemyDeath = "rbxasset://sounds/uuhhh.mp3",
	PerkSelect = "rbxasset://sounds/electronicpingshort.wav",
	WaveClear = "rbxasset://sounds/electronicpingshort.wav",
}

CombatConfig.Camera = {
	BaseFov = 70,
	-- FOV spring: how fast the camera returns to rest (higher = snappier).
	FovRecovery = 7,
	-- Trauma decay per second. Faster decay = the camera settles between swings.
	ShakeDecay = 2.2,
	MaxShakeDegrees = 2.6,
	MaxShakeOffset = 0.2,

	--[[
		Global feel multipliers, applied to every kick the client raises (swing,
		impact, parry, hit, death). Melee puts the camera very close to the action, so
		these exist as the first dial to turn when the picture feels busy -- they scale
		the whole camera language at once instead of retuning each call site.
	]]
	ShakeScale = 0.6,
	RollScale = 0.55,
	FovScale = 0.7,
	-- The shake's roll (Z) axis reads as nausea rather than impact; damp it harder.
	ShakeRollDamping = 0.35,

	--[[
		Mouse-look lock: the camera follows raw mouse movement with no right-click
		hold (MouseBehavior.LockCenter), and the cursor is handed straight back the
		moment a menu takes over.
	]]
	Lock = {
		MinZoom = 5,
		MaxZoom = 16,
		DefaultZoom = 11,
		HideCursor = true,
		-- A ScreenGui flagged with this attribute (value `true`) also frees the cursor.
		MenuAttribute = "CB_Menu",
		-- How often the lock is re-asserted, in seconds. Cheap enough to be tiny.
		RepairInterval = 0.25,
	},
}

-- ---------------------------------------------------------------------------
-- Server-side validation budget
-- ---------------------------------------------------------------------------

CombatConfig.Validation = {
	-- Extra studs granted to every hitbox to absorb latency.
	ReachGrace = 2.5,
	-- Minimum time between accepted attack requests from one client.
	MinAttackInterval = 0.08,
	-- Maximum vertical difference allowed between attacker and victim.
	MaxHeightDelta = 9,
	-- Dodge direction must be a sane unit vector; anything longer is normalized.
	MaxDodgeMagnitude = 500,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local ComboSteps = CombatConfig.Combo.Steps
local EnemyIndex = CombatConfig.Enemies :: { [string]: EnemyArchetype }

-- Safe archetype lookup; callers always get an optional.
function CombatConfig.getEnemyArchetype(id: string): EnemyArchetype?
	return EnemyIndex[id]
end

-- Returns the combo step for a 1-based index, clamped to the finisher.
function CombatConfig.getComboStep(index: number): ComboStep
	local clamped = math.clamp(math.floor(index), 1, #ComboSteps)
	return ComboSteps[clamped]
end

-- Scales a raw config duration by attack speed.
function CombatConfig.scaleTime(seconds: number, stats: Stats): number
	return seconds / math.max(stats.attackSpeed, 0.1)
end

-- Fresh baseline stat block for a player with no perks.
function CombatConfig.baseStats(): Stats
	return {
		maxHealth = CombatConfig.Player.MaxHealth,
		damageMultiplier = 1,
		attackSpeed = 1,
		parryWindow = CombatConfig.Timings.ParryWindow,
		parryCooldown = CombatConfig.Timings.ParryCooldown,
		parryStun = CombatConfig.Timings.ParryStun,
		counterWindow = CombatConfig.Timings.CounterWindow,
		counterDamageMultiplier = 2,
		dodgeCooldown = CombatConfig.Timings.DodgeCooldown,
		dodgeInvincibility = CombatConfig.Timings.DodgeInvincibility,
		dodgeDuration = CombatConfig.Timings.DodgeDuration,
		dodgeSpeed = CombatConfig.Player.DashSpeed,
		comboTimeout = CombatConfig.Timings.ComboTimeout,
		blockReduction = CombatConfig.Block.DamageReduction,
		lifestealPerParry = CombatConfig.Player.LifestealPerParry,
		instantPoiseBreak = false,
		shadowDash = false,
		extraJumps = CombatConfig.Player.AirJumps,
	}
end

-- Turns a degree pose into a rotation applied around the shoulder joint.
function CombatConfig.poseToCFrame(pose: Vector3Pose): CFrame
	return CFrame.Angles(math.rad(pose.x), math.rad(pose.y), math.rad(pose.z))
end

-- Frame-rate independent smoothing factor.
function CombatConfig.smooth(deltaTime: number, speed: number): number
	return 1 - math.exp(-speed * deltaTime)
end

return CombatConfig
