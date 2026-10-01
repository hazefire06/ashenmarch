class_name ProjectileSystem
extends RefCounted
## Moves every projectile one tick with its own physics (no Godot physics),
## run by World.step() after units have moved and before Explosions.
##
## Per projectile, in ascending id order:
## - FLYING: one FlightState.advance(), then the segment it swept is tested
##   against the ground and against living bodies (upright cylinders); the
##   earliest contact wins, a body winning a tie with the ground, the lower
##   id winning among bodies.
##   - An arrow stops at its first contact: in a body it deals its damage
##     (a frontal shield may block it) and is gone; in the ground it sticks
##     (a STICK event; the view keeps stuck arrows, the sim doesn't).
##   - A grenade or charge bounces: the speed into the surface comes back
##     scaled by restitution, the speed along it by friction. A rebound too
##     slow to leave the ground starts it rolling. Bodies deflect it without
##     harm. The rest of that tick's travel is dropped: at most 33 ms per
##     bounce, and it keeps a tick to exactly one contact.
## - ROLLING: gravity along the slope (scaled by roll_accel), rolling
##   resistance against the motion, velocity kept tangent to the ground. It
##   lifts off where the ground drops away faster than it follows, and
##   comes to rest when slow on gentle enough ground.
## - RESTING: doesn't move.
## - Then fuses and chain countdowns: a fuse that burns down rolls for a
##   fizzle (the dud stays, and a blast can still set it off) or queues the
##   explosion; a caught charge goes off when its countdown ends.
##
## Weather and water (Phase 5): a fuse fizzles more in rain and snow, and on
## snow-covered ground (fizzle_permille). A lit fuse that touches water of
## depth 1 or more (a bounce, a roll, coming to rest) goes out at once, with
## no roll: it is a dud from then on. A fire arrow rolls once for its flame
## when it lands, but only if that chance isn't zero, so in clear weather it
## draws nothing a plain arrow doesn't; a flame that goes out (FIZZLE) lights
## no fire, though the arrow still wounds.
##
## Units are tested at their positions after this tick's movement. A unit
## killed earlier in the same pass (a lower-id arrow) no longer stops later
## arrows: they fly on past the falling body.
##
## RNG draws, in projectile id order: an arrow striking a body draws a block
## roll (front arc of a shielded target only) then its damage variance; a
## fire arrow landing then draws its flame's fizzle roll (only when the
## chance isn't zero); a fuse burning down draws the fizzle roll.

## Normals from the ground gradient have this length.
const N_ONE: int = 65536
## Micrometres per tick into the ground below which a bounce becomes a roll
## (1.5 m/s).
const ROLL_SPEED: int = 50_000
## Micrometres a rolling object may sit above the ground before it counts as
## airborne: more than a tick of gravity's pull (5.5 mm), so it doesn't
## flicker to FLYING on every bump.
const LIFT_OFF: int = 20_000
## Ticks a projectile passes through a body it just glanced off.
const GLANCE_TICKS: int = 3
## Ticks an arrow ignores its launcher, and a thrown charge its thrower.
const LAUNCH_IGNORE_TICKS: int = 8
## Flying projectiles farther than this (milli-units) outside the map are
## gone for good.
const OFF_MAP_MARGIN: int = 50_000
## Arrow damage varies uniformly by up to this much either way, permille.
const DAMAGE_VARIANCE_PERMILLE: int = 100
## Bucket edge of the per-tick grid of bodies.
const GRID_BUCKET: int = 8000
const PERMILLE: int = 1000

## Bodies after this tick's movement, for hit tests here and in Explosions.
var grid: UnitGrid
var _largest_radius: int = -1


func update(world: World) -> void:
	if _largest_radius < 0:
		_largest_radius = 0
		for t: UnitType in world.catalog.types:
			_largest_radius = maxi(_largest_radius, t.body_radius)
	grid = UnitGrid.new(world.units, GRID_BUCKET)
	# Charges dropped during this pass are appended past n and first move
	# next tick.
	var n: int = world.projectiles.size()
	for i: int in n:
		var p: Projectile = world.projectiles[i]
		if p.removed:
			continue
		p.age += 1
		if p.ignore_ticks > 0:
			p.ignore_ticks -= 1
		match p.motion:
			Projectile.Motion.FLYING:
				_fly(world, p)
			Projectile.Motion.ROLLING:
				_roll(world, p)
		if p.removed:
			continue
		p.sync_position()
		_burn(world, p)


## Chance in permille that a burning projectile's flame goes out: its type's
## own chance, rain and snow falling (each scaled by its intensity), and,
## when it lies on the ground, the snow covering it. They combine as
## independent chances: 1 - (1 - base)(1 - rain)(1 - snow)(1 - cover).
## Zero for anything that doesn't burn.
static func fizzle_permille(world: World, p: Projectile, on_ground: bool) -> int:
	var t: ProjectileType = p.type
	if not t.burns():
		return 0
	var w: Weather = world.weather
	var cover: int = w.snow_cover() * t.snow_cover_fizzle_permille / PERMILLE if on_ground else 0
	var keep: int = (
		(PERMILLE - t.fizzle_permille)
		* (PERMILLE - w.rain * t.rain_fizzle_permille / PERMILLE)
		* (PERMILLE - w.snow * t.snow_fizzle_permille / PERMILLE)
		* (PERMILLE - cover)
	) / (PERMILLE * PERMILLE * PERMILLE)
	return PERMILLE - keep


## Surface normal of the ground at (x, z) milli-units, length N_ONE, from
## the gradient (permille rise per metre): (-gx, 1000, -gz) normalized.
static func ground_normal(terrain: Terrain, x: int, z: int) -> Vector3i:
	var g: Vector2i = terrain.gradient_at(x, z)
	# Scale up before the root so the floor error is negligible.
	var nx: int = -g.x * 1024
	var ny: int = PERMILLE * 1024
	var nz: int = -g.y * 1024
	var length: int = FixedMath.isqrt(nx * nx + ny * ny + nz * nz)
	return Vector3i(
		FixedMath.div_round(nx * N_ONE, length),
		FixedMath.div_round(ny * N_ONE, length),
		FixedMath.div_round(nz * N_ONE, length)
	)


func _fly(world: World, p: Projectile) -> void:
	var f: FlightState = p.flight
	var ax: int = f.px
	var ay: int = f.py
	var az: int = f.pz
	f.advance(p.type.drag_ppm_per_m)
	var terrain: Terrain = world.terrain
	var ground: int = ProjectileCollision.ground_contact(terrain, ax, ay, az, f.px, f.py, f.pz, p.type.radius)
	var body: Unit = null
	var body_frac: int = ProjectileCollision.NO_CONTACT
	for unit: Unit in _bodies_near(world, ax, az, f.px, f.pz):
		if unit.id == p.ignore_id and p.ignore_ticks > 0:
			continue
		var frac: int = _body_contact(unit, ax, ay, az, f, p.type.radius)
		if frac == ProjectileCollision.NO_CONTACT:
			continue
		if body_frac == ProjectileCollision.NO_CONTACT or frac < body_frac or (frac == body_frac and unit.id < body.id):
			body = unit
			body_frac = frac
	if body != null and (ground == ProjectileCollision.NO_CONTACT or body_frac <= ground):
		_move_to(f, ax, ay, az, body_frac)
		if p.type.behavior == ProjectileType.Behavior.STICKS:
			_strike(world, p, body)
		else:
			_glance(p, body)
		return
	if ground != ProjectileCollision.NO_CONTACT:
		_move_to(f, ax, ay, az, ground)
		if p.type.behavior == ProjectileType.Behavior.STICKS:
			_stick(world, p)
		else:
			_bounce(world, p)
		return
	var mx: int = FlightState.to_mm(f.px)
	var mz: int = FlightState.to_mm(f.pz)
	if (
		mx < -OFF_MAP_MARGIN or mz < -OFF_MAP_MARGIN
		or mx > terrain.extent_x() + OFF_MAP_MARGIN or mz > terrain.extent_z() + OFF_MAP_MARGIN
	):
		world.remove_projectile(p)


# Living, visible bodies whose cylinders the segment a -> b (um) could touch.
func _bodies_near(world: World, ax: int, az: int, bx: int, bz: int) -> Array[Unit]:
	var mx: int = FlightState.to_mm((ax + bx) / 2)
	var mz: int = FlightState.to_mm((az + bz) / 2)
	var half: int = FixedMath.isqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)) / FlightState.SUB / 2
	var out: Array[Unit] = []
	for unit: Unit in grid.near(mx, mz, half + _largest_radius + 1000):
		if unit.is_alive() and not Visibility.is_submerged(world.terrain, unit):
			out.append(unit)
	return out


static func _body_contact(unit: Unit, ax: int, ay: int, az: int, f: FlightState, radius: int) -> int:
	return ProjectileCollision.cylinder_contact(
		FlightState.to_mm(ax), FlightState.to_mm(ay), FlightState.to_mm(az),
		FlightState.to_mm(f.px), FlightState.to_mm(f.py), FlightState.to_mm(f.pz), radius,
		unit.x, unit.z, unit.type.body_radius, unit.y, unit.y + unit.type.body_height
	)


# Puts the flight at the fraction frac of the way from a to where it is now.
static func _move_to(f: FlightState, ax: int, ay: int, az: int, frac: int) -> void:
	f.px = ProjectileCollision._lerp(ax, f.px, frac)
	f.py = ProjectileCollision._lerp(ay, f.py, frac)
	f.pz = ProjectileCollision._lerp(az, f.pz, frac)


# An arrow flies into a body: shield (front arc only), then damage.
func _strike(world: World, p: Projectile, target: Unit) -> void:
	var f: FlightState = p.flight
	# The arrow came from the way it is flying from.
	var back: Vector2i = FixedMath.normalize(-f.vx, -f.vz, FixedMath.DIR_ONE)
	var from_x: int = target.x + back.x
	var from_z: int = target.z + back.y
	var aspect: MeleeCombat.Aspect = MeleeCombat.aspect_of(target, from_x, from_z)
	p.sync_position()
	var hit: ProjectileEvent = ProjectileEvent.about(ProjectileEvent.Kind.HIT, p)
	hit.unit_id = target.id
	world.projectile_events.append(hit)
	var block: int = target.type.shield_block_permille
	if aspect == MeleeCombat.Aspect.FRONT and block > 0 and world.rng.randi_range(0, PERMILLE - 1) < block:
		world.combat_events.append(CombatEvent.new(CombatEvent.Kind.BLOCK, p.owner_id, target.id, aspect))
	else:
		var variance: int = world.rng.randi_range(-DAMAGE_VARIANCE_PERMILLE, DAMAGE_VARIANCE_PERMILLE)
		var damage: int = maxi(1, FixedMath.div_round(p.type.impact_damage * (PERMILLE + variance), PERMILLE))
		Damage.apply(world, target, damage, from_x, from_z, p.owner_id, aspect)
	if p.type.marks_fire and not _flame_goes_out(world, p, false):
		world.ignite(target.x, target.z, p.instigator_id)
	world.remove_projectile(p)


# An arrow meets the ground: it stays there for the view, not the sim.
func _stick(world: World, p: Projectile) -> void:
	var f: FlightState = p.flight
	p.sync_position()
	var e: ProjectileEvent = ProjectileEvent.about(ProjectileEvent.Kind.STICK, p)
	e.dir_x = f.vx
	e.dir_y = f.vy
	e.dir_z = f.vz
	e.depth = world.terrain.water_depth_at(p.x, p.z)
	world.projectile_events.append(e)
	if p.type.marks_fire and not _flame_goes_out(world, p, true):
		world.ignite(p.x, p.z, p.instigator_id)
	world.remove_projectile(p)


# A fire arrow's flame on landing: rolls to go out (in a body, or stuck in
# the ground where snow can smother it), but only when there is a chance, so
# clear weather draws nothing. Reports a fizzle.
static func _flame_goes_out(world: World, p: Projectile, on_ground: bool) -> bool:
	var chance: int = fizzle_permille(world, p, on_ground)
	if chance <= 0 or world.rng.randi_range(0, PERMILLE - 1) >= chance:
		return false
	world.projectile_events.append(ProjectileEvent.about(ProjectileEvent.Kind.FIZZLE, p))
	return true


# A grenade or charge meets the ground.
func _bounce(world: World, p: Projectile) -> void:
	var f: FlightState = p.flight
	var mx: int = FlightState.to_mm(f.px)
	var mz: int = FlightState.to_mm(f.pz)
	var n: Vector3i = ground_normal(world.terrain, mx, mz)
	var into: int = -_along(f, n)
	var event: ProjectileEvent = ProjectileEvent.new(
		ProjectileEvent.Kind.BOUNCE, mx, FlightState.to_mm(f.py), mz
	)
	event.projectile_id = p.id
	event.type_index = p.type_index
	event.speed = maxi(into, 0)
	world.projectile_events.append(event)
	_rest_on_ground(world.terrain, p)
	_douse_if_in_water(world, p)
	if into <= 0:
		return
	var rebound: int = into * p.type.restitution_permille / PERMILLE
	_reflect(f, n, into, p.type.friction_permille, rebound)
	if rebound < ROLL_SPEED:
		# Too slow to leave the ground: slide along it from here.
		_remove_normal(f, n)
		p.motion = Projectile.Motion.ROLLING


# A grenade or charge flies into a body: it glances off, harmlessly.
func _glance(p: Projectile, unit: Unit) -> void:
	var f: FlightState = p.flight
	var n: Vector2i = FixedMath.normalize(
		FlightState.to_mm(f.px) - unit.x, FlightState.to_mm(f.pz) - unit.z, N_ONE
	)
	if n == Vector2i.ZERO:
		n = FixedMath.normalize(-f.vx, -f.vz, N_ONE)
	var normal: Vector3i = Vector3i(n.x, 0, n.y)
	var into: int = -_along(f, normal)
	if into > 0:
		_reflect(f, normal, into, p.type.friction_permille, into * p.type.restitution_permille / PERMILLE)
	p.ignore_id = unit.id
	p.ignore_ticks = GLANCE_TICKS


func _roll(world: World, p: Projectile) -> void:
	var f: FlightState = p.flight
	var terrain: Terrain = world.terrain
	var t: ProjectileType = p.type
	var mx: int = FlightState.to_mm(f.px)
	var mz: int = FlightState.to_mm(f.pz)
	var n: Vector3i = ground_normal(terrain, mx, mz)
	# Gravity's pull along the surface: g - (g . n) n with g = (0, -G, 0),
	# which is G * ny * (nx, ny, nz) - (0, G, 0), scaled by roll_accel.
	var pull: int = FlightState.GRAVITY * t.roll_accel_permille / PERMILLE
	f.vx += FixedMath.div_round(FixedMath.div_round(pull * n.y, N_ONE) * n.x, N_ONE)
	f.vy += FixedMath.div_round(FixedMath.div_round(pull * n.y, N_ONE) * n.y, N_ONE) - pull
	f.vz += FixedMath.div_round(FixedMath.div_round(pull * n.y, N_ONE) * n.z, N_ONE)
	# Stay on the surface: no velocity into it.
	if _along(f, n) < 0:
		_remove_normal(f, n)
	# Rolling resistance, proportional to how hard the ground pushes back
	# (g cos(theta), and ny is cos(theta)).
	var speed: int = f.speed()
	var resist: int = FixedMath.div_round(_per_tick2(t.rolling_resistance) * n.y, N_ONE)
	if speed <= resist:
		f.vx = 0
		f.vy = 0
		f.vz = 0
		speed = 0
	elif speed > 0:
		f.vx -= FixedMath.div_round(f.vx * resist, speed)
		f.vy -= FixedMath.div_round(f.vy * resist, speed)
		f.vz -= FixedMath.div_round(f.vz * resist, speed)
		speed -= resist
	if speed < _per_tick(t.rest_speed) and terrain.slope_at(mx, mz) <= t.static_slope_permille:
		f.vx = 0
		f.vy = 0
		f.vz = 0
		p.motion = Projectile.Motion.RESTING
		_rest_on_ground(terrain, p)
		_douse_if_in_water(world, p)
		return
	var ax: int = f.px
	var ay: int = f.py
	var az: int = f.pz
	f.px += f.vx
	f.py += f.vy
	f.pz += f.vz
	var nx_mm: int = FlightState.to_mm(f.px)
	var nz_mm: int = FlightState.to_mm(f.pz)
	if not terrain.contains(nx_mm, nz_mm):
		# The map edge stops it dead.
		f.px = ax
		f.py = ay
		f.pz = az
		f.vx = 0
		f.vy = 0
		f.vz = 0
		p.motion = Projectile.Motion.RESTING
		return
	for unit: Unit in _bodies_near(world, ax, az, f.px, f.pz):
		if unit.id == p.ignore_id and p.ignore_ticks > 0:
			continue
		var frac: int = _body_contact(unit, ax, ay, az, f, t.radius)
		if frac != ProjectileCollision.NO_CONTACT:
			_move_to(f, ax, ay, az, frac)
			_glance(p, unit)
			break
	var rest_y: int = (terrain.height_at(FlightState.to_mm(f.px), FlightState.to_mm(f.pz)) + t.radius) * FlightState.SUB
	if f.py - rest_y > LIFT_OFF:
		# The ground fell away (a crest, a lip): it flies from here.
		p.motion = Projectile.Motion.FLYING
	else:
		f.py = rest_y
		_douse_if_in_water(world, p)


# Fuse and chain countdown.
func _burn(world: World, p: Projectile) -> void:
	if p.fuse_left > 0:
		p.fuse_left -= 1
		if p.fuse_left == 0 and not p.detonating:
			var on_ground: bool = p.motion != Projectile.Motion.FLYING
			if world.rng.randi_range(0, PERMILLE - 1) < fizzle_permille(world, p, on_ground):
				p.dud = true
				world.projectile_events.append(ProjectileEvent.about(ProjectileEvent.Kind.FIZZLE, p))
			else:
				world.explosions.detonate(world, p)
	if p.detonate_in > 0:
		p.detonate_in -= 1
		if p.detonate_in == 0:
			world.explosions.detonate(world, p)


# A lit fuse touching water (the ground under it is at depth 1 or more) goes
# out for good: no roll, and the projectile is a dud from now on.
static func _douse_if_in_water(world: World, p: Projectile) -> void:
	if p.fuse_left <= 0 or p.detonating:
		return
	var f: FlightState = p.flight
	var mx: int = FlightState.to_mm(f.px)
	var mz: int = FlightState.to_mm(f.pz)
	var depth: int = world.terrain.water_depth_at(mx, mz)
	if depth <= 0:
		return
	p.fuse_left = 0
	p.dud = true
	var e: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.FIZZLE, mx, FlightState.to_mm(f.py), mz)
	e.projectile_id = p.id
	e.type_index = p.type_index
	e.depth = depth
	world.projectile_events.append(e)


# Sits the projectile on the ground under it if it has sunk into it.
static func _rest_on_ground(terrain: Terrain, p: Projectile) -> void:
	var f: FlightState = p.flight
	var rest_y: int = (terrain.height_at(FlightState.to_mm(f.px), FlightState.to_mm(f.pz)) + p.type.radius) * FlightState.SUB
	f.py = maxi(f.py, rest_y)


# Velocity component along a unit normal n (length N_ONE), um/tick.
static func _along(f: FlightState, n: Vector3i) -> int:
	return FixedMath.div_round(f.vx * n.x + f.vy * n.y + f.vz * n.z, N_ONE)


# Bounce off a surface with normal n: `into` (um/tick, > 0) was the speed
# into it. The part along the surface keeps friction (permille); the part
# into it comes back as rebound.
static func _reflect(f: FlightState, n: Vector3i, into: int, friction: int, rebound: int) -> void:
	# Tangential part: v + into * n (into is positive, v . n is -into).
	var tx: int = f.vx + FixedMath.div_round(into * n.x, N_ONE)
	var ty: int = f.vy + FixedMath.div_round(into * n.y, N_ONE)
	var tz: int = f.vz + FixedMath.div_round(into * n.z, N_ONE)
	f.vx = tx * friction / PERMILLE + FixedMath.div_round(rebound * n.x, N_ONE)
	f.vy = ty * friction / PERMILLE + FixedMath.div_round(rebound * n.y, N_ONE)
	f.vz = tz * friction / PERMILLE + FixedMath.div_round(rebound * n.z, N_ONE)


static func _remove_normal(f: FlightState, n: Vector3i) -> void:
	var along: int = _along(f, n)
	f.vx -= FixedMath.div_round(along * n.x, N_ONE)
	f.vy -= FixedMath.div_round(along * n.y, N_ONE)
	f.vz -= FixedMath.div_round(along * n.z, N_ONE)


# mm/s to um/tick.
static func _per_tick(mm_per_s: int) -> int:
	return FlightState.speed_from_mm_per_s(mm_per_s)


# mm/s^2 to um/tick^2.
static func _per_tick2(mm_per_s2: int) -> int:
	return FixedMath.div_round(mm_per_s2 * FlightState.SUB, World.TICK_RATE * World.TICK_RATE)
