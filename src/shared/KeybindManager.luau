--!strict
--[[
	KeybindManager
	--------------
	One authority for the three combat inputs, so the options menu is the only
	place a control is ever decided.

		Attack -> Left Mouse      Parry -> F      Dodge -> Left Shift

	A ModuleScript, not a service: keybinds are per-machine player preference, so
	the store lives in the client's own require cache and a rebind never needs a
	server round trip.

		KeybindManager:GetBind("Parry")                   -> Enum.KeyCode.F
		KeybindManager:SetBind("Parry", Enum.KeyCode.G)   -> ok, err?
		KeybindManager.OnBindChanged                      -> BindableEvent

	Controllers should bind `GetInputs(action)`, not `GetBind(action)`: that is the
	player's bind plus the static extras (Q keeps dodging, the gamepad keeps its
	shoulder buttons). An extra yields automatically the moment another action is
	explicitly bound to the same input, so two actions can never fire from one press.

	`OnBindChanged` fires with the action name that changed, or with no argument
	after a bulk reset -- listeners that simply re-read every bind can ignore it.
]]

local KeybindManager = {}

export type ActionName = "Attack" | "Parry" | "Dodge"

-- One input a player action can answer to.
export type Input = Enum.UserInputType | Enum.KeyCode

local ACTIONS: { ActionName } = { "Attack", "Parry", "Dodge" }

KeybindManager.Actions = ACTIONS

-- Labels for the options rows / HUD. Kept here so a fourth action needs one line
-- in this file and zero UI edits.
KeybindManager.DisplayNames = {
	Attack = "Light Attack",
	Parry = "Parry / Block",
	Dodge = "Dodge Dash",
} :: { [string]: string }

KeybindManager.Descriptions = {
	Attack = "Three-hit stance combo",
	Parry = "0.2s window, hold to guard",
	Dodge = "Dash with i-frames",
} :: { [string]: string }

local DEFAULTS: { [string]: Input } = {
	Attack = Enum.UserInputType.MouseButton1,
	Parry = Enum.KeyCode.F,
	Dodge = Enum.KeyCode.LeftShift,
}

--[[
	Static secondary inputs. These ride along with the primary bind and are not
	rebindable, so a player who never opens the options menu keeps every control
	the game shipped with (Q dodged before this menu existed; it still does).
]]
local EXTRAS: { [string]: { Input } } = {
	Attack = { Enum.KeyCode.ButtonR2 },
	Parry = { Enum.KeyCode.ButtonL2 },
	Dodge = { Enum.KeyCode.Q, Enum.KeyCode.ButtonL1 },
}

-- The live store. Written only through SetBind / RestoreDefaults.
local binds: { [string]: Input } = {}
for action, input in DEFAULTS do
	binds[action] = input
end

-- Kept out of the DataModel: an unparented BindableEvent still fires, and it never
-- replicates. The module holds the only reference, and a required module is cached
-- for the life of the client, so it cannot be collected.
local onBindChanged = Instance.new("BindableEvent")
onBindChanged.Name = "KeybindManagerBindChanged"

-- ---------------------------------------------------------------------------
-- Presentation helpers (pure: no state, safe to call from any thread)
-- ---------------------------------------------------------------------------

-- Human-readable glyphs. Keyed by enum item *name* so KeyCode and UserInputType
-- can share one table -- "MouseButton1" only ever exists as a UserInputType.
local GLYPHS: { [string]: string } = {
	LeftShift = "Shift",
	RightShift = "Shift",
	LeftControl = "Ctrl",
	RightControl = "Ctrl",
	LeftAlt = "Alt",
	RightAlt = "Alt",
	Backquote = "`",
	Return = "Enter",
	Escape = "Esc",
	Tab = "Tab",
	Space = "Space",
	MouseButton1 = "LMB",
	MouseButton2 = "RMB",
	MouseButton3 = "MMB",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonR1 = "RB",
	ButtonR2 = "RT",
	ButtonL1 = "LB",
	ButtonL2 = "LT",
	DPadUp = "D-Up",
	DPadDown = "D-Down",
	DPadLeft = "D-Left",
	DPadRight = "D-Right",
}

-- Number keys read as digits rather than "One", "Two", ...
for index, word in { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Zero" } do
	GLYPHS[word] = tostring(index % 10)
end

local function isMouseButton(inputType: Enum.UserInputType): boolean
	return inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
end

local function isGamepad(input: Input): boolean
	local name = input.Name
	return string.match(name, "^Button") ~= nil
		or string.match(name, "^DPad") ~= nil
		or string.match(name, "^Thumbstick") ~= nil
		or string.match(name, "^Gamepad") ~= nil
end

local function keyName(input: Input): string
	return GLYPHS[input.Name] or input.Name
end

-- The primary bind first, then whatever extras still make sense for it.
local function getInputs(action: ActionName): { Input }
	local inputs: { Input } = {}
	local seen: { [Input]: boolean } = {}

	local function push(input: Input, isPrimary: boolean)
		if seen[input] then
			return
		end
		if not isPrimary then
			-- An extra yields to another action's explicit choice.
			for _, other in ACTIONS do
				if other ~= action and binds[other] == input then
					return
				end
			end
		end
		seen[input] = true
		table.insert(inputs, input)
	end

	-- `Enum.KeyCode.None` is the engine's zero KeyCode: what a mouse, a touch or any
	-- non-keyboard input reports. Its legacy alias `Unknown` still resolves at
	-- runtime, but only `None` is the canonical name.
	push(binds[action] or DEFAULTS[action] or Enum.KeyCode.None, true)
	local extras = EXTRAS[action]
	if extras then
		for _, extra in extras do
			push(extra, false)
		end
	end
	return inputs
end

-- Compact label for a badge or chip: keyboard/mouse inputs only, primary first.
local function shortLabel(action: ActionName): string
	local parts: { string } = {}
	for _, input in getInputs(action) do
		if not isGamepad(input) then
			table.insert(parts, keyName(input))
		end
	end
	if #parts == 0 then
		return "--"
	end
	return table.concat(parts, "/")
end

local function primary(action: ActionName): Input
	return binds[action] or DEFAULTS[action] or Enum.KeyCode.None
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function KeybindManager:GetBind(action: ActionName): Input
	return primary(action)
end

function KeybindManager:GetInputs(action: ActionName): { Input }
	return getInputs(action)
end

-- Display glyph for one raw input ("LMB", "Shift", "Space").
function KeybindManager:KeyName(input: Input): string
	return keyName(input)
end

-- Display glyph for an action's current bind ("F").
function KeybindManager:Label(action: ActionName): string
	return keyName(primary(action))
end

-- Every non-gamepad input an action answers to ("Shift/Q").
function KeybindManager:ShortLabel(action: ActionName): string
	return shortLabel(action)
end

--[[
	Rebinds one action. Returns `ok, err`:
	  * false + a message when the input is unusable or already taken -- the caller
	    is expected to surface the message instead of failing silently.
	  * true when the bind changed, and also when the player picked the very input
	    the action already had (nothing to broadcast, nothing to undo).
]]
function KeybindManager:SetBind(action: ActionName, newInput: Input): (boolean, string?)
	if not DEFAULTS[action] then
		return false, `Unknown action "{action}".`
	end

	-- Guard the store against anything a UI might hand over from an untyped path.
	if typeof(newInput) ~= "EnumItem" then
		return false, "Only mouse, keyboard and gamepad inputs can be bound."
	end
	local item: any = newInput
	if item.EnumType == Enum.UserInputType then
		if not isMouseButton(item) then
			return false, "Only the left, right and middle mouse buttons can be bound."
		end
	elseif item.EnumType ~= Enum.KeyCode then
		return false, "Only mouse, keyboard and gamepad inputs can be bound."
	end
	if item == Enum.KeyCode.None then
		return false, "That input cannot be bound."
	end
	if item == Enum.KeyCode.Escape then
		-- Escape is the menu's own cancel key; binding it would trap the player.
		return false, "Escape closes this menu. Pick another key."
	end

	for _, other in ACTIONS do
		if other ~= action and binds[other] == newInput then
			local label = KeybindManager.DisplayNames[other] or other
			return false, `Already bound to {label}.`
		end
	end

	if binds[action] == newInput then
		return true, nil
	end

	binds[action] = newInput
	onBindChanged:Fire(action)
	return true, nil
end

function KeybindManager:RestoreDefaults(): boolean
	local changed = false
	for _, action in ACTIONS do
		local fallback = DEFAULTS[action]
		if binds[action] ~= fallback then
			binds[action] = fallback
			changed = true
		end
	end
	if changed then
		onBindChanged:Fire()
	end
	return changed
end

-- Fired with the changed action name, or with no argument after a bulk reset.
KeybindManager.OnBindChanged = onBindChanged

return KeybindManager
