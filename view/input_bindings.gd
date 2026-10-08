class_name InputBindings
extends RefCounted
## View-side input actions, registered in code so the project file stays
## readable and the player can rebind them (Settings > Controls and >
## Controller). Keys are bound by physical keycode, so they follow key
## position rather than the keyboard layout.
##
## Two slots per action (Phase 11): one keyboard-or-mouse event (Device.KBM)
## and one pad event (Device.PAD). Rebinding replaces the event in its own
## slot only (_bind), so a pad binding never knocks out a key. Most actions
## have only a KBM slot; the pad-only ones (PAD_*) only a PAD slot; Back
## (CANCEL) and the special (ABILITY) have both. Pad events are bound to every
## pad (device -1), so a controller that reconnects as another device still
## works.
##
## Presets (Phase 11): Modern (the default) and Classic, closer to Myth II.
## A preset is a set of KBM defaults plus a click scheme, not a rebinding of
## Select or Move: Classic gives orders with the left button, so the
## SelectionController routes a left click by what is under it
## (orders_on_left), and saves groups by holding the one group key
## (hold_to_save_groups). Both buttons keep their own actions, so a conflict
## check never sees Select and Move on one button. `preset` is set by
## GameSettings.apply_bindings.
##
## Rebinding (Phase 10): every rebindable action has one binding per slot,
## which apply() replaces; the group keys stay on the number row and only
## their modifiers change (set_group_modifiers, set_classic_group_modifier).
## reset() puts everything back. Bindings are saved as text (event_to_text),
## and labels for the HUD come from label_for(), so a rebound key is named
## correctly everywhere. Debug keys (F5, F6, F8, F9) aren't rebindable, nor
## is the pad's Menu button (OPEN_MENU): it always pauses.
##
## Held keys are polled in _process. Mouse-wheel zoom has its own step actions
## because a wheel notch is an instant press and release: poll it and it is
## never seen, so handle it as a discrete event in _unhandled_input.
##
## Number keys carry three action sets that differ only by modifier: bare for
## formations, a modifier to save a group, another to recall one. Godot
## matches a key action even when extra modifiers are held, so these must be
## checked with exact_match = true.
##
## Mouse actions with modifiers (Cmd/Ctrl + right click attack-moves, Cmd/Ctrl
## + left click bombards the ground, Option + left click gives the order a
## one-button mouse can't) match a press that has at least their modifiers,
## so they are checked before the bare button's action. Shift on an order
## makes it a route point (waypoints), in either preset.
##
## install() also puts the pad's A on ui_accept and B on ui_cancel, which
## Godot doesn't: every menu is then driven by the pad's focus navigation.

## Which slot of an action an event belongs in.
enum Device {
	KBM,
	PAD,
}

## The control presets (Settings > Controls).
enum Preset {
	MODERN,
	CLASSIC,
}

const CAM_FORWARD: StringName = &"cam_forward"
const CAM_BACK: StringName = &"cam_back"
const CAM_LEFT: StringName = &"cam_left"
const CAM_RIGHT: StringName = &"cam_right"
const CAM_ORBIT_LEFT: StringName = &"cam_orbit_left"
const CAM_ORBIT_RIGHT: StringName = &"cam_orbit_right"
const CAM_SWIVEL_LEFT: StringName = &"cam_swivel_left"
const CAM_SWIVEL_RIGHT: StringName = &"cam_swivel_right"
## Held: zoom continuously.
const CAM_ZOOM_IN: StringName = &"cam_zoom_in"
const CAM_ZOOM_OUT: StringName = &"cam_zoom_out"
## Mouse wheel notches: zoom one discrete step per event.
const CAM_ZOOM_IN_STEP: StringName = &"cam_zoom_in_step"
const CAM_ZOOM_OUT_STEP: StringName = &"cam_zoom_out_step"
const TOGGLE_OVERHEAD_MAP: StringName = &"toggle_overhead_map"
## Left click / drag: select. Right click: move the selection. Cmd/Ctrl +
## right click: attack-move it. Cmd/Ctrl + left click: ground attack.
const SELECT: StringName = &"unit_select"
const COMMAND: StringName = &"unit_command"
const ATTACK_MOVE: StringName = &"unit_attack_move"
const GROUND_ATTACK: StringName = &"unit_ground_attack"
## Option + left click: the order button for a one-button mouse or trackpad
## (Myth II's Option-click). Clicked, it orders; dragged, it sets the facing.
const COMMAND_ALT: StringName = &"unit_command_alt"
## T: the selection's special ability (a Sapper drops a charge, a Longbow
## nocks its fire arrow).
const ABILITY: StringName = &"unit_ability"
## Space (Myth-style): halt the selection.
const STOP: StringName = &"unit_stop"
## G, B, R: guard, scatter, retreat (Phase 11).
const GUARD: StringName = &"unit_guard"
const SCATTER: StringName = &"unit_scatter"
const RETREAT: StringName = &"unit_retreat"
## Left / Right arrow: turn the pending formation, or a moving one.
const ROTATE_LEFT: StringName = &"formation_rotate_left"
const ROTATE_RIGHT: StringName = &"formation_rotate_right"
## Enter: select every unit of yours on screen. `: select nothing.
const SELECT_ALL: StringName = &"select_all_visible"
const DESELECT: StringName = &"deselect_all"
## F: the next saved group. Delete: forget the group the selection came from.
const CYCLE_GROUPS: StringName = &"group_cycle"
const CLEAR_GROUP: StringName = &"group_clear"
## F10, held: every unit's health bar.
const HEALTH_BARS: StringName = &"show_health_bars"
## F1 / F2: game speed, single player only.
const SPEED_DOWN: StringName = &"game_speed_down"
const SPEED_UP: StringName = &"game_speed_up"
## H: glide the camera to the middle of the selection.
const CAM_CENTER: StringName = &"cam_center_selection"
## Esc: cancel an order armed from the control bar; with none armed, open or
## close the pause menu (PauseMenu). The pad's B is its other slot: it backs
## out of menus and cancels, but never opens the pause menu (OPEN_MENU does).
const CANCEL: StringName = &"cancel"
## P: pause or resume without the menu (MainView). The sim stops stepping; the
## camera, selection, and HUD keep working.
const PAUSE: StringName = &"pause_game"
## The pad's Menu button: open or close the pause menu.
const OPEN_MENU: StringName = &"open_menu"
## Debug: switch which side the mouse commands. The AI keeps driving its
## groups whichever side that is.
const SWITCH_SIDE: StringName = &"debug_switch_side"
## Debug: cycle clear, rain, heavy rain, snow (DebugWeather), until the
## mission's next weather change.
const CYCLE_WEATHER: StringName = &"debug_cycle_weather"
## Debug: paralyze, confuse, or set alight the selection, in turn.
const CYCLE_STATUS: StringName = &"debug_cycle_status"
## Debug: F5 shows or hides the enemy AI overlay (AiDebugView).
const TOGGLE_AI_DEBUG: StringName = &"debug_toggle_ai"
## F7: shows or hides a skirmish's scoreboard (SkirmishHud).
const TOGGLE_SCOREBOARD: StringName = &"toggle_scoreboard"

## The pad (PadController): the left stick moves the cursor; the right stick
## pans the camera, the triggers orbit it; A selects, X orders; LB and RB open
## the formation and order wheels; the D-pad steps through the groups (up
## held saves, down held clears); View opens the overhead map (held: health
## bars); L3 puts focus on the control bar; R3 centers on the selection (held,
## the right stick zooms).
const PAD_CURSOR_LEFT: StringName = &"pad_cursor_left"
const PAD_CURSOR_RIGHT: StringName = &"pad_cursor_right"
const PAD_CURSOR_UP: StringName = &"pad_cursor_up"
const PAD_CURSOR_DOWN: StringName = &"pad_cursor_down"
const PAD_PAN_LEFT: StringName = &"pad_pan_left"
const PAD_PAN_RIGHT: StringName = &"pad_pan_right"
const PAD_PAN_FORWARD: StringName = &"pad_pan_forward"
const PAD_PAN_BACK: StringName = &"pad_pan_back"
const PAD_ORBIT_LEFT: StringName = &"pad_orbit_left"
const PAD_ORBIT_RIGHT: StringName = &"pad_orbit_right"
const PAD_SELECT: StringName = &"pad_select"
const PAD_ORDER: StringName = &"pad_order"
const PAD_FORMATION_WHEEL: StringName = &"pad_formation_wheel"
const PAD_ORDER_WHEEL: StringName = &"pad_order_wheel"
const PAD_GROUP_PREV: StringName = &"pad_group_prev"
const PAD_GROUP_NEXT: StringName = &"pad_group_next"
const PAD_GROUP_SAVE: StringName = &"pad_group_save"
const PAD_GROUP_CLEAR: StringName = &"pad_group_clear"
const PAD_VIEW: StringName = &"pad_view"
const PAD_BAR_FOCUS: StringName = &"pad_bar_focus"
const PAD_CENTER: StringName = &"pad_center"

## Index i is formation Formations.Kind i and group slot i; keys 1..9, 0.
const FORMATIONS: Array[StringName] = [
	&"formation_1", &"formation_2", &"formation_3", &"formation_4", &"formation_5",
	&"formation_6", &"formation_7", &"formation_8", &"formation_9", &"formation_10",
]
const GROUP_SAVES: Array[StringName] = [
	&"group_save_1", &"group_save_2", &"group_save_3", &"group_save_4", &"group_save_5",
	&"group_save_6", &"group_save_7", &"group_save_8", &"group_save_9", &"group_save_10",
]
const GROUP_RECALLS: Array[StringName] = [
	&"group_recall_1", &"group_recall_2", &"group_recall_3", &"group_recall_4", &"group_recall_5",
	&"group_recall_6", &"group_recall_7", &"group_recall_8", &"group_recall_9", &"group_recall_10",
]
const NUMBER_KEYS: Array[Key] = [
	KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0,
]

## The modifier that turns a number key into a group save or recall.
enum GroupModifier {
	## Cmd on macOS, Ctrl elsewhere.
	COMMAND_OR_CONTROL,
	## Option on macOS, Alt elsewhere.
	ALT,
	SHIFT,
	## Cmd on macOS, Alt elsewhere: Myth II's one group key (Classic).
	COMMAND_OR_ALT,
}
const DEFAULT_SAVE_MODIFIER: GroupModifier = GroupModifier.COMMAND_OR_CONTROL
const DEFAULT_RECALL_MODIFIER: GroupModifier = GroupModifier.ALT
## The modifiers Modern's two group keys may use (Classic's own isn't one:
## on one platform it is Cmd, on another Alt, so "different" can't be told).
const MODERN_GROUP_MODIFIERS: Array[GroupModifier] = [
	GroupModifier.COMMAND_OR_CONTROL, GroupModifier.ALT, GroupModifier.SHIFT,
]

## The actions the player may rebind on the keyboard and mouse, in the order
## Settings > Controls lists them, by section. The group keys are the number
## row plus a modifier, changed with set_group_modifiers.
const REBINDABLE: Dictionary[String, Array] = {
	"Camera": [
		CAM_FORWARD, CAM_BACK, CAM_LEFT, CAM_RIGHT, CAM_ORBIT_LEFT, CAM_ORBIT_RIGHT,
		CAM_SWIVEL_LEFT, CAM_SWIVEL_RIGHT, CAM_ZOOM_IN, CAM_ZOOM_OUT, CAM_CENTER, TOGGLE_OVERHEAD_MAP,
	],
	"Orders": [
		SELECT, COMMAND, ATTACK_MOVE, GROUND_ATTACK, COMMAND_ALT, ABILITY, STOP, GUARD, SCATTER, RETREAT,
		ROTATE_LEFT, ROTATE_RIGHT,
	],
	"Selection": [
		SELECT_ALL, DESELECT, CYCLE_GROUPS, CLEAR_GROUP,
	],
	"Game": [
		PAUSE, SPEED_DOWN, SPEED_UP, HEALTH_BARS, TOGGLE_SCOREBOARD,
	],
	"Formations": [
		&"formation_1", &"formation_2", &"formation_3", &"formation_4", &"formation_5",
		&"formation_6", &"formation_7", &"formation_8", &"formation_9", &"formation_10",
	],
}
## The actions the player may rebind on the pad (Settings > Controller).
const PAD_REBINDABLE: Dictionary[String, Array] = {
	"Cursor and camera": [
		PAD_CURSOR_LEFT, PAD_CURSOR_RIGHT, PAD_CURSOR_UP, PAD_CURSOR_DOWN,
		PAD_PAN_LEFT, PAD_PAN_RIGHT, PAD_PAN_FORWARD, PAD_PAN_BACK, PAD_ORBIT_LEFT, PAD_ORBIT_RIGHT,
		PAD_CENTER,
	],
	"Orders": [
		PAD_SELECT, PAD_ORDER, CANCEL, ABILITY, PAD_FORMATION_WHEEL, PAD_ORDER_WHEEL,
	],
	"Groups and views": [
		PAD_GROUP_PREV, PAD_GROUP_NEXT, PAD_GROUP_SAVE, PAD_GROUP_CLEAR, PAD_VIEW, PAD_BAR_FOCUS,
	],
}
## Keys whose names Godot gives as words the player wouldn't use.
const KEY_NAMES: Dictionary[int, String] = {
	KEY_QUOTELEFT: "`", KEY_LEFT: "Left arrow", KEY_RIGHT: "Right arrow",
	KEY_UP: "Up arrow", KEY_DOWN: "Down arrow",
}
## Mouse buttons as the player reads them.
const MOUSE_NAMES: Dictionary[int, String] = {
	MOUSE_BUTTON_LEFT: "Left click", MOUSE_BUTTON_RIGHT: "Right click",
	MOUSE_BUTTON_MIDDLE: "Middle click", MOUSE_BUTTON_WHEEL_UP: "Wheel up",
	MOUSE_BUTTON_WHEEL_DOWN: "Wheel down", MOUSE_BUTTON_XBUTTON1: "Mouse 4",
	MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}
## Pad buttons as the player reads them (an Xbox layout; SDL and the browser
## map other pads onto it).
const PAD_BUTTON_NAMES: Dictionary[int, String] = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "View", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Menu",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down",
	JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
}
## Pad axes as the player reads them, by axis then direction (minus, plus).
const PAD_AXIS_NAMES: Dictionary[int, Array] = {
	JOY_AXIS_LEFT_X: ["LS left", "LS right"], JOY_AXIS_LEFT_Y: ["LS up", "LS down"],
	JOY_AXIS_RIGHT_X: ["RS left", "RS right"], JOY_AXIS_RIGHT_Y: ["RS up", "RS down"],
	JOY_AXIS_TRIGGER_LEFT: ["LT", "LT"], JOY_AXIS_TRIGGER_RIGHT: ["RT", "RT"],
}
## What Settings calls each rebindable action.
const ACTION_NAMES: Dictionary[StringName, String] = {
	CAM_FORWARD: "Camera forward", CAM_BACK: "Camera back",
	CAM_LEFT: "Camera left", CAM_RIGHT: "Camera right",
	CAM_ORBIT_LEFT: "Orbit left", CAM_ORBIT_RIGHT: "Orbit right",
	CAM_SWIVEL_LEFT: "Turn left", CAM_SWIVEL_RIGHT: "Turn right",
	CAM_ZOOM_IN: "Zoom in", CAM_ZOOM_OUT: "Zoom out",
	CAM_CENTER: "Center on selection", TOGGLE_OVERHEAD_MAP: "Overhead map",
	SELECT: "Select", COMMAND: "Move", ATTACK_MOVE: "Attack-move", GROUND_ATTACK: "Ground attack",
	COMMAND_ALT: "Move (one-button mouse)",
	ABILITY: "Special ability", STOP: "Stop", GUARD: "Guard", SCATTER: "Scatter", RETREAT: "Retreat",
	ROTATE_LEFT: "Turn formation left", ROTATE_RIGHT: "Turn formation right",
	SELECT_ALL: "Select all on screen", DESELECT: "Deselect", CYCLE_GROUPS: "Next group",
	CLEAR_GROUP: "Clear group",
	PAUSE: "Pause", SPEED_DOWN: "Slower", SPEED_UP: "Faster", HEALTH_BARS: "Health bars (hold)",
	TOGGLE_SCOREBOARD: "Scoreboard",
	&"formation_1": "Short line", &"formation_2": "Long line", &"formation_3": "Loose line",
	&"formation_4": "Staggered line", &"formation_5": "Box", &"formation_6": "Rabble",
	&"formation_7": "Shallow encirclement", &"formation_8": "Deep encirclement",
	&"formation_9": "Wedge", &"formation_10": "Circle",
	PAD_CURSOR_LEFT: "Cursor left", PAD_CURSOR_RIGHT: "Cursor right",
	PAD_CURSOR_UP: "Cursor up", PAD_CURSOR_DOWN: "Cursor down",
	PAD_PAN_LEFT: "Pan left", PAD_PAN_RIGHT: "Pan right",
	PAD_PAN_FORWARD: "Pan forward", PAD_PAN_BACK: "Pan back",
	PAD_ORBIT_LEFT: "Orbit left", PAD_ORBIT_RIGHT: "Orbit right",
	PAD_CENTER: "Center (hold: zoom with the pan stick)",
	PAD_SELECT: "Select", PAD_ORDER: "Order", CANCEL: "Back / cancel",
	PAD_FORMATION_WHEEL: "Formation wheel", PAD_ORDER_WHEEL: "Order wheel",
	PAD_GROUP_PREV: "Previous group", PAD_GROUP_NEXT: "Next group",
	PAD_GROUP_SAVE: "Save group (hold)", PAD_GROUP_CLEAR: "Clear group (hold)",
	PAD_VIEW: "Overhead map (hold: health bars)", PAD_BAR_FOCUS: "Control bar",
}

## The pad's analog actions trigger at this much deflection; the cursor and
## the camera scale with how far past it the stick is.
const STICK_DEADZONE: float = 0.2
const TRIGGER_DEADZONE: float = 0.1

## The preset in force: GameSettings.apply_bindings sets it from the file.
static var preset: Preset = Preset.MODERN


## Registers every action that is not already in the InputMap, with both its
## slots' defaults. Safe to call from several nodes: an existing action,
## including one rebound by the user, is left alone. Puts the pad's A and B
## on ui_accept and ui_cancel too.
static func install() -> void:
	var kbm: Dictionary[StringName, InputEvent] = defaults()
	var pad: Dictionary[StringName, InputEvent] = pad_defaults()
	var actions: Array[StringName] = []
	actions.assign(kbm.keys())
	for action: StringName in pad:
		if not actions.has(action):
			actions.append(action)
	for action: StringName in GROUP_SAVES:
		if not actions.has(action):
			actions.append(action)
	for action: StringName in actions:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, _deadzone_of(pad.get(action)))
		if kbm.has(action):
			InputMap.action_add_event(action, kbm[action])
		if pad.has(action):
			InputMap.action_add_event(action, pad[action])
	_ensure_event(&"ui_accept", _pad_button(JOY_BUTTON_A))
	_ensure_event(&"ui_cancel", _pad_button(JOY_BUTTON_B))


## Every action back on its default binding in the given preset (the one in
## force if none is given), both slots and the group keys.
static func reset(to: int = -1) -> void:
	if to >= 0:
		preset = to as Preset
	reset_keys()
	reset_pad()


## The keyboard and mouse slots back on the preset's defaults, the group
## keys included. The pad slots are left alone.
static func reset_keys() -> void:
	var events: Dictionary[StringName, InputEvent] = defaults()
	for action: StringName in events:
		_bind(action, events[action])
	if preset == Preset.CLASSIC:
		set_classic_group_modifier(default_classic_modifier())


## The pad slots back on their defaults. The keys are left alone.
static func reset_pad() -> void:
	var events: Dictionary[StringName, InputEvent] = pad_defaults()
	for action: StringName in events:
		_bind(action, events[action])


## Rebinds each action in `overrides` to its event, in the event's own slot.
## An action that isn't rebindable in that slot is ignored, so a stale
## settings file can't rebind a debug key or put a pad button on a key-only
## action.
static func apply(overrides: Dictionary[StringName, InputEvent]) -> void:
	for action: StringName in overrides:
		var event: InputEvent = overrides[action]
		if event != null and is_rebindable(action, device_of(event)):
			_bind(action, event)


## Puts Modern's group saves and recalls on these modifiers plus the number
## keys. The two must differ, and both be one of MODERN_GROUP_MODIFIERS;
## anything else is refused (false).
static func set_group_modifiers(save: GroupModifier, recall: GroupModifier) -> bool:
	if save == recall or not MODERN_GROUP_MODIFIERS.has(save) or not MODERN_GROUP_MODIFIERS.has(recall):
		return false
	for i: int in NUMBER_KEYS.size():
		_bind(GROUP_SAVES[i], _with_modifier(_key(NUMBER_KEYS[i]), save))
		_bind(GROUP_RECALLS[i], _with_modifier(_key(NUMBER_KEYS[i]), recall))
	return true


## Puts Classic's one group key on this modifier plus the number keys: a tap
## recalls, a hold saves (SelectionController). The save actions are left
## with no key, so nothing else can fire them.
static func set_classic_group_modifier(modifier: GroupModifier) -> void:
	for i: int in NUMBER_KEYS.size():
		_unbind(GROUP_SAVES[i], Device.KBM)
		_bind(GROUP_RECALLS[i], _with_modifier(_key(NUMBER_KEYS[i]), modifier))


## Classic's group key: Cmd on a Mac and Alt elsewhere, as in Myth II, except
## in a browser on a Mac, which keeps Cmd+number to switch tabs: Option there.
static func default_classic_modifier() -> GroupModifier:
	return GroupModifier.ALT if OS.has_feature("web_macos") else GroupModifier.COMMAND_OR_ALT


## True in the Classic preset: the left button gives orders (on the ground or
## an enemy) as well as selecting (your own units).
static func orders_on_left() -> bool:
	return preset == Preset.CLASSIC


## True in the Classic preset: a group is saved by holding its key, not with
## a key of its own.
static func hold_to_save_groups() -> bool:
	return preset == Preset.CLASSIC


## True if the player may bind `action` in that slot.
static func is_rebindable(action: StringName, device: Device = Device.KBM) -> bool:
	var sections: Dictionary[String, Array] = REBINDABLE if device == Device.KBM else PAD_REBINDABLE
	for section: String in sections:
		if sections[section].has(action):
			return true
	return false


## The slot an event belongs in.
static func device_of(event: InputEvent) -> Device:
	return Device.PAD if event is InputEventJoypadButton or event is InputEventJoypadMotion else Device.KBM


## The event an action is bound to now in that slot, or null.
static func event_of(action: StringName, device: Device = Device.KBM) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	for event: InputEvent in InputMap.action_get_events(action):
		if device_of(event) == device:
			return event
	return null


## The actions other than `action` already bound to `event` in its slot: the
## rebindable ones and the group keys, which a rebinding mustn't shadow.
static func conflicts(action: StringName, event: InputEvent) -> Array[StringName]:
	var device: Device = device_of(event)
	var text: String = event_to_text(event)
	var found: Array[StringName] = []
	var candidates: Array[StringName] = []
	for other: StringName in ACTION_NAMES:
		if is_rebindable(other, device):
			candidates.append(other)
	if device == Device.KBM:
		candidates.append_array(GROUP_SAVES)
		candidates.append_array(GROUP_RECALLS)
	for other: StringName in candidates:
		var bound: InputEvent = event_of(other, device)
		if other != action and bound != null and event_to_text(bound) == text:
			found.append(other)
	return found


## An event as saved text: "key:<name>", "mouse:<button>", "joy_button:<n>" or
## "joy_axis:<axis>:plus|minus", then "+cmdorctrl", "+ctrl", "+meta", "+alt",
## "+shift" for each modifier it needs. "" for an event it can't describe.
static func event_to_text(event: InputEvent) -> String:
	var text: String = ""
	if event is InputEventKey:
		var key: InputEventKey = event
		text = "key:" + OS.get_keycode_string(key.physical_keycode)
	elif event is InputEventMouseButton:
		text = "mouse:%d" % (event as InputEventMouseButton).button_index
	elif event is InputEventJoypadButton:
		return "joy_button:%d" % (event as InputEventJoypadButton).button_index
	elif event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		return "joy_axis:%d:%s" % [motion.axis, "plus" if motion.axis_value >= 0.0 else "minus"]
	else:
		return ""
	var with: InputEventWithModifiers = event
	if with.command_or_control_autoremap:
		text += "+cmdorctrl"
	else:
		if with.ctrl_pressed:
			text += "+ctrl"
		if with.meta_pressed:
			text += "+meta"
	if with.alt_pressed:
		text += "+alt"
	if with.shift_pressed:
		text += "+shift"
	return text


## The event event_to_text described, or null for text it doesn't recognize.
## Pad events come back bound to every pad (device -1).
static func text_to_event(text: String) -> InputEvent:
	var parts: PackedStringArray = text.split("+")
	var head: PackedStringArray = parts[0].split(":")
	var event: InputEvent = null
	match head[0]:
		"key":
			if head.size() != 2:
				return null
			var keycode: Key = OS.find_keycode_from_string(head[1])
			if keycode == KEY_NONE:
				return null
			event = _key(keycode)
		"mouse":
			if head.size() != 2 or not head[1].is_valid_int() or head[1].to_int() <= 0:
				return null
			event = _mouse(head[1].to_int() as MouseButton)
		"joy_button":
			if head.size() != 2 or not head[1].is_valid_int() or parts.size() != 1:
				return null
			var index: int = head[1].to_int()
			if index < 0 or index >= JOY_BUTTON_SDL_MAX:
				return null
			return _pad_button(index as JoyButton)
		"joy_axis":
			if head.size() != 3 or not head[1].is_valid_int() or not head[2] in ["plus", "minus"] or parts.size() != 1:
				return null
			var axis: int = head[1].to_int()
			if axis < 0 or axis >= JOY_AXIS_SDL_MAX:
				return null
			return _pad_axis(axis as JoyAxis, 1.0 if head[2] == "plus" else -1.0)
		_:
			return null
	var with: InputEventWithModifiers = event
	for modifier: String in parts.slice(1):
		match modifier:
			"cmdorctrl":
				with.command_or_control_autoremap = true
			"ctrl":
				with.ctrl_pressed = true
			"meta":
				with.meta_pressed = true
			"alt":
				with.alt_pressed = true
			"shift":
				with.shift_pressed = true
			_:
				return null
	return event


## The key or button an action is on in that slot, for the HUD: "T", "Space",
## "Cmd+Right click", "Y". "" for an action with no binding there.
static func label_for(action: StringName, device: Device = Device.KBM) -> String:
	var event: InputEvent = event_of(action, device)
	return event_label(event) if event != null else ""


## An event as the player reads it.
static func event_label(event: InputEvent) -> String:
	var key_name: String = ""
	if event is InputEventKey:
		key_name = key_label((event as InputEventKey).physical_keycode)
	elif event is InputEventMouseButton:
		var button: int = (event as InputEventMouseButton).button_index
		key_name = MOUSE_NAMES.get(button, "Mouse %d" % button)
	elif event is InputEventJoypadButton:
		var pad_button: int = (event as InputEventJoypadButton).button_index
		return PAD_BUTTON_NAMES.get(pad_button, "Pad button %d" % pad_button)
	elif event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		if PAD_AXIS_NAMES.has(motion.axis):
			return PAD_AXIS_NAMES[motion.axis][1 if motion.axis_value >= 0.0 else 0]
		return "Pad axis %d%s" % [motion.axis, "+" if motion.axis_value >= 0.0 else "-"]
	else:
		return ""
	var with: InputEventWithModifiers = event
	var prefix: String = ""
	if with.command_or_control_autoremap:
		prefix += "Cmd+" if _on_mac() else "Ctrl+"
	else:
		if with.ctrl_pressed:
			prefix += "Ctrl+"
		if with.meta_pressed:
			prefix += "Cmd+" if _on_mac() else "Meta+"
	if with.alt_pressed:
		prefix += "Option+" if _on_mac() else "Alt+"
	if with.shift_pressed:
		prefix += "Shift+"
	return prefix + key_name


## A key as the player reads it: a Mac's Backspace is its Delete key.
static func key_label(keycode: Key) -> String:
	if keycode == KEY_BACKSPACE and _on_mac():
		return "Delete"
	return KEY_NAMES.get(keycode, OS.get_keycode_string(keycode))


# Cmd and Option, not Ctrl and Alt: on a Mac, and in a browser on one.
static func _on_mac() -> bool:
	return OS.has_feature("macos") or OS.has_feature("web_macos")


## A group modifier as the player reads it.
static func modifier_label(modifier: GroupModifier) -> String:
	match modifier:
		GroupModifier.COMMAND_OR_CONTROL:
			return "Cmd" if _on_mac() else "Ctrl"
		GroupModifier.ALT:
			return "Option" if _on_mac() else "Alt"
		GroupModifier.COMMAND_OR_ALT:
			return "Cmd" if _on_mac() else "Alt"
	return "Shift"


## Every keyboard and mouse default in the preset in force, the group keys
## included (Classic's saves have none: see set_classic_group_modifier).
static func defaults() -> Dictionary[StringName, InputEvent]:
	var classic: bool = preset == Preset.CLASSIC
	var events: Dictionary[StringName, InputEvent] = {}
	events[CAM_FORWARD] = _key(KEY_W)
	events[CAM_BACK] = _key(KEY_S)
	# Myth II strafes on Z/X and turns on A/D; Modern the other way round.
	events[CAM_LEFT] = _key(KEY_Z if classic else KEY_A)
	events[CAM_RIGHT] = _key(KEY_X if classic else KEY_D)
	events[CAM_ORBIT_LEFT] = _key(KEY_Q)
	events[CAM_ORBIT_RIGHT] = _key(KEY_E)
	events[CAM_SWIVEL_LEFT] = _key(KEY_A if classic else KEY_Z)
	events[CAM_SWIVEL_RIGHT] = _key(KEY_D if classic else KEY_X)
	# Myth II zooms in on C and out on V.
	events[CAM_ZOOM_IN] = _key(KEY_C if classic else KEY_V)
	events[CAM_ZOOM_OUT] = _key(KEY_V if classic else KEY_C)
	events[CAM_ZOOM_IN_STEP] = _mouse(MOUSE_BUTTON_WHEEL_UP)
	events[CAM_ZOOM_OUT_STEP] = _mouse(MOUSE_BUTTON_WHEEL_DOWN)
	events[TOGGLE_OVERHEAD_MAP] = _key(KEY_TAB)
	events[SELECT] = _mouse(MOUSE_BUTTON_LEFT)
	events[COMMAND] = _mouse(MOUSE_BUTTON_RIGHT)
	var attack_move: InputEventMouseButton = _mouse(MOUSE_BUTTON_RIGHT)
	# Cmd on macOS, Ctrl elsewhere.
	attack_move.command_or_control_autoremap = true
	events[ATTACK_MOVE] = attack_move
	var ground_attack: InputEventMouseButton = _mouse(MOUSE_BUTTON_LEFT)
	# Cmd on macOS, Ctrl elsewhere. Cmd is the Mac binding because Godot's
	# macOS layer delivers Ctrl + left click as a right click
	# (platform/macos/godot_content_view.mm, mouseDown).
	ground_attack.command_or_control_autoremap = true
	events[GROUND_ATTACK] = ground_attack
	var command_alt: InputEventMouseButton = _mouse(MOUSE_BUTTON_LEFT)
	command_alt.alt_pressed = true
	events[COMMAND_ALT] = command_alt
	events[ABILITY] = _key(KEY_T)
	events[STOP] = _key(KEY_SPACE)
	events[GUARD] = _key(KEY_G)
	events[SCATTER] = _key(KEY_B)
	events[RETREAT] = _key(KEY_R)
	events[ROTATE_LEFT] = _key(KEY_LEFT)
	events[ROTATE_RIGHT] = _key(KEY_RIGHT)
	events[SELECT_ALL] = _key(KEY_ENTER)
	events[DESELECT] = _key(KEY_QUOTELEFT)
	events[CYCLE_GROUPS] = _key(KEY_F)
	# A Mac keyboard's Delete is Backspace; forward delete needs fn.
	events[CLEAR_GROUP] = _key(KEY_BACKSPACE if _on_mac() else KEY_DELETE)
	events[HEALTH_BARS] = _key(KEY_F10)
	events[SPEED_DOWN] = _key(KEY_F1)
	events[SPEED_UP] = _key(KEY_F2)
	events[CAM_CENTER] = _key(KEY_H)
	events[CANCEL] = _key(KEY_ESCAPE)
	events[PAUSE] = _key(KEY_P)
	events[SWITCH_SIDE] = _key(KEY_F9)
	events[CYCLE_WEATHER] = _key(KEY_F6)
	events[CYCLE_STATUS] = _key(KEY_F8)
	events[TOGGLE_AI_DEBUG] = _key(KEY_F5)
	events[TOGGLE_SCOREBOARD] = _key(KEY_F7)
	for i: int in NUMBER_KEYS.size():
		events[FORMATIONS[i]] = _key(NUMBER_KEYS[i])
		if classic:
			events[GROUP_RECALLS[i]] = _with_modifier(_key(NUMBER_KEYS[i]), default_classic_modifier())
		else:
			events[GROUP_SAVES[i]] = _with_modifier(_key(NUMBER_KEYS[i]), DEFAULT_SAVE_MODIFIER)
			events[GROUP_RECALLS[i]] = _with_modifier(_key(NUMBER_KEYS[i]), DEFAULT_RECALL_MODIFIER)
	return events


## Every pad default (the same in both presets).
static func pad_defaults() -> Dictionary[StringName, InputEvent]:
	var events: Dictionary[StringName, InputEvent] = {}
	events[PAD_CURSOR_LEFT] = _pad_axis(JOY_AXIS_LEFT_X, -1.0)
	events[PAD_CURSOR_RIGHT] = _pad_axis(JOY_AXIS_LEFT_X, 1.0)
	events[PAD_CURSOR_UP] = _pad_axis(JOY_AXIS_LEFT_Y, -1.0)
	events[PAD_CURSOR_DOWN] = _pad_axis(JOY_AXIS_LEFT_Y, 1.0)
	events[PAD_PAN_LEFT] = _pad_axis(JOY_AXIS_RIGHT_X, -1.0)
	events[PAD_PAN_RIGHT] = _pad_axis(JOY_AXIS_RIGHT_X, 1.0)
	events[PAD_PAN_FORWARD] = _pad_axis(JOY_AXIS_RIGHT_Y, -1.0)
	events[PAD_PAN_BACK] = _pad_axis(JOY_AXIS_RIGHT_Y, 1.0)
	events[PAD_ORBIT_LEFT] = _pad_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)
	events[PAD_ORBIT_RIGHT] = _pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	events[PAD_CENTER] = _pad_button(JOY_BUTTON_RIGHT_STICK)
	events[PAD_SELECT] = _pad_button(JOY_BUTTON_A)
	events[PAD_ORDER] = _pad_button(JOY_BUTTON_X)
	events[CANCEL] = _pad_button(JOY_BUTTON_B)
	events[ABILITY] = _pad_button(JOY_BUTTON_Y)
	events[PAD_FORMATION_WHEEL] = _pad_button(JOY_BUTTON_LEFT_SHOULDER)
	events[PAD_ORDER_WHEEL] = _pad_button(JOY_BUTTON_RIGHT_SHOULDER)
	events[PAD_GROUP_PREV] = _pad_button(JOY_BUTTON_DPAD_LEFT)
	events[PAD_GROUP_NEXT] = _pad_button(JOY_BUTTON_DPAD_RIGHT)
	events[PAD_GROUP_SAVE] = _pad_button(JOY_BUTTON_DPAD_UP)
	events[PAD_GROUP_CLEAR] = _pad_button(JOY_BUTTON_DPAD_DOWN)
	events[PAD_VIEW] = _pad_button(JOY_BUTTON_BACK)
	events[PAD_BAR_FOCUS] = _pad_button(JOY_BUTTON_LEFT_STICK)
	events[OPEN_MENU] = _pad_button(JOY_BUTTON_START)
	return events


static func _bind(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, _deadzone_of(event))
	_unbind(action, device_of(event))
	InputMap.action_add_event(action, event)
	if device_of(event) == Device.PAD:
		InputMap.action_set_deadzone(action, _deadzone_of(event))


# Removes the action's event in that slot, if any.
static func _unbind(action: StringName, device: Device) -> void:
	if not InputMap.has_action(action):
		return
	for event: InputEvent in InputMap.action_get_events(action):
		if device_of(event) == device:
			InputMap.action_erase_event(action, event)


# The deadzone an action bound to this event needs: low for a stick or a
# trigger, so it reads gently; Godot's default otherwise.
static func _deadzone_of(event: InputEvent) -> float:
	if event is InputEventJoypadMotion:
		var axis: JoyAxis = (event as InputEventJoypadMotion).axis
		if axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT:
			return TRIGGER_DEADZONE
		return STICK_DEADZONE
	return 0.5


# Adds the event to a built-in action unless it is there already.
static func _ensure_event(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		return
	var text: String = event_to_text(event)
	for existing: InputEvent in InputMap.action_get_events(action):
		if event_to_text(existing) == text:
			return
	InputMap.action_add_event(action, event)


static func _with_modifier(event: InputEventKey, modifier: GroupModifier) -> InputEventKey:
	match modifier:
		GroupModifier.COMMAND_OR_CONTROL:
			event.command_or_control_autoremap = true
		GroupModifier.ALT:
			event.alt_pressed = true
		GroupModifier.SHIFT:
			event.shift_pressed = true
		GroupModifier.COMMAND_OR_ALT:
			if _on_mac():
				event.command_or_control_autoremap = true
			else:
				event.alt_pressed = true
	return event


static func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	return event


static func _mouse(button: MouseButton) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	return event


static func _pad_button(button: JoyButton) -> InputEventJoypadButton:
	var event: InputEventJoypadButton = InputEventJoypadButton.new()
	event.button_index = button
	event.device = -1
	return event


static func _pad_axis(axis: JoyAxis, direction: float) -> InputEventJoypadMotion:
	var event: InputEventJoypadMotion = InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = direction
	event.device = -1
	return event
