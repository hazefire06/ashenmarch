extends GutTest
## The sound map: every type and projectile has an entry, every cue it names is
## in the bank, and unknown types, missing cues and maps fall back.


func _catalog() -> UnitCatalog:
	return load("res://data/units/catalog.tres") as UnitCatalog


func _unit(type: UnitType, id: int) -> Unit:
	return Unit.new(id, 0, 0, 0, type, 0, type.faction)


func test_every_catalog_type_and_projectile_has_its_own_entry() -> void:
	var map: SoundMap = SoundMap.shared()
	var catalog: UnitCatalog = _catalog()
	for t: UnitType in catalog.types:
		var entry: UnitSound = map.for_unit(t)
		assert_not_null(entry, "entry for %s" % t.id)
		assert_eq(entry.type_id, t.id, "own entry for %s" % t.id)
	for p: ProjectileType in catalog.projectile_types:
		var entry: ProjectileSound = map.for_projectile(p.id)
		assert_not_null(entry, "entry for %s" % p.id)
		if entry != null:
			assert_eq(entry.projectile_id, p.id)


func test_every_cue_the_map_names_is_declared() -> void:
	var map: SoundMap = SoundMap.shared()
	var bank: SoundBank = SoundBank.shared()
	var named: Array[StringName] = []
	for u: UnitSound in map.units:
		named.append(StringName("swing_%s" % u.weapon))
		named.append(StringName("hit_%s" % u.body))
		named.append(u.death)
		if u.groan != &"":
			named.append(u.groan)
	for p: ProjectileSound in map.projectiles:
		for c: StringName in [p.launch, p.stick, p.hit, p.bounce]:
			if c != &"":
				named.append(c)
	for pair: MusicPair in map.music:
		named.append(pair.calm)
		named.append(pair.combat)
	named.append(map.default_music.calm)
	named.append(map.default_music.combat)
	for c: StringName in named:
		assert_true(bank.declares(c), "bank declares %s" % c)


func test_a_type_without_its_own_entry_falls_back_by_nature() -> void:
	var map: SoundMap = SoundMap.shared()
	assert_eq(map.for_unit(TestUnits.undead(&"newcomer")).type_id, &"_undead")
	assert_eq(map.for_unit(TestUnits.melee(&"newcomer")).type_id, &"_living")


func test_a_death_cue_the_bank_lacks_falls_back_by_nature() -> void:
	var map: SoundMap = SoundMap.shared()
	var bank: SoundBank = AudioFixtures.bank({&"death_villager": 1})
	var reaver: UnitType = TestUnits.melee(&"reaver")
	assert_eq(map.death_cue(reaver, bank), &"death_villager")


func test_a_groan_the_bank_lacks_falls_back_and_the_living_have_none() -> void:
	var map: SoundMap = SoundMap.shared()
	var bank: SoundBank = AudioFixtures.bank({&"groan_husk": 1})
	assert_eq(map.groan_cue(TestUnits.undead(&"drifter"), bank), &"groan_husk")
	assert_eq(map.groan_cue(TestUnits.melee(&"reaver"), bank), &"")


func test_shieldmen_split_between_two_voices_by_id() -> void:
	var map: SoundMap = SoundMap.shared()
	var shieldman: UnitType = null
	for t: UnitType in _catalog().types:
		if t.id == &"shieldman":
			shieldman = t
	var a: StringName = map.voice_for(_unit(shieldman, 4))
	var b: StringName = map.voice_for(_unit(shieldman, 5))
	assert_ne(a, &"")
	assert_ne(b, &"")
	assert_ne(a, b)


func test_a_type_with_no_voices_has_none() -> void:
	var map: SoundMap = SoundMap.shared()
	assert_eq(map.voice_for(_unit(TestUnits.undead(&"husk"), 3)), &"")


func test_any_map_without_music_plays_riverside() -> void:
	var map: SoundMap = SoundMap.shared()
	var pair: MusicPair = map.music_for(&"nowhere")
	assert_eq(pair.calm, &"music_riverside_calm")
	assert_eq(pair.combat, &"music_riverside_combat")
	assert_eq(map.music_for(&"riverside").calm, &"music_riverside_calm")
