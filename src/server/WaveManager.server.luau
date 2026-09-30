--!strict
--[[
	WaveManager (Script)
	--------------------
	Paces the run:

		Intermission -> Wave -> (field cleared) -> PerkChoice -> Intermission -> ...

	  * Waves escalate on four axes at once: count, spawn rate, stats and the
	    share of unparryable flash attacks.
	  * Spawning pauses the moment the field is empty, and the
	    PerkChoice phase holds the next wave until every living player has picked
	    a card (or the choice window times out).

	Enemies are requested through the SpawnEnemy bindable and counted off the
	CB_WaveEnemy tag, so EnemyAI stays the single owner of their lifecycle.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local ATTR = CombatConfig.Attributes
local NAMES = Remotes.Names
local ARENA = CombatConfig.Arena
local TAG = CombatConfig.Tags.Enemy

local waveRemote = Remotes.server(NAMES.WaveState)
local bossRemote = Remotes.server(NAMES.BossState)
local startRemote = Remotes.server(NAMES.StartWave)
local spawnSignal = Remotes.signal(NAMES.SpawnEnemy)
local waveClearedSignal = Remotes.signal(NAMES.WaveCleared)
local perkSelectedSignal = Remotes.signal(NAMES.PerkSelected)
local enemyKilledSignal = Remotes.signal(NAMES.EnemyKilled)

type WavePlan = {
	wave: number,
	enemyCount: number,
	spawnInterval: number,
	maxConcurrent: number,
	healthMultiplier: number,
	damageMultiplier: number,
	speedMultiplier: number,
	unparryableChance: number,
	-- Relative spawn weights per archetype id.
	weights: { [string]: number },
	-- A boss plan spawns exactly one named boss instead of a crowd.
	isBoss: boolean,
	bossArchetype: string?,
}

local BOSS = CombatConfig.Boss

-- Pacing constants
local FIRST_WAVE_DELAY = 6
local INTERMISSION = 6
local PERK_CHOICE_TIMEOUT = 30
local FIELD_POLL = 0.5
-- How long the lobby waits for every player to press PLAY before the run starts
-- anyway, so one idle client can never hold the server hostage.
local START_TIMEOUT = 90

local phase: Remotes.WavePhase = "Idle"
local waveNumber = 0
local enemiesTotal = 0
local enemiesSpawned = 0
local runStarted = false
-- True while the live wave is a boss wave; carried on the WaveState payload.
local currentIsBoss = false
-- Players who have pressed PLAY on the main menu.
local readyPlayers = {} :: { [Player]: boolean }
local rng = Random.new(DateTime.now().UnixTimestampMillis % 2 ^ 31)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function livingPlayers(): { Player }
	local alive = {} :: { Player }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			table.insert(alive, player)
		end
	end
	return alive
end

local function aliveEnemyCount(): number
	return #CollectionService:GetTagged(TAG)
end

local function broadcast(announcement: string?, endsAt: number?)
	local payload: Remotes.WavePayload = {
		phase = phase,
		wave = waveNumber,
		enemiesRemaining = aliveEnemyCount(),
		enemiesTotal = enemiesTotal,
		endsAt = endsAt,
		announcement = announcement,
		boss = currentIsBoss,
	}
	waveRemote:FireAllClients(payload)
	for _, player in Players:GetPlayers() do
		player:SetAttribute(ATTR.Wave, waveNumber)
	end
end

local function sendState(player: Player)
	waveRemote:FireClient(player, {
		phase = phase,
		wave = waveNumber,
		enemiesRemaining = aliveEnemyCount(),
		enemiesTotal = enemiesTotal,
		announcement = nil,
		boss = currentIsBoss,
	} :: Remotes.WavePayload)
end

local function healParty(fraction: number)
	for _, player in livingPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * fraction)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Escalation curve
-- ---------------------------------------------------------------------------

local function isBossWave(wave: number): boolean
	return BOSS.EveryWaves > 0 and wave % BOSS.EveryWaves == 0
end

-- The archetype a boss wave rolls, walked in order so successive bosses alternate.
local function bossArchetypeFor(wave: number): string?
	local count = #BOSS.Archetypes
	if count == 0 then
		return nil
	end
	local index = math.floor(wave / BOSS.EveryWaves) - 1
	return BOSS.Archetypes[(index % count) + 1]
end

local function bossLabel(plan: WavePlan): string
	local id = plan.bossArchetype
	local archetype = if id then CombatConfig.getEnemyArchetype(id) else nil
	return if archetype then archetype.label else "Boss"
end

local function planFor(wave: number): WavePlan
	--[[
		Boss wave: one enemy, scaled harder than any crowd. The health and damage
		bonuses stack on top of the ordinary escalation, so a wave-2 boss is still a
		wall while a wave-12 boss is a wall the perks have to answer.
	]]
	if isBossWave(wave) then
		local id = bossArchetypeFor(wave)
		local weights: { [string]: number } = {}
		if id then
			weights[id] = 1
		end
		return {
			wave = wave,
			enemyCount = 1,
			spawnInterval = 0.5,
			maxConcurrent = 1,
			healthMultiplier = (1 + (wave - 1) * 0.16) * BOSS.HealthMultiplier,
			damageMultiplier = (1 + (wave - 1) * 0.1) * BOSS.DamageMultiplier,
			speedMultiplier = math.min(1.25, 1 + (wave - 1) * 0.03),
			unparryableChance = 0,
			weights = weights,
			isBoss = true,
			bossArchetype = id,
		}
	end

	local enemyCount = math.floor(4 + wave * 1.8 + math.max(0, wave - 6) * 1.4)
	local spawnInterval = math.max(0.28, 1.5 - (wave - 1) * 0.09)
	local maxConcurrent = math.min(ARENA.MaxAlive - 6, 8 + wave * 2)

	local weights: { [string]: number } = {
		Ronin = 100,
	}
	if wave >= 2 then
		weights.Shinobi = math.min(45, 12 + (wave - 2) * 6)
	end
	if wave >= 4 then
		weights.Brute = math.min(38, 10 + (wave - 4) * 7)
	end

	return {
		wave = wave,
		enemyCount = enemyCount,
		spawnInterval = spawnInterval,
		maxConcurrent = math.max(4, maxConcurrent),
		healthMultiplier = 1 + (wave - 1) * 0.16,
		damageMultiplier = 1 + (wave - 1) * 0.1,
		speedMultiplier = math.min(1.55, 1 + (wave - 1) * 0.045),
		unparryableChance = math.clamp(0.1 + (wave - 1) * 0.05, 0, 0.5),
		weights = weights,
		isBoss = false,
		bossArchetype = nil,
	}
end

local function pickArchetype(plan: WavePlan): string
	local total = 0
	for _, weight in plan.weights do
		total += weight
	end
	local roll = rng:NextNumber(0, total)
	local cursor = 0
	local last = "Ronin"
	for id, weight in plan.weights do
		cursor += weight
		last = id
		if roll <= cursor then
			return id
		end
	end
	return last
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

local function buildSpawnRequest(plan: WavePlan, archetype: string, anchor: Player): Remotes.SpawnRequest?
	local character = anchor.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local angle = rng:NextNumber(0, math.pi * 2)
	local spread = ARENA.SpawnMaxDistance - ARENA.SpawnMinDistance
	local distance = ARENA.SpawnMinDistance + rng:NextNumber(0, spread)
	local origin = root.Position + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)

	return {
		archetype = archetype,
		origin = Vector3.new(origin.X, ARENA.RigRootY, origin.Z),
		lookAt = root.Position,
		wave = waveNumber,
		healthMultiplier = plan.healthMultiplier,
		damageMultiplier = plan.damageMultiplier,
		speedMultiplier = plan.speedMultiplier,
		unparryableOverride = rng:NextNumber() < plan.unparryableChance,
		boss = plan.isBoss,
	}
end

-- Spawns the whole wave, throttled by the plan, then waits for the field to clear.
local function runWave(plan: WavePlan)
	phase = "Wave"
	enemiesSpawned = 0
	enemiesTotal = plan.enemyCount
	if plan.isBoss then
		-- The intermission already flashed the banner; raise the bar instead, and
		-- let EnemyAI own it from the moment the boss actually exists.
		bossRemote:FireAllClients({
			active = true,
			wave = waveNumber,
			phase = "Incoming",
			name = bossLabel(plan),
		} :: Remotes.BossPayload)
		broadcast()
	else
		broadcast(`WAVE {waveNumber}`)
	end

	while enemiesSpawned < enemiesTotal do
		local players = livingPlayers()
		if #players == 0 then
			-- Everyone is down: hold the wave instead of stacking the arena.
			task.wait(1)
		elseif aliveEnemyCount() >= plan.maxConcurrent then
			task.wait(FIELD_POLL)
		else
			local archetype = pickArchetype(plan)
			local anchor = players[rng:NextInteger(1, #players)]
			local request = buildSpawnRequest(plan, archetype, anchor)
			if request then
				spawnSignal:Fire(request)
				enemiesSpawned += 1
				broadcast()
			end
			task.wait(plan.spawnInterval)
		end
	end

	while aliveEnemyCount() > 0 do
		task.wait(FIELD_POLL)
		broadcast()
	end
end

-- ---------------------------------------------------------------------------
-- Perk choice pause
-- ---------------------------------------------------------------------------

local function waitForPicks()
	local picked = {} :: { [Player]: boolean }
	local connection = perkSelectedSignal.Event:Connect(function(player: Player)
		picked[player] = true
	end)

	local deadline = os.clock() + PERK_CHOICE_TIMEOUT
	while os.clock() < deadline do
		local players = livingPlayers()
		local pending = false
		for _, player in players do
			if not picked[player] then
				pending = true
				break
			end
		end
		if not pending or #players == 0 then
			break
		end
		task.wait(0.2)
	end

	connection:Disconnect()
end

local function intermission(seconds: number, announcement: string)
	phase = "Intermission"
	broadcast(announcement, workspace:GetServerTimeNow() + seconds)
	task.wait(seconds)
end

--[[
	Menu gate.
	The first wave belongs to the player: the run stays in "Idle" until every
	present player has asked for it through the main menu, or the lobby times out.
	A player who leaves is dropped from the tally, so the last one to press PLAY
	starts the fight immediately rather than waiting out the timeout.
]]
local function waitForStart(): boolean
	local deadline = os.clock() + START_TIMEOUT
	while os.clock() < deadline do
		local players = Players:GetPlayers()
		if #players > 0 then
			local pending = 0
			for _, player in players do
				if not readyPlayers[player] then
					pending += 1
				end
			end
			if pending == 0 then
				return true
			end
		end
		task.wait(0.25)
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Run loop
-- ---------------------------------------------------------------------------

enemyKilledSignal.Event:Connect(function()
	if phase == "Wave" then
		broadcast() -- keep the counter honest between polls
	end
end)

startRemote.OnServerEvent:Connect(function(player: Player)
	if runStarted then
		-- Already fighting: a late joiner's PLAY is a no-op, not an error.
		return
	end
	readyPlayers[player] = true
end)

Players.PlayerRemoving:Connect(function(player: Player)
	readyPlayers[player] = nil
end)

Players.PlayerAdded:Connect(function(player: Player)
	player:SetAttribute(ATTR.Wave, waveNumber)
	task.delay(2, function()
		if player.Parent then
			sendState(player)
		end
	end)
end)

task.spawn(function()
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end

	-- The menu owns the opening: nobody is thrown into wave 1 from a loading screen.
	if waitForStart() then
		print("[WaveManager] Lobby ready -- starting the run.")
	else
		print("[WaveManager] Start timed out -- starting the run anyway.")
	end
	runStarted = true

	intermission(FIRST_WAVE_DELAY, "PREPARE YOUR BLADE")

	while true do
		waveNumber += 1
		local plan = planFor(waveNumber)
		currentIsBoss = plan.isBoss
		runWave(plan)

		-- Field is empty: freeze the world and deal the cards.
		phase = "PerkChoice"
		enemiesTotal = 0
		currentIsBoss = false
		broadcast("WAVE CLEARED", workspace:GetServerTimeNow() + PERK_CHOICE_TIMEOUT)
		healParty(CombatConfig.Player.WaveClearHeal)
		waveClearedSignal:Fire(waveNumber)
		waitForPicks()

		-- Name the next wave before it starts, so a boss gets its own banner.
		if isBossWave(waveNumber + 1) then
			intermission(INTERMISSION, `BOSS INCOMING -- WAVE {waveNumber + 1}`)
		else
			intermission(INTERMISSION, `WAVE {waveNumber + 1} INCOMING`)
		end
	end
end)

print("[WaveManager] Escalation loop running.")
