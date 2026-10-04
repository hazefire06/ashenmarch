class_name TriggerAction
extends Resource
## One effect of a TriggerSpec, applied when the trigger fires. Only the
## fields named for the kind are read. MissionScript.validate() checks them,
## because group names resolve against the script's group list.

## What the action does.
enum Kind {
	## Spawns the group named in `group`.
	SPAWN_GROUP,
	## Starts the weather change in `weather` now.
	SET_WEATHER,
	## Shows `text` as the mission objective.
	SET_OBJECTIVE,
	## The player wins the mission.
	WIN,
	## The player loses the mission.
	LOSE,
	## Switches the group named in `group` to `behavior`.
	SET_BEHAVIOR,
	## Reveals the objective named in `objective` (HIDDEN to ACTIVE; nothing
	## else changes).
	SHOW_OBJECTIVE,
	## Marks the objective named in `objective` done, from HIDDEN or ACTIVE. A
	## done or failed objective stays as it is.
	COMPLETE_OBJECTIVE,
	## Marks the objective named in `objective` failed, from HIDDEN or ACTIVE.
	## A done or failed objective stays as it is.
	FAIL_OBJECTIVE,
}

## What it does (see Kind), which says which of the fields below it reads.
@export var kind: Kind = Kind.SPAWN_GROUP
## SPAWN_GROUP, SET_BEHAVIOR: the group's name in the MissionScript, or an
## alias name of a MissionDraw (the group that was drawn for it).
@export var group: StringName = &""
## SET_WEATHER: what to ramp to. Its tick must be 0 (the change starts when
## the trigger fires); every other field is as WeatherChange documents.
@export var weather: WeatherChange
## SET_OBJECTIVE: the message-line text. Empty clears it. (The objectives in
## the panel are the ones the three objective kinds name.)
@export var text: String = ""
## SET_BEHAVIOR: the new behavior. RETREAT is entered by the AI, not set.
@export var behavior: AiGroupSpec.Behavior = AiGroupSpec.Behavior.HUNT
## SHOW_OBJECTIVE, COMPLETE_OBJECTIVE, FAIL_OBJECTIVE: the objective's name in
## the MissionScript.
@export var objective: StringName = &""
