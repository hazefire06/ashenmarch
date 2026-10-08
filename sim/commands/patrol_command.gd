class_name PatrolCommand
extends SimCommand
## Closes a group's routes into a patrol: UnitRoute.Mode.LOOP or
## BACK_AND_FORTH (UnitRoute.close).

var unit_ids: PackedInt32Array
var mode: UnitRoute.Mode


func _init(at_tick: int, ids: PackedInt32Array, patrol_mode: UnitRoute.Mode) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	mode = patrol_mode


func apply(world: World) -> void:
	UnitRoute.close(world, unit_ids, mode)
