class_name ScatterModel
extends Resource
## One model of the ground scatter (a grass tuft, a plant, a bush, a pebble),
## with what ScatterPlacer and ScatterView need: its native bounds, and the
## offset that puts the middle of its base on the origin.

## The model's name in art-src/world/world.toml (lower case), e.g.
## &"grass_common_short"; ScatterPlacer's palettes refer to it.
@export var name: StringName = &""
## The imported glTF scene.
@export var scene: PackedScene
## The native bounds: width (x), height (y) and depth (z), metres.
@export var size_m: Vector3 = Vector3.ONE
## Added to the scene's own coordinates, it moves the bounds' base centre to
## the origin.
@export var offset: Vector3 = Vector3.ZERO
