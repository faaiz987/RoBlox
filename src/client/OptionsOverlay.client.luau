--!strict
--[[
	OptionsOverlay (LocalScript)
	----------------------------
	The options panel, mid-run.

	The title screen has always been able to rebind the combat actions (see
	OptionsMenu), but its ScreenGui is disabled the moment PLAY is pressed -- so
	parry and dodge could only be changed by going back to the main menu, and the
	only "options" a player could reach inside a run was Roblox's own core menu,
	which has no keybind editing in it. This script is the missing door: it builds
	the same modal from the same module, in its own ScreenGui, and opens it on the
	`Options` action (default `O`, rebindable in the panel itself) or on the touch
	button ContextActionService creates for phones.

	The cursor contract is CombatController's, shared with the title screen: a
	ScreenGui flagged `CB_Menu = true` hands the mouse back and suppresses combat
	input while it is up. The flag flips with the modal, so a sword cannot be
	swung through a rebind -- and it flips back by itself, so the mouse is
	recaptured the moment the panel closes.

	Nothing here is authoritative: this is preference UI on the player's own
	machine, and the bind store it edits lives in KeybindManager.
]]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local KeybindManager = require(Shared:WaitForChild("KeybindManager"))

-- Siblings, and `assert` because `script.Parent` is typed optional: this script
-- cannot do its job without either module.
local clientFolder = script.Parent
assert(clientFolder, "OptionsOverlay must live inside a folder")
local UiTheme = require(clientFolder:WaitForChild("UiTheme"))
local OptionsMenu = require(clientFolder:WaitForChild("OptionsMenu"))

local ATTR = CombatConfig.Attributes
local LOCK = CombatConfig.Camera.Lock

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ContextActionService name for the panel's own open/close action.
local HOTKEY = "CB_Options"

local function playSound(soundId: string, volume: number, pitch: number)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch
	SoundService:PlayLocalSound(sound)
	Debris:AddItem(sound, 4)
end

-- ---------------------------------------------------------------------------
-- Root
-- ---------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "OptionsOverlay"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
-- Above the combat HUD, the perk cards and the title screen: this panel is the
-- one thing a player opened on purpose.
gui.DisplayOrder = 60
gui.Parent = playerGui
-- The attribute exists from the first frame, `false` while the panel is down, so
-- CombatController's scan has one stable place to look.
gui:SetAttribute(LOCK.MenuAttribute, false)

-- ---------------------------------------------------------------------------
-- Cursor
-- ---------------------------------------------------------------------------

--[[
	May the game hold the cursor again? No while something else owns it: a dead
	or absent character, the perk overlay (`CB_ChoiceOpen`), Roblox's own menu, or
	another menu ScreenGui -- the title screen. The same rules CombatController's
	lock loop applies, mirrored here so closing the panel hands the mouse back in
	the same frame instead of a quarter of a second later.
]]
local function canHoldCursor(): boolean
	if player:GetAttribute(ATTR.ChoiceOpen) == true or GuiService.MenuIsOpen then
		return false
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	for _, child in playerGui:GetChildren() do
		if child ~= gui and child:IsA("ScreenGui") and child.Enabled and child:GetAttribute(LOCK.MenuAttribute) == true then
			return false
		end
	end
	return true
end

local function claimCursor()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function releaseCursor()
	if not canHoldCursor() then
		return
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = not LOCK.HideCursor
end

-- ---------------------------------------------------------------------------
-- The panel (the same module the title screen builds)
-- ---------------------------------------------------------------------------

local modal = OptionsMenu.create(gui, UiTheme, playSound, function(open: boolean)
	-- Announced on intent, before the fade: the flag has to be up the moment a
	-- click could land, or the first click of the run would swing the sword.
	gui:SetAttribute(LOCK.MenuAttribute, open)
	if open then
		claimCursor()
	else
		releaseCursor()
	end
end)

-- ---------------------------------------------------------------------------
-- Opening it
-- ---------------------------------------------------------------------------

--[[
	Refuses to open over something that already owns the screen: the title screen
	(any other ScreenGui wearing `CB_Menu`) and the perk overlay. The panel is a
	full-screen scrim, so covering either would hide a decision the player still
	owes the server -- and on the title screen there is an options button already.
]]
local function openBlocked(): boolean
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		return true
	end
	for _, child in playerGui:GetChildren() do
		if child ~= gui and child:IsA("ScreenGui") and child.Enabled and child:GetAttribute(LOCK.MenuAttribute) == true then
			return true
		end
	end
	return false
end

local function onOptionsAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if modal.isOpen() then
		-- While a row waits for a key, that key belongs to the row: closing here
		-- would make this very hotkey impossible to bind to anything else.
		if not modal.isCapturing() then
			modal.close()
		end
		return Enum.ContextActionResult.Pass
	end

	if openBlocked() then
		return Enum.ContextActionResult.Pass
	end

	modal.open()
	return Enum.ContextActionResult.Pass
end

--[[
	Bound through ContextActionService for the same reasons the combat actions
	are: a rebind is one `BindAction` away, the third argument registers the
	on-screen touch button on phones, and nothing has to know the key in advance.
	The `Options` row in the panel is this binding -- rebind it and the panel
	follows.
]]
local hotkeyBound = false

local function bindHotkey()
	ContextActionService:UnbindAction(HOTKEY)
	ContextActionService:BindAction(HOTKEY, onOptionsAction, true, table.unpack(KeybindManager:GetInputs("Options")))
	ContextActionService:SetTitle(HOTKEY, "Options")
	ContextActionService:SetPosition(HOTKEY, UDim2.new(1, -130, 0, 8))
	hotkeyBound = true
end

--[[
	The binding owns the on-screen touch button, so it only exists while the
	panel could actually open: otherwise an inert "Options" chip would float over
	the title screen and the perk cards. Unbinding is also what keeps the key from
	being swallowed while a decision owns the screen.
]]
local function syncHotkey()
	local wanted = not openBlocked()
	if wanted == hotkeyBound then
		return
	end
	if wanted then
		bindHotkey()
	else
		ContextActionService:UnbindAction(HOTKEY)
		hotkeyBound = false
	end
end

syncHotkey()

-- Fires with the changed action, or with nothing after a bulk reset; either way
-- the cheapest correct answer is to rebuild this one binding from scratch.
KeybindManager.OnBindChanged.Event:Connect(function()
	if hotkeyBound then
		ContextActionService:UnbindAction(HOTKEY)
		hotkeyBound = false
	end
	syncHotkey()
end)

-- The states that gate the binding are owned by other scripts (the title screen
-- leaves, a perk offer opens), so the gate is re-checked on a slow timer -- the
-- same repair cadence CombatController uses for the mouse lock.
local gateClock = 0
RunService.Heartbeat:Connect(function(deltaTime: number)
	gateClock += deltaTime
	if gateClock < 0.25 then
		return
	end
	gateClock = 0
	syncHotkey()
end)

--[[
	A wave that ends while the panel is up: the perk cards are a decision the
	player owes the server before the next wave starts, and they cannot be clicked
	through a scrim. The panel is a preference; the cards are not, so the panel
	steps aside.
]]
player:GetAttributeChangedSignal(ATTR.ChoiceOpen):Connect(function()
	if player:GetAttribute(ATTR.ChoiceOpen) == true then
		modal.close()
	end
end)

print(`[OptionsOverlay] Mid-run options online on {KeybindManager:ShortLabel("Options")}.`)
