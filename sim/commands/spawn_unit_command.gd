class_name SpawnUnitCommand
extends SimCommand
## Creates a unit of a catalog type on a side, standing at (x, z) or the
## nearest ground its mobility allows. No-op for an unknown type id.

var type_id: StringName
var faction: UnitType.Faction
var x: int
var z: int
var facing_x: int
var facing_z: int


func _init(
	at_tick: int, unit_type_id: StringName, side: UnitType.Faction,
	pos_x: int, pos_z: int, face_x: int = 0, face_z: int = -FixedMath.DIR_ONE
) -> void:
	super(at_tick)
	type_id = unit_type_id
	faction = side
	x = pos_x
	z = pos_z
	facing_x = face_x
	facing_z = face_z


func apply(world: World) -> void:
	if world.catalog == null:
		return
	world.spawn_unit(world.catalog.index_of(type_id), faction, x, z, facing_x, facing_z)
