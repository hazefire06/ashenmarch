extends GutTest
## Barks: who speaks, when, what they say, and that a voiced death line takes
## the place of the death cry. Text-only: no voice is needed for any bark.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const VOICES: Array[StringName] = [&"shieldman_old", &"shieldman_young"]
const TRIGGERS: Array[StringName] = [
	&"select", &"annoyed", &"move", &"attack", &"special", &"retreat", &"kill", &"death",
	&"hurt", &"status_burning", &"victory", &"formation_wedge", &"fizzle", &"heal_undead",
]


# Two lines per trigger for the Shieldman (voiced for a trigger in `voiced`).
func _book(voiced: Array[StringName] = []) -> BarkBook:
	var lines: Array[BarkLine] = []
	for trigger: StringName in TRIGGERS:
		for n: int in 2:
			var streams: Dictionary = {}
			if voiced.has(trigger):
				for voice: StringName in VOICES:
					streams[voice] = AudioFixtures.silent(1.0)
			lines.append(AudioFixtures.bark_line(
				StringName("shieldman_%s_%d" % [trigger, n]), &"shieldman", trigger,
				"%s %d" % [trigger, n], VOICES, streams
			))
	return AudioFixtures.bark_book(lines)


func _main(voiced: Array[StringName] = []) -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.skirmish_launch()
	add_child_autofree(main)
	var catalog: UnitCatalog = main.world.catalog
	var focus: Vector3 = main._camera.focus
	for i: int in 3:
		main.world.spawn_unit(
			catalog.index_of(&"shieldman"), LIGHT,
			roundi((focus.x + i * 2.0) * 1000.0), roundi(focus.z * 1000.0), 0, 1000
		)
	for i: int in 3:
		main.world.spawn_unit(
			catalog.index_of(&"husk"), DARK,
			roundi((focus.x + i * 2.0) * 1000.0), roundi((focus.z + 6.0) * 1000.0), 0, 1000
		)
	main._physics_process(1.0 / World.TICK_RATE)
	main._process(0.1)
	main._barks.book = _book(voiced)
	return main


func _ids(main: MainView, side: UnitType.Faction = LIGHT) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in main.world.units:
		if unit.faction == side and unit.is_alive():
			ids.append(unit.id)
	return ids


func _sprite(main: MainView, unit_id: int) -> UnitSprite:
	for s: UnitSprite in main._units_view.sprites():
		if s.unit_id == unit_id:
			return s
	return null


# Gives this step exactly these combat events and lets the barks read them.
func _step(main: MainView, events: Array[CombatEvent]) -> void:
	main.world.combat_events.clear()
	main.world.combat_events.append_array(events)
	main._barks.after_step()


func test_a_selection_barks_over_the_nearest_unit_to_the_focus() -> void:
	var main: MainView = _main()
	var ids: PackedInt32Array = _ids(main)
	# Farthest first, so order in the array is not what picks the speaker.
	main._barks.on_player_selected(PackedInt32Array([ids[2], ids[1], ids[0]]))
	var bark: Dictionary = main._barks.last_bark()
	assert_eq(bark["unit_id"], ids[0], "the unit at the focus speaks")
	var sprite: UnitSprite = _sprite(main, ids[0])
	assert_eq(sprite.notice_text(), bark["text"])
	assert_eq(sprite._notice.modulate, Barks.BARK_COLOR)


func test_a_text_bark_needs_no_voice() -> void:
	var main: MainView = _main()
	main._barks.on_player_selected(_ids(main))
	var bark: Dictionary = main._barks.last_bark()
	assert_false(bark["voiced"])
	assert_ne(_sprite(main, bark["unit_id"]).notice_text(), "")


func test_a_voiced_line_plays_on_the_voice_bus_and_a_disabled_one_does_not() -> void:
	var main: MainView = _main([&"select"])
	main._barks.on_player_selected(_ids(main))
	assert_true(main._barks.last_bark()["voiced"])
	var playing: int = 0
	for child: Node in main._barks.get_children():
		var player: AudioStreamPlayer3D = child as AudioStreamPlayer3D
		if player != null and player.playing:
			playing += 1
			assert_eq(player.bus, &"Voice")
	assert_eq(playing, 1)
	var quiet: MainView = _main([&"select"])
	quiet._barks.enabled = false
	quiet._barks.on_player_selected(_ids(quiet))
	assert_false(quiet._barks.last_bark()["voiced"], "no voice, but the text shows")
	assert_ne(_sprite(quiet, quiet._barks.last_bark()["unit_id"]).notice_text(), "")


func test_an_order_barks_once_per_squad_in_five_seconds() -> void:
	var main: MainView = _main()
	var barks: Barks = main._barks
	var ids: PackedInt32Array = _ids(main)
	barks.now = 0.0
	barks.on_order(ids, SelectionController.OrderKind.MOVE)
	var first: Dictionary = barks.last_bark()
	assert_eq(first["trigger"], &"move")
	barks.now = 3.0
	barks.on_order(ids, SelectionController.OrderKind.MOVE)
	assert_eq(barks.last_bark(), first, "the same ids again: only the tone")
	barks.now = 5.5
	barks.on_order(ids, SelectionController.OrderKind.MOVE)
	assert_ne(barks.last_bark(), first, "after five seconds it speaks again")
	barks.now = 20.0
	barks.on_order(ids, SelectionController.OrderKind.OTHER)
	assert_eq(barks.last_bark()["trigger"], &"move", "OTHER is silent")


func test_each_order_kind_has_its_trigger() -> void:
	var main: MainView = _main()
	var barks: Barks = main._barks
	var ids: PackedInt32Array = _ids(main)
	var kinds: Dictionary = {
		SelectionController.OrderKind.ATTACK: &"attack",
		SelectionController.OrderKind.RETREAT: &"retreat",
	}
	for kind: SelectionController.OrderKind in kinds:
		barks.now += 10.0
		barks.on_order(ids, kind)
		assert_eq(barks.last_bark()["trigger"], kinds[kind])


func test_the_kill_bark_comes_from_the_attacker_and_the_death_bark_from_the_target() -> void:
	var main: MainView = _main()
	var light: PackedInt32Array = _ids(main)
	var dark: PackedInt32Array = _ids(main, DARK)
	var husk: Unit = main.world.get_unit(dark[0])
	husk.kill()
	_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, light[0], dark[0])])
	assert_eq(main._barks.last_bark()["unit_id"], light[0])
	assert_eq(main._barks.last_bark()["trigger"], &"kill")
	main._barks.now += 10.0
	var victim: Unit = main.world.get_unit(light[1])
	victim.kill()
	_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, dark[1], light[1])])
	assert_eq(main._barks.last_bark()["unit_id"], light[1])
	assert_eq(main._barks.last_bark()["trigger"], &"death")


func test_a_kill_by_a_dead_or_missing_attacker_makes_no_bark() -> void:
	var main: MainView = _main()
	var light: PackedInt32Array = _ids(main)
	var dark: PackedInt32Array = _ids(main, DARK)
	main.world.get_unit(light[0]).kill()
	main.world.get_unit(dark[0]).kill()
	_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, light[0], dark[0])])
	assert_true(main._barks.last_bark().is_empty(), "a dead attacker")
	main.world.get_unit(dark[1]).kill()
	_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, 0, dark[1])])
	assert_true(main._barks.last_bark().is_empty(), "no attacker")
	_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, 99999, dark[1])])
	assert_true(main._barks.last_bark().is_empty(), "a missing attacker")


func test_the_hurt_bark_fires_below_35_percent_and_rearms_above_50() -> void:
	var main: MainView = _main()
	var barks: Barks = main._barks
	var unit: Unit = main.world.get_unit(_ids(main)[0])
	var max_hp: int = unit.type.max_hp
	var spoken: Array[int] = []
	for percent: int in [34, 40, 33, 51, 30]:
		# 51 is set a hit point over, so integer division cannot land on 50.
		unit.hp = max_hp * percent / 100 + (1 if percent == 51 else 0)
		# Past the side-wide gap, so only the 35/50 rule decides.
		barks.now += 10.0
		barks._last = {}
		barks.after_step()
		if barks.last_bark().get("trigger", &"") == &"hurt":
			spoken.append(percent)
	assert_eq(spoken, [34, 30] as Array[int], "exactly two hurt barks")


func test_a_burning_unit_says_its_status_line_once() -> void:
	var main: MainView = _main()
	var barks: Barks = main._barks
	var unit: Unit = main.world.get_unit(_ids(main)[0])
	unit.status_until[StatusEffects.Kind.BURNING] = main.world.tick + 300
	barks.after_step()
	var first: Dictionary = barks.last_bark()
	assert_eq(first["trigger"], &"status_burning")
	assert_eq(first["unit_id"], unit.id)
	barks.now += 10.0
	barks.after_step()
	assert_eq(barks.last_bark(), first, "still burning, nothing new to say")


func test_the_victory_bark_follows_won() -> void:
	var main: MainView = _main()
	main.world.mission_events.append(MissionEvent.new(MissionEvent.Kind.WON, -1))
	main._barks.after_step()
	assert_eq(main._barks.last_bark()["trigger"], &"victory")
	assert_eq(main._barks.last_bark()["unit_id"], _ids(main)[0], "the unit at the focus")


func test_barks_are_silent_when_the_viewer_is_dark() -> void:
	var main: MainView = _main()
	main._barks.set_viewer(DARK)
	main._barks.on_player_selected(_ids(main))
	main._barks.on_order(_ids(main), SelectionController.OrderKind.MOVE)
	main.world.mission_events.append(MissionEvent.new(MissionEvent.Kind.WON, -1))
	main._barks.after_step()
	assert_true(main._barks.last_bark().is_empty())
	var dark: PackedInt32Array = _ids(main, DARK)
	main._barks.on_player_selected(dark)
	assert_true(main._barks.last_bark().is_empty(), "the dark side has no barks either")


func test_many_steps_in_one_frame_give_at_most_one_bark() -> void:
	var main: MainView = _main()
	var light: PackedInt32Array = _ids(main)
	var dark: PackedInt32Array = _ids(main, DARK)
	var seen: Dictionary = {}
	for i: int in 3:
		main.world.get_unit(dark[i]).kill()
		_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, light[i], dark[i])])
		if not main._barks.last_bark().is_empty():
			seen[main._barks.last_bark()["unit_id"]] = true
	assert_eq(seen.size(), 1, "one speaker, one bark")
	assert_eq(_barks_showing(main), 1)


func _barks_showing(main: MainView) -> int:
	var n: int = 0
	for s: UnitSprite in main._units_view.sprites():
		if s.notice_text() != "":
			n += 1
	return n


func test_a_voiced_death_replaces_the_cry() -> void:
	for voiced: bool in [true, false]:
		var triggers: Array[StringName] = []
		if voiced:
			triggers.append(&"death")
		var main: MainView = _main(triggers)
		main._sfx.bank = AudioFixtures.bank({&"death_shieldman": 1})
		var light: PackedInt32Array = _ids(main)
		var dark: PackedInt32Array = _ids(main, DARK)
		main.world.get_unit(light[0]).kill()
		_step(main, [CombatEvent.new(CombatEvent.Kind.KILL, dark[0], light[0])])
		assert_eq(main._barks.voiced_death(light[0]), voiced)
		main._sfx.after_step()
		var cues: Array[StringName] = []
		for played: Dictionary in main._sfx.played_this_tick():
			cues.append(played["cue"])
		assert_eq(cues.has(&"death_shieldman"), not voiced, "voiced=%s" % voiced)


func test_formation_and_special_lines_follow_their_signals() -> void:
	var main: MainView = _main()
	var sel: SelectionController = main._selection
	var ids: PackedInt32Array = _ids(main)
	sel.selection.select(ids)
	main._barks.now = 0.0
	sel.formation_changed.emit(Formations.Kind.WEDGE)
	assert_eq(main._barks.last_bark()["trigger"], &"formation_wedge")
	main._barks.now = 10.0
	sel.order_given.emit(ids, SelectionController.OrderKind.SPECIAL)
	assert_eq(main._barks.last_bark()["trigger"], &"special")
	main._barks.now = 20.0
	sel.group_changed.emit(0)
	assert_eq(main._barks.last_bark()["trigger"], &"select", "a recalled group speaks as a selection")


func test_an_empty_selection_makes_no_bark() -> void:
	var main: MainView = _main()
	main._selection.player_selected.emit(PackedInt32Array())
	assert_true(main._barks.last_bark().is_empty())


func test_the_fourth_click_on_one_unit_is_annoyed() -> void:
	var main: MainView = _main()
	var barks: Barks = main._barks
	var one: PackedInt32Array = PackedInt32Array([_ids(main)[0]])
	var triggers: Array[StringName] = []
	for i: int in 4:
		barks.now = i * 1.0
		barks.on_player_selected(one)
		# The selection cooldown would swallow clicks 2 and 3; the fourth still counts.
		triggers.append(barks.last_bark()["trigger"])
	assert_eq(triggers[3], &"annoyed")
	assert_eq(triggers[0], &"select")
