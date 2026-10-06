class_name RosterEntry
extends Resource
## One kind of soldier in a MissionDef's fixed roster and how many deploy at
## each difficulty tier. Entries are listed in deploy order, which is the order
## the formation lays them out front to back, so authors list melee first.
##
## `counts` defaults to [1] (one at every tier) and `carryover` to true, the
## common case: Godot leaves defaults out of a .tres, so a mission's file only
## spells out what differs.

## Id of a Light UnitType in the catalog, e.g. &"shieldman".
@export var type_id: StringName = &""
## How many deploy, per tier: one entry used at every tier, or one per tier
## (Difficulty). Each is at least 0, so a harder tier can ask for fewer or more
## of a type; a mission must still deploy someone at every tier.
@export var counts: PackedInt32Array = PackedInt32Array([1])
## True: the slots are filled from the campaign's surviving soldiers of this
## type first, and only the empty ones get fresh recruits. False: every slot is
## a recruit (a unit the story hands the player, whatever was lost before).
@export var carryover: bool = true
