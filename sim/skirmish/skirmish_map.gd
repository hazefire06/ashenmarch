class_name SkirmishMap
extends Resource
## What a map needs to be played as a skirmish, one per map
## (maps/<id>/skirmish.tres, beside its heightmap): the two armies' spawns, the
## flags, and which flag is the hill. The map itself (MapInfo, its PNGs) is
## unchanged, so the campaign and skirmish share it.
##
## Positions are milli-units, as everywhere. A spawn is where an army's block
## is centered (World.spawn_block, DeployCommand); its facing is a direction,
## (0, 0) meaning north as for a formation. flag_radius defaults to 8 m, not 0,
## because that is the common case and Godot leaves defaults out of a .tres.
##
## The View group is for the view only, following MissionDef: nothing that
## steps a World reads it.

## The fewest flags a map offers. Odd counts keep Capture the Flags from
## ending level when every flag is owned.
const MIN_FLAGS: int = 3

## Stable key, the map's directory name, e.g. &"old_mill".
@export var id: StringName = &""
## The name the menus show.
@export var display_name: String = ""
## The ground.
@export var map: MapInfo
## Two x, z pairs: start A, then start B.
@export var spawns: PackedInt32Array = PackedInt32Array()
## Two direction pairs, the way each start's block faces.
@export var spawn_facing: PackedInt32Array = PackedInt32Array()
## The flags as x, z pairs; an odd number, at least MIN_FLAGS.
@export var flags: PackedInt32Array = PackedInt32Array()
## Which flag is the hill in King of the Hill (an index into flags).
@export var hill: int = 0
## How close, center to center, a unit must stand to a flag to count as at it.
@export var flag_radius: int = 8000

@export_group("View")
## How far the camera starts from the player's spawn, in milli-units.
@export var camera_distance: int = 75000
## The map's look (the campaign mission's, usually); null leaves the view's
## default.
@export var atmosphere: Atmosphere


## How many flags.
func flag_count() -> int:
	return flags.size() / 2


## A start's center, A = 0, B = 1.
func spawn(start: int) -> Vector2i:
	return Vector2i(spawns[2 * start], spawns[2 * start + 1])


## The way a start's block faces.
func facing(start: int) -> Vector2i:
	return Vector2i(spawn_facing[2 * start], spawn_facing[2 * start + 1])


## A flag's center.
func flag(index: int) -> Vector2i:
	return Vector2i(flags[2 * index], flags[2 * index + 1])


## Problems that make the map unplayable as a skirmish, or an empty array.
## Every one is listed. Whether the points are passable and reachable is the
## terrain's to say; the tests check that against the map.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if map == null:
		errors.append("map is missing")
	if spawns.size() != 4:
		errors.append("spawns must be two x, z pairs")
	else:
		for v: int in spawns:
			if v < 0:
				errors.append("spawns can't be negative")
				break
	if spawn_facing.size() != 4:
		errors.append("spawn_facing must be two direction pairs")
	if flags.size() % 2 != 0:
		errors.append("flags must be x, z pairs")
	var n: int = flag_count()
	if n < MIN_FLAGS or n % 2 == 0:
		errors.append("a map needs an odd number of flags, at least %d; has %d" % [MIN_FLAGS, n])
	for v: int in flags:
		if v < 0:
			errors.append("flags can't be negative")
			break
	if hill < 0 or hill >= n:
		errors.append("hill %d is not a flag" % hill)
	if flag_radius <= 0:
		errors.append("flag_radius must be positive")
	if camera_distance <= 0:
		errors.append("camera_distance must be positive")
	return errors
