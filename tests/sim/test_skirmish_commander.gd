extends GutTest
## SkirmishCommander, the AI's general in a skirmish: it takes the hill,
## stages out of reach when the enemy there is stronger and commits when it
## is stronger itself, holds each posture long enough not to flip, commits
## whatever the odds when time runs out, takes the flags one after another,
## goes to the centre in Body Count until it can attack, flanks with its
## raiders, keeps its archers behind its melee, and decides the same way in
## two identical worlds. Synthetic types with round costs on flat ground; the
## player's units are spawned by hand and stand where they are put.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const STAGE: SkirmishCommander.Posture = SkirmishCommander.Posture.STAGE
const COMMIT: SkirmishCommander.Posture = SkirmishCommander.Posture.COMMIT
const DEFEND: SkirmishCommander.Posture = SkirmishCommander.Posture.DEFEND

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const ARCHER: int = 1
const RAIDER: int = 2
const POST: int = 3
const TANK: int = 4

## Start A (the player's) and B (the AI's), and the flags: 0 the hill in the
## middle, 1 north-west, 2 south-east (nearest B).
const A: Vector2i = Vector2i(20, 80)
const B: Vector2i = Vector2i(140, 80)
const FLAGS: PackedInt32Array = [80 * M, 80 * M, 40 * M, 40 * M, 120 * M, 120 * M]
## Most posture changes a commander may make in 3000 ticks of a standoff it
## can't win.
const STANDOFF_SWITCH_BOUND: int = 6

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"grunt", {"cost": 10}),
		TestUnits.ranged(&"archer", {"cost": 15}),
		TestUnits.melee(&"raider", {"cost": 10, "move_speed": 3500, "preferred_target_roles": 6}),
		# The player's units: dummies that stand and don't fight back, one
		# cheap, one worth ten grunts.
		TestUnits.dummy(&"post", {"cost": 10}),
		TestUnits.dummy(&"tank", {"cost": 100}),
	])


## A skirmish world on flat ground with the AI's army (counts by type id) at
## start B on `ai_side`, its commander added, and the time limit in ticks.
func _world(mode: SkirmishRules.Mode, ai: Dictionary, ai_side: UnitType.Faction = DARK, limit: int = 100_000) -> World:
	var w: World = World.new(1, TestTerrains.flat(160, 160), _catalog)
	var m: SkirmishMap = SkirmishMap.new()
	m.spawns = PackedInt32Array([A.x * M, A.y * M, B.x * M, B.y * M])
	m.spawn_facing = PackedInt32Array([1, 0, -1, 0])
	m.flags = FLAGS
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = m
	var player_side: UnitType.Faction = LIGHT if ai_side == DARK else DARK
	var army: Army = Army.new(ai_side)
	for type_id: StringName in ai:
		army.set_count(type_id, ai[type_id])
	setup.armies = [Army.new(player_side), army]
	var script: MissionScript = MissionScript.new()
	var specs: Array[AiGroupSpec] = SkirmishSetup.ai_group_specs(setup, 1, 1, _catalog)
	script.groups.append_array(specs)
	assert_true(w.start_mission(script, SkirmishSetup.TIER))
	var rules: SkirmishRules = SkirmishRules.for_map(m, mode, 1, player_side)
	rules.time_limit_ticks = limit
	assert_true(w.start_skirmish(rules))
	var raiders: int = 1 if specs.size() > 1 else -1
	w.ai.commanders.append(SkirmishCommander.new(1, ai_side, 0, raiders, Vector2i(80 * M, 80 * M)))
	return w


## A unit of the player's at (x, z) m.
func _player(w: World, type_index: int, at: Vector2i, side: UnitType.Faction = LIGHT) -> Unit:
	return w.spawn_unit(type_index, side, at.x * M, at.y * M, 1, 0)


func _run(w: World, ticks: int) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for _t: int in ticks:
		w.step()
		for e: AiEvent in w.ai_events:
			if e.kind == AiEvent.Kind.COMMANDER:
				out.append(e)
	return out


func _commander(w: World) -> SkirmishCommander:
	return w.ai.commanders[0]


func _main(w: World) -> AiGroup:
	return w.ai.groups_of(0)[0]


func _postures(events: Array[AiEvent]) -> Array[int]:
	var out: Array[int] = []
	for e: AiEvent in events:
		if out.is_empty() or out[out.size() - 1] != e.value:
			out.append(e.value)
	return out


func _near(w: World, side: UnitType.Faction, x: int, z: int, radius: int) -> int:
	var n: int = 0
	for unit: Unit in w.units:
		if unit.is_alive() and unit.faction == side and FixedMath.length(unit.x - x * M, unit.z - z * M) <= radius:
			n += 1
	return n


# --- King of the Hill -------------------------------------------------------


func test_it_takes_an_unguarded_hill() -> void:
	var w: World = _world(KOTH, {&"grunt": 6})
	_player(w, POST, A)
	var events: Array[AiEvent] = _run(w, 1500)
	assert_eq(events[0].value, COMMIT, "nobody guards it: straight on")
	assert_eq(Vector2i(events[0].x, events[0].z), Vector2i(80 * M, 80 * M))
	assert_eq(w.skirmish.hill_holder, DARK)
	assert_gt(w.skirmish.hold_ticks[DARK], 0)


func test_it_stages_out_of_reach_when_the_hill_is_held_by_more() -> void:
	var w: World = _world(KOTH, {&"grunt": 6})
	for k: int in 3:
		_player(w, TANK, Vector2i(78 + 2 * k, 80))
	var events: Array[AiEvent] = _run(w, 1500)
	assert_eq(_postures(events), [STAGE] as Array[int], "never commits")
	var c: SkirmishCommander = _commander(w)
	assert_gte(FixedMath.length(c.stage_x - 80 * M, c.stage_z - 80 * M), SkirmishCommander.STAGE_MIN - 1000)
	assert_eq(_near(w, DARK, 80, 80, 20 * M), 0, "nobody walks onto the hill")
	assert_gt(c.stage_x, 80 * M, "the staging point is on its own side")


func test_it_commits_when_it_is_the_stronger() -> void:
	var w: World = _world(KOTH, {&"grunt": 8})
	_player(w, POST, Vector2i(80, 80))
	var events: Array[AiEvent] = _run(w, 1500)
	var postures: Array[int] = _postures(events)
	assert_eq(postures[0], STAGE, "a guarded hill is staged for first")
	assert_true(postures.has(COMMIT), "8 grunts against a post commit")
	var main: AiGroup = _main(w)
	assert_eq(Vector2i(main.anchor_x, main.anchor_z), Vector2i(80 * M, 80 * M))


func test_a_standoff_doesnt_flip_its_posture() -> void:
	# Even odds: strong enough to commit now and then, not to stay.
	var w: World = _world(KOTH, {&"grunt": 10})
	_player(w, TANK, Vector2i(80, 80))
	var events: Array[AiEvent] = _run(w, 3000)
	assert_lte(_postures(events).size() - 1, STANDOFF_SWITCH_BOUND)


func test_desperation_commits_whatever_the_odds() -> void:
	# 80 s on the clock: the last 60 s (more than a quarter) is desperate,
	# and the AI is behind (the player holds the hill).
	var w: World = _world(KOTH, {&"grunt": 4}, DARK, 80 * World.TICK_RATE)
	for k: int in 3:
		_player(w, TANK, Vector2i(78 + 2 * k, 80))
	var early: Array[AiEvent] = _run(w, 20 * World.TICK_RATE - 31)
	assert_eq(_postures(early), [STAGE] as Array[int])
	var late: Array[AiEvent] = _run(w, 3 * World.TICK_RATE)
	assert_eq(late[late.size() - 1].value, COMMIT)


func test_bleeding_where_it_stages_pulls_it_back_or_commits() -> void:
	var w: World = _world(KOTH, {&"grunt": 6})
	for k: int in 3:
		_player(w, TANK, Vector2i(78 + 2 * k, 80))
	_run(w, 300)
	var c: SkirmishCommander = _commander(w)
	assert_eq(c.posture, STAGE)
	var before: int = c.stage_back
	for unit: Unit in _main(w).living(w):
		unit.hp -= 10
	c.think(w)
	assert_eq(c.stage_back, before + SkirmishCommander.BLEED_BACK, "too weak to commit: further back")
	assert_eq(c.posture, STAGE)


# --- Capture the Flags ------------------------------------------------------


func test_it_takes_the_flags_one_after_another() -> void:
	var w: World = _world(CTF, {&"grunt": 6})
	_player(w, POST, A)
	var flags: Array[int] = []
	for e: AiEvent in _run(w, 4500):
		if flags.is_empty() or flags[flags.size() - 1] != e.unit_id - 1:
			flags.append(e.unit_id - 1)
	assert_eq(flags[0], 2, "the nearest flag first")
	assert_gt(flags.size(), 1, "then another")
	assert_eq(w.skirmish.flag_owner[2], DARK)
	assert_gte(w.skirmish.flags_owned(DARK), 2)


func test_with_every_flag_its_own_it_defends_the_one_nearest_the_enemy() -> void:
	var w: World = _world(CTF, {&"grunt": 6})
	_player(w, POST, Vector2i(40, 30))
	w.step()
	for i: int in 3:
		w.skirmish.flag_owner[i] = DARK
	_commander(w).think(w)
	assert_eq(_commander(w).objective_flag, 1, "the north-west flag, by the player's post")


# --- Body Count -------------------------------------------------------------


func test_body_count_goes_to_the_centre_until_it_can_attack() -> void:
	var weak: World = _world(BC, {&"grunt": 3})
	for k: int in 2:
		_player(weak, TANK, A + Vector2i(0, 2 * k))
	_run(weak, 31)
	assert_eq(Vector2i(_commander(weak).objective_x, _commander(weak).objective_z), Vector2i(80 * M, 80 * M))
	var strong: World = _world(BC, {&"grunt": 10})
	var post: Unit = _player(strong, POST, A)
	_run(strong, 31)
	assert_eq(Vector2i(_commander(strong).objective_x, _commander(strong).objective_z), Vector2i(post.x, post.z))


# --- Raiders and archers ----------------------------------------------------


func test_raiders_flank_when_it_commits_and_stay_otherwise() -> void:
	var w: World = _world(KOTH, {&"grunt": 6, &"raider": 3})
	assert_eq(w.ai.commanders[0].raider_spec, 1)
	_player(w, POST, A)
	_player(w, POST, A + Vector2i(0, 3))
	_run(w, 31)
	assert_eq(_commander(w).posture, COMMIT)
	assert_eq(w.ai.groups_of(1)[0].behavior, AiGroupSpec.Behavior.FLANK)
	var held: World = _world(KOTH, {&"grunt": 6, &"raider": 3})
	for k: int in 3:
		_player(held, TANK, Vector2i(78 + 2 * k, 80))
	_run(held, 31)
	assert_eq(_commander(held).posture, STAGE)
	assert_eq(held.ai.groups_of(1)[0].behavior, AiGroupSpec.Behavior.ADVANCE, "with the main group")


func test_the_raiders_take_over_when_the_main_group_is_gone() -> void:
	var w: World = _world(KOTH, {&"grunt": 2, &"raider": 3})
	_player(w, POST, A)
	w.step()
	for unit: Unit in _main(w).living(w):
		unit.kill()
	var events: Array[AiEvent] = _run(w, 90)
	var raiders: AiGroup = w.ai.groups_of(1)[0]
	assert_eq(events[events.size() - 1].group_id, raiders.id)
	assert_eq(raiders.behavior, AiGroupSpec.Behavior.ADVANCE)
	assert_eq(Vector2i(raiders.anchor_x, raiders.anchor_z), Vector2i(80 * M, 80 * M))


func test_its_archers_keep_behind_its_melee() -> void:
	var w: World = _world(KOTH, {&"grunt": 6, &"archer": 4})
	_player(w, POST, A)
	_run(w, 600)
	var main: AiGroup = _main(w)
	var melee: Array[Unit] = []
	var archers: Array[Unit] = []
	for unit: Unit in main.living(w):
		(archers if unit.type_index == ARCHER else melee).append(unit)
	var m: Vector2i = AiOrders.centroid(melee)
	var a: Vector2i = AiOrders.centroid(archers)
	# The hill is west of B, so "behind" is east: farther from the hill.
	assert_gt(FixedMath.length(a.x - 80 * M, a.y - 80 * M), FixedMath.length(m.x - 80 * M, m.y - 80 * M))


# --- Either side, and determinism -------------------------------------------


func test_it_drives_a_light_army_the_same_way() -> void:
	var w: World = _world(KOTH, {&"grunt": 6}, LIGHT)
	_player(w, POST, A, DARK)
	_run(w, 1500)
	assert_eq(w.skirmish.hill_holder, LIGHT)


func test_two_identical_worlds_command_identically() -> void:
	var logs: Array = []
	for k: int in 2:
		var w: World = _world(KOTH, {&"grunt": 8, &"archer": 2, &"raider": 2})
		_player(w, POST, Vector2i(80, 80))
		_player(w, POST, Vector2i(60, 70))
		var log: Array = []
		for e: AiEvent in _run(w, 1500):
			log.append(e.to_array())
		logs.append([log, w.state_hash()])
	assert_eq(logs[0], logs[1])


func test_strength_is_cost_by_health() -> void:
	var w: World = _world(KOTH, {&"grunt": 1})
	var post: Unit = _player(w, POST, A)
	var tank: Unit = _player(w, TANK, A + Vector2i(0, 3))
	assert_eq(SkirmishCommander.strength([post, tank] as Array[Unit]), 10_000 + 100_000)
	tank.hp = tank.type.max_hp / 2
	assert_eq(SkirmishCommander.strength([tank] as Array[Unit]), 50_000)
	tank.kill()
	assert_eq(SkirmishCommander.strength([tank] as Array[Unit]), 0)


func test_it_does_nothing_once_the_skirmish_is_decided() -> void:
	var w: World = _world(KOTH, {&"grunt": 2})
	var post: Unit = _player(w, POST, A)
	w.step()
	post.kill()
	w.step()
	assert_true(w.skirmish.is_decided())
	assert_eq(_run(w, 60).size(), 0)
