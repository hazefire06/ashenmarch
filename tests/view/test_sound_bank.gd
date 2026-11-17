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


func test_the_committed_bank_holds_every_cue() -> void:
	var bank: SoundBank = SoundBank.shared()
	# The 64 cues of the cue book, plus the two Riverside music layers.
	assert_eq(bank.ids().size(), 66)
	assert_true(bank.has(&"hit_flesh"))
	assert_true(bank.declares(&"swing_claw"))
	assert_true(bank.has(&"swing_claw"), "its picked takes to play")
	# bed_rain is a bought loop: an Ogg Vorbis stream imported with loop=true.
	var rain: SoundCue = bank.cue(&"bed_rain")
	assert_is(rain.streams[0], AudioStreamOggVorbis)
	assert_true((rain.streams[0] as AudioStreamOggVorbis).loop, "the loop imports with loop=true")
	assert_eq(rain.playback, AudioServer.PLAYBACK_TYPE_STREAM)
	assert_false(bank.cue(&"explosion_small").loop)
	assert_gt(bank.cue(&"hit_flesh").file_bytes, 0)
	assert_eq(bank.cue(&"music_riverside_calm").bus, &"Music")


# Cue ids the code names itself, beyond SfxPlayer.NAMED_CUES (which has its own test) and the sound map:
# UiSounds plays &"ui_click"; Ambience's BEDS and MARCHES are the ten loops below (view/audio/ambience.gd).
const CODE_NAMED: Array[StringName] = [
	&"ui_click",
	&"march_grass", &"march_sand", &"march_rock", &"march_water",
	&"bed_outdoor", &"bed_rain", &"bed_snow", &"bed_fire", &"bed_water", &"bed_gas",
]


# Every one-shot and loop the map and the code name has a stream. The music cues are not here: music is
# bought in its own batch.
func test_every_named_cue_has_a_stream() -> void:
	_assert_all_have_streams(SoundBank.shared(), _named_cues())


func test_the_named_cue_check_names_a_cue_with_no_stream() -> void:
	var bank: SoundBank = AudioFixtures.bank({&"hit_flesh": 1, &"swing_claw": 0})
	var missing: Array[StringName] = _missing(bank, [&"hit_flesh", &"swing_claw", &"nope"])
	assert_eq(missing, [&"swing_claw", &"nope"])


func _named_cues() -> Array[StringName]:
	var ids: Dictionary[StringName, bool] = {}
	for id: StringName in SfxPlayer.NAMED_CUES:
		ids[id] = true
	for id: StringName in CODE_NAMED:
		ids[id] = true
	var map: SoundMap = SoundMap.shared()
	for u: UnitSound in map.units:
		for id: StringName in [u.death, u.groan]:
			if id != &"":
				ids[id] = true
		ids[StringName(SfxPlayer.SWING_PREFIX + String(u.weapon))] = true
		ids[StringName(SfxPlayer.HIT_PREFIX + String(u.body))] = true
	for p: ProjectileSound in map.projectiles:
		for id: StringName in [p.launch, p.stick, p.hit, p.bounce]:
			if id != &"":
				ids[id] = true
	var out: Array[StringName] = []
	out.assign(ids.keys())
	return out


func _missing(bank: SoundBank, ids: Array[StringName]) -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in ids:
		if not bank.has(id):
			out.append(id)
	return out


func _assert_all_have_streams(bank: SoundBank, ids: Array[StringName]) -> void:
	assert_gt(ids.size(), 50, "the map and code name plenty of cues")
	# _missing is the check test_the_named_cue_check_names_a_cue_with_no_stream proves can fail.
	assert_eq(_missing(bank, ids), [], "these cues are named but the bank has no stream for them")
