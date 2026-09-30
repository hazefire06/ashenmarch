class_name DespawnEntityCommand
extends SimCommand
## Removes an entity. No-op if it no longer exists.

var entity_id: int


func _init(at_tick: int, target_id: int) -> void:
	super(at_tick)
	entity_id = target_id


func apply(world: World) -> void:
	world.despawn_entity(entity_id)
