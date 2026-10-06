class_name MissionDraw
extends Resource
## A random draw a mission makes once, when it starts: some of the groups in
## `pool` are picked and bound to the alias names in `slots`, so the same
## script plays out differently each time (Old Mill's waves). Triggers name a
## slot instead of a group, and the name means whichever group was bound to it;
## a pool group that wasn't picked never spawns and nothing can refer to it.
##
## The pick is World.roll_bindings, from the world's seed, so a replay or a
## lockstep peer rolls the same draw. Never change a draw at runtime: load()
## hands every world the same instance.

## The alias names, one per pick. A slot name can stand wherever a group name
## can in a trigger or action, and must not be the name of a group. One group
## is bound to each slot, so there can be no more slots than pool entries.
@export var slots: Array[StringName] = []
## The groups the picks come from, by group name. They must not spawn at start
## and can only be named through the slots: validate() rejects a trigger that
## names one directly, because it might not have been drawn.
@export var pool: Array[StringName] = []
## False: the picks are bound to the slots in the order they were drawn. True:
## in ascending pool order, so a pool listed easiest-first escalates: slot 1
## gets the easiest of the groups picked, and so on.
@export var ordered: bool = false
