extends GutTest
## GameSettings: fullscreen and edge scroll in a ConfigFile. Missing, damaged
## or wrongly typed settings read as the defaults (never an error); a setter
## keeps the keys it doesn't know; the window mode is left alone headless.

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
