class_name SimEntity
extends RefCounted
## A simulated object. Position is in milli-units (World.UNITS_PER_METER per
## meter); velocity is milli-units per tick.

var id: int
var x: int
var y: int
var z: int
var vx: int = 0
var vy: int = 0
var vz: int = 0


func _init(entity_id: int, pos_x: int, pos_y: int, pos_z: int) -> void:
	id = entity_id
	x = pos_x
	y = pos_y
	z = pos_z


## Moves the entity by its velocity; World calls this once per tick after
## steering. Projectiles override it: ProjectileSystem moves them with
## collision instead.
func integrate() -> void:
	x += vx
	y += vy
	z += vz


## Every field that defines this entity's state, for World.state_hash().
## Subclasses append their own fields.
func hash_fields() -> PackedInt64Array:
	return PackedInt64Array([id, x, y, z, vx, vy, vz])
