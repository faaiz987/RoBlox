--!strict
--[[
	EnvironmentSetup (Script)
	-------------------------
	Builds the stage the waves are fought on, then lights it.

	  * A circular floor of dark cobblestone tiles laid out to
	    `CombatConfig.Arena.Radius`, with every tile top sitting on y = 0 -- so
	    `Arena.RigRootY` still drops enemy feet exactly onto the floor.
	  * A medieval palisade boundary: plank panels (collidable, so nobody walks off
	    the edge) capped with a beam and a jagged row of sharpened wooden stakes, a
	    crimson inner line, and eight wooden lamp posts carrying amber lanterns.
	  * Dusk lighting: 19:00 sun, dense horizon Atmosphere haze, Bloom to make the
	    blade ribbons glow, and a high-contrast ColorCorrection for the samurai look.

	Re-running is safe: the stage lives under one folder and is replaced, never
	doubled, which matters when a live Rojo sync restarts the script.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local ARENA = CombatConfig.Arena

-- ---------------------------------------------------------------------------
-- Stage settings (presentation lives here; geometry comes from CombatConfig)
-- ---------------------------------------------------------------------------

local SETTINGS = {
	ArenaName = "CB_Arena",
	-- The project file ships a flat Baseplate; the arena replaces it as the floor.
	RemoveBaseplate = true,

	-- Tiles sit in a grid with a seam between them; a solid bed under the seams keeps
	-- the sky from showing through the cracks (and the player from ever falling).
	TileGap = 0.45,
	TileThickness = 2,
	--[[
		Everything that stands on the floor is sunk this far into it.
		Coplanar faces are what makes a floor flicker: a wall base, a slab edge or a
		plate bottom sitting on exactly the same plane as the tile tops z-fights and
		shimmer as the camera moves. Overlapping is fine, shared planes are not.
	]]
	Sink = 0.3,
	-- The bed's surface sits just below the tiles, so the seams read as grooves.
	BedTopDrop = 0.25,
	BedColor = Color3.fromRGB(38, 38, 46),
	BedThickness = 6,
	BedMargin = 10,
	-- Stone reads as dark slate, not as a black hole: the arena has to be legible
	-- while you are reading enemy telegraphs off it.
	TileColor = Color3.fromRGB(72, 74, 86),
	TileColorAlt = Color3.fromRGB(90, 92, 104),
	TileColorWorn = Color3.fromRGB(104, 96, 104),

	InnerLineColor = Color3.fromRGB(255, 58, 62),
	RingThickness = 1.4,
	InnerLineHeight = 0.45,
	RingSegmentsPerStud = 0.22,

	--[[
		The boundary is a wooden palisade, not a neon ring. An emissive orange wall
		blooms (BloomThreshold sits at 1.4) and glares at the camera every match, and
		the wall a player duels in front of should look like something enemies would
		have built. These wood tones sit around a third of the old ring's brightness,
		which leaves the lanterns and the blade ribbons as the arena's only light.
	]]
	WallThickness = 2.4,
	WallColor = Color3.fromRGB(76, 55, 39),
	WallColorAlt = Color3.fromRGB(63, 45, 32),
	WallBeamColor = Color3.fromRGB(49, 35, 25),

	-- Sharpened stakes along the top. Spacing is centre to centre, so the row reads
	-- as separate logs, and every stake is jittered in height and tone.
	StakeSpacing = 2.6,
	StakeWidth = 1.7,
	StakeHeight = 3.6,
	StakeColor = Color3.fromRGB(98, 70, 46),
	StakeColorAlt = Color3.fromRGB(82, 58, 38),

	PillarCount = 8,
	-- Taller than the stake crest (14 wall + ~4 stake, both sunk into the floor), or
	-- the lanterns would be hidden behind the palisade from inside the arena.
	PillarHeight = 21,
	PillarWidth = 1.7,
	-- A wooden post carrying an amber lantern, instead of a glowing bar: the light
	-- stays, the glare does not.
	PillarWoodColor = Color3.fromRGB(66, 47, 33),
	LanternColor = Color3.fromRGB(255, 168, 92),
	-- Lamps have to actually reach the duelling ground, not just the wall.
	PillarLightRange = 72,
	PillarLightBrightness = 2.4,
	-- A soft warm pool over the spawn dais so the centre of the arena is never a
	-- dark void between lamp posts.
	DaisLightRange = 64,
	DaisLightBrightness = 1.8,

	-- The time-of-day knob. 17.5 is golden hour: the sun is still above the horizon,
	-- so there is a real key light and readable shadows. Pushing this towards 19-20
	-- gives the fully-neon night look -- expect to raise `Ambient` with it.
	ClockTime = 17.5,
	GeographicLatitude = 22,
	Brightness = 2.8,
	ExposureCompensation = 0.05,
	-- Ambient light is what stops Voxel lighting from rendering unlit stone as
	-- pure black. Both values matter: OutdoorAmbient is the one the arena sees.
	Ambient = Color3.fromRGB(86, 84, 96),
	OutdoorAmbient = Color3.fromRGB(112, 108, 122),
	EnvironmentDiffuseScale = 0.7,
	EnvironmentSpecularScale = 0.5,
	-- Softer shadows: hard-edged shadow acne on a big flat floor reads as flicker.
	ShadowSoftness = 0.6,

	-- A light haze, not a fog wall. High `Haze`/`Glare` is what washes the horizon
	-- into a blinding gold sheet, so both stay low and `BloomThreshold` stays high.
	AtmosphereDensity = 0.28,
	AtmosphereOffset = 0.22,
	AtmosphereColor = Color3.fromRGB(150, 146, 152),
	AtmosphereDecay = Color3.fromRGB(102, 104, 118),
	AtmosphereGlare = 0.06,
	AtmosphereHaze = 0.8,

	-- Bloom is a sword-glow effect here: only genuinely bright pixels (neon, blade
	-- ribbons) should bloom, never the sky.
	BloomIntensity = 0.7,
	BloomSize = 20,
	BloomThreshold = 1.4,

	Contrast = 0.08,
	Saturation = 0.04,
	ColorBrightness = 0.02,
	Tint = Color3.fromRGB(255, 250, 242),

	SunRaysIntensity = 0.02,
	SunRaysSpread = 0.55,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

--[[
	Picks a tile shade.
	Deterministic rather than random so two servers build the same arena, with a
	third "worn" tone speckled through it to break up the grid.
]]
local function tileColor(gridX: number, gridZ: number): Color3
	local speckle = (gridX * 7 + gridZ * 13) % 11
	if speckle == 0 then
		return SETTINGS.TileColorWorn
	end
	return if (gridX + gridZ) % 2 == 0 then SETTINGS.TileColor else SETTINGS.TileColorAlt
end

-- ---------------------------------------------------------------------------
-- Floor
-- ---------------------------------------------------------------------------

local function buildFloor(parent: Instance): Model
	local floor = Instance.new("Model")
	floor.Name = "Floor"

	-- The bed: one slab whose top face is the tile plane, so the seams read as dark
	-- stone rather than as holes into the void.
	local span = ARENA.Radius * 2 + SETTINGS.BedMargin
	local bed = newPart(
		"Bed",
		Vector3.new(span, SETTINGS.BedThickness, span),
		SETTINGS.BedColor,
		Enum.Material.Concrete
	)
	bed.CastShadow = false
	bed.Position = Vector3.new(0, -(SETTINGS.BedThickness * 0.5 + SETTINGS.BedTopDrop), 0)
	bed.Parent = floor

	local tile = ARENA.TileSize
	local gap = SETTINGS.TileGap
	local radius = ARENA.Radius
	local limit = math.floor(radius / tile)
	local radiusSquared = radius * radius
	local inner = tile - gap

	for gridX = -limit, limit do
		for gridZ = -limit, limit do
			local x = gridX * tile
			local z = gridZ * tile
			-- Keep the cells whose centre falls inside the disc: a round stage
			-- that still reads as a laid stone floor.
			if x * x + z * z <= radiusSquared then
				local part = newPart(
					`Tile_{gridX}_{gridZ}`,
					Vector3.new(inner, SETTINGS.TileThickness, inner),
					tileColor(gridX, gridZ),
					-- Slate rather than Cobblestone: a 132-piece floor of high-relief
					-- texture shimmers badly at grazing angles under sun + Bloom.
					Enum.Material.Slate
				)
				-- Tile *top* lands on y = 0, flush with the combat floor contract.
				part.Position = Vector3.new(x, -SETTINGS.TileThickness * 0.5, z)
				part.Parent = floor
			end
		end
	end

	floor.Parent = parent
	return floor
end

-- ---------------------------------------------------------------------------
-- Perimeter
-- ---------------------------------------------------------------------------

-- One ring of segments at `radius`, rotated to face the centre.
local function buildRing(name: string, radius: number, height: number, thickness: number, color: Color3): Model
	local ring = Instance.new("Model")
	ring.Name = name

	local circumference = 2 * math.pi * radius
	local segments = math.max(24, math.floor(circumference * SETTINGS.RingSegmentsPerStud))
	local segmentLength = circumference / segments

	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local part = newPart(
			`{name}_{index}`,
			Vector3.new(segmentLength, height, thickness),
			color,
			Enum.Material.Neon
		)
		part.CastShadow = false
		-- Facing the centre means the wall presents its flat face outward. The base is
		-- sunk into the floor so it never shares the tile plane.
		local position = Vector3.new(math.cos(angle) * radius, height * 0.5 - SETTINGS.Sink, math.sin(angle) * radius)
		part.CFrame = CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
		part.Parent = ring
	end

	-- Parented by the caller: the ring is a model, the caller owns the hierarchy.
	return ring
end

--[[
	Sharpened tops for the palisade.
	`Enum.MeshType.Pyramid` is a four-sided pyramid with its apex up -- a
	sharpened log exactly -- but it is an old mesh type, so the arena probes for it
	once. If it ever goes, stakes keep their shafts and simply cap blunt, instead of
	taking the whole build down with a failed enum lookup.
]]
local STAKE_MESH: Enum.MeshType? = nil
do
	local ok, meshType = pcall(function()
		return (Enum.MeshType :: any).Pyramid
	end)
	if ok then
		STAKE_MESH = meshType
	end
end

local function buildStakePoint(name: string, width: number, height: number, color: Color3): Part
	local point = newPart(name, Vector3.new(width, height, width), color, Enum.Material.Wood)
	point.CanCollide = false
	point.CastShadow = false
	local meshType = STAKE_MESH
	if meshType then
		local mesh = Instance.new("SpecialMesh")
		mesh.Name = "Spike"
		mesh.MeshType = meshType
		-- For a built-in mesh the Scale *is* the size in studs; the part's own Size
		-- only carries the selection box.
		mesh.Scale = Vector3.new(width, height, width)
		mesh.Parent = point
	else
		point.Size = Vector3.new(width * 0.7, height, width * 0.7)
	end
	return point
end

--[[
	The palisade: plank panels around the ring, a beam capping each panel, and a
	jagged row of sharpened stakes on top. Deterministic, like the floor -- two
	servers build the same wall. The panels are what keep the player in; the stakes
	are sculpture, which is why they carry no collision.
]]
local function buildSpikedWall(name: string, radius: number): Model
	local wall = Instance.new("Model")
	wall.Name = name

	local height = ARENA.WallHeight
	local thickness = SETTINGS.WallThickness
	local beamHeight = 1.1
	local circumference = 2 * math.pi * radius
	local segments = math.max(24, math.floor(circumference * SETTINGS.RingSegmentsPerStud))
	local segmentLength = circumference / segments
	-- A hair short of its slot: two panels sharing a face would z-fight down the
	-- whole ring, which is the floor comment's warning one storey up.
	local panelLength = segmentLength * 0.97

	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local position = Vector3.new(math.cos(angle) * radius, height * 0.5 - SETTINGS.Sink, math.sin(angle) * radius)
		-- Facing the centre, so the wall presents its flat face outward and the
		-- base is sunk into the floor instead of sharing the tile plane.
		local facing = CFrame.lookAt(position, Vector3.new(0, position.Y, 0))

		local plank = newPart(
			`{name}_Plank_{index}`,
			Vector3.new(panelLength, height, thickness),
			if index % 2 == 0 then SETTINGS.WallColor else SETTINGS.WallColorAlt,
			Enum.Material.WoodPlanks
		)
		-- No shadow casting anywhere on the perimeter: a fourteen-stud wall throws a
		-- long golden-hour shadow across the duelling floor, and the original ring
		-- was shadowless for the same reason.
		plank.CastShadow = false
		plank.CFrame = facing
		plank.Parent = wall

		-- The beam sits *into* the panels rather than on top of them: a shared plane
		-- at the wall's cap would shimmer as the camera moves.
		local beam = newPart(
			`{name}_Beam_{index}`,
			Vector3.new(segmentLength, beamHeight, thickness * 1.35),
			SETTINGS.WallBeamColor,
			Enum.Material.WoodPlanks
		)
		beam.CastShadow = false
		beam.CFrame = facing * CFrame.new(0, height * 0.5 - SETTINGS.Sink + beamHeight * 0.5 - 0.15, 0)
		beam.Parent = wall
	end

	-- Stakes: one per slot, sunk into the beam and jittered, so the crest reads as
	-- sharpened logs rather than as a fence.
	local stakes = math.max(8, math.floor(circumference / SETTINGS.StakeSpacing))
	local stakeBaseY = height - SETTINGS.Sink + beamHeight - 0.3

	for index = 1, stakes do
		local angle = (index / stakes) * math.pi * 2
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		local facing = CFrame.lookAt(Vector3.new(x, stakeBaseY, z), Vector3.new(0, stakeBaseY, 0))

		local jitter = 0.86 + (((index * 7) % 5) / 4) * 0.28
		local total = SETTINGS.StakeHeight * jitter
		local shaftHeight = total * 0.6
		local pointHeight = total - shaftHeight
		local width = SETTINGS.StakeWidth * (0.94 + (((index * 3) % 4) / 3) * 0.12)
		local color = if index % 3 == 0 then SETTINGS.StakeColorAlt else SETTINGS.StakeColor

		local shaft = newPart(
			`{name}_Stake_{index}`,
			Vector3.new(width, shaftHeight, width),
			color,
			Enum.Material.WoodPlanks
		)
		shaft.CanCollide = false
		shaft.CastShadow = false
		shaft.CFrame = facing * CFrame.new(0, shaftHeight * 0.5, 0)
		shaft.Parent = wall

		local point = buildStakePoint(`{name}_Spike_{index}`, width * 1.08, pointHeight, color)
		-- Nudged down into the shaft by a tenth of a stud, for the same reason the
		-- beam is nudged into the panels.
		point.CFrame = facing * CFrame.new(0, shaftHeight + pointHeight * 0.5 - 0.1, 0)
		point.Parent = wall
	end

	return wall
end

local function buildPerimeter(parent: Instance)
	local rings = Instance.new("Model")
	rings.Name = "Perimeter"

	local wall = buildSpikedWall("Boundary", ARENA.BoundaryRadius)
	wall.Parent = rings

	local line = buildRing(
		"InnerLine",
		ARENA.BoundaryRadius - 2.5,
		SETTINGS.InnerLineHeight,
		SETTINGS.RingThickness,
		SETTINGS.InnerLineColor
	)
	line.Parent = rings

	--[[
		Lamp posts just outside the wall, and the only warm light in the arena: a
		wooden post carrying a small amber lantern under a little hood. The glow comes
		from a lamp now, not from a sixteen-stud bar of neon.
	]]
	local pillarRadius = ARENA.BoundaryRadius + 2.6
	local postTop = SETTINGS.PillarHeight - SETTINGS.Sink
	for index = 1, SETTINGS.PillarCount do
		local angle = (index / SETTINGS.PillarCount) * math.pi * 2
		local x = math.cos(angle) * pillarRadius
		local z = math.sin(angle) * pillarRadius

		local post = newPart(
			`Pillar_{index}`,
			Vector3.new(SETTINGS.PillarWidth, SETTINGS.PillarHeight, SETTINGS.PillarWidth),
			SETTINGS.PillarWoodColor,
			Enum.Material.WoodPlanks
		)
		post.CastShadow = false
		post.Position = Vector3.new(x, SETTINGS.PillarHeight * 0.5 - SETTINGS.Sink, z)
		post.Parent = rings

		-- Lantern and hood are each sat a tenth of a stud into the piece below, so no
		-- two faces in the stack ever share a plane.
		local lantern = newPart(
			`Lantern_{index}`,
			Vector3.new(1.1, 1.1, 1.1),
			SETTINGS.LanternColor,
			Enum.Material.Neon
		)
		lantern.CastShadow = false
		lantern.Position = Vector3.new(x, postTop + 0.45, z)
		lantern.Parent = rings

		local hood = newPart(
			`LanternHood_{index}`,
			Vector3.new(1.7, 0.3, 1.7),
			SETTINGS.WallBeamColor,
			Enum.Material.WoodPlanks
		)
		hood.CastShadow = false
		hood.Position = Vector3.new(x, postTop + 1.05, z)
		hood.Parent = rings

		local light = Instance.new("PointLight")
		light.Name = "LampGlow"
		light.Color = SETTINGS.LanternColor
		light.Brightness = SETTINGS.PillarLightBrightness
		light.Range = SETTINGS.PillarLightRange
		light.Shadows = false
		light.Parent = lantern
	end

	rings.Parent = parent
end

-- ---------------------------------------------------------------------------
-- Spawn dais
-- ---------------------------------------------------------------------------	-- The centre plate, so the player always has ground underfoot at wave start.
	local function buildDais(parent: Instance)
	local dais = Instance.new("Model")
	dais.Name = "Dais"

	-- The plate floats a hair above the tile tops: a plate bottom sharing the tile
	-- plane is the other place this floor used to flicker.
	local plate = newPart("Plate", Vector3.new(18, 0.5, 18), SETTINGS.TileColorWorn, Enum.Material.Slate)
	plate.Position = Vector3.new(0, 0.3, 0)
	plate.Parent = dais

	local trim = newPart("Trim", Vector3.new(18.6, 0.2, 1), SETTINGS.InnerLineColor, Enum.Material.Neon)
	trim.CastShadow = false
	trim.Position = Vector3.new(0, 0.62, -8.8)
	trim.Parent = dais

	-- A lamp on the dais, so the middle of the arena is lit from within the fight
	-- rather than only from the perimeter.
	local lamp = newPart("DaisLamp", Vector3.new(0.7, 0.5, 0.7), SETTINGS.LanternColor, Enum.Material.Neon)
	lamp.CastShadow = false
	lamp.Position = Vector3.new(0, 0.75, 8.8)
	lamp.Parent = dais

	local daisLight = Instance.new("PointLight")
	daisLight.Name = "DaisGlow"
	daisLight.Color = SETTINGS.LanternColor
	daisLight.Brightness = SETTINGS.DaisLightBrightness
	daisLight.Range = SETTINGS.DaisLightRange
	daisLight.Shadows = false
	daisLight.Parent = lamp

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ArenaSpawn"
	spawn.Size = Vector3.new(10, 0.4, 10)
	spawn.CFrame = CFrame.new(0, 0.8, 0)
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = dais

	dais.Parent = parent
end

-- ---------------------------------------------------------------------------
-- Lighting
-- ---------------------------------------------------------------------------

-- Effect instances this script owns; a re-run replaces them instead of stacking.
local OWNED_EFFECTS = { "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" }

local function configureLighting()
	for _, child in Lighting:GetChildren() do
		if table.find(OWNED_EFFECTS, child.ClassName) then
			child:Destroy()
		end
	end

	-- Dusk: the sun is low, so the arena is read mostly by neon and Bloom.
	Lighting.ClockTime = SETTINGS.ClockTime
	Lighting.GeographicLatitude = SETTINGS.GeographicLatitude
	Lighting.Brightness = SETTINGS.Brightness
	Lighting.ExposureCompensation = SETTINGS.ExposureCompensation
	Lighting.Ambient = SETTINGS.Ambient
	Lighting.OutdoorAmbient = SETTINGS.OutdoorAmbient
	Lighting.EnvironmentDiffuseScale = SETTINGS.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = SETTINGS.EnvironmentSpecularScale
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = SETTINGS.ShadowSoftness
	Lighting.Outlines = false
	Lighting.ShadowColor = Color3.fromRGB(96, 92, 104)
	-- Legacy fog would fight the Atmosphere; push it out of the way.
	Lighting.FogEnd = 100000

	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = SETTINGS.AtmosphereDensity
	atmosphere.Offset = SETTINGS.AtmosphereOffset
	atmosphere.Color = SETTINGS.AtmosphereColor
	atmosphere.Decay = SETTINGS.AtmosphereDecay
	atmosphere.Glare = SETTINGS.AtmosphereGlare
	-- Dense horizon haze: the arena melts into the dusk skyline.
	atmosphere.Haze = SETTINGS.AtmosphereHaze
	atmosphere.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = SETTINGS.BloomIntensity
	bloom.Size = SETTINGS.BloomSize
	bloom.Threshold = SETTINGS.BloomThreshold
	bloom.Parent = Lighting

	local grade = Instance.new("ColorCorrectionEffect")
	grade.Contrast = SETTINGS.Contrast
	grade.Saturation = SETTINGS.Saturation
	grade.Brightness = SETTINGS.ColorBrightness
	grade.TintColor = SETTINGS.Tint
	grade.Parent = Lighting

	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = SETTINGS.SunRaysIntensity
	rays.Spread = SETTINGS.SunRaysSpread
	rays.Parent = Lighting
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

-- The arena *is* the floor now; the template plate would z-fight with the tiles.
local function removeBaseplate()
	if not SETTINGS.RemoveBaseplate then
		return
	end
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
		print("[EnvironmentSetup] Removed the template Baseplate; the arena is the floor.")
	end
end

-- A stray spawn point outside the arena would drop players into the void.
local function clearForeignSpawns()
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") and descendant.Name ~= "ArenaSpawn" then
			descendant:Destroy()
		end
	end
end

--[[
	Guards the floor plane.
	The template Baseplate spans y -20..0, so its top face is coplanar with the tile
	tops: if it ever comes back (a live sync can re-add anything the project file
	declares), the whole arena z-fights. Destroying it on sight keeps the arena flat.
]]
local function watchForBaseplate()
	local function sweep(instance: Instance)
		if instance:IsA("BasePart") and instance.Name == "Baseplate" then
			instance:Destroy()
		end
	end

	sweep(workspace)
	workspace.ChildAdded:Connect(sweep)
end

local previous = workspace:FindFirstChild(SETTINGS.ArenaName)
if previous then
	previous:Destroy()
end

removeBaseplate()
clearForeignSpawns()
watchForBaseplate()
configureLighting()

local arena = Instance.new("Model")
arena.Name = SETTINGS.ArenaName
arena.Parent = workspace

buildFloor(arena)
buildPerimeter(arena)
buildDais(arena)

print(
	`[EnvironmentSetup] Arena online: radius {ARENA.Radius}, boundary {ARENA.BoundaryRadius}, dusk lighting armed.`
)
