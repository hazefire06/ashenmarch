extends GutTest
## Music: the combat layer comes in when enough visible units fight and goes
## out when the fighting dies down, with hysteresis; both layers start together.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog = load("res://data/units/catalog.tres") as UnitCatalog


func _world(fill: String = ".") -> World:
	var rows: Array[String] = []
	for z: int in 100:
		rows.append(fill.repeat(100))
	return World.new(1, TestTerrains.from_ascii(rows), _catalog)


func _pair() -> MusicPair:
	var pair: MusicPair = MusicPair.new()
	pair.calm = &"music_riverside_calm"
	pair.combat = &"music_riverside_combat"
	return pair


func _bank() -> SoundBank:
	var bank: SoundBank = AudioFixtures.bank({&"music_riverside_calm": 1, &"music_riverside_combat": 1}, 3, 5.0)
	for cue: SoundCue in bank.cues:
		cue.loop = true
		cue.bus = &"Music"
		cue.playback = AudioServer.PLAYBACK_TYPE_STREAM
	return bank


func _music(world: World, bank: SoundBank = null) -> Music:
	var music: Music = Music.new()
	add_child_autofree(music)
	music.setup(world, _pair(), bank if bank != null else _bank())
	return music


func _fight(world: World, count: int, side: UnitType.Faction = LIGHT, state: Unit.State = Unit.State.ATTACKING) -> void:
	for i: int in count:
		var unit: Unit = world.spawn_unit(_catalog.index_of(&"shieldman"), side, (40 + i) * M, 50 * M, 0, 1000)
		unit.state = state


# Tim's second Riverside listen: the opening fight is two or three longbows shooting a Husk patrol down from
# range, and at 4 fighters the combat layer came in only when a sapper joined, 22 s after the first arrow.
func test_combat_comes_in_after_two_fighters_for_a_second_and_a_half() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 2, LIGHT, Unit.State.SHOOTING)
	music.after_step()
	music.advance(1.4)
	assert_false(music.in_combat(), "not yet")
	music.advance(0.2)
	assert_true(music.in_combat(), "1.6 s")
	music.advance(2.0)
	assert_almost_eq(music.levels(), Vector2(0, 1), Vector2(0.01, 0.01))


func test_one_fighter_never_brings_combat_in() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 1, LIGHT, Unit.State.SHOOTING)
	music.after_step()
	music.advance(60.0)
	assert_false(music.in_combat())
	assert_almost_eq(music.levels(), Vector2(1, 0), Vector2(0.01, 0.01))


func test_shooters_and_both_sides_count() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 1, LIGHT, Unit.State.SHOOTING)
	_fight(world, 1, DARK, Unit.State.ATTACKING)
	music.after_step()
	music.advance(1.6)
	assert_true(music.in_combat(), "a Light archer and a Dark swordsman")


func test_combat_goes_out_after_ten_quiet_seconds_with_a_six_second_fade() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 4)
	music.after_step()
	music.advance(4.0)
	assert_true(music.in_combat())
	world.units[0].state = Unit.State.IDLE
	world.units[1].state = Unit.State.IDLE
	world.units[2].state = Unit.State.IDLE
	music.after_step()
	music.advance(9.9)
	assert_true(music.in_combat(), "9.9 s is not long enough")
	music.advance(0.2)
	assert_false(music.in_combat(), "10.1 s")
	music.advance(6.0)
	assert_almost_eq(music.levels(), Vector2(1, 0), Vector2(0.01, 0.01))


func test_a_short_lull_keeps_combat() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 4)
	music.after_step()
	music.advance(4.0)
	for unit: Unit in world.units:
		unit.state = Unit.State.IDLE
	music.after_step()
	music.advance(5.0)
	for unit: Unit in world.units:
		unit.state = Unit.State.ATTACKING
	music.after_step()
	music.advance(20.0)
	assert_true(music.in_combat())
	assert_almost_eq(music.levels(), Vector2(0, 1), Vector2(0.01, 0.01))


func test_hidden_fighters_dont_count() -> void:
	var world: World = _world("3")
	var music: Music = _music(world)
	for i: int in 4:
		var husk: Unit = world.spawn_unit(_catalog.index_of(&"husk"), DARK, (40 + i) * M, 50 * M, 0, 1000)
		# Only ATTACKING surfaces a husk; a shooting one stays under.
		husk.state = Unit.State.SHOOTING
	music.after_step()
	music.advance(5.0)
	assert_false(music.in_combat(), "submerged husks are unseen by the Light side")
	music.set_viewer(DARK)
	music.advance(1.6)
	assert_true(music.in_combat(), "the Dark side sees its own")


func test_both_layers_are_asked_to_play_together_and_loop() -> void:
	var world: World = _world()
	var music: Music = _music(world)
	var calm: AudioStreamPlayer = music._calm
	var combat: AudioStreamPlayer = music._combat
	assert_true(calm.playing and combat.playing, "both started in setup")
	assert_eq(calm.bus, &"Music")
	assert_eq(combat.playback_type, AudioServer.PLAYBACK_TYPE_STREAM)
	music.advance(5.0)
	assert_true(calm.playing and combat.playing, "and neither stops when its level is zero")
	assert_eq(combat.volume_db, Music.SILENT_DB, "combat is silent while calm")


func test_with_no_music_in_the_bank_both_layers_stay_silent_and_warn_once() -> void:
	var world: World = _world()
	var empty: SoundBank = SoundBank.new()
	var music: Music = _music(world, empty)
	music.advance(1.0)
	assert_false(music._calm.playing)
	assert_false(music._combat.playing)
	assert_true(empty.warned().has(&"music_riverside_calm"))
	assert_true(empty.warned().has(&"music_riverside_combat"))


func test_a_paused_crossfade_holds_and_resumes() -> void:
	# Pause (P / menu / focus loss) stops the sim stepping but not this node's _process; it must hold the mix.
	var world: World = _world()
	var music: Music = _music(world)
	_fight(world, 4)
	music.after_step()
	music.advance(4.0)
	var held: Vector2 = music.levels()
	assert_almost_eq(held, Vector2(0, 1), Vector2(0.01, 0.01), "in combat")
	music.paused = true
	for unit: Unit in world.units:
		unit.state = Unit.State.IDLE
	music.after_step()
	for i: int in 200:
		music._process(0.1)
	assert_eq(music.levels(), held, "the mix is frozen while paused")
	music.paused = false
	# Resumed: 10 s with the fighting gone flips it out, then a 6 s fade back to calm.
	for i: int in 170:
		music._process(0.1)
	assert_almost_eq(music.levels(), Vector2(1, 0), Vector2(0.01, 0.01), "and moves again once unpaused")
