class_name Fire
extends RefCounted
## Brush fire on the terrain's sample grid, run by World.step() after
## Explosions. A cell is a terrain sample, the same nearest-sample rule as
## water and pathing.
##
## - A cell catches if its ground is grass, brush, or wood, it is dry (water
##   depth 0), and it hasn't burned. Sand, rock, and water never burn, so
##   they are firebreaks.
## - A fire arrow lights a cell (World.ignite). A cell lit during tick L
##   burns until the end of tick L + its ground's BURN_TICKS, then is
##   SCORCHED for good.
## - Every tick, each burning cell may light each unburnt flammable neighbor
##   (8 of them; diagonals at DIAGONAL_PERMILLE of the chance), at the
##   neighbor's ground's SPREAD_PPM, damped by rain, wet ground, and snow
##   cover (spread_damping_permille). Speed is set by the chance, and how
##   surely a fire keeps going by the chance times the burn time, which is
##   why cells burn for a while: a slow fire that also died out at random
##   would be no fire at all.
## - Rain puts burning cells out: each rolls DOUSE_PPM_AT_FULL_RAIN (scaled
##   by intensity) every tick, and a doused cell is scorched.
## - Every DAMAGE_INTERVAL_TICKS, each living unit standing on a burning
##   cell loses DAMAGE hit points (Damage.apply), credited to whoever lit the
##   fire. A cell lit by the spread inherits its source's lighter.
## - A charge, grenade, or dud lying or rolling on a burning cell is caught,
##   exactly as a blast catches it (Explosions.catch), credited the same way.
##
## Update, per tick, every list in ascending sample index:
## 1. Douse (only while it rains): one roll per burning cell.
## 2. Spread: the front (burning cells that may still have an unburnt
##    flammable neighbor), as it stood at the start of the pass. One roll
##    per unburnt flammable neighbor whose chance isn't zero, in row-major
##    neighbor order. A neighbor lit now is burning at once, so no later
##    cell rolls for it, but it first spreads next tick. A front cell with
##    no such neighbor leaves the front for good: cells only ever go from
##    unburnt to burning to scorched.
## 3. Burn-outs: cells whose time ends this tick are scorched.
## 4. Damage, on its interval: living units in ascending id.
## 5. Explosives: projectiles in ascending id.
## Every roll is a draw from World.rng in that order; nothing else is
## random. Wind doesn't affect fire. Only the front does spreading work and
## burn-outs are kept by tick, so a fire costs per tick in proportion to its
## edge, not its area.
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
## unburnt orthogonal neighbor of this ground (by Terrain.Ground). Measured
## on open 1 m ground in clear weather, the front runs at about 0.6 m/s in
## grass, 0.3 in brush, and 0.15 in wood: many paths race, so it is several
## times faster than one neighbor's average wait suggests.
const SPREAD_PPM: Array[int] = [4_000, 2_000, 1_000, 0, 0]
## Ticks a cell of this ground burns: grass 10 s, brush 20 s, wood 40 s.
## Chance times burn time is 1.2 for each, which keeps a dry fire going
## every time (none died out in the measurements) while a burning band
## stays about 6 m deep. Rain, wet ground, or snow cuts it below that, and
## then fires die.
const BURN_TICKS: Array[int] = [300, 600, 1200, 0, 0]
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
## Burning cells: sample index -> the tick at whose end it burns out.
var burn_end: Dictionary[int, int] = {}
## Burning cells: sample index -> the unit credited with what it does (0 for
## none).
var lit_by: Dictionary[int, int] = {}
## Sample indices whose cell changed this tick, in the order they changed,
## for the view. Output only: World clears it at the start of each step, and
## it is not part of state_hash().
var changed: PackedInt32Array = PackedInt32Array()

## Burning cells that may still spread. Which cells are in it changes how
## much work a tick does, never what happens: a cell with nothing left to
## light rolls nothing whether it is in it or not. Not hashed.
var _front: Dictionary[int, bool] = {}
## Burn-outs by tick: tick -> cells lit to burn out at its end. Derived from
## burn_end; not hashed.
var _ending: Dictionary[int, PackedInt32Array] = {}


func _init(world_terrain: Terrain) -> void:
	terrain = world_terrain


## Lights the cell at (x, z) during tick, credited to instigator_id. Returns
## false, and changes nothing, if it can't burn: sand, rock, water, or
## already burning or burnt. World.ignite() is the same plus an IGNITE event
## for the view.
func ignite(x: int, z: int, instigator_id: int, tick: int) -> bool:
	var at: Vector2i = terrain.nearest_sample(x, z)
	var k: int = at.y * terrain.size_x + at.x
	if not _flammable(k):
		return false
	_light(k, instigator_id, tick)
	return true


## The cell at (x, z): UNBURNT, BURNING, or SCORCHED.
func cell_at(x: int, z: int) -> Cell:
	if state.is_empty():
		return Cell.UNBURNT
	var at: Vector2i = terrain.nearest_sample(x, z)
	return state[at.y * terrain.size_x + at.x] as Cell


## True while anything burns.
func is_burning() -> bool:
	return not burn_end.is_empty()


## Share of the spread chance left, permille, under this much rain, wet
## ground, and snow cover (all permille).
static func spread_damping_permille(rain: int, wetness: int, snow_cover: int) -> int:
	return (
		(PERMILLE - rain * RAIN_SPREAD_CUT / PERMILLE)
		* (PERMILLE - wetness * WET_SPREAD_CUT / PERMILLE)
		* (PERMILLE - snow_cover * SNOW_SPREAD_CUT / PERMILLE)
	) / (PERMILLE * PERMILLE)


func update(world: World) -> void:
	if burn_end.is_empty():
		return
	var weather: Weather = world.weather
	var douse: int = weather.rain * DOUSE_PPM_AT_FULL_RAIN / PERMILLE
	if douse > 0:
		for k: int in _sorted(burn_end.keys()):
			if world.rng.randi_range(0, PPM - 1) < douse:
				_scorch(k)
	var damping: int = spread_damping_permille(weather.rain, weather.wetness(), weather.snow_cover())
	for k: int in _sorted(_front.keys()):
		if state[k] != Cell.BURNING:
			_front.erase(k)
		elif not _spread_from(world, k, damping):
			_front.erase(k)
	if _ending.has(world.tick):
		for k: int in _ending[world.tick]:
			if state[k] == Cell.BURNING and burn_end[k] == world.tick:
				_scorch(k)
		_ending.erase(world.tick)
	if world.tick % DAMAGE_INTERVAL_TICKS == 0:
		_burn_units(world)
	_catch_explosives(world)


## Burning cells with when they burn out and who lit them, in sample order.
## World.state_hash() adds the grid itself (state) once there is one.
func hash_fields() -> PackedInt64Array:
	var keys: Array[int] = _sorted(burn_end.keys())
	var fields: PackedInt64Array = PackedInt64Array([keys.size(), state.size()])
	for k: int in keys:
		fields.append(k)
		fields.append(burn_end[k])
		fields.append(lit_by[k])
	return fields


func _flammable(k: int) -> bool:
	if BURN_TICKS[terrain.ground[k]] <= 0 or terrain.water[k] > 0:
		return false
	return state.is_empty() or state[k] == Cell.UNBURNT


func _light(k: int, instigator_id: int, tick: int) -> void:
	if state.is_empty():
		state.resize(terrain.size_x * terrain.size_z)
	state[k] = Cell.BURNING
	var end: int = tick + BURN_TICKS[terrain.ground[k]]
	burn_end[k] = end
	lit_by[k] = instigator_id
	_front[k] = true
	if not _ending.has(end):
		_ending[end] = PackedInt32Array()
	_ending[end].append(k)
	changed.append(k)


func _scorch(k: int) -> void:
	state[k] = Cell.SCORCHED
	burn_end.erase(k)
	lit_by.erase(k)
	_front.erase(k)
	changed.append(k)


# Rolls to light each unburnt flammable neighbor of k. Returns false if k
# had none left, so it can leave the front.
func _spread_from(world: World, k: int, damping: int) -> bool:
	var i: int = k % terrain.size_x
	var j: int = k / terrain.size_x
	var any: bool = false
	for offset: Vector2i in NEIGHBORS:
		var ni: int = i + offset.x
		var nj: int = j + offset.y
		if ni < 0 or nj < 0 or ni >= terrain.size_x or nj >= terrain.size_z:
			continue
		var nk: int = nj * terrain.size_x + ni
		if not _flammable(nk):
			continue
		any = true
		var chance: int = SPREAD_PPM[terrain.ground[nk]] * damping / PERMILLE
		if offset.x != 0 and offset.y != 0:
			chance = chance * DIAGONAL_PERMILLE / PERMILLE
		if chance > 0 and world.rng.randi_range(0, PPM - 1) < chance:
			_light(nk, lit_by[k], world.tick)
	return any


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


static func _sorted(keys: Array) -> Array[int]:
	var out: Array[int] = []
	out.assign(keys)
	out.sort()
	return out
