extends GutTest
## ReplayStore and ReplayVerifier: replay files round-trip, list newest first,
## keep only the newest KEEP, and refuse damaged files with a reason; the
## golden replays ship and verify; the verifier reads its request from the
## command line or the page's URL and plays a replay to a verdict.

const DIR: String = "user://test_replay_store"


func before_each() -> void:
	_clean()


func after_each() -> void:
	_clean()


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


# A small replay with every field filled.
func _replay(stamp: int = 1000, title: String = "Riverside") -> Replay:
	var replay: Replay = Replay.new()
	replay.kind = Replay.Kind.MISSION
	replay.game_version = "0.10.0"
	replay.setup = {
		"mission": "res://data/missions/riverside/mission.tres", "tier": 2, "seed": 7,
		"deploy": CommandCodec.encode(DeployCommand.new(
			0, [&"shieldman"] as Array[StringName], PackedInt32Array([1]), PackedInt32Array([0]),
			PackedInt32Array([0]), 0, 0, 0, 1000
		)),
	}
	replay.commands = [CommandCodec.encode(StopUnitsCommand.new(5, PackedInt32Array([1])))]
	replay.checkpoints = [[300, "abc", {"header": "def"}]]
	replay.end_tick = 400
	replay.final_hash = "123"
	replay.summary = {"title": title, "recorded_at": stamp}
	return replay


func test_a_saved_replay_loads_back_the_same() -> void:
	var path: String = DIR + "/one.amr"
	assert_eq(ReplayStore.save(_replay(), path), OK)
	var back: Replay = ReplayStore.load_file(path)
	assert_not_null(back)
	if back != null:
		assert_eq(back.to_dict(), _replay().to_dict())


func test_save_new_names_by_time_lists_newest_first_and_keeps_the_newest() -> void:
	var first: String = ReplayStore.save_new(_replay(1000, "Old Mill"), DIR)
	assert_eq(first.get_file(), "1000_old_mill.amr")
	assert_eq(ReplayStore.save_new(_replay(1000, "Old Mill"), DIR).get_file(), "1000_old_mill_2.amr", "no overwrite")
	for stamp: int in range(1001, 1001 + ReplayStore.KEEP):
		ReplayStore.save_new(_replay(stamp), DIR)
	var paths: PackedStringArray = ReplayStore.list(DIR)
	assert_eq(paths.size(), ReplayStore.KEEP)
	assert_eq(paths[0].get_file(), "%d_riverside.amr" % (1000 + ReplayStore.KEEP))
	assert_false(paths.has(first), "the oldest went")


func test_damaged_and_missing_files_are_refused_with_a_reason() -> void:
	var problems: Array[String] = []
	assert_null(ReplayStore.load_file(DIR + "/none.amr", problems))
	assert_string_contains(problems[0], "can't open")
	DirAccess.make_dir_recursive_absolute(DIR)
	var raw: FileAccess = FileAccess.open(DIR + "/junk.amr", FileAccess.WRITE)
	raw.store_string("not a replay at all")
	raw.close()
	problems.clear()
	assert_null(ReplayStore.load_file(DIR + "/junk.amr", problems))
	assert_eq(problems.size(), 1)
	var wrong: Replay = _replay()
	wrong.format = 99
	ReplayStore.save(wrong, DIR + "/future.amr")
	problems.clear()
	assert_null(ReplayStore.load_file(DIR + "/future.amr", problems))
	assert_string_contains(problems[0], "format 99")


func test_listing_a_missing_folder_is_empty() -> void:
	assert_eq(ReplayStore.list(DIR + "/nope"), PackedStringArray())


func test_the_golden_replays_ship_and_load() -> void:
	var paths: PackedStringArray = ReplayVerifier.golden_paths()
	assert_eq(paths.size(), 4)
	for path: String in paths:
		var problems: Array[String] = []
		var replay: Replay = ReplayStore.load_file(path, problems)
		assert_not_null(replay, "%s: %s" % [path, problems])
		if replay != null:
			assert_gt(replay.checkpoints.size(), 0, path)


func test_the_request_comes_from_the_command_line() -> void:
	assert_eq(ReplayVerifier._from_args(PackedStringArray()), {})
	assert_eq(ReplayVerifier._from_args(PackedStringArray(["--other"])), {})
	var all: Dictionary = ReplayVerifier._from_args(PackedStringArray(["--verify-replays"]))
	assert_eq(all["paths"], PackedStringArray())
	assert_eq(all["trace"], PackedInt32Array())
	var some: Dictionary = ReplayVerifier._from_args(PackedStringArray([
		"--verify-replays=a.amr,b.amr", "--trace=300-310", "--trace-entities",
	]))
	assert_eq(some["paths"], PackedStringArray(["a.amr", "b.amr"]))
	assert_eq(some["trace"], PackedInt32Array([300, 310]))
	assert_true(some["entities"])
	var bad_trace: Dictionary = ReplayVerifier._from_args(PackedStringArray(["--verify-replays", "--trace=x-3"]))
	assert_eq(bad_trace["trace"], PackedInt32Array())


func test_the_request_comes_from_the_url_on_the_web() -> void:
	assert_eq(ReplayVerifier._from_query(""), {})
	assert_eq(ReplayVerifier._from_query("?verify=0"), {})
	assert_eq(ReplayVerifier._from_query("?verify=1")["paths"], PackedStringArray())
	var some: Dictionary = ReplayVerifier._from_query("?verify=res%3A%2F%2Fa.amr&trace=5-9&entities=1")
	assert_eq(some["paths"], PackedStringArray(["res://a.amr"]))
	assert_eq(some["trace"], PackedInt32Array([5, 9]))
	assert_true(some["entities"])


func test_the_verifier_plays_a_replay_to_a_verdict() -> void:
	# The shortest golden, played in the tree as the App would.
	var verifier: ReplayVerifier = ReplayVerifier.new()
	verifier.catalog = TestTerrains.catalog()
	verifier.ticks_per_frame = 5000
	add_child_autofree(verifier)
	watch_signals(verifier)
	verifier.start({"paths": PackedStringArray([ReplayStore.GOLDEN_DIR + "/skirmish_ctf.amr"])})
	await wait_for_signal(verifier.finished, 30)
	assert_signal_emitted_with_parameters(verifier, "finished", [true])


func test_the_verifier_reports_a_missing_file_as_a_failure() -> void:
	var verifier: ReplayVerifier = ReplayVerifier.new()
	verifier.catalog = TestTerrains.catalog()
	add_child_autofree(verifier)
	watch_signals(verifier)
	verifier.start({"paths": PackedStringArray([DIR + "/none.amr"])})
	assert_signal_emitted_with_parameters(verifier, "finished", [false])


func test_oversized_or_lying_files_are_refused() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var big: FileAccess = FileAccess.open(DIR + "/big.amr", FileAccess.WRITE)
	var chunk: PackedByteArray = PackedByteArray()
	chunk.resize(1024 * 1024)
	for i: int in 9:
		big.store_buffer(chunk)
	big.close()
	var problems: Array[String] = []
	assert_null(ReplayStore.load_file(DIR + "/big.amr", problems))
	assert_string_contains(problems[0], "too big")
	# A compressed file whose stored length claims more than it holds.
	var lying: FileAccess = FileAccess.open_compressed(DIR + "/lying.amr", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	lying.store_32(1 << 30)
	lying.store_buffer(PackedByteArray([1, 2, 3]))
	lying.close()
	problems.clear()
	assert_null(ReplayStore.load_file(DIR + "/lying.amr", problems))
	assert_string_contains(problems[0], "damaged")
