class_name MissionFixtures
extends RefCounted
## Builders for mission scripts written in code, shared by the campaign-format
## tests, so each test pins only the rules it depends on. Target-dummy unit
## types, so nothing fights unless a test makes it.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the types in catalog().
const HUSK: int = 0
const WALKER: int = 1


## Two dummies: a husk (the groups' unit type) and a walker (a commanded unit
## a test spawns by hand).
static func catalog() -> UnitCatalog:
	var types: Array[UnitType] = [TestUnits.dummy(&"husk"), TestUnits.dummy(&"walker")]
	return TestUnits.catalog(types)


static func entry(type_id: StringName, counts: PackedInt32Array) -> AiUnitEntry:
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = type_id
	e.counts = counts
	return e


## A group of husks, `count` at every tier, spawning at (x, z) metres. at_start
## false waits for a SPAWN_GROUP action (a pool group must).
static func group(
	group_name: StringName, count: int = 2, x: int = 10, z: int = 10, at_start: bool = true
) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = group_name
	g.units.append(entry(&"husk", PackedInt32Array([count])))
	g.spawns = PackedInt32Array([x * M, z * M])
	g.spawn_at_start = at_start
	return g


static func action(kind: TriggerAction.Kind) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = kind
	return a


static func spawn_action(group_name: StringName) -> TriggerAction:
	var a: TriggerAction = action(TriggerAction.Kind.SPAWN_GROUP)
	a.group = group_name
	return a


static func behavior_action(group_name: StringName, behavior: AiGroupSpec.Behavior) -> TriggerAction:
	var a: TriggerAction = action(TriggerAction.Kind.SET_BEHAVIOR)
	a.group = group_name
	a.behavior = behavior
	return a


## SHOW_OBJECTIVE, COMPLETE_OBJECTIVE or FAIL_OBJECTIVE on the named objective.
static func objective_action(kind: TriggerAction.Kind, objective_name: StringName) -> TriggerAction:
	var a: TriggerAction = action(kind)
	a.objective = objective_name
	return a


static func trigger(trigger_name: StringName, condition: TriggerSpec.Condition) -> TriggerSpec:
	var t: TriggerSpec = TriggerSpec.new()
	t.name = trigger_name
	t.condition = condition
	return t


static func timer(trigger_name: StringName, ticks: int, after: StringName = &"") -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.TIMER)
	t.ticks = PackedInt32Array([ticks])
	t.after = after
	return t


## AREA_ENTERED around (x, z) metres, radius in metres. `names` (groups or
## aliases) restricts it to those groups' units.
static func area(
	trigger_name: StringName, x: int, z: int, radius: int, side: UnitType.Faction = LIGHT,
	names: Array[StringName] = []
) -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.AREA_ENTERED)
	t.area = PackedInt32Array([x * M, z * M, radius * M])
	t.faction = side
	t.names = names
	return t


static func dies(trigger_name: StringName, names: Array[StringName], count: int) -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.UNIT_DIES)
	t.names = names
	t.count = count
	return t


static func cleared(trigger_name: StringName, names: Array[StringName]) -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.GROUP_CLEARED)
	t.names = names
	return t


## TRIGGERS_FIRED: at least `min_count` of the named triggers have fired.
static func fired(trigger_name: StringName, names: Array[StringName], min_count: int = 1) -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.TRIGGERS_FIRED)
	t.names = names
	t.min_count = min_count
	return t


static func player_eliminated(trigger_name: StringName, side: UnitType.Faction = LIGHT) -> TriggerSpec:
	var t: TriggerSpec = trigger(trigger_name, TriggerSpec.Condition.PLAYER_ELIMINATED)
	t.faction = side
	return t


static func objective(
	objective_name: StringName, text: String = "", optional: bool = false, shown_at_start: bool = true
) -> ObjectiveSpec:
	var o: ObjectiveSpec = ObjectiveSpec.new()
	o.name = objective_name
	o.text = text if text != "" else String(objective_name)
	o.optional = optional
	o.shown_at_start = shown_at_start
	return o


static func draw(slots: Array[StringName], pool: Array[StringName], ordered: bool = false) -> MissionDraw:
	var d: MissionDraw = MissionDraw.new()
	d.slots = slots
	d.pool = pool
	d.ordered = ordered
	return d


static func script(
	groups: Array[AiGroupSpec], triggers: Array[TriggerSpec],
	objectives: Array[ObjectiveSpec] = [], draws: Array[MissionDraw] = []
) -> MissionScript:
	var s: MissionScript = MissionScript.new()
	s.groups = groups
	s.triggers = triggers
	s.objectives = objectives
	s.draws = draws
	return s


## A world on flat terrain with the script started at this tier. The roll
## (World.roll_bindings) follows from `world_seed`.
static func world(mission_script: MissionScript, tier: int = 0, world_seed: int = 1) -> World:
	var w: World = World.new(world_seed, TestTerrains.flat(60, 60), catalog())
	# Not assert(): under the debugger that hangs instead of failing the test. A
	# push_error fails the running test, and the world is returned without a
	# mission so what the test checks next fails by name rather than crashing.
	if not w.start_mission(mission_script, tier):
		push_error("MissionFixtures.world: the script should be accepted")
	return w


## Like world(), but the mission runs with these bindings instead of the
## roll's, so a test knows exactly which pool group each alias means.
static func world_bound(mission_script: MissionScript, bindings: PackedInt32Array, tier: int = 0) -> World:
	var w: World = World.new(1, TestTerrains.flat(60, 60), catalog())
	var errors: PackedStringArray = mission_script.validate(w.catalog)
	if not errors.is_empty():
		# Not assert() (see world()). An invalid script isn't run: the world
		# gets an empty one, so the test fails on the error and on what it expects.
		push_error("MissionFixtures.world_bound: invalid test script: %s" % [errors])
		mission_script = MissionScript.new()
	w.mission = MissionRuntime.new(mission_script, tier, w.tick, bindings)
	return w


static func run(w: World, ticks: int) -> void:
	for _t: int in ticks:
		w.step()


## A commanded (not AI-spawned) unit standing at (x, z) metres.
static func commanded(w: World, side: UnitType.Faction, x: int, z: int) -> Unit:
	return w.spawn_unit(WALKER, side, x * M, z * M, 1, 0)
