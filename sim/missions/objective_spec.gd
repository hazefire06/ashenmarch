class_name ObjectiveSpec
extends Resource
## One thing the player is asked to do in a mission, listed in the objective
## panel: what it says, whether it is optional, and whether it shows from the
## start. Its state (hidden, active, done, failed) is MissionRuntime's, so this
## stays read-only like the rest of a MissionScript. Triggers refer to an
## objective by `name`; the HUD and the hash refer to it by its index in
## MissionScript.objectives.
##
## `shown_at_start` defaults to true, not false: most objectives are on the
## list from the first tick, and a hidden one is the exception that a trigger
## has to reveal (SHOW_OBJECTIVE).

## Unique within a MissionScript; the objective actions name it.
@export var name: StringName = &""
## What the panel says. Display only: it is not hashed.
@export var text: String = ""
## An optional objective doesn't have to be done to win; the panel marks it.
## The mission's WIN trigger decides what winning takes, so this is only a
## label for the player.
@export var optional: bool = false
## True: ACTIVE from the first tick. False: HIDDEN until a SHOW_OBJECTIVE (or
## a COMPLETE_OBJECTIVE or FAIL_OBJECTIVE, which settle it without showing it).
@export var shown_at_start: bool = true
