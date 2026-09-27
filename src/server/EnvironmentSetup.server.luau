--!strict
--[[
	EnvironmentSetup (Script)
	-------------------------
	Builds the stage the waves are fought on, then lights it.

	  * A circular floor of dark cobblestone tiles laid out to
	    `CombatConfig.Arena.Radius`, with every tile top sitting on y = 0 -- so
	    `Arena.RigRootY` still drops enemy feet exactly onto the floor.
	  * A neon perimeter: an amber ring wall (collidable, so nobody walks off the
	    edge), a crimson inner line, and eight lamp posts with point lights.
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

	RingColor = Color3.fromRGB(255, 138, 60),
	InnerLineColor = Color3.fromRGB(255, 58, 62),
	RingThickness = 1.4,
	InnerLineHeight = 0.45,
	RingSegmentsPerStud = 0.22,

	PillarCount = 8,
	PillarHeight = 16,
	PillarWidth = 1.7,
	PillarColor = Color3.fromRGB(255, 178, 96),
	-- Lamps have to actually reach the duelling ground, not just the wall.
	PillarLightRange = 78,
	PillarLightBrightness = 3,
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

local function buildPerimeter(parent: Instance)
	local rings = Instance.new("Model")
	rings.Name = "Perimeter"

	local wall = buildRing("Boundary", ARENA.BoundaryRadius, ARENA.WallHeight, SETTINGS.RingThickness, SETTINGS.RingColor)
	wall.Parent = rings

	local line = buildRing(
		"InnerLine",
		ARENA.BoundaryRadius - 2.5,
		SETTINGS.InnerLineHeight,
		SETTINGS.RingThickness,
		SETTINGS.InnerLineColor
	)
	line.Parent = rings

	-- Lamp posts just outside the wall: the only warm light in the arena.
	local pillarRadius = ARENA.BoundaryRadius + 2.6
	for index = 1, SETTINGS.PillarCount do
		local angle = (index / SETTINGS.PillarCount) * math.pi * 2
		local pillar = newPart(
			`Pillar_{index}`,
			Vector3.new(SETTINGS.PillarWidth, SETTINGS.PillarHeight, SETTINGS.PillarWidth),
			SETTINGS.PillarColor,
			Enum.Material.Neon
		)
		pillar.CastShadow = false
		pillar.Position = Vector3.new(
			math.cos(angle) * pillarRadius,
			SETTINGS.PillarHeight * 0.5 - SETTINGS.Sink,
			math.sin(angle) * pillarRadius
		)
		pillar.Parent = rings

		local light = Instance.new("PointLight")
		light.Name = "LampGlow"
		light.Color = SETTINGS.PillarColor
		light.Brightness = SETTINGS.PillarLightBrightness
		light.Range = SETTINGS.PillarLightRange
		light.Shadows = false
		light.Parent = pillar
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
	local lamp = newPart("DaisLamp", Vector3.new(0.7, 0.5, 0.7), SETTINGS.PillarColor, Enum.Material.Neon)
	lamp.CastShadow = false
	lamp.Position = Vector3.new(0, 0.75, 8.8)
	lamp.Parent = dais

	local daisLight = Instance.new("PointLight")
	daisLight.Name = "DaisGlow"
	daisLight.Color = SETTINGS.PillarColor
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
