extends GutTest
## The sound bank resources: lookup by id, random variants, one warning per
## missing id, and the shared session bank.


func test_a_cue_is_found_by_id_and_picks_each_variant() -> void:
	var bank: SoundBank = AudioFixtures.bank({&"hit_flesh": 3})
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var seen: Dictionary[AudioStream, bool] = {}
	for i: int in 60:
		seen[bank.pick(&"hit_flesh", rng)] = true
	assert_eq(seen.size(), 3)
	assert_true(bank.has(&"hit_flesh"))


func test_a_missing_cue_is_silent_and_warns_once() -> void:
	var bank: SoundBank = AudioFixtures.bank({&"hit_flesh": 1})
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	for i: int in 5:
		assert_null(bank.pick(&"nope", rng))
	assert_eq(bank.warned(), [&"nope"])
	assert_false(bank.has(&"nope"))


func test_a_declared_cue_with_no_streams_is_declared_but_not_had() -> void:
	var bank: SoundBank = AudioFixtures.bank({&"swing_claw": 0})
	assert_true(bank.declares(&"swing_claw"))
	assert_false(bank.has(&"swing_claw"))


func test_the_shared_bank_is_loaded_once() -> void:
	assert_same(SoundBank.shared(), SoundBank.shared())


func test_the_committed_bank_holds_every_cue_with_its_placeholder() -> void:
	var bank: SoundBank = SoundBank.shared()
	# The 64 cues of the cue book, plus the two Riverside music layers.
	assert_eq(bank.ids().size(), 66)
	assert_true(bank.has(&"hit_flesh"))
	assert_false(bank.has(&"swing_claw"), "declared, but no placeholder to play")
	assert_true(bank.declares(&"swing_claw"))
	var rain: SoundCue = bank.cue(&"bed_rain")
	assert_eq((rain.streams[0] as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_FORWARD)
	assert_eq(rain.playback, AudioServer.PLAYBACK_TYPE_STREAM)
	assert_false(bank.cue(&"explosion_small").loop)
	assert_gt(bank.cue(&"hit_flesh").file_bytes, 0)
	assert_eq(bank.cue(&"music_riverside_calm").bus, &"Music")
