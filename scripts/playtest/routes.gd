class_name PlaytestRoutes
extends RefCounted
## Where the playtest pilots go on each shipped mission: the small table a
## player who knows the map carries in his head. Every point is in meters (the
## pilots think in floats; the commands they emit are converted to integer
## milli-units). Nothing is retyped from the mission data or a generator:
## places a map generator names (scripts/gen_*.gd) come from its constants, and
## the rest (the ford's middle, the ground the field patrols walk, the villager's
## landing and gate) from the mission's own rules, the same way the escort route
## is, so a patrol or a trigger moved in the data moves the route with it.
## test_playtest_pilot.gd checks that every point is ground a living soldier can
## stand on.

const GENERATORS: Dictionary[StringName, String] = {
	&"riverside": "res://scripts/gen_riverside.gd",
	&"the_ford": "res://scripts/gen_the_ford.gd",
	&"old_mill": "res://scripts/gen_old_mill.gd",
}

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


## The route a pilot marches, in meters, in order. Riverside: the ford (the
## middle of the `in_ford` trigger), the ground of the two field patrols (the
## centroids of their waypoints), the sand road, the village square, then the
## sweep (see sweep_from). The Ford: the ford (the `crossing` trigger), the north
## landing (`north`), the gate (`home`): where a person leads a squad that has
## been told to take a villager to the gate. Old Mill: the mill yard, where the
## squad deploys and stays. A mission this table doesn't know gets its deploy
## point, so a pilot on a future mission holds where it starts.
static func route(mission: MissionDef) -> Array[Vector2]:
	match mission.id:
		&"riverside":
			var g: Dictionary = constants(&"riverside")
			var road: PackedVector2Array = g["FORD_ROAD"]
			var out: Array[Vector2] = [
				trigger_center(mission, &"in_ford"), group_centroid(mission, &"field_patrol_w"), road[0],
				group_centroid(mission, &"field_patrol_e"), road[road.size() - 1], g["VILLAGE_SQUARE"],
			]
			out.append_array(riverside_sweep())
			return out
		&"the_ford":
			return [
				trigger_center(mission, &"crossing"), trigger_center(mission, &"north"),
				trigger_center(mission, &"home"),
			]
		&"old_mill":
			var g: Dictionary = constants(&"old_mill")
			return [g["YARD_CENTER"]]
	return [deploy(mission)]


## The middle of the area of the mission's trigger of this name, in meters. The
## deploy point, after push_error, for a mission without it.
static func trigger_center(mission: MissionDef, trigger_name: StringName) -> Vector2:
	var i: int = mission.rules.trigger_index(trigger_name)
	if i < 0 or mission.rules.triggers[i].area.size() < 2:
		push_error("PlaytestRoutes: %s has no trigger area called %s" % [mission.id, trigger_name])
		return deploy(mission)
	var area: PackedInt32Array = mission.rules.triggers[i].area
	return Vector2(area[0], area[1]) / 1000.0


## The centroid of the waypoints of the mission's group of this name, in meters.
## The deploy point, after push_error, for a mission without it.
static func group_centroid(mission: MissionDef, group_name: StringName) -> Vector2:
	var i: int = mission.rules.group_index(group_name)
	if i < 0 or mission.rules.groups[i].waypoints.size() < 2:
		push_error("PlaytestRoutes: %s has no patrol called %s" % [mission.id, group_name])
		return deploy(mission)
	var points: PackedInt32Array = mission.rules.groups[i].waypoints
	var sum: Vector2 = Vector2.ZERO
	for k: int in range(0, points.size() - 1, 2):
		sum += Vector2(points[k], points[k + 1])
	return sum / float(points.size() >> 1) / 1000.0


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
