class_name BenchScenario
extends RefCounted
## The load the benchmark (scripts/bench.gd) and the sim profiler
## (scripts/profile_sim.gd) both put on the game: a skirmish on Riverside, AI
## against AI, 50 Light against 50 Dark, every unit's health topped up between
## ticks so the hundred keep fighting, and arrows dropped over the fight to
## keep `projectiles` in the air. A load harness, not a game: the top-ups and
## extra arrows change the world from outside the command stream.

const MAP_PATH: String = "res://maps/riverside/skirmish.tres"
const LIGHT_ARMY: Dictionary[StringName, int] = {
	&"shieldman": 15, &"reaver": 10, &"longbow": 15, &"sapper": 10,
}
const DARK_ARMY: Dictionary[StringName, int] = {
	&"husk": 20, &"ripper": 10, &"drifter": 8, &"stormcaller": 6, &"blightbag": 6,
}
## At most this many extra arrows a tick, so a top-up arrives as a shower.
const ARROWS_PER_TICK: int = 12
const M: int = 1000

var projectiles: int = 200
## After the last between_ticks: units alive and projectiles flying.
var alive: int = 0
var flying: int = 0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _arrow_type: int = -1


func _init(catalog: UnitCatalog, target_projectiles: int = 200) -> void:
	projectiles = target_projectiles
	_arrow_type = catalog.projectile_index_of(&"arrow")
	_rng.seed = 20261007


## The skirmish to play.
static func setup() -> SkirmishSetup:
	var s: SkirmishSetup = SkirmishSetup.new()
	s.map = load(MAP_PATH) as SkirmishMap
	s.rules = SkirmishRules.for_map(s.map, SkirmishRules.Mode.BODY_COUNT, 30, UnitType.Faction.LIGHT)
	s.budget = 1_000_000
	var light: Army = Army.new(UnitType.Faction.LIGHT)
	for type_id: StringName in LIGHT_ARMY:
		light.set_count(type_id, LIGHT_ARMY[type_id])
	var dark: Army = Army.new(UnitType.Faction.DARK)
	for type_id: StringName in DARK_ARMY:
		dark.set_count(type_id, DARK_ARMY[type_id])
	s.armies = [light, dark]
	s.player_is_ai = true
	s.world_seed = 1000
	return s


## Before each tick: everyone back to full health, and arrows into the air
## until there are enough.
func between_ticks(world: World) -> void:
	alive = 0
	var sum: Vector2i = Vector2i.ZERO
	for unit: Unit in world.units:
		if unit.is_alive():
			unit.hp = unit.type.max_hp
			alive += 1
			sum += Vector2i(unit.x, unit.z)
	flying = 0
	for p: Projectile in world.projectiles:
		if not p.removed and p.motion == Projectile.Motion.FLYING:
			flying += 1
	if alive == 0:
		return
	var center: Vector2i = sum / alive
	for i: int in mini(projectiles - flying, ARROWS_PER_TICK):
		var x: int = center.x + _rng.randi_range(-30 * M, 30 * M)
		var z: int = center.y + _rng.randi_range(-30 * M, 30 * M)
		var y: int = world.terrain.height_at(x, z) + 12 * M
		var flight: FlightState = FlightState.at_mm(
			x, y, z,
			FlightState.speed_from_mm_per_s(_rng.randi_range(-4000, 4000)),
			FlightState.speed_from_mm_per_s(_rng.randi_range(2000, 8000)),
			FlightState.speed_from_mm_per_s(_rng.randi_range(-4000, 4000)),
		)
		world.spawn_projectile(_arrow_type, flight, 0)
