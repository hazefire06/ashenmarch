class_name PlaytestPilot
extends RefCounted
## A bot that plays the Light side of a mission through the same commands the
## player's input produces (World.enqueue), once every THINK_TICKS: the
## playtest's stand-in for a person. It sees what a player sees (a Dark unit
## lying submerged in deep water is not in its list, Visibility.seen_by) and
## orders only the soldiers the player commands: never a Light unit the AI
## spawned (The Ford's villager), which it only looks at.
##
## Two pilots, so the numbers bracket what a real player does:
## - NAIVE attack-moves every soldier at the next point of the route, advancing
##   when the army's centroid arrives (stragglers are not waited for); once the
##   route is done it attack-moves at the nearest visible enemy, again at every
##   think. On The Ford, whose hint says the villager walks only while soldiers
##   are near, it walks everyone back to him when he is LOST_VILLAGER_M from every
##   soldier. Nothing else: no formation play, no specials, no healing, no holding.
## - COMPETENT plays like a careful person who knows the map:
##   - the melee (Shieldmen and Reavers) attack-moves in a short line at the
##     route point, or at the nearest visible enemy while one is within
##     CLEAR_M of them; the route advances when they are within ARRIVED_M of the
##     point and nothing visible is within CLEAR_M; the rest follow
##     FOLLOW_BEHIND_M behind the melee's centroid;
##   - each Sapper ground-attacks a visible cluster of CLUSTER_MIN enemies in
##     range when no friend is within GRENADE_CLEAR_M of the aim point (and the
##     aim isn't in water, which puts a fuse out);
##   - each Longbow nocks its fire arrow and ground-attacks a cluster of
##     CLUSTER_MIN enemies standing on brush or wood (the pilot's own additions,
##     because a fire spreads and a ground attack ignores bodies in its way: no
##     friend within FIRE_CLEAR_M of the aim or LINE_CLEAR_M of the line of
##     flight, no charge on the ground within FIRE_CHARGE_CLEAR_M);
##   - each Warden heals the friend lowest in hit points, below HEAL_BELOW_PERCENT
##     per cent, within HEAL_REACH_M of it;
##   - The Ford: the melee stays ESCORT_AHEAD_M ahead of the villager along its
##     route (or goes out to meet an enemy that can reach it), the ranged and the
##     Wardens BESIDE_M to its sides;
##   - Old Mill: the Sappers lay all their charges down the two ramps first,
##     then everyone holds the plateau, the melee split between the two ramp
##     heads and the ranged behind each of them, attack-moving only at an enemy
##     on the plateau or at a ramp's head; and when the fight has been quiet for
##     STALL_TICKS with an enemy in sight (a Drifter standing off below a
##     cliff), the melee goes out and finishes it (stall_breaks counts these:
##     the pilot's own addition, which the naive pilot has not got).
##
## A pilot with no mission (a skirmish, where there is no plan to know) is told
## its route with set_route: the competent pilot then plays the generic march
## (the melee at the route point, the rest behind it, the specials), never The
## Ford's escort or Old Mill's ramps, and the naive pilot plays as it always
## does. At the end of the route it either hunts the nearest enemy in sight,
## wherever it is, or holds the last point (hold_at_end), fighting only what
## comes within CLEAR_M. The pilot always plays Light.
##
## Thinking is in floats (meters), as this is a script outside sim/; every
## command it emits is in integer milli-units. A pilot is deterministic: its
## decisions are a function of the world it is shown.

enum Kind { COMPETENT, NAIVE }

## Ticks between one think and the next: a player's order rate, once a second.
const THINK_TICKS: int = World.TICK_RATE
## Meters. The melee has arrived at a route point within this.
const ARRIVED_M: float = 10.0
## Meters. A visible enemy this close to the melee is fought before the route
## goes on.
const CLEAR_M: float = 25.0
## Meters. The ranged and the support stand this far behind the melee's centroid.
const FOLLOW_BEHIND_M: float = 8.0
## How many enemies make a cluster worth a grenade or a fire arrow, and how
## close (meters) to the aim point they must stand.
const CLUSTER_MIN: int = 3
const CLUSTER_RADIUS_M: float = 4.0
## Meters. A grenade is not thrown with a friend this near the aim point.
const GRENADE_CLEAR_M: float = 6.0
## Meters. Nor a fire arrow shot, which starts a fire that spreads, nor one
## shot this near a charge lying on the ground (the fire would set it off).
const FIRE_CLEAR_M: float = 8.0
const FIRE_CHARGE_CLEAR_M: float = 15.0
## Meters either side of the line of a fire arrow's flight that no friend may stand.
const LINE_CLEAR_M: float = 1.5
## A Warden heals a friend below this per cent of his hit points, within this
## many meters of the Warden.
const HEAL_BELOW_PERCENT: int = 60
const HEAL_REACH_M: float = 15.0
## Naive pilot, The Ford: everyone is walked back to the villager when the
## nearest soldier is this far (meters) from him.
const LOST_VILLAGER_M: float = 25.0
## Meters between the groups that stand side by side (the ranged and the
## Wardens behind the melee; on The Ford, to either side of the villager).
const BESIDE_M: float = 3.0
## The Ford: meters the melee keeps ahead of the villager, and how close the
## villager must be to a waypoint of its route for the pilot to look to the next.
const ESCORT_AHEAD_M: float = 8.0
const ESCORT_WAYPOINT_M: float = 5.0
## The Ford: an enemy within this many meters of the villager that the melee
## can reach is gone out to meet, but never farther than ESCORT_LEASH_M from it.
const ESCORT_THREAT_M: float = 25.0
const ESCORT_LEASH_M: float = 20.0
## Meters a goal must move before a group is ordered to it again: orders given
## every second would reset every archer's draw.
const REORDER_M: float = 4.0
## Ticks before the soldiers that stand idle far from their goal (an order that
## ran out, an errand that ended) are sent to it again.
const STRAY_TICKS: int = 5 * World.TICK_RATE
## Meters from its goal an idle soldier is let stand: a formation's width.
const STRAY_M: float = 10.0
## A group with this share of its soldiers locked in a fight isn't re-ordered
## (a new order drops the fight), for at most MAX_SKIPS thinks in a row.
const ENGAGED_SHARE: float = 0.25
const MAX_SKIPS: int = 8
## Old Mill: charges a Sapper lays (all he carries), meters between the first
## and the ramp's top and between the rows, and sideways between a row's two.
const CHARGES_PER_SAPPER: int = 4
const CHARGE_FIRST_M: float = 9.0
const CHARGE_ROW_M: float = 3.0
const CHARGE_SIDE_M: float = 2.0
## Old Mill: how close (meters) a Sapper must be to its spot to lay the charge
## there, and how long (ticks) it may take to get there before it gives the
## spot up (a charge laid anywhere else could be a trap for his own side).
const CHARGE_AT_M: float = 1.2
const CHARGE_PATIENCE: int = 60 * World.TICK_RATE
## Old Mill: how far inside the plateau (meters) a ramp's head is held, and
## how much farther in the ranged stand behind it.
const HEAD_INSET_M: float = 3.0
const HEAD_BEHIND_M: float = 6.0
## Old Mill: an enemy counts as at a ramp's head, and is fought, within this many
## meters of the ramp's top down the ramp (kept well short of the first charges,
## CHARGE_FIRST_M - CHARGE_SIDE_M down, so the melee never walks into the field
## the Sappers laid) and as far back up it, and within RAMP_HALF_WIDTH_M of its
## axis (the ramp is 8 m wide).
const RAMP_HEAD_DEPTH_M: float = 4.0
const RAMP_HALF_WIDTH_M: float = 4.0
## Competent pilot: a fight that has gone quiet this long (ticks with nobody's
## hit points changing and the nearest enemy neither coming nearer nor going
## off, by more than STALL_GAP_M) while an enemy is still in sight is walked out
## to and finished: standing off at a cliff's foot is how a Drifter outwaits a
## squad that only holds. The thinks it was needed in are counted in stall_breaks.
const STALL_TICKS: int = 60 * World.TICK_RATE
const STALL_GAP_M: float = 3.0
## How long (ticks) a Longbow keeps aiming its nocked fire arrow at a spot
## before it gives up and shoots as it likes.
const FIRE_PATIENCE: int = 8 * World.TICK_RATE

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
## Milli-units to a meter, as a float: the pilot thinks in meters.
const MM: float = 1000.0

## Which pilot this is.
var kind: Kind
## Commands this pilot has enqueued, in all.
var commands_issued: int = 0
## Keep a copy of every command in `recorded` (the tests read them; a long run
## would otherwise grow without bound).
var record: bool = false
var recorded: Array[SimCommand] = []
## Where the pilot is on its route (an index into PlaytestRoutes.route).
var route_index: int = 0
## The army has reached the route's last point (the naive pilot hunts, or holds,
## from then on; the competent pilot only notes it).
var route_done: bool = false
## Old Mill: the tick the last Sapper laid its last charge, or -1 while some
## charge is still to lay.
var charges_done_tick: int = -1
## Times the competent pilot went out to finish an enemy that wouldn't come to
## it (see STALL_TICKS).
var stall_breaks: int = 0

var _world: World
# Null for a pilot that has no mission (a skirmish): the route comes from set_route.
var _mission: MissionDef
var _route: Array[Vector2] = []
var _sweep_from: int = -1
# At the end of the route: stay on its last point (true) or hunt the nearest
# enemy in sight wherever it is (false). Only a pilot without a mission hunts
# or holds by this; a mission's pilot keeps its own endings.
var _hold_at_end: bool = false

# What this think sees; rebuilt by _scan.
var _mine: Array[Unit] = []
var _melee: Array[Unit] = []
var _archers: Array[Unit] = []
var _sappers: Array[Unit] = []
var _wardens: Array[Unit] = []
var _foes: Array[Unit] = []
var _friends: Array[Unit] = []
var _wards: Array[Unit] = []

# What it remembers between thinks.
# Where each soldier was last ordered to go.
var _goal_of: Dictionary[int, Vector2] = {}
# The tick each group last got a command, and how many thinks a fight has held
# its re-order back.
var _issued_at: Dictionary[StringName, int] = {}
var _skips: Dictionary[StringName, int] = {}
# Sappers bombarding a spot, and Longbows aiming their fire arrow at one (and
# since when).
var _grenade_aim: Dictionary[int, Vector2] = {}
var _fire_aim: Dictionary[int, Vector2] = {}
var _fire_since: Dictionary[int, int] = {}
# What the pilot sees of how the fight is going: the hit points of everyone alive
# and the distance between the sides at the last think that changed either, the
# tick of it, and whether the pilot is out hunting.
var _last_hp_total: int = -1
var _last_gap: float = INF
var _last_change_tick: int = 0
var _hunting: bool = false
# The direction the melee last marched, for the followers when it stands still.
var _facing: Vector2 = Vector2(0.0, 1.0)
# The Ford: how far along its route the villager is.
var _escort: Array[Vector2] = []
var _escort_index: int = 0
# Old Mill: which ramp (0 or 1) each soldier holds or stands behind, the next charge spot
# each Sapper goes to (an index into its own list), and since when it has been
# going to it.
var _ramp_of: Dictionary[int, int] = {}
var _charge_next: Dictionary[int, int] = {}
var _charge_since: Dictionary[int, int] = {}
var _ramps: Array[Dictionary] = []
var _sapper_rank: Dictionary[int, int] = {}


func _init(pilot_kind: Kind, mission: MissionDef = null) -> void:
	kind = pilot_kind
	_mission = mission
	if mission == null:
		return
	_route = PlaytestRoutes.route(mission)
	_sweep_from = PlaytestRoutes.sweep_from(mission)
	if mission.id == &"the_ford":
		_escort = PlaytestRoutes.escort(mission)
	if mission.id == &"old_mill":
		_ramps = PlaytestRoutes.mill_ramps()


## Where a pilot with no mission goes, `points` in milli-units, in order, and what
## it does at the last: hold it (fight only what comes within CLEAR_M of the
## army) or hunt the nearest enemy in sight. Starts the route over, so it may be
## given again. Refused for a pilot with a mission, whose route is its mission's.
func set_route(points: Array[Vector2i], hold_at_end: bool) -> void:
	if _mission != null:
		push_error("PlaytestPilot.set_route: a pilot with a mission keeps the mission's route")
		return
	_route.clear()
	for point: Vector2i in points:
		_route.append(Vector2(point) / MM)
	_hold_at_end = hold_at_end
	route_index = 0
	route_done = false


## The label a run is printed with.
static func kind_name(pilot_kind: Kind) -> String:
	return "competent" if pilot_kind == Kind.COMPETENT else "naive"


## The pilot of this name ("competent" or "naive"), or -1.
static func kind_from_name(text: String) -> int:
	match text:
		"competent":
			return Kind.COMPETENT
		"naive":
			return Kind.NAIVE
	return -1


## One think: look at the world, enqueue what the player would. Call it between
## steps, when world.tick is the next tick to simulate; commands apply at the
## start of that tick.
func think(world: World) -> void:
	_world = world
	_scan()
	if _mine.is_empty():
		return
	if _route.is_empty():
		# No route was set: the army holds where it stands.
		_route.append(_centroid(_mine))
		_hold_at_end = true
	if kind == Kind.NAIVE:
		_think_naive()
		return
	if _mission == null:
		_think_march()
		return
	match _mission.id:
		&"the_ford":
			_think_ford()
		&"old_mill":
			_think_mill()
		_:
			_think_march()


# ---- looking ----

func _scan() -> void:
	_mine.clear()
	_melee.clear()
	_archers.clear()
	_sappers.clear()
	_wardens.clear()
	_foes.clear()
	_friends.clear()
	_wards.clear()
	for unit: Unit in _world.units:
		if not unit.is_alive():
			continue
		if unit.faction == LIGHT:
			_friends.append(unit)
			if _world.ai.controls(unit.id):
				_wards.append(unit)
				continue
			_mine.append(unit)
			match unit.type.special_ability:
				UnitType.Special.SATCHEL:
					_sappers.append(unit)
				UnitType.Special.HEAL:
					_wardens.append(unit)
				_:
					if unit.type.has_ranged():
						_archers.append(unit)
					else:
						_melee.append(unit)
		elif Visibility.seen_by(_world, unit, LIGHT):
			_foes.append(unit)
	# How the fight is going is judged from what the pilot can see: his own and the
	# enemies in sight (not a Husk lying submerged, whose hit points a player
	# can't watch).
	var hp_total: int = 0
	for unit: Unit in _mine:
		hp_total += unit.hp
	for unit: Unit in _foes:
		hp_total += unit.hp
	var gap: float = _gap_between_the_sides()
	if hp_total != _last_hp_total or absf(gap - _last_gap) > STALL_GAP_M or not gap < INF:
		_last_hp_total = hp_total
		_last_gap = gap
		_last_change_tick = _world.tick


# Meters between the nearest soldier and the nearest visible enemy, or INF with
# no enemy in sight.
func _gap_between_the_sides() -> float:
	var gap: float = INF
	for foe: Unit in _foes:
		for unit: Unit in _mine:
			gap = minf(gap, _pos(foe).distance_to(_pos(unit)))
	return gap


# ---- the naive pilot ----

func _think_naive() -> void:
	var here: Vector2 = _centroid(_mine)
	var goal: Vector2 = _route[route_index]
	if not _wards.is_empty() and _gap_to_soldiers(_wards[0]) >= LOST_VILLAGER_M:
		# The hint says he walks only while soldiers are near: back to him.
		goal = _pos(_wards[0])
	else:
		if not route_done and here.distance_to(goal) <= ARRIVED_M:
			if route_index < _route.size() - 1:
				route_index += 1
				goal = _route[route_index]
			else:
				route_done = true
		if route_done and _hold_at_end and _mission == null:
			# Held: the last point, or what has come within reach of the army.
			goal = _route[_route.size() - 1]
			var near: Array[Unit] = _foes_within(here, CLEAR_M)
			if not near.is_empty():
				goal = _pos(_nearest(near, here))
		elif route_done:
			if _foes.is_empty():
				return
			goal = _pos(_nearest(_foes, here))
	_order_group(&"all", _mine, goal, true)


# Meters from `unit` to the nearest of the soldiers.
func _gap_to_soldiers(unit: Unit) -> float:
	var gap: float = INF
	for soldier: Unit in _mine:
		gap = minf(gap, _pos(soldier).distance_to(_pos(unit)))
	return gap


# ---- the competent pilot: the march (Riverside, and any mission without a plan) ----

func _think_march() -> void:
	var lead: Array[Unit] = _lead()
	var here: Vector2 = _centroid(lead)
	var near: Array[Unit] = _foes_within(here, CLEAR_M)
	if near.is_empty() and here.distance_to(_route[route_index]) <= ARRIVED_M:
		_advance_route()
	var goal: Vector2 = _route[route_index]
	if not near.is_empty():
		goal = _pos(_nearest(near, here))
	elif route_done and _mission == null and not _hold_at_end and not _foes.is_empty():
		# A pilot with no mission, at the end of its route, hunts what it can see.
		goal = _pos(_nearest(_foes, here))
	_order_group(&"melee", lead, goal, true)
	_follow(lead, here, goal)
	_use_specials()


# The soldiers who lead: the melee, or whoever is left if there is none.
func _lead() -> Array[Unit]:
	return _melee if not _melee.is_empty() else _mine


# Goes on to the next route point; past the last, round the sweep if there is
# one, else stays on it.
func _advance_route() -> void:
	if route_index < _route.size() - 1:
		route_index += 1
	elif _sweep_from >= 0:
		route_index = _sweep_from
	else:
		route_done = true


# The ranged, the Wardens and the Sappers (those not on a task of their own)
# fall in FOLLOW_BEHIND_M behind the lead, side by side.
func _follow(lead: Array[Unit], here: Vector2, goal: Vector2) -> void:
	var heading: Vector2 = goal - here
	if heading.length() > 1.0:
		_facing = heading.normalized()
	var rear: Vector2 = here - _facing * FOLLOW_BEHIND_M
	var side: Vector2 = Vector2(-_facing.y, _facing.x)
	_order_group(&"archers", _free(_archers, lead, _fire_aim), rear + side * BESIDE_M, true)
	_order_group(&"wardens", _free(_wardens, lead), rear - side * BESIDE_M, true)
	_order_group(&"sappers", _free(_sappers, lead, _grenade_aim), rear - _facing * BESIDE_M, true)


# The units of `group` that aren't in `lead` and aren't on a task (a key of any
# of the `busy` dictionaries).
func _free(
	group: Array[Unit], lead: Array[Unit], busy: Dictionary[int, Vector2] = {}
) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in group:
		if not lead.has(unit) and not busy.has(unit.id):
			out.append(unit)
	return out


# ---- the competent pilot: The Ford ----

func _think_ford() -> void:
	if _wards.is_empty() or _escort.is_empty():
		_think_march()
		return
	var villager: Unit = _wards[0]
	var at: Vector2 = _pos(villager)
	while _escort_index < _escort.size() - 1 and at.distance_to(_escort[_escort_index]) < ESCORT_WAYPOINT_M:
		_escort_index += 1
	var ahead: Vector2 = _escort[_escort_index] - at
	if ahead.length() > 1.0:
		_facing = ahead.normalized()
	var lead: Array[Unit] = _lead()
	var goal: Vector2 = at + _facing * ESCORT_AHEAD_M
	# An enemy that can reach the villager is met on the way to it, but the melee
	# doesn't leave it far behind.
	var threat: Unit = _nearest(_reachable_foes_within(at, ESCORT_THREAT_M), at)
	if threat != null:
		goal = _pos(threat)
		if goal.distance_to(at) > ESCORT_LEASH_M:
			goal = at + (goal - at).normalized() * ESCORT_LEASH_M
	_order_group(&"melee", lead, goal, true)
	var side: Vector2 = Vector2(-_facing.y, _facing.x)
	_order_group(&"archers", _free(_archers, lead, _fire_aim), at + side * BESIDE_M, true)
	_order_group(&"wardens", _free(_wardens, lead), at - side * BESIDE_M, true)
	_order_group(&"sappers", _free(_sappers, lead, _grenade_aim), at - _facing * BESIDE_M * 2.0, true)
	_use_specials()


# Enemies within `radius` meters of `at` that soldiers on foot can walk to: not
# a Drifter hovering over deep water.
func _reachable_foes_within(at: Vector2, radius: float) -> Array[Unit]:
	var out: Array[Unit] = []
	for foe: Unit in _foes_within(at, radius):
		if _world.terrain.is_passable(foe.x, foe.z, Terrain.Mobility.LIVING):
			out.append(foe)
	return out


# ---- the competent pilot: Old Mill ----

func _think_mill() -> void:
	var center: Vector2 = PlaytestRoutes.mill_center()
	_assign_ramps()
	_lay_charges()
	var invaders: Array[Unit] = _invaders(center)
	_update_hunt(center)
	var sappers: Array[Unit] = []
	for unit: Unit in _free(_sappers, _melee, _grenade_aim):
		if not _has_charges_to_lay(unit):
			sappers.append(unit)
	for ramp: int in 2:
		var head: Vector2 = _ramp_head(ramp, center)
		var group: Array[Unit] = _held_at(_melee, ramp)
		var goal: Vector2 = head
		var targets: Array[Unit] = _reachable_foes_within(center, INF) if _hunting else invaders
		if not targets.is_empty() and not group.is_empty():
			goal = _pos(_nearest(targets, _centroid(group)))
		_order_group(StringName("melee_%d" % ramp), group, goal, true)
		# Behind each head, a little way in: the ranged and the Wardens, and the
		# Sappers who have laid their charges, close enough to cover it.
		var inward: Vector2 = (center - head).normalized()
		var behind: Vector2 = head + inward * HEAD_BEHIND_M
		var side: Vector2 = Vector2(-inward.y, inward.x)
		var archers: Array[Unit] = _held_at(_free(_archers, _melee, _fire_aim), ramp)
		_order_group(StringName("archers_%d" % ramp), archers, behind + side * BESIDE_M, true)
		var wardens: Array[Unit] = _held_at(_free(_wardens, _melee), ramp)
		_order_group(StringName("wardens_%d" % ramp), wardens, behind - side * BESIDE_M, true)
		_order_group(StringName("sappers_%d" % ramp), _held_at(sappers, ramp), behind, true)
	_use_specials()


# Goes out hunting once the fight has been quiet for STALL_TICKS with an enemy
# in sight, and comes back when nothing in sight can be walked to.
func _update_hunt(center: Vector2) -> void:
	var reachable: Array[Unit] = _reachable_foes_within(center, INF)
	if _hunting:
		_hunting = not reachable.is_empty()
	elif not reachable.is_empty() and _world.tick - _last_change_tick >= STALL_TICKS:
		_hunting = true
		stall_breaks += 1


# The soldiers of `group` posted to ramp `ramp`.
func _held_at(group: Array[Unit], ramp: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in group:
		if _ramp_of.get(unit.id, 0) == ramp:
			out.append(unit)
	return out


# Splits every role between the two ramps, alternating down the roster, and
# keeps each soldier at his ramp for good.
func _assign_ramps() -> void:
	for group: Array[Unit] in [_melee, _archers, _wardens, _sappers]:
		for i: int in group.size():
			if not _ramp_of.has(group[i].id):
				_ramp_of[group[i].id] = i % 2


# Where ramp `ramp`'s defenders stand: just inside the plateau's edge.
func _ramp_head(ramp: int, center: Vector2) -> Vector2:
	var top: Vector2 = _ramps[ramp]["top"]
	return top + (center - top).normalized() * HEAD_INSET_M


# Visible enemies on the plateau or at the head of a ramp (RAMP_HEAD_DEPTH_M
# down it: not as far as the charges, which are the Sappers' to set off; a
# soldier who follows an enemy into the field he laid walks into his own blast).
func _invaders(center: Vector2) -> Array[Unit]:
	var out: Array[Unit] = []
	var radius: float = PlaytestRoutes.mill_plateau_radius()
	for foe: Unit in _foes:
		var p: Vector2 = _pos(foe)
		var at_a_head: bool = false
		for ramp: Dictionary in _ramps:
			var top: Vector2 = ramp["top"]
			var down: Vector2 = (Vector2(ramp["foot"]) - top).normalized()
			var along: float = (p - top).dot(down)
			var across: float = absf((p - top).dot(Vector2(-down.y, down.x)))
			at_a_head = at_a_head or (
				along <= RAMP_HEAD_DEPTH_M and along >= -RAMP_HEAD_DEPTH_M and across <= RAMP_HALF_WIDTH_M
			)
		if at_a_head or p.distance_to(center) <= radius:
			out.append(foe)
	return out


# Every Sapper walks down its ramp laying its charges: the nearest spots to the
# top first, a pair to a row, the first Sapper to the north-west ramp, the next
# to the south-east, the third behind the first. A Sapper who has laid all of
# his (or hasn't any) is left to the rear group.
func _lay_charges() -> void:
	for i: int in _sappers.size():
		if not _sapper_rank.has(_sappers[i].id):
			_sapper_rank[_sappers[i].id] = i
	var pending: bool = false
	for sapper: Unit in _sappers:
		if not _has_charges_to_lay(sapper):
			continue
		pending = true
		var spots: Array[Vector2] = _charge_spots(_sapper_rank[sapper.id])
		var next: int = _charge_next.get(sapper.id, 0)
		if not _charge_since.has(sapper.id):
			_charge_since[sapper.id] = _world.tick
		var spot: Vector2 = spots[next]
		var waited: int = _world.tick - _charge_since[sapper.id]
		if _pos(sapper).distance_to(spot) <= CHARGE_AT_M:
			# The charge goes down where he stands (this tick's first command),
			# then he walks on to the next spot.
			_send(UseSpecialCommand.new(_world.tick, PackedInt32Array([sapper.id])))
			_charge_next[sapper.id] = next + 1
			_charge_since[sapper.id] = _world.tick
			if next + 1 < spots.size() and sapper.special_left > 1:
				_walk(sapper, spots[next + 1])
		elif waited >= CHARGE_PATIENCE:
			# He can't get there: the spot is given up, and the next tried.
			_charge_next[sapper.id] = next + 1
			_charge_since[sapper.id] = _world.tick
		elif not _goal_of.has(sapper.id) or _goal_of[sapper.id].distance_to(spot) > 0.5:
			_walk(sapper, spot)
	if not pending and charges_done_tick < 0 and not _sappers.is_empty():
		charges_done_tick = _world.tick


# True while a Sapper has charges left to lay (Old Mill's one job for him
# besides grenades; he lays them first) and spots left to lay them at.
func _has_charges_to_lay(sapper: Unit) -> bool:
	return (
		_mission != null and _mission.id == &"old_mill" and sapper.special_left > 0
		and _charge_next.get(sapper.id, 0) < CHARGES_PER_SAPPER
	)


# The spots Sapper number `rank` lays his charges at: his ramp's (rank mod 2),
# a share of CHARGES_PER_SAPPER in the ramp's list, which runs from the top
# toward the foot, a pair to a row.
func _charge_spots(rank: int) -> Array[Vector2]:
	var ramp: Dictionary = _ramps[rank % 2]
	var top: Vector2 = ramp["top"]
	var down: Vector2 = (Vector2(ramp["foot"]) - top).normalized()
	var side: Vector2 = Vector2(-down.y, down.x)
	var out: Array[Vector2] = []
	var share: int = rank >> 1
	for k: int in CHARGES_PER_SAPPER:
		var n: int = share * CHARGES_PER_SAPPER + k
		var along: float = CHARGE_FIRST_M + CHARGE_ROW_M * (n >> 1)
		var across: float = -CHARGE_SIDE_M if n % 2 == 0 else CHARGE_SIDE_M
		out.append(top + down * along + side * across)
	return out


# One soldier walks (not attack-moves: it has a job) to a point.
func _walk(unit: Unit, to: Vector2) -> void:
	var at: Vector2i = _clamp(to)
	_send(MoveUnitsCommand.new(_world.tick, PackedInt32Array([unit.id]), at.x, at.y, Formations.Kind.SHORT_LINE))
	_goal_of[unit.id] = Vector2(at) / MM


# ---- specials, shared by every competent think ----

func _use_specials() -> void:
	_throw_grenades()
	_shoot_fire_arrows()
	_heal()


# Each Sapper bombards the best visible cluster in its range, and lets go of
# the spot when there isn't one any more (the follow order that comes next
# sees to the rest).
func _throw_grenades() -> void:
	for sapper: Unit in _sappers:
		if _has_charges_to_lay(sapper):
			continue
		var aim: Vector2 = _grenade_target(sapper)
		if aim.is_finite():
			# Already bombarding this spot (near enough) is left alone, and so is a
			# throw being drawn: a new order would spoil it.
			var held: Vector2 = _grenade_aim.get(sapper.id, Vector2.INF)
			var bombarding: bool = sapper.order == Unit.Order.GROUND_ATTACK and held.is_finite()
			var new_spot: bool = not bombarding or held.distance_to(aim) > REORDER_M / 2.0
			if new_spot and not (bombarding and sapper.aim_left > 0):
				var at: Vector2i = _clamp(aim)
				_send(GroundAttackCommand.new(_world.tick, PackedInt32Array([sapper.id]), at.x, at.y))
				_grenade_aim[sapper.id] = Vector2(at) / MM
		else:
			_grenade_aim.erase(sapper.id)


# Where `sapper` would throw: the densest cluster of CLUSTER_MIN or more visible
# enemies it can reach with no friend near the spot, or Vector2.INF.
func _grenade_target(sapper: Unit) -> Vector2:
	var from: Vector2 = _pos(sapper)
	var low: float = sapper.type.ranged_min_range / MM + 1.0
	var high: float = sapper.type.ranged_max_range / MM - 2.0
	var best: Vector2 = Vector2.INF
	var best_count: int = 0
	var best_distance: float = 0.0
	for foe: Unit in _foes:
		var cluster: Array[Unit] = _foes_within(_pos(foe), CLUSTER_RADIUS_M)
		if cluster.size() < CLUSTER_MIN:
			continue
		var aim: Vector2 = _centroid(cluster)
		var distance: float = from.distance_to(aim)
		if distance < low or distance > high:
			continue
		var at: Vector2i = _clamp(aim)
		if _world.terrain.water_depth_at(at.x, at.y) > 0 or _friend_within(aim, GRENADE_CLEAR_M):
			continue
		if cluster.size() > best_count or (cluster.size() == best_count and distance < best_distance):
			best = aim
			best_count = cluster.size()
			best_distance = distance
	return best


# Each Longbow with its fire arrow still to shoot nocks it and aims it at a
# cluster standing on brush or wood; one that has shot it, or has tried for too
# long, goes back to the squad.
func _shoot_fire_arrows() -> void:
	for archer: Unit in _archers:
		if archer.type.special_ability != UnitType.Special.FIRE_ARROW:
			continue
		if _fire_aim.has(archer.id):
			var spent: bool = not archer.fire_nocked and archer.special_left == 0
			if spent or _world.tick - _fire_since[archer.id] >= FIRE_PATIENCE:
				_fire_aim.erase(archer.id)
			continue
		if archer.special_left <= 0:
			continue
		var aim: Vector2 = _fire_target(archer)
		if not aim.is_finite():
			continue
		var at: Vector2i = _clamp(aim)
		var ids: PackedInt32Array = PackedInt32Array([archer.id])
		_send(UseSpecialCommand.new(_world.tick, ids))
		_send(GroundAttackCommand.new(_world.tick, ids, at.x, at.y))
		_fire_aim[archer.id] = Vector2(at) / MM
		_fire_since[archer.id] = _world.tick


# Where `archer` would loose its fire arrow: a cluster of CLUSTER_MIN or more
# enemies in reach, standing on ground that burns, with no friend near the spot
# or in the way and no charge lying near it; or Vector2.INF.
func _fire_target(archer: Unit) -> Vector2:
	var from: Vector2 = _pos(archer)
	var low: float = archer.type.ranged_min_range / MM + 1.0
	var high: float = archer.type.ranged_max_range / MM - 4.0
	var best: Vector2 = Vector2.INF
	var best_count: int = 0
	var best_distance: float = 0.0
	for foe: Unit in _foes:
		var burning: Array[Unit] = []
		for other: Unit in _foes_within(_pos(foe), CLUSTER_RADIUS_M):
			var ground: int = _world.terrain.ground_at(other.x, other.z)
			if ground == Terrain.Ground.BRUSH or ground == Terrain.Ground.WOOD:
				burning.append(other)
		if burning.size() < CLUSTER_MIN:
			continue
		var aim: Vector2 = _centroid(burning)
		var distance: float = from.distance_to(aim)
		if distance < low or distance > high or _friend_within(aim, FIRE_CLEAR_M) or _charge_within(aim, FIRE_CHARGE_CLEAR_M):
			continue
		if _friend_in_the_way(archer, from, aim):
			continue
		if burning.size() > best_count or (burning.size() == best_count and distance < best_distance):
			best = aim
			best_count = burning.size()
			best_distance = distance
	return best


# Each Warden with a herb sends itself to the most hurt friend, below
# HEAL_BELOW_PERCENT, within HEAL_REACH_M (the villager counts), and no two go
# to the same one.
func _heal() -> void:
	var taken: Dictionary[int, bool] = {}
	# Whoever a Warden is already on his way to is taken, or two would go to him
	# one think apart.
	for warden: Unit in _wardens:
		if warden.order == Unit.Order.INTERACT:
			taken[warden.interact_id] = true
	for warden: Unit in _wardens:
		if warden.special_left <= 0 or warden.order == Unit.Order.INTERACT:
			continue
		var patient: Unit = null
		var worst: float = HEAL_BELOW_PERCENT
		for friend: Unit in _friends:
			var percent: float = 100.0 * friend.hp / friend.type.max_hp
			if friend == warden or taken.has(friend.id) or percent >= worst:
				continue
			if _pos(friend).distance_to(_pos(warden)) <= HEAL_REACH_M:
				patient = friend
				worst = percent
		if patient != null:
			taken[patient.id] = true
			_send(HealCommand.new(_world.tick, PackedInt32Array([warden.id]), patient.id))


# ---- ordering a group ----

# Attack-moves (or moves) `units` to `goal` (meters) in a short line, but only
# when that is news: the group has never been sent, its goal has moved
# REORDER_M, or someone has stood idle for STRAY_TICKS far from it (an errand
# ended; a bombardment was called off), who then goes alone. A group in a fight
# is left alone for a few thinks (_fighting). Soldiers on an errand are not
# touched.
func _order_group(key: StringName, units: Array[Unit], goal: Vector2, attack: bool) -> void:
	var group: Array[Unit] = []
	for unit: Unit in units:
		if unit.order != Unit.Order.INTERACT:
			group.append(unit)
	if group.is_empty():
		return
	var at: Vector2i = _clamp(goal)
	var target: Vector2 = Vector2(at) / MM
	var moved: bool = false
	var strays: Array[Unit] = []
	for unit: Unit in group:
		var last: Vector2 = _goal_of.get(unit.id, Vector2.INF)
		if not last.is_finite() or last.distance_to(target) >= REORDER_M:
			moved = true
		elif _is_stray(unit, target):
			strays.append(unit)
	if not moved and (strays.is_empty() or _world.tick - _issued_at.get(key, -STRAY_TICKS) < STRAY_TICKS):
		return
	if _fighting(group) and _skips.get(key, 0) < MAX_SKIPS:
		_skips[key] = _skips.get(key, 0) + 1
		return
	var sent: Array[Unit] = group if moved else strays
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in sent:
		ids.append(unit.id)
		_goal_of[unit.id] = target
	if attack:
		_send(AttackMoveCommand.new(_world.tick, ids, at.x, at.y, Formations.Kind.SHORT_LINE))
	else:
		_send(MoveUnitsCommand.new(_world.tick, ids, at.x, at.y, Formations.Kind.SHORT_LINE))
	_issued_at[key] = _world.tick
	_skips[key] = 0


# Idle far from where it was sent, or still bombarding after being let go.
func _is_stray(unit: Unit, target: Vector2) -> bool:
	if unit.order == Unit.Order.GROUND_ATTACK:
		return true
	return unit.order == Unit.Order.NONE and _pos(unit).distance_to(target) > STRAY_M


# True if a quarter of the group is in a fight right now.
func _fighting(group: Array[Unit]) -> bool:
	var engaged: int = 0
	for unit: Unit in group:
		if unit.target_id != 0 or unit.state == Unit.State.ATTACKING:
			engaged += 1
	return float(engaged) >= ENGAGED_SHARE * group.size()


# ---- small helpers ----

func _send(command: SimCommand) -> void:
	if not _world.enqueue(command):
		push_error("PlaytestPilot: tick %d is already past for %s" % [command.tick, command.get_script().resource_path])
		return
	commands_issued += 1
	if record:
		recorded.append(command)


# Meters.
func _pos(unit: Unit) -> Vector2:
	return Vector2(unit.x, unit.z) / MM


# A point in meters as milli-units on the map.
func _clamp(point: Vector2) -> Vector2i:
	var terrain: Terrain = _world.terrain
	return Vector2i(
		clampi(roundi(point.x * MM), 0, terrain.extent_x()), clampi(roundi(point.y * MM), 0, terrain.extent_z())
	)


func _centroid(units: Array[Unit]) -> Vector2:
	if units.is_empty():
		return Vector2.ZERO
	var sum: Vector2 = Vector2.ZERO
	for unit: Unit in units:
		sum += _pos(unit)
	return sum / units.size()


# The visible enemies within `radius` meters of `at`.
func _foes_within(at: Vector2, radius: float) -> Array[Unit]:
	var out: Array[Unit] = []
	for foe: Unit in _foes:
		if _pos(foe).distance_to(at) <= radius:
			out.append(foe)
	return out


# The unit nearest `at` (ties to the lower id, which the list's order gives), or
# null for none.
func _nearest(units: Array[Unit], at: Vector2) -> Unit:
	var best: Unit = null
	var best_distance: float = 0.0
	for unit: Unit in units:
		var distance: float = _pos(unit).distance_to(at)
		if best == null or distance < best_distance:
			best = unit
			best_distance = distance
	return best


# True if a friend (not the shooter) stands on the line from `from` to `to`: a
# ground attack doesn't care about bodies in the way, and a fire arrow into a
# friend sets him, and the ground he stands on, alight.
func _friend_in_the_way(shooter: Unit, from: Vector2, to: Vector2) -> bool:
	for friend: Unit in _friends:
		if friend == shooter:
			continue
		var p: Vector2 = _pos(friend)
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, from, to)) <= LINE_CLEAR_M:
			return true
	return false


# True if a charge or an unexploded grenade lies within `radius` meters.
func _charge_within(at: Vector2, radius: float) -> bool:
	for p: Projectile in _world.projectiles:
		if p.removed or p.motion != Projectile.Motion.RESTING or not p.type.chain_detonates:
			continue
		if Vector2(p.x, p.z).distance_to(at * MM) <= radius * MM:
			return true
	return false


# True if any living Light unit (the villager too) is within `radius` meters.
func _friend_within(at: Vector2, radius: float) -> bool:
	for friend: Unit in _friends:
		if _pos(friend).distance_to(at) <= radius:
			return true
	return false
