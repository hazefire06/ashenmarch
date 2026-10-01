class_name Lightning
extends RefCounted
## Lightning (ProjectileType.Behavior.BOLT): no projectile flies. A bolt is a
## straight line from the caster's launch point through the point it aims at
## and on to the full reach of its range, cut short where it meets the
## ground. Everything along it is struck at once:
## - every living body the line passes within the bolt's half-width
##   (ProjectileType.radius) of, friend and foe, except the caster and units
##   submerged in deep water, in ascending id: impact_damage with a +-10 %
##   roll each, credited to the caster. Shields don't stop it;
## - every charge, grenade, gas packet, or dud the line passes within reach
##   of (lying, rolling, flying, or in someone's hand) is set off
##   (Explosions.catch), credited to the caster.
##
## RangedCombat decides who casts and where, makes the one lateral spread
## draw per bolt as the shot leaves, and strikes every bolt of the tick once
## all shots have left, in caster id order, so a caster killed by an earlier
## bolt that tick still casts (bolts, like melee blows, are simultaneous).
##
## RNG: per bolt, one damage roll per body struck, in ascending id.

## The line must be clear of the ground up to this many milli-units short of
## the point aimed at (a ground target ends in the ground).
const GROUND_SLACK: int = 1000
const DAMAGE_VARIANCE_PERMILLE: int = 100
const PERMILLE: int = 1000


## True if a bolt from unit aimed at (x, y, z) (milli-units) gets there: no
## ground in the way short of it. With careful, also no friend of unit's
## body within the half-width plus margin of the whole line, out to reach.
static func is_clear(
	world: World, unit: Unit, p: ProjectileType, x: int, y: int, z: int,
	careful: bool, margin: int, reach: int
) -> bool:
	var from: PackedInt64Array = launch_point(unit)
	var dist: int = FixedMath.length(x - from[0], z - from[2])
	if dist > GROUND_SLACK:
		var keep: int = dist - GROUND_SLACK
		var sx: int = from[0] + (x - from[0]) * keep / dist
		var sy: int = from[1] + (y - from[1]) * keep / dist
		var sz: int = from[2] + (z - from[2]) * keep / dist
		if _ground(world, from[0], from[1], from[2], sx, sy, sz) != ProjectileCollision.NO_CONTACT:
			return false
	if not careful:
		return true
	var end: PackedInt64Array = end_point(from, x, y, z, reach)
	for other: Unit in world.units:
		if other == unit or not other.is_alive() or other.faction != unit.faction:
			continue
		if _touches(other, from, end, p.radius + margin):
			return false
	return true


## Strikes a bolt of catalog type type_index cast by caster at (x, y, z),
## running on to reach (horizontal milli-units from the caster) unless the
## ground stops it first.
static func strike(world: World, caster: Unit, type_index: int, x: int, y: int, z: int, reach: int) -> void:
	var p: ProjectileType = world.catalog.projectile_types[type_index]
	var from: PackedInt64Array = launch_point(caster)
	var end: PackedInt64Array = end_point(from, x, y, z, reach)
	var hit: int = _ground(world, from[0], from[1], from[2], end[0], end[1], end[2])
	if hit != ProjectileCollision.NO_CONTACT:
		for i: int in 3:
			end[i] = ProjectileCollision._lerp(from[i], end[i], hit)
	for unit: Unit in world.units:
		if unit == caster or not unit.is_alive() or Visibility.is_submerged(world.terrain, unit):
			continue
		if not _touches(unit, from, end, p.radius):
			continue
		var variance: int = world.rng.randi_range(-DAMAGE_VARIANCE_PERMILLE, DAMAGE_VARIANCE_PERMILLE)
		var damage: int = maxi(1, FixedMath.div_round(p.impact_damage * (PERMILLE + variance), PERMILLE))
		Damage.apply(world, unit, damage, caster.x, caster.z, caster.id)
	# Deaths above drop charges into world.projectiles; this walk sees them,
	# which is right: the bolt passes through where they fall.
	for q: Projectile in world.projectiles:
		if q.removed or q.detonating or not q.type.chain_detonates:
			continue
		if distance_to_segment(q.x, q.y, q.z, from, end) <= p.radius + q.type.radius:
			Explosions.catch(world, q, caster.id)
	var e: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.BOLT, from[0], from[1], from[2])
	e.unit_id = caster.id
	e.type_index = type_index
	e.end_x = end[0]
	e.end_y = end[1]
	e.end_z = end[2]
	e.radius = p.radius
	world.projectile_events.append(e)


## Where unit's bolts leave it: x, y, z in milli-units.
static func launch_point(unit: Unit) -> PackedInt64Array:
	return PackedInt64Array([unit.x, unit.y + unit.type.ranged_launch_height, unit.z])


## The point reach (horizontal milli-units) from `from` along the line
## through (x, y, z); that point itself if it is right above or below.
static func end_point(from: PackedInt64Array, x: int, y: int, z: int, reach: int) -> PackedInt64Array:
	var dist: int = FixedMath.length(x - from[0], z - from[2])
	if dist == 0:
		return PackedInt64Array([x, y, z])
	return PackedInt64Array([
		from[0] + FixedMath.div_round((x - from[0]) * reach, dist),
		from[1] + FixedMath.div_round((y - from[1]) * reach, dist),
		from[2] + FixedMath.div_round((z - from[2]) * reach, dist),
	])


## Milli-units from (px, py, pz) to the nearest point of the segment a-b.
static func distance_to_segment(px: int, py: int, pz: int, a: PackedInt64Array, b: PackedInt64Array) -> int:
	var dx: int = b[0] - a[0]
	var dy: int = b[1] - a[1]
	var dz: int = b[2] - a[2]
	var length2: int = dx * dx + dy * dy + dz * dz
	var along: int = (px - a[0]) * dx + (py - a[1]) * dy + (pz - a[2]) * dz
	var cx: int = a[0]
	var cy: int = a[1]
	var cz: int = a[2]
	if length2 > 0 and along >= length2:
		cx = b[0]
		cy = b[1]
		cz = b[2]
	elif length2 > 0 and along > 0:
		cx += FixedMath.div_floor(dx * along, length2)
		cy += FixedMath.div_floor(dy * along, length2)
		cz += FixedMath.div_floor(dz * along, length2)
	return FixedMath.isqrt((px - cx) * (px - cx) + (py - cy) * (py - cy) + (pz - cz) * (pz - cz))


# True if the segment a-b, as wide as width either side, touches unit's body.
# Bodies outside the segment's box (grown by the width and the body) are
# ruled out first: besides saving the work, the swept-cylinder test's
# quadratic terms overflow 64 bits for a body hundreds of metres off a 40 m
# line, and would read as a hit. (ProjectileSystem only ever asks about
# bodies its grid found near the segment.)
static func _touches(unit: Unit, a: PackedInt64Array, b: PackedInt64Array, width: int) -> bool:
	var reach: int = width + unit.type.body_radius
	if (
		unit.x < mini(a[0], b[0]) - reach or unit.x > maxi(a[0], b[0]) + reach
		or unit.z < mini(a[2], b[2]) - reach or unit.z > maxi(a[2], b[2]) + reach
	):
		return false
	return ProjectileCollision.cylinder_contact(
		a[0], a[1], a[2], b[0], b[1], b[2], width,
		unit.x, unit.z, unit.type.body_radius, unit.y, unit.y + unit.type.body_height
	) != ProjectileCollision.NO_CONTACT


# Where the segment (milli-units) first meets the ground, as a fraction.
static func _ground(world: World, ax: int, ay: int, az: int, bx: int, by: int, bz: int) -> int:
	var s: int = FlightState.SUB
	return ProjectileCollision.ground_contact(world.terrain, ax * s, ay * s, az * s, bx * s, by * s, bz * s, 0)
