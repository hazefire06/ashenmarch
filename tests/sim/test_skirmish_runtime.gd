extends GutTest
## A skirmish's rules played out (SkirmishRuntime): Body Count, King of the
## Hill and Capture the Flags scoring, the time limit, elimination, the
## outcome from the player's side, and the freeze once decided. Dummies stand
## where they are put, so nothing moves or fights unless a test says so.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const HILL: Vector2i = Vector2i(10, 10)
## Three flags: 0 the hill, 1 and 2.
const FLAGS: PackedInt32Array = [10 * M, 10 * M, 30 * M, 30 * M, 50 * M, 50 * M]
const RADIUS: int = 3 * M
## Somewhere far from every flag.
const AWAY_LIGHT: Vector2i = Vector2i(5, 40)
const AWAY_DARK: Vector2i = Vector2i(55, 20)

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.dummy(&"walker"),
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true, "faction": DARK}),
	])


func _rules(mode: SkirmishRules.Mode, limit: int = 100_000, player: UnitType.Faction = LIGHT) -> SkirmishRules:
	var r: SkirmishRules = SkirmishRules.new()
	r.mode = mode
	r.time_limit_ticks = limit
	r.player_faction = player
	r.flags = FLAGS
	r.hill = 0
	r.flag_radius = RADIUS
	return r


func _world(rules: SkirmishRules, terrain: Terrain = null) -> World:
	var w: World = World.new(1, terrain if terrain != null else TestTerrains.flat(60, 60), _catalog)
	assert_true(w.start_mission(MissionScript.new(), 0))
	assert_true(w.start_skirmish(rules))
	return w


func _unit(w: World, side: UnitType.Faction, at: Vector2i, type_index: int = 0) -> Unit:
	return w.spawn_unit(type_index, side, at.x * M, at.y * M, 1, 0)


func _place(unit: Unit, at: Vector2i) -> void:
	unit.x = at.x * M
	unit.z = at.y * M


func _run(w: World, ticks: int) -> void:
	for _t: int in ticks:
		w.step()


func _flag(i: int) -> Vector2i:
	return Vector2i(FLAGS[2 * i] / M, FLAGS[2 * i + 1] / M)


# --- Starting ---------------------------------------------------------------


func test_start_refuses_what_it_cant_play() -> void:
	var bare: World = World.new(1)
	assert_false(bare.start_skirmish(_rules(BC)))
	assert_push_error("no terrain or unit catalog")
	var no_mission: World = World.new(1, TestTerrains.flat(20, 20), _catalog)
	assert_false(no_mission.start_skirmish(_rules(BC)))
	assert_push_error("there is no mission")
	var w: World = World.new(1, TestTerrains.flat(20, 20), _catalog)
	w.start_mission(MissionScript.new(), 0)
	assert_false(w.start_skirmish(null))
	assert_push_error("there are no rules")
	var bad: SkirmishRules = _rules(BC)
	bad.time_limit_ticks = 0
	assert_false(w.start_skirmish(bad))
	assert_push_error("time_limit_ticks must be positive")
	assert_true(w.start_skirmish(_rules(BC)))
	assert_false(w.start_skirmish(_rules(BC)))
	assert_push_error("already started")
	var stepped: World = World.new(1, TestTerrains.flat(20, 20), _catalog)
	stepped.start_mission(MissionScript.new(), 0)
	stepped.step()
	assert_false(stepped.start_skirmish(_rules(BC)))
	assert_push_error("already stepped")


func test_rules_validation_lists_every_problem() -> void:
	var r: SkirmishRules = SkirmishRules.new()
	r.capture_ticks = 0
	r.hill = 3
	r.set("mode", 7)
	r.set("player_faction", 5)
	var text: String = "\n".join(r.validate())
	for expected: String in [
		"mode 7 is not a Mode", "time_limit_ticks must be positive", "capture_ticks must be positive",
		"player_faction 5 is not a Faction", "flags must be one or more", "hill 3 is not a flag",
		"flag_radius must be positive",
	]:
		assert_string_contains(text, expected)


func test_for_map_copies_the_flags_and_sets_the_clock() -> void:
	var m: SkirmishMap = SkirmishMap.new()
	m.flags = FLAGS
	m.hill = 2
	m.flag_radius = 6000
	var r: SkirmishRules = SkirmishRules.for_map(m, CTF, 10, DARK)
	assert_eq(r.mode, CTF)
	assert_eq(r.time_limit_ticks, 10 * 60 * World.TICK_RATE)
	assert_eq(r.player_faction, DARK)
	assert_eq(r.flags, FLAGS)
	assert_eq(r.hill, 2)
	assert_eq(r.flag_radius, 6000)
	r.flags[0] = 1
	assert_eq(m.flags[0], FLAGS[0], "a copy")
	assert_eq(r.validate(), PackedStringArray())


func test_the_first_step_records_both_armies() -> void:
	var w: World = _world(_rules(BC))
	var a: Unit = _unit(w, LIGHT, AWAY_LIGHT)
	var b: Unit = _unit(w, LIGHT, AWAY_LIGHT + Vector2i(2, 0))
	var c: Unit = _unit(w, DARK, AWAY_DARK)
	w.step()
	assert_true(w.skirmish.started)
	assert_eq(w.skirmish.roster_ids[LIGHT], PackedInt32Array([a.id, b.id]))
	assert_eq(w.skirmish.roster_ids[DARK], PackedInt32Array([c.id]))
	assert_eq(w.skirmish.alive, PackedInt32Array([2, 1]))
	assert_eq(w.skirmish.deaths, PackedInt32Array([0, 0]))


# --- Body Count -------------------------------------------------------------


func test_body_count_scores_every_enemy_death_whatever_killed_it() -> void:
	var w: World = _world(_rules(BC))
	var light: Array[Unit] = [_unit(w, LIGHT, AWAY_LIGHT), _unit(w, LIGHT, AWAY_LIGHT + Vector2i(2, 0))]
	var dark: Array[Unit] = [_unit(w, DARK, AWAY_DARK), _unit(w, DARK, AWAY_DARK + Vector2i(0, 2))]
	w.step()
	# A Dark unit dying of nothing in particular (no credit) scores for Light.
	Damage.apply(w, dark[0], dark[0].hp, 0, 0, 0)
	w.step()
	assert_eq(w.skirmish.score(LIGHT), 1)
	assert_eq(w.skirmish.score(DARK), 0)
	# Light's own friendly fire scores for Dark.
	Damage.apply(w, light[0], light[0].hp, 0, 0, light[1].id)
	w.step()
	assert_eq(w.skirmish.score(DARK), 1)
	assert_eq(w.skirmish.deaths, PackedInt32Array([1, 1]))
	assert_eq(w.skirmish.alive, PackedInt32Array([1, 1]))


func test_a_unit_that_changes_side_counts_as_lost() -> void:
	var w: World = _world(_rules(BC))
	_unit(w, LIGHT, AWAY_LIGHT)
	var turned: Unit = _unit(w, LIGHT, AWAY_LIGHT + Vector2i(2, 0))
	_unit(w, DARK, AWAY_DARK)
	w.step()
	turned.faction = DARK
	w.step()
	assert_eq(w.skirmish.deaths[LIGHT], 1)
	assert_eq(w.skirmish.alive[DARK], 1, "it doesn't join the Dark roster")


# --- King of the Hill -------------------------------------------------------


func test_the_hill_scores_only_while_held_alone() -> void:
	var w: World = _world(_rules(KOTH))
	var l: Unit = _unit(w, LIGHT, HILL)
	var d: Unit = _unit(w, DARK, AWAY_DARK)
	_run(w, 10)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([10, 0]))
	assert_eq(w.skirmish.hill_holder, LIGHT)
	assert_eq(w.skirmish.score(LIGHT), 10)
	_place(d, HILL + Vector2i(2, 0))
	_run(w, 5)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([10, 0]), "contested scores nothing")
	assert_eq(w.skirmish.hill_holder, SkirmishRuntime.CONTESTED)
	_place(l, AWAY_LIGHT)
	_run(w, 4)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([10, 4]))
	_place(d, AWAY_DARK)
	_run(w, 3)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([10, 4]), "empty scores nothing")
	assert_eq(w.skirmish.hill_holder, SkirmishRuntime.NO_SIDE)


func test_the_radius_is_center_to_center_and_inclusive() -> void:
	var w: World = _world(_rules(KOTH))
	var l: Unit = _unit(w, LIGHT, AWAY_LIGHT)
	_unit(w, DARK, AWAY_DARK)
	l.x = HILL.x * M + RADIUS
	l.z = HILL.y * M
	w.step()
	assert_eq(w.skirmish.hold_ticks[LIGHT], 1, "on the edge counts")
	l.x += 1
	w.step()
	assert_eq(w.skirmish.hold_ticks[LIGHT], 1, "a millimetre out doesn't")


func test_a_submerged_unit_holds_and_contests_nothing() -> void:
	# The hill at (10, 10) is in deep water (depth 3) to the east of x = 10.
	var rows: Array[String] = []
	for j: int in 20:
		rows.append(".".repeat(11) + "3".repeat(9))
	var w: World = _world(_rules(KOTH), TestTerrains.from_ascii(rows))
	var lurker: Unit = _unit(w, DARK, HILL + Vector2i(2, 0), 1)
	var l: Unit = _unit(w, LIGHT, HILL + Vector2i(-2, 0))
	assert_true(Visibility.is_submerged(w.terrain, lurker))
	_run(w, 3)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([3, 0]), "the lurker doesn't contest")
	_place(l, Vector2i(2, 2))
	_run(w, 3)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([3, 0]), "nor hold")
	lurker.surfaced = true
	_run(w, 2)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([3, 2]), "once surfaced it does")


# --- Capture the Flags ------------------------------------------------------


func test_a_flag_is_captured_after_exactly_capture_ticks_alone() -> void:
	var w: World = _world(_rules(CTF))
	_unit(w, LIGHT, _flag(1))
	_unit(w, DARK, AWAY_DARK)
	_run(w, SkirmishRules.CAPTURE_TICKS - 1)
	assert_eq(w.skirmish.flag_owner[1], SkirmishRuntime.NO_SIDE)
	assert_eq(w.skirmish.flag_capture_side[1], LIGHT)
	assert_eq(w.skirmish.flag_progress[1], SkirmishRules.CAPTURE_TICKS - 1)
	w.step()
	assert_eq(w.skirmish.flag_owner[1], LIGHT)
	assert_eq(w.skirmish.flag_progress[1], 0)
	assert_eq(w.skirmish.score(LIGHT), 1)
	assert_eq(w.skirmish.owned_ticks[LIGHT], 1, "owned from the capturing tick")


func test_a_flag_stays_owned_when_its_side_leaves_and_flips_to_the_other() -> void:
	var w: World = _world(_rules(CTF))
	var l: Unit = _unit(w, LIGHT, _flag(2))
	var d: Unit = _unit(w, DARK, AWAY_DARK)
	_run(w, SkirmishRules.CAPTURE_TICKS)
	_place(l, AWAY_LIGHT)
	_run(w, 20)
	assert_eq(w.skirmish.flag_owner[2], LIGHT)
	assert_eq(w.skirmish.owned_ticks[LIGHT], 21)
	_place(d, _flag(2))
	_run(w, SkirmishRules.CAPTURE_TICKS)
	assert_eq(w.skirmish.flag_owner[2], DARK)
	assert_eq(w.skirmish.flags_owned(LIGHT), 0)
	assert_eq(w.skirmish.flags_owned(DARK), 1)


func test_progress_resets_when_who_stands_alone_changes() -> void:
	var w: World = _world(_rules(CTF))
	var l: Unit = _unit(w, LIGHT, AWAY_LIGHT)
	var d: Unit = _unit(w, DARK, _flag(1))
	_run(w, 100)
	assert_eq(w.skirmish.flag_progress[1], 100)
	_place(l, _flag(1))
	w.step()
	assert_eq(w.skirmish.flag_progress[1], 0, "contested")
	assert_eq(w.skirmish.flag_capture_side[1], SkirmishRuntime.NO_SIDE)
	_place(l, AWAY_LIGHT)
	_run(w, 10)
	assert_eq(w.skirmish.flag_progress[1], 10, "starts over")
	_place(d, AWAY_DARK)
	w.step()
	assert_eq(w.skirmish.flag_progress[1], 0, "and over again when it leaves")


func test_the_owner_standing_on_its_flag_makes_no_progress() -> void:
	var w: World = _world(_rules(CTF))
	_unit(w, LIGHT, _flag(1))
	_unit(w, DARK, AWAY_DARK)
	_run(w, SkirmishRules.CAPTURE_TICKS + 30)
	assert_eq(w.skirmish.flag_owner[1], LIGHT)
	assert_eq(w.skirmish.flag_progress[1], 0)
	assert_eq(w.skirmish.flag_capture_side[1], SkirmishRuntime.NO_SIDE)


func test_only_the_mode_being_played_is_scored() -> void:
	var w: World = _world(_rules(BC))
	_unit(w, LIGHT, HILL)
	_unit(w, DARK, _flag(1))
	_run(w, SkirmishRules.CAPTURE_TICKS + 5)
	assert_eq(w.skirmish.hold_ticks, PackedInt64Array([0, 0]))
	assert_eq(w.skirmish.flag_owner, PackedInt32Array([-1, -1, -1]))


# --- Endings ----------------------------------------------------------------


func test_the_time_limit_decides_by_score() -> void:
	var w: World = _world(_rules(KOTH, 50))
	_unit(w, LIGHT, HILL)
	_unit(w, DARK, AWAY_DARK)
	_run(w, 50)
	assert_false(w.skirmish.is_decided(), "the limit's tick hasn't been played yet")
	assert_eq(w.skirmish.ticks_left(w.tick), 0)
	w.step()
	assert_eq(w.skirmish.winner, LIGHT)
	assert_eq(w.skirmish.end_reason, SkirmishRuntime.EndReason.TIME)
	assert_eq(w.skirmish.end_tick, 50)
	assert_eq(w.skirmish.hold_ticks[LIGHT], 50, "the deciding tick isn't scored")
	assert_eq(w.mission.outcome, MissionRuntime.Outcome.WON)
	assert_eq(w.mission.outcome_tick, 50)


func test_level_at_the_limit_is_a_draw() -> void:
	var w: World = _world(_rules(BC, 20))
	_unit(w, LIGHT, AWAY_LIGHT)
	_unit(w, DARK, AWAY_DARK)
	_run(w, 21)
	assert_eq(w.skirmish.winner, SkirmishRuntime.DRAW)
	assert_eq(w.mission.outcome, MissionRuntime.Outcome.DRAW)
	var drawn: Array[MissionEvent] = w.mission_events.filter(func(e: MissionEvent) -> bool:
		return e.kind == MissionEvent.Kind.DRAWN)
	assert_eq(drawn.size(), 1)
	assert_eq(drawn[0].trigger_index, -1)


func test_capture_the_flags_breaks_a_tie_by_flag_ticks() -> void:
	var limit: int = SkirmishRules.CAPTURE_TICKS + 40
	var w: World = _world(_rules(CTF, limit))
	var l: Unit = _unit(w, LIGHT, _flag(1))
	var d: Unit = _unit(w, DARK, AWAY_DARK)
	_run(w, 20)
	# Dark starts 20 ticks later, so it owns its flag 20 ticks less.
	_place(d, _flag(2))
	_run(w, limit - 20 + 1)
	assert_eq(w.skirmish.flags_owned(LIGHT), 1)
	assert_eq(w.skirmish.flags_owned(DARK), 1)
	assert_gt(w.skirmish.owned_ticks[LIGHT], w.skirmish.owned_ticks[DARK])
	assert_eq(w.skirmish.winner, LIGHT)
	assert_true(is_instance_valid(l))


func test_elimination_ends_any_mode_at_once() -> void:
	for mode: SkirmishRules.Mode in [BC, KOTH, CTF]:
		var w: World = _world(_rules(mode))
		_unit(w, LIGHT, AWAY_LIGHT)
		var d: Unit = _unit(w, DARK, AWAY_DARK)
		_run(w, 5)
		d.kill()
		w.step()
		assert_eq(w.skirmish.winner, LIGHT, "mode %d" % mode)
		assert_eq(w.skirmish.end_reason, SkirmishRuntime.EndReason.ELIMINATION)
		assert_eq(w.skirmish.end_tick, 5)
		assert_eq(w.mission.outcome, MissionRuntime.Outcome.WON)


func test_both_wiped_out_on_one_tick_is_a_draw() -> void:
	var w: World = _world(_rules(BC))
	var l: Unit = _unit(w, LIGHT, AWAY_LIGHT)
	var d: Unit = _unit(w, DARK, AWAY_DARK)
	w.step()
	l.kill()
	d.kill()
	w.step()
	assert_eq(w.skirmish.winner, SkirmishRuntime.DRAW)
	assert_eq(w.skirmish.end_reason, SkirmishRuntime.EndReason.ELIMINATION)
	assert_eq(w.mission.outcome, MissionRuntime.Outcome.DRAW)


func test_the_outcome_is_the_players_point_of_view() -> void:
	for player: UnitType.Faction in [LIGHT, DARK]:
		var w: World = _world(_rules(BC, 100_000, player))
		_unit(w, LIGHT, AWAY_LIGHT)
		var d: Unit = _unit(w, DARK, AWAY_DARK)
		w.step()
		d.kill()
		w.step()
		assert_eq(w.skirmish.winner, LIGHT)
		var expected: MissionRuntime.Outcome = MissionRuntime.Outcome.WON if player == LIGHT else MissionRuntime.Outcome.LOST
		assert_eq(w.mission.outcome, expected, "player %d" % player)
		var kind: MissionEvent.Kind = MissionEvent.Kind.WON if player == LIGHT else MissionEvent.Kind.LOST
		assert_eq(w.mission_events.filter(func(e: MissionEvent) -> bool: return e.kind == kind).size(), 1)


func test_the_result_freezes_when_decided() -> void:
	var w: World = _world(_rules(BC))
	var light: Array[Unit] = [_unit(w, LIGHT, AWAY_LIGHT), _unit(w, LIGHT, AWAY_LIGHT + Vector2i(2, 0))]
	var d: Unit = _unit(w, DARK, AWAY_DARK)
	w.step()
	d.kill()
	w.step()
	assert_eq(w.skirmish.final_alive[LIGHT], PackedByteArray([1, 1]))
	assert_eq(w.skirmish.final_alive[DARK], PackedByteArray([0]))
	var before: String = str(w.skirmish.hash_fields())
	# The rest of the deciding tick, or any later one, may still kill.
	light[0].kill()
	_run(w, 3)
	assert_eq(str(w.skirmish.hash_fields()), before)
	assert_eq(w.skirmish.score(DARK), 0)
	assert_eq(w.skirmish.ticks_left(w.tick), w.skirmish.rules.time_limit_ticks - 1, "the clock stops too")


func test_conclude_refuses_a_second_outcome() -> void:
	var w: World = _world(_rules(BC))
	w.step()
	assert_false(w.mission.conclude(w, MissionRuntime.Outcome.NONE))
	assert_true(w.mission.conclude(w, MissionRuntime.Outcome.LOST))
	assert_false(w.mission.conclude(w, MissionRuntime.Outcome.WON))
	assert_eq(w.mission.outcome, MissionRuntime.Outcome.LOST)


# --- Hash -------------------------------------------------------------------


func test_the_skirmish_is_in_the_hash() -> void:
	var a: World = _world(_rules(KOTH))
	var b: World = _world(_rules(KOTH))
	var c: World = _world(_rules(CTF))
	for w: World in [a, b, c]:
		_unit(w, LIGHT, HILL)
		_unit(w, DARK, AWAY_DARK)
	_run(a, 5)
	_run(b, 5)
	_run(c, 5)
	assert_eq(a.state_hash(), b.state_hash())
	assert_ne(a.state_hash(), c.state_hash(), "the rules are hashed")
	_place(b.units[0], AWAY_LIGHT)
	b.step()
	a.step()
	assert_ne(a.state_hash(), b.state_hash(), "the score is hashed")
