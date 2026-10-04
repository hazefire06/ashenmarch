class_name Visibility
extends RefCounted
## What each side can see. Pure functions of the World; no state.
##
## A unit that hides in deep water (UnitType.hidden_in_deep_water: Husks) is
## submerged at depth Terrain.LIVING_IMPASSABLE_DEPTH or more, unless it is
## fighting (it surfaced to do it) or has sprung from an ambush
## (Unit.surfaced, for good). Submerged units can't be targeted or hit by
## anyone: melee and ranged don't pick them, and projectiles pass over them.
## That holds whoever sees them.
##
## Seeing is about the player's view (the units view draws only what the
## commanding side sees): a side sees its own units, every unit that isn't
## submerged, and a submerged one only while a living unit of that side is
## within its type's reveal_radius.


## True if the unit is out of sight in deep water, lying in wait.
static func is_submerged(terrain: Terrain, unit: Unit) -> bool:
	return (
		unit.type.hidden_in_deep_water
		and not unit.surfaced
		and unit.state != Unit.State.ATTACKING
		and terrain.water_depth_at(unit.x, unit.z) >= Terrain.LIVING_IMPASSABLE_DEPTH
	)


## True if the viewer's side can see the unit.
static func seen_by(world: World, unit: Unit, viewer: UnitType.Faction) -> bool:
	if unit.faction == viewer or not is_submerged(world.terrain, unit):
		return true
	var reach: int = unit.type.reveal_radius
	if reach <= 0:
		return false
	for other: Unit in world.units:
		if other.faction != viewer or not other.is_alive():
			continue
		var dx: int = other.x - unit.x
		var dz: int = other.z - unit.z
		if dx * dx + dz * dz <= reach * reach:
			return true
	return false
