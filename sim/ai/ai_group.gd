class_name AiGroup
extends RefCounted
## One spawned instance of an AiGroupSpec: who is in it, what it is doing, and
## what the AI last told each member to do. The spec says what the group is
## meant to do; this is the progress, so everything except `spec` is hashed
## (hash_fields). A spec spawned twice makes two groups.
##
## Members are unit ids in ascending order. A unit that dies, despawns, or
## changes side (conversion) leaves `members` at the next prune() and never
## comes back; `spawned_ids` keeps everyone the group ever had, so triggers can
## count its dead.

## Director-assigned, from 1 in creation order.
var id: int
## Index of `spec` in the MissionScript's groups. Hashed instead of the spec.
var spec_index: int
## What spawned this group. Read-only: load() hands every world the same
## instance, so never change it.
var spec: AiGroupSpec
## The side its members fight for.
var faction: UnitType.Faction

## Every unit this group ever had, ascending. Never pruned.
var spawned_ids: PackedInt32Array = PackedInt32Array()
## Members still alive and still on `faction`, ascending.
var members: PackedInt32Array = PackedInt32Array()
## What the AI last sent each member to, parallel to `members` and pruned with
## it: where it was sent, the unit id of the objective it was sent after (0
## for none), and whether it was an attack-move (1) or a plain move (0). The
## AI compares these with its next plan so it only re-orders a member when the
## plan changed. Where it was sent is never the member's own formation slot:
## - a march: the march's goal, for STANDOFF members too, though they are
##   sent to a point short of it (AiTactics.behind);
## - an ASSAULT member, or a STANDOFF member with no spot: the objective's
##   position when it was sent;
## - a STANDOFF member to a firing spot: that spot (StandoffSpot);
## - a CLUSTER member: the middle of the knot (ClusterFinder).
## A new member starts recorded at its own position, with no objective.
var ordered_x: PackedInt64Array = PackedInt64Array()
var ordered_z: PackedInt64Array = PackedInt64Array()
var ordered_target: PackedInt32Array = PackedInt32Array()
var ordered_attack: PackedByteArray = PackedByteArray()

var behavior: AiGroupSpec.Behavior
## Sub-state of the behavior; 0 is fresh, so set_behavior restarts it.
var phase: int = 0
## Asks the AI to plan at the next update instead of waiting for its interval.
var think_now: bool = false

## Where the group spawned.
var spawn_x: int
var spawn_z: int
## The post a GUARD group holds or the spot an AMBUSH group waits at. Starts at
## the spawn point.
var anchor_x: int
var anchor_z: int

## PATROL: the waypoint being walked to (pair index) and which way the index
## advances (1 or -1).
var waypoint_index: int = 0
var waypoint_step: int = 1
## A leg is one march to one goal. While one is active, (leg_x, leg_z) is its
## goal and leg_retried says it already got one second try.
var leg_active: bool = false
var leg_x: int = 0
var leg_z: int = 0
var leg_retried: bool = false

## FLANK: the unit being circled, the route around it as x, z pairs, and the
## pair being walked to.
var focus_id: int = 0
var route: PackedInt64Array = PackedInt64Array()
var route_index: int = 0

## Hit points of the members at spawn and when the AI last looked. The drop
## from one to the other is what makes a group retreat, or springs an ambush.
var start_hp: int = 0
var last_hp: int = 0
## True once the group has retreated; it only retreats once.
var retreated: bool = false


func _init(
	group_id: int, index: int, group_spec: AiGroupSpec, side: UnitType.Faction, at_x: int, at_z: int
) -> void:
	id = group_id
	spec_index = index
	spec = group_spec
	faction = side
	behavior = group_spec.behavior
	spawn_x = at_x
	spawn_z = at_z
	anchor_x = at_x
	anchor_z = at_z


## Position of unit_id in `members`, or -1 if it isn't a member.
func member_index(unit_id: int) -> int:
	return members.find(unit_id)


## Drops members that are dead, gone, or no longer on the group's side, along
## with their order records.
func prune(world: World) -> void:
	var kept: PackedInt32Array = PackedInt32Array()
	var kept_x: PackedInt64Array = PackedInt64Array()
	var kept_z: PackedInt64Array = PackedInt64Array()
	var kept_target: PackedInt32Array = PackedInt32Array()
	var kept_attack: PackedByteArray = PackedByteArray()
	for i: int in members.size():
		if not _is_member(world.get_unit(members[i])):
			continue
		kept.append(members[i])
		kept_x.append(ordered_x[i])
		kept_z.append(ordered_z[i])
		kept_target.append(ordered_target[i])
		kept_attack.append(ordered_attack[i])
	if kept.size() == members.size():
		return
	members = kept
	ordered_x = kept_x
	ordered_z = kept_z
	ordered_target = kept_target
	ordered_attack = kept_attack


## The members as units, in ascending id order, skipping any that died or
## changed side since the last prune.
func living(world: World) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit_id: int in members:
		var unit: Unit = world.get_unit(unit_id)
		if _is_member(unit):
			out.append(unit)
	return out


## Notes that the AI sent unit_id to (x, z) after objective target_id (0 for
## none), attack-moving if attack. Ignores units that aren't members.
func record_order(unit_id: int, x: int, z: int, target_id: int, attack: bool = false) -> void:
	var i: int = member_index(unit_id)
	if i < 0:
		return
	ordered_x[i] = x
	ordered_z[i] = z
	ordered_target[i] = target_id
	ordered_attack[i] = 1 if attack else 0


## Every hashed field. Packed arrays come after their sizes, so two groups
## can't hash alike by moving a boundary.
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([
		id, spec_index, faction, behavior, phase, int(think_now),
		spawn_x, spawn_z, anchor_x, anchor_z,
		waypoint_index, waypoint_step, int(leg_active), leg_x, leg_z, int(leg_retried),
		focus_id, route_index, start_hp, last_hp, int(retreated),
	])
	fields.append(spawned_ids.size())
	for unit_id: int in spawned_ids:
		fields.append(unit_id)
	fields.append(members.size())
	for unit_id: int in members:
		fields.append(unit_id)
	fields.append(ordered_x.size())
	fields.append_array(ordered_x)
	fields.append(ordered_z.size())
	fields.append_array(ordered_z)
	fields.append(ordered_target.size())
	for target_id: int in ordered_target:
		fields.append(target_id)
	fields.append(ordered_attack.size())
	for attack: int in ordered_attack:
		fields.append(attack)
	fields.append(route.size())
	fields.append_array(route)
	return fields


func _is_member(unit: Unit) -> bool:
	return unit != null and unit.is_alive() and unit.faction == faction
