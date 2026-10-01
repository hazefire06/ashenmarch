class_name Damage
extends RefCounted
## The one way hit points leave a unit, for melee blows, arrows, and blasts
## alike: the damage lands, the unit dies at 0, the kill is credited, a
## CombatEvent goes to the view, and a dying Sapper drops its charges.
##
## No randomness here. Each source rolls its own dice (hit, block, variance)
## in its own documented order before calling apply(), so the RNG stream is
## the same as before this was factored out.

## Milli-units from a dying unit's feet to where its dropped charges lie.
const DROP_SPREAD: int = 300


## Takes amount hit points from target, which came from (from_x, from_z)
## (the attacker, the blast center, the arrow's approach). credit_id is the
## unit credited with a kill (0 for none); it only counts an enemy.
## Returns true if this killed the target. A target already dead takes
## nothing, so a body can't die (and drop or burst) twice when two blows meet
## it in one tick.
static func apply(
	world: World, target: Unit, amount: int, from_x: int, from_z: int, credit_id: int,
	aspect: MeleeCombat.Aspect = MeleeCombat.Aspect.FRONT
) -> bool:
	if not target.is_alive():
		return false
	var hp_before: int = target.hp
	target.hp -= amount
	if target.hp > 0:
		world.combat_events.append(_event(CombatEvent.Kind.HIT, credit_id, target, aspect, amount, 0, from_x, from_z))
		return false
	target.kill()
	var credited: Unit = world.get_unit(credit_id)
	if credited != null and credited.faction != target.faction:
		credited.kills += 1
	world.combat_events.append(_event(
		CombatEvent.Kind.KILL, credit_id, target, aspect, amount, amount - hp_before, from_x, from_z
	))
	drop_on_death(world, target)
	return true


## A dying Sapper's unused charges fall around its feet, at fixed spots so
## no dice are needed: they lie there as live hazards.
static func drop_on_death(world: World, unit: Unit) -> void:
	if unit.type.special_ability != UnitType.Special.SATCHEL or unit.special_left <= 0:
		return
	var n: int = unit.special_left
	unit.special_left = 0
	for k: int in n:
		var angle: int = k * FixedMath.ANGLE_FULL / n
		var at_x: int = unit.x + FixedMath.cos_b(angle) * DROP_SPREAD / FixedMath.TRIG_ONE
		var at_z: int = unit.z + FixedMath.sin_b(angle) * DROP_SPREAD / FixedMath.TRIG_ONE
		world.drop_charge(unit, at_x, at_z)


static func _event(
	kind: CombatEvent.Kind, attacker_id: int, target: Unit, aspect: MeleeCombat.Aspect,
	amount: int, overkill: int, from_x: int, from_z: int
) -> CombatEvent:
	var e: CombatEvent = CombatEvent.new(kind, attacker_id, target.id, aspect, amount, overkill)
	e.source_x = from_x
	e.source_z = from_z
	return e
