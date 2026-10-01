class_name StandoffSpot
extends RefCounted
## Where a STANDOFF unit (UnitType.AiTactic.STANDOFF: a Stormcaller, a
## Drifter) should stand to shoot a target, whether where it stands will do,
## and whether an enemy has got inside its dead zone. Static and pure: it
## reads the world and changes nothing; AiTactics moves the unit.
##
## A spot is on the circle of ai_standoff_permille of the unit's range about
## the target. The first tried is straight back along the line from the
## target to the unit, the shortest walk; then the line swung 22.5 degrees
## either way, then 45. So a friend in the line, or an enemy near the first
## spot, sends the unit round rather than through. A spot will do if:
## - it is on the map, in the pathing component the unit stands in;
## - no enemy the unit's side can see is inside its dead zone there
##   (ranged_min_range + DEAD_ZONE_MARGIN), the target included;
## - the target is within the unit's range from there, shortened uphill;
## - and the line is clear: for a bolt, the check RangedCombat makes before it
##   casts (Lightning.is_clear_from, careful); for anything else, no friend
##   within FRIEND_CORRIDOR of the straight line to the target.

## Binary angles (1024 to a turn) the line from the target is swung by, in
## the order tried: straight back, 22.5 degrees each way, then 45.
const ANGLES: Array[int] = [0, 64, -64, 128, -128]
## Milli-units beyond ranged_min_range an enemy must stay for a spot to do,
## so an enemy closing in doesn't step inside the minimum range a moment after
## the unit gets there.
const DEAD_ZONE_MARGIN: int = 2000
## Milli-units from a friend's center to the straight line from a spot to its
## target within which an archer or thrower won't take the spot. RangedCombat
## checks the real flight before it shoots; this keeps the AI from choosing a
## spot that puts a friend in the way to begin with.
const FRIEND_CORRIDOR: int = 1500
## ai_standoff_permille is in parts per this many.
const PERMILLE: int = 1000


## A spot for unit to shoot target from, [x, z] in milli-units, or empty if
## none of the five will do.
static func find(world: World, unit: Unit, target: Unit) -> PackedInt64Array:
	var t: UnitType = unit.type
	var radius: int = t.ranged_max_range * t.ai_standoff_permille / PERMILLE
	var component: int = world.pathing.component_at(unit.x, unit.z, t.mobility)
	if component == PathLayer.NO_COMPONENT:
		return PackedInt64Array()
	var dir: Vector2i = FixedMath.normalize(unit.x - target.x, unit.z - target.z, FixedMath.DIR_ONE)
	if dir == Vector2i.ZERO:
		dir = Vector2i(0, -FixedMath.DIR_ONE)
	var enemies: Array[Unit] = AiOrders.enemies(world, unit.faction)
	for angle: int in ANGLES:
		var offset: Vector2i = FixedMath.rotate_local(
			FixedMath.div_round(radius * FixedMath.sin_b(angle), FixedMath.TRIG_ONE),
			FixedMath.div_round(radius * FixedMath.cos_b(angle), FixedMath.TRIG_ONE),
			dir.x, dir.y
		)
		var x: int = target.x + offset.x
		var z: int = target.z + offset.y
		if not world.terrain.contains(x, z) or world.pathing.component_at(x, z, t.mobility) != component:
			continue
		if _fits(world, unit, target, enemies, x, z, radius):
			return PackedInt64Array([x, z])
	return PackedInt64Array()


## True if where unit stands will do to shoot target from: the target is in
## range and out of the dead zone, no other enemy is in the dead zone, and
## the line is clear. The same checks as a spot find() offers.
static func holds(world: World, unit: Unit, target: Unit) -> bool:
	var dist: int = FixedMath.length(unit.x - target.x, unit.z - target.z)
	return _fits(world, unit, target, AiOrders.enemies(world, unit.faction), unit.x, unit.z, dist)


## True if an enemy unit's side can see stands inside its dead zone (within
## ranged_min_range + DEAD_ZONE_MARGIN, center to center): it can't shoot it,
## or soon won't, and should get out.
static func threatened(world: World, unit: Unit) -> bool:
	var dead_zone: int = unit.type.ranged_min_range + DEAD_ZONE_MARGIN
	return _enemy_within(AiOrders.enemies(world, unit.faction), unit.x, unit.z, dead_zone)


# Whether unit could shoot target from (x, z), dist from it, with enemies
# (what its side can see) about.
static func _fits(
	world: World, unit: Unit, target: Unit, enemies: Array[Unit], x: int, z: int, dist: int
) -> bool:
	var t: UnitType = unit.type
	var dead_zone: int = t.ranged_min_range + DEAD_ZONE_MARGIN
	if dist <= dead_zone or _enemy_within(enemies, x, z, dead_zone):
		return false
	var from_y: int = world.terrain.height_at(x, z) + t.hover_height + t.ranged_launch_height
	var ground: int = world.terrain.height_at(target.x, target.z)
	var chest: int = RangedCombat.chest_height(target, ground)
	var rise: int = chest - from_y
	if dist > RangedCombat.effective_max_range(unit, rise, dist):
		return false
	var p: ProjectileType = world.catalog.find_projectile(t.ranged_projectile)
	if p.behavior == ProjectileType.Behavior.BOLT:
		# As RangedCombat aims one: the spread from the rise to the chest, the
		# reach from the rise to the ground there.
		var from: PackedInt64Array = PackedInt64Array([x, from_y, z])
		var reach: int = RangedCombat.effective_max_range(unit, ground - from_y, dist)
		return Lightning.is_clear_from(
			world, unit, from, p, target.x, chest, target.z, true,
			RangedCombat.PATH_MARGIN, RangedCombat.spread_for(unit, rise, dist), reach
		)
	var a: PackedInt64Array = PackedInt64Array([x, 0, z])
	var b: PackedInt64Array = PackedInt64Array([target.x, 0, target.z])
	for other: Unit in world.units:
		if other == unit or not other.is_alive() or other.faction != unit.faction:
			continue
		if Lightning.distance_to_segment(other.x, 0, other.z, a, b) <= FRIEND_CORRIDOR:
			return false
	return true


# True if one of enemies stands within radius of (x, z), center to center.
static func _enemy_within(enemies: Array[Unit], x: int, z: int, radius: int) -> bool:
	for enemy: Unit in enemies:
		if FixedMath.length(enemy.x - x, enemy.z - z) <= radius:
			return true
	return false
