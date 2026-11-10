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


func test_registration_runs_only_on_web() -> void:
	var types: Array[StringName] = [&"shieldman", &"husk"]
	var off: Dictionary = SoundRegistry.load_for(types, _catalog(), SoundBank.shared(), SoundMap.shared(), [], 0, false)
	assert_gt(off["seconds"], 0.0, "still reports the seconds")
	assert_gt(off["file_bytes"], 0)
	assert_eq((off["lengths"] as PackedFloat32Array).size(), (off["streams"] as Array).size())
	var extra: Array[AudioStream] = [AudioStreamWAV.new()]
	var on: Dictionary = SoundRegistry.load_for(types, _catalog(), SoundBank.shared(), SoundMap.shared(), extra, 1000, false, true)
	assert_eq(on["file_bytes"], off["file_bytes"] + 1000)
	assert_eq((on["streams"] as Array).size(), (off["streams"] as Array).size() + 1, "extra joins")
