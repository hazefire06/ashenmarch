class_name MissionEvent
extends RefCounted
## Something that happened to the mission during a tick, for the HUD and for
## tests. Output only, like AiEvent: World clears its list at the start of
## each step, nothing in the sim may read it, and it is never hashed.

## What happened. Append only: determinism logs index counts by kind.
enum Kind {
	## A trigger fired; trigger_index is its place in the MissionScript.
	TRIGGER_FIRED,
	## A trigger set the objective to `text`.
	OBJECTIVE,
	## The mission was won; trigger_index is the trigger whose WIN decided it.
	WON,
	## The mission was lost; trigger_index is the trigger whose LOSE decided it.
	LOST,
	## An objective changed state; trigger_index is the trigger whose action did
	## it, `objective` the objective's place in MissionScript.objectives, and
	## `value` its new MissionRuntime.ObjectiveState. An action that changes
	## nothing (showing what is already shown, anything on a done or failed
	## objective) reports nothing.
	OBJECTIVE_STATE,
}

## What happened.
var kind: Kind
## The trigger it is about, by its index in the MissionScript.
var trigger_index: int
## OBJECTIVE only: the new objective text (empty clears it).
var text: String = ""
## OBJECTIVE_STATE only: the objective, by its index in MissionScript.objectives.
var objective: int = -1
## OBJECTIVE_STATE only: the objective's new state, a
## MissionRuntime.ObjectiveState value.
var value: int = 0


func _init(
	event_kind: Kind, trigger: int, event_text: String = "", event_objective: int = -1,
	event_value: int = 0
) -> void:
	kind = event_kind
	trigger_index = trigger
	text = event_text
	objective = event_objective
	value = event_value


## [kind, trigger_index], the form determinism logs compare; an OBJECTIVE_STATE
## adds the objective and its new state. The text is display only and left out.
func to_array() -> PackedInt64Array:
	if kind == Kind.OBJECTIVE_STATE:
		return PackedInt64Array([kind, trigger_index, objective, value])
	return PackedInt64Array([kind, trigger_index])
