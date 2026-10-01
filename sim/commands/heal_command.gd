class_name HealCommand
extends SimCommand
## T, then a click on a unit: the nearest Warden of the group with a herb
## left goes and heals it (or, if it is undead, kills it). See Interactions.

var unit_ids: PackedInt32Array
var target_id: int


func _init(at_tick: int, ids: PackedInt32Array, patient_id: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	target_id = patient_id


func apply(world: World) -> void:
	Interactions.order(world, unit_ids, target_id, Interactions.Action.HEAL)
