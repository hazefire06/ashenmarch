class_name TriggerSpec
extends Resource
## A mission rule: when its condition holds (and the trigger named in `after`
## has fired), run its actions once. Triggers are checked in list order, and
## are hashed by their index in the MissionScript.
##
## Like WeatherChange.snow_cover, a few defaults are deliberately not zero so
## the common case needs no fields: faction LIGHT (the player's side),
## min_count and count of 1 (zero would never be satisfied, and validate()
## rejects it), and ticks of [0], so a TIMER with no ticks set fires the
## moment its prerequisite does.

enum Condition {
	## `min_count` units of `faction` are inside `area`.
	AREA_ENTERED,
	## `count` units have died across the groups in `names`.
	UNIT_DIES,
	## `ticks` have passed since the trigger became active.
	TIMER,
	## Every unit of every group in `names` is dead.
	GROUP_CLEARED,
	## `faction` has no units left.
	FACTION_ELIMINATED,
}

## Unique within a MissionScript; `after` refers to a trigger by it.
@export var name: StringName = &""
## The trigger that must have fired before this one is checked. Empty: active
## from mission start.
@export var after: StringName = &""
@export var condition: Condition = Condition.TIMER
## AREA_ENTERED: x, z, radius in milli-units.
@export var area: PackedInt32Array = PackedInt32Array()
## AREA_ENTERED: whose units count. FACTION_ELIMINATED: which side must be
## wiped out.
@export var faction: UnitType.Faction = UnitType.Faction.LIGHT
## AREA_ENTERED: how many units must be inside at once.
@export var min_count: int = 1
## UNIT_DIES, GROUP_CLEARED: the groups' names in the MissionScript.
@export var names: Array[StringName] = []
## UNIT_DIES: deaths needed, summed across the groups in `names`.
@export var count: int = 1
## TIMER: ticks to wait after the trigger becomes active, per tier: one entry
## for every tier or one per tier (Difficulty).
@export var ticks: PackedInt32Array = PackedInt32Array([0])
## What happens when it fires. May be empty: a trigger with no actions is a
## gate for the triggers that name it in `after`.
@export var actions: Array[TriggerAction] = []
