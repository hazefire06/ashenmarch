class_name RetreatCommand
extends SimCommand
## R: a group of units falls back from the nearest enemy in a formation
## (Formations.Kind) and ends facing it (UnitOrders.retreat).

var unit_ids: PackedInt32Array
var formation: int


func _init(at_tick: int, ids: PackedInt32Array, formation_kind: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	formation = formation_kind


func apply(world: World) -> void:
	UnitOrders.retreat(world, unit_ids, formation)
