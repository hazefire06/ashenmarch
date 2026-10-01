class_name AiGroupSpec
extends Resource
## One enemy (or friendly) group in a MissionScript: what spawns, where, and
## how the AI drives it. The AI treats the group as one body; it picks one
## goal for the whole group and orders it with UnitOrders.move.
##
## Like WeatherChange, several fields have non-zero defaults on purpose
## (faction DARK, on_alert HUNT, flank_roles 6, formation BOX): they are the
## common case, and validate() checks every field that has a range.
## Positions and radii are milli-units. Never change a spec at runtime:
## load() hands every world the same instance.

## What a group is doing. The order is the hash order, so only append.
enum Behavior {
	## Stands where it spawned and fights what comes to it.
	IDLE,
	## Walks the waypoints; switches to on_alert when an enemy comes within
	## alert_radius.
	PATROL,
	## Holds its spawn point; chases enemies within guard_radius and comes
	## back afterwards.
	GUARD,
	## Marches at the nearest enemy.
	HUNT,
	## Goes after the roles in flank_roles: walks round the end of any enemy
	## melee screening them, then strikes from the side (AiFlank).
	FLANK,
	## Waits hidden until an enemy comes within alert_radius, a member is
	## hurt, or one is fought, then springs into on_alert.
	AMBUSH,
	## Falls back to the retreat point, then guards it. The AI enters it,
	## once, when the group's health drops below retreat_below_permille
	## and the enemies near it outweigh it; a script can't set it.
	RETREAT,
}

## How a PATROL walks its waypoints.
enum PatrolMode {
	## Last waypoint to first again.
	LOOP,
	## Out to the last waypoint and back along the same route.
	PING_PONG,
}

## Unique within a MissionScript; triggers refer to the group by it.
@export var name: StringName = &""
## Which side the group fights for.
@export var faction: UnitType.Faction = UnitType.Faction.DARK
## What spawns, with per-tier counts.
@export var units: Array[AiUnitEntry] = []
## Spawn points as x, z pairs.
@export var spawns: PackedInt32Array = PackedInt32Array()
## Which spawn point each tier uses, as indices into spawns (point 0 is the
## first pair). Empty: point 0 at every tier. Otherwise one entry for every
## tier or one per tier (Difficulty).
@export var spawn_by_tier: PackedInt32Array = PackedInt32Array()
## Direction the group faces when it spawns. 0, 0 means north (Formations
## does that).
@export var facing_x: int = 0
@export var facing_z: int = 0
## The shape it spawns in and marches in.
@export var formation: Formations.Kind = Formations.Kind.BOX
## True: spawns when the mission starts. False: waits for a SPAWN_GROUP
## trigger action.
@export var spawn_at_start: bool = false
## What it does from the moment it spawns.
@export var behavior: Behavior = Behavior.IDLE
## PATROL: the route, as x, z pairs.
@export var waypoints: PackedInt32Array = PackedInt32Array()
@export var patrol_mode: PatrolMode = PatrolMode.LOOP
## GUARD: how far from its post it chases an enemy.
@export var guard_radius: int = 0
## PATROL: an enemy this close (center to center, to any member) switches the
## group to on_alert; 0 never does. AMBUSH: the radius that springs it, which
## must be above 0.
@export var alert_radius: int = 0
## What a PATROL or AMBUSH becomes when it spots an enemy.
@export var on_alert: Behavior = Behavior.HUNT
## The roles FLANK goes after, as bits (1 << UnitType.Role): melee, ranged,
## support. The default is ranged and support.
@export_flags("Melee", "Ranged", "Support") var flank_roles: int = 6
## The group falls back when its health drops below this share of what it
## spawned with, in permille. 0 never retreats.
@export var retreat_below_permille: int = 0
## Where RETREAT falls back to, one x, z pair. Empty: its spawn point.
@export var retreat_point: PackedInt32Array = PackedInt32Array()


## The spawn point this tier uses.
func spawn_point(tier: int) -> Vector2i:
	var i: int = 0 if spawn_by_tier.is_empty() else Difficulty.pick(spawn_by_tier, tier)
	return Vector2i(spawns[2 * i], spawns[2 * i + 1])


## How many units spawn at this tier, over every entry.
func unit_count(tier: int) -> int:
	var total: int = 0
	for entry: AiUnitEntry in units:
		total += Difficulty.pick(entry.counts, tier)
	return total


## Problems that make the group unusable, or an empty array. Messages start
## with "group <name>: ".
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var prefix: String = _prefix()
	if name == &"":
		errors.append(prefix + "name is empty")
	errors.append_array(_validate_units(catalog))
	if spawns.is_empty():
		errors.append(prefix + "spawns needs at least one x, z pair")
	elif spawns.size() % 2 != 0:
		errors.append(prefix + "spawns must hold x, z pairs")
	if not spawn_by_tier.is_empty():
		if not Difficulty.is_valid(spawn_by_tier):
			errors.append(prefix + "spawn_by_tier needs 1 or %d entries" % Difficulty.TIERS)
		else:
			var spawn_count: int = spawns.size() >> 1
			for index: int in spawn_by_tier:
				if index < 0 or index >= spawn_count:
					errors.append(prefix + "spawn_by_tier index %d is out of range" % index)
	if not Formations.Kind.values().has(formation):
		errors.append(prefix + "formation is not a Formations.Kind")
	if behavior == Behavior.RETREAT:
		errors.append(prefix + "RETREAT can't be a starting behavior")
	else:
		errors.append_array(params_errors(behavior))
	if on_alert != Behavior.GUARD and on_alert != Behavior.HUNT and on_alert != Behavior.FLANK:
		errors.append(prefix + "on_alert must be GUARD, HUNT or FLANK")
	elif behavior == Behavior.PATROL or behavior == Behavior.AMBUSH:
		for problem: String in _param_problems(on_alert):
			errors.append("%son_alert: %s" % [prefix, problem])
	if alert_radius < 0:
		errors.append(prefix + "alert_radius can't be negative")
	if guard_radius < 0:
		errors.append(prefix + "guard_radius can't be negative")
	if retreat_below_permille < 0 or retreat_below_permille > 1000:
		errors.append(prefix + "retreat_below_permille must be 0..1000")
	if retreat_point.size() != 0 and retreat_point.size() != 2:
		errors.append(prefix + "retreat_point must be empty or one x, z pair")
	if flank_roles & ~UnitType.ALL_ROLES_MASK != 0:
		errors.append(prefix + "flank_roles has unknown role bits")
	return errors


## What this group lacks to be given behavior b, or an empty array. Public
## because a SET_BEHAVIOR trigger action is checked against its target group
## with it. Messages start with "group <name>: ".
func params_errors(b: Behavior) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var prefix: String = _prefix()
	for problem: String in _param_problems(b):
		errors.append(prefix + problem)
	return errors


func _param_problems(b: Behavior) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	match b:
		Behavior.PATROL:
			if waypoints.size() % 2 != 0:
				problems.append("PATROL needs waypoints as x, z pairs")
			elif waypoints.size() < 4:
				problems.append("PATROL needs at least 2 waypoints")
		Behavior.GUARD:
			if guard_radius <= 0:
				problems.append("GUARD needs guard_radius > 0")
		Behavior.AMBUSH:
			if alert_radius <= 0:
				problems.append("AMBUSH needs alert_radius > 0")
		Behavior.FLANK:
			if flank_roles == 0:
				problems.append("FLANK needs flank_roles to name at least one role")
		Behavior.RETREAT:
			problems.append("RETREAT is entered by the AI, not set")
	return problems


func _validate_units(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var prefix: String = _prefix()
	if units.is_empty():
		errors.append(prefix + "units is empty")
		return errors
	# unit_count() can only be asked once every entry's counts are well formed.
	var counts_usable: bool = true
	for i: int in units.size():
		var entry: AiUnitEntry = units[i]
		if entry == null:
			errors.append("%sunits entry %d is null" % [prefix, i])
			counts_usable = false
			continue
		if catalog.index_of(entry.type_id) < 0:
			errors.append("%sunits entry %d: unknown unit type %s" % [prefix, i, entry.type_id])
		if not Difficulty.is_valid(entry.counts):
			errors.append("%sunits entry %d: needs 1 or %d counts" % [prefix, i, Difficulty.TIERS])
			counts_usable = false
		elif _has_negative(entry.counts):
			errors.append("%sunits entry %d: counts can't be negative" % [prefix, i])
			counts_usable = false
	if not counts_usable:
		return errors
	for tier: int in Difficulty.TIERS:
		if unit_count(tier) > 0:
			return errors
	errors.append(prefix + "never spawns anything")
	return errors


static func _has_negative(values: PackedInt32Array) -> bool:
	for value: int in values:
		if value < 0:
			return true
	return false


func _prefix() -> String:
	return "group %s: " % (String(name) if name != &"" else "<unnamed>")
