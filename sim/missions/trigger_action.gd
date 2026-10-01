class_name TriggerAction
extends Resource
## One effect of a TriggerSpec, applied when the trigger fires. Only the
## fields named for the kind are read. MissionScript.validate() checks them,
## because group names resolve against the script's group list.

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
}

@export var kind: Kind = Kind.SPAWN_GROUP
## SPAWN_GROUP, SET_BEHAVIOR: the group's name in the MissionScript.
@export var group: StringName = &""
## SET_WEATHER: what to ramp to. Its tick must be 0 (the change starts when
## the trigger fires); every other field is as WeatherChange documents.
@export var weather: WeatherChange
## SET_OBJECTIVE: the objective text. Empty clears it.
@export var text: String = ""
## SET_BEHAVIOR: the new behavior. RETREAT is entered by the AI, not set.
@export var behavior: AiGroupSpec.Behavior = AiGroupSpec.Behavior.HUNT
