class_name KitPiece
extends Resource
## One model of the world kit (a house, a wall section, a gatehouse, the
## mill), with what StructurePlacer needs to fit it to a footprint. The
## scene's bounds are centred on its origin in x and z and start at y = 0, so
## its origin is the middle of its base.

@export var scene: PackedScene
## The native bounds: width (x), height (y) and depth (z), metres. A wall
## section runs along x and is z thick.
@export var size_m: Vector3 = Vector3.ONE
## The axis the door faces in the scene, x and z.
@export var door: Vector2i = Vector2i(0, 1)
