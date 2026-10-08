class_name SfxBank
extends RefCounted
## The placeholder sound effects (scripts/gen_sfx.py, assets/audio/sfx) by
## name, with the level each plays at. View only: nothing here touches the sim.

const STREAMS: Dictionary[StringName, AudioStream] = {
	&"ui_click": preload("res://assets/audio/sfx/ui_click.wav"),
	&"order_ack": preload("res://assets/audio/sfx/order_ack.wav"),
	&"order_deny": preload("res://assets/audio/sfx/order_deny.wav"),
	&"sword_hit": preload("res://assets/audio/sfx/sword_hit.wav"),
	&"shield_block": preload("res://assets/audio/sfx/shield_block.wav"),
	&"death": preload("res://assets/audio/sfx/death.wav"),
	&"bow_release": preload("res://assets/audio/sfx/bow_release.wav"),
	&"arrow_impact": preload("res://assets/audio/sfx/arrow_impact.wav"),
	&"grenade_bounce": preload("res://assets/audio/sfx/grenade_bounce.wav"),
	&"explosion": preload("res://assets/audio/sfx/explosion.wav"),
	&"lightning": preload("res://assets/audio/sfx/lightning.wav"),
	&"fire_ignite": preload("res://assets/audio/sfx/fire_ignite.wav"),
	&"heal": preload("res://assets/audio/sfx/heal.wav"),
	&"gas_hiss": preload("res://assets/audio/sfx/gas_hiss.wav"),
	&"rain_loop": preload("res://assets/audio/sfx/rain_loop.wav"),
	&"fire_loop": preload("res://assets/audio/sfx/fire_loop.wav"),
}

## Decibels each plays at, before distance and the bus volumes. Frequent small
## sounds sit lower so a melee of fifty doesn't drown a blast.
const LEVELS_DB: Dictionary[StringName, float] = {
	&"ui_click": -10.0, &"order_ack": -8.0, &"order_deny": -6.0,
	&"sword_hit": -9.0, &"shield_block": -9.0, &"death": -6.0,
	&"bow_release": -10.0, &"arrow_impact": -12.0, &"grenade_bounce": -10.0,
	&"explosion": 0.0, &"lightning": 0.0, &"fire_ignite": -6.0,
	&"heal": -6.0, &"gas_hiss": -6.0, &"rain_loop": -4.0, &"fire_loop": -4.0,
}


static func stream(sound: StringName) -> AudioStream:
	return STREAMS.get(sound)


static func level_db(sound: StringName) -> float:
	return LEVELS_DB.get(sound, 0.0)
