class_name SkirmishCommander
extends RefCounted
## The AI's general in a skirmish: one per side the AI plays, above that
## side's groups (a main group of everything but its Rippers, and a raider
## group of the Rippers). Every THINK_TICKS it picks an objective for the
## mode, weighs its strength against the enemy's near it, and moves the main
## group with AiDirector.advance: up to a staging point out of the enemy's
## range, onto the objective once it is strong enough there, back again when
## it is losing. Its ranged and support members keep behind its melee
## through the group's spec (ranged_behind, AiTactics.is_back).
##
## Strength is cost x health: the sum over units of UnitType.cost scaled by
## hp / max_hp, in permille-points, the same currency as the armies' budget.
## Its own units count submerged or not; enemies only if seen.
##
## Postures (append only: hashed):
## - STAGE: hold a point stage_distance short of the objective, on the side
##   the main group comes from, attack-moving, so it fights what comes.
##   Entered on a fall back with a plain move (march_attack off), so members
##   disengage as they come free rather than being pulled out of fights.
## - COMMIT: onto the objective; the raiders FLANK the enemy's ranged and
##   support. Entered when the army has gathered at the stage point and its
##   strength near it is at least the required ratio of the threat, or at
##   once if the objective is unguarded or time is running out (desperation).
## - DEFEND: holding an objective it owns while ahead on score (King of the
##   Hill, Capture the Flags): the raiders stay with the main group.
## A posture is held at least MIN_POSTURE_TICKS, so it doesn't flip with each
## think, except to commit when the objective is unguarded or desperate.
##
## No random numbers: ties go to the nearer, then the lower index.

enum Posture {
	STAGE,
	COMMIT,
	DEFEND,
}

## Ticks between thinks (1 s), staggered by the commander's id.
const THINK_TICKS: int = World.TICK_RATE
## Milli-units round a point within which strength counts as local to it.
const LOCAL_RADIUS: int = 40000
## The main group's engage radius (AiGroup.engage_radius).
const ENGAGE_RADIUS: int = 25000
## Hold radius at a staging point, or at a Body Count objective.
const STAGE_HOLD_RADIUS: int = 12000
## Units inside a flag's radius by this much hold it (the hold radius is the
## flag radius less this).
const FLAG_HOLD_MARGIN: int = 2000
## Shortest staging distance, and how far beyond the enemy's longest reach
## the staging point stands. The shortest is past ENGAGE_RADIUS, so an army
## holding its staging point doesn't go for enemies standing on the objective.
const STAGE_MIN: int = 40000
const STAGE_MARGIN: int = 8000
## How much farther back the staging point goes each time the army bleeds
## there with nobody to fight, and the most it may add up to.
const BLEED_BACK: int = 20000
const BLEED_BACK_MAX: int = 60000
## Least ticks between posture changes (10 s).
const MIN_POSTURE_TICKS: int = 10 * World.TICK_RATE
## Share of the army's strength (permille) that must be near the staging
## point before it commits.
const GATHER_PERMILLE: int = 700
## Strength ratio (own over threat, permille) needed to commit: to take an
## objective the enemy holds, or for an open-field fight in Body Count.
const TAKE_PERMILLE: int = 1250
const OPEN_PERMILLE: int = 900
## The ratio a side behind on score falls to by the end of the clock, and
## one level on score.
const BEHIND_FLOOR_PERMILLE: int = 700
const LEVEL_FLOOR_PERMILLE: int = 1000
## Below this ratio a committed army falls back.
const BREAK_PERMILLE: int = 800
## A Body Count army attacks the enemy's main body once its whole strength
## is at least this ratio of the enemy's; until then it goes to the centre.
const BODY_COUNT_ATTACK_PERMILLE: int = 1100
## The share of the clock left (permille) under which a side behind or level
## commits whatever the odds, but never less than DESPERATE_MIN_TICKS.
const DESPERATE_PERMILLE: int = 250
const DESPERATE_MIN_TICKS: int = 60 * World.TICK_RATE
## Capture the Flags switches objective only to one this much cheaper
## (permille of the current one's cost).
const SWITCH_PERMILLE: int = 700
## Milli-units: radius of a Body Count knot (the enemy's main body).
const KNOT_RADIUS: int = 20000

## Stagger for the think tick; the order the commander was added in, from 1.
var id: int
var faction: UnitType.Faction
## The MissionScript index of the main group's spec and the raiders' (-1 for
## none). The groups are found again by them (AiDirector.groups_of).
var main_spec: int
var raider_spec: int
## The middle of the map between the starts, where a Body Count army goes
## before it has the strength to attack.
var centre_x: int
var centre_z: int

var posture: Posture = Posture.STAGE
## The tick the posture last changed.
var posture_tick: int = 0
## The flag being taken or held, or -1 for a point (Body Count).
var objective_flag: int = -1
var objective_x: int = 0
var objective_z: int = 0
var stage_x: int = 0
var stage_z: int = 0
## Extra staging distance after bleeding (BLEED_BACK).
var stage_back: int = 0
## Its units' hit points at the last think: a drop with nobody to fight is
## bleeding.
var last_hp: int = 0


func _init(
	commander_id: int, side: UnitType.Faction, main_index: int, raider_index: int, centre: Vector2i
) -> void:
	id = commander_id
	faction = side
	main_spec = main_index
	raider_spec = raider_index
	centre_x = centre.x
	centre_z = centre.y


## Thinks if it is its turn and the skirmish is still being played.
func update(world: World) -> void:
	if world.skirmish == null or world.skirmish.is_decided():
		return
	if (world.tick + id) % THINK_TICKS != 0:
		return
	think(world)


## One think: objective, strength, posture, orders. Public so a test can make
## the commander think on a tick of its choosing.
func think(world: World) -> void:
	var main: AiGroup = _first_with_members(world, main_spec)
	var raiders: AiGroup = _first_with_members(world, raider_spec)
	if main == null:
		# The raiders are all that is left: they do the main group's job.
		main = raiders
		raiders = null
	if main == null:
		return
	var own: Array[Unit] = main.living(world)
	if raiders != null:
		own.append_array(raiders.living(world))
	var enemies: Array[Unit] = AiOrders.enemies(world, faction)
	var own_total: int = strength(own)
	var c: Vector2i = AiOrders.centroid(AiTactics.front(main.living(world), main))
	var was_flag: int = objective_flag
	_pick_objective(world, c, enemies, own_total)
	# A new flag is staged for afresh: gather short of it, then commit.
	var retargeted: bool = objective_flag != was_flag and posture != Posture.STAGE
	if retargeted:
		posture = Posture.STAGE
	var threat: int = maxi(
		strength(_within(enemies, objective_x, objective_z, LOCAL_RADIUS)),
		strength(_within(enemies, c.x, c.y, LOCAL_RADIUS))
	)
	var own_local: int = strength(_within(own, c.x, c.y, LOCAL_RADIUS))
	var hp: int = AiOrders.hp_sum(own)
	var bleeding: bool = hp < last_hp and _within(enemies, c.x, c.y, ENGAGE_RADIUS).is_empty()
	last_hp = hp
	var desperate: bool = _desperate(world)
	var dwelt: bool = retargeted or world.tick - posture_tick >= MIN_POSTURE_TICKS
	var before: Posture = posture
	var falling_back: bool = false
	match posture:
		Posture.STAGE:
			var gathered: bool = (
				strength(_within(own, stage_x, stage_z, LOCAL_RADIUS)) * 1000 >= own_total * GATHER_PERMILLE
			)
			if desperate or threat == 0:
				posture = Posture.COMMIT
			elif dwelt and gathered and own_local * 1000 >= threat * _required(world):
				posture = Posture.COMMIT
			elif bleeding:
				if own_local * 1000 >= threat * BREAK_PERMILLE:
					posture = Posture.COMMIT
				else:
					stage_back = mini(stage_back + BLEED_BACK, BLEED_BACK_MAX)
		Posture.COMMIT:
			if dwelt and not desperate and threat > 0 and own_local * 1000 < threat * BREAK_PERMILLE:
				posture = Posture.STAGE
				falling_back = true
			elif dwelt and _holds_objective(world) and _ahead(world):
				posture = Posture.DEFEND
		Posture.DEFEND:
			if not _holds_objective(world) or not _ahead(world):
				posture = Posture.COMMIT
	if posture != before or retargeted:
		posture_tick = world.tick
		if posture == Posture.COMMIT:
			stage_back = 0
	_set_stage(world, main, c, enemies)
	_order(world, main, raiders, falling_back)
	world.ai_events.append(AiEvent.new(
		AiEvent.Kind.COMMANDER, main.id, objective_x, objective_z, posture, objective_flag + 1
	))


## Strength of units: sum of cost x hp / max_hp, in permille-points.
static func strength(units: Array[Unit]) -> int:
	var total: int = 0
	for unit: Unit in units:
		if unit.is_alive():
			total += unit.type.cost * 1000 * unit.hp / unit.type.max_hp
	return total


## Everything the commander keeps, for state_hash().
func hash_fields() -> PackedInt64Array:
	return PackedInt64Array([
		id, faction, main_spec, raider_spec, centre_x, centre_z, posture, posture_tick,
		objective_flag, objective_x, objective_z, stage_x, stage_z, stage_back, last_hp,
	])


func _first_with_members(world: World, spec_index: int) -> AiGroup:
	if spec_index < 0:
		return null
	for group: AiGroup in world.ai.groups_of(spec_index):
		if not group.members.is_empty():
			return group
	return null


static func _within(units: Array[Unit], x: int, z: int, radius: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in units:
		if FixedMath.length(unit.x - x, unit.z - z) <= radius:
			out.append(unit)
	return out


# The objective for the mode, kept until it is ours or another is enough
# cheaper (Capture the Flags).
func _pick_objective(world: World, c: Vector2i, enemies: Array[Unit], own_total: int) -> void:
	var rules: SkirmishRules = world.skirmish.rules
	match rules.mode:
		SkirmishRules.Mode.KING_OF_THE_HILL:
			_set_flag(rules, rules.hill)
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			_set_flag(rules, _pick_flag(world, c, enemies, own_total))
		_:
			objective_flag = -1
			var enemy_total: int = strength(enemies)
			var knot: PackedInt64Array = ClusterFinder.densest(enemies, KNOT_RADIUS, c.x, c.y)
			if not knot.is_empty() and (
				own_total * 1000 >= enemy_total * BODY_COUNT_ATTACK_PERMILLE or _desperate(world)
				or _behind(world)
			):
				objective_x = knot[0]
				objective_z = knot[1]
			else:
				objective_x = centre_x
				objective_z = centre_z


func _set_flag(rules: SkirmishRules, flag: int) -> void:
	objective_flag = flag
	objective_x = rules.flags[2 * flag]
	objective_z = rules.flags[2 * flag + 1]


# Capture the Flags: the cheapest flag not ours, cost being the distance from
# the main group scaled up by the enemy's strength there (a flag guarded by
# as much as the whole army costs three times its distance). The current one
# stays until it is ours or another costs under SWITCH_PERMILLE of it. With
# every flag ours, the one nearest the enemy's middle (the hill if none is
# seen).
func _pick_flag(world: World, c: Vector2i, enemies: Array[Unit], own_total: int) -> int:
	var rt: SkirmishRuntime = world.skirmish
	var rules: SkirmishRules = rt.rules
	var best: int = -1
	var best_cost: int = 0
	var current_cost: int = -1
	for i: int in rules.flag_count():
		if rt.flag_owner[i] == faction:
			continue
		var fx: int = rules.flags[2 * i]
		var fz: int = rules.flags[2 * i + 1]
		var guard: int = strength(_within(enemies, fx, fz, LOCAL_RADIUS))
		var cost: int = FixedMath.length(fx - c.x, fz - c.y) * (own_total + 2 * guard) / maxi(own_total, 1)
		if i == objective_flag:
			current_cost = cost
		if best < 0 or cost < best_cost:
			best = i
			best_cost = cost
	if best < 0:
		if enemies.is_empty():
			return rules.hill
		var e: Vector2i = AiOrders.centroid(enemies)
		var nearest: int = -1
		var nearest_d: int = 0
		for i: int in rules.flag_count():
			var d: int = FixedMath.length(rules.flags[2 * i] - e.x, rules.flags[2 * i + 1] - e.y)
			if nearest < 0 or d < nearest_d:
				nearest = i
				nearest_d = d
		return nearest
	if current_cost >= 0 and best_cost * 1000 >= current_cost * SWITCH_PERMILLE:
		return objective_flag
	return best


# The strength ratio (permille) needed to commit: TAKE_PERMILLE (OPEN_PERMILLE
# in Body Count), easing as the clock runs toward BEHIND_FLOOR_PERMILLE when
# behind on score, LEVEL_FLOOR_PERMILLE when level, and not at all ahead.
func _required(world: World) -> int:
	var base: int = OPEN_PERMILLE if world.skirmish.rules.mode == SkirmishRules.Mode.BODY_COUNT else TAKE_PERMILLE
	var floor_ratio: int = base
	if _behind(world):
		floor_ratio = mini(base, BEHIND_FLOOR_PERMILLE)
	elif not _ahead(world):
		floor_ratio = mini(base, LEVEL_FLOOR_PERMILLE)
	var rt: SkirmishRuntime = world.skirmish
	var elapsed: int = clampi(world.tick - rt.start_tick, 0, rt.rules.time_limit_ticks)
	return base - (base - floor_ratio) * elapsed / rt.rules.time_limit_ticks


func _desperate(world: World) -> bool:
	if _ahead(world):
		return false
	var rt: SkirmishRuntime = world.skirmish
	var left: int = rt.ticks_left(world.tick)
	var limit: int = maxi(rt.rules.time_limit_ticks * DESPERATE_PERMILLE / 1000, DESPERATE_MIN_TICKS)
	return left <= limit


func _ahead(world: World) -> bool:
	return _margin(world) > 0


func _behind(world: World) -> bool:
	return _margin(world) < 0


# Own score less the enemy's; Capture the Flags level on flags compares
# flag-ticks, as the time limit does.
func _margin(world: World) -> int:
	var rt: SkirmishRuntime = world.skirmish
	var other: int = 1 - faction
	var margin: int = rt.score(faction) - rt.score(other)
	if margin == 0 and rt.rules.mode == SkirmishRules.Mode.CAPTURE_THE_FLAGS:
		return rt.owned_ticks[faction] - rt.owned_ticks[other]
	return margin


func _holds_objective(world: World) -> bool:
	var rt: SkirmishRuntime = world.skirmish
	match rt.rules.mode:
		SkirmishRules.Mode.KING_OF_THE_HILL:
			return rt.hill_holder == faction
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			return objective_flag >= 0 and rt.flag_owner[objective_flag] == faction
	return false


# The staging point: stage distance short of the objective on the line from
# it to the main group, on the map and in the main group's component.
func _set_stage(world: World, main: AiGroup, c: Vector2i, enemies: Array[Unit]) -> void:
	var reach: int = 0
	for enemy: Unit in enemies:
		if enemy.type.has_ranged() or enemy.type.throws_carried:
			reach = maxi(reach, enemy.type.ranged_max_range)
	var distance: int = maxi(STAGE_MIN, reach + STAGE_MARGIN) + stage_back
	var away: Vector2i = FixedMath.normalize(c.x - objective_x, c.y - objective_z, distance)
	if away == Vector2i.ZERO:
		away = Vector2i(0, distance)
	var t: Terrain = world.terrain
	var x: int = clampi(objective_x + away.x, 0, t.extent_x())
	var z: int = clampi(objective_z + away.y, 0, t.extent_z())
	var units: Array[Unit] = main.living(world)
	var leader: Unit = units[0]
	var mobility: Terrain.Mobility = Terrain.Mobility.LIVING
	var component: int = world.pathing.component_at(leader.x, leader.z, mobility)
	if component == PathLayer.NO_COMPONENT:
		mobility = leader.type.mobility
		component = world.pathing.component_at(leader.x, leader.z, mobility)
	var at: Vector2i = world.pathing.snap_to_component(x, z, mobility, component)
	stage_x = at.x
	stage_z = at.y


func _order(world: World, main: AiGroup, raiders: AiGroup, falling_back: bool) -> void:
	var rules: SkirmishRules = world.skirmish.rules
	match posture:
		Posture.STAGE:
			var attack: bool = not falling_back and (main.march_attack or main.phase == 1)
			world.ai.advance(world, main, stage_x, stage_z, ENGAGE_RADIUS, STAGE_HOLD_RADIUS, attack)
			if raiders != null:
				world.ai.advance(world, raiders, stage_x, stage_z, ENGAGE_RADIUS, STAGE_HOLD_RADIUS, attack)
		Posture.COMMIT, Posture.DEFEND:
			var hold: int = STAGE_HOLD_RADIUS
			if objective_flag >= 0:
				hold = maxi(rules.flag_radius - FLAG_HOLD_MARGIN, FLAG_HOLD_MARGIN)
			world.ai.advance(world, main, objective_x, objective_z, ENGAGE_RADIUS, hold, true)
			if raiders == null:
				return
			if posture == Posture.COMMIT:
				if raiders.behavior != AiGroupSpec.Behavior.FLANK:
					world.ai.set_behavior(world, raiders, AiGroupSpec.Behavior.FLANK)
			else:
				world.ai.advance(world, raiders, objective_x, objective_z, ENGAGE_RADIUS, hold, true)
