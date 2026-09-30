class_name UnitType
extends Resource
## Data-driven unit definition, saved as data/units/<id>.tres and listed in
## data/units/catalog.tres. The sim reads every gameplay number from here;
## no unit stats live in scripts.
##
## All gameplay fields are integers: distances in milli-units, speeds in
## milli-units per second, times in ticks, multipliers in permille. Required
## numbers default to 0 and validate() rejects 0, for the same reason as
## MapInfo: Godot omits default values from .tres files, so a non-zero default
## would let a unit's stats change silently if the default changed.

enum Faction {
	## The player's side.
	LIGHT,
	## The enemy side.
	DARK,
}

## What a unit is, as opposed to how it moves (mobility). Healing kills
## UNDEAD; conversion only works on LIVING.
enum Nature {
	LIVING,
	UNDEAD,
}

const WATER_DEPTH_LEVELS: int = Terrain.MAX_WATER_DEPTH + 1

## Stable key used by commands and saves, e.g. &"shieldman".
@export var id: StringName = &""
@export var display_name: String = ""
@export var faction: Faction = Faction.LIGHT
@export var nature: Nature = Nature.LIVING
## Which terrain the unit can stand on (water depth, slope).
@export var mobility: Terrain.Mobility = Terrain.Mobility.LIVING

@export_group("Body")
@export var max_hp: int = 0
## Milli-units. Used for spacing, avoidance, and selection.
@export var body_radius: int = 0
## Milli-units. Sprite height now; line of sight and hit tests later.
@export var body_height: int = 0

@export_group("Movement")
## Milli-units per second on flat, dry ground.
@export var move_speed: int = 0
## Speed multiplier in permille, indexed by water depth 0..4. Every depth the
## unit's mobility can stand in must be above 0.
@export var water_speed_permille: PackedInt32Array = PackedInt32Array()
## Permille of speed lost per 1000 permille (45 degrees) of uphill grade along
## the direction of travel. 500 halves speed climbing a 45 degree slope.
@export var uphill_slowdown_permille: int = 0
## Hidden from the player's view at depth LIVING_IMPASSABLE_DEPTH and deeper.
@export var hidden_in_deep_water: bool = false

@export_group("Melee")
@export var melee_damage: int = 0
## Milli-units from body edge to body edge.
@export var melee_reach: int = 0
@export var melee_windup_ticks: int = 0
@export var melee_cooldown_ticks: int = 0

@export_group("Ranged")
## 0 means the unit has no ranged attack.
@export var ranged_damage: int = 0
## Milli-units. Targets closer than this can't be attacked (Stormcaller).
@export var ranged_min_range: int = 0
@export var ranged_max_range: int = 0
@export var ranged_cooldown_ticks: int = 0
## Shots carried; -1 is unlimited.
@export var ammo: int = 0

@export_group("Abilities")
## Ability keys the sim understands, e.g. &"fire_arrow", &"satchel".
@export var abilities: Array[StringName] = []

@export_group("View")
## Placeholder quad color until the art pass. View only; the sim ignores it.
@export var placeholder_color: Color = Color.WHITE
## Null until the art pass. View only.
@export var sprite: Texture2D


## Problems that make this type unusable, or an empty array if it is valid.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var who: String = String(id) if id != &"" else resource_path
	if id == &"":
		errors.append("%s: id is empty" % who)
	if display_name.is_empty():
		errors.append("%s: display_name is empty" % who)
	for field: String in ["max_hp", "body_radius", "body_height", "move_speed"]:
		if int(get(field)) <= 0:
			errors.append("%s: %s must be positive" % [who, field])
	if uphill_slowdown_permille < 0 or uphill_slowdown_permille > 1000:
		errors.append("%s: uphill_slowdown_permille must be 0..1000" % who)
	errors.append_array(_validate_water(who))
	if melee_damage > 0 and (melee_reach <= 0 or melee_cooldown_ticks <= 0):
		errors.append("%s: melee needs positive reach and cooldown" % who)
	if ranged_damage > 0:
		if ranged_max_range <= ranged_min_range or ranged_min_range < 0:
			errors.append("%s: ranged needs 0 <= min_range < max_range" % who)
		if ranged_cooldown_ticks <= 0:
			errors.append("%s: ranged needs a positive cooldown" % who)
	return errors


## Water depth levels this unit's mobility lets it stand in.
func can_enter_depth(depth: int) -> bool:
	return mobility != Terrain.Mobility.LIVING or depth < Terrain.LIVING_IMPASSABLE_DEPTH


func _validate_water(who: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if water_speed_permille.size() != WATER_DEPTH_LEVELS:
		errors.append("%s: water_speed_permille needs %d entries" % [who, WATER_DEPTH_LEVELS])
		return errors
	for depth: int in WATER_DEPTH_LEVELS:
		var speed: int = water_speed_permille[depth]
		if speed < 0 or speed > 1000:
			errors.append("%s: water speed at depth %d must be 0..1000" % [who, depth])
		elif speed == 0 and can_enter_depth(depth):
			# A unit that can stand somewhere it can't move would be stuck.
			errors.append("%s: water speed at enterable depth %d is 0" % [who, depth])
	return errors
