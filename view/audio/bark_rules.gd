class_name BarkRules
extends RefCounted
## When a bark may sound: per-trigger cooldowns, the repeat-order rule for one
## squad, the side-wide gap for kill, hurt and death, one bark at a time (a death
## cuts in), the annoyed click counter, the clan line, and a shuffle bag per
## voice and trigger. Pure: time arrives as `now` in seconds, and chance comes
## only from `rng`, which the caller seeds.

## A repeat order to the same set of ids inside this gets only the tone.
const SQUAD_REPEAT_S: float = 5.0
## Kill, hurt and death share this gap, side-wide.
const SIDE_GAP_S: float = 4.0
## About one bark in ten is a clan line.
const CLAN_CHANCE: float = 0.1
## A unit selected this many times within the window is annoyed.
const ANNOYED_CLICKS: int = 4
const ANNOYED_WINDOW_S: float = 3.0

## Cooldown by trigger family; a trigger not listed has none.
const COOLDOWNS: Dictionary[StringName, float] = {
	&"select": 10.0,
	&"formation": 8.0,
	&"status": 6.0,
	&"annoyed": 6.0,
	&"fizzle": 6.0,
	&"heal_undead": 8.0,
	&"special": 3.0,
}
const SIDE_GAPPED: Array[StringName] = [&"kill", &"hurt", &"death"]

var rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _speaking_until: float = -INF
var _side_until: float = -INF
var _cooldown_until: Dictionary[StringName, float] = {}
var _squad_last: Dictionary[String, float] = {}
var _clicks: Dictionary[int, Array] = {}
var _last_was_clan: bool = false
var _bags: Dictionary[StringName, ShuffleBag] = {}


## The cooldown family: formation_* and status_* share one each.
func family(trigger: StringName) -> StringName:
	var name: String = String(trigger)
	if name.begins_with("formation_"):
		return &"formation"
	if name.begins_with("status_"):
		return &"status"
	return trigger


## True when this bark may sound now. A refusal records nothing.
func allow(trigger: StringName, now: float, squad: PackedInt32Array = PackedInt32Array()) -> bool:
	if trigger != &"death" and speaking(now):
		return false
	if now < _cooldown_until.get(family(trigger), -INF):
		return false
	if SIDE_GAPPED.has(trigger) and now < _side_until:
		return false
	if not squad.is_empty():
		var key: String = _squad_key(squad)
		if _squad_last.has(key) and now - _squad_last[key] < SQUAD_REPEAT_S:
			return false
	return true


## A bark began: it speaks for `seconds`, and starts its cooldown, the side gap
## when it is gapped, and the squad's repeat clock.
func started(trigger: StringName, now: float, seconds: float,
		squad: PackedInt32Array = PackedInt32Array()) -> void:
	_speaking_until = now + seconds
	var fam: StringName = family(trigger)
	if COOLDOWNS.has(fam):
		_cooldown_until[fam] = now + COOLDOWNS[fam]
	if SIDE_GAPPED.has(trigger):
		_side_until = now + SIDE_GAP_S
	if not squad.is_empty():
		_squad_last[_squad_key(squad)] = now


func speaking(now: float) -> bool:
	return now < _speaking_until


## True when this click is the ANNOYED_CLICKS-th within the window for the unit;
## its count then starts again.
func click(unit_id: int, now: float) -> bool:
	var kept: Array = []
	for t: float in _clicks.get(unit_id, []):
		if now - t <= ANNOYED_WINDOW_S:
			kept.append(t)
	kept.append(now)
	if kept.size() >= ANNOYED_CLICKS:
		_clicks.erase(unit_id)
		return true
	_clicks[unit_id] = kept
	return false


## Whether this bark should be a clan line: a roll, never right after one.
func clan_turn() -> bool:
	var roll: float = rng.randf()
	if _last_was_clan:
		return false
	return roll < CLAN_CHANCE


func note_clan(was_clan: bool) -> void:
	_last_was_clan = was_clan


## The next line index for a voice and trigger ("<voice>/<trigger>").
func pick(key: StringName, count: int) -> int:
	var bag: ShuffleBag = _bags.get(key)
	if bag == null:
		bag = ShuffleBag.new(count)
		_bags[key] = bag
	return bag.next(rng)


# Ids sorted on a copy, so the same set in any order is one squad.
func _squad_key(squad: PackedInt32Array) -> String:
	var ids: PackedInt32Array = squad.duplicate()
	ids.sort()
	return ",".join(Array(ids).map(func(i: int) -> String: return str(i)))
