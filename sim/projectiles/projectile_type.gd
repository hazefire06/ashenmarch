class_name ProjectileType
extends Resource
## Data-driven projectile definition, saved as data/projectiles/<id>.tres and
## listed in the unit catalog's projectile_types. The sim reads every
## projectile number from here: arrows, grenades, satchel charges.
##
## Same conventions as UnitType: integers only (milli-units, mm/s, ticks,
## permille), and required numbers default to 0 so validate() can reject a
## field a .tres forgot to set.

## What happens when it meets the ground.
enum Behavior {
	## Arrows: stop dead where they land. They hurt a unit they fly into.
	STICKS,
	## Grenades and satchels: bounce, roll on slopes, come to rest. They
	## glance off bodies without hurting them.
	BOUNCES,
}

## Stable key used by unit types (ranged_projectile, special_projectile).
@export var id: StringName = &""
@export var display_name: String = ""
@export var behavior: Behavior = Behavior.STICKS

@export_group("Flight")
## Milli-units. Collision radius against ground and bodies.
@export var radius: int = 0
## Quadratic air drag: parts per million of speed lost per metre travelled.
## 5000 loses 0.5% of its speed every metre. 0 flies in a vacuum.
@export var drag_ppm_per_m: int = 0

@export_group("Contact")
## BOUNCES: share of the speed into the surface returned as rebound, permille.
@export var restitution_permille: int = 0
## BOUNCES: share of the speed along the surface kept through a bounce.
@export var friction_permille: int = 0
## BOUNCES: share of the slope's pull a rolling object feels (a solid ball
## is 714, 5/7; a sack that slides and snags is lower).
@export var roll_accel_permille: int = 0
## BOUNCES: deceleration while rolling on level ground, mm/s^2. Scales with
## the cosine of the slope.
@export var rolling_resistance: int = 0
## BOUNCES: slower than this (mm/s) on gentle enough ground, it stops.
@export var rest_speed: int = 0
## BOUNCES: the steepest ground it can come to rest on, permille grade.
@export var static_slope_permille: int = 0

@export_group("Impact")
## STICKS: damage to a unit it flies into.
@export var impact_damage: int = 0
## Leaves a fire mark where it lands (fire arrows). Phase 5 lights it.
@export var marks_fire: bool = false

@export_group("Fuse")
## Ticks from launch to bursting; 0 means no fuse (arrows, satchels).
@export var fuse_ticks: int = 0
## The fuse varies uniformly by up to this much either way, permille.
@export var fuse_variance_permille: int = 0
## Chance in permille that the fuse goes out instead, leaving a dud.
@export var fizzle_permille: int = 0

@export_group("Weather")
## For burning projectiles (a lit fuse, or marks_fire; ignored on anything
## else): extra chance in permille that the flame goes out in full rain, in
## full snow, and lying on fully snow-covered ground. Each scales with the intensity or cover, and
## they combine with fizzle_permille as independent chances
## (ProjectileSystem.fizzle_permille). A fuse rolls when it burns down; a
## fire arrow rolls when it lands. Water puts either out with no roll.
@export var rain_fizzle_permille: int = 0
@export var snow_fizzle_permille: int = 0
@export var snow_cover_fizzle_permille: int = 0

@export_group("Explosive")
## Milli-units. 0 means it doesn't explode.
@export var blast_radius: int = 0
## Full damage within this distance of the burst.
@export var blast_inner_radius: int = 0
@export var blast_damage: int = 0
## Units and loose objects within this are thrown clear, fastest at the
## center (knock_speed, mm/s) and not at all at the edge.
@export var knock_radius: int = 0
@export var knock_speed: int = 0
## The crater the burst digs when it goes off on (or near) the ground.
## crater_radius must not exceed blast_radius.
@export var crater_radius: int = 0
@export var crater_depth: int = 0
## Set off by any blast that reaches it (satchels, grenades, duds).
@export var chain_detonates: bool = false

@export_group("View")
## Placeholder color until the art pass. View only.
@export var placeholder_color: Color = Color.WHITE
## Milli-units: drawn length (arrows) or size. View only.
@export var length: int = 0


func is_explosive() -> bool:
	return blast_radius > 0


## Carries a flame: a lit fuse or a fire arrow. Weather and water put it out.
func burns() -> bool:
	return fuse_ticks > 0 or marks_fire


## Problems that make this type unusable, or an empty array if it is valid.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var who: String = String(id) if id != &"" else resource_path
	if id == &"":
		errors.append("%s: id is empty" % who)
	if display_name.is_empty():
		errors.append("%s: display_name is empty" % who)
	if radius <= 0:
		errors.append("%s: radius must be positive" % who)
	if drag_ppm_per_m < 0 or drag_ppm_per_m > 100_000:
		errors.append("%s: drag_ppm_per_m must be 0..100000" % who)
	if behavior == Behavior.STICKS:
		if impact_damage <= 0:
			errors.append("%s: a sticking projectile needs impact_damage" % who)
	else:
		for field: String in ["restitution_permille", "friction_permille", "roll_accel_permille"]:
			var value: int = int(get(field))
			if value < 0 or value > 1000:
				errors.append("%s: %s must be 0..1000" % [who, field])
		if rest_speed <= 0:
			errors.append("%s: rest_speed must be positive" % who)
		if rolling_resistance < 0 or static_slope_permille < 0:
			errors.append("%s: rolling_resistance and static_slope_permille can't be negative" % who)
	if fuse_ticks < 0:
		errors.append("%s: fuse_ticks can't be negative" % who)
	if fuse_ticks > 0 and not is_explosive():
		errors.append("%s: a fuse needs something to explode" % who)
	for field: String in ["fuse_variance_permille", "fizzle_permille"]:
		var value: int = int(get(field))
		if value < 0 or value > 1000:
			errors.append("%s: %s must be 0..1000" % [who, field])
	for field: String in ["rain_fizzle_permille", "snow_fizzle_permille", "snow_cover_fizzle_permille"]:
		var value: int = int(get(field))
		if value < 0 or value > 1000:
			errors.append("%s: %s must be 0..1000" % [who, field])
	if chain_detonates and not is_explosive():
		errors.append("%s: chain_detonates needs a blast" % who)
	if is_explosive():
		errors.append_array(_validate_blast(who))
	return errors


func _validate_blast(who: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if blast_damage <= 0:
		errors.append("%s: blast_damage must be positive" % who)
	if blast_inner_radius < 0 or blast_inner_radius >= blast_radius:
		errors.append("%s: blast_inner_radius must be 0..blast_radius" % who)
	if knock_radius < 0 or knock_speed < 0:
		errors.append("%s: knock_radius and knock_speed can't be negative" % who)
	if crater_radius < 0 or crater_depth < 0:
		errors.append("%s: crater_radius and crater_depth can't be negative" % who)
	# Anything a crater could wake is inside the blast, so it is already
	# detonated or thrown clear; that is why craters don't wake objects.
	if crater_radius > blast_radius:
		errors.append("%s: crater_radius can't exceed blast_radius" % who)
	return errors
