--!strict
--[[
	Remotes
	-------
	One registry for every cross-boundary channel, so no script has to guess at
	instance names and nothing gets created twice.

	  * RemoteEvent  -> ReplicatedStorage.Remotes.<Name>   (client <-> server)
	  * BindableEvent-> ServerStorage.ServerSignals.<Name> (server <-> server)

	Call `Remotes.server(name)` from the server (creates on demand) and
	`Remotes.client(name)` from the client (waits for replication).
	Fx payload types live here too: sender and receiver share one shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Remotes = {}

-- ---------------------------------------------------------------------------
-- Payload types
-- ---------------------------------------------------------------------------

-- `CombatFx.action` discriminator.
export type FxAction =
	"Swing"
	| "Hit"
	| "PlayerHit"
	| "Parry"
	| "ParrySuccess"
	| "Guard"
	| "Dodge"
	| "Blocked"
	| "Evaded"
	| "PoiseBreak"
	| "EnemySpawn"
	| "EnemyDied"
	| "PlayerDied"

export type FxPayload = {
	action: FxAction,
	-- Player that caused the event, when there is one.
	player: Player?,
	-- Enemy (or character) the event happened to.
	target: Instance?,
	-- World position for sparks / flashes.
	position: Vector3?,
	-- Unit direction for trails / knockback reads.
	direction: Vector3?,
	-- Damage dealt or health restored, when the event carries a number.
	amount: number?,
	-- 1-based combo step, when the event belongs to a swing.
	stepIndex: number?,
	stepKind: string?,
	stepName: string?,
	-- Shadow Dash was active for this dodge.
	shadow: boolean?,
	-- Effective attack speed of the actor, so observers can time the pose.
	attackSpeed: number?,
}

export type PerkCard = {
	id: string,
	title: string,
	description: string,
	flavor: string,
	glyph: string,
	imageId: string,
	rarity: string,
	color: Color3,
}

export type PerkChoicePayload = {
	wave: number,
	cards: { PerkCard },
}

export type WavePhase = "Idle" | "Intermission" | "Wave" | "PerkChoice"

export type WavePayload = {
	phase: WavePhase,
	wave: number,
	enemiesRemaining: number,
	enemiesTotal: number,
	-- Optional absolute deadline on the `workspace:GetServerTimeNow()` clock.
	endsAt: number?,
	-- Optional banner text pushed to every client.
	announcement: string?,
}

-- Server -> EnemyAI: spawn one enemy for a wave.
export type SpawnRequest = {
	archetype: string,
	origin: Vector3,
	lookAt: Vector3,
	wave: number,
	healthMultiplier: number,
	damageMultiplier: number,
	speedMultiplier: number,
	unparryableOverride: boolean?,
}

-- ---------------------------------------------------------------------------
-- Channel names
-- ---------------------------------------------------------------------------

Remotes.Names = {
	-- client -> server
	Attack = "Attack",
	Parry = "Parry",
	Dodge = "Dodge",
	SelectPerk = "SelectPerk",
	-- Main menu -> WaveManager: "I pressed PLAY". The run holds in Intermission
	-- until every player has sent it (or the lobby times out).
	StartWave = "StartWave",

	-- server -> client
	CombatFx = "CombatFx",
	PerkChoice = "PerkChoice",
	PerkGranted = "PerkGranted",
	WaveState = "WaveState",

	-- server -> server
	SpawnEnemy = "SpawnEnemy",
	EnemyKilled = "EnemyKilled",
	EnemyHit = "EnemyHit",
	ParrySuccess = "ParrySuccess",
	PerkSelected = "PerkSelected",
	WaveCleared = "WaveCleared",
} :: { [string]: string }

local REMOTE_NAMES: { string } = {
	Remotes.Names.Attack,
	Remotes.Names.Parry,
	Remotes.Names.Dodge,
	Remotes.Names.SelectPerk,
	Remotes.Names.StartWave,
	Remotes.Names.CombatFx,
	Remotes.Names.PerkChoice,
	Remotes.Names.PerkGranted,
	Remotes.Names.WaveState,
}

local SIGNAL_NAMES: { string } = {
	Remotes.Names.SpawnEnemy,
	Remotes.Names.EnemyKilled,
	Remotes.Names.EnemyHit,
	Remotes.Names.ParrySuccess,
	Remotes.Names.PerkSelected,
	Remotes.Names.WaveCleared,
}

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local REMOTE_FOLDER = "Remotes"
local SIGNAL_FOLDER = "ServerSignals"

local remoteCache = {} :: { [string]: RemoteEvent }
local signalCache = {} :: { [string]: BindableEvent }

local function buildSet(names: { string }): { [string]: boolean }
	local set = {} :: { [string]: boolean }
	for _, name in names do
		set[name] = true
	end
	return set
end

local REMOTE_SET = buildSet(REMOTE_NAMES)
local SIGNAL_SET = buildSet(SIGNAL_NAMES)

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

--[[
	Creates `ReplicatedStorage.Remotes` and every RemoteEvent in it, skipping any
	that already exist. The server calls this up front so clients never race on a
	channel; the client can call it too as a last-resort so a missing remote never
	kills a whole LocalScript.
]]
local function instantiateRemotes()
	local folder = ensureFolder(ReplicatedStorage, REMOTE_FOLDER)
	for _, name in REMOTE_NAMES do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			remoteCache[name] = existing
		else
			local event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
			remoteCache[name] = event
		end
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Server: fetch or create the RemoteEvent shared with clients.
function Remotes.server(name: string): RemoteEvent
	assert(RunService:IsServer(), "Remotes.server is server-only")
	assert(REMOTE_SET[name], `Unknown remote name "{name}"`)

	local cached = remoteCache[name]
	if cached then
		return cached
	end

	local folder = ensureFolder(ReplicatedStorage, REMOTE_FOLDER)
	local existing = folder:FindFirstChild(name)
	local event: RemoteEvent
	if existing and existing:IsA("RemoteEvent") then
		event = existing
	else
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
	end

	remoteCache[name] = event
	return event
end

-- Client: resolve the RemoteEvent the server published, creating it locally if
-- replication is late. Never blocks a script forever on a missing channel.
function Remotes.client(name: string): RemoteEvent
	assert(REMOTE_SET[name], `Unknown remote name "{name}"`)

	local cached = remoteCache[name]
	if cached and cached.Parent then
		return cached
	end

	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
	if not folder or not folder:IsA("Folder") then
		folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER, 10)
	end

	local instance: Instance? = if folder then folder:FindFirstChild(name) else nil
	if (not instance or not instance:IsA("RemoteEvent")) and folder then
		instance = folder:WaitForChild(name, 10)
	end

	if not instance or not instance:IsA("RemoteEvent") then
		-- Last resort: fabricate the whole folder so callers never error out.
		instantiateRemotes()
		local createdFolder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
		instance = if createdFolder then createdFolder:FindFirstChild(name) else nil
	end

	if not instance or not instance:IsA("RemoteEvent") then
		error(`RemoteEvent "{name}" could not be resolved`)
	end

	-- Explicit cast: after the guard above the instance is always a RemoteEvent.
	local event = instance :: RemoteEvent
	remoteCache[name] = event
	return event
end

-- Server: synchronous in-process signal (BindableEvent kept out of the DataModel).
function Remotes.signal(name: string): BindableEvent
	assert(RunService:IsServer(), "Remotes.signal is server-only")
	assert(SIGNAL_SET[name], `Unknown signal name "{name}"`)

	local cached = signalCache[name]
	if cached then
		return cached
	end

	local folder = ensureFolder(ServerStorage, SIGNAL_FOLDER)
	local existing = folder:FindFirstChild(name)
	local signal: BindableEvent
	if existing and existing:IsA("BindableEvent") then
		signal = existing
	else
		signal = Instance.new("BindableEvent")
		signal.Name = name
		signal.Parent = folder
	end

	signalCache[name] = signal
	return signal
end

-- Server: create every RemoteEvent up front so clients never race on first use.
function Remotes.publishAll()
	assert(RunService:IsServer(), "Remotes.publishAll is server-only")
	instantiateRemotes()
end

-- The server owns the canonical instances: build them the moment this module is
-- required so no client ever has to fall back to a local placeholder.
if RunService:IsServer() then
	instantiateRemotes()
end

return Remotes
