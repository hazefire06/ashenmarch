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
## ground) and to_unit's body centre (half its body height up). Marches in
## integer maths, a sample every quarter cell; blocked when the ground at any
## intermediate sample is above the line. The fine spacing keeps a wall one
## vertex wide (a bilinear tent) from slipping between samples: the nearest
## one is within an eighth of a cell of its peak, so over 87 % of its height.
## hover_height and unit.y are ignored (display only; a Drifter is judged from
## the ground).
static func clear_sight(world: World, from_unit: Unit, to_unit: Unit) -> bool:
	var terrain: Terrain = world.terrain
	var eye_y: int = terrain.height_at(from_unit.x, from_unit.z) + from_unit.type.body_height
	var target_y: int = terrain.height_at(to_unit.x, to_unit.z) + to_unit.type.body_height / 2
	var dx: int = to_unit.x - from_unit.x
	var dz: int = to_unit.z - from_unit.z
	var steps: int = maxi(absi(dx), absi(dz)) * 4 / terrain.cell_size
	for s: int in range(1, steps):
		var x: int = from_unit.x + dx * s / steps
		var z: int = from_unit.z + dz * s / steps
		var line_y: int = eye_y + (target_y - eye_y) * s / steps
		if terrain.height_at(x, z) > line_y:
			return false
	return true


## Like spotted_by for an enemy of the viewer, but returns the id of a viewer
## unit that spots it, or -1. hint_id (a viewer unit that spotted it before, or
## -1) is tried first, and every candidate passes a cheap squared-range check
## before the line-of-sight march. A unit of the viewer's own side returns its
## own id. Display only.
static func spotted_by_hint(world: World, unit: Unit, viewer: UnitType.Faction, hint_id: int) -> int:
	if unit.faction == viewer:
		return unit.id
	if not seen_by(world, unit, viewer):
		return -1
	if hint_id >= 0 and _spots(world, world.entities.get(hint_id) as Unit, unit, viewer):
		return hint_id
	for other: Unit in world.units:
		if other.id != hint_id and _spots(world, other, unit, viewer):
			return other.id
	return -1


static func _spots(world: World, other: Unit, unit: Unit, viewer: UnitType.Faction) -> bool:
	if other == null or other.faction != viewer or not other.is_alive():
		return false
	var reach: int = other.type.sight_radius
	var dx: int = unit.x - other.x
	var dz: int = unit.z - other.z
	return dx * dx + dz * dz <= reach * reach and clear_sight(world, other, unit)
