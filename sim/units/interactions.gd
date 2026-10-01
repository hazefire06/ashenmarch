class_name Interactions
extends RefCounted
## Errands, run by World.step() after melee and before ranged. A unit on
## order INTERACT walks to its target (Unit.interact_id), and once within
## REACH of it, edge to edge, stands, winds up, and does what the pair calls
## for (action_for):
## - a healer (UnitType.Special.HEAL) touches a unit with a herb: a living
##   friend gets heal_hp back and is cured of every status effect; anything
##   undead, either side, dies of it. A living enemy is refused, and so is a
##   friend with nothing to heal;
## - a healer with room picks up a herb;
## - a carrier (UnitType.throws_carried) picks up a loose CARRY object, or
##   tears a part off a body (at most PARTS_PER_BODY per body);
## - anyone who fights in melee strikes a herb plant, which drops its herbs.
## Then the unit goes back to resume_order: ATTACK_MOVE marches on to its
## goal, anything else holds where it stands.
##
## The wind-up is committed like a melee swing: the act happens when it ends
## if the target is still within REACH + REACH_TOLERANCE, and is lost (the
## herb kept) if not; the unit then closes in again. A target that becomes
## something the unit can't act on (picked up by someone else, healed to
## full, dead) ends the errand. A unit that has walked to where its target is
## and still can't reach it (deep water between) gives up.
##
## A paralyzed or reeling unit makes no progress and loses its wind-up; a
## confused one is busy fighting (MeleeCombat), and picks the errand up again
## when it wears off (UnitOrders.resume). A melee blow that lands also spoils
## the wind-up (MeleeCombat).
##
## Healers also pick up any herb they touch (within CONTACT_REACH of their
## body) while they have room for it, errand or not.
##
## No randomness. Units act in ascending id, then herbs are gathered (units
## in ascending id, herbs in ascending id).

enum Action {
	NONE,
	HEAL,
	TAKE_HERB,
	STRIKE_PLANT,
	TAKE_OBJECT,
	TEAR_PART,
}

## Milli-units, edge to edge, within which a unit can act on its target.
const REACH: int = 600
## The act still happens if the target is this much farther when the wind-up
## ends (bodies jostle a few cm a tick).
const REACH_TOLERANCE: int = 250
## A walk re-paths when its target has moved this far from where it is headed.
const REPATH_DISTANCE: int = 1000
## Ticks to pick something up or tear a part off a body.
const PICKUP_TICKS: int = 9
## Milli-units beyond its body edge a healer picks up a herb it walks over.
const CONTACT_REACH: int = 300
## Parts a scavenger can tear off one body.
const PARTS_PER_BODY: int = 2
## How high up a carrier's body what it holds rides, permille of its height.
const HAND_PERMILLE: int = 750
const PERMILLE: int = 1000


func update(world: World) -> void:
	for unit: Unit in world.units:
		if unit.is_alive() and unit.order == Unit.Order.INTERACT:
			_errand(world, unit)
	_gather_herbs(world)


## The command side (InteractCommand, HealCommand): of the living units among
## unit_ids, the nearest one that can act on entity_id and get to it starts
## the errand (ties to the lower id); the rest keep their orders. With only
## set, only that action counts (a heal order never sends a Ripper).
static func order(world: World, unit_ids: PackedInt32Array, entity_id: int, only: Action = Action.NONE) -> void:
	var target: SimEntity = world.get_entity(entity_id)
	if target == null or world.terrain == null:
		return
	var best: Unit = null
	var best_d: int = 0
	for unit: Unit in UnitOrders.living_units(world, unit_ids):
		var action: Action = action_for(world, unit, target)
		if action == Action.NONE or (only != Action.NONE and action != only):
			continue
		if not can_get_to(world, unit, target):
			continue
		var d: int = FixedMath.length(target.x - unit.x, target.z - unit.z)
		if best == null or d < best_d:
			best = unit
			best_d = d
	if best != null:
		begin(world, best, target, Unit.Order.NONE)


## Sends unit on an errand to target, going back to resume (NONE or
## ATTACK_MOVE) when it is done. Drops whatever it was fighting.
static func begin(world: World, unit: Unit, target: SimEntity, resume: Unit.Order) -> void:
	unit.clear_engagement()
	unit.clear_shot()
	unit.order = Unit.Order.INTERACT
	unit.interact_id = target.id
	unit.resume_order = resume
	unit.act_left = 0
	unit.ground_walked = false
	if _gap(unit, target) > REACH:
		_walk(world, unit, target)
	else:
		world.movement.order_stop(unit)


## What unit would do to target, or NONE if nothing.
static func action_for(world: World, unit: Unit, target: SimEntity) -> Action:
	if target is Unit:
		return _action_on_unit(world, unit, target as Unit)
	if target is Projectile:
		var p: Projectile = target as Projectile
		if p.removed or p.carrier_id != 0 or p.detonating or p.motion != Projectile.Motion.RESTING:
			return Action.NONE
		match p.type.pickup:
			ProjectileType.Pickup.HERB:
				if _has_room_for_herbs(unit):
					return Action.TAKE_HERB
			ProjectileType.Pickup.CARRY:
				if unit.type.throws_carried and world.carried_by(unit) == null:
					return Action.TAKE_OBJECT
		return Action.NONE
	if target is HerbPlant:
		var plant: HerbPlant = target as HerbPlant
		if not plant.spent and unit.type.melee_damage > 0:
			return Action.STRIKE_PLANT
	return Action.NONE


## True if unit is within reach of target already, or can walk to it (the
## same pathing component for its mobility).
static func can_get_to(world: World, unit: Unit, target: SimEntity) -> bool:
	if _gap(unit, target) <= REACH:
		return true
	var mobility: Terrain.Mobility = unit.type.mobility
	var component: int = world.pathing.component_at(unit.x, unit.z, mobility)
	return component != PathLayer.NO_COMPONENT and world.pathing.component_at(target.x, target.z, mobility) == component


## Where something unit carries rides, milli-units above the ground.
static func hand_y(unit: Unit) -> int:
	return unit.y + unit.type.body_height * HAND_PERMILLE / PERMILLE


## Puts p in carrier's hand.
static func take(world: World, carrier: Unit, p: Projectile) -> void:
	p.motion = Projectile.Motion.CARRIED
	p.carrier_id = carrier.id
	p.thrown = false
	p.flight = FlightState.at_mm(carrier.x, hand_y(carrier), carrier.z, 0, 0, 0)
	p.sync_position()
	carrier.carried_id = p.id
	_event(world, ProjectileEvent.Kind.PICK_UP, p, carrier)


## The errand is over: back to the order it interrupted.
static func finish(world: World, unit: Unit) -> void:
	var resume: Unit.Order = unit.resume_order
	unit.clear_errand()
	unit.ground_walked = false
	if resume == Unit.Order.ATTACK_MOVE:
		unit.order = Unit.Order.ATTACK_MOVE
		world.movement.order_move(
			world, unit, unit.order_x, unit.order_z,
			unit.order_facing_x, unit.order_facing_z, unit.order_speed_cap
		)
	else:
		UnitOrders.hold(unit)
		world.movement.order_stop(unit)


## After something else had the unit (a confusion), it starts its walk over.
static func restart(world: World, unit: Unit) -> void:
	unit.act_left = 0
	unit.ground_walked = false
	world.movement.order_stop(unit)


static func _action_on_unit(world: World, unit: Unit, other: Unit) -> Action:
	if other == unit:
		return Action.NONE
	if not other.is_alive():
		return Action.TEAR_PART if _can_tear(world, unit, other) else Action.NONE
	if unit.type.special_ability != UnitType.Special.HEAL or unit.special_left <= 0:
		return Action.NONE
	if Visibility.is_submerged(world.terrain, other):
		return Action.NONE
	if other.type.nature == UnitType.Nature.UNDEAD:
		return Action.HEAL
	if other.faction != unit.faction:
		return Action.NONE
	if other.hp < other.type.max_hp or _has_any_status(world, other):
		return Action.HEAL
	return Action.NONE


static func _has_any_status(world: World, unit: Unit) -> bool:
	for kind: int in StatusEffects.Kind.size():
		if StatusEffects.has(world, unit, kind as StatusEffects.Kind):
			return true
	return false


static func _has_room_for_herbs(unit: Unit) -> bool:
	return unit.type.special_ability == UnitType.Special.HEAL and unit.special_left < unit.type.special_charges


static func _can_tear(world: World, unit: Unit, body: Unit) -> bool:
	return (
		unit.type.throws_carried and unit.type.scavenged_projectile != &""
		and world.carried_by(unit) == null and body.parts_taken < PARTS_PER_BODY
		and body.type.special_ability != UnitType.Special.DETONATE
	)


func _errand(world: World, unit: Unit) -> void:
	if StatusEffects.confused(world, unit):
		return
	if StatusEffects.paralyzed(world, unit) or unit.is_reeling():
		unit.act_left = 0
		return
	var target: SimEntity = world.get_entity(unit.interact_id)
	var action: Action = action_for(world, unit, target) if target != null else Action.NONE
	if action == Action.NONE:
		finish(world, unit)
		return
	var gap: int = _gap(unit, target)
	if unit.act_left > 0:
		_face(unit, target)
		unit.act_left -= 1
		if unit.act_left == 0 and gap <= REACH + REACH_TOLERANCE:
			_act(world, unit, target, action)
		return
	if gap <= REACH:
		if unit.state == Unit.State.MOVING:
			world.movement.order_stop(unit)
		_face(unit, target)
		unit.act_left = _windup(unit, action)
		if unit.act_left == 0:
			_act(world, unit, target, action)
		return
	var drift: int = FixedMath.length(target.x - unit.goal_x, target.z - unit.goal_z)
	if unit.state == Unit.State.MOVING:
		if drift > REPATH_DISTANCE:
			_walk(world, unit, target)
		return
	if unit.ground_walked and drift <= REPATH_DISTANCE:
		# Walked as close as it could get, and it isn't close enough.
		finish(world, unit)
		return
	_walk(world, unit, target)


static func _walk(world: World, unit: Unit, target: SimEntity) -> void:
	unit.ground_walked = true
	world.movement.order_move(world, unit, target.x, target.z, target.x - unit.x, target.z - unit.z, 0)


static func _windup(unit: Unit, action: Action) -> int:
	match action:
		Action.HEAL:
			return unit.type.heal_windup_ticks
		Action.STRIKE_PLANT:
			return unit.type.melee_windup_ticks
	return PICKUP_TICKS


func _act(world: World, unit: Unit, target: SimEntity, action: Action) -> void:
	match action:
		Action.HEAL:
			_heal(world, unit, target as Unit)
		Action.TAKE_HERB:
			_take_herb(world, unit, target as Projectile)
		Action.STRIKE_PLANT:
			_strike_plant(world, unit, target as HerbPlant)
		Action.TAKE_OBJECT:
			take(world, unit, target as Projectile)
		Action.TEAR_PART:
			_tear(world, unit, target as Unit)
	finish(world, unit)


static func _heal(world: World, healer: Unit, patient: Unit) -> void:
	healer.special_left -= 1
	var gained: int = 0
	if patient.type.nature == UnitType.Nature.UNDEAD:
		Damage.apply(world, patient, patient.hp, healer.x, healer.z, healer.id)
	else:
		gained = mini(healer.type.heal_hp, patient.type.max_hp - patient.hp)
		patient.hp += gained
		StatusEffects.cure(world, patient)
	world.combat_events.append(CombatEvent.new(
		CombatEvent.Kind.HEAL, healer.id, patient.id, MeleeCombat.Aspect.FRONT, gained
	))


static func _take_herb(world: World, healer: Unit, herb: Projectile) -> void:
	world.remove_projectile(herb)
	healer.special_left += 1
	_event(world, ProjectileEvent.Kind.PICK_UP, herb, healer)


static func _strike_plant(world: World, _unit: Unit, plant: HerbPlant) -> void:
	plant.spent = true
	var index: int = world.catalog.projectile_index_of(HerbPlant.ROOT_PROJECTILE)
	for k: int in HerbPlant.ROOTS:
		var angle: int = k * FixedMath.ANGLE_FULL / HerbPlant.ROOTS
		world.drop_object(
			index,
			plant.x + FixedMath.cos_b(angle) * HerbPlant.DROP_SPREAD / FixedMath.TRIG_ONE,
			plant.z + FixedMath.sin_b(angle) * HerbPlant.DROP_SPREAD / FixedMath.TRIG_ONE,
			0
		)


static func _tear(world: World, carrier: Unit, body: Unit) -> void:
	var index: int = world.catalog.projectile_index_of(carrier.type.scavenged_projectile)
	if index < 0:
		return
	body.parts_taken += 1
	var part: Projectile = world.spawn_projectile(
		index, FlightState.at_mm(carrier.x, hand_y(carrier), carrier.z, 0, 0, 0), carrier.id
	)
	take(world, carrier, part)


# Healers pick up herbs they touch.
func _gather_herbs(world: World) -> void:
	for unit: Unit in world.units:
		if not unit.is_alive() or not _has_room_for_herbs(unit) or StatusEffects.paralyzed(world, unit):
			continue
		for p: Projectile in world.projectiles:
			if not _has_room_for_herbs(unit):
				break
			if p.removed or p.carrier_id != 0 or p.type.pickup != ProjectileType.Pickup.HERB:
				continue
			if p.motion != Projectile.Motion.RESTING and p.motion != Projectile.Motion.ROLLING:
				continue
			var reach: int = unit.type.body_radius + p.type.radius + CONTACT_REACH
			var dx: int = p.x - unit.x
			var dz: int = p.z - unit.z
			if dx * dx + dz * dz <= reach * reach:
				_take_herb(world, unit, p)


# Milli-units between unit's body edge and target's (a unit's body, a loose
# object's radius, a plant's spread); negative if they overlap.
static func _gap(unit: Unit, target: SimEntity) -> int:
	var radius: int = 0
	if target is Unit:
		radius = (target as Unit).type.body_radius
	elif target is Projectile:
		radius = (target as Projectile).type.radius
	elif target is HerbPlant:
		radius = HerbPlant.RADIUS
	return FixedMath.length(target.x - unit.x, target.z - unit.z) - unit.type.body_radius - radius


static func _face(unit: Unit, target: SimEntity) -> void:
	var dir: Vector2i = FixedMath.normalize(target.x - unit.x, target.z - unit.z, FixedMath.DIR_ONE)
	if dir != Vector2i.ZERO:
		unit.facing_x = dir.x
		unit.facing_z = dir.y


static func _event(world: World, kind: ProjectileEvent.Kind, p: Projectile, unit: Unit) -> void:
	var e: ProjectileEvent = ProjectileEvent.about(kind, p)
	e.unit_id = unit.id
	world.projectile_events.append(e)
