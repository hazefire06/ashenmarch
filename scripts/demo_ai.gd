extends SceneTree
## Phase 7 showcase: `make demo-ai` (DEMO_SPEED=2 to run faster).
##
## Runs the real game and stages the enemy AI on Riverside, one behavior after
## another, each with a caption and a live tally. The F7 overlay is on for the
## whole demo: a label over each group says what it is doing, and the lines and
## rings show where (cyan: a patrol's loop, red: an ambush's alert radius,
## orange: a guard's radius, magenta: a flank's route, blue: a retreat).
## 1. Patrol: Husks walk a loop of waypoints until Shieldmen come near.
## 2. Ambush: Husks lie submerged by the ford and spring on the Shieldmen
##    crossing it.
## 3. Flank: Rippers go round the end of a Shieldman line to reach the Wardens
##    behind it.
## 4. Standoff: a Stormcaller holds at range behind Husk bodyguards, steps
##    out of reach, and keeps casting while Reavers charge and chase it.
## 5. Cluster: Blightbags walk past a straggler into the densest knot of
##    Shieldmen.
## 6. Retreat: Rippers that are losing badly fall back, once.
## 7. Finale: a mission script's triggers set the objective, spawn the Dark
##    line, bring reinforcements and rain, and end in Victory.
## When it ends the game is yours.
##
## DEMO_STAGE=<n> runs stage n alone. DEMO_CAPTURE=<dir> saves a screenshot at
## each result and quits at the end.
##
## The Light side is driven through sim commands, exactly like player input.
## Every wait counts sim ticks, never wall-clock time, and each stage starts on
## a whole second of ticks, so every run plays out the same and the result lines
## are the same on every machine. The Dark side is the AI: stages 1 to 6 spawn each group from a spec
## (AiDirector.spawn_group) and switch behaviors with AiDirector.set_behavior;
## the finale is driven by the demo's MissionScript triggers. MainView's own
## Riverside mission is switched off (MainView.mission_path) and the demo
## starts its own before the first step. MainView also spawns the Light test
## squads at tick 0; the demo removes them, so nothing else is on the field
## for the AI to hunt.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const STAGES: int = 7
## The middle difficulty tier, as the game plays it.
const TIER: int = 2
const READ_BEFORE: float = 4.0
const READ_AFTER: float = 5.0
## A stage that hasn't ended by then (sim seconds) moves on anyway.
const FIGHT_TIMEOUT: float = 60.0
const FINALE_TIMEOUT: float = 150.0
## How often (sim seconds) idle Reavers are sent after the Stormcaller.
const CHASE_SECONDS: float = 2.0
## Yaw 0 looks north; a half turn looks south.
const LOOK_NORTH: float = 0.0
const LOOK_SOUTH: float = PI
## Pixels from the top of the screen to the caption: below the mission
## objective, which sits under the stats label.
const CAPTION_TOP: float = 104.0

## The demo's groups, in the order of its MissionScript.
enum Group { PATROL, AMBUSH, FLANKERS, CASTER, BAGS, RAIDERS, WAVE_ONE, WAVE_TWO }

## Where the finale's Light squad spawns, and how close to it counts as
## entering the area that starts the finale (meters). No other stage puts a
## Light unit there.
const STAGING: Vector2 = Vector2(322.0, 190.0)
const STAGING_RADIUS: float = 10.0
## The finale's reinforcements come this many seconds after it starts.
const REINFORCE_SECONDS: int = 25

var _main: MainView
var _world: World
var _camera: RtsCamera
var _caption: Label
var _tally: Label
var _mission_script: MissionScript
var _last_tick: int = -1
var _capture_dir: String = OS.get_environment("DEMO_CAPTURE")
var _only: int = int(OS.get_environment("DEMO_STAGE"))
var _stage: int = 0
## This stage's counts, by name.
var _counts: Dictionary[String, int] = {}
## The tick each named moment first happened this stage.
var _first: Dictionary[String, int] = {}
## Units this stage spawned, which the tally watches and the next stage
## removes.
var _watched: Dictionary[int, bool] = {}
## Where blasts went off this stage, in meters.
var _bursts: PackedVector2Array = PackedVector2Array()
## Units in the ambush that surfaced when it sprang.
var _surfaced: int = 0
## Ripper swings this stage, by the type of unit swung at.
var _swings: Dictionary[StringName, int] = {}
## Ids of the units whose swings _swings counts.
var _swingers: Dictionary[int, bool] = {}


func _initialize() -> void:
	var speed: String = OS.get_environment("DEMO_SPEED")
	Engine.time_scale = float(speed) if speed.is_valid_float() and float(speed) > 0.0 else 1.0
	# Lets the sim keep up at DEMO_SPEED > 1 instead of slowing down.
	Engine.max_physics_steps_per_frame = 16
	_main = load("res://view/main.tscn").instantiate() as MainView
	# No mission of the game's own: the demo starts its own.
	_main.mission_path = ""
	root.add_child(_main)
	# MainView builds its world in _ready, which has not run yet, and steps it
	# in _physics_process, which comes after: start the mission in between.
	if _main.is_node_ready():
		_start_mission()
	else:
		_main.ready.connect(_start_mission)
	_run.call_deferred()


func _physics_process(_delta: float) -> bool:
	if _world == null or _world.tick == _last_tick:
		return false
	# Each tick's events stay in the World until the next step, so reading
	# them once per new tick sees every event exactly once.
	_last_tick = _world.tick
	for event: AiEvent in _world.ai_events:
		_note_ai(event)
	for event: MissionEvent in _world.mission_events:
		_note_mission(event)
	for event: ProjectileEvent in _world.projectile_events:
		if event.kind == ProjectileEvent.Kind.BOLT:
			_bump("bolt")
		elif event.kind == ProjectileEvent.Kind.EXPLODE:
			_bump("burst")
			_bursts.append(Vector2(event.x / float(M), event.z / float(M)))
	for event: CombatEvent in _world.combat_events:
		if event.kind == CombatEvent.Kind.KILL and _watched.has(event.target_id):
			_bump("killed")
		elif event.kind == CombatEvent.Kind.SWING and _swingers.has(event.attacker_id):
			_stamp("strike")
			var target: Unit = _world.get_unit(event.target_id)
			if target != null:
				_swings[target.type.id] = _swings.get(target.type.id, 0) + 1
	_refresh_tally()
	return false


func _run() -> void:
	await process_frame
	_world = _main.world
	_camera = _main.get_node("CameraRig") as RtsCamera
	_build_labels()
	(_main.get_node("AiDebug") as AiDebugView).toggle()
	await _clear_the_field()
	if _runs(1):
		await _patrol()
	if _runs(2):
		await _ambush()
	if _runs(3):
		await _flank()
	if _runs(4):
		await _standoff()
	if _runs(5):
		await _cluster()
	if _runs(6):
		await _retreat()
	if _runs(7):
		await _finale()
	Engine.time_scale = 1.0
	if not _capture_dir.is_empty():
		quit()
		return
	_caption.text = "Demo over. You have control. F7 shows or hides the AI overlay. F9 switches the side you command; the Dark groups keep thinking either way."
	_tally.text = ""


func _runs(stage: int) -> bool:
	return _only == 0 or _only == stage


# --- the stages ---


func _patrol() -> void:
	var c: Vector2 = Vector2(318.0, 262.0)
	await _begin(1, "Patrol", "5 Husks walk a loop of waypoints (cyan), fighting what they meet and walking on. Any Light unit within 12 m of one of them (the alert radius) turns the patrol into a hunt. After 2 legs, 4 Shieldmen come up from the south.", c + Vector2(0.0, 6.0), LOOK_NORTH, 46.0)
	var patrol: AiGroup = _spawn_group(Group.PATROL)
	var t0: int = _world.tick
	await _until(func() -> bool: return _n("waypoint") >= 3, FIGHT_TIMEOUT)
	var walked: float = _since(t0)
	var scouts: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _grid(c + Vector2(0.0, 36.0), 2, 2, 1.6), Vector2i(0, -1))
	_attack_move(scouts, c + Vector2(0.0, 2.0), Formations.Kind.SHORT_LINE)
	var t1: int = _world.tick
	await _until(func() -> bool: return _first.has("hunt"), FIGHT_TIMEOUT)
	var spotted: float = _since(t1)
	await _until(func() -> bool: return _alive(scouts) == 0 or _alive(patrol.spawned_ids) == 0, FIGHT_TIMEOUT)
	_result("The patrol reached %d waypoints in %.0f s. It spotted the Shieldmen %.0f s after they set out and switched to %s. Then: Shieldmen %d/4, Husks %d/5." % [
		_n("waypoint"), walked, spotted, AiGroupSpec.Behavior.find_key(patrol.behavior), _alive(scouts), _alive(patrol.spawned_ids)
	])
	await _wait_sim(READ_AFTER)


func _ambush() -> void:
	var c: Vector2 = Vector2(296.0, 222.0)
	await _begin(2, "Ambush", "6 Husks lie submerged in depth-3 water west of the ford: unseen, and nothing can hit them. The red ring is the ambush's alert radius. 8 Shieldmen cross the ford. The first one inside the ring springs it: the Husks surface for good and hunt.", c + Vector2(0.0, -4.0), LOOK_SOUTH, 50.0)
	var ambush: AiGroup = _spawn_group(Group.AMBUSH)
	var shieldmen: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _grid(Vector2(302.0, 198.0), 4, 2, 1.6), Vector2i(0, 1))
	await _wait_sim(READ_BEFORE)
	_attack_move(shieldmen, Vector2(300.0, 252.0), Formations.Kind.BOX)
	var t0: int = _world.tick
	await _until(func() -> bool: return _first.has("sprung"), FIGHT_TIMEOUT)
	var sprang: float = _since(t0)
	await _until(func() -> bool: return _alive(shieldmen) == 0 or _alive(ambush.spawned_ids) == 0, FIGHT_TIMEOUT)
	_result("Sprang %.1f s after the Shieldmen set out, as the first of them reached the ford; %d/6 Husks surfaced. Then: Shieldmen %d/8, Husks %d/6." % [
		sprang, _surfaced, _alive(shieldmen), _alive(ambush.spawned_ids)
	])
	await _wait_sim(READ_AFTER)


func _flank() -> void:
	var c: Vector2 = Vector2(392.0, 122.0)
	await _begin(3, "Flank", "5 Rippers prefer ranged and support units: here, 3 Wardens. 8 Shieldmen stand in front of them, so the Rippers don't charge the line: they plan a route round its end (magenta), walk it with plain moves so nothing on the way stops them, and strike the Wardens from the side.", c + Vector2(0.0, 18.0), LOOK_NORTH, 56.0)
	var screen: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c, 8, 1.6), Vector2i(0, 1))
	var wardens: PackedInt32Array = await _spawn(&"warden", LIGHT, _row(c + Vector2(0.0, -6.0), 3, 2.0), Vector2i(0, 1))
	await _wait_sim(READ_BEFORE)
	var raiders: AiGroup = _spawn_group(Group.FLANKERS)
	for unit_id: int in raiders.spawned_ids:
		_swingers[unit_id] = true
	var t0: int = _world.tick
	await _until(func() -> bool: return _alive(wardens) == 0 or _alive(raiders.spawned_ids) == 0, FIGHT_TIMEOUT)
	_result("The Rippers planned a %d-waypoint route round the line and struck %.0f s after setting out. Ripper swings: %d at Wardens, %d at Shieldmen. Then: Wardens %d/3, Shieldmen %d/8, Rippers %d/5." % [
		_n("flank waypoint"), _since(t0, "strike"), _swings.get(&"warden", 0), _swings.get(&"shieldman", 0),
		_alive(wardens), _alive(screen), _alive(raiders.spawned_ids)
	])
	await _wait_sim(READ_AFTER)


func _standoff() -> void:
	var c: Vector2 = Vector2(110.0, 160.0)
	await _begin(4, "Standoff", "A Stormcaller can't cast inside 8 m, so it stands off at 36 m, at a spot where its line is clear of its own side, and walks to a new one when that stops being true. 6 Husks guard it and go out to meet whatever comes near. 6 Reavers charge it from 40 m, spread wide so one bolt can't take them all, and chase it when they have nothing else to do.", c + Vector2(0.0, 22.0), LOOK_NORTH, 60.0)
	var guards: AiGroup = _spawn_group(Group.CASTER)
	var caster: int = _first_of(guards, &"stormcaller")
	await _wait_sim(READ_BEFORE)
	var reavers: PackedInt32Array = await _spawn(&"reaver", LIGHT, _row(c + Vector2(0.0, 40.0), 6, 6.0), Vector2i(0, -1))
	var t0: int = _world.tick
	while _world.tick - t0 < roundi(FIGHT_TIMEOUT * World.TICK_RATE):
		# A Reaver that has run out of orders goes for the Stormcaller wherever
		# it has got to, as a player would send it. One that is fighting or
		# still walking keeps at it: a new order drops a swing.
		if (_world.tick - t0) % roundi(CHASE_SECONDS * World.TICK_RATE) == 0:
			_chase(reavers, caster)
		await physics_frame
		if _alive(reavers) == 0 or _alive(PackedInt32Array([caster])) == 0:
			break
	var caster_alive: bool = _alive(PackedInt32Array([caster])) > 0
	_result("The Stormcaller cast %d bolts and moved to a new firing spot %d times. After %.0f s: Stormcaller %s, Husks %d/6, Reavers %d/6." % [
		_n("bolt"), _n("standoff move"), _since(t0), "alive" if caster_alive else "dead",
		_alive(guards.spawned_ids) - (1 if caster_alive else 0), _alive(reavers)
	])
	await _wait_sim(READ_AFTER)


func _cluster() -> void:
	var c: Vector2 = Vector2(150.0, 400.0)
	var straggler_at: Vector2 = c + Vector2(15.0, 15.0)
	await _begin(5, "Cluster", "A Blightbag goes for the thickest knot of enemies, not the nearest one, and doesn't stop for anything on the way. 3 Blightbags start 30 m from 10 Shieldmen packed together, with a straggler off to the side that is nearer to them. They walk past it into the knot and burst there.", c + Vector2(6.0, 14.0), LOOK_NORTH, 52.0)
	var knot: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _grid(c, 5, 2, 1.4), Vector2i(0, 1))
	var straggler: PackedInt32Array = await _spawn(&"shieldman", LIGHT, [straggler_at], Vector2i(0, 1))
	var bags: AiGroup = _spawn_group(Group.BAGS)
	await _wait_sim(READ_BEFORE)
	_world.ai.set_behavior(_world, bags, AiGroupSpec.Behavior.HUNT)
	var t0: int = _world.tick
	await _until(func() -> bool: return _alive(bags.spawned_ids) == 0, FIGHT_TIMEOUT)
	await _wait_sim(6.0)
	var knot_burst: float = INF
	var straggler_burst: float = INF
	for at: Vector2 in _bursts:
		knot_burst = minf(knot_burst, at.distance_to(c))
		straggler_burst = minf(straggler_burst, at.distance_to(straggler_at))
	_result("%d/3 Blightbags burst, the nearest blast %.1f m from the knot's middle and %.1f m from the straggler, which they passed on the way. After %.0f s: %d of the knot killed, %d paralyzed; the straggler is untouched (%d/1)." % [
		3 - _alive(bags.spawned_ids), knot_burst, straggler_burst, _since(t0), 10 - _alive(knot), _paralyzed(knot), _alive(straggler)
	])
	await _wait_sim(READ_AFTER)


func _retreat() -> void:
	var c: Vector2 = Vector2(380.0, 440.0)
	await _begin(6, "Retreat", "4 Rippers guard a post. 10 Shieldmen attack it, and the Rippers are losing. When their health falls below half of what they started with and the enemies near them outweigh them, they fall back once, to their retreat point (blue), and guard it. A retreat can't be ordered; the AI decides.", c + Vector2(0.0, -12.0), LOOK_NORTH, 60.0)
	var raiders: AiGroup = _spawn_group(Group.RAIDERS)
	var wall: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _grid(c + Vector2(0.0, 40.0), 5, 2, 1.6), Vector2i(0, -1))
	await _wait_sim(READ_BEFORE)
	_attack_move(wall, c, Formations.Kind.SHORT_LINE)
	var t0: int = _world.tick
	await _until(func() -> bool: return _first.has("retreat") or _alive(raiders.spawned_ids) == 0, FIGHT_TIMEOUT)
	var health: int = roundi(100.0 * AiOrders.hp_sum(raiders.living(_world)) / maxf(raiders.start_hp, 1.0))
	var left: int = _alive(raiders.spawned_ids)
	var fell_back: float = _since(t0, "retreat")
	await _until(func() -> bool: return raiders.behavior != AiGroupSpec.Behavior.RETREAT, FIGHT_TIMEOUT)
	_result("The Rippers fell back %.0f s after the Shieldmen set out, with %d/4 left and %d%% of their starting health. They walked to the retreat point, 36 m from the post, and are now in %s. Shieldmen %d/10." % [
		fell_back, left, health, AiGroupSpec.Behavior.find_key(raiders.behavior), _alive(wall)
	])
	await _wait_sim(READ_AFTER)


func _finale() -> void:
	await _begin(7, "Finale", "The mission script's triggers run this one. Light units entering the staging area (gray ring) start it: the objective is set and a Dark line (Husks and a Stormcaller) appears on the south bank. 25 s later 6 Rippers arrive from the east and the rain starts. When every Dark group is dead, the mission is won.", Vector2(298.0, 226.0), LOOK_SOUTH, 80.0)
	await _wait_sim(READ_BEFORE)
	var light: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _grid(STAGING + Vector2(0.0, 2.0), 5, 2, 1.6), Vector2i(0, 1))
	light.append_array(await _spawn(&"reaver", LIGHT, _row(STAGING + Vector2(0.0, -2.0), 4, 2.0), Vector2i(0, 1)))
	light.append_array(await _spawn(&"longbow", LIGHT, _row(STAGING + Vector2(0.0, -5.0), 6, 2.0), Vector2i(0, 1)))
	# The trigger fires on the next step; the Dark line is spawned by it.
	await _wait_sim(1.0)
	_attack_move(light, Vector2(300.0, 258.0), Formations.Kind.BOX)
	var t0: int = _world.tick
	await _until(func() -> bool: return _world.mission.outcome != MissionRuntime.Outcome.NONE, FINALE_TIMEOUT)
	var dark: PackedInt32Array = PackedInt32Array()
	for group: AiGroup in _world.ai.groups:
		if group.faction == DARK and group.spec_index >= Group.WAVE_ONE:
			dark.append_array(group.spawned_ids)
	_result("%s banner after %.0f s. Rain and reinforcements came at %.0f s. Light %d/%d standing, Dark %d/%d down. Objective now: %s" % [
		MissionHud.banner_text(_world.mission.outcome) if _world.mission.outcome != MissionRuntime.Outcome.NONE else "No outcome",
		_since(t0), _since(t0, "trigger:reinforce"), _alive(light), light.size(), dark.size() - _alive(dark), dark.size(),
		_world.mission.objective
	])
	await _wait_sim(READ_AFTER + 3.0)


# --- the script and the field ---


# The mission the demo plays: every stage's groups (spawned by the stages for
# 1 to 6, by triggers for the finale) and the finale's triggers. MainView is
# told to start none of its own (mission_path), because the game's Riverside
# mission would spawn its own Dark side on the first step and decide the
# outcome when a side runs out.
func _start_mission() -> void:
	_mission_script = _build_script()
	if not _main.world.start_mission(_mission_script, TIER):
		push_error("demo_ai: could not start the demo mission")


func _build_script() -> MissionScript:
	var mission_script: MissionScript = MissionScript.new()
	var patrol: AiGroupSpec = _spec(&"patrol", [[&"husk", 5]], Vector2(310.0, 254.0), Vector2i(1, 0), AiGroupSpec.Behavior.PATROL)
	patrol.waypoints = _points([Vector2(310.0, 254.0), Vector2(326.0, 254.0), Vector2(326.0, 266.0), Vector2(310.0, 266.0)])
	patrol.alert_radius = 12 * M
	# Deep water west of the ford: every sample within 3 m is depth 3.
	var ambush: AiGroupSpec = _spec(&"ambush", [[&"husk", 6]], Vector2(284.0, 222.0), Vector2i(1, 0), AiGroupSpec.Behavior.AMBUSH)
	ambush.alert_radius = 14 * M
	var flankers: AiGroupSpec = _spec(&"flankers", [[&"ripper", 5]], Vector2(392.0, 162.0), Vector2i(0, -1), AiGroupSpec.Behavior.FLANK)
	var caster: AiGroupSpec = _spec(&"caster", [[&"husk", 6], [&"stormcaller", 1]], Vector2(110.0, 160.0), Vector2i(0, 1), AiGroupSpec.Behavior.GUARD)
	caster.guard_radius = 45 * M
	var bags: AiGroupSpec = _spec(&"bags", [[&"blightbag", 3]], Vector2(150.0, 430.0), Vector2i(0, -1), AiGroupSpec.Behavior.IDLE)
	var raiders: AiGroupSpec = _spec(&"raiders", [[&"ripper", 4]], Vector2(380.0, 440.0), Vector2i(0, 1), AiGroupSpec.Behavior.GUARD)
	raiders.guard_radius = 25 * M
	raiders.retreat_below_permille = 500
	raiders.retreat_point = _points([Vector2(380.0, 404.0)])
	var wave_one: AiGroupSpec = _spec(&"wave_one", [[&"husk", 8], [&"stormcaller", 1]], Vector2(298.0, 262.0), Vector2i(0, -1), AiGroupSpec.Behavior.GUARD)
	wave_one.guard_radius = 30 * M
	var wave_two: AiGroupSpec = _spec(&"wave_two", [[&"ripper", 6]], Vector2(345.0, 262.0), Vector2i(-1, 0), AiGroupSpec.Behavior.FLANK)
	mission_script.groups = [patrol, ambush, flankers, caster, bags, raiders, wave_one, wave_two]

	var start: TriggerSpec = _trigger(&"start", TriggerSpec.Condition.AREA_ENTERED)
	start.area = PackedInt32Array([roundi(STAGING.x * M), roundi(STAGING.y * M), roundi(STAGING_RADIUS * M)])
	start.actions = [_objective("Cross the creek and break the Dark line"), _spawn_action(&"wave_one")]
	var reinforce: TriggerSpec = _trigger(&"reinforce", TriggerSpec.Condition.TIMER)
	reinforce.after = &"start"
	reinforce.ticks = PackedInt32Array([REINFORCE_SECONDS * World.TICK_RATE])
	var downpour: WeatherChange = WeatherChange.new()
	downpour.rain = 700
	downpour.wind_x = 3000
	downpour.wind_z = 1000
	downpour.ramp_ticks = 150
	var rain: TriggerAction = TriggerAction.new()
	rain.kind = TriggerAction.Kind.SET_WEATHER
	rain.weather = downpour
	reinforce.actions = [_spawn_action(&"wave_two"), rain, _objective("Rippers from the east: protect the Longbows")]
	var clear: TriggerSpec = _trigger(&"clear", TriggerSpec.Condition.GROUP_CLEARED)
	clear.after = &"reinforce"
	clear.names = [&"wave_one", &"wave_two"]
	var win: TriggerAction = TriggerAction.new()
	win.kind = TriggerAction.Kind.WIN
	clear.actions = [_objective("The south bank is clear"), win]
	var lost: TriggerSpec = _trigger(&"lost", TriggerSpec.Condition.FACTION_ELIMINATED)
	lost.after = &"start"
	var lose: TriggerAction = TriggerAction.new()
	lose.kind = TriggerAction.Kind.LOSE
	lost.actions = [lose]
	mission_script.triggers = [start, reinforce, clear, lost]
	return mission_script


# A DARK group of the listed [type id, count] pairs, spawning in a box at at
# (meters), facing face.
static func _spec(
	group_name: StringName, entries: Array, at: Vector2, face: Vector2i, behavior: AiGroupSpec.Behavior
) -> AiGroupSpec:
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = group_name
	for pair: Array in entries:
		var entry: AiUnitEntry = AiUnitEntry.new()
		entry.type_id = pair[0]
		entry.counts = PackedInt32Array([pair[1]])
		spec.units.append(entry)
	spec.spawns = _points([at])
	spec.facing_x = face.x
	spec.facing_z = face.y
	spec.behavior = behavior
	return spec


static func _trigger(trigger_name: StringName, condition: TriggerSpec.Condition) -> TriggerSpec:
	var trigger: TriggerSpec = TriggerSpec.new()
	trigger.name = trigger_name
	trigger.condition = condition
	return trigger


static func _objective(text: String) -> TriggerAction:
	var action: TriggerAction = TriggerAction.new()
	action.kind = TriggerAction.Kind.SET_OBJECTIVE
	action.text = text
	return action


static func _spawn_action(group_name: StringName) -> TriggerAction:
	var action: TriggerAction = TriggerAction.new()
	action.kind = TriggerAction.Kind.SPAWN_GROUP
	action.group = group_name
	return action


# Meters to the milli-unit x, z pairs the specs use.
static func _points(points: Array[Vector2]) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for p: Vector2 in points:
		out.append(roundi(p.x * M))
		out.append(roundi(p.y * M))
	return out


# MainView spawns the Light test squads with tick-0 commands. Once they exist
# they go: every AI group looks across the whole map for what it hunts, so
# they would draw the Dark side away from every stage.
func _clear_the_field() -> void:
	while _world.tick < 1:
		await physics_frame
	_despawn_all()
	await _wait_sim(0.2)


func _despawn_all() -> void:
	for unit: Unit in _world.units:
		_world.enqueue(DespawnEntityCommand.new(_world.tick, unit.id))


# --- staging ---


# Starts stage n: removes what the last stage left standing, resets the tally,
# sets the caption, and frames the camera. Waits for a whole second of ticks
# first, so a stage starts at the same point of the AI's think cycle however
# long the window took to open, and every run plays out alike.
func _begin(n: int, title: String, text: String, focus: Vector2, yaw: float, distance: float) -> void:
	while _world.tick % World.TICK_RATE != 0:
		await physics_frame
	_stage = n
	for unit_id: int in _watched:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			_world.enqueue(DespawnEntityCommand.new(_world.tick, unit_id))
	_watched.clear()
	_counts.clear()
	_first.clear()
	_bursts = PackedVector2Array()
	_surfaced = 0
	_swings.clear()
	_swingers.clear()
	_caption.text = "%d/%d  %s\n%s" % [n, STAGES, title, text]
	_camera.set_pose(focus, yaw, distance)


# Enqueues one spawn per spot (meters) and waits for the step that makes them.
# They are the units of that type and side newer than any unit that existed
# when this was called.
func _spawn(type_id: StringName, side: UnitType.Faction, spots: Array[Vector2], face: Vector2i) -> PackedInt32Array:
	var newest: int = 0
	for unit: Unit in _world.units:
		newest = maxi(newest, unit.id)
	var queued: int = _world.tick
	for p: Vector2 in spots:
		_world.enqueue(SpawnUnitCommand.new(
			queued, type_id, side, roundi(p.x * M), roundi(p.y * M), face.x, face.y
		))
	while _world.tick <= queued:
		await physics_frame
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _world.units:
		if unit.id > newest and unit.faction == side and unit.type.id == type_id:
			ids.append(unit.id)
			_watched[unit.id] = true
	return ids


# Spawns one of the demo's groups from its spec, as the mission does for a
# SPAWN_GROUP trigger. Between ticks, so the group is there for the next step.
func _spawn_group(which: Group) -> AiGroup:
	var group: AiGroup = _world.ai.spawn_group(_world, _mission_script.groups[which], which, TIER)
	for unit_id: int in group.spawned_ids:
		_watched[unit_id] = true
	return group


func _attack_move(ids: PackedInt32Array, to: Vector2, formation: Formations.Kind) -> void:
	_world.enqueue(AttackMoveCommand.new(_world.tick, ids, roundi(to.x * M), roundi(to.y * M), formation))


# Sends the idle ones of ids (no order left) at the unit target_id.
func _chase(ids: PackedInt32Array, target_id: int) -> void:
	var target: Unit = _world.get_unit(target_id)
	if target == null or not target.is_alive():
		return
	var idle: PackedInt32Array = PackedInt32Array()
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and unit.order == Unit.Order.NONE:
			idle.append(unit_id)
	if not idle.is_empty():
		_attack_move(idle, Vector2(target.x / float(M), target.z / float(M)), Formations.Kind.LOOSE_LINE)


# Waits until done() is true or timeout seconds of sim time pass, and returns
# how long it waited.
func _until(done: Callable, timeout: float) -> float:
	var start: int = _world.tick
	while _world.tick - start < roundi(timeout * World.TICK_RATE):
		if done.call():
			break
		await physics_frame
	return _since(start)


# Waits this many seconds of sim time (it runs faster with DEMO_SPEED). Every
# wait in the demo counts ticks, not wall-clock time, so the same ticks pass
# whatever the frame rate and the outcome of each stage doesn't vary.
func _wait_sim(seconds: float) -> void:
	var until: int = _world.tick + roundi(seconds * World.TICK_RATE)
	while _world.tick < until:
		await physics_frame


func _result(text: String) -> void:
	_caption.text += "\nResult: " + text
	print("stage %d result: %s" % [_stage, text])
	if not _capture_dir.is_empty():
		await process_frame
		await process_frame
		root.get_viewport().get_texture().get_image().save_png(
			_capture_dir.path_join("demo_ai_%d.png" % _stage)
		)


# Seconds of sim time since tick start, or since a stamped moment's tick.
func _since(start: int, moment: String = "") -> float:
	if moment != "":
		if not _first.has(moment):
			return -1.0
		return float(_first[moment] - start) / World.TICK_RATE
	return float(_world.tick - start) / World.TICK_RATE


static func _row(center: Vector2, count: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i: int in count:
		out.append(center + Vector2((i - (count - 1) * 0.5) * spacing, 0.0))
	return out


# columns x rows spots centered on center, spacing meters apart.
static func _grid(center: Vector2, columns: int, rows: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for r: int in rows:
		out.append_array(_row(center + Vector2(0.0, (r - (rows - 1) * 0.5) * spacing), columns, spacing))
	return out


# --- reading the world ---


func _alive(ids: PackedInt32Array) -> int:
	var n: int = 0
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			n += 1
	return n


# Living units of ids that are paralyzed now.
func _paralyzed(ids: PackedInt32Array) -> int:
	var n: int = 0
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and StatusEffects.paralyzed(_world, unit):
			n += 1
	return n


# The first member of group of this type (by id), or 0.
func _first_of(group: AiGroup, type_id: StringName) -> int:
	for unit_id: int in group.spawned_ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.type.id == type_id:
			return unit_id
	return 0


# --- tally ---


func _note_ai(event: AiEvent) -> void:
	match event.kind:
		AiEvent.Kind.WAYPOINT_REACHED:
			_bump("waypoint")
		AiEvent.Kind.AMBUSH_SPRUNG:
			_stamp("sprung")
			_surfaced += event.value
		AiEvent.Kind.FLANK_WAYPOINT:
			_bump("flank waypoint")
		AiEvent.Kind.STANDOFF:
			_bump("standoff move")
		AiEvent.Kind.RETREAT:
			_stamp("retreat")
		AiEvent.Kind.BEHAVIOR:
			if event.value == AiGroupSpec.Behavior.HUNT:
				_stamp("hunt")


func _note_mission(event: MissionEvent) -> void:
	if event.kind == MissionEvent.Kind.TRIGGER_FIRED:
		_stamp("trigger:" + _mission_script.triggers[event.trigger_index].name)


func _stamp(moment: String) -> void:
	if not _first.has(moment):
		_first[moment] = _world.tick


func _bump(key: String) -> void:
	_counts[key] = _counts.get(key, 0) + 1


func _n(key: String) -> int:
	return _counts.get(key, 0)


func _refresh_tally() -> void:
	if _tally == null or _stage == 0:
		return
	var parts: PackedStringArray = PackedStringArray()
	for key: String in ["waypoint", "flank waypoint", "standoff move", "bolt", "burst", "killed"]:
		if _counts.has(key):
			parts.append("%s %d" % [key, _counts[key]])
	var standing: PackedInt32Array = PackedInt32Array([0, 0])
	for unit_id: int in _watched:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			standing[unit.faction] += 1
	_tally.text = "Light %d · Dark %d standing    %s" % [standing[0], standing[1], " · ".join(parts)]


# --- setup ---


func _build_labels() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	box.offset_top = CAPTION_TOP
	_caption = _label(22)
	_tally = _label(17)
	box.add_child(_caption)
	box.add_child(_tally)
	_main.get_node("Hud").add_child(box)


static func _label(font_size: int) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_constant_override("outline_size", 8)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	return label
