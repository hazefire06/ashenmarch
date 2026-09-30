class_name FormationSlot
extends RefCounted
## One target position in a formation, and the facing a unit takes on arrival.
## Position is world milli-units; facing is a direction of length
## FixedMath.DIR_ONE.

var x: int
var z: int
var facing_x: int
var facing_z: int


func _init(slot_x: int, slot_z: int, face_x: int, face_z: int) -> void:
	x = slot_x
	z = slot_z
	facing_x = face_x
	facing_z = face_z
