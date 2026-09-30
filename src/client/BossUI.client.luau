--!strict
--[[
	BossUI (LocalScript)
	--------------------
	The boss channel's face: a top-of-screen health bar and a one-off announcement.

	Driven entirely by the `BossState` RemoteEvent:

		Incoming  -> WaveManager raises the bar in a "summoning" state and this
		             script flashes the announcement
		Fight     -> EnemyAI owns it: the bar tracks `health / maxHealth`
		Defeated  -> bar fades away, a short flourish plays

	Everything it shows comes from the server payload, so a boss can never be
	faked client-side, and the bar is keyed by `wave` so a stale packet from the
	previous boss cannot repaint a live fight.

	The ordinary wave banner is PerkUI's job; this script only ever speaks about
	bosses, which is why it lives apart from the perk card overlay.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local BOSS = CombatConfig.Boss
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local bossRemote = Remotes.client(Remotes.Names.BossState)

type BossPayload = {
	active: boolean,
	wave: number,
	phase: string,
	name: string?,
	health: number?,
	maxHealth: number?,
}

local PALETTE = {
	Panel = Color3.fromRGB(18, 12, 14),
	Ink = Color3.fromRGB(240, 236, 236),
	Muted = Color3.fromRGB(168, 158, 158),
	Track = Color3.fromRGB(10, 8, 9),
}

-- ---------------------------------------------------------------------------
-- Root
-- ---------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "BossUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
-- Above the combat HUD, below the perk cards (30): a decision outranks a bar.
gui.DisplayOrder = 25
gui.Parent = playerGui

local function corner(parent: Instance, radius: number): UICorner
	local instance = Instance.new("UICorner")
	instance.CornerRadius = UDim.new(0, radius)
	instance.Parent = parent
	return instance
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local instance = Instance.new("UIStroke")
	instance.Color = color
	instance.Thickness = thickness
	instance.Transparency = transparency
	instance.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	instance.Parent = parent
	return instance
end

-- ---------------------------------------------------------------------------
-- Announcement
-- ---------------------------------------------------------------------------

local announceLabel = Instance.new("TextLabel")
announceLabel.Name = "BossAnnounce"
announceLabel.AnchorPoint = Vector2.new(0.5, 0.5)
announceLabel.Position = UDim2.fromScale(0.5, 0.36)
announceLabel.Size = UDim2.fromOffset(1000, 96)
announceLabel.BackgroundTransparency = 1
announceLabel.Font = Enum.Font.GothamBlack
announceLabel.TextSize = 62
announceLabel.TextColor3 = BOSS.BarAccent
announceLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
announceLabel.TextStrokeTransparency = 0.3
announceLabel.TextTransparency = 1
announceLabel.Text = ""
announceLabel.Parent = gui

local announceToken = 0

local function announce(text: string, color: Color3)
	announceToken += 1
	local token = announceToken
	announceLabel.Text = text
	announceLabel.TextColor3 = color
	announceLabel.TextTransparency = 1
	TweenService:Create(announceLabel, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	task.delay(2.2, function()
		if announceToken ~= token then
			return
		end
		TweenService:Create(announceLabel, TweenInfo.new(0.7), { TextTransparency = 1 }):Play()
	end)
end

-- ---------------------------------------------------------------------------
-- Bar
-- ---------------------------------------------------------------------------

local bar = Instance.new("Frame")
bar.Name = "BossBar"
bar.AnchorPoint = Vector2.new(0.5, 0)
bar.Position = UDim2.new(0.5, 0, 0, 92)
bar.Size = UDim2.fromOffset(660, 64)
bar.BackgroundColor3 = PALETTE.Panel
bar.BackgroundTransparency = 0.12
bar.BorderSizePixel = 0
-- Starts down: a bar must never be on screen before a boss is announced.
bar.Visible = false
bar.Parent = gui
corner(bar, 10)
stroke(bar, BOSS.BarColor, 1.5, 0.25)

local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(42, 22, 24)),
	ColorSequenceKeypoint.new(1, PALETTE.Panel),
})
gradient.Parent = bar

local tag = Instance.new("TextLabel")
tag.Name = "Tag"
tag.Position = UDim2.fromOffset(14, 8)
tag.Size = UDim2.fromOffset(58, 20)
tag.BackgroundColor3 = BOSS.BarColor
tag.BackgroundTransparency = 0.15
tag.BorderSizePixel = 0
tag.Font = Enum.Font.GothamBlack
tag.TextSize = 13
tag.TextColor3 = Color3.fromRGB(20, 8, 8)
tag.Text = "BOSS"
tag.Parent = bar
corner(tag, 5)

local nameLabel = Instance.new("TextLabel")
nameLabel.Name = "Name"
nameLabel.Position = UDim2.fromOffset(80, 7)
nameLabel.Size = UDim2.new(1, -160, 0, 22)
nameLabel.BackgroundTransparency = 1
nameLabel.Font = Enum.Font.GothamBold
nameLabel.TextSize = 17
nameLabel.TextXAlignment = Enum.TextXAlignment.Center
nameLabel.TextColor3 = PALETTE.Ink
nameLabel.Text = ""
nameLabel.Parent = bar

local track = Instance.new("Frame")
track.Name = "Track"
track.Position = UDim2.fromOffset(14, 32)
track.Size = UDim2.new(1, -28, 0, 14)
track.BackgroundColor3 = PALETTE.Track
track.BackgroundTransparency = 0.1
track.BorderSizePixel = 0
track.Parent = bar
corner(track, 7)

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(1, 1)
fill.BackgroundColor3 = BOSS.BarColor
fill.BorderSizePixel = 0
fill.Parent = track
corner(fill, 7)

local healthText = Instance.new("TextLabel")
healthText.Name = "Value"
healthText.Position = UDim2.fromOffset(0, 46)
healthText.Size = UDim2.new(1, 0, 0, 16)
healthText.BackgroundTransparency = 1
healthText.Font = Enum.Font.GothamMedium
healthText.TextSize = 12
healthText.TextColor3 = PALETTE.Muted
healthText.Text = ""
healthText.Parent = bar

-- The "summoning" pulse, alive only between Incoming and the first Fight packet.
local pulseTween: Tween? = nil

local function stopPulse()
	local running = pulseTween
	if running then
		running:Cancel()
		pulseTween = nil
	end
	fill.BackgroundTransparency = 0
end

local function playPulse()
	stopPulse()
	fill.Size = UDim2.fromScale(1, 1)
	pulseTween = TweenService:Create(
		fill,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ BackgroundTransparency = 0.55 }
	)
	pulseTween:Play()
end

local function showBar()
	if not bar.Visible then
		bar.Visible = true
		bar.BackgroundTransparency = 1
		TweenService:Create(bar, TweenInfo.new(0.25), { BackgroundTransparency = 0.12 }):Play()
	end
end

local function hideBar(instant: boolean)
	stopPulse()
	if not bar.Visible then
		return
	end
	if instant then
		bar.Visible = false
		bar.BackgroundTransparency = 0.12
		return
	end
	local tween = TweenService:Create(bar, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
	tween:Play()
	tween.Completed:Connect(function()
		bar.Visible = false
		bar.BackgroundTransparency = 0.12
	end)
end

local function renderFight(payload: BossPayload)
	stopPulse()
	showBar()

	local maxHealth = if typeof(payload.maxHealth) == "number" and payload.maxHealth > 0 then payload.maxHealth else 1
	local health = if typeof(payload.health) == "number" then math.max(0, payload.health) else maxHealth
	local ratio = math.clamp(health / maxHealth, 0, 1)

	nameLabel.Text = payload.name or "Boss"
	track.Visible = true
	healthText.Text = `{math.ceil(health)} / {math.ceil(maxHealth)}`
	TweenService:Create(fill, TweenInfo.new(0.18), { Size = UDim2.fromScale(ratio, 1) }):Play()
	-- A low boss bar glows hotter, so the last stretch reads without reading numbers.
	fill.BackgroundColor3 = BOSS.BarColor:Lerp(BOSS.BarAccent, math.clamp(1 - ratio * 1.6, 0, 1))
end

local function renderIncoming(payload: BossPayload)
	nameLabel.Text = payload.name or "Boss"
	healthText.Text = "INCOMING"
	showBar()
	playPulse()
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- The wave a bar belongs to, so a late packet from a finished boss is ignored.
local liveWave = 0

bossRemote.OnClientEvent:Connect(function(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: BossPayload
	if typeof(data.wave) ~= "number" then
		return
	end

	local phase = data.phase
	if phase == "Incoming" then
		liveWave = data.wave
		renderIncoming(data)
		announce(BOSS.Announcement, BOSS.BarAccent)
	elseif phase == "Fight" then
		if not data.active then
			hideBar(false)
			return
		end
		liveWave = data.wave
		renderFight(data)
	elseif phase == "Defeated" then
		if data.wave ~= liveWave then
			return
		end
		liveWave = 0
		hideBar(false)
		announce("BOSS DEFEATED", BOSS.BarAccent)
	elseif not data.active then
		liveWave = 0
		hideBar(false)
	end
end)

-- The run can restart under a synced place; the bar has no business surviving a
-- respawn, and the server re-announces the next boss anyway.
player.CharacterAdded:Connect(function()
	liveWave = 0
	hideBar(true)
end)

print("[BossUI] Boss channel online.")
