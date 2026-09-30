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
