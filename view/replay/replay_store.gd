class_name ReplayStore
extends RefCounted
## Replay files: Zstandard-compressed var_to_bytes of Replay.to_dict(), with no
## objects allowed in, so a file can never carry code. The App keeps the
## player's replays in user://replays (the newest KEEP of them); the golden
## replays the verifier checks ship in res://data/replays/golden.
##
## Every function takes its path or directory, so tests use folders of their
## own.

const EXTENSION: String = "amr"
const DEFAULT_DIR: String = "user://replays"
const GOLDEN_DIR: String = "res://data/replays/golden"
## Replays kept in DEFAULT_DIR; save_new drops the oldest past this.
const KEEP: int = 30
## Files are refused above this on disk, and above MAX_DATA_BYTES once
## decompressed: a replay file is untrusted, and a small zstd file can claim
## a huge payload. A long campaign mission is about 15 KB.
const MAX_FILE_BYTES: int = 8 * 1024 * 1024
const MAX_DATA_BYTES: int = 32 * 1024 * 1024


## Writes `replay` to `path`, creating its folder. Returns OK or the error.
static func save(replay: Replay, path: String) -> Error:
	var made: Error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if made != OK and made != ERR_ALREADY_EXISTS:
		return made
	var file: FileAccess = FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(replay.to_dict(), false)
	var error: Error = file.get_error()
	file.close()
	return error


## The replay at `path`, or null; the reason, if any, is appended to
## `problems` ("can't open", "damaged", or Replay.from_dict's).
static func load_file(path: String, problems: Array[String] = []) -> Replay:
	var raw: FileAccess = FileAccess.open(path, FileAccess.READ)
	if raw == null:
		problems.append("can't open %s" % path)
		return null
	var raw_size: int = raw.get_length()
	raw.close()
	if raw_size > MAX_FILE_BYTES:
		problems.append("%s is too big to be a replay" % path)
		return null
	var file: FileAccess = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		problems.append("can't open %s" % path)
		return null
	# store_var's layout, read by hand so the length is checked before
	# anything is allocated for it: a 32-bit length, then that many bytes,
	# decoded with no objects allowed.
	var total: int = file.get_length()
	var size: int = file.get_32() if total >= 4 else -1
	if total > MAX_DATA_BYTES or size < 0 or size > total - 4:
		file.close()
		problems.append("%s is damaged" % path)
		return null
	var bytes: PackedByteArray = file.get_buffer(size)
	file.close()
	if bytes.size() != size:
		problems.append("%s is damaged" % path)
		return null
	return Replay.from_dict(bytes_to_var(bytes), problems)


## Saves a new replay in `dir` under a name from the summary's recorded_at and
## title, then drops the oldest past KEEP. Returns the path, or "" on failure.
static func save_new(replay: Replay, dir: String = DEFAULT_DIR) -> String:
	var stamp: int = replay.summary.get("recorded_at", 0)
	var title: String = str(replay.summary.get("title", "replay")).to_snake_case().validate_filename()
	var path: String = "%s/%d_%s.%s" % [dir, stamp, title, EXTENSION]
	var n: int = 2
	while FileAccess.file_exists(path):
		path = "%s/%d_%s_%d.%s" % [dir, stamp, title, n, EXTENSION]
		n += 1
	if save(replay, path) != OK:
		return ""
	prune(dir, KEEP)
	return path


## Replay files in `dir`, newest first (by name, which starts with the time).
static func list(dir: String = DEFAULT_DIR) -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return paths
	for file_name: String in DirAccess.get_files_at(dir):
		if file_name.get_extension() == EXTENSION:
			paths.append(dir.path_join(file_name))
	paths.sort()
	paths.reverse()
	return paths


## Deletes all but the newest `keep` replays in `dir`.
static func prune(dir: String, keep: int) -> void:
	var paths: PackedStringArray = list(dir)
	for i: int in range(keep, paths.size()):
		DirAccess.remove_absolute(paths[i])


## Deletes one replay. Returns OK or the error.
static func delete(path: String) -> Error:
	return DirAccess.remove_absolute(path)
