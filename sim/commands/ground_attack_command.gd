class_name GroundAttackCommand
extends SimCommand
## Orders a group's ranged units to bombard the ground at (x, z): Cmd/Ctrl +
## left click. See UnitOrders.ground_attack.

var unit_ids: PackedInt32Array
var x: int
var z: int


func _init(at_tick: int, ids: PackedInt32Array, target_x: int, target_z: int) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	x = target_x
	z = target_z


func apply(world: World) -> void:
	UnitOrders.ground_attack(world, unit_ids, x, z)
