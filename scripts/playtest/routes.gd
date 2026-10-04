class_name PlaytestRoutes
extends RefCounted
## Where the playtest pilots go on each shipped mission: the small table a
## player who knows the map carries in his head. Every point is in meters (the
## pilots think in floats; the commands they emit are converted to integer
## milli-units), and wherever a map generator names a place (scripts/gen_*.gd)
## it is read from the generator's constants rather than retyped, so a moved
## village or ford moves the route with it. The few points the generators
## don't name (the ford's middle, the places the field patrols walk) are
## literals, with where they come from; test_playtest_pilot.gd checks that
## every point is ground a living soldier can stand on.

const GENERATORS: Dictionary[StringName, String] = {
	&"riverside": "res://scripts/gen_riverside.gd",
	&"the_ford": "res://scripts/gen_the_ford.gd",
	&"old_mill": "res://scripts/gen_old_mill.gd",
}

## The middle of Riverside's ford, where the creek is shallow: the centre of
## the `at_ford` trigger in data/missions/riverside/rules.tres.
const RIVERSIDE_FORD: Vector2 = Vector2(300.0, 226.0)
## Where the west field patrol loops, just south of the ford's landing: the
## centroid of its three waypoints in the same rules file.
const RIVERSIDE_WEST_PATROL: Vector2 = Vector2(286.7, 257.3)
## Where the east field patrol loops, on the sand road to the village.
const RIVERSIDE_EAST_PATROL: Vector2 = Vector2(358.7, 308.0)

# Constant maps of the generator scripts, loaded once: reading a script's
# constants compiles it, and the pilots ask for them every run.
static var _constants: Dictionary[StringName, Dictionary] = {}
static var _scripts: Dictionary[StringName, GDScript] = {}


## A generator's constants by name (its public layout), for a mission id.
static func constants(mission_id: StringName) -> Dictionary:
	if not _constants.has(mission_id):
		_constants[mission_id] = generator(mission_id).get_script_constant_map()
	return _constants[mission_id]


## The generator script of a mission, whose static helpers (Old Mill's ramp())
## the tests reach the same way.
static func generator(mission_id: StringName) -> GDScript:
	if not _scripts.has(mission_id):
		_scripts[mission_id] = load(GENERATORS[mission_id]) as GDScript
	return _scripts[mission_id]


## The route a pilot marches, in meters, in order. Riverside: the ford, the two
## field patrols' ground, the sand road, the village square, then the sweep
## (see sweep_from). The Ford: the
## villager's own waypoints. Old Mill: the mill yard, where the squad deploys
## and stays. A mission this table doesn't know gets its deploy point, so a
## pilot on a future mission holds where it starts.
static func route(mission: MissionDef) -> Array[Vector2]:
	match mission.id:
		&"riverside":
			var g: Dictionary = constants(&"riverside")
			var road: PackedVector2Array = g["FORD_ROAD"]
			var out: Array[Vector2] = [
				RIVERSIDE_FORD, RIVERSIDE_WEST_PATROL, road[0], RIVERSIDE_EAST_PATROL,
				road[road.size() - 1], g["VILLAGE_SQUARE"],
			]
			out.append_array(riverside_sweep())
			return out
		&"the_ford":
			return escort(mission)
		&"old_mill":
			var g: Dictionary = constants(&"old_mill")
			return [g["YARD_CENTER"]]
	return [deploy(mission)]


## Where a pilot goes once it has walked the whole route and Dark units remain
## that it hasn't seen: the index in route() of the first point of the sweep it
## repeats, or -1 to stay on the last point. Riverside sweeps the village's lane
## ends, which is where a Husk that never came out would be.
static func sweep_from(mission: MissionDef) -> int:
	if mission.id == &"riverside":
		return route(mission).size() - riverside_sweep().size()
	return -1


## The points a Riverside sweep visits after the route: the ends of the
## village's four spurs.
static func riverside_sweep() -> Array[Vector2]:
	var g: Dictionary = constants(&"riverside")
	var out: Array[Vector2] = []
	for lane_name: String in ["LANE_EAST", "LANE_SOUTH", "LANE_WEST", "LANE_NORTH"]:
		var lane: PackedVector2Array = g[lane_name]
		out.append(lane[lane.size() - 1])
	return out


## The villager's waypoints of an escort mission, in meters: read from the
## mission's own rules, so the pilot walks exactly what the AI does. Empty for
## a mission with no escort group.
static func escort(mission: MissionDef) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for group: AiGroupSpec in mission.rules.groups:
		if group.behavior != AiGroupSpec.Behavior.ESCORT:
			continue
		for k: int in range(0, group.waypoints.size() - 1, 2):
			out.append(Vector2(group.waypoints[k], group.waypoints[k + 1]) / 1000.0)
		return out
	return out


## Where the mission's roster deploys, in meters.
static func deploy(mission: MissionDef) -> Vector2:
	return Vector2(mission.deploy[0], mission.deploy[1]) / 1000.0


## Old Mill's two ramps, in the order the generator lists them (north-west,
## then south-east): each as {"foot": where it meets the plain, "top": where it
## meets the plateau's edge}, both in meters. The same ramp() the generator
## cut them with.
static func mill_ramps() -> Array[Dictionary]:
	var g: Dictionary = constants(&"old_mill")
	var out: Array[Dictionary] = []
	for foot_name: String in ["NW_RAMP_FOOT", "SE_RAMP_FOOT"]:
		var foot: Vector2 = g[foot_name]
		var ramp: Dictionary = generator(&"old_mill").call(&"ramp", foot)
		out.append({"foot": foot, "top": ramp["to"]})
	return out


## The middle of Old Mill's plateau, in meters.
static func mill_center() -> Vector2:
	return constants(&"old_mill")["PLATEAU_CENTER"]


## The plateau's radius, in meters, plus its cliff: everything within it is
## "on the plateau" for a pilot deciding whether the enemy has arrived.
static func mill_plateau_radius() -> float:
	var g: Dictionary = constants(&"old_mill")
	return float(g["PLATEAU_RADIUS_M"]) + float(g["CLIFF_WIDTH_M"]) / 2.0 + 1.0
