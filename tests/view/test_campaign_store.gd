extends GutTest
## CampaignStore: the campaign save file. It round-trips a CampaignState through
## JSON, writes to a temporary file and renames it over the save (so a failed
## write never damages the last good save), and reads suspiciously: a missing,
## empty, damaged or other-version file gives null and a reason, never a crash.
## Every test uses a directory of its own under user://, removed afterwards.

const DIR: String = "user://test_campaign_store"
const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"

var _store: CampaignStore


func before_each() -> void:
	_clean()
	_store = CampaignStore.new(DIR + "/campaign.json")


func after_each() -> void:
	_clean()


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## A state with a bit of everything: soldiers (one wounded), a fallen one, a
## history, a seed past 2^53 (which a JSON number would round).
func _busy_state() -> CampaignState:
	var state: CampaignState = CampaignFixtures.state([
		CampaignFixtures.soldier(1, SHIELDMAN, 7, 40), CampaignFixtures.soldier(2, LONGBOW, 2, 0),
	], 3, 9_007_199_254_740_993)
	var dead: Soldier = CampaignFixtures.soldier(3, SHIELDMAN, 4)
	dead.fallen_in = &"riverside"
	state.fallen.append(dead)
	state.next_soldier_id = 4
	state.mission_index = 1
	state.history.append({"id": "riverside", "ticks": 4500, "kills": 22, "losses": 1})
	return state


func test_a_saved_campaign_loads_back_the_same() -> void:
	var state: CampaignState = _busy_state()
	assert_eq(_store.save(state), OK)
	assert_eq(_store.last_error, "")
	var loaded: CampaignState = _store.load()
	assert_not_null(loaded, _store.last_error)
	assert_eq(loaded.to_dict(), state.to_dict(), "every field survives the file")
	assert_eq(loaded.campaign_seed, 9_007_199_254_740_993, "a seed past 2^53 isn't rounded by JSON")
	assert_eq(_store.last_error, "")


func test_exists_follows_the_file() -> void:
	assert_false(_store.exists())
	_store.save(_busy_state())
	assert_true(_store.exists())
	assert_eq(_store.delete(), OK)
	assert_false(_store.exists())
	assert_eq(_store.delete(), OK, "deleting nothing is fine")


func test_a_second_save_replaces_the_first() -> void:
	var state: CampaignState = _busy_state()
	_store.save(state)
	state.mission_index = 2
	state.tier = 4
	assert_eq(_store.save(state), OK)
	var loaded: CampaignState = _store.load()
	assert_eq(loaded.mission_index, 2)
	assert_eq(loaded.tier, 4)


func test_a_save_goes_through_a_temporary_file_that_is_gone_afterwards() -> void:
	_store.save(_busy_state())
	assert_file_exists(_store.path)
	assert_file_does_not_exist(_store.path + CampaignStore.TEMP_SUFFIX)
	assert_eq(CampaignStore.TEMP_SUFFIX, ".tmp")
	assert_eq(_store.path.get_file(), "campaign.json")


func test_a_leftover_temporary_file_never_gets_read_and_is_overwritten() -> void:
	# What a crash mid-save leaves: the old save intact, half a new one beside it.
	var state: CampaignState = _busy_state()
	_store.save(state)
	_write(_store.path + CampaignStore.TEMP_SUFFIX, "{\"version\": 1, \"campaign_se")
	var loaded: CampaignState = _store.load()
	assert_not_null(loaded, "the real save is read, not the temporary one")
	assert_eq(loaded.to_dict(), state.to_dict())
	state.mission_index = 2
	assert_eq(_store.save(state), OK)
	assert_file_does_not_exist(_store.path + CampaignStore.TEMP_SUFFIX)
	assert_eq(_store.load().mission_index, 2)


func test_a_failed_write_keeps_the_old_save() -> void:
	var state: CampaignState = _busy_state()
	_store.save(state)
	var before: String = _read(_store.path)
	# A directory where the temporary file must go: it can't be opened for writing.
	DirAccess.make_dir_recursive_absolute(_store.path + CampaignStore.TEMP_SUFFIX)
	state.mission_index = 2
	assert_ne(_store.save(state), OK)
	assert_ne(_store.last_error, "")
	assert_eq(_read(_store.path), before, "the old save is exactly as it was")
	DirAccess.remove_absolute(_store.path + CampaignStore.TEMP_SUFFIX)
	assert_eq(_store.load().mission_index, 1)


func test_a_save_makes_its_directory() -> void:
	var nested: CampaignStore = CampaignStore.new(DIR + "/deeper/still/campaign.json")
	assert_eq(nested.save(_busy_state()), OK)
	assert_not_null(nested.load())
	DirAccess.remove_absolute(DIR + "/deeper/still/campaign.json")
	DirAccess.remove_absolute(DIR + "/deeper/still")
	DirAccess.remove_absolute(DIR + "/deeper")


func test_no_save_gives_null_and_a_reason() -> void:
	assert_null(_store.load())
	assert_string_contains(_store.last_error, "no saved campaign")


func test_a_damaged_file_gives_null_and_a_reason() -> void:
	for text: String in ["", "not json at all", "{\"version\": 1,", "[1, 2, 3]", "null", "42"]:
		_write(_store.path, text)
		assert_null(_store.load(), "'%s' is not a save" % text)
		assert_ne(_store.last_error, "", "'%s' says why" % text)


func test_a_truncated_save_is_refused() -> void:
	_store.save(_busy_state())
	var text: String = _read(_store.path)
	# Half of it is the point; the odd character doesn't matter.
	@warning_ignore("integer_division")
	var half: int = text.length() / 2
	_write(_store.path, text.substr(0, half))
	assert_null(_store.load())
	assert_string_contains(_store.last_error, "not valid JSON")


func test_another_version_is_refused_with_a_reason() -> void:
	var data: Dictionary = _busy_state().to_dict()
	data["version"] = CampaignState.VERSION + 1
	_write(_store.path, JSON.stringify(data))
	assert_null(_store.load())
	assert_string_contains(_store.last_error, "version")


func test_a_well_formed_file_with_a_bad_field_is_refused() -> void:
	var data: Dictionary = _busy_state().to_dict()
	data["tier"] = 9
	_write(_store.path, JSON.stringify(data))
	assert_null(_store.load())
	assert_string_contains(_store.last_error, "tier")


func test_a_good_load_clears_the_last_error() -> void:
	assert_null(_store.load())
	assert_ne(_store.last_error, "")
	_store.save(_busy_state())
	assert_not_null(_store.load())
	assert_eq(_store.last_error, "")


func test_delete_removes_a_stale_temporary_file_too() -> void:
	_store.save(_busy_state())
	_write(_store.path + CampaignStore.TEMP_SUFFIX, "half")
	assert_eq(_store.delete(), OK)
	assert_file_does_not_exist(_store.path)
	assert_file_does_not_exist(_store.path + CampaignStore.TEMP_SUFFIX)


func test_the_default_path_is_the_users_campaign_file() -> void:
	assert_eq(CampaignStore.new().path, "user://campaign.json")
