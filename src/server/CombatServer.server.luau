--!strict
--[[
	CombatServer (Script)
	---------------------
	The authority for everything a player *intends* to do:

	  * Attack  -> validates the combo clock, sweeps a spatial query, deals damage,
	               applies poise/knockback through EnemyAI, and reports the hit.
	  * Parry   -> opens a short parry window (or a damage-reducing guard stance).
	  * Dodge   -> grants invincibility frames and reports the dash direction.
	  * Perks   -> rolls the three post-wave cards and folds picked perks into stats.

	Trust model: the client only ever *asks*. Every request is checked against a
	server clock and a server-owned stat block before it touches the world.

	Replicated attributes written here (see CombatConfig.Attributes):
	  ParryActive, ParryUntil, InvulnerableUntil, Blocking, CounterUntil,
	  Perks, ExtraJumps, ShadowDash, AttackSpeed, ParryWindow, DodgeCooldown,
	  Lifesteal, InstantPoiseBreak, BlockReduction, DamageMultiplier, Wave
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local PerkDatabase = require(ReplicatedStorage.Shared.PerkDatabase)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local KatanaFactory = require(script.Parent.KatanaFactory)

local ATTR = CombatConfig.Attributes
local NAMES = Remotes.Names
local VALIDATION = CombatConfig.Validation

type Stats = CombatConfig.Stats
type Step = CombatConfig.ComboStep
type PerkId = PerkDatabase.PerkId

type PlayerState = {
	stats: Stats,
	perks: { PerkId },
	perkSet: { [string]: boolean },

	-- all clocks live on the server's os.clock() timeline
	lastAttackRequest: number,
	attackLockUntil: number,
	comboIndex: number,
	comboExpiresAt: number,
	parryUntil: number,
	parryCooldownUntil: number,
	dodgeCooldownUntil: number,
	invulnerableUntil: number,
	counterUntil: number,
	blocking: boolean,

	-- Perk ids currently on the player's cards (empty when no choice is open).
	offered: { PerkId },
	rng: Random,
}

-- Payload for the CombatServer -> EnemyAI hit report.
type EnemyHitReport = {
	player: Player,
	damage: number,
	poiseDamage: number,
	knockback: number,
	direction: Vector3,
	heavy: boolean,
	counter: boolean,
}

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local attackRemote = Remotes.server(NAMES.Attack)
local parryRemote = Remotes.server(NAMES.Parry)
local dodgeRemote = Remotes.server(NAMES.Dodge)
local selectPerkRemote = Remotes.server(NAMES.SelectPerk)
local fxRemote = Remotes.server(NAMES.CombatFx)
local perkChoiceRemote = Remotes.server(NAMES.PerkChoice)
local perkGrantedRemote = Remotes.server(NAMES.PerkGranted)

local enemyHitSignal = Remotes.signal(NAMES.EnemyHit)
local parrySuccessSignal = Remotes.signal(NAMES.ParrySuccess)
local perkSelectedSignal = Remotes.signal(NAMES.PerkSelected)
local waveClearedSignal = Remotes.signal(NAMES.WaveCleared)

-- Every player's live combat state, keyed by Player.
local states = {} :: { [Player]: PlayerState }

local function now(): number
	return os.clock()
end

local function broadcastFx(payload: Remotes.FxPayload)
	fxRemote:FireAllClients(payload)
end

-- ---------------------------------------------------------------------------
-- Stat plumbing
-- ---------------------------------------------------------------------------

local function recomputeStats(state: PlayerState)
	state.stats = PerkDatabase.computeStats(state.perks)
end

-- Mirrors the server-owned stat block onto attributes so clients can read it.
local function publishStats(player: Player, state: PlayerState)
	local stats = state.stats
	player:SetAttribute(ATTR.DamageMultiplier, stats.damageMultiplier)
	player:SetAttribute(ATTR.AttackSpeed, stats.attackSpeed)
	player:SetAttribute(ATTR.ParryWindow, stats.parryWindow)
	player:SetAttribute(ATTR.ParryCooldown, stats.parryCooldown)
	player:SetAttribute(ATTR.DodgeCooldown, stats.dodgeCooldown)
	player:SetAttribute(ATTR.ExtraJumps, stats.extraJumps)
	player:SetAttribute(ATTR.ShadowDash, stats.shadowDash)
	player:SetAttribute(ATTR.Lifesteal, stats.lifestealPerParry)
	player:SetAttribute(ATTR.InstantPoiseBreak, stats.instantPoiseBreak)
	player:SetAttribute(ATTR.BlockReduction, stats.blockReduction)
	player:SetAttribute(ATTR.Perks, PerkDatabase.encode(state.perks))
end

local function newState(): PlayerState
	local state = {
		stats = CombatConfig.baseStats(),
		perks = {} :: { PerkId },
		perkSet = {} :: { [string]: boolean },
		lastAttackRequest = 0,
		attackLockUntil = 0,
		comboIndex = 0,
		comboExpiresAt = 0,
		parryUntil = 0,
		parryCooldownUntil = 0,
		dodgeCooldownUntil = 0,
		invulnerableUntil = 0,
		counterUntil = 0,
		blocking = false,
		offered = {} :: { PerkId },
		rng = Random.new(os.clock() * 1e6 % 2 ^ 31),
	}
	recomputeStats(state)
	return state
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function setBlocking(player: Player, state: PlayerState, blocking: boolean)
	if state.blocking == blocking then
		return
	end
	state.blocking = blocking
	player:SetAttribute(ATTR.Blocking, blocking)

	local humanoid = getHumanoid(player)
	if humanoid then
		local base = CombatConfig.Player.WalkSpeed
		humanoid.WalkSpeed = if blocking then base * CombatConfig.Block.WalkSpeedMultiplier else base
	end
end

-- Clears transient combat flags (death, respawn, phase change).
local function resetTransientState(player: Player, state: PlayerState)
	state.parryUntil = 0
	state.parryCooldownUntil = 0
	state.dodgeCooldownUntil = 0
	state.invulnerableUntil = 0
	state.counterUntil = 0
	state.attackLockUntil = 0
	state.comboIndex = 0
	state.comboExpiresAt = 0
	setBlocking(player, state, false)
	player:SetAttribute(ATTR.ParryActive, false)
	player:SetAttribute(ATTR.InvulnerableUntil, 0)
	player:SetAttribute(ATTR.CounterUntil, 0)
end

-- ---------------------------------------------------------------------------
-- Spatial queries
-- ---------------------------------------------------------------------------

-- Root parts of every live, tagged wave enemy.
local function gatherEnemyRoots(): { BasePart }
	local roots = {} :: { BasePart }
	for _, enemy in CollectionService:GetTagged(CombatConfig.Tags.Enemy) do
		local root = enemy:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local humanoid = enemy:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				table.insert(roots, root)
			end
		end
	end
	return roots
end

-- ---------------------------------------------------------------------------
-- Attack resolution
-- ---------------------------------------------------------------------------

local function damageEnemy(player: Player, state: PlayerState, step: Step, enemy: Model, part: BasePart, look: Vector3)
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local stunnedUntil = enemy:GetAttribute(ATTR.StunnedUntil) or 0
	local counter = typeof(stunnedUntil) == "number" and stunnedUntil > now() and now() <= state.counterUntil

	local damage = step.damage * state.stats.damageMultiplier
	if counter then
		damage *= state.stats.counterDamageMultiplier
	end

	local instantBreak = state.stats.instantPoiseBreak and step.kind == "Heavy"
	local report: EnemyHitReport = {
		player = player,
		damage = damage,
		poiseDamage = if instantBreak then 999 else step.poiseDamage,
		knockback = step.knockback * (if step.kind == "Heavy" then 1.35 else 1),
		direction = look,
		heavy = step.kind == "Heavy",
		counter = counter,
	}

	humanoid:TakeDamage(damage)
	enemyHitSignal:Fire(enemy, report)
	broadcastFx({
		action = "Hit",
		player = player,
		target = enemy,
		position = part.Position,
		direction = look,
		amount = damage,
		stepKind = step.kind,
		stepName = step.name,
	})
end

--[[
	Sweeps a box in front of the attacker, then applies the cone/height checks.
	Runs after the step's windup so the hit lands on the animation, not the input.
]]
local function performStrike(player: Player, state: PlayerState, step: Step)
	local humanoid = getHumanoid(player)
	local root = getRoot(player)
	if not humanoid or not root then
		return
	end

	local candidates = gatherEnemyRoots()
	if #candidates == 0 then
		return
	end

	local flatLook = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	local look = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = candidates :: { Instance }
	overlap.MaxParts = 24

	local origin = root.Position
	local boxCenter = origin + Vector3.new(0, 1.5, 0) + look * (step.reach * 0.45)
	local boxCFrame = CFrame.lookAt(boxCenter, boxCenter + look)
	local boxSize = Vector3.new(step.radius * 2, 8, step.reach * 0.95)

	local minDot = math.cos(math.rad(step.halfAngle))
	local reach = step.reach + VALIDATION.ReachGrace

	for _, part in workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlap) do
		if part:IsDescendantOf(workspace) then
			local enemy = part:FindFirstAncestorOfClass("Model")
			if enemy and CollectionService:HasTag(enemy, CombatConfig.Tags.Enemy) then
				local offset = part.Position - origin
				local flat = Vector3.new(offset.X, 0, offset.Z)
				local distance = flat.Magnitude
				if distance <= reach and math.abs(offset.Y) <= VALIDATION.MaxHeightDelta then
					local insideCone = distance < 0.75 or flat.Unit:Dot(look) >= minDot
					if insideCone then
						damageEnemy(player, state, step, enemy, part, look)
					end
				end
			end
		end
	end
end

attackRemote.OnServerEvent:Connect(function(player: Player)
	local state = states[player]
	if not state then
		return
	end
	if not getHumanoid(player) then
		return
	end

	local timestamp = now()
	if timestamp - state.lastAttackRequest < VALIDATION.MinAttackInterval then
		return -- spam guard, cheap and boring to bypass
	end
	state.lastAttackRequest = timestamp

	if timestamp < state.attackLockUntil then
		return -- still recovering from the previous swing
	end

	local steps = CombatConfig.Combo.Steps
	local stepIndex: number
	if timestamp <= state.comboExpiresAt and state.comboIndex < #steps then
		stepIndex = state.comboIndex + 1
	else
		stepIndex = 1
	end

	local step = CombatConfig.getComboStep(stepIndex)
	local windup = CombatConfig.scaleTime(step.windup, state.stats)
	local recovery = CombatConfig.scaleTime(step.recovery, state.stats)

	local root = getRoot(player)
	state.comboIndex = stepIndex
	state.attackLockUntil = timestamp + windup + recovery
	state.comboExpiresAt = state.attackLockUntil + state.stats.comboTimeout

	-- Swinging drops a guard: no turtling through a combo.
	setBlocking(player, state, false)

	broadcastFx({
		action = "Swing",
		player = player,
		stepIndex = stepIndex,
		stepKind = step.kind,
		stepName = step.name,
		attackSpeed = state.stats.attackSpeed,
		position = if root then root.Position else nil,
	})

	task.delay(windup, function()
		-- The player may have died or left during the windup; re-check before hitting.
		if states[player] ~= state or not getHumanoid(player) then
			return
		end
		performStrike(player, state, step)
	end)
end)

-- ---------------------------------------------------------------------------
-- Parry & guard
-- ---------------------------------------------------------------------------

local function onParryRequest(player: Player, state: PlayerState, mode: string)
	local humanoid = getHumanoid(player)
	if not humanoid then
		return
	end

	if mode == "Guard" then
		setBlocking(player, state, true)
		return
	elseif mode == "Unguard" then
		setBlocking(player, state, false)
		return
	end

	local timestamp = now()
	if timestamp < state.parryCooldownUntil or timestamp < state.attackLockUntil then
		return
	end

	state.parryCooldownUntil = timestamp + state.stats.parryCooldown
	state.parryUntil = timestamp + state.stats.parryWindow
	player:SetAttribute(ATTR.ParryActive, true)
	player:SetAttribute(ATTR.ParryUntil, state.parryUntil)

	broadcastFx({
		action = "Parry",
		player = player,
		stepKind = "Parry",
		position = humanoid.RootPart and humanoid.RootPart.Position or nil,
	})

	local window = state.stats.parryWindow
	task.delay(window, function()
		if states[player] ~= state then
			return
		end
		if now() >= state.parryUntil then
			player:SetAttribute(ATTR.ParryActive, false)
		end
	end)
end

parryRemote.OnServerEvent:Connect(function(player: Player, mode: unknown)
	local state = states[player]
	if not state then
		return
	end
	if typeof(mode) == "string" then
		onParryRequest(player, state, mode :: string)
	else
		onParryRequest(player, state, "Parry")
	end
end)

-- EnemyAI reports a parry: pay the player for reading the telegraph.
parrySuccessSignal.Event:Connect(function(player: Player, enemy: Model, contactPoint: Vector3?)
	local state = states[player]
	if not state then
		return
	end

	local timestamp = now()
	state.counterUntil = timestamp + state.stats.counterWindow
	player:SetAttribute(ATTR.CounterUntil, state.counterUntil)
	player:SetAttribute(ATTR.ParryActive, false)

	-- A perfect read should not be punished by a long cooldown.
	state.parryCooldownUntil = math.min(state.parryCooldownUntil, timestamp + 0.12)

	local healed = 0
	local humanoid = getHumanoid(player)
	if humanoid and state.stats.lifestealPerParry > 0 then
		healed = humanoid.MaxHealth * state.stats.lifestealPerParry
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + healed)
	end

	broadcastFx({
		action = "ParrySuccess",
		player = player,
		target = enemy,
		position = contactPoint or (getRoot(player) and (getRoot(player) :: BasePart).Position) or nil,
		amount = healed,
	})
end)

-- ---------------------------------------------------------------------------
-- Dodge
-- ---------------------------------------------------------------------------

dodgeRemote.OnServerEvent:Connect(function(player: Player, directionHint: unknown)
	local state = states[player]
	if not state then
		return
	end

	local humanoid = getHumanoid(player)
	local root = getRoot(player)
	if not humanoid or not root then
		return
	end

	local timestamp = now()
	if timestamp < state.dodgeCooldownUntil then
		return
	end

	local direction = -root.CFrame.LookVector
	if typeof(directionHint) == "Vector3" then
		local hint = directionHint :: Vector3
		if hint.Magnitude > VALIDATION.MaxDodgeMagnitude then
			hint = hint.Unit * VALIDATION.MaxDodgeMagnitude
		end
		local flat = Vector3.new(hint.X, 0, hint.Z)
		if flat.Magnitude > 1e-3 then
			direction = flat.Unit
		end
	end

	state.dodgeCooldownUntil = timestamp + state.stats.dodgeCooldown
	local iframes = state.stats.dodgeInvincibility
	if state.stats.shadowDash then
		-- Shadow Dash: the whole dash is invincible, not just the opening slice.
		iframes = math.max(iframes, state.stats.dodgeDuration + 0.06)
	end
	state.invulnerableUntil = timestamp + iframes
	player:SetAttribute(ATTR.InvulnerableUntil, state.invulnerableUntil)

	setBlocking(player, state, false)
	broadcastFx({
		action = "Dodge",
		player = player,
		direction = direction,
		position = root.Position,
		shadow = state.stats.shadowDash,
	})

	task.delay(iframes, function()
		if states[player] == state and now() >= state.invulnerableUntil then
			player:SetAttribute(ATTR.InvulnerableUntil, 0)
		end
	end)
end)

-- ---------------------------------------------------------------------------
-- Perks
-- ---------------------------------------------------------------------------

local function grantPerk(player: Player, perkId: PerkId): boolean
	local state = states[player]
	if not state then
		return false
	end
	if state.perkSet[perkId] then
		return false
	end

	state.perkSet[perkId] = true
	table.insert(state.perks, perkId)
	recomputeStats(state)
	publishStats(player, state)

	local humanoid = getHumanoid(player)
	if humanoid and humanoid.MaxHealth ~= state.stats.maxHealth then
		local ratio = humanoid.Health / humanoid.MaxHealth
		humanoid.MaxHealth = state.stats.maxHealth
		humanoid.Health = math.max(1, humanoid.MaxHealth * ratio)
	end

	local perk = PerkDatabase.get(perkId)
	perkGrantedRemote:FireClient(player, {
		id = perkId,
		stats = {
			attackSpeed = state.stats.attackSpeed,
			parryWindow = state.stats.parryWindow,
			damageMultiplier = state.stats.damageMultiplier,
			dodgeCooldown = state.stats.dodgeCooldown,
			extraJumps = state.stats.extraJumps,
			shadowDash = state.stats.shadowDash,
			lifestealPerParry = state.stats.lifestealPerParry,
			instantPoiseBreak = state.stats.instantPoiseBreak,
		},
		perk = perk,
	})
	return true
end

selectPerkRemote.OnServerEvent:Connect(function(player: Player, perkId: unknown)
	local state = states[player]
	if not state then
		return
	end
	if typeof(perkId) ~= "string" then
		return
	end

	local id = perkId :: string
	if not table.find(state.offered :: { string }, id) then
		return -- not on this player's cards: ignore
	end

	table.clear(state.offered)
	grantPerk(player, id :: PerkId)
	-- Release the wave gate even on a duplicate pick, so a stale card can never
	-- stall WaveManager's intermission until its timeout.
	perkSelectedSignal:Fire(player)
end)

-- Rolls a fresh hand of cards for every living player and opens the overlay.
local function openPerkChoice(waveNumber: number)
	for _, player in Players:GetPlayers() do
		local state = states[player]
		if state and getHumanoid(player) then
			local pool = PerkDatabase.getRandomPerks(3, state.rng, state.perks)
			if #pool == 0 then
				-- Every perk owned: hand the player a full heal instead of a dead card.
				state.offered = {}
				local humanoid = getHumanoid(player)
				if humanoid then
					humanoid.Health = humanoid.MaxHealth
				end
				perkSelectedSignal:Fire(player)
			else
				local cards = table.create(#pool) :: { Remotes.PerkCard }
				local ids = table.create(#pool) :: { PerkId }
				for index, perk in pool do
					ids[index] = perk.id
					cards[index] = {
						id = perk.id,
						title = perk.title,
						description = perk.description,
						flavor = perk.flavor,
						glyph = perk.glyph,
						imageId = perk.imageId,
						rarity = perk.rarity,
						color = perk.color,
					}
				end
				state.offered = ids
				perkChoiceRemote:FireClient(player, { wave = waveNumber, cards = cards })
			end
		end
	end
end

waveClearedSignal.Event:Connect(function(waveNumber: number)
	if typeof(waveNumber) ~= "number" then
		return
	end
	openPerkChoice(waveNumber)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function onCharacterAdded(player: Player, state: PlayerState, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 15)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	humanoid.MaxHealth = state.stats.maxHealth
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = CombatConfig.Player.WalkSpeed
	humanoid.BreakJointsOnDeath = false

	KatanaFactory.attach(character)
	KatanaFactory.ensureWeld(character)
	resetTransientState(player, state)

	humanoid.Died:Connect(function()
		resetTransientState(player, state)
		local root = character:FindFirstChild("HumanoidRootPart")
		broadcastFx({
			action = "PlayerDied",
			player = player,
			position = if root and root:IsA("BasePart") then root.Position else nil,
		})
	end)
end

local function onPlayerAdded(player: Player)
	local state = newState()
	states[player] = state
	publishStats(player, state)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, state, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, state, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	local state = states[player]
	if state then
		states[player] = nil
	end
	if player.Character then
		KatanaFactory.forget(player.Character)
	end
end)

Remotes.publishAll()
print("[CombatServer] Combat authority online.")
