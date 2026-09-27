--!strict
--[[
	Animations
	----------
	Animation-track plumbing shared by the player controller and the enemy AI, with
	one hard guarantee: **loading never throws and never hands back a dead track**.

	Every combat animation in this game is optional. A key (e.g. "Slash1")
	resolves in this order:

	  1. An asset id from `CombatConfig.Animations` -- empty string means "not
	     authored yet", which is the state a freshly synced place is in.
	  2. An `Animation` instance named after the key or one of its aliases, found
	     under the model. This is how custom clips are dropped onto a rig without
	     touching code.
	  3. nil. Every caller treats nil as "use the procedural Motor6D fallback".

	A track is memoised per model+key, and it is only ever *played* once the engine
	reports a length for it (`Length > 0`), which is the engine's own signal that
	the asset actually loaded. Until then the caller's procedural path runs, so a
	typo in an id degrades into an animation-less-but-correct swing rather than a
	broken one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local Animations = {}

export type Kind = "Player" | "Enemy"

type Entry = {
	animation: Animation?,
	track: AnimationTrack?,
	usable: boolean,
}

local ANIM_CFG = CombatConfig.Animations
local DEFAULT_FADE: number = ANIM_CFG.FadeTime

local cache = {} :: { [Model]: { [string]: Entry } }

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

-- Which id table applies to this rig: R15 clips cannot drive R6 joints.
local function scopeFor(model: Model, kind: Kind): { [string]: string }
	if kind == "Enemy" then
		return ANIM_CFG.Enemy
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
		return ANIM_CFG.PlayerR6
	end
	return ANIM_CFG.Player
end

--[[
	Finds (or mints) the `Animation` instance for a key.
	Configured ids become named children of the humanoid so reloading a rig cannot
	leave a stale id behind; unconfigured keys fall back to whatever the rig ships.
]]
local function describe(model: Model, key: string, kind: Kind): Animation?
	local scope = scopeFor(model, kind)
	local id = scope[key]
	if id and id ~= "" then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local holder: Instance = if humanoid then humanoid else model
		local name = `CB_Anim_{key}`

		local existing = holder:FindFirstChild(name)
		if existing and existing:IsA("Animation") then
			if existing.AnimationId ~= id then
				existing.AnimationId = id
			end
			return existing
		end

		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id
		animation.Parent = holder
		return animation
	end

	local aliases: { string } = ANIM_CFG.Aliases[key] or { key }
	for _, alias in aliases do
		local found = model:FindFirstChild(alias, true)
		if found and found:IsA("Animation") then
			return found
		end
	end
	return nil
end

-- The rig's animator, created on demand (custom NPC rigs often ship without one).
local function animatorFor(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local found = humanoid:FindFirstChildOfClass("Animator")
	if found and found:IsA("Animator") then
		return found
	end
	local animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

-- True once the engine has proven the track's asset is live.
local function isUsable(entry: Entry): boolean
	if entry.usable then
		return true
	end
	local track = entry.track
	if track and track.Length > 0 then
		entry.usable = true
		return true
	end
	return false
end

local function entriesFor(model: Model): { [string]: Entry }
	local entries = cache[model]
	if not entries then
		entries = {}
		cache[model] = entries
	end
	return entries
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--[[
	Memoised track for `key`, or nil when the rig has no usable clip.
	Loading is attempted exactly once per model+key: a missing asset is not retried
	every swing.
]]
function Animations.track(model: Model, key: string, kind: Kind?): AnimationTrack?
	local entries = entriesFor(model)
	local entry = entries[key]

	if not entry then
		local fresh: Entry = { animation = nil, track = nil, usable = false }
		entries[key] = fresh
		entry = fresh

		local animation = describe(model, key, kind or "Player")
		local animator = animatorFor(model)
		if animation and animator then
			fresh.animation = animation
			local ok, loaded = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			if ok and loaded then
				fresh.track = loaded
			end
		end
	end

	local track = entry.track
	if track and isUsable(entry) then
		return track
	end
	return nil
end

--[[
	Plays a track and returns it, or returns nil so the caller runs its procedural
	fallback. `speed` scales playback (attack-speed perks), `weight` blends it
	against the rig's own locomotion.
]]
function Animations.play(
	model: Model,
	key: string,
	kind: Kind?,
	fadeTime: number?,
	speed: number?,
	weight: number?
): AnimationTrack?
	local track = Animations.track(model, key, kind)
	if not track then
		return nil
	end

	local ok = pcall(function()
		track:Play(fadeTime or DEFAULT_FADE, weight or 1, speed or 1)
	end)
	if not ok then
		-- A track that refuses to play is dropped so the fallback owns this swing.
		Animations.invalidate(model, key)
		return nil
	end
	return track
end

-- Fades a track out without clearing the cache.
function Animations.stop(model: Model, key: string, fadeTime: number?)
	local entries = cache[model]
	local entry = entries and entries[key]
	local track = entry and entry.track
	if not track then
		return
	end
	pcall(function()
		track:Stop(fadeTime or DEFAULT_FADE)
	end)
end

-- Fades every cached track for a rig (character died, enemy despawned).
function Animations.stopAll(model: Model, fadeTime: number?)
	local entries = cache[model]
	if not entries then
		return
	end
	for key in entries do
		Animations.stop(model, key, fadeTime)
	end
end

-- Forgets one key so the next call re-resolves and reloads it.
function Animations.invalidate(model: Model, key: string)
	local entries = cache[model]
	if entries then
		entries[key] = nil
	end
end

-- Drops a rig's whole cache; call when the character is destroyed.
function Animations.forget(model: Model)
	local entries = cache[model]
	if entries then
		for key, entry in entries do
			local track = entry.track
			if track then
				pcall(function()
					track:Stop(0)
				end)
			end
			entries[key] = nil
		end
	end
	cache[model] = nil
end

return Animations
