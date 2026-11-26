class_name ScatterSet
extends Resource
## The ground scatter's models (data/world/scatter.tres, written by
## scripts/art/build_scatter_set.gd from the imported Stylized Nature MegaKit
## models). An empty set scatters nothing.

const PATH: String = "res://data/world/scatter.tres"

@export var models: Array[ScatterModel] = []


## The set at PATH, or an empty one when there is none yet.
static func shared() -> ScatterSet:
	if not ResourceLoader.exists(PATH):
		return ScatterSet.new()
	return load(PATH) as ScatterSet


## The model called name, or null.
func find(name: StringName) -> ScatterModel:
	for model: ScatterModel in models:
		if model.name == name:
			return model
	return null


## Native height in metres per model name, what ScatterPlacer sizes by.
func native_heights() -> Dictionary[StringName, float]:
	var heights: Dictionary[StringName, float] = {}
	for model: ScatterModel in models:
		heights[model.name] = model.size_m.y
	return heights
