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

## What has to hold for the trigger to fire. Only the fields named for it are
## read.
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
	## At least `min_count` of the triggers named in `names` have fired, each on
	## an earlier tick. A link takes a tick, like `after`, so it never sees a
	## trigger that fired this tick. `min_count` 1 is any-of, the number of
	## names is all-of. Unlike `after` it can wait on several triggers at once.
	TRIGGERS_FIRED,
	## `faction` has no living unit that a player commands (one the AI didn't
	## spawn), and has had one since the mission started. A Light group the
	## mission spawns doesn't count either way, so a LOSE on this isn't held off
	## by allies, and doesn't fire on tick 0 in a mission whose Light units
	## arrive later.
	PLAYER_ELIMINATED,
}

## Unique within a MissionScript; `after` refers to a trigger by it.
@export var name: StringName = &""
## The trigger that must have fired before this one is checked. Empty: active
## from mission start.
@export var after: StringName = &""
## What has to hold for it to fire (see Condition).
@export var condition: Condition = Condition.TIMER
## AREA_ENTERED: x, z, radius in milli-units.
@export var area: PackedInt32Array = PackedInt32Array()
## AREA_ENTERED: whose units count. FACTION_ELIMINATED: which side must be
## wiped out. PLAYER_ELIMINATED: the side the player commands.
@export var faction: UnitType.Faction = UnitType.Faction.LIGHT
## AREA_ENTERED: how many units must be inside at once. TRIGGERS_FIRED: how
## many of `names` must have fired.
@export var min_count: int = 1
## UNIT_DIES, GROUP_CLEARED: the groups' names in the MissionScript, or the
## alias names of a MissionDraw. AREA_ENTERED: the same, optional; when set, only
## units those groups spawned count, instead of every unit of `faction`.
## TRIGGERS_FIRED: the names of the triggers to wait for.
@export var names: Array[StringName] = []
## UNIT_DIES: deaths needed, summed across the groups in `names`.
@export var count: int = 1
## TIMER: ticks to wait after the trigger becomes active, per tier: one entry
## used at every tier, or one per tier (Difficulty).
@export var ticks: PackedInt32Array = PackedInt32Array([0])
## What happens when it fires. May be empty: a trigger with no actions is a
## gate for the triggers that name it in `after`.
@export var actions: Array[TriggerAction] = []
