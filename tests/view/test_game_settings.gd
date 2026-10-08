extends GutTest
## GameSettings: fullscreen and edge scroll in a ConfigFile, and the skirmish
## section that remembers the last setup. Missing, damaged or wrongly typed
## settings read as the defaults (never an error); a setter keeps the keys it
## doesn't know; the window mode is left alone headless.

const DIR: String = "user://test_game_settings"

var _path: String


func before_each() -> void:
	_clean()
	_path = DIR + "/settings.cfg"


func after_each() -> void:
	_clean()


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


func _write(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func test_defaults_with_no_file() -> void:
	assert_false(GameSettings.fullscreen(_path))
	assert_false(GameSettings.edge_scroll(_path))
	assert_false(GameSettings.FULLSCREEN_DEFAULT)
	assert_false(GameSettings.EDGE_SCROLL_DEFAULT)


func test_a_setting_round_trips() -> void:
	assert_eq(GameSettings.set_fullscreen(true, _path), OK)
	assert_true(GameSettings.fullscreen(_path))
	assert_false(GameSettings.edge_scroll(_path), "the other setting is untouched")
	assert_eq(GameSettings.set_edge_scroll(true, _path), OK)
	assert_true(GameSettings.edge_scroll(_path))
	assert_true(GameSettings.fullscreen(_path), "and the first is still there")
	GameSettings.set_fullscreen(false, _path)
	assert_false(GameSettings.fullscreen(_path))
	assert_true(GameSettings.edge_scroll(_path))


func test_the_file_is_a_real_config_file() -> void:
	GameSettings.set_fullscreen(true, _path)
	GameSettings.set_edge_scroll(true, _path)
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_path), OK)
	assert_eq(config.get_value("display", "fullscreen"), true)
	assert_eq(config.get_value("controls", "edge_scroll"), true)


func test_a_damaged_file_reads_as_the_defaults_and_is_mended_by_a_setter() -> void:
	_write("[display\nfullscreen = = = true\n" + char(1) + char(2))
	assert_false(GameSettings.fullscreen(_path))
	assert_false(GameSettings.edge_scroll(_path))
	assert_eq(GameSettings.set_edge_scroll(true, _path), OK, "writing over a damaged file works")
	assert_true(GameSettings.edge_scroll(_path))
	# ConfigFile reports a file it can't parse to the log, once per read: the two
	# getters and the setter's own read.
	assert_engine_error_count(3, "the damage is logged, and nothing else goes wrong")


func test_a_value_of_the_wrong_type_reads_as_the_default() -> void:
	_write("[display]\nfullscreen=\"yes\"\n[controls]\nedge_scroll=3\n")
	assert_false(GameSettings.fullscreen(_path))
	assert_false(GameSettings.edge_scroll(_path))


func test_a_setter_keeps_keys_it_does_not_know() -> void:
	_write("[display]\nfullscreen=false\nresolution=\"1920x1080\"\n[audio]\nvolume=0.5\n")
	GameSettings.set_fullscreen(true, _path)
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_path), OK)
	assert_eq(config.get_value("display", "resolution"), "1920x1080")
	assert_eq(config.get_value("audio", "volume"), 0.5)
	assert_eq(config.get_value("display", "fullscreen"), true)


func test_a_setter_makes_the_directory() -> void:
	var nested: String = DIR + "/deeper/settings.cfg"
	assert_eq(GameSettings.set_edge_scroll(true, nested), OK)
	assert_true(GameSettings.edge_scroll(nested))
	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(DIR + "/deeper")


func test_the_window_mode_is_left_alone_without_a_window() -> void:
	var before: DisplayServer.WindowMode = DisplayServer.window_get_mode()
	GameSettings.apply_window_mode(true)
	GameSettings.apply_window_mode(false)
	assert_eq(DisplayServer.window_get_mode(), before)


func test_the_default_path_is_the_users_settings_file() -> void:
	assert_eq(GameSettings.DEFAULT_PATH, "user://settings.cfg")


# --- the [skirmish] section -------------------------------------------------------


func _full_choice() -> Dictionary:
	return {
		"map": "old_mill", "mode": 2, "minutes": 15, "budget": 1500, "side": 1, "start": 1,
		"ai_choice": "light_siege", "army": "husk:30,ripper:10", "army_side": 1,
	}


func test_skirmish_keys_read_as_their_fallbacks_with_no_file() -> void:
	assert_eq(GameSettings.skirmish_int("budget", 1000, _path), 1000)
	assert_eq(GameSettings.skirmish_string("map", "riverside", _path), "riverside")
	assert_eq(GameSettings.skirmish_choice(_path), {}, "nothing is remembered")


func test_a_skirmish_number_and_a_skirmish_string_round_trip() -> void:
	assert_eq(GameSettings.set_skirmish_int("budget", 1500, _path), OK)
	assert_eq(GameSettings.set_skirmish_string("map", "the_ford", _path), OK)
	assert_eq(GameSettings.skirmish_int("budget", 1000, _path), 1500)
	assert_eq(GameSettings.skirmish_string("map", "riverside", _path), "the_ford")
	assert_eq(GameSettings.skirmish_int("minutes", 10, _path), 10, "another key is untouched")


func test_the_skirmish_keys_live_in_their_own_section() -> void:
	GameSettings.set_skirmish_int("budget", 600, _path)
	GameSettings.set_skirmish_string("map", "old_mill", _path)
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_path), OK)
	assert_eq(config.get_value("skirmish", "budget"), 600)
	assert_eq(config.get_value("skirmish", "map"), "old_mill")
	assert_false(config.has_section("display"), "the other sections are not made")


func test_a_skirmish_value_of_the_wrong_type_reads_as_the_fallback() -> void:
	_write("[skirmish]\nbudget=\"lots\"\nminutes=true\nmap=7\nai_choice=[\"a\"]\nmode=1.5\n")
	assert_eq(GameSettings.skirmish_int("budget", 1000, _path), 1000)
	assert_eq(GameSettings.skirmish_int("minutes", 10, _path), 10, "a bool is not a whole number")
	assert_eq(GameSettings.skirmish_int("mode", 0, _path), 0, "nor is a float")
	assert_eq(GameSettings.skirmish_string("map", "riverside", _path), "riverside")
	assert_eq(GameSettings.skirmish_string("ai_choice", "random", _path), "random")
	assert_eq(GameSettings.skirmish_choice(_path), {}, "none of it is usable")


func test_a_skirmish_setter_keeps_everything_else_in_the_file() -> void:
	_write("[display]\nfullscreen=true\n[skirmish]\nfavourite_colour=\"green\"\nbudget=600\n[audio]\nvolume=0.5\n")
	GameSettings.set_skirmish_int("budget", 1000, _path)
	GameSettings.set_skirmish_choice({"map": "old_mill"}, _path)
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_path), OK)
	assert_eq(config.get_value("skirmish", "favourite_colour"), "green", "a skirmish key it doesn't know")
	assert_eq(config.get_value("skirmish", "budget"), 1000)
	assert_eq(config.get_value("skirmish", "map"), "old_mill")
	assert_eq(config.get_value("display", "fullscreen"), true)
	assert_eq(config.get_value("audio", "volume"), 0.5)
	assert_true(GameSettings.fullscreen(_path))


func test_a_whole_skirmish_choice_round_trips() -> void:
	assert_eq(GameSettings.set_skirmish_choice(_full_choice(), _path), OK)
	assert_eq(GameSettings.skirmish_choice(_path), _full_choice())
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_path), OK)
	assert_eq(config.get_value("skirmish", "army"), "husk:30,ripper:10")
	assert_eq(config.get_value("skirmish", "army_side"), 1)
	assert_eq(config.get_section_keys("skirmish").size(), 9)


func test_a_later_choice_replaces_the_earlier_one() -> void:
	GameSettings.set_skirmish_choice(_full_choice(), _path)
	var other: Dictionary = _full_choice()
	other["map"] = "riverside"
	other["budget"] = 600
	other["army"] = "shieldman:4"
	other["army_side"] = 0
	other["side"] = 0
	GameSettings.set_skirmish_choice(other, _path)
	assert_eq(GameSettings.skirmish_choice(_path), other)


func test_a_partial_choice_is_written_and_read_as_the_keys_it_has() -> void:
	GameSettings.set_skirmish_choice({"map": "the_ford", "budget": 600}, _path)
	assert_eq(GameSettings.skirmish_choice(_path), {"map": "the_ford", "budget": 600})


func test_a_choice_keeps_only_the_right_keys_with_the_right_types() -> void:
	var messy: Dictionary = {
		"map": "old_mill", "budget": "1000", "mode": 1, "minutes": 5.5, "colour": "red",
		"side": null, "ai_choice": 3, "army": "husk:2", "start": true,
	}
	GameSettings.set_skirmish_choice(messy, _path)
	assert_eq(GameSettings.skirmish_choice(_path), {"map": "old_mill", "mode": 1, "army": "husk:2"})
	var config: ConfigFile = ConfigFile.new()
	config.load(_path)
	assert_false(config.has_section_key("skirmish", "colour"), "a stray key is not written")


func test_a_choice_in_a_damaged_file_reads_as_nothing_and_is_mended() -> void:
	_write("[skirmish\nmap = = =\n" + char(1))
	assert_eq(GameSettings.skirmish_choice(_path), {})
	assert_eq(GameSettings.set_skirmish_choice(_full_choice(), _path), OK, "writing over a damaged file works")
	assert_eq(GameSettings.skirmish_choice(_path), _full_choice())
	# The damage is logged once by each read of the damaged file: the first
	# getter and the setter's own.
	assert_engine_error_count(2, "the damage is logged, and nothing else goes wrong")


func test_the_skirmish_choice_makes_the_directory() -> void:
	var nested: String = DIR + "/deeper/settings.cfg"
	assert_eq(GameSettings.set_skirmish_choice(_full_choice(), nested), OK)
	assert_eq(GameSettings.skirmish_choice(nested), _full_choice())
	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(DIR + "/deeper")


func test_a_file_that_builds_a_resource_reads_as_the_defaults() -> void:
	# ConfigFile would load the named resource while parsing (running its
	# script); no setting is ever one, so such a file is treated as damaged.
	_write("[display]\nfullscreen=true\nsneaky=Resource(\"res://nowhere/evil.gd\")\n")
	assert_false(GameSettings.fullscreen(_path), "the whole file is ignored")
	_write("[display]\nfullscreen=true\nsneaky=Object(Node,\"name\":\"x\")\n")
	assert_false(GameSettings.fullscreen(_path))
