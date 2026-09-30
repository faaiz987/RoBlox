--!strict
--[[
	MusicManager (LocalScript)
	--------------------------
	One looping music bed, crossfaded between three moods:

		Wave live              -> Combat
		Between waves          -> Intermission
		Title screen / options -> Menu   (falls back to Intermission)

	The ids live in `CombatConfig.Music` -- change one string and the whole game
	follows. This workspace cannot author an audio asset, so the slots ship empty
	and the manager stays silent until real ids are pasted in; everything else
	(looping, crossfade, menu ducking) is already wired.

	Why local: `SoundService` respects filtering, so a `Sound` created here is
	heard by this client only -- no per-player replication cost, no server state.

	The state is recomputed on a slow poll because two of its inputs (a menu
	ScreenGui's `CB_Menu` flag and Roblox's own menu) are not events this script
	can subscribe to. Everything else is event-driven.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MUSIC = CombatConfig.Music
local LOCK = CombatConfig.Camera.Lock

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local waveRemote = Remotes.client(Remotes.Names.WaveState)

type MusicState = "Combat" | "Intermission" | "Menu"

-- Which configured id each state plays. Menu with no id of its own falls back to
-- the intermission bed rather than cutting to silence on the title screen.
local STATE_ID: { [MusicState]: string } = {
	Combat = MUSIC.Combat,
	Intermission = MUSIC.Intermission,
	Menu = if MUSIC.Menu ~= "" then MUSIC.Menu else MUSIC.Intermission,
}

-- ---------------------------------------------------------------------------
-- Build the loop players
--   One Sound per *unique* id, so Menu and Intermission sharing an id costs one
--   instance rather than two of the same loop running at once. Every loop is
--   always Playing and volume is the only crossfade channel, which is what makes
--   the swap seamless instead of a restart with a gap in it.
-- ---------------------------------------------------------------------------

local FOLDER_NAME = "CB_Music"
local wouldPlay = false
for _, id in STATE_ID do
	if id ~= "" then
		wouldPlay = true
		break
	end
end

-- Re-running (a live Rojo sync restarts scripts) replaces, never doubles.
local previous = SoundService:FindFirstChild(FOLDER_NAME)
if previous then
	previous:Destroy()
end

local folder = Instance.new("Folder")
folder.Name = FOLDER_NAME
folder.Parent = SoundService

local soundsById: { [string]: Sound } = {}

local function makeSound(id: string): Sound
	local existing = soundsById[id]
	if existing then
		return existing
	end
	local sound = Instance.new("Sound")
	sound.Name = `Music_{#soundsById + 1}`
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.Playing = true
	sound.Parent = folder
	soundsById[id] = sound
	return sound
end

if MUSIC.Enabled and wouldPlay then
	for _, id in STATE_ID do
		if id ~= "" then
			makeSound(id)
		end
	end
elseif MUSIC.Enabled then
	print("[MusicManager] No music ids configured in CombatConfig.Music; staying silent.")
end

-- One late check so a typo'd / unpublished id is visible in the output instead of
-- silently quiet. Harmless when the asset is simply still streaming.
if MUSIC.Enabled and wouldPlay then
	task.delay(3, function()
		for _, sound in soundsById do
			if not sound.IsLoaded then
				print(`[MusicManager] {sound.SoundId} has not loaded -- is it published and audio-enabled?`)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Crossfade
-- ---------------------------------------------------------------------------

local currentState: MusicState? = nil

local function fadeSound(sound: Sound, targetVolume: number, duration: number)
	TweenService:Create(sound, TweenInfo.new(duration), { Volume = targetVolume }):Play()
end

local function applyState(state: MusicState)
	if not MUSIC.Enabled or not wouldPlay then
		return
	end

	local target = soundsById[STATE_ID[state]]

	for _, sound in soundsById do
		if sound == target then
			-- Long fade in so a wave starting does not slam the music on.
			fadeSound(sound, MUSIC.Volume, MUSIC.FadeIn)
		elseif sound.Volume > 0 then
			fadeSound(sound, 0, MUSIC.FadeOut)
		end
	end
	currentState = state
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local phase: string = "Idle"

--[[
	A menu ScreenGui is flagged `CB_Menu = true` (see CombatConfig.Camera.Lock);
	Roblox's own menu is the second door out of the game. Either one frees the
	cursor, so either one gets the calm track.
]]
local function menuOpen(): boolean
	if GuiService.MenuIsOpen then
		return true
	end
	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") and child.Enabled and child:GetAttribute(LOCK.MenuAttribute) == true then
			return true
		end
	end
	return false
end

local function desiredState(): MusicState
	if menuOpen() then
		return "Menu"
	end
	if phase == "Wave" then
		return "Combat"
	end
	return "Intermission"
end

local function refresh()
	if not MUSIC.Enabled or not wouldPlay then
		return
	end
	local wanted = desiredState()
	if wanted ~= currentState then
		applyState(wanted)
	end
end

waveRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: { phase: string? }
	if typeof(data.phase) == "string" then
		phase = data.phase
		refresh()
	end
end)

-- A menu opening or closing is not an event we own: poll, the same way the mouse
-- lock and the options hotkey do. Quarter second is far below what a human hears.
local clock = 0
RunService.Heartbeat:Connect(function(deltaTime: number)
	if not MUSIC.Enabled or not wouldPlay then
		return
	end
	clock += deltaTime
	if clock < 0.25 then
		return
	end
	clock = 0
	refresh()
end)

refresh()

if MUSIC.Enabled and wouldPlay then
	print("[MusicManager] Music online.")
end
