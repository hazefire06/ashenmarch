class_name RandomImpulseCommand
extends SimCommand
## Test-only: nudges an entity's horizontal velocity using the world's seeded
## RNG, so determinism tests exercise World.rng without adding placeholder
## gameplay to sim/.

var entity_id: int
var max_delta: int


func _init(at_tick: int, target_id: int, max_change: int) -> void:
	super(at_tick)
	entity_id = target_id
	max_delta = max_change


func apply(world: World) -> void:
	var entity: SimEntity = world.get_entity(entity_id)
	if entity == null:
		return
	entity.vx += world.rng.randi_range(-max_delta, max_delta)
	entity.vz += world.rng.randi_range(-max_delta, max_delta)
