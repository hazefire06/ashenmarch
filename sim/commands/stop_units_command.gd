class_name StopUnitsCommand
extends SimCommand
## Halts a group of units where they stand.

var unit_ids: PackedInt32Array


func _init(at_tick: int, ids: PackedInt32Array) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()


func apply(world: World) -> void:
	UnitOrders.stop(world, unit_ids)
