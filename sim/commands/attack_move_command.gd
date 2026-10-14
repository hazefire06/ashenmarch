class_name AttackMoveCommand
extends SimCommand
## Moves a group of units to (x, z) in a formation (Formations.Kind), fighting
## the enemies they meet on the way, and faces (facing_x, facing_z) there; a
## zero facing is the automatic one. See UnitOrders.move.

var unit_ids: PackedInt32Array
var x: int
var z: int
var formation: int
var facing_x: int
var facing_z: int


func _init(
	at_tick: int, ids: PackedInt32Array, target_x: int, target_z: int, formation_kind: int,
	face_x: int = 0, face_z: int = 0
) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	x = target_x
	z = target_z
	formation = formation_kind
	facing_x = face_x
	facing_z = face_z


func apply(world: World) -> void:
	UnitOrders.move(world, unit_ids, x, z, formation, true, facing_x, facing_z)
