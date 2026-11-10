extends GutTest
## The audio budget's arithmetic and the Web registration's cue list.


func _catalog() -> UnitCatalog:
	return load(App.CATALOG_PATH) as UnitCatalog


func test_decoded_bytes_are_seconds_times_rate_times_eight() -> void:
	assert_eq(AudioBudget.decoded_bytes(10.0, 48000.0), 3_840_000.0)


func test_the_play_allowance_takes_the_27_longest() -> void:
	var lengths: PackedFloat32Array = PackedFloat32Array()
	for s: int in range(30, 0, -1):
		lengths.append(float(s))
	var sum: float = 0.0
	for s: int in range(4, 31):
		sum += s
	assert_eq(AudioBudget.play_allowance_bytes(lengths, 48000.0), sum * 48000.0 * 8.0)
	assert_eq(AudioBudget.play_allowance_bytes(PackedFloat32Array([2.0]), 48000.0), 2.0 * 48000.0 * 8.0, "fewer than 27")


func test_the_audio_verdict_is_against_270() -> void:
	assert_eq(AudioBudget.verdict(270.0), "PASS")
	assert_eq(AudioBudget.verdict(270.5), "FAIL")


func test_a_launch_registers_its_types_and_the_shared_cues() -> void:
	var types: Array[StringName] = [&"shieldman", &"husk"]
	var ids: Array[StringName] = SoundRegistry.one_shot_cues(types, _catalog(), SoundBank.shared(), SoundMap.shared())
	for id: StringName in [&"death_shieldman", &"death_husk", &"groan_husk", &"ui_click"]:
		assert_has(ids, id)
	assert_does_not_have(ids, &"death_reaver")
	for id: StringName in ids:
		assert_false(String(id).begins_with("bed_") or String(id).begins_with("music_"), String(id))
	var sorted: Array[StringName] = ids.duplicate()
	sorted.sort()
	assert_eq(ids, sorted, "sorted")


var _registered: Array[AudioStream] = []


func _record(s: AudioStream) -> void:
	_registered.append(s)


func before_each() -> void:
	SoundRegistry.reset_for_tests()
	_registered.clear()


func _load(on_web: bool, enabled: bool, extra: Array[AudioStream] = [], extra_bytes: int = 0) -> Dictionary:
	var types: Array[StringName] = [&"shieldman", &"husk"]
	return SoundRegistry.load_for(
		types, _catalog(), SoundBank.shared(), SoundMap.shared(), extra, extra_bytes, on_web, enabled, _record
	)


func test_web_and_enabled_registers_each_stream_once() -> void:
	var r: Dictionary = _load(true, true)
	assert_gt((r["streams"] as Array).size(), 0)
	assert_eq(_registered.size(), (r["streams"] as Array).size())
	for s: AudioStream in r["streams"]:
		assert_eq(_registered.count(s), 1)


func test_a_second_load_registers_nothing_again_but_still_counts() -> void:
	var first: Dictionary = _load(true, true)
	var n: int = _registered.size()
	var second: Dictionary = _load(true, true)
	assert_eq(_registered.size(), n, "no stream registers twice")
	assert_eq(second["seconds"], first["seconds"])
	assert_eq((second["streams"] as Array).size(), (first["streams"] as Array).size())


func test_audio_0_never_registers() -> void:
	var r: Dictionary = _load(true, false)
	assert_eq(_registered.size(), 0)
	assert_gt(r["seconds"], 0.0, "still reports the seconds")


func test_desktop_never_registers() -> void:
	var r: Dictionary = _load(false, true)
	assert_eq(_registered.size(), 0)
	assert_gt(r["seconds"], 0.0)
	assert_gt(r["file_bytes"], 0)
	assert_eq((r["lengths"] as PackedFloat32Array).size(), (r["streams"] as Array).size())


func test_extra_streams_join_and_their_file_bytes_add() -> void:
	var base: Dictionary = _load(false, true)
	var extra: Array[AudioStream] = [AudioStreamWAV.new()]
	var r: Dictionary = _load(true, true, extra, 1000)
	assert_eq(r["file_bytes"], base["file_bytes"] + 1000)
	assert_eq((r["streams"] as Array).size(), (base["streams"] as Array).size() + 1)
	assert_has(_registered, extra[0])
