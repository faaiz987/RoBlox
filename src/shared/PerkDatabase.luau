--!strict
--[[
	PerkDatabase
	------------
	Registry of post-wave perks.

	A perk is pure data: an id, card presentation, and a bag of modifiers.
	`PerkDatabase.computeStats` folds a player's owned perks over the baseline
	stat block, so the server never needs bespoke logic per perk in the hot path.

	Adding a new perk:
	  1. append an entry to `PerkDatabase.Perks`
	  2. if it needs a brand new modifier, extend `PerkModifiers` + `computeStats`
]]

local CombatConfig = require(script.Parent.CombatConfig)

local PerkDatabase = {}

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

export type PerkId =
	"DoubleJump"
	| "PerfectWindow"
	| "BladeDance"
	| "ShadowDash"
	| "LifestealStance"
	| "Sunder"

export type Rarity = "Common" | "Rare" | "Mythic"

export type PerkModifiers = {
	damageMultiplier: number?,
	attackSpeedMultiplier: number?,
	parryWindowMultiplier: number?,
	parryCooldownMultiplier: number?,
	dodgeCooldownMultiplier: number?,
	dodgeInvincibilityBonus: number?,
	dodgeSpeedMultiplier: number?,
	lifestealPerParry: number?,
	instantPoiseBreak: boolean?,
	shadowDash: boolean?,
	extraJumps: number?,
	maxHealthBonus: number?,
	blockReductionBonus: number?,
}

export type Perk = {
	id: PerkId,
	title: string,
	-- Card body copy: one punchy sentence.
	description: string,
	-- Blade-ink flavour line shown under the description in italics.
	flavor: string,
	-- Glyph drawn on the card when `imageId` is empty.
	glyph: string,
	-- Optional uploaded icon; empty string falls back to `glyph`.
	imageId: string,
	rarity: Rarity,
	color: Color3,
	modifiers: PerkModifiers,
}

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

PerkDatabase.Perks = {
	{
		-- The id is the wire format for the perk list and stays put; the card is now
		-- the *second* air jump, since the first one is part of every player's kit.
		id = "DoubleJump",
		title = "Air Step",
		description = "A third jump: one more kick off the empty air than everyone gets.",
		flavor = '"The wind is a step, if you believe it is."',
		glyph = "⇈",
		imageId = "",
		rarity = "Common",
		color = Color3.fromRGB(120, 206, 255),
		modifiers = {
			extraJumps = 1,
		},
	} :: Perk,

	{
		id = "PerfectWindow",
		title = "Perfect Window",
		description = "+50% parry window. Catch steel in a far wider pocket of time.",
		flavor = '"Hear the intent before the blade."',
		glyph = "◈",
		imageId = "",
		rarity = "Mythic",
		color = Color3.fromRGB(255, 214, 108),
		modifiers = {
			parryWindowMultiplier = 1.5,
			parryCooldownMultiplier = 0.9,
		},
	} :: Perk,

	{
		id = "BladeDance",
		title = "Blade Dance",
		description = "+30% attack speed. Your three-hit stance flows like water.",
		flavor = '"Do not swing the sword. Let it continue."',
		glyph = "⚔",
		imageId = "",
		rarity = "Rare",
		color = Color3.fromRGB(255, 138, 92),
		modifiers = {
			attackSpeedMultiplier = 1.3,
		},
	} :: Perk,

	{
		id = "ShadowDash",
		title = "Shadow Dash",
		description = "Your dodge is invincible for the whole dash and leaves a spectral trail.",
		flavor = '"Where the body was, only smoke remains."',
		glyph = "➤",
		imageId = "",
		rarity = "Mythic",
		color = Color3.fromRGB(178, 118, 255),
		modifiers = {
			shadowDash = true,
			dodgeInvincibilityBonus = 0.2,
			dodgeSpeedMultiplier = 1.2,
			dodgeCooldownMultiplier = 0.9,
		},
	} :: Perk,

	{
		id = "LifestealStance",
		title = "Lifesteal Stance",
		description = "Every successful parry counter heals 10% of your maximum health.",
		flavor = '"Take their breath to keep your own."',
		glyph = "✚",
		imageId = "",
		rarity = "Rare",
		color = Color3.fromRGB(226, 78, 96),
		modifiers = {
			lifestealPerParry = 0.1,
		},
	} :: Perk,

	{
		id = "Sunder",
		title = "Sunder",
		description = "Heavy finishers shatter enemy poise instantly, staggering anything hit.",
		flavor = '"Stone breaks. So does pride."',
		glyph = "✹",
		imageId = "",
		rarity = "Rare",
		color = Color3.fromRGB(240, 196, 64),
		modifiers = {
			instantPoiseBreak = true,
			damageMultiplier = 1.05,
		},
	} :: Perk,
} :: { Perk }

-- O(1) lookup table, built once at require time.
PerkDatabase.ById = (function(): { [PerkId]: Perk }
	local index = {} :: { [PerkId]: Perk }
	for _, perk in PerkDatabase.Perks do
		index[perk.id] = perk
	end
	return index
end)();

-- Shared RNG for rolls that do not need per-player determinism.
PerkDatabase.random = Random.new(DateTime.now().UnixTimestampMillis % 2 ^ 31)

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

function PerkDatabase.get(id: string): Perk?
	return (PerkDatabase.ById :: { [string]: Perk })[id]
end

-- True when the perk id is part of the registry.
function PerkDatabase.isValidId(id: string): boolean
	return (PerkDatabase.ById :: { [string]: Perk })[id] ~= nil
end

-- ---------------------------------------------------------------------------
-- Rolling choices
-- ---------------------------------------------------------------------------

--[[
	Picks `count` distinct perks using an unbiased partial Fisher-Yates shuffle.

	`rng`       optional Random instance (the server rolls a seeded one per player)
	`exclude`   perk ids that must not appear again (already owned / already offered)
]]
function PerkDatabase.getRandomPerks(count: number, rng: Random?, exclude: { PerkId }?): { Perk }
	local random = rng or PerkDatabase.random

	local blocked = {} :: { [string]: boolean }
	for _, id in exclude or {} do
		blocked[id] = true
	end

	local pool = {} :: { Perk }
	for _, perk in PerkDatabase.Perks do
		if not blocked[perk.id] then
			table.insert(pool, perk)
		end
	end

	-- Partial shuffle: we only need the first `count` results.
	local wanted = math.clamp(math.floor(count), 0, #pool)
	for i = 1, wanted do
		local swapIndex = random:NextInteger(i, #pool)
		pool[i], pool[swapIndex] = pool[swapIndex], pool[i]
	end

	local chosen = table.create(wanted) :: { Perk }
	for i = 1, wanted do
		chosen[i] = pool[i]
	end
	return chosen
end

-- ---------------------------------------------------------------------------
-- Stat folding
-- ---------------------------------------------------------------------------

-- Applies one modifier bag to a live stat block. Mutates and returns it.
function PerkDatabase.applyModifiers(stats: CombatConfig.Stats, modifiers: PerkModifiers): CombatConfig.Stats
	stats.damageMultiplier *= modifiers.damageMultiplier or 1
	stats.attackSpeed *= modifiers.attackSpeedMultiplier or 1
	stats.parryWindow *= modifiers.parryWindowMultiplier or 1
	stats.parryCooldown *= modifiers.parryCooldownMultiplier or 1
	stats.dodgeCooldown = math.max(0.25, stats.dodgeCooldown * (modifiers.dodgeCooldownMultiplier or 1))
	stats.dodgeInvincibility += modifiers.dodgeInvincibilityBonus or 0
	stats.dodgeSpeed *= modifiers.dodgeSpeedMultiplier or 1
	stats.lifestealPerParry += modifiers.lifestealPerParry or 0
	stats.maxHealth += modifiers.maxHealthBonus or 0
	stats.instantPoiseBreak = stats.instantPoiseBreak or modifiers.instantPoiseBreak == true
	stats.shadowDash = stats.shadowDash or modifiers.shadowDash == true
	stats.extraJumps += modifiers.extraJumps or 0
	stats.blockReduction = math.clamp(stats.blockReduction + (modifiers.blockReductionBonus or 0), 0, 0.9)
	return stats
end

-- Rebuilds a full stat block from the baseline plus every owned perk.
function PerkDatabase.computeStats(perkIds: { PerkId }): CombatConfig.Stats
	local stats = CombatConfig.baseStats()
	for _, id in perkIds do
		local perk = PerkDatabase.get(id)
		if perk then
			PerkDatabase.applyModifiers(stats, perk.modifiers)
		end
	end
	return stats
end

-- Serialises perk ids for a replicated attribute.
function PerkDatabase.encode(perkIds: { PerkId }): string
	return table.concat(perkIds :: { string }, ",")
end

-- Parses a replicated perk attribute, dropping anything unrecognised.
function PerkDatabase.decode(packed: string?): { PerkId }
	local ids = {} :: { PerkId }
	if not packed or packed == "" then
		return ids
	end
	for token in string.gmatch(packed, "[^,]+") do
		if PerkDatabase.isValidId(token) then
			table.insert(ids, token :: PerkId)
		end
	end
	return ids
end

return PerkDatabase