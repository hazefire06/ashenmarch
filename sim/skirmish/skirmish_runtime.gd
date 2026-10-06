class_name SkirmishRuntime
extends RefCounted
## A skirmish in progress: the score, the hill, the flags, the clock, and who
## won. SkirmishRules is the read-only data; this is the state it drives, so it
## lives in the world and is hashed. update() runs once a tick inside
## World.step(), right after the mission's triggers and before the AI, so the
## commanders see this tick's score; like the triggers, it reads the state the
## previous tick left.
##
## Each update, in order:
## 1. the first time, record each side's army (roster_ids): every unit alive
##    then, the deploy and the AI's starting groups both;
## 2. count each side's dead (deaths) and living (alive);
## 3. a side with none left loses at once, any mode (ELIMINATION); both at
##    once is a draw;
## 4. at the time limit, the score decides (TIME);
## 5. otherwise score this tick: who holds the hill, who stands at each flag.
## Once decided it freezes: nothing changes again, and the score and
## final_alive are what the results screen shows, even though the rest of the
## tick may still kill.
##
## Presence at a flag counts living units within flag_radius, center to
## center, that aren't submerged: a Husk lurking in deep water holds nothing.
## No random numbers.

## No side: the hill or a flag nobody holds, or no winner yet.
const NO_SIDE: int = -1
## The hill with both sides on it.
const CONTESTED: int = -2
## The two sides, LIGHT and DARK, by faction.
const SIDES: int = 2
## `winner` when neither side won: past every faction.
const DRAW: int = SIDES

## Why the skirmish ended. Append only: hashed.
enum EndReason {
	## Still being played.
	NONE,
	## The time limit; the score decided.
	TIME,
	## A side was wiped out.
	ELIMINATION,
}

var rules: SkirmishRules
## The tick the skirmish started on; the clock counts from it.
var start_tick: int
## True once the armies have been recorded (the first update).
var started: bool = false
## Each side's units, alive or dead, by id ascending, indexed by faction.
var roster_ids: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
## Each side's units dead, gone, or no longer on its side. A side's Body Count
## score is the other side's deaths.
var deaths: PackedInt32Array = PackedInt32Array([0, 0])
## Each side's units still alive and on its side.
var alive: PackedInt32Array = PackedInt32Array([0, 0])
## Who held the hill on the last scored tick: a faction, NO_SIDE, or CONTESTED.
var hill_holder: int = NO_SIDE
## Ticks each side has held the hill alone.
var hold_ticks: PackedInt64Array = PackedInt64Array([0, 0])
## Per flag: the faction that owns it, or NO_SIDE.
var flag_owner: PackedInt32Array = PackedInt32Array()
## Per flag: the faction standing alone at it and capturing it, or NO_SIDE.
var flag_capture_side: PackedInt32Array = PackedInt32Array()
## Per flag: ticks capture_side has stood there alone (0 once owned).
var flag_progress: PackedInt32Array = PackedInt32Array()
## Flag-ticks each side has owned, summed over the flags: Capture the Flags'
## tie-break.
var owned_ticks: PackedInt64Array = PackedInt64Array([0, 0])
## The winning faction, DRAW, or NO_SIDE while it is still being played.
var winner: int = NO_SIDE
var end_reason: EndReason = EndReason.NONE
## The tick it was decided on, or -1.
var end_tick: int = -1
## Per side, parallel to roster_ids: 1 if that unit was alive and on its side
## when the skirmish was decided. Empty until then.
var final_alive: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]


func _init(skirmish_rules: SkirmishRules, at_tick: int) -> void:
	rules = skirmish_rules
	start_tick = at_tick
	var n: int = rules.flag_count()
	flag_owner.resize(n)
	flag_owner.fill(NO_SIDE)
	flag_capture_side.resize(n)
	flag_capture_side.fill(NO_SIDE)
	flag_progress.resize(n)


## One tick of the skirmish. Does nothing once it has a winner.
func update(world: World) -> void:
	if winner != NO_SIDE:
		return
	if not started:
		for unit: Unit in world.units:
			if unit.is_alive() and unit.faction >= 0 and unit.faction < SIDES:
				roster_ids[unit.faction].append(unit.id)
		started = true
	_count(world)
	var wiped: Array[bool] = [false, false]
	for side: int in SIDES:
		wiped[side] = not roster_ids[side].is_empty() and alive[side] == 0
	if wiped[0] and wiped[1]:
		_decide(world, DRAW, EndReason.ELIMINATION)
		return
	for side: int in SIDES:
		if wiped[side]:
			_decide(world, 1 - side, EndReason.ELIMINATION)
			return
	if world.tick - start_tick >= rules.time_limit_ticks:
		_decide(world, _leader(), EndReason.TIME)
		return
	_score_tick(world)


## Ticks left on the clock (0 once it has run out).
func ticks_left(world_tick: int) -> int:
	if winner != NO_SIDE:
		return maxi(0, rules.time_limit_ticks - (end_tick - start_tick))
	return maxi(0, rules.time_limit_ticks - (world_tick - start_tick))


## A side's score in the mode being played: enemy deaths (Body Count), ticks
## holding the hill (King of the Hill), or flags owned (Capture the Flags).
func score(side: int) -> int:
	match rules.mode:
		SkirmishRules.Mode.BODY_COUNT:
			return deaths[1 - side]
		SkirmishRules.Mode.KING_OF_THE_HILL:
			return hold_ticks[side]
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			return flags_owned(side)
	return 0


## How many flags a side owns.
func flags_owned(side: int) -> int:
	var n: int = 0
	for owner: int in flag_owner:
		if owner == side:
			n += 1
	return n


## True if the skirmish is over.
func is_decided() -> bool:
	return winner != NO_SIDE


## Everything the skirmish keeps, for state_hash(): the rules, then the state,
## each array after its size.
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = rules.hash_fields()
	fields.append_array(PackedInt64Array([
		start_tick, int(started), hill_holder, winner, end_reason, end_tick,
		deaths[0], deaths[1], alive[0], alive[1], hold_ticks[0], hold_ticks[1],
		owned_ticks[0], owned_ticks[1],
	]))
	for side: int in SIDES:
		fields.append(roster_ids[side].size())
		for unit_id: int in roster_ids[side]:
			fields.append(unit_id)
		fields.append(final_alive[side].size())
		for flag: int in final_alive[side]:
			fields.append(flag)
	fields.append(flag_owner.size())
	for i: int in flag_owner.size():
		fields.append(flag_owner[i])
		fields.append(flag_capture_side[i])
		fields.append(flag_progress[i])
	return fields


# The side ahead on score at the limit, or DRAW. Capture the Flags breaks a
# tie on flags owned by flag-ticks owned.
func _leader() -> int:
	var a: int = score(0)
	var b: int = score(1)
	if a == b and rules.mode == SkirmishRules.Mode.CAPTURE_THE_FLAGS:
		a = owned_ticks[0]
		b = owned_ticks[1]
	if a > b:
		return 0
	if b > a:
		return 1
	return DRAW


func _count(world: World) -> void:
	for side: int in SIDES:
		var living: int = 0
		for unit_id: int in roster_ids[side]:
			if _still_standing(world, unit_id, side):
				living += 1
		alive[side] = living
		deaths[side] = roster_ids[side].size() - living


func _still_standing(world: World, unit_id: int, side: int) -> bool:
	var unit: Unit = world.get_unit(unit_id)
	return unit != null and unit.is_alive() and unit.faction == side


func _score_tick(world: World) -> void:
	var present: Array[PackedByteArray] = _presence(world)
	if rules.mode == SkirmishRules.Mode.KING_OF_THE_HILL:
		var at_hill: PackedByteArray = present[rules.hill]
		if at_hill[0] != 0 and at_hill[1] != 0:
			hill_holder = CONTESTED
		elif at_hill[0] != 0 or at_hill[1] != 0:
			hill_holder = 0 if at_hill[0] != 0 else 1
			hold_ticks[hill_holder] += 1
		else:
			hill_holder = NO_SIDE
	elif rules.mode == SkirmishRules.Mode.CAPTURE_THE_FLAGS:
		for i: int in flag_owner.size():
			var sole: int = NO_SIDE
			if present[i][0] != 0 and present[i][1] == 0:
				sole = 0
			elif present[i][1] != 0 and present[i][0] == 0:
				sole = 1
			# Progress resets whenever who stands there alone changes, and
			# stays at 0 for the owner itself.
			if sole != flag_capture_side[i] or sole == flag_owner[i]:
				flag_progress[i] = 0
			flag_capture_side[i] = sole if sole != flag_owner[i] else NO_SIDE
			if flag_capture_side[i] != NO_SIDE:
				flag_progress[i] += 1
				if flag_progress[i] >= rules.capture_ticks:
					flag_owner[i] = flag_capture_side[i]
					flag_capture_side[i] = NO_SIDE
					flag_progress[i] = 0
			if flag_owner[i] != NO_SIDE:
				owned_ticks[flag_owner[i]] += 1


# Per flag, per side: 1 if a living unit of that side that isn't submerged
# stands within flag_radius of it.
func _presence(world: World) -> Array[PackedByteArray]:
	var n: int = rules.flag_count()
	var out: Array[PackedByteArray] = []
	for i: int in n:
		var row: PackedByteArray = PackedByteArray()
		row.resize(SIDES)
		out.append(row)
	var r2: int = rules.flag_radius * rules.flag_radius
	for unit: Unit in world.units:
		if not unit.is_alive() or unit.faction < 0 or unit.faction >= SIDES:
			continue
		if Visibility.is_submerged(world.terrain, unit):
			continue
		for i: int in n:
			var dx: int = unit.x - rules.flags[2 * i]
			var dz: int = unit.z - rules.flags[2 * i + 1]
			if dx * dx + dz * dz <= r2:
				out[i][unit.faction] = 1
	return out


func _decide(world: World, side: int, reason: EndReason) -> void:
	winner = side
	end_reason = reason
	end_tick = world.tick
	for s: int in SIDES:
		var snapshot: PackedByteArray = PackedByteArray()
		snapshot.resize(roster_ids[s].size())
		for k: int in roster_ids[s].size():
			snapshot[k] = 1 if _still_standing(world, roster_ids[s][k], s) else 0
		final_alive[s] = snapshot
	var outcome: MissionRuntime.Outcome = MissionRuntime.Outcome.DRAW
	if side == rules.player_faction:
		outcome = MissionRuntime.Outcome.WON
	elif side != DRAW:
		outcome = MissionRuntime.Outcome.LOST
	world.mission.conclude(world, outcome)
