class_name AiUnitEntry
extends Resource
## One kind of unit in an AiGroupSpec and how many of it spawn at each
## difficulty tier.

## Id of a UnitType in the catalog, e.g. &"husk".
@export var type_id: StringName = &""
## How many spawn, per tier: one entry used at every tier, or one per tier
## (Difficulty). Each is at least 0, so a harder tier can add a type an easier
## one lacks.
@export var counts: PackedInt32Array = PackedInt32Array()
