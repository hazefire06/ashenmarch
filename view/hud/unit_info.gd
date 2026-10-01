class_name UnitInfo
extends RefCounted
## The words the HUD uses about a unit or a loose thing, shared by the hover
## tooltip (UnitTooltip) and the selection panel (UnitInfoPanel). Pure
## functions of sim state; tested on their own.
##
## A living unit gets, one per line:
##   Shieldman (Light)
##   HP 64/100 · Attacking
##   Kills 3
##   Accuracy 86% (+6 from kills)
##   Attack rate +16% · Speed +0%
## then, only where they apply:
##   Paralyzed 2.3 s · Burning 1.0 s       (status effects, given the world)
##   Arrows: unlimited                     (its ranged attack)
##   Lightning: unlimited · dead zone 8 m  (a lightning caster's)
##   Fire arrow: 1                         (its special: "nocked" once readied)
##   Satchels: 3   /   Herbs: 4/6   /   Bursts when it dies
##   Carrying: Satchel charge              (a Ripper with something in hand)
## A dead unit gets just its name, "dead", and its kills. Percentages round to
## the nearest point, seconds to a tenth.

const PERMILLE_PER_PERCENT: int = 10


## The lines above for unit. catalog names projectiles (without one, ids
## stand in); world adds status effects and names errands (without one,
## neither shows).
static func lines(unit: Unit, catalog: UnitCatalog = null, world: World = null) -> PackedStringArray:
	var header: String = header_of(unit)
	if not unit.is_alive():
		return PackedStringArray(["%s — dead" % header, "Kills %d" % unit.kills])
	var accuracy: String = "Accuracy %d%%" % _percent(Veterancy.melee_accuracy(unit))
	if Veterancy.accuracy_bonus(unit) > 0:
		accuracy += " (+%d from kills)" % _percent(Veterancy.accuracy_bonus(unit))
	var out: PackedStringArray = PackedStringArray([
		header,
		"HP %d/%d · %s" % [unit.hp, unit.type.max_hp, activity(unit, world)],
		"Kills %d" % unit.kills,
		accuracy,
		"Attack rate +%d%% · Speed +%d%%" % [
			_percent(Veterancy.attack_rate_bonus(unit)), _percent(Veterancy.speed_bonus(unit))
		],
	])
	if world != null:
		var statuses: String = status_line(unit, world)
		if not statuses.is_empty():
			out.append(statuses)
	if unit.type.has_ranged():
		out.append(_ammo_line(unit, catalog))
	if unit.type.special_ability != UnitType.Special.NONE:
		out.append(_special_line(unit))
	if world != null:
		var carried: Projectile = world.carried_by(unit)
		if carried != null:
			out.append("Carrying: %s" % carried.type.display_name)
	return out


## "Shieldman (Light)".
static func header_of(unit: Unit) -> String:
	return "%s (%s)" % [unit.type.display_name, UnitType.Faction.keys()[unit.faction].capitalize()]


## What the unit is doing: its state, except that a unit holding a ground
## attack order and not walking is bombarding, and one on an errand says
## which (given the world).
static func activity(unit: Unit, world: World = null) -> String:
	if unit.order == Unit.Order.INTERACT and world != null:
		var target: SimEntity = world.get_entity(unit.interact_id)
		if target != null:
			match Interactions.action_for(world, unit, target):
				Interactions.Action.HEAL:
					return "Healing"
				Interactions.Action.TAKE_HERB, Interactions.Action.TAKE_OBJECT:
					return "Fetching"
				Interactions.Action.STRIKE_PLANT:
					return "Gathering herbs"
				Interactions.Action.TEAR_PART:
					return "Scavenging"
	var bombarding: bool = unit.order == Unit.Order.GROUND_ATTACK and (
		unit.state == Unit.State.SHOOTING or unit.state == Unit.State.IDLE
	)
	return "Bombarding" if bombarding else Unit.State.keys()[unit.state].capitalize()


## "Paralyzed 2.3 s · Confused 4.0 s · Burning 1.0 s" for the effects on the
## unit now, or an empty string if none.
static func status_line(unit: Unit, world: World) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for kind: int in StatusEffects.Kind.size():
		var ticks: int = StatusEffects.ticks_left(world, unit, kind as StatusEffects.Kind)
		if ticks > 0:
			parts.append("%s %s" % [status_name(kind as StatusEffects.Kind), seconds(ticks)])
	return " · ".join(parts)


static func status_name(kind: StatusEffects.Kind) -> String:
	match kind:
		StatusEffects.Kind.PARALYSIS:
			return "Paralyzed"
		StatusEffects.Kind.CONFUSION:
			return "Confused"
	return "Burning"


## "2.3 s" for 69 ticks.
static func seconds(ticks: int) -> String:
	return "%.1f s" % (float(ticks) / World.TICK_RATE)


## What to call a loose thing or a herb plant under the cursor: its name,
## plus what state it is in.
static func describe_thing(thing: SimEntity) -> String:
	if thing is HerbPlant:
		return "Herb plant" + (" (spent)" if (thing as HerbPlant).spent else "\nStrike it for herbs")
	if thing is Projectile:
		var p: Projectile = thing as Projectile
		var text: String = p.type.display_name
		if p.detonating:
			text += " — about to go off"
		elif p.dud:
			text += " (dud)"
		match p.type.pickup:
			ProjectileType.Pickup.HERB:
				text += "\nA Warden picks it up"
			ProjectileType.Pickup.CARRY:
				text += "\nA Ripper can throw it"
		return text
	return ""


# "Arrows: unlimited" or "Arrows: 12": the projectile's display name, plural.
# Lightning isn't counted out: "Lightning: unlimited · dead zone 8 m".
static func _ammo_line(unit: Unit, catalog: UnitCatalog) -> String:
	var ammo: String = "unlimited" if unit.ammo_left < 0 else str(unit.ammo_left)
	var type: ProjectileType = catalog.find_projectile(unit.type.ranged_projectile) if catalog != null else null
	var name: String = type.display_name if type != null else String(unit.type.ranged_projectile).capitalize()
	if type != null and type.behavior == ProjectileType.Behavior.BOLT:
		return "%s: %s · dead zone %d m" % [name, ammo, unit.type.ranged_min_range / World.UNITS_PER_METER]
	return "%ss: %s" % [name, ammo]


# "Satchels: 3", "Fire arrow: 1" (or "nocked" once readied), "Herbs: 4/6",
# or "Bursts when it dies".
static func _special_line(unit: Unit) -> String:
	match unit.type.special_ability:
		UnitType.Special.SATCHEL:
			return "Satchels: %d" % unit.special_left
		UnitType.Special.HEAL:
			return "Herbs: %d/%d" % [unit.special_left, unit.type.special_charges]
		UnitType.Special.DETONATE:
			return "Bursts when it dies"
	return "Fire arrow: %s" % ["nocked" if unit.fire_nocked else str(unit.special_left)]


static func _percent(permille: int) -> int:
	return FixedMath.div_round(permille, PERMILLE_PER_PERCENT)
