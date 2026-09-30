class_name SetVelocityCommand
extends SimCommand
## Sets an entity's velocity in milli-units per tick. No-op if the entity no
## longer exists.

var entity_id: int
var vx: int
var vy: int
var vz: int


func _init(at_tick: int, target_id: int, vel_x: int, vel_y: int, vel_z: int) -> void:
	super(at_tick)
	entity_id = target_id
	vx = vel_x
	vy = vel_y
	vz = vel_z


func apply(world: World) -> void:
	var entity: SimEntity = world.get_entity(entity_id)
	if entity == null:
		return
	entity.vx = vx
	entity.vy = vy
	entity.vz = vz
