class_name AttackMoveCommand
extends SimCommand
## Moves a group of units to (x, z) in a formation (Formations.Kind), fighting
## the enemies they meet on the way. See UnitOrders.move.

var unit_ids: PackedInt32Array
var x: int
var z: int
var formation: int


func _init(at_tick: int, ids: PackedInt32Array, target_x: int, target_z: int, formation_kind: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	x = target_x
	z = target_z
	formation = formation_kind


func apply(world: World) -> void:
	UnitOrders.move(world, unit_ids, x, z, formation, true)
