class_name Veterancy
extends RefCounted
## Kill-based improvement. Every kill raises a unit's melee accuracy, attack
## rate, and (for types with a speed cap) move speed, each kill by less than
## the one before, toward a per-type cap it never quite reaches:
##
##     bonus(kills) = cap * kills / (kills + HALF_CAP_KILLS)
##
## so HALF_CAP_KILLS kills earn half the cap. The caps live in the unit's
## UnitType (0 means it never improves at that). Everything here is a pure
## function of the type and the kill count; nothing is cached, and
## Unit.kills is hashed.

const HALF_CAP_KILLS: int = 4


## Bonus in permille after this many kills, for a type whose cap is cap.
static func bonus_permille(cap: int, kills: int) -> int:
	if cap <= 0 or kills <= 0:
		return 0
	return cap * kills / (kills + HALF_CAP_KILLS)


## Hit-chance points (permille) added to the type's melee accuracy.
static func accuracy_bonus(unit: Unit) -> int:
	return bonus_permille(unit.type.veterancy_accuracy_permille, unit.kills)


## Permille faster attacking: a bonus of 250 makes the cooldown 1000/1250 as long.
static func attack_rate_bonus(unit: Unit) -> int:
	return bonus_permille(unit.type.veterancy_attack_rate_permille, unit.kills)


## Permille faster walking.
static func speed_bonus(unit: Unit) -> int:
	return bonus_permille(unit.type.veterancy_speed_permille, unit.kills)


## Chance in permille that a swing in reach hits, never above 1000.
static func melee_accuracy(unit: Unit) -> int:
	return mini(1000, unit.type.melee_accuracy_permille + accuracy_bonus(unit))


## Ticks from a blow landing to the next swing starting; at least 1.
static func melee_cooldown(unit: Unit) -> int:
	return maxi(1, FixedMath.div_round(
		unit.type.melee_cooldown_ticks * 1000, 1000 + attack_rate_bonus(unit)
	))


## Milli-units per second on flat, dry ground.
static func move_speed(unit: Unit) -> int:
	return FixedMath.div_round(unit.type.move_speed * (1000 + speed_bonus(unit)), 1000)
