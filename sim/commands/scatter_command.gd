class_name ScatterCommand
extends SimCommand
## B: a group of units scatters from its centroid (UnitOrders.scatter).

var unit_ids: PackedInt32Array


func _init(at_tick: int, ids: PackedInt32Array) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()


func apply(world: World) -> void:
	UnitOrders.scatter(world, unit_ids)
