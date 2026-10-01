class_name Fire
extends RefCounted
## Brush fire on the terrain's sample grid, run by World.step() after
## Explosions. A cell is a terrain sample, the same nearest-sample rule as
## water and pathing.
##
## - A cell catches if its ground is grass, brush, or wood, it is dry (water
##   depth 0), and it hasn't burned. Sand, rock, and water never burn, so
##   they are firebreaks.
## - A fire arrow lights a cell (ignite). A burning cell burns for its
##   ground's BURN_TICKS, then is SCORCHED for good.
## - Every tick, each burning cell may light each unburnt flammable neighbor
##   (8 of them; diagonals at DIAGONAL_PERMILLE of the chance), at the
##   neighbor's ground's SPREAD_PPM, damped by rain, wet ground, and snow
##   cover (spread_damping_permille).
## - Rain puts burning cells out: each rolls DOUSE_PPM_AT_FULL_RAIN (scaled
##   by intensity) every tick, and a doused cell is scorched.
## - Every DAMAGE_INTERVAL_TICKS, each living unit standing on a burning
##   cell loses DAMAGE hit points (Damage.apply), credited to whoever lit the
##   fire. A cell lit by the spread inherits its source's lighter.
## - A charge, grenade, or dud lying or rolling on a burning cell is caught,
##   exactly as a blast catches it (Explosions.catch), credited the same way.
##
## Update, per tick:
## 1. Burning cells, in ascending sample index, as they stood at the start
##    of the pass: the douse roll (only while it rains); if still burning,
##    a spread roll per unburnt flammable neighbor (only when the chance
##    isn't zero), in row-major neighbor order; then a tick off its time. A
##    neighbor lit now is burning at once, so no later cell rolls for it,
##    but it first spreads next tick.
## 2. Damage, on its interval: living units in ascending id.
## 3. Explosives: projectiles in ascending id.
## Every roll is a draw from World.rng in that order; nothing else is
## random. Wind doesn't affect fire.
##
## Rates are rules of the world, kept here like MeleeCombat's flank
## multipliers; they are starting values to tune in playtests.

## A cell's state.
enum Cell {
	UNBURNT,
	BURNING,
	SCORCHED,
}

const PERMILLE: int = 1000
const PPM: int = 1_000_000
## Chance per tick, in parts per million, that a burning cell lights an
## unburnt orthogonal neighbor of this ground (by Terrain.Ground). On 1 m
## cells, grass runs at about 0.5 m/s, brush 0.3, wood 0.15.
const SPREAD_PPM: Array[int] = [17_000, 10_000, 5_000, 0, 0]
## Ticks a cell of this ground burns: grass 4 s, brush 10 s, wood 25 s.
const BURN_TICKS: Array[int] = [120, 300, 750, 0, 0]
## Diagonal neighbors are farther: they catch at this share of the chance.
const DIAGONAL_PERMILLE: int = 707
## Chance per tick, ppm, that full rain puts a burning cell out (about 2 s
## on average).
const DOUSE_PPM_AT_FULL_RAIN: int = 15_000
## Share of the spread chance taken away by full rain, by soaked ground, and
## by full snow cover, permille. They compound.
const RAIN_SPREAD_CUT: int = 900
const WET_SPREAD_CUT: int = 800
const SNOW_SPREAD_CUT: int = 900
## Hit points lost every DAMAGE_INTERVAL_TICKS standing on a burning cell
## (9 hp/s).
const DAMAGE: int = 3
const DAMAGE_INTERVAL_TICKS: int = 10
## Neighbor offsets (di, dj), row-major.
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

var terrain: Terrain
## Cell per sample, row-major like the terrain. Empty until the first fire,
## so a world that never burns carries no grid.
var state: PackedByteArray = PackedByteArray()
## Burning cells: sample index -> ticks left to burn.
var burning: Dictionary[int, int] = {}
## Burning cells: sample index -> the unit credited with what it does (0 for
## none).
var lit_by: Dictionary[int, int] = {}
## Sample indices whose cell changed this tick, in the order they changed,
## for the view. Output only: World clears it at the start of each step, and
## it is not part of state_hash().
var changed: PackedInt32Array = PackedInt32Array()


func _init(world_terrain: Terrain) -> void:
	terrain = world_terrain


## Lights the cell at (x, z), credited to instigator_id. Returns false, and
## changes nothing, if it can't burn: sand, rock, water, or already burning
## or burnt. World.ignite() is the same plus an IGNITE event for the view.
func ignite(x: int, z: int, instigator_id: int) -> bool:
	var at: Vector2i = terrain.nearest_sample(x, z)
	var k: int = at.y * terrain.size_x + at.x
	if not _flammable(k):
		return false
	_light(k, instigator_id)
	return true


## The cell at (x, z): UNBURNT, BURNING, or SCORCHED.
func cell_at(x: int, z: int) -> Cell:
	if state.is_empty():
		return Cell.UNBURNT
	var at: Vector2i = terrain.nearest_sample(x, z)
	return state[at.y * terrain.size_x + at.x] as Cell


## Share of the spread chance left, permille, under this much rain, wet
## ground, and snow cover (all permille).
static func spread_damping_permille(rain: int, wetness: int, snow_cover: int) -> int:
	return (
		(PERMILLE - rain * RAIN_SPREAD_CUT / PERMILLE)
		* (PERMILLE - wetness * WET_SPREAD_CUT / PERMILLE)
		* (PERMILLE - snow_cover * SNOW_SPREAD_CUT / PERMILLE)
	) / (PERMILLE * PERMILLE)


func update(world: World) -> void:
	if burning.is_empty():
		return
	var weather: Weather = world.weather
	var douse: int = weather.rain * DOUSE_PPM_AT_FULL_RAIN / PERMILLE
	var damping: int = spread_damping_permille(weather.rain, weather.wetness(), weather.snow_cover())
	var cells: Array[int] = []
	cells.assign(burning.keys())
	cells.sort()
	for k: int in cells:
		if douse > 0 and world.rng.randi_range(0, PPM - 1) < douse:
			_scorch(k)
			continue
		_spread_from(world, k, damping)
		var left: int = burning[k] - 1
		if left <= 0:
			_scorch(k)
		else:
			burning[k] = left
	if world.tick % DAMAGE_INTERVAL_TICKS == 0:
		_burn_units(world)
	_catch_explosives(world)


## Burning cells with their time left and lighter, in sample order.
## World.state_hash() adds the grid itself (state) once there is one.
func hash_fields() -> PackedInt64Array:
	var keys: Array[int] = []
	keys.assign(burning.keys())
	keys.sort()
	var fields: PackedInt64Array = PackedInt64Array([keys.size(), state.size()])
	for k: int in keys:
		fields.append(k)
		fields.append(burning[k])
		fields.append(lit_by[k])
	return fields


func _flammable(k: int) -> bool:
	if BURN_TICKS[terrain.ground[k]] <= 0 or terrain.water[k] > 0:
		return false
	return state.is_empty() or state[k] == Cell.UNBURNT


func _light(k: int, instigator_id: int) -> void:
	if state.is_empty():
		state.resize(terrain.size_x * terrain.size_z)
	state[k] = Cell.BURNING
	burning[k] = BURN_TICKS[terrain.ground[k]]
	lit_by[k] = instigator_id
	changed.append(k)


func _scorch(k: int) -> void:
	state[k] = Cell.SCORCHED
	burning.erase(k)
	lit_by.erase(k)
	changed.append(k)


func _spread_from(world: World, k: int, damping: int) -> void:
	var i: int = k % terrain.size_x
	var j: int = k / terrain.size_x
	for offset: Vector2i in NEIGHBORS:
		var ni: int = i + offset.x
		var nj: int = j + offset.y
		if ni < 0 or nj < 0 or ni >= terrain.size_x or nj >= terrain.size_z:
			continue
		var nk: int = nj * terrain.size_x + ni
		if not _flammable(nk):
			continue
		var chance: int = SPREAD_PPM[terrain.ground[nk]] * damping / PERMILLE
		if offset.x != 0 and offset.y != 0:
			chance = chance * DIAGONAL_PERMILLE / PERMILLE
		if chance > 0 and world.rng.randi_range(0, PPM - 1) < chance:
			_light(nk, lit_by[k])


func _burn_units(world: World) -> void:
	for unit: Unit in world.units:
		if not unit.is_alive():
			continue
		var at: Vector2i = terrain.nearest_sample(unit.x, unit.z)
		var k: int = at.y * terrain.size_x + at.x
		if state[k] == Cell.BURNING:
			Damage.apply(
				world, unit, DAMAGE, at.x * terrain.cell_size, at.y * terrain.cell_size, lit_by[k]
			)


func _catch_explosives(world: World) -> void:
	for p: Projectile in world.projectiles:
		if p.removed or p.detonating or not p.type.chain_detonates:
			continue
		if p.motion == Projectile.Motion.FLYING:
			continue
		var at: Vector2i = terrain.nearest_sample(p.x, p.z)
		var k: int = at.y * terrain.size_x + at.x
		if state[k] == Cell.BURNING:
			world.explosions.catch(p, lit_by[k])
