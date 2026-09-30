class_name UseSpecialCommand
extends SimCommand
## T: each unit in the group uses its special (a Sapper drops a charge, a
## Longbow nocks its fire arrow). See UnitOrders.use_special.

var unit_ids: PackedInt32Array


func _init(at_tick: int, ids: PackedInt32Array) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()


func apply(world: World) -> void:
	UnitOrders.use_special(world, unit_ids)
