class_name MissionEvent
extends RefCounted
## Something that happened to the mission during a tick, for the HUD and for
## tests. Output only, like AiEvent: World clears its list at the start of
## each step, nothing in the sim may read it, and it is never hashed.

enum Kind {
	## A trigger fired; trigger_index is its place in the MissionScript.
	TRIGGER_FIRED,
	## A trigger set the objective to `text`.
	OBJECTIVE,
	## The mission was won; trigger_index is the trigger whose WIN decided it.
	WON,
	## The mission was lost; trigger_index is the trigger whose LOSE decided it.
	LOST,
}

var kind: Kind
var trigger_index: int
## OBJECTIVE only: the new objective text (empty clears it).
var text: String = ""


func _init(event_kind: Kind, trigger: int, event_text: String = "") -> void:
	kind = event_kind
	trigger_index = trigger
	text = event_text


## [kind, trigger_index], the form determinism logs compare. The text is
## display only and left out.
func to_array() -> PackedInt64Array:
	return PackedInt64Array([kind, trigger_index])
