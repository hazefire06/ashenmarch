class_name MainView
extends Node3D
## Entry scene: owns the World and advances it one tick per physics frame.
## Draws a flat placeholder ground until Phase 1 terrain replaces it.

const WORLD_SEED: int = 1

var world: World

@onready var _tick_label: Label = $Hud/TickLabel


func _ready() -> void:
	# One physics frame is one sim tick, so the physics rate is the tick rate.
	Engine.physics_ticks_per_second = World.TICK_RATE
	world = World.new(WORLD_SEED)


func _physics_process(_delta: float) -> void:
	world.step()
	_tick_label.text = "tick %d" % world.tick
