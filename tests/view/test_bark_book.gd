extends GutTest
## The bark book the builder writes from audio-src/voices, and BarkLine's timing.


func test_the_book_has_every_light_unit_voiced() -> void:
	# All five light units are voiced (Tim's picks, 2026-11-18 to -20). Each line carries a stream for every
	# voice that can say it: both Shieldman voices (bar two lines he kept in the old voice only), each other
	# unit's single voice, and for a clan line all six light voices.
	var book: BarkBook = BarkBook.shared()
	var shield: int = 0
	for line: BarkLine in book.lines:
		assert_ne(line.text, "")
		if line.unit == &"shieldman":
			shield += 1
			assert_true(line.streams.has(&"shieldman_old"), "%s: the old voice" % line.id)
			var young: bool = not [&"annoyed_3", &"victory_1"].has(line.id)
			assert_eq(line.streams.has(&"shieldman_young"), young, "%s: the young voice" % line.id)
		elif not line.clan:
			assert_true(line.streams.has(line.unit), "%s (%s) is voiced" % [line.id, line.unit])
	assert_eq(shield, 37)
	assert_eq(book.lines_for(&"shieldman", &"select").size(), 5)
	assert_eq(book.lines_for(&"shieldman", &"victory").size(), 2)
	assert_true(book.has_trigger(&"shieldman", &"annoyed"))
	assert_false(book.has_trigger(&"shieldman", &"retreat"))
	assert_eq(book.clan_lines().size(), 5)
	for line: BarkLine in book.clan_lines():
		assert_eq(line.trigger, &"")
		assert_true(String(line.id).begins_with("clan_"))
	assert_gt(book.file_bytes(), 0, "the Shieldman's voice files")


func test_a_clan_line_is_not_among_a_units_lines() -> void:
	var book: BarkBook = BarkBook.shared()
	var found: int = 0
	for trigger: StringName in [&"select", &"move", &"attack"]:
		for line: BarkLine in book.lines_for(&"reaver", trigger):
			assert_false(line.clan)
			found += 1
	assert_eq(found, 13, "select 4, move 4, attack 5")


# Every Light unit can answer every trigger the game always fires, its own specials, and a victory.
func test_every_light_voice_file_covers_the_required_triggers() -> void:
	var book: BarkBook = BarkBook.shared()
	var required: Array[StringName] = [
		&"select", &"move", &"attack", &"kill", &"hurt", &"death", &"annoyed", &"victory"
	]
	var specials: Dictionary[StringName, Array] = {
		&"longbow": [&"special", &"fizzle"], &"sapper": [&"special", &"fizzle"], &"warden": [&"special", &"heal_undead"],
	}
	for unit: StringName in [&"shieldman", &"reaver", &"longbow", &"sapper", &"warden"]:
		var triggers: Array[StringName] = required.duplicate()
		for extra: StringName in specials.get(unit, []):
			triggers.append(extra)
		for trigger: StringName in triggers:
			assert_true(book.has_trigger(unit, trigger), "%s has no %s line" % [unit, trigger])


func test_estimate_seconds_is_a_lead_plus_a_fourteenth_per_character() -> void:
	assert_almost_eq(BarkLine.estimate_seconds(""), 0.4, 0.0001)
	assert_almost_eq(BarkLine.estimate_seconds("x".repeat(14)), 1.4, 0.0001)


func test_seconds_is_the_stream_length_when_voiced_else_the_estimate() -> void:
	var line: BarkLine = BarkLine.new()
	line.text = "x".repeat(28)
	line.streams[&"reaver"] = AudioFixtures.silent(2.5)
	assert_almost_eq(line.seconds(&"reaver"), 2.5, 0.001)
	assert_almost_eq(line.seconds(&"warden"), 2.4, 0.0001)


func test_every_light_voice_in_the_sound_map_is_in_some_lines_voices() -> void:
	var spoken: Dictionary[StringName, bool] = {}
	for line: BarkLine in BarkBook.shared().lines:
		for voice: StringName in line.voices:
			spoken[voice] = true
	var found: int = 0
	for entry: UnitSound in SoundMap.shared().units:
		for voice: StringName in entry.voices:
			assert_true(spoken.has(voice), "%s has no voice file" % voice)
			found += 1
	assert_eq(found, 6, "shieldman_old, shieldman_young, reaver, longbow, sapper, warden")
	for line: BarkLine in BarkBook.shared().clan_lines():
		assert_eq(line.voices.size(), 6)
