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


## True if the viewer's side has spotted the unit, for the corner map: its own
## units always; otherwise the unit must be seen_by the side and a living unit
## of the side must be within its type's sight_radius (horizontal) with a
## clear_sight line. Display only: the sim step never calls this.
static func spotted_by(world: World, unit: Unit, viewer: UnitType.Faction) -> bool:
	if unit.faction == viewer:
		return true
	if not seen_by(world, unit, viewer):
		return false
	for other: Unit in world.units:
		if other.faction != viewer or not other.is_alive():
			continue
		var reach: int = other.type.sight_radius
		var dx: int = unit.x - other.x
		var dz: int = unit.z - other.z
		if dx * dx + dz * dz > reach * reach:
			continue
		if clear_sight(world, other, unit):
			return true
	return false


## True if no terrain stands between from_unit's eye (its body height above the
## ground) and to_unit's body centre (half its body height up). Marches one
## terrain sample per cell in integer maths; blocked when the ground at any
## intermediate sample is above the line.
static func clear_sight(world: World, from_unit: Unit, to_unit: Unit) -> bool:
	var terrain: Terrain = world.terrain
	var eye_y: int = terrain.height_at(from_unit.x, from_unit.z) + from_unit.type.body_height
	var target_y: int = terrain.height_at(to_unit.x, to_unit.z) + to_unit.type.body_height / 2
	var dx: int = to_unit.x - from_unit.x
	var dz: int = to_unit.z - from_unit.z
	var steps: int = maxi(absi(dx), absi(dz)) / terrain.cell_size
	for s: int in range(1, steps):
		var x: int = from_unit.x + dx * s / steps
		var z: int = from_unit.z + dz * s / steps
		var line_y: int = eye_y + (target_y - eye_y) * s / steps
		if terrain.height_at(x, z) > line_y:
			return false
	return true
