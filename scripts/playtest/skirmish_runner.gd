class_name SkirmishRunner
extends RefCounted
## Plays one skirmish headless and says how it went: the skirmish playtest's
## counterpart of PlaytestRunner. The world is built exactly as the game builds
## one (a SkirmishSetup through SkirmishSetup.create_world, armies bought from
## the AI's own templates), stepped in a tight loop with no view. No Nodes: the
## tests drive it the same way scripts/skirmish_playtest.gd does.
##
## Two kinds of run, so one harness answers two questions:
## - Matrix A (pilot_kind NO_PILOT): a commander commands each side, Light too
##   (SkirmishSetup.player_is_ai). Which army templates beat which, on which
##   map and mode, from which start.
## - Matrix B (pilot_kind a PlaytestPilot.Kind): a Phase 8 pilot plays Light
##   through the command stream, as a person would, against the Dark
##   commander. How the AI fares against a player, and how a player's army
##   fares against the AI's.
##
## The pilot is sent where the mode says (route_for): it holds the hill in
## King of the Hill, takes every flag and goes back to hold the hill flag in
## Capture the Flags, and in Body Count walks to the middle of the map and
## hunts what it finds. It thinks every PlaytestPilot.THINK_TICKS, as it does
## in a campaign run.
##
## A skirmish decides itself at its time limit (SkirmishRuntime), so a run ends
## when it is decided; SAFETY_TICKS past the limit is a cap that should never
## be reached, and a run that reaches it is a TIMEOUT: a sim bug worth a look.

## `pilot_kind` for a run the commander plays on both sides (Matrix A).
const NO_PILOT: int = -1
## Game seconds past the time limit the run is let go on before it is called a
## timeout.
const SAFETY_TICKS: int = 60 * World.TICK_RATE
## How many of the units a timeout leaves are described in the notes.
const MAX_DESCRIBED: int = 8

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var catalog: UnitCatalog
var skirmish: SkirmishCatalog
## Print a status line every this many game seconds; 0 for never.
var trace_seconds: int = 0
## Keep the pilot's commands (PlaytestPilot.recorded), for the tests.
var record_commands: bool = false

var last_world: World
var last_pilot: PlaytestPilot


func _init(unit_catalog: UnitCatalog, skirmish_catalog: SkirmishCatalog) -> void:
	catalog = unit_catalog
	skirmish = skirmish_catalog


## Plays one skirmish to its end and returns the result; null if the world
## can't be built (an unknown map or template, an army the budget can't buy, a
## map that won't load: each said by push_error or printerr).
## - `map_id`, `mode`, `minutes`, `budget`: what the screen offers;
## - `light_template`, `dark_template`: the army templates, ids in the
##   SkirmishCatalog; each side is bought from its own for `budget`;
## - `light_start`: which of the map's starts Light has, 0 (A) or 1 (B), Dark
##   has the other;
## - `world_seed`: the world's RNG seed, which with the rest reproduces the run;
## - `pilot_kind`: a PlaytestPilot.Kind plays Light (Matrix B), or NO_PILOT.
func play(
	map_id: StringName, mode: SkirmishRules.Mode, minutes: int, budget: int, light_template: StringName,
	dark_template: StringName, light_start: int, world_seed: int, pilot_kind: int = NO_PILOT
) -> SkirmishResult:
	var setup: SkirmishSetup = make_setup(
		map_id, mode, minutes, budget, light_template, dark_template, light_start, world_seed,
		pilot_kind == NO_PILOT
	)
	if setup == null:
		return null
	var world: World = SkirmishSetup.create_world(setup, catalog)
	if world == null:
		return null
	var pilot: PlaytestPilot = null
	if pilot_kind != NO_PILOT:
		pilot = PlaytestPilot.new(pilot_kind as PlaytestPilot.Kind, null)
		pilot.record = record_commands
		pilot.set_route(route_for(setup, world), holds_at_end(mode))
	var cap: int = world.skirmish.start_tick + setup.rules.time_limit_ticks + SAFETY_TICKS
	var started_us: int = Time.get_ticks_usec()
	while not world.skirmish.is_decided() and world.tick < cap:
		# The deploy applies on the first step; the pilot looks at the squad after it.
		if pilot != null and (world.tick == 1 or world.tick % PlaytestPilot.THINK_TICKS == 0):
			pilot.think(world)
		world.step()
		if trace_seconds > 0 and world.tick % (trace_seconds * World.TICK_RATE) == 0:
			print("    " + trace_line(world, pilot))
	var result: SkirmishResult = summarize(setup, world, pilot, light_template)
	result.wall_ms = roundi((Time.get_ticks_usec() - started_us) / 1000.0)
	last_world = world
	last_pilot = pilot
	return result


## Lets go of the last run's world and pilot.
func release() -> void:
	last_world = null
	last_pilot = null


## The setup a run is played from; null, after a push_error, for a map or a
## template the catalog doesn't have. Light is the player's side, so
## armies[0] is Light's; `both_ai` has the commander play Light too.
func make_setup(
	map_id: StringName, mode: SkirmishRules.Mode, minutes: int, budget: int, light_template: StringName,
	dark_template: StringName, light_start: int, world_seed: int, both_ai: bool
) -> SkirmishSetup:
	var map: SkirmishMap = skirmish.skirmish_map(map_id)
	var light: ArmyTemplate = skirmish.template(light_template)
	var dark: ArmyTemplate = skirmish.template(dark_template)
	if map == null or light == null or dark == null:
		push_error("SkirmishRunner: no map %s, or no template %s or %s" % [map_id, light_template, dark_template])
		return null
	if light.faction != LIGHT or dark.faction != DARK:
		push_error("SkirmishRunner: %s must be a Light template and %s a Dark one" % [light_template, dark_template])
		return null
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = map
	setup.rules = SkirmishRules.for_map(map, mode, minutes, LIGHT)
	setup.budget = budget
	setup.armies = [light.fill(budget, catalog), dark.fill(budget, catalog)]
	setup.player_spawn = light_start
	setup.ai_template_id = dark_template
	setup.world_seed = world_seed
	setup.player_is_ai = both_ai
	return setup


## Where the pilot goes for this setup's mode, in milli-units, each point
## snapped to ground a living soldier can reach from its start:
## - King of the Hill: the hill;
## - Capture the Flags: every flag, nearest to the pilot's start first (as the
##   crow flies), then the hill flag again if it wasn't the last;
## - Body Count: the middle of the two starts.
static func route_for(setup: SkirmishSetup, world: World) -> Array[Vector2i]:
	var map: SkirmishMap = setup.map
	var from: Vector2i = map.spawn(setup.player_spawn)
	var points: Array[Vector2i] = []
	match setup.rules.mode:
		SkirmishRules.Mode.KING_OF_THE_HILL:
			points.append(map.flag(map.hill))
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			var order: Array[int] = []
			for i: int in map.flag_count():
				order.append(i)
			order.sort_custom(func(a: int, b: int) -> bool:
				var da: int = (map.flag(a) - from).length_squared()
				var db: int = (map.flag(b) - from).length_squared()
				return da < db or (da == db and a < b))
			for i: int in order:
				points.append(map.flag(i))
			if order[order.size() - 1] != map.hill:
				points.append(map.flag(map.hill))
		_:
			var other: Vector2i = map.spawn(1 - setup.player_spawn)
			points.append(Vector2i(floor_div(from.x + other.x, 2), floor_div(from.y + other.y, 2)))
	var component: int = world.pathing.component_at(from.x, from.y, Terrain.Mobility.LIVING)
	for i: int in points.size():
		points[i] = world.pathing.snap_to_component(points[i].x, points[i].y, Terrain.Mobility.LIVING, component)
	return points


## True if the pilot holds the last point of its route (the modes with ground
## to hold), false if it hunts from there (Body Count).
static func holds_at_end(mode: SkirmishRules.Mode) -> bool:
	return mode != SkirmishRules.Mode.BODY_COUNT


## `a` over `b`, rounded down (for non-negative values): the whole seconds and
## minutes a result reports, where the dropped remainder is no loss. The one
## place the integer division is allowed, so that the warning stays on elsewhere.
static func floor_div(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	return a / b


## "light", "dark", "draw" for a SkirmishRuntime.winner, "timeout" for a skirmish
## still undecided (SkirmishRuntime.NO_SIDE).
static func winner_name(winner: int) -> String:
	if winner == LIGHT:
		return SkirmishResult.LIGHT
	if winner == DARK:
		return SkirmishResult.DARK
	if winner == SkirmishRuntime.DRAW:
		return SkirmishResult.DRAW
	return SkirmishResult.TIMEOUT


## "time" or "elimination" for how a skirmish was decided, "" if it wasn't.
static func reason_name(reason: SkirmishRuntime.EndReason) -> String:
	match reason:
		SkirmishRuntime.EndReason.TIME:
			return SkirmishResult.REASON_TIME
		SkirmishRuntime.EndReason.ELIMINATION:
			return SkirmishResult.REASON_ELIMINATION
	return ""


## The status line a trace prints: the time, who is alive on each side, each
## side's score in every mode, and the pilot's place on its route.
static func trace_line(world: World, pilot: PlaytestPilot) -> String:
	var s: SkirmishRuntime = world.skirmish
	var text: String = "t=%ds alive %d-%d | kills %d-%d | hold %d-%d s | flags %d-%d" % [
		roundi(world.tick / float(World.TICK_RATE)), s.alive[LIGHT], s.alive[DARK], s.deaths[DARK], s.deaths[LIGHT],
		floor_div(s.hold_ticks[LIGHT], World.TICK_RATE), floor_div(s.hold_ticks[DARK], World.TICK_RATE),
		s.flags_owned(LIGHT), s.flags_owned(DARK),
	]
	if pilot != null:
		text += " | route %d" % pilot.route_index
	return text


## What a world came to, as a result without its wall-clock time: the setup it
## was built from, the pilot that played Light (null when the commander did),
## and the id of the template Light's army was bought from (the setup keeps
## only the AI's). A world not yet decided summarizes as a timeout.
func summarize(
	setup: SkirmishSetup, world: World, pilot: PlaytestPilot, light_template: StringName
) -> SkirmishResult:
	var s: SkirmishRuntime = world.skirmish
	var r: SkirmishResult = SkirmishResult.new()
	r.matrix = SkirmishResult.MATRIX_A if pilot == null else SkirmishResult.MATRIX_B
	r.map_id = setup.map.id
	r.mode = String(SkirmishRules.Mode.keys()[setup.rules.mode]).to_lower()
	r.minutes = floor_div(setup.rules.time_limit_ticks, 60 * World.TICK_RATE)
	r.budget = setup.budget
	r.light_template = light_template
	r.dark_template = setup.ai_template_id
	r.light_start = setup.player_spawn
	r.world_seed = setup.world_seed
	r.pilot = SkirmishResult.AI if pilot == null else PlaytestPilot.kind_name(pilot.kind)
	r.winner = winner_name(s.winner)
	r.end_reason = reason_name(s.end_reason)
	r.end_tick = world.tick if s.end_tick < 0 else s.end_tick
	r.light_deployed = s.roster_ids[LIGHT].size()
	r.dark_deployed = s.roster_ids[DARK].size()
	r.light_alive = s.alive[LIGHT]
	r.dark_alive = s.alive[DARK]
	r.light_kills = s.deaths[DARK]
	r.dark_kills = s.deaths[LIGHT]
	r.light_hold_s = floor_div(s.hold_ticks[LIGHT], World.TICK_RATE)
	r.dark_hold_s = floor_div(s.hold_ticks[DARK], World.TICK_RATE)
	r.light_flags = s.flags_owned(LIGHT)
	r.dark_flags = s.flags_owned(DARK)
	r.light_owned_s = floor_div(s.owned_ticks[LIGHT], World.TICK_RATE)
	r.dark_owned_s = floor_div(s.owned_ticks[DARK], World.TICK_RATE)
	r.commands = 0 if pilot == null else pilot.commands_issued
	r.state_hash = world.state_hash()
	if r.winner == SkirmishResult.TIMEOUT:
		_note_timeout(r, world)
	return r


# Says what a run that was never decided left behind.
func _note_timeout(r: SkirmishResult, world: World) -> void:
	r.notes.append("timeout at tick %d with %d Light and %d Dark alive" % [world.tick, r.light_alive, r.dark_alive])
	var described: int = 0
	for unit: Unit in world.units:
		if described >= MAX_DESCRIBED:
			break
		if unit.is_alive():
			r.notes.append("left: " + PlaytestRunner.describe(world, unit))
			described += 1
