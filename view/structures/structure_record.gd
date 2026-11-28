class_name StructureRecord
extends Resource
## One structure a map generator stamped (a house or a wall), kept beside the
## map so the view can draw a model where the sim sees only raised, blocked
## samples. View only: the sim never loads this.

## &"house" or &"wall".
@export var kind: StringName = &"house"
## A hint for which model to draw: &"" (choose by kind and seed) or &"mill".
@export var model: StringName = &""
## Footprint centre and size in metres (houses).
@export var center_m: Vector2 = Vector2.ZERO
@export var size_m: Vector2 = Vector2.ZERO
## House: the height of the ground the roof sits on, metres (the stamped top
## minus height_m). Wall: unused.
@export var base_m: float = 0.0
## Metres above its base (house) or above the ground beneath it (wall).
@export var height_m: float = 0.0
## The axis the house faces, a unit axis vector, or Vector2i.ZERO to choose by
## seed.
@export var facing: Vector2i = Vector2i.ZERO
## Walls only: the polyline, its thickness, and its gates (start, end metres
## along the polyline).
@export var points_m: PackedVector2Array = PackedVector2Array()
@export var thickness_m: float = 0.0
@export var gaps_m: PackedVector2Array = PackedVector2Array()
## Indices of the samples this structure made blocked.
@export var samples: PackedInt32Array = PackedInt32Array()
