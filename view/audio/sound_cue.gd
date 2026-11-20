class_name SoundCue
extends Resource
## One named sound: its variants and how they play. Data only; the SfxPlayer
## decides when. View only: nothing here touches the sim.

## melee, projectile, death, groan, ui, march, bed or music.
@export var id: StringName
@export var category: StringName
## The variants; one is picked at random each time the cue plays.
@export var streams: Array[AudioStream] = []
@export var bus: StringName = &"Effects"
@export var level_db: float = 0.0
## Random pitch spread either side of 1.0.
@export var pitch_spread: float = 0.06
## The most of this cue that may start in one tick.
@export var max_voices: int = 3
@export var loop: bool = false
@export var playback: AudioServer.PlaybackType = AudioServer.PLAYBACK_TYPE_DEFAULT
## Bytes of the imported files, for the audio budget.
@export var file_bytes: int = 0
