class_name SpawnHerbPlantCommand
extends SimCommand
## Plants a herb plant on the ground at (x, z): MainView sends one for each
## the map lists (MapInfo.herb_plants), as tick-0 commands like the spawns.

var x: int
var z: int


func _init(at_tick: int, at_x: int, at_z: int) -> void:
	super(at_tick)
	x = at_x
	z = at_z


func apply(world: World) -> void:
	world.spawn_herb_plant(x, z)
