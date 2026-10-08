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

## What a unit does in a fight. Target preferences (a Ripper hunts RANGED
## and SUPPORT units) and, later, the AI read it.
enum Role {
	MELEE,
	RANGED,
	SUPPORT,
}

## How a ranged unit picks its launch. Either way it falls back to the other
## when its own style has no clear path to the target.
enum AimStyle {
	## Archers: the flattest arc at full launch speed.
	DIRECT,
	## Throwers: a fixed elevation (ranged_lob_grade_permille), as hard as
	## needed up to full launch speed.
	LOB,
}

## What T does.
enum Special {
	NONE,
	## Nock the fire arrow: the next shot is special_projectile.
	FIRE_ARROW,
	## Drop a charge (special_projectile) at the unit's feet.
	SATCHEL,
	## Heal a unit with a herb (special_projectile, a HERB pickup): T arms it
	## and a click picks who (HealCommand). special_charges is the stack it
	## starts with and can hold.
	HEAL,
	## Burst (special_projectile) where it stands, dying. It bursts the same
	## way whenever it dies, whatever killed it.
	DETONATE,
}

## How the AI fights with a unit of this type, beyond marching at its
## group's objective.
enum AiTactic {
	## Closes with its objective by attack-moving.
	ASSAULT,
	## Holds at ai_standoff_permille of its max range where its line is clear,
	## and keeps enemies out of its minimum range.
	STANDOFF,
	## Walks at the densest knot of enemies (a Blightbag wants as many as it
	## can catch in one burst).
	CLUSTER,
	## Heals its own side's wounded with its HEAL special (and kills undead
	## enemies with it), standing behind its group while it has herbs; fights
	## as ASSAULT once they are gone (a Warden).
	MEDIC,
}

const WATER_DEPTH_LEVELS: int = Terrain.MAX_WATER_DEPTH + 1
## Highest ai_standoff_permille a STANDOFF type may have (see it).
const MAX_STANDOFF_PERMILLE: int = 950
## preferred_target_roles holds bit (1 << Role) per role.
const ALL_ROLES_MASK: int = (1 << Role.MELEE) | (1 << Role.RANGED) | (1 << Role.SUPPORT)

## Stable key used by commands and saves, e.g. &"shieldman".
@export var id: StringName = &""
@export var display_name: String = ""
@export var faction: Faction = Faction.LIGHT
@export var nature: Nature = Nature.LIVING
## Which terrain the unit can stand on (water depth, slope).
@export var mobility: Terrain.Mobility = Terrain.Mobility.LIVING
@export var role: Role = Role.MELEE

@export_group("Body")
@export var max_hp: int = 0
## Milli-units. Used for spacing, avoidance, and selection.
@export var body_radius: int = 0
## Milli-units. Sprite height, and the height of the cylinder projectiles
## and blasts hit.
@export var body_height: int = 0
## Milli-units the unit floats above the ground (Drifter). 0 stands on it.
@export var hover_height: int = 0

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
## Milli-units: while hidden, an enemy's living unit this close (center to
## center, horizontally) still sees it (Visibility). 0: only seen once it
## surfaces.
@export var reveal_radius: int = 0

@export_group("Melee")
@export var melee_damage: int = 0
## Chance in permille that a swing which lands in reach hits.
@export var melee_accuracy_permille: int = 0
## Milli-units from body edge to body edge.
@export var melee_reach: int = 0
## Ticks from starting a swing to the blow landing. The swing is committed:
## a target that steps out of reach meanwhile is missed.
@export var melee_windup_ticks: int = 0
## Ticks from a blow landing to the next swing starting.
@export var melee_cooldown_ticks: int = 0
## Chance in permille to block a melee hit from the front arc. 0: no shield.
@export var shield_block_permille: int = 0
## A status effect every blow that lands inflicts (a paralyzing touch), for
## melee_status_ticks ticks. 0 ticks: none.
@export var melee_status: StatusEffects.Kind = StatusEffects.Kind.PARALYSIS
@export var melee_status_ticks: int = 0
## The blow is the unit bursting (a Blightbag): it closes in and winds up like
## any melee unit, and when the wind-up ends with the target in reach it dies
## and its DETONATE special goes off. No accuracy roll, no damage of its own.
@export var melee_detonates: bool = false

@export_group("Targeting")
## Milli-units, body edge to body edge: how far an attack-moving unit looks
## for enemies to fight.
@export var acquire_radius: int = 0
## Roles this unit attacks first when choosing a target, as bits
## (1 << Role): 1 melee, 2 ranged, 4 support. 0: nearest enemy.
@export_flags("Melee", "Ranged", "Support") var preferred_target_roles: int = 0

@export_group("Ranged")
## Id of the projectile it shoots or throws (a ProjectileType in the
## catalog). Empty: no ranged attack.
@export var ranged_projectile: StringName = &""
@export var ranged_aim: AimStyle = AimStyle.DIRECT
## The fastest it can launch, mm/s.
@export var ranged_launch_speed: int = 0
## Elevation of a lob as a grade (rise per 1000 of run; 1000 is 45 degrees).
## Needed by both styles: archers lob when the direct path is blocked.
@export var ranged_lob_grade_permille: int = 0
## Milli-units above the unit's feet where projectiles leave it.
@export var ranged_launch_height: int = 0
## Milli-units, horizontal. Nothing closer is shot at (a thrower's own blast
## radius, or a Stormcaller's dead zone).
@export var ranged_min_range: int = 0
## Milli-units, horizontal, on level ground; uphill shortens it.
@export var ranged_max_range: int = 0
## Ticks from starting to draw or wind up to the shot leaving.
@export var ranged_windup_ticks: int = 0
## Ticks from a shot leaving to the next draw starting.
@export var ranged_cooldown_ticks: int = 0
## Half-width of the aim cone as a grade (tan x 1000): 25 is about 1.4
## degrees. Veterancy narrows it.
@export var ranged_spread_permille: int = 0
## Extra spread per 1000 permille (45 degrees) of uphill grade to the target,
## in permille of the base: 800 widens the cone 1.8x at 45 degrees uphill.
@export var uphill_spread_permille: int = 0
## Lost range per 1000 permille of uphill grade, in permille: 400 cuts the
## range to 1/1.4 at 45 degrees uphill. Slow throws need none; physics
## already shortens them.
@export var uphill_range_permille: int = 0
## Shots carried per mission; -1 is unlimited.
@export var ranged_ammo: int = 0

@export_group("Special")
## What T does.
@export var special_ability: Special = Special.NONE
## Uses per mission.
@export var special_charges: int = 0
## Projectile id the special fires or drops.
@export var special_projectile: StringName = &""
## HEAL: hit points a herb gives back.
@export var heal_hp: int = 0
## HEAL: ticks from reaching the patient to the herb taking effect.
@export var heal_windup_ticks: int = 0

@export_group("Carrying")
## Picks up loose CARRY objects (and tears parts off bodies) and throws them,
## using the Ranged group's launch, range, timing, and spread numbers with no
## ranged_projectile of its own (Rippers).
@export var throws_carried: bool = false
## Milli-units: how far off, center to center, it notices something to pick
## up while it has nothing better to do. 0: only when ordered to.
@export var scavenge_radius: int = 0
## Projectile id of what it tears off a body. Empty: it leaves bodies alone.
@export var scavenged_projectile: StringName = &""

@export_group("Veterancy")
## The most each kill-based bonus can reach, in permille. See Veterancy for
## the curve; 0 means the unit never improves at that. Accuracy also
## narrows the ranged aim cone.
@export var veterancy_accuracy_permille: int = 0
@export var veterancy_attack_rate_permille: int = 0
@export var veterancy_speed_permille: int = 0

@export_group("AI")
## How the AI fights with it.
@export var ai_tactic: AiTactic = AiTactic.ASSAULT
## STANDOFF only: permille of ranged_max_range to hold at, so a unit that
## stands back doesn't sit at the very edge of its reach, where a step of the
## target out of range would stop it shooting. 1..950: a unit walking to a
## spot at 1000 can overshoot by up to 250 mm, find the target out of range
## where it stops, and be sent to a new spot at every think.
@export var ai_standoff_permille: int = 0

@export_group("Skirmish")
## Points a skirmish army pays for one of these (Army, ArmyTemplate). 0: it
## can't be bought (the Ford's villager).
@export var cost: int = 0

@export_group("View")
## Placeholder quad color until the art pass. View only; the sim ignores it.
@export var placeholder_color: Color = Color.WHITE  # purity-ok: view only
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
	if has_melee():
		for field: String in ["melee_reach", "melee_windup_ticks", "melee_cooldown_ticks", "acquire_radius"]:
			if int(get(field)) <= 0:
				errors.append("%s: melee needs a positive %s" % [who, field])
	if melee_damage > 0 and (melee_accuracy_permille <= 0 or melee_accuracy_permille > 1000):
		errors.append("%s: melee_accuracy_permille must be 1..1000" % who)
	if melee_detonates and special_ability != Special.DETONATE:
		errors.append("%s: melee_detonates needs the DETONATE special" % who)
	if melee_detonates and melee_damage > 0:
		errors.append("%s: a unit whose blow is bursting has no melee_damage" % who)
	for field: String in [
		"shield_block_permille", "veterancy_accuracy_permille",
		"veterancy_attack_rate_permille", "veterancy_speed_permille",
	]:
		var value: int = int(get(field))
		if value < 0 or value > 1000:
			errors.append("%s: %s must be 0..1000" % [who, field])
	if melee_status_ticks < 0:
		errors.append("%s: melee_status_ticks can't be negative" % who)
	if preferred_target_roles & ~ALL_ROLES_MASK != 0:
		errors.append("%s: preferred_target_roles has unknown role bits" % who)
	if hover_height < 0:
		errors.append("%s: hover_height can't be negative" % who)
	if reveal_radius < 0:
		errors.append("%s: reveal_radius can't be negative" % who)
	if has_ranged():
		errors.append_array(_validate_ranged(who))
	if throws_carried:
		if has_ranged():
			errors.append("%s: a unit can't both shoot and throw what it carries" % who)
		else:
			errors.append_array(_validate_ranged(who))
			for field: String in ["ranged_launch_speed", "ranged_lob_grade_permille"]:
				if int(get(field)) <= 0:
					errors.append("%s: throwing needs a positive %s" % [who, field])
	if scavenge_radius < 0:
		errors.append("%s: scavenge_radius can't be negative" % who)
	if (scavenge_radius > 0 or scavenged_projectile != &"") and not throws_carried:
		errors.append("%s: scavenging needs throws_carried" % who)
	if special_ability != Special.NONE:
		if special_charges <= 0:
			errors.append("%s: a special needs charges" % who)
		if special_projectile == &"":
			errors.append("%s: a special needs special_projectile" % who)
	if special_ability == Special.FIRE_ARROW and not has_ranged():
		errors.append("%s: a fire arrow needs a ranged attack to shoot it" % who)
	if special_ability == Special.HEAL and heal_hp <= 0:
		errors.append("%s: HEAL needs a positive heal_hp" % who)
	if heal_windup_ticks < 0:
		errors.append("%s: heal_windup_ticks can't be negative" % who)
	if ai_tactic == AiTactic.STANDOFF:
		if not has_ranged():
			errors.append("%s: STANDOFF needs a ranged attack" % who)
		if ai_standoff_permille < 1 or ai_standoff_permille > MAX_STANDOFF_PERMILLE:
			errors.append("%s: ai_standoff_permille must be 1..%d for STANDOFF" % [who, MAX_STANDOFF_PERMILLE])
	elif ai_standoff_permille != 0:
		errors.append("%s: ai_standoff_permille only applies to STANDOFF" % who)
	# A hand-written .tres can hold any integer in an enum field, and an
	# unknown tactic would fall through every match in the AI without a word.
	if ai_tactic < 0 or ai_tactic >= AiTactic.size():
		errors.append("%s: ai_tactic %d is not an AiTactic" % [who, ai_tactic])
	if ai_tactic == AiTactic.MEDIC and special_ability != Special.HEAL:
		errors.append("%s: MEDIC needs the HEAL special" % who)
	if cost < 0:
		errors.append("%s: cost can't be negative" % who)
	return errors


func has_ranged() -> bool:
	return ranged_projectile != &""


## True if it fights in melee at all: blows, or bursting on contact.
func has_melee() -> bool:
	return melee_damage > 0 or melee_detonates


## Water depth levels this unit's mobility lets it stand in.
func can_enter_depth(depth: int) -> bool:
	return mobility != Terrain.Mobility.LIVING or depth < Terrain.LIVING_IMPASSABLE_DEPTH


func _validate_ranged(who: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	# Launch speed and lob grade depend on what is shot (a bolt needs
	# neither), so UnitCatalog checks them against the projectile.
	for field: String in ["ranged_launch_height", "ranged_max_range", "ranged_cooldown_ticks"]:
		if int(get(field)) <= 0:
			errors.append("%s: ranged needs a positive %s" % [who, field])
	if ranged_min_range < 0 or ranged_min_range >= ranged_max_range:
		errors.append("%s: ranged needs 0 <= min_range < max_range" % who)
	if ranged_windup_ticks < 0:
		errors.append("%s: ranged_windup_ticks can't be negative" % who)
	if ranged_spread_permille < 0 or ranged_spread_permille > 1000:
		errors.append("%s: ranged_spread_permille must be 0..1000" % who)
	for field: String in ["uphill_spread_permille", "uphill_range_permille"]:
		var value: int = int(get(field))
		if value < 0 or value > 10_000:
			errors.append("%s: %s must be 0..10000" % [who, field])
	if ranged_ammo == 0 or ranged_ammo < -1:
		errors.append("%s: ranged_ammo must be positive or -1 (unlimited)" % who)
	return errors


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
