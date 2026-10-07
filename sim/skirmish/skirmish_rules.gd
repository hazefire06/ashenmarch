class_name SkirmishRules
extends RefCounted
## How a skirmish is scored and when it ends: the mode, the time limit, the
## flags (copied from the SkirmishMap, so the runtime needs nothing else), and
## which side is the player's. SkirmishRuntime plays them out. Read-only once
## the skirmish starts; hashed with the runtime, so two worlds started with
## different rules never hash alike.

## What the sides are scored on. Append only: the mode is hashed.
enum Mode {
	## Enemy deaths, whatever the cause, at the time limit.
	BODY_COUNT,
	## Ticks spent holding the hill (alone inside its radius) at the limit.
	KING_OF_THE_HILL,
	## Flags owned at the limit; total flag-owned ticks break a tie.
	CAPTURE_THE_FLAGS,
}

## Ticks a side must stand alone at a flag to capture it (5 s).
const CAPTURE_TICKS: int = 5 * World.TICK_RATE

var mode: Mode = Mode.BODY_COUNT
## How long the skirmish runs, in ticks from its start.
var time_limit_ticks: int = 0
## Ticks of sole presence that capture a flag (Capture the Flags).
var capture_ticks: int = CAPTURE_TICKS
## The side the player commands. The sim decides a winning side
## (SkirmishRuntime.winner); the mission's outcome (WON, LOST, DRAW) is that
## result from this side's point of view.
var player_faction: UnitType.Faction = UnitType.Faction.LIGHT
## The flags as x, z pairs in milli-units.
var flags: PackedInt32Array = PackedInt32Array()
## Which flag is the hill (an index into flags).
var hill: int = 0
## How close, center to center, a unit must stand to a flag to count as at it.
var flag_radius: int = 0


## Rules for a skirmish on `skirmish_map` in `chosen_mode`, `minutes` long,
## with the player on `side`.
static func for_map(
	skirmish_map: SkirmishMap, chosen_mode: Mode, minutes: int, side: UnitType.Faction
) -> SkirmishRules:
	var rules: SkirmishRules = SkirmishRules.new()
	rules.mode = chosen_mode
	rules.time_limit_ticks = minutes * 60 * World.TICK_RATE
	rules.player_faction = side
	rules.flags = skirmish_map.flags.duplicate()
	rules.hill = skirmish_map.hill
	rules.flag_radius = skirmish_map.flag_radius
	return rules


## How many flags.
func flag_count() -> int:
	return flags.size() / 2


## Problems that make the rules unplayable, or an empty array. Every one is
## listed.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if mode < 0 or mode >= Mode.size():
		errors.append("mode %d is not a Mode" % mode)
	if time_limit_ticks <= 0:
		errors.append("time_limit_ticks must be positive")
	if capture_ticks <= 0:
		errors.append("capture_ticks must be positive")
	if player_faction < 0 or player_faction >= UnitType.Faction.size():
		errors.append("player_faction %d is not a Faction" % player_faction)
	if flags.size() % 2 != 0 or flags.is_empty():
		errors.append("flags must be one or more x, z pairs")
	if hill < 0 or hill >= flag_count():
		errors.append("hill %d is not a flag" % hill)
	if flag_radius <= 0:
		errors.append("flag_radius must be positive")
	return errors


## The rules as integers, for state_hash().
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([
		mode, time_limit_ticks, capture_ticks, player_faction, hill, flag_radius, flags.size(),
	])
	for v: int in flags:
		fields.append(v)
	return fields
