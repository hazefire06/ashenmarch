class_name PlaytestRunner
extends RefCounted
## Plays one campaign mission headless with a PlaytestPilot, and says how it
## went. The world is built exactly as the game builds one (a CampaignState's
## plan_deploy and mission_seed, then MissionSetup.create_world), stepped in a
## tight loop with no view, with MissionStats watching as the results screen's
## numbers do. No Nodes: the tests drive it the same way scripts/playtest.gd
## does.
##
## After play() the world, the plan and the stats it used stay in last_world,
## last_plan and last_stats, so a campaign run can apply a victory
## (CampaignState.apply_victory) exactly as the App does; release() lets them
## go.

## A loss this early (ticks: one minute) is called instant in the notes.
const INSTANT_TICKS: int = 60 * World.TICK_RATE
## How many of the Dark units a timeout leaves are described in the notes.
const MAX_DESCRIBED: int = 8
## A unit that has walked this many ticks (4 s) without getting nearer its
## waypoint is called stuck. The sim gives such a unit's order up at 180
## (UnitMovement.GIVE_UP_TICKS), and the runner looks every 30, so this catches
## each one at least twice.
const STUCK_TICKS: int = 120
## ...if it is also more than this far (milli-units) from the goal it was sent
## to: a unit waiting its turn for a crowded slot is a couple of meters off and
## no pathing fault, and a patrol or a formation does that every time it stops.
const STUCK_FAR: int = 4000
## How many stuck units a run describes in its notes.
const MAX_STUCK_NOTED: int = 4

var catalog: UnitCatalog
## The campaign's soldier names, so recruits are named as the game names them.
var names: PackedStringArray
## Keep the pilot's commands (PlaytestPilot.recorded), for the tests.
var record_commands: bool = false
## Print a status line (who is alive on each side, where the squad is) every
## this many game seconds; 0 for never. For finding out why a run went as it did.
var trace_seconds: int = 0

var last_world: World
var last_plan: DeployPlan
var last_stats: MissionStats
var last_pilot: PlaytestPilot


func _init(unit_catalog: UnitCatalog, soldier_names: PackedStringArray) -> void:
	catalog = unit_catalog
	names = soldier_names


## Plays `mission` (the campaign's mission number `index`) from `state` at the
## state's tier, for at most `max_ticks`, and returns the result; null if the
## world can't be built. `state` is only read: the deploy is its plan_deploy
## (veterans first, recruits for the rest) and the world's seed its
## mission_seed(index), which is what the App would use.
func play(
	mission: MissionDef, index: int, state: CampaignState, pilot_kind: PlaytestPilot.Kind,
	max_ticks: int, chain: bool = false
) -> PlaytestResult:
	var started_us: int = Time.get_ticks_usec()
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), names)
	var world_seed: int = state.mission_seed(index)
	var world: World = MissionSetup.create_world(
		mission, state.tier, world_seed, plan.command(0, mission), catalog
	)
	if world == null:
		return null
	var pilot: PlaytestPilot = PlaytestPilot.new(pilot_kind, mission)
	pilot.record = record_commands
	var stats: MissionStats = MissionStats.new()
	var result: PlaytestResult = PlaytestResult.new()
	var stuck: Dictionary[int, bool] = {}
	# The deploy applies on the first step; the pilot looks at the squad after it.
	world.step()
	stats.begin(world)
	stats.observe(world)
	# The AI-led Light units (The Ford's villager) exist after it too: watched.
	var wards: Array[Unit] = []
	for unit: Unit in world.units:
		if unit.faction == UnitType.Faction.LIGHT and world.ai.controls(unit.id):
			wards.append(unit)
	while world.mission.outcome == MissionRuntime.Outcome.NONE and world.tick < max_ticks:
		if world.tick == 1 or world.tick % PlaytestPilot.THINK_TICKS == 0:
			_watch_for_stuck_units(world, result, stuck)
			pilot.think(world)
		world.step()
		stats.observe(world)
		_watch_the_villager(world, result, wards)
		for event: AiEvent in world.ai_events:
			if event.kind == AiEvent.Kind.AMBUSH_SPRUNG:
				result.ambushes_sprung += 1
		if trace_seconds > 0 and world.tick % (trace_seconds * World.TICK_RATE) == 0:
			print("    " + trace_line(world, pilot))
	stats.finish(world)
	_fill(result, mission, state, pilot, world, plan, stats, world_seed, chain)
	result.wall_ms = roundi((Time.get_ticks_usec() - started_us) / 1000.0)
	last_world = world
	last_plan = plan
	last_stats = stats
	last_pilot = pilot
	return result


## Lets go of the last run's world, plan, stats and pilot.
func release() -> void:
	last_world = null
	last_plan = null
	last_stats = null
	last_pilot = null


# Counts each unit once that is walking and hasn't got nearer its waypoint for
# STUCK_TICKS, and describes the first few.
func _watch_for_stuck_units(world: World, result: PlaytestResult, seen: Dictionary[int, bool]) -> void:
	for unit: Unit in world.units:
		if not unit.is_alive() or unit.state != Unit.State.MOVING or unit.stuck_ticks < STUCK_TICKS or seen.has(unit.id):
			continue
		if FixedMath.length(unit.goal_x - unit.x, unit.goal_z - unit.z) <= STUCK_FAR:
			continue
		seen[unit.id] = true
		result.stuck_units += 1
		if result.stuck_units <= MAX_STUCK_NOTED:
			result.notes.append("stuck at tick %d: %s" % [world.tick, describe(world, unit)])


# Notes how low the escorted villager's hit points got, and what killed him
# (from the step's KILL events).
func _watch_the_villager(world: World, result: PlaytestResult, wards: Array[Unit]) -> void:
	for unit: Unit in wards:
		result.villager_lowest_percent = mini(
			result.villager_lowest_percent, roundi(100.0 * unit.hp / unit.type.max_hp)
		)
	for event: CombatEvent in world.combat_events:
		if event.kind != CombatEvent.Kind.KILL:
			continue
		var victim: Unit = world.get_unit(event.target_id)
		if victim == null or victim.faction != UnitType.Faction.LIGHT or not world.ai.controls(victim.id):
			continue
		var killer: Unit = world.get_unit(event.attacker_id)
		result.villager_died = true
		if killer == null:
			result.villager_killer = "a stray blast or fire"
		elif killer.faction == UnitType.Faction.LIGHT:
			result.villager_killer = "friendly fire (%s)" % killer.type.id
		else:
			result.villager_killer = String(killer.type.id)


func _fill(
	result: PlaytestResult, mission: MissionDef, state: CampaignState, pilot: PlaytestPilot,
	world: World, plan: DeployPlan, stats: MissionStats, world_seed: int, chain: bool
) -> void:
	result.mission_id = mission.id
	result.tier = state.tier
	result.pilot = PlaytestPilot.kind_name(pilot.kind)
	result.campaign_seed = state.campaign_seed
	result.world_seed = world_seed
	result.chain = chain
	result.outcome = outcome_label(world.mission.outcome)
	result.end_tick = world.tick
	result.roster = plan.size()
	result.losses = stats.lost.size()
	result.friendly_fire = stats.friendly_fire.size()
	result.kills = stats.enemies_killed()
	result.commands = pilot.commands_issued
	result.charges_done_tick = pilot.charges_done_tick
	result.stall_breaks = pilot.stall_breaks
	result.state_hash = world.state_hash()
	var alive: Array[Unit] = []
	for unit: Unit in world.units:
		if unit.faction == UnitType.Faction.DARK and unit.is_alive():
			alive.append(unit)
	result.dark_alive = alive.size()
	for unit: Unit in alive:
		var group_name: String = String(group_of(world, unit)).trim_prefix("wave_")
		if group_name != "" and not result.alive_groups.has(group_name):
			result.alive_groups.append(group_name)
	_fill_waves(result, world)
	_fill_notes(result, world, alive)


# Old Mill's draw: which wave group each of waves 1 to 4 is, and how many have
# spawned (their `w1`..`w4` triggers have fired).
func _fill_waves(result: PlaytestResult, world: World) -> void:
	var script: MissionScript = world.mission.mission_script
	for bound: int in world.mission.bindings:
		result.waves.append(String(script.groups[bound].name).trim_prefix("wave_"))
	if result.waves.is_empty():
		return
	for k: int in range(1, result.waves.size() + 1):
		var at: int = script.trigger_index(StringName("w%d" % k))
		if at >= 0 and world.mission.fired_tick[at] >= 0:
			result.waves_spawned += 1


func _fill_notes(result: PlaytestResult, world: World, alive: Array[Unit]) -> void:
	if result.outcome == PlaytestResult.LOST and result.end_tick <= INSTANT_TICKS:
		result.notes.append("instant loss at tick %d" % result.end_tick)
	if result.outcome != PlaytestResult.TIMEOUT:
		return
	result.notes.append("timeout with %d Dark alive and %d of %d soldiers lost" % [
		alive.size(), result.losses, result.roster,
	])
	for i: int in mini(MAX_DESCRIBED, alive.size()):
		result.notes.append("left: " + describe(world, alive[i]))


## The label a mission's outcome goes by in a result: WON, LOST or DRAW (neither
## side won: a skirmish level at its limit), and TIMEOUT for a run that was never
## decided.
static func outcome_label(outcome: MissionRuntime.Outcome) -> String:
	match outcome:
		MissionRuntime.Outcome.WON:
			return PlaytestResult.WON
		MissionRuntime.Outcome.LOST:
			return PlaytestResult.LOST
		MissionRuntime.Outcome.DRAW:
			return PlaytestResult.DRAW
	return PlaytestResult.TIMEOUT


## The status line a trace prints: the time, the squad's centre and the pilot's
## place on its route, and who is alive on each side by type.
static func trace_line(world: World, pilot: PlaytestPilot) -> String:
	var light: Dictionary[String, int] = {}
	var dark: Dictionary[String, int] = {}
	var centre: Vector2 = Vector2.ZERO
	var soldiers: int = 0
	for unit: Unit in world.units:
		if not unit.is_alive():
			continue
		if unit.faction == UnitType.Faction.LIGHT:
			light[String(unit.type.id)] = light.get(String(unit.type.id), 0) + 1
			if not world.ai.controls(unit.id):
				centre += Vector2(unit.x, unit.z) / 1000.0
				soldiers += 1
		else:
			dark[String(unit.type.id)] = dark.get(String(unit.type.id), 0) + 1
	if soldiers > 0:
		centre /= soldiers
	return "t=%ds route %d at (%.0f, %.0f) | light %s | dark %s" % [
		roundi(world.tick / float(World.TICK_RATE)), pilot.route_index, centre.x, centre.y, light, dark,
	]


## The name of the AI group a unit belongs to, or &"" for none.
static func group_of(world: World, unit: Unit) -> StringName:
	for group: AiGroup in world.ai.groups:
		if group.members.has(unit.id):
			return group.spec.name
	return &""


## One line on where a unit stands and what it is doing: type and id, place in
## meters, the water under it and whether that hides it, its state and order,
## and the AI group it belongs to with that group's behavior.
static func describe(world: World, unit: Unit) -> String:
	var group_text: String = "no group"
	for group: AiGroup in world.ai.groups:
		if group.members.has(unit.id):
			group_text = "%s/%s" % [group.spec.name, AiGroupSpec.Behavior.keys()[group.behavior]]
			break
	return "%s #%d at (%.0f, %.0f) m, water %d%s, %s, order %s, group %s" % [
		unit.type.id, unit.id, unit.x / 1000.0, unit.z / 1000.0, world.terrain.water_depth_at(unit.x, unit.z),
		" (submerged)" if Visibility.is_submerged(world.terrain, unit) else "",
		Unit.State.keys()[unit.state], Unit.Order.keys()[unit.order], group_text,
	]
