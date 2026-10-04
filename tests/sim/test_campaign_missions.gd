extends GutTest
## The shipped campaign (Phase 8): data/campaign/campaign.tres and its three
## missions, Riverside, The Ford, and Old Mill, each a MissionDef with a rules
## script and an atmosphere, all hand-written .tres. They are checked as data
## against the shipped catalog and the real maps, and then played: the
## campaign and every mission validate; every spawn point, waypoint, and deploy
## point is ground its units can stand on; the coordinates that come from a map
## generator match the generator's own constants; the trigger chains can all
## fire and each mission can be won (and lost) by a scripted player; and two
## worlds built the way a campaign builds them stay identical tick for tick.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const UNDEAD: Terrain.Mobility = Terrain.Mobility.UNDEAD
const FLOATING: Terrain.Mobility = Terrain.Mobility.FLOATING
const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
const RIVERSIDE: int = 0
const FORD: int = 1
const MILL: int = 2
const MISSION_IDS: Array[StringName] = [&"riverside", &"the_ford", &"old_mill"]
const GENERATORS: Array[String] = [
	"res://scripts/gen_riverside.gd", "res://scripts/gen_the_ford.gd", "res://scripts/gen_old_mill.gd",
]
## How far a mission coordinate may sit from the generator's constant (milli-units).
const TOLERANCE: int = 500
## The tier a campaign plays at by default, and the seed the tests build it from.
const TIER: int = 2
const CAMPAIGN_SEED: int = 7
## How far around a pool's centre (m) the water must be depth 3 or more, so the
## whole group laid out there is hidden.
const DEEP_MARGIN: int = 3
## Short names for the action kinds the tables below use.
const SAY: TriggerAction.Kind = TriggerAction.Kind.SET_OBJECTIVE
const SPAWN: TriggerAction.Kind = TriggerAction.Kind.SPAWN_GROUP
const SHOW: TriggerAction.Kind = TriggerAction.Kind.SHOW_OBJECTIVE
const DONE: TriggerAction.Kind = TriggerAction.Kind.COMPLETE_OBJECTIVE
const FAIL: TriggerAction.Kind = TriggerAction.Kind.FAIL_OBJECTIVE
const WIN: TriggerAction.Kind = TriggerAction.Kind.WIN
const LOSE: TriggerAction.Kind = TriggerAction.Kind.LOSE
const WEATHER: TriggerAction.Kind = TriggerAction.Kind.SET_WEATHER
const BEHAVE: TriggerAction.Kind = TriggerAction.Kind.SET_BEHAVIOR
## Ticks of the determinism run, and how often its hashes are compared.
const DETERMINISM_TICKS: int = 3000
const HASH_EVERY: int = 500
## What the AI-aware smoke and scripted runs may take at most, in ticks.
const SCRIPTED_LIMIT: int = 9000

var _campaign: CampaignDef
var _catalog: UnitCatalog
var _terrains: Array[Terrain] = []
var _pathings: Array[Pathing] = []
var _generators: Array[Dictionary] = []


func before_all() -> void:
	_campaign = load(CAMPAIGN_PATH) as CampaignDef
	_catalog = TestTerrains.catalog()
	for i: int in MISSION_IDS.size():
		var terrain: Terrain = Terrain.load_map(_campaign.missions[i].map)
		_terrains.append(terrain)
		_pathings.append(Pathing.new(terrain))
		var generator: GDScript = load(GENERATORS[i]) as GDScript
		_generators.append(generator.get_script_constant_map())


# ---- helpers ----

func _mission(index: int) -> MissionDef:
	return _campaign.missions[index]


func _rules(index: int) -> MissionScript:
	return _campaign.missions[index].rules


func _group(index: int, group_name: StringName) -> AiGroupSpec:
	var i: int = _rules(index).group_index(group_name)
	assert_gte(i, 0, "mission %d has group %s" % [index, group_name])
	return _rules(index).groups[i] if i >= 0 else AiGroupSpec.new()


func _trigger(index: int, trigger_name: StringName) -> TriggerSpec:
	var i: int = _rules(index).trigger_index(trigger_name)
	assert_gte(i, 0, "mission %d has trigger %s" % [index, trigger_name])
	return _rules(index).triggers[i] if i >= 0 else TriggerSpec.new()


func _names_of(items: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for item: Resource in items:
		out.append(item.get("name"))
	return out


## The x, z pair at pair index k of a flat array, in milli-units.
func _pair(flat: PackedInt32Array, k: int = 0) -> Vector2i:
	return Vector2i(flat[2 * k], flat[2 * k + 1])


## Every spawn point, waypoint, and retreat point of the group, in milli-units.
func _points_of(group: AiGroupSpec) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for flat: PackedInt32Array in [group.spawns, group.waypoints, group.retreat_point]:
		for k: int in range(0, flat.size() - 1, 2):
			out.append(Vector2i(flat[k], flat[k + 1]))
	return out


## The distinct mobilities among the group's unit types.
func _mobilities_of(group: AiGroupSpec) -> Array[Terrain.Mobility]:
	var out: Array[Terrain.Mobility] = []
	for entry: AiUnitEntry in group.units:
		var mobility: Terrain.Mobility = _catalog.find(entry.type_id).mobility
		if not out.has(mobility):
			out.append(mobility)
	return out


## How many of a type a group spawns at each tier, as five values.
func _per_tier(group: AiGroupSpec, type_id: StringName) -> PackedInt32Array:
	var total: PackedInt32Array = PackedInt32Array()
	total.resize(Difficulty.TIERS)
	for entry: AiUnitEntry in group.units:
		if entry.type_id == type_id:
			for tier: int in Difficulty.TIERS:
				total[tier] += Difficulty.pick(entry.counts, tier)
	return total


## A per-tier array's five values, whether it holds one or five.
func _five(values: PackedInt32Array) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for tier: int in Difficulty.TIERS:
		out.append(Difficulty.pick(values, tier))
	return out


func _type_ids(group: AiGroupSpec) -> Array[StringName]:
	var out: Array[StringName] = []
	for entry: AiUnitEntry in group.units:
		out.append(entry.type_id)
	return out


## The roster entry for a type.
func _roster(index: int, type_id: StringName) -> RosterEntry:
	for entry: RosterEntry in _mission(index).roster:
		if entry.type_id == type_id:
			return entry
	fail_test("mission %d has no roster entry for %s" % [index, type_id])
	return RosterEntry.new()


## The text of the trigger's one message (SET_OBJECTIVE) action.
func _message(index: int, trigger_name: StringName) -> String:
	for action: TriggerAction in _trigger(index, trigger_name).actions:
		if action.kind == TriggerAction.Kind.SET_OBJECTIVE:
			return action.text
	return ""


func _action_kinds(index: int, trigger_name: StringName) -> Array[TriggerAction.Kind]:
	var out: Array[TriggerAction.Kind] = []
	for action: TriggerAction in _trigger(index, trigger_name).actions:
		out.append(action.kind)
	return out


## Milli-units as whole metres, for messages.
func _m(milli: int) -> int:
	return roundi(float(milli) / M)


## True if flat coordinates (milli-units) are within TOLERANCE of a point in metres.
func _near(at: Vector2i, meters: Vector2) -> bool:
	return absi(at.x - roundi(meters.x * M)) <= TOLERANCE and absi(at.y - roundi(meters.y * M)) <= TOLERANCE


func _assert_near(at: Vector2i, meters: Vector2, what: String) -> void:
	assert_true(_near(at, meters), "%s is %s milli-units, the generator's is %s m" % [what, at, meters])


## A campaign world for the mission at this tier, built the way the game builds
## one: a CampaignState's plan, the plan's deploy command, MissionSetup.
func _world(index: int, tier: int = TIER) -> World:
	var state: CampaignState = CampaignState.new_campaign(CAMPAIGN_SEED, tier)
	var plan: DeployPlan = state.plan_deploy(_mission(index), PackedInt32Array(), _campaign.soldier_names)
	var world: World = MissionSetup.create_world(
		_mission(index), tier, state.mission_seed(index), plan.command(0, _mission(index)), _catalog
	)
	assert_not_null(world, "mission %d builds a world" % index)
	return world


## The player's soldiers: Light units the AI didn't spawn.
func _soldiers(world: World) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in world.units:
		if unit.faction == LIGHT and unit.is_alive() and not world.ai.controls(unit.id):
			ids.append(unit.id)
	return ids


func _kill_dark(world: World) -> void:
	for unit: Unit in world.units:
		if unit.faction == DARK and unit.is_alive():
			unit.kill()


## The first objective's spot: the ford, the ford's mouth, and the mill yard.
func _first_objective(index: int) -> Vector2i:
	var spots: Array[Vector2i] = [Vector2i(300, 226), Vector2i(192, 226), Vector2i(166, 157)]
	return spots[index] * M


## How many groups have spawned so far, over every group of the script.
func _spawned_groups(world: World) -> int:
	var total: int = 0
	for g: int in world.mission.mission_script.groups.size():
		total += world.ai.groups_of(g).size()
	return total


func _fired(world: World, trigger_name: StringName) -> int:
	return world.mission.fired_tick[world.mission.mission_script.trigger_index(trigger_name)]


func _objective_state(world: World, objective_name: StringName) -> MissionRuntime.ObjectiveState:
	return world.mission.objective_state(world.mission.mission_script.objective_index(objective_name))


# ---- the campaign ----

func test_the_campaign_validates_against_the_shipped_catalog() -> void:
	assert_not_null(_campaign, "the campaign loads as a CampaignDef")
	assert_eq(_campaign.validate(_catalog), PackedStringArray(), "the campaign validates clean")
	for i: int in MISSION_IDS.size():
		assert_eq(_mission(i).validate(_catalog), PackedStringArray(), "mission %s validates clean" % MISSION_IDS[i])


func test_the_campaign_lists_the_three_missions_in_play_order() -> void:
	assert_eq(_campaign.missions.size(), 3)
	for i: int in MISSION_IDS.size():
		assert_eq(_mission(i).id, MISSION_IDS[i])
	assert_eq(_mission(RIVERSIDE).display_name, "Riverside")
	assert_eq(_mission(FORD).display_name, "The Ford")
	assert_eq(_mission(MILL).display_name, "Old Mill")


func test_there_are_at_least_sixty_distinct_plain_given_names() -> void:
	assert_gte(_campaign.soldier_names.size(), 60)
	var seen: Dictionary[String, bool] = {}
	var plain: RegEx = RegEx.create_from_string("^[A-Z][a-z]+$")
	for given: String in _campaign.soldier_names:
		assert_not_null(plain.search(given), "%s is a plain given name" % given)
		assert_false(seen.has(given), "%s appears once" % given)
		seen[given] = true


func test_every_briefing_is_eighty_to_a_hundred_and_fifty_words() -> void:
	for i: int in MISSION_IDS.size():
		var words: int = _mission(i).briefing.replace("\n", " ").split(" ", false).size()
		assert_between(words, 80, 150, "%s's briefing is %d words" % [MISSION_IDS[i], words])


func test_each_mission_names_its_map_and_its_own_rules() -> void:
	assert_eq(_mission(RIVERSIDE).map.resource_path, "res://maps/riverside/riverside.tres")
	assert_eq(_mission(FORD).map.resource_path, "res://maps/the_ford/the_ford.tres")
	assert_eq(_mission(MILL).map.resource_path, "res://maps/old_mill/old_mill.tres")
	for i: int in MISSION_IDS.size():
		assert_eq(_mission(i).rules.resource_path, "res://data/missions/%s/rules.tres" % MISSION_IDS[i])
		assert_eq(_mission(i).resource_path, "res://data/missions/%s/mission.tres" % MISSION_IDS[i])
		assert_eq(_mission(i).atmosphere.resource_path, "res://data/atmospheres/%s.tres" % MISSION_IDS[i])


func test_the_atmospheres_validate_and_darken_mission_by_mission() -> void:
	var atmospheres: Array[Atmosphere] = []
	for i: int in MISSION_IDS.size():
		var atmosphere: Atmosphere = _mission(i).atmosphere
		assert_not_null(atmosphere, "%s has an atmosphere" % MISSION_IDS[i])
		assert_eq(atmosphere.validate(), PackedStringArray(), "%s's atmosphere validates" % MISSION_IDS[i])
		atmospheres.append(atmosphere)
	var riverside: Atmosphere = atmospheres[RIVERSIDE]
	var ford: Atmosphere = atmospheres[FORD]
	var mill: Atmosphere = atmospheres[MILL]
	# Riverside: late summer and a faint haze, near the defaults.
	assert_true(riverside.fog_enabled)
	assert_lt(riverside.fog_density, 0.005, "a faint haze")
	assert_eq(riverside.terrain_desaturation, 0.0)
	assert_true(riverside.ground_recolor.is_empty())
	assert_eq(riverside.water_tint.a, 0.0, "the water is as it is")
	assert_eq(riverside.ash_fall, 0.0)
	# The Ford: grey-green, desaturated 0.35, dead grass, murky water, light fog.
	assert_almost_eq(ford.terrain_desaturation, 0.35, 0.01)
	assert_eq(ford.ground_recolor.size(), Terrain.GROUND_COUNT, "one colour per ground type")
	assert_gt(ford.ground_recolor[Terrain.Ground.GRASS].a, 0.3, "the grass is recoloured the most")
	assert_gt(ford.water_tint.a, 0.4, "murky water")
	assert_true(ford.fog_enabled)
	assert_gt(ford.background_color.g, ford.background_color.r, "a green in the grey")
	assert_eq(ford.ash_fall, 0.0)
	# Old Mill: ember sky and sun, dark ambient, red-brown fog, ash, near-black water.
	assert_gt(mill.background_color.r, mill.background_color.g, "an ember sky")
	assert_gt(mill.sun_color.r, mill.sun_color.b + 0.5, "an ember sun")
	assert_lt(mill.ambient_energy, riverside.ambient_energy, "dark ambient")
	assert_true(mill.fog_enabled)
	assert_gt(mill.fog_color.r, mill.fog_color.g, "red-brown fog")
	assert_gt(mill.fog_color.g, mill.fog_color.b)
	assert_almost_eq(mill.ash_fall, 0.6, 0.01)
	# Drained further than The Ford's, with headroom (the ordering checks below);
	# the exact value was eased in the balance pass so the plateau reads.
	assert_between(mill.terrain_desaturation, 0.4, 0.6)
	assert_eq(mill.ground_recolor.size(), Terrain.GROUND_COUNT)
	assert_lt(mill.water_tint.r + mill.water_tint.g + mill.water_tint.b, 0.3, "near-black water")
	assert_gt(mill.water_tint.a, 0.7)
	# Headroom: Old Mill is not the end of the dark.
	assert_lt(mill.ash_fall, 1.0)
	assert_lt(mill.terrain_desaturation, 1.0)
	# And each is darker than the one before.
	assert_lt(riverside.terrain_desaturation, ford.terrain_desaturation)
	assert_lt(ford.terrain_desaturation, mill.terrain_desaturation)
	assert_lt(riverside.water_tint.a, ford.water_tint.a)
	assert_lt(ford.water_tint.a, mill.water_tint.a)
	assert_lt(riverside.fog_density, ford.fog_density)
	assert_lt(ford.fog_density, mill.fog_density)
	assert_lt(riverside.ash_fall, mill.ash_fall)


# ---- rosters and deploys ----

func test_the_rosters_are_the_designed_ones_and_every_entry_carries_over() -> void:
	var expected: Array[Dictionary] = [
		{&"shieldman": [8, 7, 6, 6, 5], &"reaver": [3, 3, 3, 3, 3], &"longbow": [3, 3, 3, 3, 3], &"sapper": [2, 2, 2, 2, 2]},
		{
			&"shieldman": [8, 7, 6, 6, 5], &"reaver": [3, 3, 3, 3, 3], &"longbow": [4, 4, 4, 4, 4],
			&"sapper": [2, 2, 2, 2, 2], &"warden": [2, 1, 1, 1, 1],
		},
		{
			&"shieldman": [10, 9, 8, 8, 7], &"reaver": [3, 3, 3, 3, 3], &"longbow": [4, 4, 4, 4, 4],
			&"sapper": [3, 3, 3, 3, 3], &"warden": [2, 2, 2, 2, 2],
		},
	]
	for i: int in MISSION_IDS.size():
		var roster: Array[RosterEntry] = _mission(i).roster
		var want: Dictionary = expected[i]
		assert_eq(roster.size(), want.size(), "%s's roster types" % MISSION_IDS[i])
		for entry: RosterEntry in roster:
			var counts: Array = want[entry.type_id]
			assert_eq(_five(entry.counts), PackedInt32Array(counts), "%s %s per tier" % [MISSION_IDS[i], entry.type_id])
			assert_true(entry.carryover, "%s %s carries over" % [MISSION_IDS[i], entry.type_id])
			assert_eq(_catalog.find(entry.type_id).faction, LIGHT)
	# Melee first, the way the box lays it out front to back.
	for i: int in MISSION_IDS.size():
		assert_eq(_mission(i).roster[0].type_id, &"shieldman")


func test_the_plan_deploys_the_rosters_at_tier_two() -> void:
	var totals: Array[int] = [14, 16, 20]
	for i: int in MISSION_IDS.size():
		var state: CampaignState = CampaignState.new_campaign(CAMPAIGN_SEED, TIER)
		var plan: DeployPlan = state.plan_deploy(_mission(i), PackedInt32Array(), _campaign.soldier_names)
		assert_eq(plan.size(), totals[i], "%s deploys %d at tier 2" % [MISSION_IDS[i], totals[i]])


func test_the_deploy_points_facings_formation_and_cameras() -> void:
	var deploys: Array[Vector2i] = [Vector2i(290, 180), Vector2i(192, 300), Vector2i(156, 158)]
	var facings: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(0, -1)]
	var cameras: Array[Vector2i] = [Vector2i(285, 240), Vector2i(192, 285), Vector2i(160, 205)]
	for i: int in MISSION_IDS.size():
		var mission: MissionDef = _mission(i)
		assert_eq(_pair(mission.deploy), deploys[i] * M, "%s deploy" % MISSION_IDS[i])
		assert_eq(Vector2i(mission.deploy_facing_x, mission.deploy_facing_z), facings[i], "%s facing" % MISSION_IDS[i])
		assert_eq(mission.deploy_formation, Formations.Kind.BOX)
		assert_eq(_pair(mission.camera_start), cameras[i] * M, "%s camera" % MISSION_IDS[i])
		assert_true(_terrains[i].is_passable(mission.camera_start[0], mission.camera_start[1], LIVING), "the camera looks at ground")


func test_the_deploy_point_and_every_slot_of_its_block_is_walkable() -> void:
	for i: int in MISSION_IDS.size():
		var mission: MissionDef = _mission(i)
		assert_true(_terrains[i].is_passable(mission.deploy[0], mission.deploy[1], LIVING), "%s deploy point" % MISSION_IDS[i])
		var count: int = 0
		var largest: int = 0
		for entry: RosterEntry in mission.roster:
			count += Difficulty.pick(entry.counts, 0)
			largest = maxi(largest, _catalog.find(entry.type_id).body_radius)
		# Tier 0 is the largest block of the three.
		for slot: FormationSlot in Formations.slots(
			mission.deploy_formation, count, mission.deploy[0], mission.deploy[1],
			mission.deploy_facing_x, mission.deploy_facing_z, Formations.spacing_for(largest)
		):
			assert_true(
				_terrains[i].is_passable(slot.x, slot.z, LIVING),
				"%s: a slot at (%d, %d) milli-units is not walkable" % [MISSION_IDS[i], slot.x, slot.z]
			)


# ---- the enum numbers in the hand-written data ----

func test_the_numeric_enums_in_the_data_mean_what_the_comments_say() -> void:
	var behaviors: Array[Dictionary] = [
		{
			&"field_patrol_w": AiGroupSpec.Behavior.PATROL, &"field_patrol_e": AiGroupSpec.Behavior.PATROL,
			&"village_patrol": AiGroupSpec.Behavior.PATROL, &"village_guard": AiGroupSpec.Behavior.GUARD,
			&"raiders": AiGroupSpec.Behavior.FLANK, &"field_roamers_s": AiGroupSpec.Behavior.PATROL,
			&"field_roamers_w": AiGroupSpec.Behavior.PATROL,
		},
		{
			&"villager": AiGroupSpec.Behavior.ESCORT, &"pool_w": AiGroupSpec.Behavior.AMBUSH,
			&"pool_e": AiGroupSpec.Behavior.AMBUSH, &"landing": AiGroupSpec.Behavior.GUARD,
			&"drifters": AiGroupSpec.Behavior.PATROL, &"rippers": AiGroupSpec.Behavior.FLANK,
			&"rippers_rear": AiGroupSpec.Behavior.FLANK,
		},
		{
			&"wave_husks": AiGroupSpec.Behavior.HUNT, &"wave_rippers": AiGroupSpec.Behavior.HUNT,
			&"wave_bags": AiGroupSpec.Behavior.HUNT, &"wave_drifters": AiGroupSpec.Behavior.HUNT,
			&"wave_storm": AiGroupSpec.Behavior.HUNT,
		},
	]
	for i: int in MISSION_IDS.size():
		var want: Dictionary = behaviors[i]
		assert_eq(_rules(i).groups.size(), want.size(), "%s's groups" % MISSION_IDS[i])
		for group_name: StringName in want:
			assert_eq(_group(i, group_name).behavior, want[group_name], "%s %s behavior" % [MISSION_IDS[i], group_name])
	assert_eq(_group(FORD, &"drifters").patrol_mode, AiGroupSpec.PatrolMode.PING_PONG)
	for patrol: StringName in [&"field_patrol_w", &"field_patrol_e", &"village_patrol", &"field_roamers_s", &"field_roamers_w"]:
		assert_eq(_group(RIVERSIDE, patrol).patrol_mode, AiGroupSpec.PatrolMode.LOOP, "%s loops" % patrol)
	# Only the villager is Light.
	for i: int in MISSION_IDS.size():
		for group: AiGroupSpec in _rules(i).groups:
			assert_eq(group.faction, LIGHT if group.name == &"villager" else DARK, "%s faction" % group.name)
	var conditions: Array[Dictionary] = [
		{
			&"hello": TriggerSpec.Condition.TIMER, &"hint_formation": TriggerSpec.Condition.TIMER,
			&"at_ford": TriggerSpec.Condition.AREA_ENTERED, &"hint_grenade": TriggerSpec.Condition.AREA_ENTERED,
			&"hint_fire": TriggerSpec.Condition.TIMER, &"stirring": TriggerSpec.Condition.TIMER,
			&"raid": TriggerSpec.Condition.UNIT_DIES,
			&"raid_over": TriggerSpec.Condition.GROUP_CLEARED, &"win": TriggerSpec.Condition.FACTION_ELIMINATED,
			&"lose": TriggerSpec.Condition.PLAYER_ELIMINATED,
		},
		{
			&"start": TriggerSpec.Condition.TIMER, &"crossing": TriggerSpec.Condition.AREA_ENTERED,
			&"rear": TriggerSpec.Condition.TIMER,
			&"north": TriggerSpec.Condition.AREA_ENTERED, &"flank_timer": TriggerSpec.Condition.TIMER,
			&"flank": TriggerSpec.Condition.TRIGGERS_FIRED, &"home": TriggerSpec.Condition.AREA_ENTERED,
			&"villager_dead": TriggerSpec.Condition.UNIT_DIES, &"lose": TriggerSpec.Condition.PLAYER_ELIMINATED,
		},
		{
			&"setup": TriggerSpec.Condition.TIMER, &"w1": TriggerSpec.Condition.TIMER,
			&"w1_clear": TriggerSpec.Condition.GROUP_CLEARED, &"w2_breather": TriggerSpec.Condition.TIMER,
			&"w2_late": TriggerSpec.Condition.TIMER, &"w2": TriggerSpec.Condition.TRIGGERS_FIRED,
			&"w2_clear": TriggerSpec.Condition.GROUP_CLEARED, &"w3_breather": TriggerSpec.Condition.TIMER,
			&"w3_late": TriggerSpec.Condition.TIMER, &"w3": TriggerSpec.Condition.TRIGGERS_FIRED,
			&"w3_clear": TriggerSpec.Condition.GROUP_CLEARED, &"w4_breather": TriggerSpec.Condition.TIMER,
			&"w4_late": TriggerSpec.Condition.TIMER, &"w4": TriggerSpec.Condition.TRIGGERS_FIRED,
			&"rain": TriggerSpec.Condition.TIMER, &"win": TriggerSpec.Condition.GROUP_CLEARED,
			&"overrun": TriggerSpec.Condition.AREA_ENTERED, &"lose": TriggerSpec.Condition.PLAYER_ELIMINATED,
		},
	]
	for i: int in MISSION_IDS.size():
		var want: Dictionary = conditions[i]
		assert_eq(_rules(i).triggers.size(), want.size(), "%s's triggers" % MISSION_IDS[i])
		for trigger_name: StringName in want:
			assert_eq(_trigger(i, trigger_name).condition, want[trigger_name], "%s %s condition" % [MISSION_IDS[i], trigger_name])
	# The faction fields that aren't the Light default.
	assert_eq(_trigger(RIVERSIDE, &"win").faction, DARK)
	assert_eq(_trigger(MILL, &"overrun").faction, DARK)
	assert_eq(_trigger(RIVERSIDE, &"lose").faction, LIGHT)
	# The Ripper groups go for ranged and support: 2 | 4.
	assert_eq(_group(RIVERSIDE, &"raiders").flank_roles, (1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT))
	assert_eq(_group(FORD, &"rippers").flank_roles, (1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT))
	assert_eq(_group(FORD, &"rippers_rear").flank_roles, (1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT))
	# The crossing springs both pools into HUNT (3).
	for k: int in [1, 2]:
		assert_eq(_trigger(FORD, &"crossing").actions[k].behavior, AiGroupSpec.Behavior.HUNT)


func test_the_action_kinds_of_every_trigger() -> void:
	var kinds: Array[Dictionary] = [
		{
			&"hello": [SAY], &"hint_formation": [SAY], &"at_ford": [DONE, SAY], &"hint_grenade": [SAY],
			&"hint_fire": [SAY], &"stirring": [BEHAVE, BEHAVE, SAY], &"raid": [SPAWN, SHOW, SAY], &"raid_over": [DONE],
			&"win": [DONE, WIN],
			&"lose": [LOSE],
		},
		{
			&"start": [SAY], &"crossing": [SAY, BEHAVE, BEHAVE], &"rear": [SPAWN, SAY], &"north": [SHOW],
			&"flank_timer": [], &"flank": [SPAWN, SAY],
			&"home": [DONE, DONE, WIN], &"villager_dead": [FAIL, LOSE], &"lose": [LOSE],
		},
		{
			&"setup": [SAY], &"w1": [SPAWN, SAY], &"w1_clear": [], &"w2_breather": [], &"w2_late": [],
			&"w2": [SPAWN, SAY], &"w2_clear": [], &"w3_breather": [], &"w3_late": [], &"w3": [SPAWN, SAY],
			&"w3_clear": [], &"w4_breather": [], &"w4_late": [], &"w4": [SPAWN, SAY], &"rain": [WEATHER],
			&"win": [DONE, DONE, WIN], &"overrun": [FAIL, LOSE], &"lose": [LOSE],
		},
	]
	for i: int in MISSION_IDS.size():
		var want: Dictionary = kinds[i]
		for trigger_name: StringName in want:
			assert_eq(_action_kinds(i, trigger_name), want[trigger_name], "%s %s actions" % [MISSION_IDS[i], trigger_name])


# ---- Riverside ----

func test_riverside_has_the_designed_groups_counts_and_objectives() -> void:
	var rules: MissionScript = _rules(RIVERSIDE)
	assert_eq(
		_names_of(rules.groups),
		[&"field_patrol_w", &"field_patrol_e", &"village_patrol", &"village_guard", &"raiders", &"field_roamers_s", &"field_roamers_w"]
	)
	for patrol: StringName in [&"field_patrol_w", &"field_patrol_e", &"village_patrol"]:
		assert_eq(_type_ids(_group(RIVERSIDE, patrol)), [&"husk"])
		assert_eq(_per_tier(_group(RIVERSIDE, patrol), &"husk"), PackedInt32Array([7, 7, 7, 7, 7]), "%s has 7 Husks" % patrol)
	assert_eq(_per_tier(_group(RIVERSIDE, &"village_guard"), &"husk"), PackedInt32Array([6, 8, 10, 11, 12]))
	assert_eq(_per_tier(_group(RIVERSIDE, &"raiders"), &"ripper"), PackedInt32Array([2, 3, 5, 6, 7]))
	for band: StringName in [&"field_roamers_s", &"field_roamers_w"]:
		assert_eq(_type_ids(_group(RIVERSIDE, band)), [&"husk"])
		assert_eq(_per_tier(_group(RIVERSIDE, band), &"husk"), PackedInt32Array([4, 5, 6, 7, 8]), "%s per tier" % band)
		assert_eq(_group(RIVERSIDE, band).alert_radius, 12000)
	assert_eq(_group(RIVERSIDE, &"field_patrol_w").alert_radius, 12000)
	assert_eq(_group(RIVERSIDE, &"field_patrol_e").alert_radius, 12000)
	assert_eq(_group(RIVERSIDE, &"village_patrol").alert_radius, 10000)
	assert_eq(_group(RIVERSIDE, &"village_guard").guard_radius, 18000)
	for group: AiGroupSpec in rules.groups:
		assert_eq(group.spawn_at_start, group.name != &"raiders", "%s spawn_at_start" % group.name)
	assert_true(rules.draws.is_empty(), "Riverside rolls no dice")
	assert_eq(_names_of(rules.objectives), [&"cross", &"clear", &"raid"])
	var texts: Array[String] = []
	for objective: ObjectiveSpec in rules.objectives:
		texts.append(objective.text)
		assert_false(objective.optional, "%s is not optional" % objective.name)
	assert_eq(texts, ["Cross the ford", "Clear the village", "Destroy the raiders"])
	assert_true(rules.objectives[0].shown_at_start)
	assert_true(rules.objectives[1].shown_at_start)
	assert_false(rules.objectives[2].shown_at_start, "the raid objective is hidden")


func test_riverside_triggers_run_in_tutorial_order_with_the_designed_hints() -> void:
	var rules: MissionScript = _rules(RIVERSIDE)
	assert_eq(
		_names_of(rules.triggers),
		[&"hello", &"hint_formation", &"at_ford", &"hint_grenade", &"hint_fire", &"stirring", &"raid", &"raid_over", &"win", &"lose"]
	)
	assert_eq(_message(RIVERSIDE, &"hello"), "Select soldiers: click one, or drag a box. Shift adds.")
	assert_eq(_message(RIVERSIDE, &"hint_formation"), "Pick a formation with 1-0, then right-click the ground to march.")
	assert_eq(_message(RIVERSIDE, &"at_ford"), "The water slows you. Keep your line tight.")
	assert_eq(_message(RIVERSIDE, &"hint_grenade"), "Sappers: Cmd-click (Ctrl-click) the ground to throw. Mind your own men.")
	assert_eq(_message(RIVERSIDE, &"hint_fire"), "Longbows: press T to nock the fire arrow. Brush and houses burn.")
	assert_eq(_message(RIVERSIDE, &"raid"), "Rippers! They go for your archers and sappers.")
	assert_eq(_message(RIVERSIDE, &"stirring"), "The dead in the fields have heard you. They are coming.")
	var stirring: TriggerSpec = _trigger(RIVERSIDE, &"stirring")
	assert_eq(stirring.after, &"hint_grenade", "40 s after the squad reaches the village")
	assert_eq(stirring.ticks, PackedInt32Array([1200]))
	assert_eq(stirring.actions[0].group, &"field_roamers_s")
	assert_eq(stirring.actions[1].group, &"field_roamers_w")
	assert_eq(stirring.actions[0].behavior, AiGroupSpec.Behavior.HUNT)
	assert_eq(stirring.actions[1].behavior, AiGroupSpec.Behavior.HUNT)
	assert_eq(_trigger(RIVERSIDE, &"hello").ticks, PackedInt32Array([0]))
	assert_eq(_trigger(RIVERSIDE, &"hint_formation").after, &"hello")
	assert_eq(_trigger(RIVERSIDE, &"hint_formation").ticks, PackedInt32Array([300]))
	assert_eq(_trigger(RIVERSIDE, &"hint_fire").after, &"hint_grenade")
	assert_eq(_trigger(RIVERSIDE, &"hint_fire").ticks, PackedInt32Array([450]))
	var at_ford: TriggerSpec = _trigger(RIVERSIDE, &"at_ford")
	assert_eq(at_ford.area, PackedInt32Array([300000, 226000, 15000]), "the ford's centre, 15 m")
	assert_eq(at_ford.faction, LIGHT)
	assert_eq(at_ford.min_count, 1)
	assert_eq(at_ford.actions[0].objective, &"cross")
	var grenade: TriggerSpec = _trigger(RIVERSIDE, &"hint_grenade")
	assert_eq(grenade.area[2], 40000, "within 40 m of the square")
	assert_eq(grenade.min_count, 1)
	var raid: TriggerSpec = _trigger(RIVERSIDE, &"raid")
	assert_eq(raid.names, [&"field_roamers_s", &"field_roamers_w"], "the raid comes as the field dead fall")
	assert_eq(raid.count, 6)
	assert_eq(raid.actions[0].group, &"raiders")
	assert_eq(raid.actions[1].objective, &"raid")
	assert_eq(_trigger(RIVERSIDE, &"raid_over").names, [&"raiders"])
	assert_eq(_trigger(RIVERSIDE, &"raid_over").actions[0].objective, &"raid")
	var win: TriggerSpec = _trigger(RIVERSIDE, &"win")
	assert_eq(win.after, &"raid", "a straight assault can't win before the raid")
	assert_eq(win.actions[0].objective, &"clear")
	# Every hint is a message short enough for the line.
	for hint: StringName in [&"hello", &"hint_formation", &"at_ford", &"hint_grenade", &"hint_fire", &"stirring", &"raid"]:
		assert_lt(_message(RIVERSIDE, hint).length(), 100, "%s fits the message line" % hint)


func test_riverside_has_enough_husks_to_spring_the_raid_at_every_tier() -> void:
	var raid: TriggerSpec = _trigger(RIVERSIDE, &"raid")
	for tier: int in Difficulty.TIERS:
		var husks: int = 0
		for group_name: StringName in raid.names:
			husks += _group(RIVERSIDE, group_name).unit_count(tier)
		assert_gt(husks, raid.count, "tier %d has %d Husks for a raid at %d deaths" % [tier, husks, raid.count])


func test_the_field_patrols_keep_their_alert_radius_off_the_north_bank() -> void:
	var terrain: Terrain = _terrains[RIVERSIDE]
	# The dry ground a squad can stand on before it crosses: north of the creek's
	# north shore (z 212) near the ford.
	var bank: Array[Vector2i] = []
	for z: int in range(150, 213):
		for x: int in range(240, 361):
			if terrain.is_sample_passable(x, z, LIVING) and terrain.sample_water_depth(x, z) == 0:
				bank.append(Vector2i(x, z) * M)
	assert_gt(bank.size(), 1000, "there is a north bank to keep clear of")
	for group_name: StringName in [&"field_patrol_w", &"field_patrol_e"]:
		var group: AiGroupSpec = _group(RIVERSIDE, group_name)
		# A group's spread (its box, 4 m or so) is added to the radius.
		var clear: int = group.alert_radius + 4 * M
		for at: Vector2i in _points_of(group):
			for dry: Vector2i in bank:
				if (at - dry).length_squared() <= clear * clear:
					fail_test("%s: (%d, %d) is within %d m of the north bank at (%d, %d)" % [group_name, _m(at.x), _m(at.y), _m(clear), _m(dry.x), _m(dry.y)])
					return
	pass_test("both field patrols are out of alert range of the north bank")


func test_the_raiders_come_from_the_villages_far_south_east_side() -> void:
	var square: Vector2 = _generators[RIVERSIDE]["VILLAGE_SQUARE"]
	var spawn: Vector2i = _pair(_group(RIVERSIDE, &"raiders").spawns)
	assert_gt(spawn.x, roundi(square.x + 25.0) * M, "east of the square")
	assert_gt(spawn.y, roundi(square.y + 15.0) * M, "south of the square")
	var deploy: Vector2i = _pair(_mission(RIVERSIDE).deploy)
	assert_gt(Vector2(spawn - deploy).length(), Vector2(roundi(square.x) * M - deploy.x, roundi(square.y) * M - deploy.y).length(), "farther from the squad than the village is")


# ---- The Ford ----

func test_the_ford_has_the_designed_groups_counts_and_objectives() -> void:
	var rules: MissionScript = _rules(FORD)
	assert_eq(_names_of(rules.groups), [&"villager", &"pool_w", &"pool_e", &"landing", &"drifters", &"rippers", &"rippers_rear"])
	var villager: AiGroupSpec = _group(FORD, &"villager")
	assert_eq(_per_tier(villager, &"villager"), PackedInt32Array([1, 1, 1, 1, 1]))
	assert_eq(villager.escort_radius, 12000)
	assert_eq(villager.alert_radius, 10000)
	assert_eq(villager.retreat_below_permille, 0, "an escort never retreats")
	assert_true(villager.spawn_at_start)
	for pool: StringName in [&"pool_w", &"pool_e"]:
		assert_eq(_per_tier(_group(FORD, pool), &"husk"), PackedInt32Array([4, 5, 6, 6, 7]), "%s Husks per tier" % pool)
		assert_eq(_group(FORD, pool).alert_radius, 12000, "a soldier on the pool's shelf springs it")
		assert_true(_group(FORD, pool).spawn_at_start)
	assert_eq(_per_tier(_group(FORD, &"landing"), &"husk"), PackedInt32Array([5, 6, 6, 7, 8]))
	assert_eq(_group(FORD, &"landing").guard_radius, 15000)
	assert_eq(_per_tier(_group(FORD, &"drifters"), &"drifter"), PackedInt32Array([3, 4, 4, 5, 6]))
	assert_eq(_group(FORD, &"drifters").alert_radius, 25000)
	assert_eq(_per_tier(_group(FORD, &"rippers"), &"ripper"), PackedInt32Array([3, 4, 6, 6, 7]))
	assert_false(_group(FORD, &"rippers").spawn_at_start, "the flank trigger spawns the Rippers")
	assert_eq(_per_tier(_group(FORD, &"rippers_rear"), &"ripper"), PackedInt32Array([3, 4, 6, 6, 7]))
	assert_false(_group(FORD, &"rippers_rear").spawn_at_start, "the rear trigger spawns the rear pack")
	assert_true(rules.draws.is_empty())
	assert_eq(_names_of(rules.objectives), [&"escort", &"hold"])
	assert_eq(rules.objectives[0].text, "Bring the villager to the gate")
	assert_eq(rules.objectives[1].text, "Hold the north landing")
	assert_true(rules.objectives[0].shown_at_start)
	assert_false(rules.objectives[0].optional)
	assert_false(rules.objectives[1].shown_at_start, "hold is hidden until the villager crosses")
	assert_true(rules.objectives[1].optional)


func test_the_fords_triggers_do_what_the_design_says() -> void:
	assert_eq(_message(FORD, &"start"), "The villager walks only while your soldiers are near.")
	assert_eq(_message(FORD, &"crossing"), "Mind the deep water either side.")
	assert_eq(_message(FORD, &"flank"), "Rippers in the east woods!")
	var crossing: TriggerSpec = _trigger(FORD, &"crossing")
	assert_eq(crossing.names, [&"villager"])
	assert_eq(crossing.area[2], 12000)
	assert_eq(crossing.actions[1].group, &"pool_w", "the villager at the ford springs both pools")
	assert_eq(crossing.actions[2].group, &"pool_e")
	var rear: TriggerSpec = _trigger(FORD, &"rear")
	assert_eq(rear.after, &"crossing")
	assert_eq(rear.ticks, PackedInt32Array([90]), "3 s after the crossing, so its warning follows")
	assert_eq(rear.actions[0].group, &"rippers_rear")
	assert_eq(_message(FORD, &"rear"), "Rippers on the south bank, behind you!")
	var north: TriggerSpec = _trigger(FORD, &"north")
	assert_eq(north.names, [&"villager"])
	assert_eq(north.area[2], 15000)
	assert_eq(north.actions[0].objective, &"hold")
	var flank: TriggerSpec = _trigger(FORD, &"flank")
	assert_eq(flank.names, [&"north", &"flank_timer"])
	assert_eq(flank.min_count, 1, "either one")
	assert_eq(flank.actions[0].group, &"rippers")
	assert_eq(_trigger(FORD, &"flank_timer").ticks, PackedInt32Array([6300, 5700, 5400, 4800, 4200]))
	var home: TriggerSpec = _trigger(FORD, &"home")
	assert_eq(home.names, [&"villager"])
	assert_eq(home.actions[0].objective, &"escort")
	assert_eq(home.actions[1].objective, &"hold")
	var dead: TriggerSpec = _trigger(FORD, &"villager_dead")
	assert_eq(dead.names, [&"villager"])
	assert_eq(dead.count, 1)
	assert_eq(dead.actions[0].objective, &"escort")


func test_the_fords_ambush_points_have_deep_water_all_round() -> void:
	var terrain: Terrain = _terrains[FORD]
	for pool: StringName in [&"pool_w", &"pool_e"]:
		var group: AiGroupSpec = _group(FORD, pool)
		assert_eq(group.spawns.size(), 2, "%s has one spawn point" % pool)
		assert_true(group.spawn_by_tier.is_empty())
		var at: Vector2i = _pair(group.spawns) / M
		for dz: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
			for dx: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
				assert_gte(
					terrain.water_depth_at((at.x + dx) * M, (at.y + dz) * M), 3,
					"%s: (%d, %d) m is not depth 3" % [pool, at.x + dx, at.y + dz]
				)


func test_the_escort_walks_one_living_component_into_the_gate_area() -> void:
	var villager: AiGroupSpec = _group(FORD, &"villager")
	var pathing: Pathing = _pathings[FORD]
	var start: Vector2i = _pair(villager.spawns)
	var home: int = pathing.component_at(start.x, start.y, LIVING)
	assert_ne(home, PathLayer.NO_COMPONENT)
	assert_eq(villager.waypoints.size(), 12, "six waypoints")
	for k: int in villager.waypoints.size() >> 1:
		var at: Vector2i = _pair(villager.waypoints, k)
		assert_eq(pathing.component_at(at.x, at.y, LIVING), home, "waypoint %d is in the villager's component" % k)
	var gate: TriggerSpec = _trigger(FORD, &"home")
	assert_gte(gate.area[2], 7000, "the gate area is at least 7 m across")
	var last: Vector2i = _pair(villager.waypoints, (villager.waypoints.size() >> 1) - 1)
	var to_gate: Vector2i = last - Vector2i(gate.area[0], gate.area[1])
	assert_lte(to_gate.length_squared(), gate.area[2] * gate.area[2], "the last waypoint is inside the gate area")
	# The squad's deploy point is in the same component, and inside escort range of the start.
	var deploy: Vector2i = _pair(_mission(FORD).deploy)
	assert_eq(pathing.component_at(deploy.x, deploy.y, LIVING), home)
	assert_lte((start - deploy).length_squared(), villager.escort_radius * villager.escort_radius, "the villager starts escorted")


func test_the_drifters_one_route_covers_both_reaches_over_deep_water() -> void:
	var drifters: AiGroupSpec = _group(FORD, &"drifters")
	var terrain: Terrain = _terrains[FORD]
	var pathing: Pathing = _pathings[FORD]
	assert_eq(drifters.waypoints.size(), 8, "four waypoints")
	assert_eq(_pair(drifters.spawns), _pair(drifters.waypoints), "it spawns at the route's first point")
	var component: int = PathLayer.NO_COMPONENT
	for k: int in drifters.waypoints.size() >> 1:
		var at: Vector2i = _pair(drifters.waypoints, k)
		assert_gte(terrain.water_depth_at(at.x, at.y), 3, "waypoint %d is over deep water" % k)
		var here: int = pathing.component_at(at.x, at.y, FLOATING)
		component = here if k == 0 else component
		assert_eq(here, component, "one connected route")
	assert_lt(_pair(drifters.waypoints, 1).x, 192 * M, "the first reach is west of the ford")
	assert_gt(_pair(drifters.waypoints, 2).x, 192 * M, "the second is east")


func test_the_ripper_spawn_is_in_the_east_woods_and_walks_to_the_landing() -> void:
	var spawn: Vector2i = _pair(_group(FORD, &"rippers").spawns)
	var landing: Vector2i = _pair(_group(FORD, &"landing").spawns)
	assert_between(spawn.x, 280 * M, 360 * M)
	assert_between(spawn.y, 100 * M, 185 * M)
	assert_eq(
		_pathings[FORD].component_at(spawn.x, spawn.y, LIVING),
		_pathings[FORD].component_at(landing.x, landing.y, LIVING)
	)


func test_the_rear_pack_comes_from_the_south_bank_behind_the_ford() -> void:
	var spawn: Vector2i = _pair(_group(FORD, &"rippers_rear").spawns)
	var deploy: Vector2i = _pair(_mission(FORD).deploy)
	var ford: Vector2i = _pair(_trigger(FORD, &"crossing").area)
	# South of the river (the south bank's water edge is at about z 207 m at the
	# ford), west of the road, and nearer the ford than the deploy point is.
	assert_gt(spawn.y, 215 * M, "on the south bank")
	assert_lt(spawn.x, ford.x, "west of the road")
	assert_lt(Vector2(spawn - ford).length(), Vector2(deploy - ford).length(), "nearer the ford than the squad starts")
	assert_eq(
		_pathings[FORD].component_at(spawn.x, spawn.y, LIVING),
		_pathings[FORD].component_at(ford.x, ford.y, LIVING), "it can follow the escort over the ford"
	)


# ---- Old Mill ----

func test_old_mill_has_the_designed_waves() -> void:
	var rules: MissionScript = _rules(MILL)
	assert_eq(_names_of(rules.groups), [&"wave_husks", &"wave_rippers", &"wave_bags", &"wave_drifters", &"wave_storm"])
	for group: AiGroupSpec in rules.groups:
		assert_false(group.spawn_at_start, "%s waits for its trigger" % group.name)
		assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
		assert_eq(group.spawns.size(), 8, "%s has the four edge zones" % group.name)
		assert_eq(group.spawn_by_tier.size(), Difficulty.TIERS, "%s picks an edge per tier" % group.name)
	assert_eq(_per_tier(_group(MILL, &"wave_husks"), &"husk"), PackedInt32Array([24, 30, 40, 42, 44]))
	assert_eq(_type_ids(_group(MILL, &"wave_husks")), [&"husk"])
	# The balance pass's sizes (Phase 8, Task 10), per tier.
	var mixed: Dictionary[StringName, Array] = {
		&"wave_rippers": [&"ripper", [8, 10, 12, 13, 14]], &"wave_bags": [&"blightbag", [6, 7, 8, 8, 9]],
		&"wave_drifters": [&"drifter", [8, 10, 12, 13, 14]], &"wave_storm": [&"stormcaller", [1, 1, 1, 2, 2]],
	}
	var husks: Dictionary[StringName, Array] = {
		&"wave_rippers": [6, 6, 6, 6, 6], &"wave_bags": [12, 14, 16, 17, 18],
		&"wave_drifters": [8, 10, 12, 13, 14], &"wave_storm": [10, 13, 16, 16, 16],
	}
	for wave: StringName in mixed:
		var group: AiGroupSpec = _group(MILL, wave)
		var special: StringName = mixed[wave][0]
		assert_eq(_per_tier(group, special), PackedInt32Array(mixed[wave][1]), "%s %s" % [wave, special])
		assert_eq(_per_tier(group, &"husk"), PackedInt32Array(husks[wave]), "%s Husks" % wave)
		assert_eq(_type_ids(group).size(), 2)
	# Every tier is at least as big as the one below it, wave by wave.
	for group: AiGroupSpec in rules.groups:
		for tier: int in range(1, Difficulty.TIERS):
			assert_gte(group.unit_count(tier), group.unit_count(tier - 1), "%s grows with the tier" % group.name)
	# Husks stand in front of the ranged waves (listed first).
	assert_eq(_type_ids(_group(MILL, &"wave_storm"))[0], &"husk", "the Stormcallers stand behind their Husks")
	assert_eq(_type_ids(_group(MILL, &"wave_drifters"))[0], &"husk")


func test_old_mills_waves_are_drawn_four_of_five_in_difficulty_order() -> void:
	var rules: MissionScript = _rules(MILL)
	assert_eq(rules.draws.size(), 1)
	var draw: MissionDraw = rules.draws[0]
	assert_eq(draw.slots, [&"wave1", &"wave2", &"wave3", &"wave4"])
	assert_eq(draw.pool, [&"wave_husks", &"wave_rippers", &"wave_bags", &"wave_drifters", &"wave_storm"])
	assert_true(draw.ordered, "wave 1 is the easiest drawn")


func test_across_twenty_seeds_every_wave_is_drawn_and_exactly_four_are_bound_each_time() -> void:
	var rules: MissionScript = _rules(MILL)
	var pool: Array[StringName] = rules.draws[0].pool
	var drawn: Dictionary[StringName, int] = {}
	for roll_seed: int in range(1, 21):
		var bound: PackedInt32Array = World.roll_bindings(rules, roll_seed)
		assert_eq(bound.size(), 4, "seed %d binds four waves" % roll_seed)
		var seen: Dictionary[int, bool] = {}
		var last_pool_position: int = -1
		for group_index: int in bound:
			assert_false(seen.has(group_index), "seed %d binds each group once" % roll_seed)
			seen[group_index] = true
			var position: int = pool.find(rules.groups[group_index].name)
			assert_gt(position, last_pool_position, "seed %d binds in pool order, easiest first" % roll_seed)
			last_pool_position = position
			drawn[rules.groups[group_index].name] = drawn.get(rules.groups[group_index].name, 0) + 1
	for wave: StringName in pool:
		assert_true(drawn.has(wave), "%s is drawn at least once in 20 seeds" % wave)


func test_each_waves_edge_by_tier_follows_the_designed_scheme() -> void:
	var rules: MissionScript = _rules(MILL)
	# Tiers 0 and 1: one edge for every wave, the north one.
	for tier: int in [0, 1]:
		for group: AiGroupSpec in rules.groups:
			assert_eq(group.spawn_point(tier), Vector2i(150000, 14000), "%s at tier %d comes from the north" % [group.name, tier])
	# Tier 2 uses both ramps' sides, and tiers 3 and 4 use all four edges.
	for tier: int in [2, 3, 4]:
		var edges: Dictionary[int, bool] = {}
		for group: AiGroupSpec in rules.groups:
			edges[Difficulty.pick(group.spawn_by_tier, tier)] = true
		assert_gte(edges.size(), 2 if tier == 2 else 4, "tier %d varies the edge" % tier)
	# No wave takes the same edge at tiers 2, 3, and 4 (varied edges as the tiers climb).
	for group: AiGroupSpec in rules.groups:
		assert_ne(group.spawn_by_tier[2], group.spawn_by_tier[3], "%s changes edge from tier 2 to 3" % group.name)
		assert_ne(group.spawn_by_tier[3], group.spawn_by_tier[4], "%s changes edge from tier 3 to 4" % group.name)
	# The Stormcallers' worst approach (the south, up the south-east ramp's axis)
	# is the middle tier's and the hardest tier's.
	assert_eq(_group(MILL, &"wave_storm").spawn_point(2), Vector2i(150000, 306000))
	assert_eq(_group(MILL, &"wave_storm").spawn_point(4), Vector2i(150000, 306000))
	# The four zones are listed north, west, south, east.
	var gen: Dictionary = _generators[MILL]
	var zones: Array[Vector2] = [gen["SPAWN_N"], gen["SPAWN_W"], gen["SPAWN_S"], gen["SPAWN_E"]]
	for group: AiGroupSpec in rules.groups:
		for k: int in 4:
			_assert_near(_pair(group.spawns, k), zones[k], "%s zone %d" % [group.name, k])


func test_old_mills_pacing_triggers_chain_as_designed() -> void:
	assert_eq(_message(MILL, &"setup"), "Set satchel charges on the ramps (Sapper: T). The first wave comes in a minute.")
	assert_eq(_trigger(MILL, &"w1").ticks, PackedInt32Array([2400, 2100, 1800, 1500, 1200]))
	assert_eq(_trigger(MILL, &"w1").actions[0].group, &"wave1")
	for k: int in range(2, 5):
		var previous: StringName = StringName("w%d" % (k - 1))
		var wave: StringName = StringName("w%d" % k)
		var breather: TriggerSpec = _trigger(MILL, StringName("w%d_breather" % k))
		assert_eq(breather.after, StringName("w%d_clear" % (k - 1)), "w%d's breather follows wave %d being cleared" % [k, k - 1])
		assert_eq(breather.ticks, PackedInt32Array([750]))
		assert_true(breather.actions.is_empty(), "the breather is a gate")
		var late: TriggerSpec = _trigger(MILL, StringName("w%d_late" % k))
		assert_eq(late.after, previous, "w%d's deadline runs from wave %d spawning" % [k, k - 1])
		assert_eq(late.ticks, PackedInt32Array([5400, 4950, 4500, 3900, 3300]))
		assert_true(late.actions.is_empty())
		var clear: TriggerSpec = _trigger(MILL, StringName("w%d_clear" % (k - 1)))
		assert_eq(clear.names, [StringName("wave%d" % (k - 1))])
		assert_true(clear.actions.is_empty())
		var spawn: TriggerSpec = _trigger(MILL, wave)
		assert_eq(spawn.names, [StringName("w%d_breather" % k), StringName("w%d_late" % k)])
		assert_eq(spawn.min_count, 1)
		assert_eq(spawn.actions[0].group, StringName("wave%d" % k))
		assert_eq(spawn.actions[1].text, "Wave %d of 4." % k)
	assert_eq(_message(MILL, &"w1"), "Wave 1 of 4.")
	var rain: TriggerSpec = _trigger(MILL, &"rain")
	assert_eq(rain.after, &"w3")
	assert_eq(rain.ticks, PackedInt32Array([0]))
	var weather: WeatherChange = rain.actions[0].weather
	assert_eq(weather.rain, 600)
	assert_eq(weather.ramp_ticks, 300)
	assert_eq(weather.tick, 0)
	assert_gt(absi(weather.wind_x) + absi(weather.wind_z), 0, "a light wind")
	assert_lte(absi(weather.wind_x) + absi(weather.wind_z), 5000, "and only light")
	assert_eq(_trigger(MILL, &"win").names, [&"wave1", &"wave2", &"wave3", &"wave4"])
	assert_eq(_trigger(MILL, &"win").actions[0].objective, &"hold")
	assert_eq(_trigger(MILL, &"win").actions[1].objective, &"waves")
	var overrun: TriggerSpec = _trigger(MILL, &"overrun")
	assert_eq(overrun.min_count, 6)
	assert_eq(overrun.area, PackedInt32Array([166000, 157000, 7000]))
	assert_eq(overrun.actions[0].objective, &"hold")
	assert_eq(_names_of(_rules(MILL).objectives), [&"hold", &"waves"])
	assert_eq(_rules(MILL).objectives[0].text, "Hold the mill")
	assert_eq(_rules(MILL).objectives[1].text, "Survive four waves")


func test_every_wave_spawn_reaches_the_plateau() -> void:
	var pathing: Pathing = _pathings[MILL]
	var deploy: Vector2i = _pair(_mission(MILL).deploy)
	for group: AiGroupSpec in _rules(MILL).groups:
		for mobility: Terrain.Mobility in _mobilities_of(group):
			var home: int = pathing.component_at(deploy.x, deploy.y, mobility)
			assert_ne(home, PathLayer.NO_COMPONENT)
			for k: int in group.spawns.size() >> 1:
				var at: Vector2i = _pair(group.spawns, k)
				assert_eq(
					pathing.component_at(at.x, at.y, mobility), home,
					"%s: zone %d is not in the deploy point's component for mobility %d" % [group.name, k, mobility]
				)


# ---- every mission: ground, areas, generator constants ----

func test_every_spawn_waypoint_retreat_and_deploy_point_is_ground_its_units_can_stand_on() -> void:
	for i: int in MISSION_IDS.size():
		var terrain: Terrain = _terrains[i]
		for group: AiGroupSpec in _rules(i).groups:
			var mobilities: Array[Terrain.Mobility] = _mobilities_of(group)
			assert_false(mobilities.is_empty())
			for at: Vector2i in _points_of(group):
				for mobility: Terrain.Mobility in mobilities:
					assert_true(
						terrain.is_passable(at.x, at.y, mobility),
						"%s %s: %s (milli-units) is not passable for mobility %d" % [MISSION_IDS[i], group.name, at, mobility]
					)
		var deploy: Vector2i = _pair(_mission(i).deploy)
		assert_true(terrain.is_passable(deploy.x, deploy.y, LIVING), "%s deploy" % MISSION_IDS[i])


func test_every_group_can_reach_and_be_reached_by_the_squad() -> void:
	# Each point of each group is in the same component as the deploy point for
	# the group's own mobility, so nothing spawns somewhere it can't leave and
	# the squad can't be cut off from what it has to fight.
	for i: int in MISSION_IDS.size():
		var pathing: Pathing = _pathings[i]
		var deploy: Vector2i = _pair(_mission(i).deploy)
		for group: AiGroupSpec in _rules(i).groups:
			for mobility: Terrain.Mobility in _mobilities_of(group):
				var home: int = pathing.component_at(deploy.x, deploy.y, mobility)
				assert_ne(home, PathLayer.NO_COMPONENT)
				for at: Vector2i in _points_of(group):
					assert_eq(
						pathing.component_at(at.x, at.y, mobility), home,
						"%s %s: (%d, %d) m is cut off from the deploy point (mobility %d)" % [MISSION_IDS[i], group.name, _m(at.x), _m(at.y), mobility]
					)


func test_every_trigger_area_lies_on_its_map() -> void:
	for i: int in MISSION_IDS.size():
		var areas: int = 0
		for trigger: TriggerSpec in _rules(i).triggers:
			if trigger.condition != TriggerSpec.Condition.AREA_ENTERED:
				continue
			areas += 1
			var terrain: Terrain = _terrains[i]
			assert_true(
				terrain.contains(trigger.area[0] - trigger.area[2], trigger.area[1] - trigger.area[2])
				and terrain.contains(trigger.area[0] + trigger.area[2], trigger.area[1] + trigger.area[2]),
				"%s %s: the whole circle is on the map" % [MISSION_IDS[i], trigger.name]
			)
		assert_gt(areas, 0, "%s has an area trigger to check" % MISSION_IDS[i])


func test_riverside_coordinates_match_the_generators_constants() -> void:
	var gen: Dictionary = _generators[RIVERSIDE]
	var square: Vector2 = gen["VILLAGE_SQUARE"]
	_assert_near(_pair(_group(RIVERSIDE, &"village_guard").spawns), square, "the guard's post")
	var grenade: TriggerSpec = _trigger(RIVERSIDE, &"hint_grenade")
	_assert_near(Vector2i(grenade.area[0], grenade.area[1]), square, "the grenade hint's centre")
	assert_gt(float(grenade.area[2]) / M, float(gen["VILLAGE_SQUARE_RADIUS_M"]) + 20.0, "it fires before the square")
	var at_ford: TriggerSpec = _trigger(RIVERSIDE, &"at_ford")
	assert_almost_eq(float(at_ford.area[0]) / M, float(gen["FORD_X_M"]), 0.5, "the ford hint's x")
	# The village patrol walks the lanes: each waypoint is on one of the lane polylines.
	var lanes: Array = gen["VILLAGE_LANES"]
	var patrol: AiGroupSpec = _group(RIVERSIDE, &"village_patrol")
	for k: int in patrol.waypoints.size() >> 1:
		var at: Vector2 = Vector2(_pair(patrol.waypoints, k)) / M
		var nearest: float = INF
		for lane: PackedVector2Array in lanes:
			for s: int in lane.size() - 1:
				var closest: Vector2 = Geometry2D.get_closest_point_to_segment(at, lane[s], lane[s + 1])
				nearest = minf(nearest, at.distance_to(closest))
		assert_lte(nearest, float(TOLERANCE) / M, "patrol waypoint %d (%s) is on a lane" % [k, at])


func test_the_fords_coordinates_match_the_generators_constants() -> void:
	var gen: Dictionary = _generators[FORD]
	var mission: MissionDef = _mission(FORD)
	_assert_near(_pair(mission.deploy), gen["DEPLOY"], "deploy")
	_assert_near(_pair(mission.camera_start), gen["CAMERA_START"], "camera")
	var villager: AiGroupSpec = _group(FORD, &"villager")
	_assert_near(_pair(villager.spawns), gen["VILLAGER_START"], "villager start")
	var route: Array = gen["ESCORT_WAYPOINTS"]
	assert_eq(villager.waypoints.size(), route.size() * 2, "the same number of waypoints")
	for k: int in route.size():
		_assert_near(_pair(villager.waypoints, k), route[k], "escort waypoint %d" % k)
	var pools: Array = gen["POOLS"]
	_assert_near(_pair(_group(FORD, &"pool_w").spawns), pools[0], "west pool")
	_assert_near(_pair(_group(FORD, &"pool_e").spawns), pools[1], "east pool")
	var landing: Vector2 = gen["LANDING_GUARD"]
	_assert_near(_pair(_group(FORD, &"landing").spawns), landing, "landing guard")
	var north: TriggerSpec = _trigger(FORD, &"north")
	_assert_near(Vector2i(north.area[0], north.area[1]), landing, "the north landing area")
	var gate: TriggerSpec = _trigger(FORD, &"home")
	_assert_near(Vector2i(gate.area[0], gate.area[1]), gen["GATE_AREA_CENTER"], "the gate area")
	assert_almost_eq(float(gate.area[2]) / M, float(gen["GATE_AREA_RADIUS_M"]), 0.5, "the gate area's radius")
	_assert_near(_pair(_group(FORD, &"rippers").spawns), gen["RIPPER_SPAWN"], "Ripper spawn")
	var drifters: AiGroupSpec = _group(FORD, &"drifters")
	var reaches: Array[Vector2] = []
	for reach: Vector2 in gen["DRIFTER_WEST"]:
		reaches.append(reach)
	for reach: Vector2 in gen["DRIFTER_EAST"]:
		reaches.append(reach)
	assert_eq(drifters.waypoints.size(), reaches.size() * 2)
	for k: int in reaches.size():
		_assert_near(_pair(drifters.waypoints, k), reaches[k], "Drifter waypoint %d" % k)
	# The ford: x is the generator's FORD_X_M, z is the river's centreline there.
	var crossing: TriggerSpec = _trigger(FORD, &"crossing")
	var ford_x: float = gen["FORD_X_M"]
	var centreline_z: float = float(gen["RIVER_Z_M"]) + float(gen["RIVER_SWING_M"]) * sin(TAU * ford_x / float(gen["RIVER_PERIOD_M"]))
	_assert_near(Vector2i(crossing.area[0], crossing.area[1]), Vector2(ford_x, centreline_z), "the ford's centre")


func test_old_mills_coordinates_match_the_generators_constants() -> void:
	var gen: Dictionary = _generators[MILL]
	var mission: MissionDef = _mission(MILL)
	_assert_near(_pair(mission.deploy), gen["DEPLOY"], "deploy")
	_assert_near(_pair(mission.camera_start), gen["CAMERA_START"], "camera")
	var overrun: TriggerSpec = _trigger(MILL, &"overrun")
	_assert_near(Vector2i(overrun.area[0], overrun.area[1]), gen["YARD_CENTER"], "the mill yard")
	assert_almost_eq(float(overrun.area[2]) / M, float(gen["YARD_RADIUS_M"]), 0.5, "the yard's radius")
	# The yard is open walkable ground (the map's own test says so too).
	var yard: Vector2 = gen["YARD_CENTER"]
	assert_true(_terrains[MILL].is_passable(roundi(yard.x) * M, roundi(yard.y) * M, LIVING))


# ---- the trigger chains can all fire, and each mission can be won and lost ----

## Which triggers can ever fire, as a fixpoint: a trigger needs the one in
## `after` to be able to fire, and its own condition to be possible: a
## GROUP_CLEARED or UNIT_DIES needs its groups spawnable (at start, or by a
## trigger that can fire), and enough units to die; a TRIGGERS_FIRED needs
## enough of its triggers able to fire. Areas, timers, and eliminations are
## assumed possible (the scripted runs below prove them on the real maps).
func _firable(rules: MissionScript, tier: int) -> Dictionary[StringName, bool]:
	var can: Dictionary[StringName, bool] = {}
	var spawnable: Dictionary[StringName, bool] = {}
	for group: AiGroupSpec in rules.groups:
		if group.spawn_at_start:
			spawnable[group.name] = true
	var changed: bool = true
	while changed:
		changed = false
		for t: TriggerSpec in rules.triggers:
			if can.has(t.name):
				continue
			if t.after != &"" and not can.has(t.after):
				continue
			if not _condition_possible(rules, t, tier, can, spawnable):
				continue
			can[t.name] = true
			changed = true
			for action: TriggerAction in t.actions:
				if action.kind == TriggerAction.Kind.SPAWN_GROUP:
					spawnable[action.group] = true
	return can


func _condition_possible(
	rules: MissionScript, t: TriggerSpec, tier: int, can: Dictionary[StringName, bool],
	spawnable: Dictionary[StringName, bool]
) -> bool:
	match t.condition:
		TriggerSpec.Condition.GROUP_CLEARED:
			for group_name: StringName in t.names:
				if not spawnable.has(group_name):
					return false
			return true
		TriggerSpec.Condition.UNIT_DIES:
			var deaths: int = 0
			for group_name: StringName in t.names:
				if not spawnable.has(group_name):
					return false
				deaths += rules.groups[rules.group_index(group_name)].unit_count(tier)
			return deaths >= t.count
		TriggerSpec.Condition.TRIGGERS_FIRED:
			var fired: int = 0
			for trigger_name: StringName in t.names:
				if can.has(trigger_name):
					fired += 1
			return fired >= t.min_count
	return true


func test_every_trigger_chain_can_fire_at_every_tier() -> void:
	for i: int in MISSION_IDS.size():
		for tier: int in Difficulty.TIERS:
			var can: Dictionary[StringName, bool] = _firable(_rules(i), tier)
			for t: TriggerSpec in _rules(i).triggers:
				assert_true(can.has(t.name), "%s tier %d: trigger %s can never fire" % [MISSION_IDS[i], tier, t.name])


func test_riverside_can_be_won_by_a_scripted_player() -> void:
	var world: World = _world(RIVERSIDE)
	while world.tick < SCRIPTED_LIMIT and world.mission.outcome == MissionRuntime.Outcome.NONE:
		if world.tick % 60 == 0 and world.tick > 0:
			_kill_dark(world)
		world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.WON)
	assert_gte(_fired(world, &"raid"), 0, "the raid came")
	assert_gt(_fired(world, &"win"), _fired(world, &"raid"), "and the win followed it")
	assert_eq(_objective_state(world, &"raid"), MissionRuntime.ObjectiveState.DONE)
	assert_eq(_objective_state(world, &"clear"), MissionRuntime.ObjectiveState.DONE)
	assert_gt(world.ai.groups_of(world.mission.mission_script.group_index(&"raiders")).size(), 0, "the raiders spawned")


func test_riverside_is_lost_when_the_squad_is_wiped_out() -> void:
	var world: World = _world(RIVERSIDE)
	world.step()
	for id: int in _soldiers(world):
		world.get_unit(id).kill()
	world.step()
	world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.LOST)
	assert_gte(_fired(world, &"lose"), 0)


func test_the_ford_can_be_won_by_walking_the_villager_to_the_gate() -> void:
	var world: World = _world(FORD)
	world.step()
	var soldiers: PackedInt32Array = _soldiers(world)
	while world.tick < SCRIPTED_LIMIT and world.mission.outcome == MissionRuntime.Outcome.NONE:
		if world.tick % 60 == 0:
			_kill_dark(world)
		if world.tick % 30 == 0:
			# The squad stays with the villager, so the escort keeps walking.
			for unit: Unit in world.units:
				if unit.type.id == &"villager" and unit.is_alive():
					world.enqueue(MoveUnitsCommand.new(world.tick, soldiers, unit.x, unit.z - 4000, Formations.Kind.LOOSE_LINE))
		world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.WON, "the villager reached the gate")
	for trigger_name: StringName in [&"crossing", &"north", &"flank", &"home"]:
		assert_gte(_fired(world, trigger_name), 0, "%s fired" % trigger_name)
	assert_gt(_fired(world, &"crossing"), 0)
	assert_gt(_fired(world, &"flank"), _fired(world, &"north"), "the Rippers came the tick after the landing")
	assert_eq(_objective_state(world, &"escort"), MissionRuntime.ObjectiveState.DONE)
	assert_eq(_objective_state(world, &"hold"), MissionRuntime.ObjectiveState.DONE)


func test_the_ford_is_lost_with_the_villager() -> void:
	var world: World = _world(FORD)
	world.step()
	for unit: Unit in world.units:
		if unit.type.id == &"villager":
			unit.kill()
	world.step()
	world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.LOST)
	assert_gte(_fired(world, &"villager_dead"), 0)
	assert_eq(_objective_state(world, &"escort"), MissionRuntime.ObjectiveState.FAILED)
	assert_eq(_fired(world, &"lose"), -1, "the squad itself is untouched")


func test_old_mill_can_be_won_wave_by_wave() -> void:
	var world: World = _world(MILL)
	var rules: MissionScript = world.mission.mission_script
	while world.tick < SCRIPTED_LIMIT and world.mission.outcome == MissionRuntime.Outcome.NONE:
		if world.tick % 60 == 0 and world.tick > 0:
			_kill_dark(world)
		world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.WON)
	var last: int = -1
	for wave: StringName in [&"w1", &"w2", &"w3", &"w4"]:
		assert_gt(_fired(world, wave), last, "%s fired, after the wave before it" % wave)
		last = _fired(world, wave)
	assert_gt(_fired(world, &"rain"), _fired(world, &"w3"), "the rain follows the third wave")
	assert_eq(world.weather.rain, 600, "and it is raining")
	assert_eq(_objective_state(world, &"hold"), MissionRuntime.ObjectiveState.DONE)
	assert_eq(_objective_state(world, &"waves"), MissionRuntime.ObjectiveState.DONE)
	# Exactly the four bound groups spawned.
	var spawned: int = 0
	for group_index: int in rules.groups.size():
		spawned += world.ai.groups_of(group_index).size()
	assert_eq(spawned, 4)


func test_old_mill_is_overrun_when_six_dark_units_hold_the_yard() -> void:
	var husk: int = _catalog.index_of(&"husk")
	var five: World = _world(MILL)
	var six: World = _world(MILL)
	for n: int in 6:
		if n < 5:
			five.spawn_unit(husk, DARK, 164000 + n * 1000, 157000, 0, 1)
		six.spawn_unit(husk, DARK, 164000 + n * 1000, 157000, 0, 1)
	for _t: int in 3:
		five.step()
		six.step()
	assert_eq(five.mission.outcome, MissionRuntime.Outcome.NONE, "five are not an overrun")
	assert_eq(six.mission.outcome, MissionRuntime.Outcome.LOST, "six are")
	assert_eq(_objective_state(six, &"hold"), MissionRuntime.ObjectiveState.FAILED)
	assert_gte(_fired(six, &"overrun"), 0)


func test_old_mills_first_wave_comes_at_the_tiers_timer_and_nothing_spawns_before_it() -> void:
	# Tier 4, the shortest timer (1200 ticks), so the run is short.
	var world: World = _world(MILL, 4)
	var at: int = Difficulty.pick(_trigger(MILL, &"w1").ticks, 4)
	assert_eq(at, 1200)
	for _t: int in at - 3:
		world.step()
	assert_eq(_spawned_groups(world), 0, "nothing spawns before the first wave")
	for _t: int in 6:
		world.step()
	assert_eq(_spawned_groups(world), 1, "wave 1 spawns at the tier's timer")


# ---- determinism ----

func test_two_campaign_worlds_of_each_mission_stay_identical_tick_for_tick() -> void:
	for i: int in MISSION_IDS.size():
		var a: World = _world(i)
		var b: World = _world(i)
		assert_eq(a.state_hash(), b.state_hash(), "%s starts identical" % MISSION_IDS[i])
		a.step()
		b.step()
		var ids: PackedInt32Array = _soldiers(a)
		assert_gt(ids.size(), 0, "%s has soldiers to command" % MISSION_IDS[i])
		assert_eq(ids, _soldiers(b))
		var target: Vector2i = _first_objective(i)
		a.enqueue(AttackMoveCommand.new(30, ids, target.x, target.y, Formations.Kind.LOOSE_LINE))
		b.enqueue(AttackMoveCommand.new(30, ids, target.x, target.y, Formations.Kind.LOOSE_LINE))
		while a.tick < DETERMINISM_TICKS:
			a.step()
			b.step()
			if a.tick % HASH_EVERY == 0:
				assert_eq(a.state_hash(), b.state_hash(), "%s: the hashes match at tick %d" % [MISSION_IDS[i], a.tick])
