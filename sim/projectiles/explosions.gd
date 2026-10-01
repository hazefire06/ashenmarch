class_name Explosions
extends RefCounted
## Blasts, run by World.step() after ProjectileSystem. Projectiles bound to
## explode this tick (a fuse burned down, a chain countdown ended) are
## queued by detonate(); resolve() bursts them first come, first served,
## and each burst can set off more.
##
## One burst, in order:
## 1. Units: everyone whose body is within blast_radius (3D distance from
##    the burst to the nearest point of the body's cylinder), friend and
##    foe alike, in ascending id. Damage is full within blast_inner_radius
##    and falls off linearly to nothing at blast_radius; there is no roll.
## 2. Knockback: everyone within knock_radius is thrown away from the burst,
##    fastest at the center (knock_speed) and not at all at the edge. It is
##    horizontal; UnitMovement carries it and bleeds it off.
## 3. Charges dropped by units that just died (a Sapper's satchels) land
##    now, so a Sapper caught in a blast cooks off its own charges.
## 4. Loose objects: every charge, grenade, or dud within blast_radius that
##    isn't already bound to explode is caught (catch(): fire catches them
##    the same way): it goes off CHAIN_DELAY_TICKS later, credited to
##    whoever set off this one. Other
##    loose objects within knock_radius are thrown (arrows in flight aren't
##    touched).
## 5. Gas: a cloud (GasCloud) hangs where it burst, if the type has gas.
## 6. Scatter: the type's scatter_projectile, scatter_count of them, lie in a
##    ring scatter_radius out, at rest (a Blightbag's gas packets). They come
##    after step 4, so this burst doesn't set them off.
## 7. A crater, if the burst was near enough the ground (Terrain.scar).
##    Craters never change where anyone can walk.
##
## Units die in step 1, before step 4 walks the projectiles: a death drops
## charges or a burst into world.projectiles, which that walk then visits.
## Steps 5 and 6 spawn after it. Gas alone hurts no one and sets nothing off:
## only a blast does.
##
## Kills are credited to the burst's instigator: the thrower of a grenade,
## or whoever set off the blast that caught a charge.

## Ticks from a charge being caught to it going off: a visible ripple down a
## line of satchels rather than one flash.
const CHAIN_DELAY_TICKS: int = 4
## Loose objects are thrown upward at this share of their outward speed.
const KNOCK_LIFT_PERMILLE: int = 500
const PERMILLE: int = 1000

var _queue: Array[Projectile] = []
var _largest_radius: int = -1


## Binds p to explode during this tick's resolve().
func detonate(_world: World, p: Projectile) -> void:
	if p.removed:
		return
	p.detonating = true
	p.detonate_in = 0
	p.fuse_left = 0
	_queue.append(p)


## Sets off a loose charge, grenade, or dud caught by a blast, a fire, or
## lightning (or a Blightbag's burst at its death): it goes off exactly
## CHAIN_DELAY_TICKS ticks after this one, credited to instigator_id. The
## caller checks it can be (chain_detonates, not already detonating).
## ProjectileSystem counts the delay down, so one caught before it has run
## this tick gets a tick more (World.projectile_pass_begun). Nothing already
## lying about is caught during the pass itself; only charges spawned in it
## (a Blightbag an arrow killed), which it doesn't count this tick.
static func catch(world: World, p: Projectile, instigator_id: int) -> void:
	p.detonating = true
	p.detonate_in = CHAIN_DELAY_TICKS + (0 if world.projectile_pass_begun else 1)
	p.fuse_left = 0
	p.instigator_id = instigator_id


## Bursts every queued projectile, including ones set off by earlier bursts
## this tick with no delay (none today; CHAIN_DELAY_TICKS spreads chains
## over ticks). grid holds the bodies after this tick's movement.
func resolve(world: World, grid: UnitGrid) -> void:
	if _largest_radius < 0:
		_largest_radius = 0
		for t: UnitType in world.catalog.types:
			_largest_radius = maxi(_largest_radius, t.body_radius)
	var i: int = 0
	while i < _queue.size():
		var p: Projectile = _queue[i]
		i += 1
		if not p.removed:
			_burst(world, grid, p)
	_queue.clear()


## Pending bursts, for World.state_hash(). Always empty between ticks.
func queued() -> int:
	return _queue.size()


## Share (permille) of full blast damage at distance d from the burst.
static func falloff_permille(t: ProjectileType, d: int) -> int:
	if d >= t.blast_radius:
		return 0
	if d <= t.blast_inner_radius:
		return PERMILLE
	return (t.blast_radius - d) * PERMILLE / (t.blast_radius - t.blast_inner_radius)


## Distance (milli-units) from a point to the nearest point of a unit's
## body, an upright cylinder from its feet (y) to y + body_height. 0 inside.
static func distance_to_body(unit: Unit, x: int, y: int, z: int) -> int:
	var dx: int = x - unit.x
	var dz: int = z - unit.z
	var out: int = maxi(0, FixedMath.length(dx, dz) - unit.type.body_radius)
	var dy: int = 0
	if y < unit.y:
		dy = unit.y - y
	elif y > unit.y + unit.type.body_height:
		dy = y - unit.y - unit.type.body_height
	return FixedMath.isqrt(out * out + dy * dy)


func _burst(world: World, grid: UnitGrid, p: Projectile) -> void:
	var t: ProjectileType = p.type
	var bx: int = p.x
	var by: int = p.y
	var bz: int = p.z
	world.remove_projectile(p)
	var reach: int = maxi(t.blast_radius, t.knock_radius)
	# The grid gives nearby bodies in bucket order; blasts treat them in id
	# order so damage and credit don't depend on where anyone stood.
	var near: Array[Unit] = []
	if reach > 0:
		near = grid.near(bx, bz, reach + _largest_radius)
	near.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)
	for unit: Unit in near:
		if not unit.is_alive():
			continue
		var d: int = distance_to_body(unit, bx, by, bz)
		var share: int = falloff_permille(t, d)
		if share > 0:
			var damage: int = maxi(1, FixedMath.div_round(t.blast_damage * share, PERMILLE))
			if Damage.apply(world, unit, damage, bx, bz, p.instigator_id):
				continue
		_knock_unit(t, unit, bx, bz, d)
	for other: Projectile in world.projectiles:
		if other.removed or other.detonating:
			continue
		var d: int = maxi(0, FixedMath.isqrt(
			(other.x - bx) * (other.x - bx) + (other.y - by) * (other.y - by) + (other.z - bz) * (other.z - bz)
		) - other.type.radius)
		if other.type.chain_detonates and d < t.blast_radius:
			catch(world, other, p.instigator_id)
		elif (
			d < t.knock_radius and other.type.behavior == ProjectileType.Behavior.BOUNCES
			and other.motion != Projectile.Motion.CARRIED
		):
			# Something in a hand stays there.
			_knock_object(t, other, bx, bz, d)
	if t.gas_radius > 0:
		world.spawn_cloud(bx, by, bz, t, p.instigator_id)
	if t.scatter_projectile != &"":
		var index: int = world.catalog.projectile_index_of(t.scatter_projectile)
		for k: int in t.scatter_count:
			var angle: int = k * FixedMath.ANGLE_FULL / t.scatter_count
			world.drop_object(
				index,
				bx + FixedMath.cos_b(angle) * t.scatter_radius / FixedMath.TRIG_ONE,
				bz + FixedMath.sin_b(angle) * t.scatter_radius / FixedMath.TRIG_ONE,
				0
			)
	var e: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.EXPLODE, bx, by, bz)
	e.projectile_id = p.id
	e.type_index = p.type_index
	e.radius = t.effect_radius()
	if t.crater_radius > 0 and by - world.terrain.height_at(bx, bz) <= t.crater_radius:
		e.cells = world.terrain.scar(bx, bz, t.crater_radius, t.crater_depth)
		e.crater = t.crater_radius
	world.projectile_events.append(e)


# Throws a living unit away from the burst at (bx, bz), d away.
static func _knock_unit(t: ProjectileType, unit: Unit, bx: int, bz: int, d: int) -> void:
	var speed: int = _knock_speed(t, d)
	if speed <= 0:
		return
	var dir: Vector2i = _away(unit.x - bx, unit.z - bz, unit.id)
	# mm/s to mm/tick.
	unit.knock_vx += FixedMath.div_round(dir.x * speed, FixedMath.DIR_ONE * World.TICK_RATE)
	unit.knock_vz += FixedMath.div_round(dir.y * speed, FixedMath.DIR_ONE * World.TICK_RATE)
	if unit.is_reeling():
		# Thrown off its feet: a swing or a draw in progress is lost.
		unit.clear_engagement()
		unit.clear_shot()


# Throws a loose object: outward and up, wherever it was lying or flying.
static func _knock_object(t: ProjectileType, p: Projectile, bx: int, bz: int, d: int) -> void:
	var speed: int = _knock_speed(t, d)
	if speed <= 0:
		return
	var dir: Vector2i = _away(p.x - bx, p.z - bz, p.id)
	var per_tick: int = FlightState.speed_from_mm_per_s(speed)
	p.flight.vx += FixedMath.div_round(dir.x * per_tick, FixedMath.DIR_ONE)
	p.flight.vz += FixedMath.div_round(dir.y * per_tick, FixedMath.DIR_ONE)
	p.flight.vy += per_tick * KNOCK_LIFT_PERMILLE / PERMILLE
	p.motion = Projectile.Motion.FLYING


# mm/s at distance d: knock_speed at the burst, falling to 0 at knock_radius.
static func _knock_speed(t: ProjectileType, d: int) -> int:
	if t.knock_radius <= 0 or d >= t.knock_radius:
		return 0
	return t.knock_speed * (t.knock_radius - d) / t.knock_radius


# Direction (length DIR_ONE) from the burst toward (dx, dz). Something right
# on top of it gets a direction from its id, the same on every peer.
static func _away(dx: int, dz: int, entity_id: int) -> Vector2i:
	var dir: Vector2i = FixedMath.normalize(dx, dz, FixedMath.DIR_ONE)
	if dir != Vector2i.ZERO:
		return dir
	var angle: int = (entity_id * 97) % FixedMath.ANGLE_FULL
	return Vector2i(
		FixedMath.cos_b(angle) * FixedMath.DIR_ONE / FixedMath.TRIG_ONE,
		FixedMath.sin_b(angle) * FixedMath.DIR_ONE / FixedMath.TRIG_ONE
	)
