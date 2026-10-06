class_name CampaignStore
extends RefCounted
## The campaign save: one JSON file holding CampaignState.to_dict(). The state
## is pure data, so this is the only place that knows the file exists. The path
## is a parameter so a test can point it at a directory of its own.
##
## A save never leaves a half-written file where the good one was: the JSON is
## written to `<path>.tmp` first and that is renamed over the target, so a crash
## or a full disk during the write loses the new save and keeps the old one. A
## stale `.tmp` from such a crash is never read, only overwritten by the next
## save. Reads are as suspicious as CampaignState.from_dict is: a missing,
## empty, damaged or other-version file gives null and `last_error` says why,
## and the game carries on without a save.
##
## The autosave points are the App's: a new campaign, and after each victory is
## applied. A Retry reloads this file, which is the state as it stood before the
## mission (a defeat is never applied).

## Where the real game keeps it: the per-user data directory.
const DEFAULT_PATH: String = "user://campaign.json"
## Appended to the path for the file a save is written to before the rename.
const TEMP_SUFFIX: String = ".tmp"

## Where this store reads and writes.
var path: String = DEFAULT_PATH
## Why the last save() or load() failed, or "" if it didn't. For the menu to show.
var last_error: String = ""


func _init(save_path: String = DEFAULT_PATH) -> void:
	path = save_path


## True if a file is at the path (whether it can be read or not).
func exists() -> bool:
	return FileAccess.file_exists(path)


## Writes the state: to the temporary file, then renamed over the save. Returns
## OK, or the error that stopped it (last_error says in words). A failed save
## leaves the old save as it was and removes its own temporary file.
func save(state: CampaignState) -> Error:
	last_error = ""
	var folder: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder):
		var made: Error = DirAccess.make_dir_recursive_absolute(folder)
		if made != OK and made != ERR_ALREADY_EXISTS:
			return _fail("could not create %s (%s)" % [folder, error_string(made)], made)
	var temp_path: String = path + TEMP_SUFFIX
	var file: FileAccess = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		var opened: Error = FileAccess.get_open_error()
		return _fail("could not write %s (%s)" % [temp_path, error_string(opened)], opened)
	var written: bool = file.store_string(JSON.stringify(state.to_dict(), "\t"))
	var write_error: Error = file.get_error()
	file.close()
	if not written or write_error != OK:
		DirAccess.remove_absolute(temp_path)
		var failure: Error = write_error if write_error != OK else FAILED
		return _fail("could not finish writing %s (%s)" % [temp_path, error_string(failure)], failure)
	var renamed: Error = DirAccess.rename_absolute(temp_path, path)
	if renamed != OK:
		DirAccess.remove_absolute(temp_path)
		return _fail("could not move the save into place at %s (%s)" % [path, error_string(renamed)], renamed)
	return OK


## Reads the save back. Null if there is none, or it can't be trusted (not
## JSON, the wrong version, a field missing or out of range: whatever
## CampaignState.from_dict says); `last_error` says which.
func load() -> CampaignState:
	last_error = ""
	if not exists():
		last_error = "there is no saved campaign"
		return null
	var text: String = FileAccess.get_file_as_string(path)
	var read_error: Error = FileAccess.get_open_error()
	if read_error != OK:
		last_error = "could not read %s (%s)" % [path, error_string(read_error)]
		return null
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		last_error = "the save is not valid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]
		return null
	var errors: PackedStringArray = PackedStringArray()
	var state: CampaignState = CampaignState.from_dict(json.data, errors)
	if state == null:
		last_error = errors[0] if not errors.is_empty() else "the save could not be read"
	return state


## Removes the save and any temporary file beside it. OK if there was nothing
## to remove.
func delete() -> Error:
	var result: Error = OK
	for file_path: String in [path, path + TEMP_SUFFIX]:
		if FileAccess.file_exists(file_path):
			var removed: Error = DirAccess.remove_absolute(file_path)
			if removed != OK:
				result = removed
	return result


func _fail(message: String, error: Error) -> Error:
	last_error = message
	return error
