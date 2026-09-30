class_name SimCommand
extends RefCounted
## Base for every change applied to the World from outside the sim (player
## input, AI orders, mission scripts). Commands are immutable data scheduled
## for a specific tick; this is the stream lockstep multiplayer and replays
## will carry.

## The tick at whose start this command is applied.
var tick: int


func _init(at_tick: int) -> void:
	tick = at_tick


func apply(_world: World) -> void:
	push_error("%s does not override apply()" % get_script().resource_path)
