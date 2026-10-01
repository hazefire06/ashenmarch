class_name ProjectileEvent
extends RefCounted
## Something projectiles did during a tick, for the view: launches, landings,
## bounces, blasts. Output only: World clears its list at the start of each
## step, and events are never part of state_hash(). Damage to units is
## reported as CombatEvents, like melee.

enum Kind {
	## A projectile left its launcher (unit_id).
	LAUNCH,
	## An arrow stuck in the ground at (x, y, z), flying along (dir_*).
	## depth is the water depth there.
	STICK,
	## An arrow struck a unit (unit_id) at (x, y, z).
	HIT,
	## A grenade or charge bounced at (x, y, z), speed um/tick into the ground.
	BOUNCE,
	## A blast at (x, y, z) of radius. crater is the crater dug (0 for an air
	## burst); cells is the terrain rectangle it changed, for re-meshing.
	EXPLODE,
	## A fuse went out at (x, y, z); the projectile is now a dud.
	FIZZLE,
	## A charge was dropped at (x, y, z) by unit_id (T, or on death).
	DROP,
	## A fire arrow lit the ground at (x, y, z), credited to unit_id (Fire).
	IGNITE,
	## A ground-attack order at (x, z) could not be carried out by unit_id:
	## out of reach from anywhere it can walk, or inside its minimum range.
	CANT_REACH,
}

var kind: Kind
var projectile_id: int = 0
## The projectile's type index in the catalog, or -1.
var type_index: int = -1
var unit_id: int = 0
var x: int = 0
var y: int = 0
var z: int = 0
## STICK: flight direction, any length.
var dir_x: int = 0
var dir_y: int = 0
var dir_z: int = 0
var radius: int = 0
var crater: int = 0
var depth: int = 0
var speed: int = 0
var cells: Rect2i = Rect2i()


func _init(event_kind: Kind, at_x: int = 0, at_y: int = 0, at_z: int = 0) -> void:
	kind = event_kind
	x = at_x
	y = at_y
	z = at_z


static func about(event_kind: Kind, p: Projectile) -> ProjectileEvent:
	var e: ProjectileEvent = ProjectileEvent.new(event_kind, p.x, p.y, p.z)
	e.projectile_id = p.id
	e.type_index = p.type_index
	return e
