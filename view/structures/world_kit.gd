class_name WorldKit
extends Resource
## The kit models StructuresView places: houses to choose from by footprint
## shape, a wall section, a gatehouse and the mill. A piece left null is drawn
## as a grey box.

const PATH: String = "res://data/world/kit.tres"

@export var houses: Array[KitPiece] = []
@export var wall: KitPiece
@export var gate: KitPiece
@export var mill: KitPiece


## The kit at PATH, or an empty one when there is none yet.
static func shared() -> WorldKit:
	if not ResourceLoader.exists(PATH):
		return WorldKit.new()
	return load(PATH) as WorldKit
