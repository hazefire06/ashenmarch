extends GutTest
## The playtest harness (scripts/playtest.gd and scripts/playtest/): the pilots
## that play the Light side through sim commands, the runner that builds a
## world as the game does, and the tables. The properties that make the
## numbers worth reading are pinned: a pilot orders only soldiers the player
## would, a run is repeatable from its seed, and the pilot's rules (when a
## Sapper throws, a Warden heals, a Longbow shoots its fire arrow, where the
## charges go) do what the brief says. The long runs are the playtest's own
## job (`make playtest`); these are short.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
const TIER: int = 2
const SEED: int = 7
## Ticks of the short runs: enough for every pilot to have given its first
## orders and (on Old Mill, where the Sappers lay charges for their first 40
## seconds) for those to be laid.
const SHORT_TICKS: int = 300
const MILL_TICKS: int = 1500

var _campaign: CampaignDef
var _catalog: UnitCatalog
var _allowed: Array[GDScript] = []
# The one competent run of Old Mill's first minute, shared by the tests that read
# it (it is the slowest thing here).
var _mill: PlaytestRunner
var _mill_result: PlaytestResult


func before_all() -> void:
	_campaign = load(CAMPAIGN_PATH) as CampaignDef
	_catalog = TestTerrains.catalog()
	_allowed = [
		MoveUnitsCommand, AttackMoveCommand, GroundAttackCommand, UseSpecialCommand,
		HealCommand, StopUnitsCommand, InteractCommand,
	]
	# The route table reads the map generators' constants, which compiles them
	# (and the shared map builder, whose integer division GDScript warns about
	# once): done here so the warning isn't taken for the first test's.
	for mission: MissionDef in _campaign.missions:
		PlaytestRoutes.constants(mission.id)
	_mill = _runner()
	_mill_result = _play(_mill, 2, PlaytestPilot.Kind.COMPETENT, MILL_TICKS)


func after_all() -> void:
	_mill.release()


# ---- helpers ----

func _runner(record: bool = true) -> PlaytestRunner:
	var runner: PlaytestRunner = PlaytestRunner.new(_catalog, _campaign.soldier_names)
	runner.record_commands = record
	return runner


## Plays campaign mission `index` for `ticks` with `kind`, the way scripts/playtest.gd
## does.
func _play(
	runner: PlaytestRunner, index: int, kind: PlaytestPilot.Kind, ticks: int, campaign_seed: int = SEED
) -> PlaytestResult:
	var state: CampaignState = CampaignState.new_campaign(campaign_seed, TIER)
	return runner.play(_campaign.missions[index], index, state, kind, ticks)


## A mission of two Husks (idle until something comes) 15 m from a small squad,
## won when every Dark unit is dead. The smallest thing a pilot can win.
func _tiny_mission() -> MissionDef:
	var roster: Array[RosterEntry] = [
		CampaignFixtures.entry(&"shieldman", PackedInt32Array([3])),
		CampaignFixtures.entry(&"longbow", PackedInt32Array([1])),
	]
	var mission: MissionDef = CampaignFixtures.mission(&"tiny", roster)
	var husks: AiGroupSpec = MissionFixtures.group(&"husks", 2, 75, 60)
	var win: TriggerSpec = MissionFixtures.trigger(&"win", TriggerSpec.Condition.FACTION_ELIMINATED)
	win.faction = DARK
	win.actions.append(MissionFixtures.action(TriggerAction.Kind.WIN))
	var lose: TriggerSpec = MissionFixtures.player_eliminated(&"lose")
	lose.actions.append(MissionFixtures.action(TriggerAction.Kind.LOSE))
	var groups: Array[AiGroupSpec] = [husks]
	var triggers: Array[TriggerSpec] = [win, lose]
	mission.rules = MissionFixtures.script(groups, triggers)
	return mission


## A bare flat world of the shipped catalog, for a pilot's single decisions:
## units are spawned by hand, nothing steps unless a test says.
func _bare(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(120, 120), _catalog)


func _spawn(w: World, type_id: StringName, side: UnitType.Faction, x: int, z: int) -> Unit:
	return w.spawn_unit(_catalog.index_of(type_id), side, x * M, z * M, 1, 0)


## A pilot of the tiny mission's kind, recording, that has looked at `w` once.
func _think(w: World, kind: PlaytestPilot.Kind = PlaytestPilot.Kind.COMPETENT) -> PlaytestPilot:
	var pilot: PlaytestPilot = PlaytestPilot.new(kind, _tiny_mission())
	pilot.record = true
	pilot.think(w)
	return pilot


func _commands_of(pilot: PlaytestPilot, script: GDScript, unit_id: int) -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	for command: SimCommand in pilot.recorded:
		if command.get_script() == script and (command.get(&"unit_ids") as PackedInt32Array).has(unit_id):
			out.append(command)
	return out


## Flat ground with a patch of brush from (x0, z0) to (x1, z1) metres.
func _brushy(x0: int, z0: int, x1: int, z1: int) -> Terrain:
	var rows: Array[String] = []
	for j: int in 120:
		var row: String = ""
		for i: int in 120:
			row += "b" if i >= x0 and i <= x1 and j >= z0 and j <= z1 else "."
		rows.append(row)
	return TestTerrains.from_ascii(rows)


# ---- the pilot orders only what the player could ----

func test_the_pilot_orders_only_light_soldiers_the_ai_does_not_control() -> void:
	for index: int in _campaign.missions.size():
		for kind: PlaytestPilot.Kind in [PlaytestPilot.Kind.COMPETENT, PlaytestPilot.Kind.NAIVE]:
			var label: String = "%s %s" % [_campaign.missions[index].id, PlaytestPilot.kind_name(kind)]
			var runner: PlaytestRunner = _mill if index == 2 and kind == PlaytestPilot.Kind.COMPETENT else _runner()
			if runner != _mill:
				assert_not_null(_play(runner, index, kind, SHORT_TICKS), label)
			_assert_orders_are_the_players(runner, label)
			if runner != _mill:
				runner.release()


# Every command the pilot of this run gave names only Light units the AI does
# not control, and is one the player's input produces.
func _assert_orders_are_the_players(runner: PlaytestRunner, label: String) -> void:
	var world: World = runner.last_world
	var pilot: PlaytestPilot = runner.last_pilot
	assert_gt(pilot.recorded.size(), 0, "%s: the pilot gave orders" % label)
	assert_eq(pilot.recorded.size(), pilot.commands_issued, "%s: every command was kept" % label)
	var wards: int = 0
	for unit: Unit in world.units:
		if unit.faction == LIGHT and world.ai.controls(unit.id):
			wards += 1
	if label.begins_with("the_ford"):
		assert_eq(wards, 1, "%s: the villager is the AI's, and in the world" % label)
	for command: SimCommand in pilot.recorded:
		assert_true(_allowed.has(command.get_script()), "%s: %s is a player command" % [label, command.get_script().resource_path])
		var ids: PackedInt32Array = command.get(&"unit_ids")
		assert_gt(ids.size(), 0, "%s: a command names someone" % label)
		for id: int in ids:
			var unit: Unit = world.get_unit(id)
			assert_not_null(unit, "%s: unit %d exists" % [label, id])
			if unit == null:
				continue
			assert_eq(unit.faction, LIGHT, "%s: %s is on the player's side" % [label, unit.type.id])
			assert_false(world.ai.controls(id), "%s: %s #%d isn't the AI's" % [label, unit.type.id, id])


func test_every_route_point_is_ground_a_soldier_can_stand_on() -> void:
	for mission: MissionDef in _campaign.missions:
		var terrain: Terrain = Terrain.load_map(mission.map)
		var points: Array[Vector2] = PlaytestRoutes.route(mission)
		points.append_array(PlaytestRoutes.escort(mission))
		assert_gt(points.size(), 0, "%s has a route" % mission.id)
		for point: Vector2 in points:
			assert_true(
				terrain.is_passable(roundi(point.x * M), roundi(point.y * M), Terrain.Mobility.LIVING),
				"%s: route point %s is walkable" % [mission.id, point]
			)


func test_the_fords_escort_is_the_villagers_own_waypoints_and_its_route_is_ford_landing_gate() -> void:
	var mission: MissionDef = _campaign.missions[1]
	var villager: AiGroupSpec = mission.rules.groups[mission.rules.group_index(&"villager")]
	var escort: Array[Vector2] = PlaytestRoutes.escort(mission)
	assert_eq(escort.size() * 2, villager.waypoints.size())
	for k: int in escort.size():
		assert_eq(roundi(escort[k].x * M), villager.waypoints[2 * k])
		assert_eq(roundi(escort[k].y * M), villager.waypoints[2 * k + 1])
	var route: Array[Vector2] = PlaytestRoutes.route(mission)
	assert_eq(route.size(), 3, "the ford, the north landing, the gate")
	var crossing: TriggerSpec = mission.rules.triggers[mission.rules.trigger_index(&"crossing")]
	var north: TriggerSpec = mission.rules.triggers[mission.rules.trigger_index(&"north")]
	var home: TriggerSpec = mission.rules.triggers[mission.rules.trigger_index(&"home")]
	for k: int in 3:
		var area: PackedInt32Array = [crossing, north, home][k].area
		assert_eq(roundi(route[k].x * M), area[0], "point %d is the trigger's x" % k)
		assert_eq(roundi(route[k].y * M), area[1], "point %d is the trigger's z" % k)


func test_rivesides_route_is_read_from_its_rules_not_retyped() -> void:
	var mission: MissionDef = _campaign.missions[0]
	var route: Array[Vector2] = PlaytestRoutes.route(mission)
	var in_ford: TriggerSpec = mission.rules.triggers[mission.rules.trigger_index(&"in_ford")]
	assert_eq(roundi(route[0].x * M), in_ford.area[0])
	assert_eq(roundi(route[0].y * M), in_ford.area[1])
	for pair: Array in [[1, &"field_patrol_w"], [3, &"field_patrol_e"]]:
		var waypoints: PackedInt32Array = mission.rules.groups[mission.rules.group_index(pair[1])].waypoints
		var sum: Vector2 = Vector2.ZERO
		for k: int in range(0, waypoints.size() - 1, 2):
			sum += Vector2(waypoints[k], waypoints[k + 1])
		var centroid: Vector2 = sum / float(waypoints.size() >> 1) / float(M)
		assert_almost_eq(route[pair[0]].x, centroid.x, 0.001, "%s: x" % pair[1])
		assert_almost_eq(route[pair[0]].y, centroid.y, 0.001, "%s: z" % pair[1])


# ---- a run is repeatable from its seed ----

func test_a_tiny_run_ends_the_same_way_every_time_for_the_same_seed() -> void:
	var mission: MissionDef = _tiny_mission()
	var hashes: Array[String] = []
	for campaign_seed: int in [1, 2]:
		var first: PlaytestResult = _play_tiny(mission, campaign_seed)
		var again: PlaytestResult = _play_tiny(mission, campaign_seed)
		assert_eq(first.outcome, PlaytestResult.WON, "seed %d: the squad wins" % campaign_seed)
		assert_eq(again.outcome, first.outcome)
		assert_eq(again.end_tick, first.end_tick, "seed %d: the same outcome tick" % campaign_seed)
		assert_eq(again.state_hash, first.state_hash, "seed %d: the same world" % campaign_seed)
		assert_eq(again.commands, first.commands, "seed %d: the same orders" % campaign_seed)
		assert_eq(again.losses, first.losses)
		assert_eq(again.kills, first.kills)
		assert_gt(first.commands, 0)
		hashes.append(first.state_hash)
	assert_ne(hashes[0], hashes[1], "different seeds are different worlds")


func _play_tiny(mission: MissionDef, campaign_seed: int) -> PlaytestResult:
	var runner: PlaytestRunner = _runner(false)
	var state: CampaignState = CampaignState.new_campaign(campaign_seed, TIER)
	var result: PlaytestResult = runner.play(mission, 0, state, PlaytestPilot.Kind.COMPETENT, 3000)
	runner.release()
	return result


func test_a_run_uses_the_seed_the_app_would() -> void:
	var mission: MissionDef = _campaign.missions[0]
	var state: CampaignState = CampaignState.new_campaign(SEED, TIER)
	var runner: PlaytestRunner = _runner(false)
	var result: PlaytestResult = runner.play(mission, 0, state, PlaytestPilot.Kind.NAIVE, 30)
	assert_eq(result.campaign_seed, SEED)
	assert_eq(result.world_seed, state.mission_seed(0))
	assert_eq(result.roster, state.plan_deploy(mission, PackedInt32Array(), _campaign.soldier_names).size())
	assert_eq(result.outcome, PlaytestResult.TIMEOUT, "30 ticks decide nothing: a timeout")
	assert_eq(result.end_tick, 30)
	runner.release()


func test_a_won_run_can_be_applied_to_the_campaign_like_the_apps() -> void:
	var mission: MissionDef = _tiny_mission()
	var runner: PlaytestRunner = _runner(false)
	var state: CampaignState = CampaignState.new_campaign(SEED, TIER)
	var result: PlaytestResult = runner.play(mission, state.mission_index, state, PlaytestPilot.Kind.COMPETENT, 3000, true)
	assert_true(result.won())
	assert_true(result.chain)
	state.apply_victory(mission, runner.last_plan, runner.last_world, runner.last_stats)
	assert_eq(state.mission_index, 1, "the campaign moved on")
	assert_eq(state.soldiers.size() + state.fallen.size(), result.roster)
	assert_eq(state.fallen.size(), result.losses)
	runner.release()


# ---- Old Mill: the charges go on the ramps, early ----

func test_old_mills_sappers_lay_all_their_charges_on_the_ramps_within_forty_seconds() -> void:
	var world: World = _mill.last_world
	var result: PlaytestResult = _mill_result
	assert_gt(result.charges_done_tick, 0, "every Sapper laid his last charge")
	assert_lte(result.charges_done_tick, 40 * World.TICK_RATE, "in the first 40 seconds")
	var charges: int = 0
	var near: Array[int] = [0, 0]
	var ramps: Array[Dictionary] = PlaytestRoutes.mill_ramps()
	for p: Projectile in world.projectiles:
		if p.type.id != &"satchel":
			continue
		charges += 1
		var at: Vector2 = Vector2(p.x, p.z) / float(M)
		for r: int in 2:
			var line: Vector2 = Geometry2D.get_closest_point_to_segment(at, ramps[r]["top"], ramps[r]["foot"])
			if at.distance_to(line) <= 4.0:
				near[r] += 1
	var sappers: int = 0
	for unit: Unit in world.units:
		if unit.type.id == &"sapper":
			sappers += 1
			assert_eq(unit.special_left, 0, "a Sapper has none left")
	assert_eq(charges, sappers * PlaytestPilot.CHARGES_PER_SAPPER, "every charge is on the ground")
	assert_eq(near[0] + near[1], charges, "each one lies on a ramp")
	assert_gt(near[0], 0, "the north-west ramp has some")
	assert_gt(near[1], 0, "and the south-east one")


func test_a_stand_off_that_goes_quiet_for_a_minute_sends_the_melee_out_to_finish_it() -> void:
	# Old Mill with nothing coming but one idle Husk at the foot of the plateau's
	# west cliff: in sight, reachable, and not on the plateau, so a pilot that
	# only holds would wait for it forever.
	var mission: MissionDef = _campaign.missions[2].duplicate() as MissionDef
	var husks: AiGroupSpec = MissionFixtures.group(&"husks", 1, 130, 160)
	var groups: Array[AiGroupSpec] = [husks]
	var triggers: Array[TriggerSpec] = []
	mission.rules = MissionFixtures.script(groups, triggers)
	var runner: PlaytestRunner = _runner()
	var state: CampaignState = CampaignState.new_campaign(SEED, TIER)
	var result: PlaytestResult = runner.play(mission, 2, state, PlaytestPilot.Kind.COMPETENT, 2500)
	assert_eq(result.stall_breaks, 1, "the pilot went out once")
	var sortie: int = -1
	for command: SimCommand in runner.last_pilot.recorded:
		var march: AttackMoveCommand = command as AttackMoveCommand
		if march != null and Vector2(march.x, march.z).distance_to(Vector2(130.0 * M, 160.0 * M)) < 3.0 * M:
			sortie = command.tick
			break
	assert_gt(sortie, PlaytestPilot.STALL_TICKS, "it was ordered at the Husk, and not before the minute was up")
	runner.release()


# ---- the pilot's rules, one decision at a time ----

func test_a_sapper_throws_at_a_cluster_of_three_in_range() -> void:
	var w: World = _bare()
	var sapper: Unit = _spawn(w, &"sapper", LIGHT, 20, 20)
	_spawn(w, &"shieldman", LIGHT, 20, 26)
	for at: Vector2i in [Vector2i(35, 20), Vector2i(36, 21), Vector2i(35, 22)]:
		_spawn(w, &"husk", DARK, at.x, at.y)
	var throws: Array[SimCommand] = _commands_of(_think(w), GroundAttackCommand, sapper.id)
	assert_eq(throws.size(), 1, "one bombardment is ordered")
	var aim: GroundAttackCommand = throws[0] as GroundAttackCommand
	assert_almost_eq(float(aim.x) / M, 35.3, 1.0)
	assert_almost_eq(float(aim.z) / M, 21.0, 1.0)


func test_a_sapper_does_not_throw_at_fewer_than_three() -> void:
	var w: World = _bare()
	var sapper: Unit = _spawn(w, &"sapper", LIGHT, 20, 20)
	_spawn(w, &"husk", DARK, 35, 20)
	_spawn(w, &"husk", DARK, 36, 21)
	assert_eq(_commands_of(_think(w), GroundAttackCommand, sapper.id).size(), 0)


func test_a_sapper_does_not_throw_with_a_friend_within_six_meters_of_the_aim() -> void:
	var w: World = _bare()
	var sapper: Unit = _spawn(w, &"sapper", LIGHT, 20, 20)
	for at: Vector2i in [Vector2i(35, 20), Vector2i(36, 21), Vector2i(35, 22)]:
		_spawn(w, &"husk", DARK, at.x, at.y)
	# A Shieldman 5 m short of the cluster: inside six meters of its middle.
	_spawn(w, &"shieldman", LIGHT, 30, 21)
	assert_eq(_commands_of(_think(w), GroundAttackCommand, sapper.id).size(), 0)


func test_a_sapper_does_not_throw_out_of_range_or_at_a_cluster_in_the_water() -> void:
	var far: World = _bare()
	var sapper: Unit = _spawn(far, &"sapper", LIGHT, 10, 20)
	for at: Vector2i in [Vector2i(60, 20), Vector2i(61, 21), Vector2i(60, 22)]:
		_spawn(far, &"husk", DARK, at.x, at.y)
	assert_eq(_commands_of(_think(far), GroundAttackCommand, sapper.id).size(), 0, "50 m is out of a grenade's reach")
	var rows: Array[String] = []
	for j: int in 120:
		rows.append(".".repeat(30) + "1".repeat(20) + ".".repeat(70) if j >= 15 and j <= 25 else ".".repeat(120))
	var wet: World = _bare(TestTerrains.from_ascii(rows))
	var thrower: Unit = _spawn(wet, &"sapper", LIGHT, 20, 20)
	for at: Vector2i in [Vector2i(35, 20), Vector2i(36, 21), Vector2i(35, 22)]:
		_spawn(wet, &"husk", DARK, at.x, at.y)
	assert_eq(_commands_of(_think(wet), GroundAttackCommand, thrower.id).size(), 0, "a fuse goes out in water")


func test_a_warden_heals_the_most_hurt_friend_below_sixty_per_cent_within_fifteen_meters() -> void:
	var w: World = _bare()
	var warden: Unit = _spawn(w, &"warden", LIGHT, 20, 20)
	var hurt: Unit = _spawn(w, &"shieldman", LIGHT, 25, 20)
	hurt.hp = 30
	var worse_but_far: Unit = _spawn(w, &"shieldman", LIGHT, 60, 20)
	worse_but_far.hp = 20
	var scratched: Unit = _spawn(w, &"shieldman", LIGHT, 22, 20)
	scratched.hp = 65
	var heals: Array[SimCommand] = _commands_of(_think(w), HealCommand, warden.id)
	assert_eq(heals.size(), 1)
	assert_eq((heals[0] as HealCommand).target_id, hurt.id, "the one at 30 per cent, not 20 per cent out of reach")


func test_a_warden_leaves_everyone_at_sixty_per_cent_or_more_alone() -> void:
	var w: World = _bare()
	var warden: Unit = _spawn(w, &"warden", LIGHT, 20, 20)
	var fine: Unit = _spawn(w, &"shieldman", LIGHT, 24, 20)
	fine.hp = 60
	assert_eq(_commands_of(_think(w), HealCommand, warden.id).size(), 0)


func test_two_wardens_heal_two_different_friends() -> void:
	var w: World = _bare()
	var first: Unit = _spawn(w, &"warden", LIGHT, 20, 20)
	var second: Unit = _spawn(w, &"warden", LIGHT, 21, 20)
	var worst: Unit = _spawn(w, &"shieldman", LIGHT, 25, 20)
	worst.hp = 10
	var next: Unit = _spawn(w, &"shieldman", LIGHT, 26, 20)
	next.hp = 40
	var pilot: PlaytestPilot = _think(w)
	var a: Array[SimCommand] = _commands_of(pilot, HealCommand, first.id)
	var b: Array[SimCommand] = _commands_of(pilot, HealCommand, second.id)
	assert_eq(a.size(), 1, "the first Warden is sent")
	assert_eq(b.size(), 1, "and so is the second")
	if a.size() == 1 and b.size() == 1:
		assert_eq((a[0] as HealCommand).target_id, worst.id, "the lower id takes the worst hurt")
		assert_eq((b[0] as HealCommand).target_id, next.id, "and the other goes to the next")


func test_a_second_warden_is_not_sent_to_a_patient_the_first_is_already_walking_to() -> void:
	var w: World = _bare()
	var first: Unit = _spawn(w, &"warden", LIGHT, 20, 20)
	var second: Unit = _spawn(w, &"warden", LIGHT, 21, 20)
	var patient: Unit = _spawn(w, &"shieldman", LIGHT, 25, 20)
	patient.hp = 10
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, _tiny_mission())
	pilot.record = true
	pilot.think(w)
	assert_eq(_commands_of(pilot, HealCommand, first.id).size(), 1, "the first goes")
	assert_eq(_commands_of(pilot, HealCommand, second.id).size(), 0, "the second has no one else to go to")
	w.step()
	assert_eq(first.order, Unit.Order.INTERACT, "the first is on his way")
	pilot.think(w)
	assert_eq(_commands_of(pilot, HealCommand, second.id).size(), 0, "a think later he still isn't sent")


func test_a_longbow_nocks_its_fire_arrow_and_aims_it_at_a_cluster_on_brush() -> void:
	var w: World = _bare(_brushy(60, 15, 80, 25))
	var archer: Unit = _spawn(w, &"longbow", LIGHT, 35, 20)
	for at: Vector2i in [Vector2i(68, 20), Vector2i(70, 21), Vector2i(69, 22)]:
		_spawn(w, &"husk", DARK, at.x, at.y)
	var pilot: PlaytestPilot = _think(w)
	var nocks: Array[SimCommand] = _commands_of(pilot, UseSpecialCommand, archer.id)
	var shots: Array[SimCommand] = _commands_of(pilot, GroundAttackCommand, archer.id)
	assert_eq(nocks.size(), 1, "the arrow is nocked")
	assert_eq(shots.size(), 1, "and aimed")
	assert_lt(pilot.recorded.find(nocks[0]), pilot.recorded.find(shots[0]), "in that order")
	assert_almost_eq(float((shots[0] as GroundAttackCommand).x) / M, 69.0, 1.5)


func test_a_longbow_keeps_its_fire_arrow_for_brush_a_friend_or_a_charge_isnt_near() -> void:
	var bare: World = _bare(_brushy(0, 0, 0, 0))
	var archer: Unit = _spawn(bare, &"longbow", LIGHT, 35, 20)
	for at: Vector2i in [Vector2i(68, 20), Vector2i(70, 21), Vector2i(69, 22)]:
		_spawn(bare, &"husk", DARK, at.x, at.y)
	assert_eq(_commands_of(_think(bare), UseSpecialCommand, archer.id).size(), 0, "grass doesn't take it")
	var crowded: World = _bare(_brushy(60, 15, 80, 25))
	var shooter: Unit = _spawn(crowded, &"longbow", LIGHT, 35, 20)
	for at: Vector2i in [Vector2i(68, 20), Vector2i(70, 21), Vector2i(69, 22)]:
		_spawn(crowded, &"husk", DARK, at.x, at.y)
	_spawn(crowded, &"shieldman", LIGHT, 50, 20)
	assert_eq(_commands_of(_think(crowded), UseSpecialCommand, shooter.id).size(), 0, "a friend is in the line of fire")
	var mined: World = _bare(_brushy(60, 15, 80, 25))
	var third: Unit = _spawn(mined, &"longbow", LIGHT, 35, 20)
	for at: Vector2i in [Vector2i(68, 20), Vector2i(70, 21), Vector2i(69, 22)]:
		_spawn(mined, &"husk", DARK, at.x, at.y)
	mined.drop_object(_catalog.projectile_index_of(&"satchel"), 62 * M, 20 * M, 0)
	assert_eq(_commands_of(_think(mined), UseSpecialCommand, third.id).size(), 0, "a charge lies near the aim")


func test_the_pilot_does_not_chase_husks_lying_submerged() -> void:
	var rows: Array[String] = []
	for j: int in 120:
		rows.append(".".repeat(35) + "4".repeat(15) + ".".repeat(70))
	var w: World = _bare(TestTerrains.from_ascii(rows))
	var soldier: Unit = _spawn(w, &"shieldman", LIGHT, 20, 20)
	var husk: Unit = _spawn(w, &"husk", DARK, 40, 20)
	assert_true(Visibility.is_submerged(w.terrain, husk), "it lies in deep water")
	var pilot: PlaytestPilot = _think(w)
	var marches: Array[SimCommand] = _commands_of(pilot, AttackMoveCommand, soldier.id)
	assert_eq(marches.size(), 1)
	# Nothing in sight: it goes to the route's point (the deploy point, 60 m
	# east and 40 south), not to the Husk 20 m away.
	assert_almost_eq(float((marches[0] as AttackMoveCommand).x) / M, 60.0, 1.0)
	husk.surfaced = true
	var seen: PlaytestPilot = _think(w)
	var chase: AttackMoveCommand = _commands_of(seen, AttackMoveCommand, soldier.id)[0] as AttackMoveCommand
	assert_almost_eq(float(chase.x) / M, 40.0, 1.0, "once it has sprung, it is fought")


func test_the_naive_pilot_only_attack_moves_everyone_and_nothing_else() -> void:
	var w: World = _bare()
	_spawn(w, &"sapper", LIGHT, 20, 20)
	_spawn(w, &"warden", LIGHT, 21, 20).hp = 5
	_spawn(w, &"longbow", LIGHT, 22, 20)
	for at: Vector2i in [Vector2i(35, 20), Vector2i(36, 21), Vector2i(35, 22)]:
		_spawn(w, &"husk", DARK, at.x, at.y)
	var pilot: PlaytestPilot = _think(w, PlaytestPilot.Kind.NAIVE)
	assert_eq(pilot.recorded.size(), 1)
	assert_eq(pilot.recorded[0].get_script(), AttackMoveCommand)
	assert_eq((pilot.recorded[0].get(&"unit_ids") as PackedInt32Array).size(), 3)


func test_the_naive_pilot_hunts_the_nearest_visible_enemy_once_the_route_is_done() -> void:
	# The tiny mission's route is its deploy point, (60, 60) m.
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 58, 58)
	var husk: Unit = _spawn(w, &"husk", DARK, 100, 60)
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.NAIVE, _tiny_mission())
	pilot.record = true
	pilot.think(w)
	assert_true(pilot.route_done, "he is at the last point of the route")
	var march: AttackMoveCommand = pilot.recorded[0] as AttackMoveCommand
	assert_almost_eq(float(march.x) / M, 100.0, 1.0, "and goes for the Husk, 40 m off")
	# The Husk moves 10 m: the next think follows it.
	husk.x += 10 * M
	w.step()
	pilot.think(w)
	assert_eq(pilot.recorded.size(), 2, "the order is repeated for the new spot")
	assert_almost_eq(float((pilot.recorded[1] as AttackMoveCommand).x) / M, 110.0, 1.0)
	# With nothing in sight he stands where he is.
	husk.kill()
	w.step()
	pilot.think(w)
	assert_eq(pilot.recorded.size(), 2, "no enemy, no order")


func test_the_naive_pilot_does_not_hunt_before_the_route_is_done() -> void:
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 20, 20)
	_spawn(w, &"husk", DARK, 40, 20)
	var pilot: PlaytestPilot = _think(w, PlaytestPilot.Kind.NAIVE)
	assert_false(pilot.route_done)
	assert_almost_eq(float((pilot.recorded[0] as AttackMoveCommand).x) / M, 60.0, 1.0, "he marches for the route point")


func test_the_naive_pilot_walks_everyone_back_to_a_villager_left_25_meters_behind() -> void:
	var ford: MissionDef = _campaign.missions[1]
	for gap: int in [30, 10]:
		var w: World = _bare(TestTerrains.flat(250, 250))
		var spec: AiGroupSpec = AiGroupSpec.new()
		spec.name = &"villager"
		spec.faction = LIGHT
		spec.units.append(MissionFixtures.entry(&"villager", PackedInt32Array([1])))
		spec.spawns = PackedInt32Array([80 * M, 20 * M])
		w.ai.spawn_group(w, spec, 0, 2)
		_spawn(w, &"shieldman", LIGHT, 80 - gap, 20)
		var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.NAIVE, ford)
		pilot.record = true
		pilot.think(w)
		var march: AttackMoveCommand = pilot.recorded[0] as AttackMoveCommand
		if gap > 25:
			assert_almost_eq(float(march.x) / M, 80.0, 1.0, "30 m behind him: back to the villager")
			assert_almost_eq(float(march.z) / M, 20.0, 1.0)
		else:
			assert_gt(float(march.x) / M, 150.0, "10 m from him: on with the route (the ford is at x = 192)")


func test_a_naive_run_of_the_ford_follows_the_ford_the_landing_and_the_gate() -> void:
	var runner: PlaytestRunner = _runner()
	assert_not_null(_play(runner, 1, PlaytestPilot.Kind.NAIVE, 90))
	var route: Array[Vector2] = PlaytestRoutes.route(_campaign.missions[1])
	var march: AttackMoveCommand = runner.last_pilot.recorded[0] as AttackMoveCommand
	assert_almost_eq(float(march.x) / M, route[0].x, 1.0, "the first leg is the ford")
	assert_almost_eq(float(march.z) / M, route[0].y, 1.0)
	runner.release()


func test_orders_are_not_repeated_until_the_goal_moves() -> void:
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 20, 20)
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, _tiny_mission())
	pilot.record = true
	pilot.think(w)
	var first: int = pilot.commands_issued
	assert_gt(first, 0)
	w.step()
	pilot.think(w)
	assert_eq(pilot.commands_issued, first, "the same goal gives no new order")


# ---- Old Mill: the melee holds the heads and stays out of the charge field ----

# Plays the first second of Old Mill with one idle Husk standing `along` m down
# the north-west ramp from its top and `across` m off its axis, and returns the
# melee soldiers' attack-move targets (meters) with the ramps' heads.
func _melee_targets_with_a_husk_on_the_ramp(along: float, across: float) -> Array[Vector2]:
	var ramp: Dictionary = PlaytestRoutes.mill_ramps()[0]
	var top: Vector2 = ramp["top"]
	var down: Vector2 = (Vector2(ramp["foot"]) - top).normalized()
	var husk_at: Vector2 = top + down * along + Vector2(-down.y, down.x) * across
	var mission: MissionDef = _campaign.missions[2].duplicate() as MissionDef
	var groups: Array[AiGroupSpec] = [MissionFixtures.group(&"husks", 1, roundi(husk_at.x), roundi(husk_at.y))]
	var triggers: Array[TriggerSpec] = []
	mission.rules = MissionFixtures.script(groups, triggers)
	var runner: PlaytestRunner = _runner()
	var state: CampaignState = CampaignState.new_campaign(SEED, TIER)
	assert_not_null(runner.play(mission, 2, state, PlaytestPilot.Kind.COMPETENT, 20))
	var targets: Array[Vector2] = []
	for command: SimCommand in runner.last_pilot.recorded:
		var march: AttackMoveCommand = command as AttackMoveCommand
		if march == null:
			continue
		var first: Unit = runner.last_world.get_unit(march.unit_ids[0])
		if first.type.id == &"shieldman" or first.type.id == &"reaver":
			targets.append(Vector2(march.x, march.z) / float(M))
	runner.release()
	return targets


func test_the_melee_does_not_go_out_to_an_enemy_in_the_charge_field() -> void:
	var center: Vector2 = PlaytestRoutes.mill_center()
	var heads: Array[Vector2] = []
	for ramp: Dictionary in PlaytestRoutes.mill_ramps():
		var top: Vector2 = ramp["top"]
		heads.append(top + (center - top).normalized() * PlaytestPilot.HEAD_INSET_M)
	# On the first pair of charges (9 m down, 2 m off the axis) and a little short
	# of them (7 m down, where a soldier's 5 m blast would reach the charges).
	for along: float in [PlaytestPilot.CHARGE_FIRST_M, PlaytestPilot.CHARGE_FIRST_M - PlaytestPilot.CHARGE_SIDE_M]:
		var targets: Array[Vector2] = _melee_targets_with_a_husk_on_the_ramp(along, PlaytestPilot.CHARGE_SIDE_M)
		assert_gt(targets.size(), 0, "%.0f m down: the melee was ordered" % along)
		for target: Vector2 in targets:
			var nearest_head: float = minf(target.distance_to(heads[0]), target.distance_to(heads[1]))
			assert_lt(nearest_head, 2.0, "%.0f m down: they hold a head, %s is not one" % [along, target])


func test_the_melee_does_go_out_to_an_enemy_at_the_head_of_a_ramp() -> void:
	var ramp: Dictionary = PlaytestRoutes.mill_ramps()[0]
	var top: Vector2 = ramp["top"]
	var down: Vector2 = (Vector2(ramp["foot"]) - top).normalized()
	var husk_at: Vector2 = top + down * 2.0
	var targets: Array[Vector2] = _melee_targets_with_a_husk_on_the_ramp(2.0, 0.0)
	var close: int = 0
	for target: Vector2 in targets:
		if target.distance_to(husk_at) < 2.0:
			close += 1
	assert_gt(close, 0, "2 m down the ramp, he is fought")


func test_the_charge_field_starts_beyond_the_head_zone_with_room_for_a_blast() -> void:
	# The geometry the two tests above lean on: the zone stops short of the first
	# charges by more than a soldier's width and the satchels' 5 m blast.
	assert_lt(PlaytestPilot.RAMP_HEAD_DEPTH_M, PlaytestPilot.CHARGE_FIRST_M - PlaytestPilot.CHARGE_SIDE_M)
	assert_lte(PlaytestPilot.RAMP_HEAD_DEPTH_M + 5.0, PlaytestPilot.CHARGE_FIRST_M)


func test_a_husk_lying_submerged_changing_hit_points_is_not_news_to_the_pilot() -> void:
	var rows: Array[String] = []
	for j: int in 120:
		rows.append(".".repeat(40) + "4".repeat(30) + ".".repeat(50))
	var w: World = _bare(TestTerrains.from_ascii(rows))
	_spawn(w, &"shieldman", LIGHT, 20, 20)
	var lurker: Unit = _spawn(w, &"husk", DARK, 50, 20)
	_spawn(w, &"husk", DARK, 100, 100)
	assert_true(Visibility.is_submerged(w.terrain, lurker))
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, _tiny_mission())
	pilot.think(w)
	for _t: int in 5:
		w.step()
	lurker.hp = 40
	pilot.think(w)
	assert_eq(pilot._last_change_tick, 0, "nothing visible changed, so the fight is no less quiet")


# ---- the results and their tables ----

func _result(
	mission_id: StringName, outcome: String, minutes: float, losses: int, roster: int = 10, pilot: String = "competent",
	tier: int = 2
) -> PlaytestResult:
	var r: PlaytestResult = PlaytestResult.new()
	r.mission_id = mission_id
	r.outcome = outcome
	r.end_tick = roundi(minutes * 60.0 * World.TICK_RATE)
	r.losses = losses
	r.roster = roster
	r.pilot = pilot
	r.tier = tier
	return r


func test_the_median_and_percentile_use_the_nearest_rank() -> void:
	var values: Array[float] = [5.0, 1.0, 3.0, 2.0, 4.0, 10.0, 9.0, 8.0, 7.0, 6.0]
	assert_almost_eq(PlaytestReport.median(values), 5.5, 0.001)
	assert_almost_eq(PlaytestReport.percentile(values, 90.0), 9.0, 0.001)
	assert_almost_eq(PlaytestReport.percentile(values, 100.0), 10.0, 0.001)
	assert_almost_eq(PlaytestReport.percentile(values, 0.0), 1.0, 0.001)
	var odd: Array[float] = [3.0, 1.0, 2.0]
	assert_almost_eq(PlaytestReport.median(odd), 2.0, 0.001)
	var none: Array[float] = []
	assert_eq(PlaytestReport.median(none), 0.0)
	assert_eq(PlaytestReport.percentile(none, 90.0), 0.0)


func test_the_table_counts_wins_losses_and_timeouts_per_group() -> void:
	var results: Array[PlaytestResult] = [
		_result(&"old_mill", PlaytestResult.WON, 8.0, 2, 20),
		_result(&"old_mill", PlaytestResult.LOST, 5.0, 20, 20),
		_result(&"old_mill", PlaytestResult.TIMEOUT, 25.0, 1, 20),
		_result(&"old_mill", PlaytestResult.WON, 10.0, 4, 20),
		_result(&"riverside", PlaytestResult.WON, 2.0, 0, 14, "naive", 0),
	]
	var text: String = PlaytestReport.markdown(results, "T")
	var rows: PackedStringArray = text.split("\n")
	var mill: String = ""
	var river: String = ""
	for row: String in rows:
		if row.begins_with("| old_mill | 2 | competent"):
			mill = row
		if row.begins_with("| riverside | 0 | naive"):
			river = row
	assert_ne(mill, "", "an Old Mill row")
	assert_string_contains(mill, "| 4 | 50% | 25% | 25% |", "two of four won, one lost, one timed out")
	assert_string_contains(river, "| 1 | 100% | 0% | 0% |")
	assert_lt(text.find("| riverside |"), text.find("| old_mill |"), "the campaign's order, not the order of arrival")
	assert_string_contains(text, "1 of 4 timed out", "the anomalies name the timeout")


func test_a_timeout_names_the_wave_still_standing_not_the_last_to_spawn() -> void:
	var stale: PlaytestResult = _result(&"old_mill", PlaytestResult.TIMEOUT, 25.0, 3, 20)
	stale.waves = PackedStringArray(["rippers", "bags", "drifters", "storm"])
	stale.waves_spawned = 4
	stale.alive_groups = PackedStringArray(["drifters"])
	var results: Array[PlaytestResult] = [stale]
	var text: String = PlaytestReport.markdown(results, "T")
	assert_string_contains(text, "timeout with drifters left 1")
	assert_eq(text.find("timeout in wave 4"), -1, "and not wave 4 (storm)")


func test_the_table_gives_the_median_minutes_of_wins_alone() -> void:
	var results: Array[PlaytestResult] = [
		_result(&"riverside", PlaytestResult.WON, 2.0, 0, 14),
		_result(&"riverside", PlaytestResult.WON, 4.0, 0, 14),
		_result(&"riverside", PlaytestResult.LOST, 20.0, 14, 14),
	]
	var text: String = PlaytestReport.markdown(results, "T")
	assert_string_contains(text, "| 3 | 67% | 33% | 0% | 4.0 | 20.0 | 3.0 |", "all runs' median 4.0, p90 20.0, the wins' median 3.0")


func test_the_fords_and_old_mills_tables_say_what_went_wrong() -> void:
	var ford: PlaytestResult = _result(&"the_ford", PlaytestResult.LOST, 1.5, 6, 16)
	ford.villager_died = true
	ford.villager_killer = "drifter"
	var ok: PlaytestResult = _result(&"the_ford", PlaytestResult.WON, 2.0, 0, 16)
	var mill: PlaytestResult = _result(&"old_mill", PlaytestResult.LOST, 6.0, 20, 20)
	mill.waves = PackedStringArray(["husks", "rippers", "bags", "storm"])
	mill.waves_spawned = 3
	var results: Array[PlaytestResult] = [ford, ok, mill]
	var text: String = PlaytestReport.markdown(results, "T")
	assert_string_contains(text, "| 2 | competent | 2 | 50% | drifter 1 | 100 / 100 |")
	assert_string_contains(text, "bags 1, husks 1, rippers 1, storm 1")
	assert_string_contains(text, "lost in wave 3 (bags) 1")


func test_a_chained_campaign_is_tabled_by_how_far_it_got() -> void:
	var results: Array[PlaytestResult] = []
	for mission_id: StringName in [&"riverside", &"the_ford", &"old_mill"]:
		var r: PlaytestResult = _result(mission_id, PlaytestResult.WON, 3.0, 1)
		r.chain = true
		results.append(r)
	var stopped: PlaytestResult = _result(&"riverside", PlaytestResult.LOST, 3.0, 14, 14)
	stopped.chain = true
	results.append(stopped)
	var text: String = PlaytestReport.markdown(results, "T")
	assert_string_contains(text, "| 2 | competent | 2 | 1 | 1 / 1 | 1 / 1 | 50% |")


func test_a_result_survives_the_trip_through_json() -> void:
	var r: PlaytestResult = _result(&"old_mill", PlaytestResult.LOST, 6.5, 12, 20)
	r.world_seed = 5392023410520822974
	r.campaign_seed = 1002
	r.waves = PackedStringArray(["husks", "bags"])
	r.waves_spawned = 2
	r.notes = PackedStringArray(["left: husk #4 at (1, 2) m"])
	r.state_hash = "abcd"
	var back: PlaytestResult = PlaytestResult.from_dict(JSON.parse_string(JSON.stringify(r.to_dict())))
	assert_not_null(back)
	assert_eq(back.world_seed, r.world_seed, "a 63-bit seed survives JSON")
	assert_eq(back.mission_id, r.mission_id)
	assert_eq(back.end_tick, r.end_tick)
	assert_eq(back.waves, r.waves)
	assert_eq(back.notes, r.notes)
	assert_eq(back.state_hash, "abcd")
	assert_null(PlaytestResult.from_dict({"mission": "x"}), "an incomplete line isn't a run")
	assert_null(PlaytestResult.from_dict("nonsense"))


# ---- a pilot with no mission (a skirmish) ----

## A pilot with no mission, told to march `points` (metres) and hold or hunt at the end.
func _free_pilot(
	kind: PlaytestPilot.Kind, points: Array[Vector2i], hold: bool
) -> PlaytestPilot:
	var pilot: PlaytestPilot = PlaytestPilot.new(kind)
	pilot.record = true
	var milli: Array[Vector2i] = []
	for point: Vector2i in points:
		milli.append(point * M)
	pilot.set_route(milli, hold)
	return pilot


func _last_march_x(pilot: PlaytestPilot) -> float:
	var march: AttackMoveCommand = pilot.recorded[pilot.recorded.size() - 1] as AttackMoveCommand
	return float(march.x) / M


func test_a_pilot_with_no_mission_marches_its_route_in_order() -> void:
	var w: World = _bare()
	var soldier: Unit = _spawn(w, &"shieldman", LIGHT, 10, 20)
	var pilot: PlaytestPilot = _free_pilot(
		PlaytestPilot.Kind.COMPETENT, [Vector2i(50, 20), Vector2i(90, 60)], true
	)
	pilot.think(w)
	assert_almost_eq(_last_march_x(pilot), 50.0, 1.0, "first to the first point")
	assert_eq(pilot.route_index, 0)
	soldier.x = 45 * M
	soldier.z = 20 * M
	w.step()
	pilot.think(w)
	assert_eq(pilot.route_index, 1, "within ARRIVED_M of it, on to the next")
	assert_false(pilot.route_done)
	assert_almost_eq(_last_march_x(pilot), 90.0, 1.0)


func test_a_pilot_with_no_mission_never_plays_the_ford_or_old_mill() -> void:
	# No Sapper walks off to lay charges (Old Mill's plan), and with no Light unit
	# the AI controls there is no villager to look after: the march is all there is.
	var w: World = _bare()
	var sapper: Unit = _spawn(w, &"sapper", LIGHT, 20, 20)
	_spawn(w, &"shieldman", LIGHT, 22, 20)
	var pilot: PlaytestPilot = _free_pilot(PlaytestPilot.Kind.COMPETENT, [Vector2i(60, 60)], true)
	pilot.think(w)
	assert_eq(pilot.charges_done_tick, -1, "no charges are laid")
	for command: SimCommand in pilot.recorded:
		assert_ne(command.get_script(), UseSpecialCommand, "nothing to use a special on")
	assert_true(_commands_of(pilot, MoveUnitsCommand, sapper.id).is_empty(), "no walking to a charge spot")
	assert_eq(_commands_of(pilot, AttackMoveCommand, sapper.id).size(), 1, "the Sapper follows the march")


func test_a_competent_pilot_holds_the_last_point_and_ignores_a_far_enemy() -> void:
	var w: World = _bare()
	var soldier: Unit = _spawn(w, &"shieldman", LIGHT, 58, 60)
	var husk: Unit = _spawn(w, &"husk", DARK, 110, 60)
	var pilot: PlaytestPilot = _free_pilot(PlaytestPilot.Kind.COMPETENT, [Vector2i(60, 60)], true)
	pilot.think(w)
	assert_true(pilot.route_done, "it is on the last point")
	assert_almost_eq(_last_march_x(pilot), 60.0, 1.0, "the order is for the point, not for the Husk 50 m off")
	var sent: int = pilot.recorded.size()
	w.step()
	pilot.think(w)
	assert_eq(pilot.recorded.size(), sent, "nothing new: it holds")
	# The Husk comes within CLEAR_M: it is fought, and the point is gone back to after.
	husk.x = soldier.x + 20 * M
	w.step()
	pilot.think(w)
	assert_almost_eq(_last_march_x(pilot), husk.x / float(M), 1.0, "a Husk 20 m off is gone for")
	husk.kill()
	w.step()
	pilot.think(w)
	assert_almost_eq(_last_march_x(pilot), 60.0, 1.0, "and with it dead, back to the point")


func test_a_competent_pilot_hunts_the_nearest_enemy_when_it_is_not_told_to_hold() -> void:
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 58, 60)
	_spawn(w, &"husk", DARK, 110, 60)
	_spawn(w, &"husk", DARK, 100, 100)
	var pilot: PlaytestPilot = _free_pilot(PlaytestPilot.Kind.COMPETENT, [Vector2i(60, 60)], false)
	pilot.think(w)
	assert_true(pilot.route_done)
	assert_almost_eq(_last_march_x(pilot), 110.0, 1.0, "the nearer Husk, 50 m off, is hunted")


func test_a_naive_pilot_holds_or_hunts_at_the_end_of_its_route_as_told() -> void:
	for hold: bool in [true, false]:
		var w: World = _bare()
		var soldier: Unit = _spawn(w, &"shieldman", LIGHT, 58, 60)
		var husk: Unit = _spawn(w, &"husk", DARK, 100, 60)
		var pilot: PlaytestPilot = _free_pilot(PlaytestPilot.Kind.NAIVE, [Vector2i(60, 60)], hold)
		pilot.think(w)
		assert_true(pilot.route_done, "hold %s" % hold)
		assert_almost_eq(_last_march_x(pilot), 60.0 if hold else 100.0, 1.0, "hold %s" % hold)
		# A Husk within CLEAR_M of the army is fought either way.
		husk.x = soldier.x + 15 * M
		w.step()
		pilot.think(w)
		assert_almost_eq(_last_march_x(pilot), husk.x / float(M), 1.0, "hold %s: a close Husk is fought" % hold)


func test_a_pilot_with_no_route_holds_where_its_army_stands() -> void:
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 30, 30)
	_spawn(w, &"husk", DARK, 100, 30)
	for kind: PlaytestPilot.Kind in [PlaytestPilot.Kind.COMPETENT, PlaytestPilot.Kind.NAIVE]:
		var pilot: PlaytestPilot = PlaytestPilot.new(kind)
		pilot.record = true
		pilot.think(w)
		assert_true(pilot.route_done, PlaytestPilot.kind_name(kind))
		assert_almost_eq(_last_march_x(pilot), 30.0, 1.0, "%s stays at its own centroid" % PlaytestPilot.kind_name(kind))


func test_the_pilots_with_a_mission_ignore_hold_and_keep_their_endings() -> void:
	# The tiny mission's pilot hunts at the end of its route, as before set_route existed.
	var w: World = _bare()
	_spawn(w, &"shieldman", LIGHT, 58, 58)
	_spawn(w, &"husk", DARK, 100, 60)
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.NAIVE, _tiny_mission())
	pilot.record = true
	pilot.think(w)
	assert_almost_eq(_last_march_x(pilot), 100.0, 1.0)


func test_a_held_army_ends_on_its_point_and_a_hunting_one_goes_for_the_far_enemy() -> void:
	# Played out: an idle Husk 50 m beyond the point the army is sent to.
	for hold: bool in [true, false]:
		var w: World = _bare()
		var soldier: Unit = _spawn(w, &"shieldman", LIGHT, 20, 60)
		var husk: Unit = _spawn(w, &"husk", DARK, 110, 60)
		var pilot: PlaytestPilot = _free_pilot(PlaytestPilot.Kind.COMPETENT, [Vector2i(60, 60)], hold)
		var seconds: int = 45 if hold else 75
		for tick: int in seconds * World.TICK_RATE:
			if tick % PlaytestPilot.THINK_TICKS == 0:
				pilot.think(w)
			w.step()
		if hold:
			assert_lt(Vector2(soldier.x - 60 * M, soldier.z - 60 * M).length(), 10.0 * M, "he stands on the point")
			assert_eq(husk.hp, husk.type.max_hp, "and the Husk 50 m off was never touched")
		else:
			assert_true(not husk.is_alive() or husk.hp < husk.type.max_hp, "he went and fought the Husk")
