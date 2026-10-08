class_name GuardCommand
extends SimCommand
## G: a group of units guards the spots they stand on (UnitOrders.guard).

var unit_ids: PackedInt32Array


func _init(at_tick: int, ids: PackedInt32Array) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()


func apply(world: World) -> void:
	UnitOrders.guard(world, unit_ids)
