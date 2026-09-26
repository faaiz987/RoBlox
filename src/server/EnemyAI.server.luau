--!strict
--[[
	EnemyAI (Script)
	----------------
	Owns every wave enemy: its rig, its blade, its state machine and its telegraph.

	Readability rules (Ghost of Tsushima / Sekiro lineage):
	  * Every attack has a visible 1.0s windup. Slow, committed, unmissable.
	  * Parryable swings telegraph amber; "unparryable" flash cuts telegraph crimson
	    and must be dodged. Both write attributes so clients can render the tell.
	  * Getting parried stuns the attacker for 1.5s and opens it to a counter.

	Cross-script contract
	  in  : SpawnRequest          (SpawnEnemy bindable, from WaveManager)
	        EnemyHitReport        (EnemyHit bindable, from CombatServer)
	  out : EnemyKilled           (bindable, to WaveManager)
	        ParrySuccess          (bindable, to CombatServer -- pays the parry)
	        CombatFx              (remote, to every client)
	        attributes on the enemy model: Archetype, Poise, StunnedUntil,
	        StaggeredUntil, TelegraphEnds, TelegraphParryable, TelegraphLabel

	The rig is an anchored-root R6 body: the HumanoidRootPart is driven directly and
	the limbs follow through Motor6D joints, so movement is frame-perfect and free
	of network-ownership jitter.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local KatanaFactory = require(script.Parent.KatanaFactory)

local ATTR = CombatConfig.Attributes
local NAMES = Remotes.Names
local TAG = CombatConfig.Tags.Enemy
local POSES = CombatConfig.Poses
local TELEGRAPH = CombatConfig.Telegraph
local ARENA = CombatConfig.Arena

type Archetype = CombatConfig.EnemyArchetype
type Pose = CombatConfig.Vector3Pose
type Katana = KatanaFactory.Katana

type EnemyHitReport = {
	player: Player,
	damage: number,
	poiseDamage: number,
	knockback: number,
	direction: Vector3,
	heavy: boolean,
	counter: boolean,
}

type EnemyPhase = "Spawn" | "Chase" | "Windup" | "Recover" | "Stagger" | "Stun" | "Dead"

type Enemy = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	katana: Katana?,
	archetype: Archetype,
	phase: EnemyPhase,
	timer: number,
	nextAttackAt: number,
	stunUntil: number,
	staggerUntil: number,
	target: Player?,
	-- Lateral offset so a pack surrounds the player instead of stacking.
	orbit: number,
	-- Decaying impulse applied on top of steering (knockback).
	knockback: Vector3,
	unparryable: boolean,
	damageMultiplier: number,
	speedMultiplier: number,
	wave: number,
	telegraphActive: boolean,
}

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local fxRemote = Remotes.server(NAMES.CombatFx)
local spawnSignal = Remotes.signal(NAMES.SpawnEnemy)
local enemyHitSignal = Remotes.signal(NAMES.EnemyHit)
local enemyKilledSignal = Remotes.signal(NAMES.EnemyKilled)
local parrySuccessSignal = Remotes.signal(NAMES.ParrySuccess)

local enemyFolder = Instance.new("Folder")
enemyFolder.Name = "Enemies"
enemyFolder.Parent = workspace

-- Live enemies by model; `order` keeps iteration cheap and allocation free.
local active: { [Model]: Enemy } = {}
local order: { Model } = {}

local STAGGER_TIME = 0.85
local SPAWN_GRACE = 0.5
local KNOCKBACK_DECAY = 9

local function broadcastFx(payload: Remotes.FxPayload)
	fxRemote:FireAllClients(payload)
end

local function flat(vector: Vector3): Vector3
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	if horizontal.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return horizontal.Unit
end

-- ---------------------------------------------------------------------------
-- Rig construction
-- ---------------------------------------------------------------------------

-- Local layout, measured from the HumanoidRootPart (root y = feet + 3).
local PART_LAYOUT = {
	{ name = "Torso", size = Vector3.new(2, 2, 1), offset = Vector3.new(0, 0, 0) },
	{ name = "Head", size = Vector3.new(1.5, 1.5, 1.5), offset = Vector3.new(0, 1.75, 0) },
	{ name = "Right Arm", size = Vector3.new(1, 2, 1), offset = Vector3.new(1.5, 0, 0) },
	{ name = "Left Arm", size = Vector3.new(1, 2, 1), offset = Vector3.new(-1.5, 0, 0) },
	{ name = "Right Leg", size = Vector3.new(1, 2, 1), offset = Vector3.new(0.5, -2, 0) },
	{ name = "Left Leg", size = Vector3.new(1, 2, 1), offset = Vector3.new(-0.5, -2, 0) },
}

-- Joint pivot (in rig space) for every limb Motor6D.
local JOINT_PIVOTS = {
	{ name = "Right Shoulder", part = "Right Arm", pivot = Vector3.new(1, 1, 0) },
	{ name = "Left Shoulder", part = "Left Arm", pivot = Vector3.new(-1, 1, 0) },
	{ name = "Neck", part = "Head", pivot = Vector3.new(0, 1, 0) },
	{ name = "Right Hip", part = "Right Leg", pivot = Vector3.new(0.5, -1, 0) },
	{ name = "Left Hip", part = "Left Leg", pivot = Vector3.new(-0.5, -1, 0) },
}

local function newBodyPart(name: string, size: Vector3, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = transparency
	part.Anchored = name == "HumanoidRootPart"
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function newMotor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part0
	return motor
end

local function newSound(name: string, soundId: string, parent: Instance, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Volume = volume
	sound.RollOffMaxDistance = 220
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Parent = parent
	return sound
end

-- Builds one enemy rig, facing `lookAt`, with its feet planted at origin.Y.
local function createRig(archetype: Archetype, origin: Vector3, lookAt: Vector3): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = `{archetype.label}`
	model:SetAttribute(ATTR.Archetype, archetype.id)

	local root = newBodyPart("HumanoidRootPart", Vector3.new(2, 2, 1), archetype.bodyColor, 1)
	root.Parent = model

	local parts: { [string]: Part } = { HumanoidRootPart = root }

	for _, entry in PART_LAYOUT do
		local offset = entry.offset
		local color = if entry.name == "Head" then archetype.accentColor else archetype.bodyColor
		local part = newBodyPart(entry.name, entry.size, color, 0)
		part.CFrame = CFrame.new(offset)
		part.Parent = model
		parts[entry.name] = part
	end

	newMotor("RootJoint", root, parts.Torso, CFrame.new(), CFrame.new())
	for _, joint in JOINT_PIVOTS do
		local limb = parts[joint.part]
		local pivot = joint.pivot
		local limbCenter = limb.CFrame.Position
		-- C1 is the joint position expressed in the limb's own space.
		newMotor(
			joint.name,
			parts.Torso :: BasePart,
			limb,
			CFrame.new(pivot),
			CFrame.new(pivot - limbCenter)
		)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = archetype.health
	humanoid.Health = archetype.health
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.PlatformStand = true
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = model

	-- Presentation sounds travel with the rig.
	newSound("Telegraph", TELEGRAPH.ParryableSound, parts.Head, 0.55)
	newSound("Clash", CombatConfig.Fx.ParryClash, parts.Head, 0.7)
	newSound("Death", CombatConfig.Fx.EnemyDeath, parts.Head, 0.6)

	model.PrimaryPart = root
	model.Parent = enemyFolder

	local facing = flat(lookAt - origin)
	root.CFrame = CFrame.lookAt(Vector3.new(origin.X, origin.Y, origin.Z), Vector3.new(origin.X, origin.Y, origin.Z) + facing)

	return model, humanoid, root
end

local function playSound(model: Model, soundName: string, pitch: number?)
	local sound = model:FindFirstChild(soundName, true)
	if sound and sound:IsA("Sound") then
		sound.PlaybackSpeed = pitch or 1
		sound:Play()
	end
end

-- ---------------------------------------------------------------------------
-- Telegraphs
-- ---------------------------------------------------------------------------

local function clearTelegraph(enemy: Enemy)
	if not enemy.telegraphActive then
		return
	end
	enemy.telegraphActive = false
	enemy.model:SetAttribute(ATTR.TelegraphEnds, nil)
	enemy.model:SetAttribute(ATTR.TelegraphParryable, nil)
	enemy.model:SetAttribute(ATTR.TelegraphLabel, nil)
end

-- Publishes the windup on the *synced* clock so every client can draw the tell.
local function beginTelegraph(enemy: Enemy, duration: number)
	local endsAt = workspace:GetServerTimeNow() + duration
	enemy.telegraphActive = true
	enemy.model:SetAttribute(ATTR.TelegraphEnds, endsAt)
	enemy.model:SetAttribute(ATTR.TelegraphParryable, not enemy.unparryable)
	enemy.model:SetAttribute(ATTR.TelegraphLabel, if enemy.unparryable then TELEGRAPH.UnparryableLabel else TELEGRAPH.ParryableLabel)

	local katana = enemy.katana
	if katana then
		local pose = if enemy.unparryable then POSES.EnemyUnparryableWindup else POSES.EnemyWindup
		KatanaFactory.blendArm(katana, pose, 0.15)
	end
	playSound(enemy.model, if enemy.unparryable then "Clash" else "Telegraph", if enemy.unparryable then 1.35 else 0.95)
end

-- ---------------------------------------------------------------------------
-- Damage exchange
-- ---------------------------------------------------------------------------

local function stun(enemy: Enemy, duration: number)
	clearTelegraph(enemy)
	enemy.phase = "Stun"
	enemy.timer = duration
	enemy.stunUntil = os.clock() + duration
	enemy.nextAttackAt = math.max(enemy.nextAttackAt, enemy.stunUntil + 0.35)
	enemy.model:SetAttribute(ATTR.StunnedUntil, enemy.stunUntil)
	enemy.model:SetAttribute(ATTR.Poise, enemy.archetype.poise)

	local katana = enemy.katana
	if katana then
		KatanaFactory.poseArm(katana, POSES.EnemyStun)
	end
	playSound(enemy.model, "Clash", 0.8)
end

local function stagger(enemy: Enemy)
	local timestamp = os.clock()
	clearTelegraph(enemy)
	enemy.phase = "Stagger"
	enemy.timer = STAGGER_TIME
	enemy.staggerUntil = timestamp + STAGGER_TIME
	enemy.model:SetAttribute(ATTR.StaggeredUntil, enemy.staggerUntil)
	playSound(enemy.model, "Clash", 1.2)
	broadcastFx({
		action = "PoiseBreak",
		target = enemy.model,
		position = enemy.root.Position,
	})
end

local function parryEnemy(enemy: Enemy, player: Player, humanoid: Humanoid)
	local contact = (enemy.root.Position + (humanoid.RootPart and humanoid.RootPart.Position or enemy.root.Position)) * 0.5
	stun(enemy, CombatConfig.Timings.ParryStun)
	-- CombatServer pays the parry (lifesteal, counter window, clash FX).
	parrySuccessSignal:Fire(player, enemy.model, contact)
end

--[[
	The enemy's held attack resolves. Order matters:
	  dodge i-frames > parry window > guard reduction > clean hit.
]]
local function damagePlayer(enemy: Enemy, player: Player, humanoid: Humanoid, rootPart: BasePart)
	local timestamp = os.clock()
	local contact = (enemy.root.Position + rootPart.Position) * 0.5
	local direction = flat(rootPart.Position - enemy.root.Position)

	local iframes = player:GetAttribute(ATTR.InvulnerableUntil) or 0
	if typeof(iframes) == "number" and timestamp < iframes then
		broadcastFx({
			action = "Evaded",
			player = player,
			target = enemy.model,
			position = contact,
			direction = direction,
		})
		return
	end

	local parryUntil = player:GetAttribute(ATTR.ParryUntil) or 0
	if not enemy.unparryable and typeof(parryUntil) == "number" and timestamp < parryUntil then
		parryEnemy(enemy, player, humanoid)
		return
	end

	local damage = enemy.archetype.damage * enemy.damageMultiplier
	local blocked = player:GetAttribute(ATTR.Blocking) == true

	if blocked then
		local reduction = player:GetAttribute(ATTR.BlockReduction) or CombatConfig.Block.DamageReduction
		damage *= 1 - (if typeof(reduction) == "number" then reduction else CombatConfig.Block.DamageReduction)
		humanoid:TakeDamage(damage)
		broadcastFx({
			action = "Blocked",
			player = player,
			target = enemy.model,
			position = contact,
			direction = direction,
			amount = damage,
		})
		return
	end

	humanoid:TakeDamage(damage)
	broadcastFx({
		action = "PlayerHit",
		player = player,
		target = enemy.model,
		position = contact,
		direction = direction,
		amount = damage,
		stepKind = if enemy.unparryable then "Heavy" else "Slash",
	})
end

local function validTarget(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

-- Resolves the held swing against everyone inside the cone.
local function resolveStrike(enemy: Enemy)
	local look = flat(enemy.root.CFrame.LookVector)
	local minDot = math.cos(math.rad(enemy.archetype.attackHalfAngle))
	local range = enemy.archetype.attackRange + 1.5
	local origin = enemy.root.Position
	local hitSomething = false

	for _, player in Players:GetPlayers() do
		local humanoid, rootPart = validTarget(player)
		if humanoid and rootPart then
			local offset = rootPart.Position - origin
			local horizontal = Vector3.new(offset.X, 0, offset.Z)
			local distance = horizontal.Magnitude
			local inRange = distance <= range and math.abs(offset.Y) <= CombatConfig.Validation.MaxHeightDelta
			local inCone = distance < 1 or horizontal.Unit:Dot(look) >= minDot
			if inRange and inCone then
				damagePlayer(enemy, player, humanoid, rootPart)
				hitSomething = true
			end
		end
	end

	local katana = enemy.katana
	if katana then
		KatanaFactory.poseArm(katana, POSES.EnemyStrike)
		KatanaFactory.setTrail(katana, true)
		task.delay(0.12, function()
			KatanaFactory.setTrail(katana, false)
		end)
	end

	if not hitSomething then
		playSound(enemy.model, "Telegraph", 0.7)
	end
end

-- ---------------------------------------------------------------------------
-- Steering
-- ---------------------------------------------------------------------------

local function acquireTarget(enemy: Enemy): Player?
	local origin = enemy.root.Position
	local best: Player? = nil
	local bestDistance = math.huge
	for _, player in Players:GetPlayers() do
		local humanoid, rootPart = validTarget(player)
		if humanoid and rootPart then
			local distance = (rootPart.Position - origin).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = player
			end
		end
	end
	return best
end

local function moveToward(enemy: Enemy, targetRoot: BasePart, deltaTime: number)
	local current = enemy.root.Position
	local targetPosition = targetRoot.Position
	local toward = flat(targetPosition - current)
	local right = Vector3.new(-toward.Z, 0, toward.X)

	-- Hold a standoff ring with a lateral bias so the pack fans out.
	local desired = targetPosition - toward * (enemy.archetype.attackRange * 0.8) + right * enemy.orbit
	desired = Vector3.new(desired.X, current.Y, desired.Z)

	local delta = desired - current
	local distance = delta.Magnitude
	if distance > 0.08 then
		local speed = enemy.archetype.moveSpeed * enemy.speedMultiplier
		local travel = math.min(distance, speed * deltaTime)
		local nextPosition = current + delta.Unit * travel
		enemy.root.CFrame = CFrame.lookAt(nextPosition, nextPosition + toward)
	end
end

local function faceTarget(enemy: Enemy, targetPosition: Vector3, deltaTime: number, rate: number)
	local current = enemy.root.Position
	local toward = flat(targetPosition - current)
	local goal = CFrame.lookAt(current, current + toward)
	enemy.root.CFrame = enemy.root.CFrame:Lerp(goal, CombatConfig.smooth(deltaTime, rate))
end

-- ---------------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------------

local function updateEnemy(enemy: Enemy, deltaTime: number)
	local timestamp = os.clock()

	-- Knockback rides on top of steering and decays away.
	if enemy.knockback.Magnitude > 0.05 then
		local shift = enemy.knockback * deltaTime
		enemy.root.CFrame = enemy.root.CFrame + shift
		enemy.knockback = enemy.knockback * math.exp(-KNOCKBACK_DECAY * deltaTime)
	elseif enemy.knockback.Magnitude > 0 then
		enemy.knockback = Vector3.zero
	end

	if enemy.phase == "Dead" or enemy.phase == "Stun" or enemy.phase == "Stagger" then
		-- Stun/Stagger poses are applied once on entry; here we only count down.
		if enemy.timer > 0 then
			enemy.timer -= deltaTime
			if enemy.timer <= 0 and enemy.phase ~= "Dead" then
				enemy.phase = "Chase"
				enemy.model:SetAttribute(ATTR.StunnedUntil, 0)
				enemy.model:SetAttribute(ATTR.StaggeredUntil, 0)
				if katana then
					KatanaFactory.resetArm(katana)
				end
			end
		end
		return
	end

	-- Poise recovers while the enemy is not being poked.
	local maxPoise = enemy.archetype.poise
	local poise = enemy.model:GetAttribute(ATTR.Poise)
	if typeof(poise) == "number" and poise < maxPoise then
		enemy.model:SetAttribute(ATTR.Poise, math.min(maxPoise, poise + enemy.archetype.poiseRegen * deltaTime))
	end

	local target = enemy.target
	if target then
		local humanoid, rootPart = validTarget(target)
		if not humanoid or not rootPart then
			enemy.target = nil
			target = nil
		end
	end

	if not target then
		enemy.target = acquireTarget(enemy)
		target = enemy.target
		if not target then
			return
		end
	end

	local _, targetRoot = validTarget(target :: Player)
	if not targetRoot then
		enemy.target = nil
		return
	end

	if enemy.phase == "Spawn" then
		enemy.timer -= deltaTime
		if enemy.timer <= 0 then
			enemy.phase = "Chase"
			enemy.nextAttackAt = timestamp + 0.25
		end
		faceTarget(enemy, targetRoot.Position, deltaTime, 6)
		return
	end

	if enemy.phase == "Chase" then
		local distance = (targetRoot.Position - enemy.root.Position).Magnitude
		if distance <= enemy.archetype.attackRange and timestamp >= enemy.nextAttackAt then
			enemy.phase = "Windup"
			enemy.timer = enemy.archetype.windup
			beginTelegraph(enemy, enemy.archetype.windup)
		else
			moveToward(enemy, targetRoot, deltaTime)
			local katana = enemy.katana
			if katana then
				KatanaFactory.resetArm(katana)
			end
		end
		return
	end

	if enemy.phase == "Windup" then
		enemy.timer -= deltaTime
		local windup = enemy.archetype.windup
		local progress = math.clamp(1 - enemy.timer / windup, 0, 1)

		local katana = enemy.katana
		if katana then
			local pose = if enemy.unparryable then POSES.EnemyUnparryableWindup else POSES.EnemyWindup
			KatanaFactory.blendArm(katana, pose, math.min(progress * 1.6, 1))
		end

		-- Track the player early, then commit: sidestepping the last moment works.
		if progress < 0.55 then
			faceTarget(enemy, targetRoot.Position, deltaTime, 4)
		end

		if enemy.timer <= 0 then
			clearTelegraph(enemy)
			resolveStrike(enemy)
			enemy.phase = "Recover"
			enemy.timer = enemy.archetype.recovery
			enemy.nextAttackAt = timestamp + enemy.archetype.recovery + math.random() * 0.35
		end
		return
	end

	if enemy.phase == "Recover" then
		enemy.timer -= deltaTime
		local katana = enemy.katana
		if katana then
			local recovery = math.max(enemy.archetype.recovery, 0.01)
			KatanaFactory.blendArm(katana, POSES.EnemyStrike, math.clamp(enemy.timer / recovery, 0, 1))
		end
		if enemy.timer <= 0 then
			enemy.phase = "Chase"
			if katana then
				KatanaFactory.resetArm(katana)
			end
		end
		return
	end
end

-- ---------------------------------------------------------------------------
-- Birth and death
-- ---------------------------------------------------------------------------

local function fadeOut(model: Model, duration: number)
	local tweens = {} :: { Tween }
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "HumanoidRootPart" then
				table.insert(tweens, TweenService:Create(descendant, info, { Transparency = 1 }))
			end
		elseif descendant:IsA("Trail") then
			descendant.Enabled = false
		end
	end
	for _, tween in tweens do
		tween:Play()
	end
end

local function killEnemy(enemy: Enemy)
	if enemy.phase == "Dead" then
		return
	end
	enemy.phase = "Dead"
	clearTelegraph(enemy)
	CollectionService:RemoveTag(enemy.model, TAG)
	enemy.model:SetAttribute(ATTR.StunnedUntil, 0)
	enemy.model:SetAttribute(ATTR.StaggeredUntil, 0)

	local katana = enemy.katana
	if katana then
		KatanaFactory.poseArm(katana, POSES.EnemyStagger)
		KatanaFactory.setTrail(katana, false)
	end
	playSound(enemy.model, "Death", 0.9)

	broadcastFx({
		action = "EnemyDied",
		target = enemy.model,
		position = enemy.root.Position,
		stepKind = enemy.archetype.id,
	})

	enemyKilledSignal:Fire(enemy.model)
	fadeOut(enemy.model, SPAWN_GRACE + 0.25)
	Debris:AddItem(enemy.model, 1.4)
end

local function spawnEnemy(request: Remotes.SpawnRequest): Enemy?
	local archetype = CombatConfig.getEnemyArchetype(request.archetype)
	if not archetype then
		warn(`[EnemyAI] unknown archetype "{request.archetype}"`)
		return nil
	end
	if #order >= ARENA.MaxAlive then
		return nil
	end

	local health = archetype.health * (if request.healthMultiplier > 0 then request.healthMultiplier else 1)
	local model, humanoid, root = createRig(archetype, request.origin, request.lookAt)
	humanoid.MaxHealth = health
	humanoid.Health = health

	local enemy: Enemy = {
		model = model,
		humanoid = humanoid,
		root = root,
		katana = nil,
		archetype = archetype,
		phase = "Spawn",
		timer = SPAWN_GRACE,
		nextAttackAt = os.clock() + SPAWN_GRACE,
		stunUntil = 0,
		staggerUntil = 0,
		target = nil,
		orbit = (math.random() * 2 - 1) * 5,
		knockback = Vector3.zero,
		unparryable = request.unparryableOverride == true or archetype.unparryable,
		damageMultiplier = request.damageMultiplier,
		speedMultiplier = request.speedMultiplier,
		wave = request.wave,
		telegraphActive = false,
	}

	model:SetAttribute(ATTR.Poise, archetype.poise)
	model:SetAttribute(ATTR.MaxPoise, archetype.poise)
	model:SetAttribute(ATTR.StunnedUntil, 0)
	model:SetAttribute(ATTR.StaggeredUntil, 0)
	model:SetAttribute(ATTR.Knockback, 0)
	model:SetAttribute(ATTR.Wave, request.wave)

	enemy.katana = KatanaFactory.attach(model)
	CollectionService:AddTag(model, TAG)

	-- Spawn-in: fade the body up so a new wave never pops in out of nowhere.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			local original = descendant.Transparency
			descendant.Transparency = 1
			TweenService:Create(descendant, TweenInfo.new(SPAWN_GRACE), { Transparency = original }):Play()
		end
	end

	humanoid.Died:Connect(function()
		killEnemy(enemy)
	end)

	active[model] = enemy
	table.insert(order, model)
	return enemy
end

-- ---------------------------------------------------------------------------
-- Incoming hit reports (poise, stagger, knockback)
-- ---------------------------------------------------------------------------

enemyHitSignal.Event:Connect(function(model: Model, report: EnemyHitReport)
	local enemy = active[model]
	if not enemy or enemy.phase == "Dead" then
		return
	end

	local poise = enemy.model:GetAttribute(ATTR.Poise)
	local remaining = (if typeof(poise) == "number" then poise else enemy.archetype.poise) - report.poiseDamage

	if remaining <= 0 then
		enemy.model:SetAttribute(ATTR.Poise, enemy.archetype.poise)
		stagger(enemy)
	else
		enemy.model:SetAttribute(ATTR.Poise, remaining)
	end

	-- Knockback: heavy archetypes barely budge.
	local strength = report.knockback * (1 - math.clamp(enemy.archetype.knockbackResist, 0, 0.9))
	enemy.knockback = enemy.knockback + flat(report.direction) * strength

	if report.counter then
		enemy.nextAttackAt = math.max(enemy.nextAttackAt, os.clock() + 0.25)
	end
end)

spawnSignal.Event:Connect(function(request: Remotes.SpawnRequest)
	if typeof(request) ~= "table" then
		return
	end
	spawnEnemy(request)
end)

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

RunService.Heartbeat:Connect(function(deltaTime: number)
	local step = math.min(deltaTime, 0.1)
	for _, model in order do
		local enemy = active[model]
		if enemy and enemy.phase ~= "Dead" then
			updateEnemy(enemy, step)
		end
	end
end)

--[[
	Housekeeping sweeps the roster on a slow timer and rebuilds the array in one
	shot, so the Heartbeat iterator is never mutated underneath itself.
]]
task.spawn(function()
	while true do
		task.wait(2)
		local compacted = {} :: { Model }
		for _, model in order do
			if model.Parent ~= nil and active[model] ~= nil then
				table.insert(compacted, model)
			else
				active[model] = nil
			end
		end
		order = compacted
	end
end)

print("[EnemyAI] Wave enemies armed with telegraphed steel.")
