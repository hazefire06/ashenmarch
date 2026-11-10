class_name UnitSound
extends Resource
## What one unit type sounds like: its weapon and body for melee, its death and
## groan cues, and the voices it speaks with. View only.

@export var type_id: StringName
## blade, heavy, staff, claw or stomp: picks the swing_<weapon> cue.
@export var weapon: StringName = &"blade"
## flesh or dry: picks the hit_<body> cue.
@export var body: StringName = &"flesh"
@export var death: StringName
## &"" for none.
@export var groan: StringName
## Voice ids; a unit speaks the one at its id modulo the count.
@export var voices: Array[StringName] = []
