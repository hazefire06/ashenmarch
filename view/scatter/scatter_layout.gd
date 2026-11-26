class_name ScatterLayout
extends RefCounted
## What ScatterPlacer.place() returns: one entry per placed item, in the order
## they were placed. View only.

## Model names; models[] indexes into it.
var names: Array[StringName] = []
## Per item: its model (index into names).
var models: PackedInt32Array = PackedInt32Array()
## Per item: where it stands, its turn and tilt and its scale. The origin is
## on the drawn ground; the model's base centre goes there.
var transforms: Array[Transform3D] = []
## Per item: the Terrain.Ground whose recolor it takes (the ground under mud,
## rock on a cliff).
var grounds: PackedByteArray = PackedByteArray()


func size() -> int:
	return models.size()


## Items of the model called name.
func count_of(name: StringName) -> int:
	var index: int = names.find(name)
	if index < 0:
		return 0
	return models.count(index)
