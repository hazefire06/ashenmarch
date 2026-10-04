class_name AiDirector
extends RefCounted
## Owns every AiGroup in a world: spawns them from specs, switches their
## behavior, and each tick keeps their member lists honest and lets them think
## (AiBehaviors). Like MeleeCombat, it is stateless apart from what it hashes,
## and it draws no random numbers.
##
## A group thinks every THINK_TICKS, staggered by its id so groups don't all
## plan on the same tick, and at once when think_now is set (a new behavior).

## Ticks between one plan and the next for a group, so the AI isn't re-ordering
## units 30 times a second. A group with think_now set plans at once instead.
const THINK_TICKS: int = 15

## Every group ever spawned, in creation order (ascending id). Emptied groups
## stay, so triggers can tell a cleared group from one that never spawned.
var groups: Array[AiGroup] = []

var _next_group_id: int = 1
## Every unit id any group ever spawned, so controls() is a lookup instead of a
## scan of every group's spawned_ids. It holds nothing the groups don't, so it
## isn't hashed (the groups' spawned_ids are).
var _controlled: Dictionary[int, bool] = {}


## Spawns one instance of spec, the tier's units laid out in the spec's
## formation at the tier's spawn point. spec_index is the spec's place in the
## MissionScript, which triggers use to find the group again. A tier with no
## units still makes the (empty) group, so GROUP_CLEARED sees it spawned. The
## spec must have passed MissionScript.validate().
func spawn_group(world: World, spec: AiGroupSpec, spec_index: int, tier: int) -> AiGroup:
	var type_indices: Array[int] = []
	var largest_radius: int = 0
	for entry: AiUnitEntry in spec.units:
		var type_index: int = world.catalog.index_of(entry.type_id)
		for _n: int in Difficulty.pick(entry.counts, tier):
			type_indices.append(type_index)
			largest_radius = maxi(largest_radius, world.catalog.types[type_index].body_radius)
	var at: Vector2i = spec.spawn_point(tier)
	var group: AiGroup = AiGroup.new(_next_group_id, spec_index, spec, spec.faction, at.x, at.y)
	_next_group_id += 1
	var slots: Array[FormationSlot] = Formations.slots(
		spec.formation, type_indices.size(), at.x, at.y, spec.facing_x, spec.facing_z,
		Formations.spacing_for(largest_radius)
	)
	for i: int in type_indices.size():
		var unit: Unit = world.spawn_unit(
			type_indices[i], spec.faction, slots[i].x, slots[i].z, slots[i].facing_x, slots[i].facing_z
		)
		group.spawned_ids.append(unit.id)
		_controlled[unit.id] = true
		group.members.append(unit.id)
		group.ordered_x.append(unit.x)
		group.ordered_z.append(unit.z)
		group.ordered_target.append(0)
		group.ordered_attack.append(0)
		group.start_hp += unit.hp
	group.last_hp = group.start_hp
	groups.append(group)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.SPAWNED, group.id, at.x, at.y, type_indices.size()))
	return group


## True if a group ever had this unit: the AI spawned it, as opposed to a unit
## the player commands. Once AI, always AI: a unit that dies, is despawned, or
## changes side is still the one a group spawned. O(1).
func controls(unit_id: int) -> bool:
	return _controlled.has(unit_id)


## Gives the group a new behavior with a clean slate: the old plan's progress
## is dropped and the group plans at the next update. A group leaving AMBUSH
## springs first, so whatever ends the ambush (an alert, or a trigger that sets
## another behavior) brings the lurkers up, and the spring is reported before
## the change.
func set_behavior(world: World, group: AiGroup, behavior: AiGroupSpec.Behavior) -> void:
	if group.behavior == AiGroupSpec.Behavior.AMBUSH and behavior != AiGroupSpec.Behavior.AMBUSH:
		spring(world, group)
	group.behavior = behavior
	group.phase = 0
	group.leg_active = false
	group.leg_retried = false
	group.focus_id = 0
	group.route = PackedInt64Array()
	group.route_index = 0
	group.plan_x = 0
	group.plan_z = 0
	group.think_now = true
	world.ai_events.append(AiEvent.new(AiEvent.Kind.BEHAVIOR, group.id, 0, 0, behavior))


## Brings an ambush up: every living member surfaces for good (Unit.surfaced),
## so it can be seen and fought in deep water, and one AMBUSH_SPRUNG is
## reported at the members' centroid with the member count. A group with no
## living members has nothing to bring up and reports nothing. set_behavior
## calls this when a group leaves AMBUSH; nothing else should need to.
func spring(world: World, group: AiGroup) -> void:
	var units: Array[Unit] = group.living(world)
	if units.is_empty():
		return
	for unit: Unit in units:
		unit.surfaced = true
	var c: Vector2i = AiOrders.centroid(units)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.AMBUSH_SPRUNG, group.id, c.x, c.y, units.size()))


## The groups spawned from the spec at spec_index, in creation order.
func groups_of(spec_index: int) -> Array[AiGroup]:
	var out: Array[AiGroup] = []
	for group: AiGroup in groups:
		if group.spec_index == spec_index:
			out.append(group)
	return out


## Runs once a tick, after the mission's triggers, group by group in creation
## order: drops members that died or changed side, then a group that still has
## members thinks if it is its turn or think_now is set. The think spends the
## request: think_now is cleared before it.
func update(world: World) -> void:
	for group: AiGroup in groups:
		group.prune(world)
		if group.members.is_empty():
			continue
		if group.think_now or (world.tick + group.id) % THINK_TICKS == 0:
			group.think_now = false
			AiBehaviors.think(world, group)


## Everything the AI keeps: the next group id, then each group's fields.
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([_next_group_id, groups.size()])
	for group: AiGroup in groups:
		fields.append_array(group.hash_fields())
	return fields
