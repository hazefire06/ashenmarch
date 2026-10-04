class_name CampaignState
extends RefCounted
## Everything that carries from one campaign mission to the next: who is alive
## (with his kills and wounds), who has fallen, which mission is next, and the
## seed the missions' dice come from. Pure data and rules, no file IO and no
## clock: a save is to_dict() through JSON, written and read elsewhere.
##
## The flow around a mission:
##   plan_deploy() -> DeployPlan: who fills each slot, nothing committed;
##   the world is built from the plan's command (MissionSetup) and played;
##   apply_victory() commits the plan and what the world shows.
## A defeat is simply not applying anything: the failed attempt is dropped and
## a Retry plans again from this same state with the same mission_seed(), so the
## waves come the same. (The pre-mission save is just this state's to_dict().)
##
## Soldiers are kept in two lists: `soldiers`, the alive pool (the reserve
## included: those who aren't deploying), and `fallen`. Ids are never reused.

## The save format. Any other version is refused by from_dict.
const VERSION: int = 1
## The low 32 bits of an int, for the 32-bit mix and for splitting the seed.
const MASK32: int = 0xFFFFFFFF
## Mixed into the mission index in mission_seed(): the golden-ratio multiplier,
## chosen only because it is well mixed. Changing it re-rolls every campaign's
## missions, so it is part of the save format.
const INDEX_SALT: int = 0x9E3779B1
## Mixed into the high half of the seed in mission_seed(): the murmur3
## multiplier, with the same warning as INDEX_SALT.
const HIGH_SALT: int = 0x85EBCA6B
## The multiplier of the 32-bit mix below (the same one Formations uses for its
## rabble jitter). Odd, so multiplying by it mod 2^32 is a bijection.
const MIX_MULTIPLIER: int = 0x45D9F3B
## A soldier at full health outranks any wounded one when slots are filled.
const FULL_HEALTH_RANK: int = 0x7FFFFFFF
## The text of the largest int64, for reading a seed back.
const INT64_MAX_TEXT: String = "9223372036854775807"
## The digits of the magnitude of the smallest int64, which has no positive twin.
const INT64_MIN_DIGITS: String = "9223372036854775808"
## Roman numeral values, largest first, for the numeral after a recycled name.
const ROMAN_VALUES: Array[int] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
## The symbols for ROMAN_VALUES, in the same order.
const ROMAN_SYMBOLS: Array[String] = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]

## The campaign's seed; every mission's seed follows from it (mission_seed).
var campaign_seed: int = 0
## The difficulty tier (Difficulty), 0..TIERS-1, for the whole campaign.
var tier: int = 0
## The next mission to play: an index into CampaignDef.missions.
var mission_index: int = 0
## The id the next recruit gets. Ids start at 1 (0 is "not a campaign
## soldier") and are never reused.
var next_soldier_id: int = 1
## Soldiers alive, in the order they joined, those not deploying included.
var soldiers: Array[Soldier] = []
## Soldiers who died or were converted, in the order they fell.
var fallen: Array[Soldier] = []
## One entry per won mission, in order: {"id": the mission's id as text,
## "ticks": how long it lasted, "kills": enemies dead, "losses": soldiers
## lost}. JSON-safe as it stands.
var history: Array[Dictionary] = []


## A campaign at its first mission with nobody on the roll yet (the first
## mission's recruits are made by plan_deploy). `new_tier` is kept within the
## five tiers.
static func new_campaign(new_seed: int, new_tier: int) -> CampaignState:
	var state: CampaignState = CampaignState.new()
	state.campaign_seed = new_seed
	state.tier = clampi(new_tier, 0, Difficulty.TIERS - 1)
	return state


## The seed for the mission at this index, a pure integer mix of campaign_seed
## and the index: the same index always gives the same seed, so a Retry
## replays the same draws and waves, and different missions (or campaigns)
## draw differently.
##
## The seed's two 32-bit halves go through a two-step Feistel-like chain of
## 32-bit mixes (see _mix32), the index salted into the first step:
##     a = mix(low ^ mix(index + INDEX_SALT)),  b = mix(high ^ mix(a ^ HIGH_SALT))
## and the result is a in the low half and b's low 31 bits above it, so it is
## never negative. Every step is a bijection, so no two indices (or campaign
## seeds, apart from that one dropped bit) share a result. It uses only
## integer ops with every product under 2^63, so it is the same on every
## platform. (A 64-bit splitmix would need 64-bit literals GDScript can't
## write, and relies on overflow.)
func mission_seed(index: int) -> int:
	var low: int = campaign_seed & MASK32
	# The mask makes the shift logical: only the low 32 bits of the shifted
	# value survive, whatever the sign.
	var high: int = (campaign_seed >> 32) & MASK32
	var salted_index: int = _mix32(((index & MASK32) + INDEX_SALT) & MASK32)
	var a: int = _mix32(low ^ salted_index)
	var b: int = _mix32(high ^ _mix32(a ^ HIGH_SALT))
	return ((b & 0x7FFFFFFF) << 32) | a


## A recruit's given name from his id. Ids start at 1, so the id's place in the
## list is id - 1: the first names.size() recruits get the names in order, plain,
## and each further lap of the list adds a roman numeral (the second says II,
## the third III, and so on). Deterministic, so a replay or a Retry names the
## same recruits the same. With no names at all he is "Soldier <id>".
static func name_for(id: int, names: PackedStringArray) -> String:
	if names.is_empty():
		return "Soldier %d" % id
	var place: int = maxi(0, id - 1)
	# The whole number of laps is the point, so the remainder is dropped on purpose.
	@warning_ignore("integer_division")
	var lap: int = place / names.size()
	var base: String = names[place % names.size()]
	return base if lap == 0 else "%s %s" % [base, _roman(lap + 1)]


## The soldier alive with this id (the reserve included), or null.
func find_soldier(soldier_id: int) -> Soldier:
	for s: Soldier in soldiers:
		if s.id == soldier_id:
			return s
	return null


## Who the mission would deploy, from this state, without changing anything.
## For each roster entry, in the mission's order, `Difficulty.pick(counts,
## tier)` slots are filled:
## - if the entry carries over, from the alive soldiers of its type who are not
##   in `benched` and not already placed in an earlier slot, best first: most
##   kills, then healthiest (full health counts above any wound), then lowest
##   id;
## - any slots left, and every slot of an entry that doesn't carry over, with a
##   fresh recruit. Recruits get provisional ids next_soldier_id, +1, ... in
##   slot order, and a name from `names` (name_for). They are not committed:
##   planning twice gives the same ids, and only apply_victory adds them.
## Veterans beyond the slots (and the benched) are the reserve.
func plan_deploy(mission: MissionDef, benched: PackedInt32Array, names: PackedStringArray) -> DeployPlan:
	var plan: DeployPlan = DeployPlan.new()
	plan.mission_id = mission.id
	plan.mission_index = mission_index
	var placed: Dictionary[int, bool] = {}
	var next_id: int = next_soldier_id
	for entry: RosterEntry in mission.roster:
		var veterans: Array[Soldier] = []
		if entry.carryover:
			veterans = _available(entry.type_id, benched, placed)
		for slot: int in Difficulty.pick(entry.counts, tier):
			if slot < veterans.size():
				placed[veterans[slot].id] = true
				plan.add_slot(veterans[slot], false)
			else:
				plan.add_slot(Soldier.new(next_id, entry.type_id, name_for(next_id, names)), true)
				next_id += 1
	return plan


## The alive soldiers this mission would leave out: those benched, those the
## roster has no slot for, and the extras of a type. In the order they joined.
func reserve_for(mission: MissionDef, benched: PackedInt32Array) -> Array[Soldier]:
	var plan: DeployPlan = plan_deploy(mission, benched, PackedStringArray())
	var placed: Dictionary[int, bool] = {}
	for i: int in plan.size():
		if not plan.is_recruit[i]:
			placed[plan.soldier_ids[i]] = true
	var reserve: Array[Soldier] = []
	for s: Soldier in soldiers:
		if not placed.has(s.id):
			reserve.append(s)
	return reserve


## Commits a won mission. `plan` is the DeployPlan the world was built from and
## `world` the world as the mission ended; `stats` (finished) supplies the
## history entry. The world is read only through public fields: the unit
## carrying each deployed soldier's id.
## - The plan's recruits join the roll (next_soldier_id moves past them); a
##   recruit who died is committed and falls like anyone else, so his id is
##   spent either way.
## - A deployed soldier whose unit is alive and still Light keeps the kills and
##   wounds it ended with (a full-health survivor is stored as hp 0) and
##   `missions` goes up one.
## - One whose unit is dead, or no longer Light (converted), moves to `fallen`
##   with fallen_in set to the mission's id, keeping the kills he made.
## - One with no unit in the world at all is left as he was: nothing is known
##   of him.
## - The reserve is untouched. The mission is added to the history and
##   mission_index moves on.
## `plan` must be one this state made for this mission and hasn't changed since;
## otherwise (made for another mission, already applied so the mission has moved
## on, its recruits' ids no longer the next ones, a veteran no longer on the
## roll) nothing is changed and push_error says why, so applying a plan twice
## can't put a recruit on the roll twice or leave a save the loader refuses. A
## defeat is never applied: see the class comment.
func apply_victory(mission: MissionDef, plan: DeployPlan, world: World, stats: MissionStats) -> void:
	var problem: String = _plan_problem(mission, plan)
	if problem != "":
		push_error("CampaignState.apply_victory: " + problem)
		return
	# Copies, so the plan (which a menu may still hold) never aliases the roll.
	for recruit: Soldier in plan.recruits:
		var joined: Soldier = Soldier.new(recruit.id, recruit.type_id, recruit.name)
		joined.kills = recruit.kills
		joined.hp = recruit.hp
		soldiers.append(joined)
		next_soldier_id = maxi(next_soldier_id, recruit.id + 1)
	var units: Dictionary[int, Unit] = {}
	for unit: Unit in world.units:
		if unit.soldier_id != 0:
			units[unit.soldier_id] = unit
	var losses: int = 0
	for soldier_id: int in plan.soldier_ids:
		var soldier: Soldier = find_soldier(soldier_id)
		var unit: Unit = units.get(soldier_id)
		if soldier == null or unit == null:
			continue
		soldier.kills = unit.kills
		if unit.is_alive() and unit.faction == UnitType.Faction.LIGHT:
			soldier.hp = 0 if unit.hp >= unit.type.max_hp else unit.hp
			soldier.missions += 1
		else:
			soldiers.erase(soldier)
			soldier.fallen_in = mission.id
			fallen.append(soldier)
			losses += 1
	history.append({
		"id": String(mission.id), "ticks": stats.end_tick, "kills": stats.enemies_killed(), "losses": losses,
	})
	mission_index += 1


# Why this plan can't be applied to this state for this mission, or "".
func _plan_problem(mission: MissionDef, plan: DeployPlan) -> String:
	if plan.mission_id != mission.id:
		return "the plan was made for mission %s, not %s" % [plan.mission_id, mission.id]
	if plan.mission_index != mission_index:
		return "the plan was made at mission %d but the campaign is at %d (applied already?)" % [plan.mission_index, mission_index]
	for i: int in plan.recruits.size():
		if plan.recruits[i].id != next_soldier_id + i:
			return "the plan's recruit ids don't start at next_soldier_id %d" % next_soldier_id
	for i: int in plan.size():
		if plan.is_recruit[i]:
			continue
		var veteran: Soldier = find_soldier(plan.soldier_ids[i])
		if veteran == null or veteran.type_id != plan.type_ids[i]:
			return "soldier %d is no longer on the roll" % plan.soldier_ids[i]
	return ""


## True once every mission of the campaign has been won.
func is_complete(campaign: CampaignDef) -> bool:
	return mission_index >= campaign.missions.size()


## The state as JSON-safe values (Dictionary, Array, String, int). The seed is
## decimal text, because JSON numbers are doubles and lose a 64-bit seed past
## 2^53; the other numbers are small.
func to_dict() -> Dictionary:
	var alive: Array = []
	for s: Soldier in soldiers:
		alive.append(s.to_dict())
	var dead: Array = []
	for s: Soldier in fallen:
		dead.append(s.to_dict())
	var wins: Array = []
	for entry: Dictionary in history:
		wins.append(entry.duplicate())
	return {
		"version": VERSION,
		"campaign_seed": str(campaign_seed),
		"tier": tier,
		"mission_index": mission_index,
		"next_soldier_id": next_soldier_id,
		"soldiers": alive,
		"fallen": dead,
		"history": wins,
	}


## Reads a state back from what JSON gave (every number a float, the seed
## text). Returns null if the version isn't VERSION or anything is missing or
## of the wrong shape or range, and says why in `error_out` (one message, the
## first problem found). Soldier ids must be unique across both lists and below
## next_soldier_id, so a damaged save can't hand out an id twice. Everything is
## copied: the result shares nothing with `d`.
static func from_dict(d: Variant, error_out: PackedStringArray = PackedStringArray()) -> CampaignState:
	var state: CampaignState = CampaignState.new()
	var problem: String = state._read(d)
	if problem != "":
		error_out.append(problem)
		return null
	return state


# Fills this state from a parsed save and returns what is wrong with it, or "".
func _read(d: Variant) -> String:
	if not d is Dictionary:
		return "a save must be a dictionary"
	var save: Dictionary = d
	if not save.has("version") or not Soldier.is_whole_number(save["version"]) or int(save["version"]) != VERSION:
		return "unsupported save version (this build reads version %d)" % VERSION
	for key: String in ["campaign_seed", "tier", "mission_index", "next_soldier_id", "soldiers", "fallen", "history"]:
		if not save.has(key):
			return "the save is missing %s" % key
	var seed_text: Variant = save["campaign_seed"]
	var parsed_seed: Variant = _seed_from_text(seed_text as String) if seed_text is String else null
	if parsed_seed == null:
		return "campaign_seed must be a whole number written as text"
	campaign_seed = int(parsed_seed)
	var problem: String = _read_count(save, "tier", 0, Difficulty.TIERS - 1)
	if problem != "":
		return problem
	tier = int(save["tier"])
	problem = _read_count(save, "mission_index", 0, 0x7FFFFFFF)
	if problem != "":
		return problem
	mission_index = int(save["mission_index"])
	problem = _read_count(save, "next_soldier_id", 1, 0x7FFFFFFF)
	if problem != "":
		return problem
	next_soldier_id = int(save["next_soldier_id"])
	problem = _read_soldiers(save, "soldiers", soldiers)
	if problem != "":
		return problem
	problem = _read_soldiers(save, "fallen", fallen)
	if problem != "":
		return problem
	var seen: Dictionary[int, bool] = {}
	for s: Soldier in soldiers + fallen:
		if seen.has(s.id):
			return "soldier id %d appears more than once" % s.id
		if s.id >= next_soldier_id:
			return "soldier id %d is not below next_soldier_id %d" % [s.id, next_soldier_id]
		seen[s.id] = true
	return _read_history(save)


# A whole number in low..high at save[key], or what is wrong with it.
static func _read_count(save: Dictionary, key: String, low: int, high: int) -> String:
	var value: Variant = save[key]
	if not Soldier.is_whole_number(value) or int(value) < low or int(value) > high:
		return "%s must be a whole number from %d to %d" % [key, low, high]
	return ""


# Reads a list of soldier records into `into`, or says which one is wrong.
static func _read_soldiers(save: Dictionary, key: String, into: Array[Soldier]) -> String:
	if not save[key] is Array:
		return "%s must be a list" % key
	var records: Array = save[key]
	for i: int in records.size():
		var errors: PackedStringArray = PackedStringArray()
		var s: Soldier = Soldier.from_dict(records[i], errors)
		if s == null:
			return "%s[%d]: %s" % [key, i, errors[0]]
		into.append(s)
	return ""


# Reads the history list, keeping only the four fields, as ints.
func _read_history(save: Dictionary) -> String:
	if not save["history"] is Array:
		return "history must be a list"
	var entries: Array = save["history"]
	for i: int in entries.size():
		if not entries[i] is Dictionary:
			return "history[%d] must be a dictionary" % i
		var entry: Dictionary = entries[i]
		if not entry.has("id") or not entry["id"] is String:
			return "history[%d] needs id as text" % i
		for key: String in ["ticks", "kills", "losses"]:
			if not entry.has(key) or not Soldier.is_whole_number(entry[key]) or int(entry[key]) < 0:
				return "history[%d] needs %s as a whole number, 0 or more" % [i, key]
		history.append({
			"id": entry["id"] as String, "ticks": int(entry["ticks"]),
			"kills": int(entry["kills"]), "losses": int(entry["losses"]),
		})
	return ""


# The int64 a seed's decimal text stands for, or null if it isn't exactly what
# str() writes for one: no sign but "-", no leading zeros, no spaces, in range.
# Checked by hand because String.to_int() reports an error for a number that
# doesn't fit, rather than failing quietly.
static func _seed_from_text(text: String) -> Variant:
	var negative: bool = text.begins_with("-")
	var digits: String = text.substr(1) if negative else text
	if digits.is_empty() or digits.length() > INT64_MAX_TEXT.length():
		return null
	for i: int in digits.length():
		if digits[i] < "0" or digits[i] > "9":
			return null
	if (digits.length() > 1 and digits.begins_with("0")) or (negative and digits == "0"):
		return null
	if digits.length() == INT64_MAX_TEXT.length():
		if negative and digits == INT64_MIN_DIGITS:
			return -9223372036854775807 - 1
		# Equal lengths of digits compare like the numbers they spell.
		if digits > INT64_MAX_TEXT:
			return null
	return text.to_int()


# The alive soldiers of this type who may take a slot, best first.
func _available(type_id: StringName, benched: PackedInt32Array, placed: Dictionary[int, bool]) -> Array[Soldier]:
	var out: Array[Soldier] = []
	for s: Soldier in soldiers:
		if s.type_id == type_id and not benched.has(s.id) and not placed.has(s.id):
			out.append(s)
	out.sort_custom(_outranks)
	return out


# Most kills first, then healthiest, then lowest id: a total order, so the
# unstable sort can't change the result.
static func _outranks(a: Soldier, b: Soldier) -> bool:
	if a.kills != b.kills:
		return a.kills > b.kills
	# Both are the same type, so only the order matters: a stand-in maximum above
	# any real one puts full health (hp 0) first.
	var health_a: int = a.current_hp(FULL_HEALTH_RANK)
	var health_b: int = b.current_hp(FULL_HEALTH_RANK)
	if health_a != health_b:
		return health_a > health_b
	return a.id < b.id


# A 32-bit integer hash (a bijection on 0..2^32-1): xor-shift and multiply
# twice, then a last xor-shift. Every product is under 2^59, so nothing
# overflows.
static func _mix32(value: int) -> int:
	var h: int = value & MASK32
	for _pass: int in 2:
		h = (((h >> 16) ^ h) * MIX_MULTIPLIER) & MASK32
	return (h >> 16) ^ h


static func _roman(n: int) -> String:
	if n < 1 or n > 3999:
		return str(n)
	var out: String = ""
	var rest: int = n
	for i: int in ROMAN_VALUES.size():
		while rest >= ROMAN_VALUES[i]:
			out += ROMAN_SYMBOLS[i]
			rest -= ROMAN_VALUES[i]
	return out
