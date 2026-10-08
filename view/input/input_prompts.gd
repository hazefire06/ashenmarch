class_name InputPrompts
extends RefCounted
## On-screen prompts that name the device in use (InputDevice): the key or
## mouse button while the keyboard and mouse are in use, the pad's button,
## drawn, while a pad is. The pad's glyphs are original drawings in
## assets/ui/pad (an Xbox layout's buttons, plain shapes and letters).

const GLYPH_DIR: String = "res://assets/ui/pad/"
## Glyph file names by pad button.
const BUTTON_GLYPHS: Dictionary[int, String] = {
	JOY_BUTTON_A: "a", JOY_BUTTON_B: "b", JOY_BUTTON_X: "x", JOY_BUTTON_Y: "y",
	JOY_BUTTON_BACK: "view", JOY_BUTTON_START: "menu",
	JOY_BUTTON_LEFT_STICK: "l3", JOY_BUTTON_RIGHT_STICK: "r3",
	JOY_BUTTON_LEFT_SHOULDER: "lb", JOY_BUTTON_RIGHT_SHOULDER: "rb",
	JOY_BUTTON_DPAD_UP: "dpad_up", JOY_BUTTON_DPAD_DOWN: "dpad_down",
	JOY_BUTTON_DPAD_LEFT: "dpad_left", JOY_BUTTON_DPAD_RIGHT: "dpad_right",
}
## Glyph file names by pad axis.
const AXIS_GLYPHS: Dictionary[int, String] = {
	JOY_AXIS_LEFT_X: "ls", JOY_AXIS_LEFT_Y: "ls", JOY_AXIS_RIGHT_X: "rs", JOY_AXIS_RIGHT_Y: "rs",
	JOY_AXIS_TRIGGER_LEFT: "lt", JOY_AXIS_TRIGGER_RIGHT: "rt",
}
## What the pad hint strip lists, in order: the action and what it does.
const PAD_HINTS: Array[Array] = [
	[InputBindings.PAD_SELECT, "select"], [InputBindings.PAD_ORDER, "order"],
	[InputBindings.CANCEL, "back"], [InputBindings.ABILITY, "special"],
	[InputBindings.PAD_FORMATION_WHEEL, "formations"], [InputBindings.PAD_ORDER_WHEEL, "orders"],
	[InputBindings.PAD_GROUP_NEXT, "groups"], [InputBindings.PAD_VIEW, "map"],
	[InputBindings.PAD_BAR_FOCUS, "bar"],
]


## The glyph for a pad event, or null for one with none.
static func glyph(event: InputEvent) -> Texture2D:
	var file: String = ""
	if event is InputEventJoypadButton:
		file = BUTTON_GLYPHS.get((event as InputEventJoypadButton).button_index, "")
	elif event is InputEventJoypadMotion:
		file = AXIS_GLYPHS.get((event as InputEventJoypadMotion).axis, "")
	if file == "":
		return null
	return load(GLYPH_DIR + file + ".svg") as Texture2D


## The glyph for an action's pad binding, or null.
static func glyph_for(action: StringName) -> Texture2D:
	var event: InputEvent = InputBindings.event_of(action, InputBindings.Device.PAD)
	return glyph(event) if event != null else null


## BBCode naming an action for the device in use: its pad glyph as an image
## (size pixels high) while a pad is in use and has one, else the key's name.
static func prompt(action: StringName, size: int = 20) -> String:
	if pad_in_use():
		var event: InputEvent = InputBindings.event_of(action, InputBindings.Device.PAD)
		var texture: Texture2D = glyph(event) if event != null else null
		if texture != null:
			return "[img=%d]%s[/img]" % [size, texture.resource_path]
		if event != null:
			return InputBindings.event_label(event)
	return InputBindings.label_for(action)


## Plain text naming an action for the device in use: "T", or "Y".
static func label(action: StringName) -> String:
	if pad_in_use():
		var pad: String = InputBindings.label_for(action, InputBindings.Device.PAD)
		if pad != "":
			return pad
	return InputBindings.label_for(action)


## The pad hint strip's BBCode: each of PAD_HINTS as its glyph and what it does.
static func pad_hints(size: int = 22) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for hint: Array in PAD_HINTS:
		parts.append("%s %s" % [prompt(hint[0], size), hint[1]])
	return "   ".join(parts)


## True while a pad is the device in use.
static func pad_in_use() -> bool:
	return InputDeviceTracker.pad_in_use()
