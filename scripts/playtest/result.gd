class_name PlaytestResult
extends RefCounted
## What one played mission came to: the line a run prints, a row of the
## baseline table's raw data, and (through to_dict) a JSON line that
## PlaytestReport can read back, so batches run in several processes can be
## merged into one table. Plain data; the runner fills it.

const WON: String = "won"
const LOST: String = "lost"
## The run hit MAX_MINUTES without the mission being decided: counted as a
## loss in the tables, in a column of its own.
const TIMEOUT: String = "timeout"

## The mission's id, and the tier it was played at.
var mission_id: StringName = &""
var tier: int = 0
## "competent" or "naive".
var pilot: String = ""
## The campaign seed the run was built from (CampaignState.new_campaign), and
## the world's seed (CampaignState.mission_seed), which the game would use.
var campaign_seed: int = 0
var world_seed: int = 0
## True if the soldiers were the campaign's survivors (CHAIN), not recruits.
var chain: bool = false
## WON, LOST or TIMEOUT.
var outcome: String = TIMEOUT
## The tick the mission ended on, or the cap for a timeout.
var end_tick: int = 0
## Soldiers deployed, soldiers lost (dead or converted), and how many of those
## died to friendly fire (MissionStats).
var roster: int = 0
var losses: int = 0
var friendly_fire: int = 0
## Enemies dead.
var kills: int = 0
## Dark units still standing at the end (the ones a timeout couldn't clear).
var dark_alive: int = 0
## Units, of either side, that spent STUCK_TICKS walking without getting nearer
## their waypoint at some point of the run (PlaytestRunner counts each once).
var stuck_units: int = 0
## Ambushes that sprang (AiEvent AMBUSH_SPRUNG): The Ford's two pools.
var ambushes_sprung: int = 0
## The Ford: the lowest his hit points got, in per cent (100 if he was never
## hurt), whether he died, and what killed him ("" if he lived).
var villager_lowest_percent: int = 100
## See villager_lowest_percent.
var villager_died: bool = false
var villager_killer: String = ""
## Old Mill: the wave groups the draw bound to waves 1 to 4, and how many of
## those waves had spawned when it ended.
var waves: PackedStringArray = PackedStringArray()
var waves_spawned: int = 0
## The tick the pilot's last Sapper laid its last charge (Old Mill), or -1.
var charges_done_tick: int = -1
## Times the pilot had to go out and finish an enemy that wouldn't come to it.
var stall_breaks: int = 0
## The world's state hash at the end (determinism checks, repro).
var state_hash: String = ""
## Commands the pilot enqueued, and the wall-clock milliseconds the run took.
var commands: int = 0
var wall_ms: int = 0
## What looked wrong and why: the enemies a timeout left (type, place, what
## they were doing), an instant loss. One line each.
var notes: PackedStringArray = PackedStringArray()


## True for a win.
func won() -> bool:
	return outcome == WON


## The mission's length in minutes of game time.
func minutes() -> float:
	return float(end_tick) / float(World.TICK_RATE) / 60.0


## Wall-clock milliseconds per simulated tick.
func ms_per_tick() -> float:
	return float(wall_ms) / maxf(1.0, float(end_tick))


## The one line a run prints.
func line() -> String:
	var text: String = "%s%s t%d %s seed=%d (world %d): %s %.2f min (%d ticks) | lost %d/%d | kills %d | ff %d" % [
		"chain " if chain else "", mission_id, tier, pilot, campaign_seed, world_seed,
		outcome.to_upper(), minutes(), end_tick, losses, roster, kills, friendly_fire,
	]
	if mission_id == &"the_ford":
		text += " | villager %s | ambushes sprung %d" % [
			("killed by " + villager_killer) if villager_died else "alive", ambushes_sprung,
		]
	if not waves.is_empty():
		text += " | waves %s (%d spawned)" % [",".join(waves), waves_spawned]
	text += " | %.2f ms/tick" % ms_per_tick()
	return text


## JSON-safe values. The seeds go as text: JSON numbers are doubles and a
## 63-bit world seed doesn't survive one.
func to_dict() -> Dictionary:
	return {
		"mission": String(mission_id), "tier": tier, "pilot": pilot,
		"campaign_seed": str(campaign_seed), "world_seed": str(world_seed), "chain": chain,
		"outcome": outcome, "end_tick": end_tick, "roster": roster, "losses": losses,
		"friendly_fire": friendly_fire, "kills": kills, "dark_alive": dark_alive, "stuck_units": stuck_units,
		"ambushes_sprung": ambushes_sprung, "villager_lowest_percent": villager_lowest_percent, "villager_died": villager_died, "villager_killer": villager_killer,
		"waves": Array(waves), "waves_spawned": waves_spawned, "charges_done_tick": charges_done_tick, "stall_breaks": stall_breaks,
		"state_hash": state_hash, "commands": commands, "wall_ms": wall_ms, "notes": Array(notes),
	}


## A result from what to_dict wrote (and JSON read back), or null if it isn't
## one.
static func from_dict(d: Variant) -> PlaytestResult:
	if not d is Dictionary:
		return null
	var data: Dictionary = d
	for key: String in ["mission", "tier", "pilot", "outcome", "end_tick", "roster", "losses"]:
		if not data.has(key):
			return null
	var r: PlaytestResult = PlaytestResult.new()
	r.mission_id = StringName(str(data["mission"]))
	r.tier = int(data["tier"])
	r.pilot = str(data["pilot"])
	r.campaign_seed = int(str(data.get("campaign_seed", "0")))
	r.world_seed = int(str(data.get("world_seed", "0")))
	r.chain = bool(data.get("chain", false))
	r.outcome = str(data["outcome"])
	r.end_tick = int(data["end_tick"])
	r.roster = int(data["roster"])
	r.losses = int(data["losses"])
	r.friendly_fire = int(data.get("friendly_fire", 0))
	r.kills = int(data.get("kills", 0))
	r.dark_alive = int(data.get("dark_alive", 0))
	r.stuck_units = int(data.get("stuck_units", 0))
	r.ambushes_sprung = int(data.get("ambushes_sprung", 0))
	r.villager_lowest_percent = int(data.get("villager_lowest_percent", 100))
	r.villager_died = bool(data.get("villager_died", false))
	r.villager_killer = str(data.get("villager_killer", ""))
	r.waves = PackedStringArray(data.get("waves", []))
	r.waves_spawned = int(data.get("waves_spawned", 0))
	r.charges_done_tick = int(data.get("charges_done_tick", -1))
	r.stall_breaks = int(data.get("stall_breaks", 0))
	r.state_hash = str(data.get("state_hash", ""))
	r.commands = int(data.get("commands", 0))
	r.wall_ms = int(data.get("wall_ms", 0))
	r.notes = PackedStringArray(data.get("notes", []))
	return r
