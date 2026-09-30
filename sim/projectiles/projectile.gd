class_name Projectile
extends SimEntity
## An arrow, grenade, or satchel charge: a SimEntity that ProjectileSystem
## moves with its own physics at micrometre precision (flight), not
## World._integrate(). x, y, z mirror the flight in milli-units and vx, vy,
## vz are the last tick's displacement, for the view.

enum Motion {
	## Under gravity and drag; sweeps for ground and bodies each tick.
	FLYING,
	## On the ground, pulled along the slope and slowed by rolling
	## resistance, until it lifts off a crest or comes to rest.
	ROLLING,
	## Lying still. Only a blast moves it again.
	RESTING,
}

var type: ProjectileType
## Index of type in the catalog's projectile_types; hashed instead of it.
var type_index: int
## The unit that launched or dropped it; 0 for none.
var owner_id: int
## The unit credited with kills if it explodes: the thrower, or whoever set
## off the blast that caught it. 0 for none.
var instigator_id: int
var flight: FlightState
var motion: Motion = Motion.FLYING
## Ticks until the lit fuse burns down; 0 when there is none burning.
var fuse_left: int = 0
## The fuse went out: it will never go off on its own, but a blast still
## sets it off.
var dud: bool = false
## Set once it is bound to explode (fuse ended, or caught by a blast), so
## nothing sets it off twice.
var detonating: bool = false
## Ticks until a caught charge goes off; 0 when none is counting.
var detonate_in: int = 0
## A body the projectile passes through for ignore_ticks more ticks: the
## launcher at release, or a body it just glanced off.
var ignore_id: int = 0
var ignore_ticks: int = 0
## Ticks since it was spawned.
var age: int = 0
## Flagged for removal; World drops it at the end of the tick, so the loops
## that flag it never see the array change under them.
var removed: bool = false


func _init(
	entity_id: int, projectile_type: ProjectileType, catalog_index: int,
	state: FlightState, owner: int
) -> void:
	super(entity_id, FlightState.to_mm(state.px), FlightState.to_mm(state.py), FlightState.to_mm(state.pz))
	flight = state
	type = projectile_type
	type_index = catalog_index
	owner_id = owner
	instigator_id = owner


## ProjectileSystem moves projectiles, with collision.
func integrate() -> void:
	pass


## Copies the flight's position to x, y, z (milli-units), with the change
## as the velocity.
func sync_position() -> void:
	var nx: int = FlightState.to_mm(flight.px)
	var ny: int = FlightState.to_mm(flight.py)
	var nz: int = FlightState.to_mm(flight.pz)
	vx = nx - x
	vy = ny - y
	vz = nz - z
	x = nx
	y = ny
	z = nz


func is_live() -> bool:
	return not removed


func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = super()
	fields.append_array(flight.hash_fields())
	fields.append_array(PackedInt64Array([
		type_index, owner_id, instigator_id, motion, fuse_left, 1 if dud else 0,
		1 if detonating else 0, detonate_in, ignore_id, ignore_ticks, age, 1 if removed else 0,
	]))
	return fields
