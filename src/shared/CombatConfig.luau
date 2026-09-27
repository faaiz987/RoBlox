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
	bodyColor: Color3,
	accentColor: Color3,
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
		bodyColor = Color3.fromRGB(58, 54, 66),
		accentColor = Color3.fromRGB(196, 148, 82),
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
		bodyColor = Color3.fromRGB(96, 40, 44),
		accentColor = Color3.fromRGB(214, 96, 62),
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
		bodyColor = Color3.fromRGB(34, 38, 48),
		accentColor = Color3.fromRGB(126, 208, 244),
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
	-- Height of an enemy's root so its feet land on the baseplate.
	RigRootY = 3,
	-- Wave enemies appear on a ring between these distances from a defendant.
	SpawnMinDistance = 44,
	SpawnMaxDistance = 62,
	-- Hard ceiling so a late wave cannot melt the server.
	MaxAlive = 34,
}

--[[
	Rig lookup, in preference order. The game supports R6 and R15 avatars:
	server and client must agree on which joint carries the sword.
]]
CombatConfig.RigParts = {
	HandNames = { "RightHand", "Right Arm" },
	ShoulderJointNames = { "RightShoulder", "Right Shoulder" },
	KatanaName = "Katana",
	KatanaGripName = "KatanaGrip",
}

-- ---------------------------------------------------------------------------
-- Pose data (degrees) -- shared so server + client animate identically.
--   Angles are applied to the shoulder joint C0, pivoting on the real joint.
-- ---------------------------------------------------------------------------

CombatConfig.Poses = {
	-- Light slash: wind arm back, then cut through.
	SlashWindup = { x = -22, y = -16, z = 34 } :: Vector3Pose,
	SlashImpact = { x = 96, y = 12, z = -18 } :: Vector3Pose,
	SlashAlternate = { x = -16, y = 18, z = -34 } :: Vector3Pose,

	-- Heavy finisher: overhead raise, then a full body slam.
	HeavyWindup = { x = 152, y = 0, z = -12 } :: Vector3Pose,
	HeavyImpact = { x = 38, y = 0, z = 8 } :: Vector3Pose,

	-- Parry / guard: blade held vertical in front of the face.
	ParryGuard = { x = 118, y = -6, z = -8 } :: Vector3Pose,
	ParryRiposte = { x = 62, y = -18, z = -22 } :: Vector3Pose,

	-- Enemy windups are deliberately huge so the tell is unmissable.
	EnemyWindup = { x = 158, y = 0, z = -16 } :: Vector3Pose,
	EnemyUnparryableWindup = { x = 208, y = 0, z = 22 } :: Vector3Pose,
	EnemyStrike = { x = 30, y = 0, z = 10 } :: Vector3Pose,
	EnemyStagger = { x = -54, y = 0, z = 30 } :: Vector3Pose,
	EnemyStun = { x = -34, y = 0, z = 14 } :: Vector3Pose,
}

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

CombatConfig.Fx = {
	SlashColor = Color3.fromRGB(228, 236, 245),
	ParryColor = Color3.fromRGB(255, 214, 108),
	ShadowDashColor = Color3.fromRGB(88, 34, 122),
	DodgeColor = Color3.fromRGB(160, 214, 255),
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
	-- Trauma decay per second.
	ShakeDecay = 1.35,
	MaxShakeDegrees = 6,
	MaxShakeOffset = 0.55,
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
		extraJumps = 0,
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
