class_name SpawnEntityCommand
extends SimCommand
## Creates an entity at a position given in milli-units.

var x: int
var y: int
var z: int


func _init(at_tick: int, pos_x: int, pos_y: int, pos_z: int) -> void:
	super(at_tick)
	x = pos_x
	y = pos_y
	z = pos_z


func apply(world: World) -> void:
	world.spawn_entity(x, y, z)
