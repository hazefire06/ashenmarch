class_name UnitAnimator
extends RefCounted
## Decides what a unit's art body plays, from what the sim says the unit is
## doing. One per art sprite: UnitsView feeds it once per sim tick
## (after_tick) and the sprite plays the Play it returns. It reads sim state
## and never writes it.
##
## Strikes are timed to the sim. When a wind-up starts (windup_left, aim_left
## or act_left goes from 0 to N ticks), the strike is sped up or slowed down
## so its impact frame shows on the tick the blow lands or the shot leaves.
## That is recomputed from the sim's own numbers every time, so retuned
## wind-ups and veterancy never desync it. A shot with no wind-up to watch
## starts at its release frame. A strike plays out before walking or idling
## resumes, and only death cuts it short. Walking plays at the speed the unit
## actually covers ground, so wading and climbing slow the legs. Paralysis
## freezes whatever is showing.

const MIN_SPEED: float = 0.25
const MAX_SPEED: float = 4.0
## Ground speed (m/s) below which a moving unit idles instead of treading air.
const MIN_WALK_SPEED: float = 0.05
## What a shot and an errand (heal, pick up, strike a plant) play, in order
## of preference: a unit's art has one of them.
const RANGED_ANIMS: Array[StringName] = [&"shoot", &"throw", &"cast"]
const ACT_ANIMS: Array[StringName] = [&"cast", &"place"]


## What the sim says about the unit this tick. Not called Input: GDScript
## refuses an inner class that hides the engine's Input.
class AnimInput:
	extends RefCounted
	var alive: bool = true
	var moving: bool = false
	## Meters per second it covered on the ground this tick.
	var ground_speed: float = 0.0
	var windup_left: int = 0
	var aim_left: int = 0
	var act_left: int = 0
	## It launched a projectile this tick (ProjectileEvent.LAUNCH).
	var launched: bool = false
	var paralyzed: bool = false


## What the body should play.
class Play:
	extends RefCounted
	var anim: StringName = &"idle"
	var speed_scale: float = 1.0
	## Start over (a new strike, a death) instead of carrying on.
	var restart: bool = false
	## The frame a restart starts on.
	var start_frame: int = 0


var _art: UnitArt
var _last_windup: int = 0
var _last_aim: int = 0
var _last_act: int = 0
var _strike: StringName = &""
var _strike_speed: float = 1.0
## Seconds of the strike still to play, at its speed.
var _strike_left: float = 0.0
var _dead: bool = false


func _init(art: UnitArt) -> void:
	_art = art


func after_tick(input: AnimInput) -> Play:
	var play: Play = Play.new()
	if not input.alive:
		play.anim = _pick([&"die"], &"idle")
		play.restart = not _dead
		_dead = true
		return play
	var strike: Play = _strike_started(input)
	_last_windup = input.windup_left
	_last_aim = input.aim_left
	_last_act = input.act_left
	if strike != null:
		_strike = strike.anim
		_strike_speed = strike.speed_scale
		_strike_left = _seconds(strike.anim, strike.start_frame) / strike.speed_scale
		play = strike
	elif _strike_left > 0.0:
		_strike_left -= 1.0 / World.TICK_RATE
		play.anim = _strike
		play.speed_scale = _strike_speed
	elif input.moving and input.ground_speed >= MIN_WALK_SPEED:
		play.anim = &"walk"
		play.speed_scale = clampf(
			input.ground_speed * _seconds(&"walk", 0) / _art.stride_m, MIN_SPEED, MAX_SPEED
		)
	if input.paralyzed:
		play.speed_scale = 0.0
	return play


## The death already played (the sprite was rebuilt): show the corpse, don't
## die again.
func mark_dead() -> void:
	_dead = true


func _strike_started(input: AnimInput) -> Play:
	if input.windup_left > 0 and _last_windup == 0:
		return _timed(_pick([&"attack"], &"idle"), input.windup_left)
	if input.aim_left > 0 and _last_aim == 0:
		return _timed(_pick(RANGED_ANIMS, &"attack"), input.aim_left)
	if input.act_left > 0 and _last_act == 0:
		return _timed(_pick(ACT_ANIMS, &"attack"), input.act_left)
	if input.launched and input.aim_left == 0 and _last_aim == 0:
		# No draw to watch (a zero-tick wind-up): show the release.
		var release: Play = Play.new()
		release.anim = _pick(RANGED_ANIMS, &"attack")
		release.restart = true
		release.start_frame = _art.impact_frames.get(release.anim, 0)
		return release
	return null


# The strike, sped so its impact frame shows `ticks` ticks from now.
func _timed(anim: StringName, ticks: int) -> Play:
	var play: Play = Play.new()
	play.anim = anim
	play.restart = true
	var impact: int = _art.impact_frames.get(anim, 0)
	var fps: float = _fps(anim)
	if impact > 0 and fps > 0.0:
		var natural: float = impact / fps
		var wanted: float = float(ticks) / World.TICK_RATE
		play.speed_scale = clampf(natural / wanted, MIN_SPEED, MAX_SPEED)
	return play


func _pick(preferred: Array[StringName], fallback: StringName) -> StringName:
	for anim: StringName in preferred:
		if _art.has_anim(anim):
			return anim
	return fallback if _art.has_anim(fallback) else &"idle"


func _fps(anim: StringName) -> float:
	return _art.frames.get_animation_speed(UnitArt.anim_name(anim, 0)) if _art.has_anim(anim) else 0.0


# Seconds the animation runs at speed 1 from frame `from` to its end.
func _seconds(anim: StringName, from: int) -> float:
	var fps: float = _fps(anim)
	if fps <= 0.0:
		return 0.0
	return (_art.frames.get_frame_count(UnitArt.anim_name(anim, 0)) - from) / fps
