class_name InteractCommand
extends SimCommand
## Right-click on something that isn't ground: the nearest unit of the group
## that can do something with entity_id goes and does it (Interactions): a
## Warden picks up a herb, a Ripper picks up a loose object or tears a part
## off a body, anyone who fights in melee strikes a herb plant. The rest of
## the group keeps its orders. Nothing happens if no one can.

var unit_ids: PackedInt32Array
var entity_id: int


func _init(at_tick: int, ids: PackedInt32Array, target_id: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	entity_id = target_id


func apply(world: World) -> void:
	Interactions.order(world, unit_ids, entity_id)
