class_name GameSettings
extends RefCounted
## The player's settings, kept in a ConfigFile (user://settings.cfg). Static
## helpers, because nothing here needs an object: each getter reads the file
## and each setter rewrites it, which is cheap at this size and means two
## screens can never disagree. Every function takes the path so a test can use
## a file of its own.
##
## A missing, unreadable or damaged file, or a value of the wrong type, gives
## the default: settings are a convenience and must never stop the game from
## starting. A setter keeps the keys it doesn't know (Phase 10 adds keybinds,
## volume and resolution to this file), so it loads, changes one value and
## saves, rather than writing a fresh file.
##
## Fullscreen is the window's, applied by the App (apply_window_mode); edge
## scroll is the mission camera's, applied by the App when a mission starts and
## when Settings closes over one.
##
## Phase 10 adds the rest of [display] (window size, vsync, frame cap, 3D
## render scale, interface scale; apply_display), [audio] (a volume per bus;
## apply_audio) and the controls ([keybinds], one line per rebound action as
## InputBindings.event_to_text, and the group modifiers in [controls];
## apply_bindings). Each apply reads the file and sets the engine to match, so
## it is called at boot and again after any change.
##
## Phase 11 adds the control preset ([controls] preset: Modern or Classic),
## Classic's own rebinds ([keybinds_classic]; [keybinds] stays Modern's, so a
## Phase 10 file loads as it was), its one group key ([controls]
## classic_group_modifier), and the pad's rebinds ([padbinds]).
##
## The [skirmish] section remembers the last skirmish setup (map, mode, time,
## budget, side, start, the AI's army and the player's own army), so the
## skirmish screen opens where the player left it. Not a setting the player
## edits, so it has no screen of its own; it is read as one choice
## (skirmish_choice) and written as one (set_skirmish_choice).

## Where the real game keeps it: the per-user data directory.
const DEFAULT_PATH: String = "user://settings.cfg"
## The file's sections and keys.
const DISPLAY: String = "display"
const CONTROLS: String = "controls"
const FULLSCREEN: String = "fullscreen"
const EDGE_SCROLL: String = "edge_scroll"
const SKIRMISH: String = "skirmish"
const AUDIO: String = "audio"
const KEYBINDS: String = "keybinds"
const KEYBINDS_CLASSIC: String = "keybinds_classic"
const PADBINDS: String = "padbinds"
const PRESET: String = "preset"
const CLASSIC_GROUP_MODIFIER: String = "classic_group_modifier"
const WINDOW_SIZE: String = "window_size"
const VSYNC: String = "vsync"
const MAX_FPS: String = "max_fps"
const RENDER_SCALE: String = "render_scale"
const UI_SCALE: String = "ui_scale"
const GROUP_SAVE_MODIFIER: String = "group_save_modifier"
const GROUP_RECALL_MODIFIER: String = "group_recall_modifier"
## Windowed sizes offered, in points: multiplied by the screen's scale, so
## 1280x720 is 2560x1440 pixels on a Retina display and the same size on
## screen as on any other.
const WINDOW_SIZES: Array[Vector2i] = [
	Vector2i(1152, 648), Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]
const WINDOW_SIZE_DEFAULT: int = 1
## Frame caps offered; 0 is none (vsync, if on, still holds it to the display).
const MAX_FPS_CHOICES: PackedInt32Array = [0, 30, 60, 120]
const MAX_FPS_DEFAULT: int = 0
const VSYNC_DEFAULT: bool = true
## 3D resolution in percent of the window's, bilinear-upscaled. The HUD is
## always drawn at full resolution.
const RENDER_SCALE_MIN: int = 50
const RENDER_SCALE_DEFAULT: int = 100
## Interface sizes offered, in percent; 0 is Auto, the screen's own scale
## (200 on a Retina display, a browser's devicePixelRatio on the web).
const UI_SCALE_CHOICES: PackedInt32Array = [0, 75, 100, 125, 150, 200, 250]
const UI_SCALE_DEFAULT: int = 0
## The audio buses (default_bus_layout.tres), with their default volumes in
## percent.
const VOLUMES_DEFAULT: Dictionary[String, int] = {
	"Master": 80, "Effects": 100, "Ambient": 100, "Interface": 100,
}
## What each reads as when the file doesn't say: windowed, and no edge scroll.
## Both are opt-in (CLAUDE.md: edge scroll is optional).
const FULLSCREEN_DEFAULT: bool = false
const EDGE_SCROLL_DEFAULT: bool = false
## The skirmish choice's keys, by type. Integers: the mode and the side as
## their enum values, the time limit in minutes, the budget in points, the
## start (0 is A, 1 is B), and the side the remembered army is on.
const SKIRMISH_INT_KEYS: PackedStringArray = [
	"mode", "minutes", "budget", "side", "start", "army_side",
]
## Strings: the map's id, the AI's army (a template id or "random"), and the
## player's army as "shieldman:10,longbow:4".
const SKIRMISH_STRING_KEYS: PackedStringArray = ["map", "ai_choice", "army"]


## Whether the game runs fullscreen.
static func fullscreen(path: String = DEFAULT_PATH) -> bool:
	return _get_bool(path, DISPLAY, FULLSCREEN, FULLSCREEN_DEFAULT)


## Whether the mission camera pans when the mouse is at the window's edge.
static func edge_scroll(path: String = DEFAULT_PATH) -> bool:
	return _get_bool(path, CONTROLS, EDGE_SCROLL, EDGE_SCROLL_DEFAULT)


## Saves the fullscreen choice. Returns the error from the write, or OK.
static func set_fullscreen(enabled: bool, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, DISPLAY, FULLSCREEN, enabled)


## Saves the edge scroll choice. Returns the error from the write, or OK.
static func set_edge_scroll(enabled: bool, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, CONTROLS, EDGE_SCROLL, enabled)


## One whole number from the [skirmish] section, or `fallback` if it is missing
## or isn't a whole number.
static func skirmish_int(key: String, fallback: int, path: String = DEFAULT_PATH) -> int:
	var value: Variant = _read(path).get_value(SKIRMISH, key, fallback)
	return value if value is int else fallback


## One string from the [skirmish] section, or `fallback` if it is missing or
## isn't a string.
static func skirmish_string(key: String, fallback: String, path: String = DEFAULT_PATH) -> String:
	var value: Variant = _read(path).get_value(SKIRMISH, key, fallback)
	return value if value is String else fallback


## Saves one whole number in the [skirmish] section. Returns the error from the
## write, or OK.
static func set_skirmish_int(key: String, value: int, path: String = DEFAULT_PATH) -> Error:
	return _set_values(path, SKIRMISH, {key: value})


## Saves one string in the [skirmish] section. Returns the error from the
## write, or OK.
static func set_skirmish_string(key: String, value: String, path: String = DEFAULT_PATH) -> Error:
	return _set_values(path, SKIRMISH, {key: value})


## The remembered skirmish choice: a dictionary with only the keys the file
## holds (as the right type), so a caller falls back key by key and an empty
## one means nothing is remembered. The keys are SKIRMISH_INT_KEYS and
## SKIRMISH_STRING_KEYS; whether the values still make sense (a map that was
## removed, an army that no longer fits) is for the skirmish screen to judge.
static func skirmish_choice(path: String = DEFAULT_PATH) -> Dictionary:
	var config: ConfigFile = _read(path)
	var choice: Dictionary = {}
	for key: String in SKIRMISH_INT_KEYS + SKIRMISH_STRING_KEYS:
		# get_value without a default complains about a missing key.
		if not config.has_section_key(SKIRMISH, key):
			continue
		var value: Variant = config.get_value(SKIRMISH, key)
		if (value is int and SKIRMISH_INT_KEYS.has(key)) or (value is String and SKIRMISH_STRING_KEYS.has(key)):
			choice[key] = value
	return choice


## Saves a skirmish choice in one write: every key it holds that is one of the
## skirmish keys, as the right type (anything else is left out, so a stray
## entry can't put a wrongly typed value in the file). Keys it lacks are left
## as they are. Returns the error from the write, or OK.
static func set_skirmish_choice(choice: Dictionary, path: String = DEFAULT_PATH) -> Error:
	var values: Dictionary = {}
	for key: String in SKIRMISH_INT_KEYS:
		if choice.get(key) is int:
			values[key] = choice[key]
	for key: String in SKIRMISH_STRING_KEYS:
		if choice.get(key) is String:
			values[key] = choice[key]
	return _set_values(path, SKIRMISH, values)


## The windowed size choice: an index into WINDOW_SIZES.
static func window_size(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, DISPLAY, WINDOW_SIZE, WINDOW_SIZE_DEFAULT, range(WINDOW_SIZES.size()))


static func vsync(path: String = DEFAULT_PATH) -> bool:
	return _get_bool(path, DISPLAY, VSYNC, VSYNC_DEFAULT)


## Frames per second at most; 0 for no cap.
static func max_fps(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, DISPLAY, MAX_FPS, MAX_FPS_DEFAULT, Array(MAX_FPS_CHOICES))


## 3D render scale in percent, RENDER_SCALE_MIN..100.
static func render_scale(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, DISPLAY, RENDER_SCALE, RENDER_SCALE_DEFAULT, range(RENDER_SCALE_MIN, 101))


## Interface scale in percent, or 0 for Auto.
static func ui_scale(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, DISPLAY, UI_SCALE, UI_SCALE_DEFAULT, Array(UI_SCALE_CHOICES))


## A display setting by key (WINDOW_SIZE, MAX_FPS, RENDER_SCALE, UI_SCALE, or
## VSYNC as a bool). Returns the error from the write, or OK.
static func set_display(key: String, value: Variant, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, DISPLAY, key, value)


## A bus's volume in percent, 0..100.
static func volume(bus: String, path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, AUDIO, bus.to_lower(), VOLUMES_DEFAULT.get(bus, 100), range(101))


static func set_volume(bus: String, percent: int, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, AUDIO, bus.to_lower(), clampi(percent, 0, 100))


## The control preset (InputBindings.Preset): Modern unless the file says.
static func preset(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(path, CONTROLS, PRESET, InputBindings.Preset.MODERN, range(InputBindings.Preset.size()))


static func set_preset(chosen: int, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, CONTROLS, PRESET, chosen)


## A preset's keyboard and mouse rebinds (the preset in the file if none is
## given). Lines that don't parse, name an action that isn't rebindable on the
## keyboard, or hold a pad event, are skipped.
static func keybinds(path: String = DEFAULT_PATH, of_preset: int = -1) -> Dictionary[StringName, InputEvent]:
	return _bindings(path, _keybinds_section(path, of_preset), InputBindings.Device.KBM)


## Saves several actions' keyboard and mouse bindings in one write (a swap
## changes two), for a preset (the one in the file if none is given).
static func set_keybinds(
	bindings: Dictionary[StringName, InputEvent], path: String = DEFAULT_PATH, of_preset: int = -1
) -> Error:
	return _set_bindings(bindings, path, _keybinds_section(path, of_preset))


## The pad's rebinds, skipping lines as keybinds() does.
static func padbinds(path: String = DEFAULT_PATH) -> Dictionary[StringName, InputEvent]:
	return _bindings(path, PADBINDS, InputBindings.Device.PAD)


## Saves several actions' pad bindings in one write.
static func set_padbinds(bindings: Dictionary[StringName, InputEvent], path: String = DEFAULT_PATH) -> Error:
	return _set_bindings(bindings, path, PADBINDS)


## Classic's one group key (InputBindings.GroupModifier); its default if
## missing or invalid.
static func classic_group_modifier(path: String = DEFAULT_PATH) -> int:
	return _get_int_in(
		path, CONTROLS, CLASSIC_GROUP_MODIFIER, InputBindings.default_classic_modifier(),
		range(InputBindings.GroupModifier.size())
	)


static func set_classic_group_modifier(modifier: int, path: String = DEFAULT_PATH) -> Error:
	return _set_value(path, CONTROLS, CLASSIC_GROUP_MODIFIER, modifier)


static func _keybinds_section(path: String, of_preset: int) -> String:
	var chosen: int = of_preset if of_preset >= 0 else preset(path)
	return KEYBINDS_CLASSIC if chosen == InputBindings.Preset.CLASSIC else KEYBINDS


static func _bindings(path: String, section: String, device: InputBindings.Device) -> Dictionary[StringName, InputEvent]:
	var config: ConfigFile = _read(path)
	var bound: Dictionary[StringName, InputEvent] = {}
	if not config.has_section(section):
		return bound
	for key: String in config.get_section_keys(section):
		var value: Variant = config.get_value(section, key)
		var event: InputEvent = InputBindings.text_to_event(value) if value is String else null
		if event == null or InputBindings.device_of(event) != device:
			continue
		if InputBindings.is_rebindable(StringName(key), device):
			bound[StringName(key)] = event
	return bound


static func _set_bindings(bindings: Dictionary[StringName, InputEvent], path: String, section: String) -> Error:
	var values: Dictionary = {}
	for action: StringName in bindings:
		values[String(action)] = InputBindings.event_to_text(bindings[action])
	return _set_values(path, section, values)


## The group save and recall modifiers (InputBindings.GroupModifier), as
## [save, recall]; the defaults if missing, invalid or equal.
static func group_modifiers(path: String = DEFAULT_PATH) -> Array[int]:
	var choices: Array = InputBindings.MODERN_GROUP_MODIFIERS
	var save: int = _get_int_in(path, CONTROLS, GROUP_SAVE_MODIFIER, InputBindings.DEFAULT_SAVE_MODIFIER, choices)
	var recall: int = _get_int_in(path, CONTROLS, GROUP_RECALL_MODIFIER, InputBindings.DEFAULT_RECALL_MODIFIER, choices)
	if save == recall:
		return [InputBindings.DEFAULT_SAVE_MODIFIER, InputBindings.DEFAULT_RECALL_MODIFIER]
	return [save, recall]


static func set_group_modifiers(save: int, recall: int, path: String = DEFAULT_PATH) -> Error:
	return _set_values(path, CONTROLS, {GROUP_SAVE_MODIFIER: save, GROUP_RECALL_MODIFIER: recall})


## Forgets the preset in force's keyboard and mouse rebinds and its group
## keys: its defaults again. The other preset's and the pad's are kept.
static func clear_controls(path: String = DEFAULT_PATH) -> Error:
	var config: ConfigFile = _read(path)
	var section: String = _keybinds_section(path, -1)
	if config.has_section(section):
		config.erase_section(section)
	var keys: Array[String] = [GROUP_SAVE_MODIFIER, GROUP_RECALL_MODIFIER]
	if section == KEYBINDS_CLASSIC:
		keys = [CLASSIC_GROUP_MODIFIER]
	for key: String in keys:
		if config.has_section_key(CONTROLS, key):
			config.erase_section_key(CONTROLS, key)
	return config.save(path)


## Forgets the pad's rebinds.
static func clear_pad_controls(path: String = DEFAULT_PATH) -> Error:
	var config: ConfigFile = _read(path)
	if config.has_section(PADBINDS):
		config.erase_section(PADBINDS)
	return config.save(path)


## Puts the InputMap on the saved controls: the preset's defaults, then its
## rebinds, the pad's, and the group keys on top.
static func apply_bindings(path: String = DEFAULT_PATH) -> void:
	InputBindings.reset(preset(path))
	InputBindings.apply(keybinds(path))
	InputBindings.apply(padbinds(path))
	if InputBindings.preset == InputBindings.Preset.CLASSIC:
		InputBindings.set_classic_group_modifier(classic_group_modifier(path) as InputBindings.GroupModifier)
		return
	var modifiers: Array[int] = group_modifiers(path)
	InputBindings.set_group_modifiers(
		modifiers[0] as InputBindings.GroupModifier, modifiers[1] as InputBindings.GroupModifier
	)


## Sets each bus's volume from the file; 0 % mutes it. A bus the layout
## doesn't have is skipped.
static func apply_audio(path: String = DEFAULT_PATH) -> void:
	for bus: String in VOLUMES_DEFAULT:
		var index: int = AudioServer.get_bus_index(bus)
		if index < 0:
			continue
		var percent: int = volume(bus, path)
		AudioServer.set_bus_mute(index, percent == 0)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(percent, 1) / 100.0))


## The interface scale a choice means on this screen: Auto is the screen's own
## scale (1 to 3).
static func resolved_ui_scale(percent: int) -> float:
	if percent == 0:
		return clampf(DisplayServer.screen_get_scale(), 1.0, 3.0)
	return percent / 100.0


## Sets `window` up as the file says: the interface and 3D render scales, the
## frame cap and vsync, and, when `size_window` and windowed on a desktop, the
## window size, centered on its screen. The window mode itself is
## apply_window_mode's. Headless, only the scales are set (there's no window).
static func apply_display(window: Window, size_window: bool, path: String = DEFAULT_PATH) -> void:
	window.content_scale_factor = resolved_ui_scale(ui_scale(path))
	window.scaling_3d_scale = render_scale(path) / 100.0
	Engine.max_fps = max_fps(path)
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync(path) else DisplayServer.VSYNC_DISABLED
	)
	if not size_window or OS.has_feature("web"):
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen: int = DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	var wanted: Vector2i = Vector2i(Vector2(WINDOW_SIZES[window_size(path)]) * DisplayServer.screen_get_scale(screen))
	var size: Vector2i = wanted.min(usable.size)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)


## Puts the window in or out of fullscreen. Does nothing without a window: the
## headless tests have a DisplayServer that would only complain.
static func apply_window_mode(enabled: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if enabled else DisplayServer.WINDOW_MODE_WINDOWED
	)


# The file's contents, or an empty ConfigFile if it is missing or won't parse.
# A file that constructs a Resource or an Object counts as damaged: ConfigFile
# would load the named resource (and run its script) while parsing, and no
# setting is ever one.
static func _read(path: String) -> ConfigFile:
	var config: ConfigFile = ConfigFile.new()
	if not FileAccess.file_exists(path):
		return config
	var text: String = FileAccess.get_file_as_string(path)
	if text.contains("Resource(") or text.contains("Object(") or config.parse(text) != OK:
		config.clear()
	return config


# An int setting that must be one of `allowed`, else `fallback`.
static func _get_int_in(path: String, section: String, key: String, fallback: int, allowed: Array) -> int:
	var value: Variant = _read(path).get_value(section, key, fallback)
	return value if value is int and allowed.has(value) else fallback


static func _get_bool(path: String, section: String, key: String, fallback: bool) -> bool:
	var value: Variant = _read(path).get_value(section, key, fallback)
	return value if value is bool else fallback


static func _set_value(path: String, section: String, key: String, value: Variant) -> Error:
	return _set_values(path, section, {key: value})


# Loads the file, sets every key in `values` and saves once: a write that
# fails halfway can't leave a choice half remembered.
static func _set_values(path: String, section: String, values: Dictionary) -> Error:
	var folder: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder):
		var made: Error = DirAccess.make_dir_recursive_absolute(folder)
		if made != OK and made != ERR_ALREADY_EXISTS:
			return made
	var config: ConfigFile = _read(path)
	for key: String in values:
		config.set_value(section, key, values[key])
	return config.save(path)
