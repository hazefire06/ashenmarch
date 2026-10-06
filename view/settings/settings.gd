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

## Where the real game keeps it: the per-user data directory.
const DEFAULT_PATH: String = "user://settings.cfg"
## The file's sections and keys.
const DISPLAY: String = "display"
const CONTROLS: String = "controls"
const FULLSCREEN: String = "fullscreen"
const EDGE_SCROLL: String = "edge_scroll"
## What each reads as when the file doesn't say: windowed, and no edge scroll.
## Both are opt-in (CLAUDE.md: edge scroll is optional).
const FULLSCREEN_DEFAULT: bool = false
const EDGE_SCROLL_DEFAULT: bool = false


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


## Puts the window in or out of fullscreen. Does nothing without a window: the
## headless tests have a DisplayServer that would only complain.
static func apply_window_mode(enabled: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if enabled else DisplayServer.WINDOW_MODE_WINDOWED
	)


# The file's contents, or an empty ConfigFile if it is missing or won't parse.
static func _read(path: String) -> ConfigFile:
	var config: ConfigFile = ConfigFile.new()
	if config.load(path) != OK:
		config.clear()
	return config


static func _get_bool(path: String, section: String, key: String, fallback: bool) -> bool:
	var value: Variant = _read(path).get_value(section, key, fallback)
	return value if value is bool else fallback


static func _set_value(path: String, section: String, key: String, value: Variant) -> Error:
	var folder: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder):
		var made: Error = DirAccess.make_dir_recursive_absolute(folder)
		if made != OK and made != ERR_ALREADY_EXISTS:
			return made
	var config: ConfigFile = _read(path)
	config.set_value(section, key, value)
	return config.save(path)
