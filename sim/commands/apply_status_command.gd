class_name ApplyStatusCommand
extends SimCommand
## Puts a status effect on a group's living units for a number of ticks
## (StatusEffects.apply: it extends a shorter one, never stacks). The F8 debug
## key sends it; mission scripts may later.

var unit_ids: PackedInt32Array
var kind: StatusEffects.Kind
var ticks: int


func _init(at_tick: int, ids: PackedInt32Array, status: StatusEffects.Kind, duration_ticks: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	kind = status
	ticks = duration_ticks


func apply(world: World) -> void:
	for unit: Unit in UnitOrders.living_units(world, unit_ids):
		StatusEffects.apply(world, unit, kind, ticks, 0)
