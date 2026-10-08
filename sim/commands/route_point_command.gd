class_name RoutePointCommand
extends SimCommand
## Shift+order: adds (x, z) to a group's routes in a formation
## (Formations.Kind), facing (facing_x, facing_z) there, or the automatic way
## if zero; with attack, a new route's legs are attack-moves. See
## UnitRoute.add_point.

var unit_ids: PackedInt32Array
var x: int
var z: int
var formation: int
var attack: bool
var facing_x: int
var facing_z: int


func _init(
	at_tick: int, ids: PackedInt32Array, target_x: int, target_z: int, formation_kind: int,
	attack_legs: bool, face_x: int = 0, face_z: int = 0
) -> void:
	super(at_tick)
	unit_ids = ids.duplicate()
	x = target_x
	z = target_z
	formation = formation_kind
	attack = attack_legs
	facing_x = face_x
	facing_z = face_z


func apply(world: World) -> void:
	UnitRoute.add_point(world, unit_ids, x, z, formation, attack, facing_x, facing_z)
