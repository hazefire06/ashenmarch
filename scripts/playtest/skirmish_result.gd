class_name SkirmishResult
extends RefCounted
## What one played skirmish came to: the line a run prints and a row of the
## skirmish tables' raw data, which round-trips through to_dict and from_dict
## as a JSON line (the RAW and REPORT settings of scripts/skirmish_playtest.gd)
## so batches run in several processes can be merged into one table. Plain
## data; SkirmishRunner fills it. Sides are named by their faction ("light"
## and "dark") in every field, so the table code never has to know which side
## a pilot or a commander played.

## `matrix`: both armies commanded by the AI (A), or a playtest pilot playing
## Light against the AI's Dark (B).
const MATRIX_A: String = "A"
const MATRIX_B: String = "B"
## `pilot` when no pilot played: the commander commanded Light too.
const AI: String = "ai"
## `winner`: a side, a draw, or a run that hit the safety cap undecided.
const LIGHT: String = "light"
const DARK: String = "dark"
const DRAW: String = "draw"
const TIMEOUT: String = "timeout"
## `end_reason`: how the skirmish was decided; "" for a timeout.
const REASON_TIME: String = "time"
const REASON_ELIMINATION: String = "elimination"

## "A" or "B", see MATRIX_A.
var matrix: String = MATRIX_A
var map_id: StringName = &""
## The mode's lower-case name, e.g. "king_of_the_hill".
var mode: String = ""
## The skirmish's time limit, in minutes.
var minutes: int = 0
var budget: int = 0
## The army templates each side was bought from.
var light_template: StringName = &""
var dark_template: StringName = &""
## Which of the map's starts Light had, 0 (A) or 1 (B).
var light_start: int = 0
## The world's seed (the run's reproduction key, with the settings above).
var world_seed: int = 0
## "ai", or the pilot's name ("competent" or "naive").
var pilot: String = AI
## See the winner constants.
var winner: String = TIMEOUT
## See the end_reason constants.
var end_reason: String = ""
## The tick the run ended on (the cap for a timeout).
var end_tick: int = 0
## Units each side fielded and how many were still standing at the end (the
## lost ones are the difference: dead, or no longer on their side).
var light_deployed: int = 0
var dark_deployed: int = 0
var light_alive: int = 0
var dark_alive: int = 0
## Each side's score in each mode, whichever mode was played: enemies killed,
## seconds holding the hill, flags owned at the end, and flag-seconds owned
## over the run (Capture the Flags' tie-break).
var light_kills: int = 0
var dark_kills: int = 0
var light_hold_s: int = 0
var dark_hold_s: int = 0
var light_flags: int = 0
var dark_flags: int = 0
var light_owned_s: int = 0
var dark_owned_s: int = 0
## The pilot's commands (0 when the AI commanded Light).
var commands: int = 0
## The world's state hash at the end (determinism checks, repro).
var state_hash: String = ""
## Wall-clock milliseconds the stepping loop took, the pilot's thinks
## included, the world's construction not.
var wall_ms: int = 0
## What looked wrong and why, one line each (a timeout's leftovers).
var notes: PackedStringArray = PackedStringArray()


## Units Light lost.
func light_lost() -> int:
	return light_deployed - light_alive


## Units Dark lost.
func dark_lost() -> int:
	return dark_deployed - dark_alive


## The length of the run in minutes of game time.
func end_minutes() -> float:
	return float(end_tick) / float(World.TICK_RATE) / 60.0


## Wall-clock milliseconds per simulated tick.
func ms_per_tick() -> float:
	return float(wall_ms) / maxf(1.0, float(end_tick))


## The pairing of templates, "light_balanced vs dark_horde".
func pairing() -> String:
	return "%s vs %s" % [light_template, dark_template]


## The start Light had, as the map's name for it: "A" or "B".
func start_name() -> String:
	return "B" if light_start == 1 else "A"


## "<map> / <mode>", the cell a run belongs to.
func cell() -> String:
	return "%s / %s" % [map_id, mode]


## The one line a run prints.
func line() -> String:
	var text: String = "%s %s %s %dm budget %d | %s (%s) vs %s | seed=%d %s: %s" % [
		matrix, map_id, mode, minutes, budget, light_template, start_name(), dark_template, world_seed,
		pilot, outcome_text(),
	]
	text += " %.2f min | alive light %d/%d dark %d/%d | kills %d-%d | hold %d-%d s | flags %d-%d" % [
		end_minutes(), light_alive, light_deployed, dark_alive, dark_deployed, light_kills, dark_kills,
		light_hold_s, dark_hold_s, light_flags, dark_flags,
	]
	return text + " | %.2f ms/tick" % ms_per_tick()


## "LIGHT wins by elimination", "DRAW by time", or "TIMEOUT".
func outcome_text() -> String:
	if winner == TIMEOUT:
		return "TIMEOUT"
	if winner == DRAW:
		return "DRAW by %s" % end_reason
	return "%s wins by %s" % [winner.to_upper(), end_reason]


## JSON-safe values. The seed goes as text: JSON numbers are doubles and a
## 63-bit seed doesn't survive one.
func to_dict() -> Dictionary:
	return {
		"matrix": matrix, "map": String(map_id), "mode": mode, "minutes": minutes, "budget": budget,
		"light_template": String(light_template), "dark_template": String(dark_template),
		"light_start": light_start, "world_seed": str(world_seed), "pilot": pilot, "winner": winner,
		"end_reason": end_reason, "end_tick": end_tick, "light_deployed": light_deployed,
		"dark_deployed": dark_deployed, "light_alive": light_alive, "dark_alive": dark_alive,
		"light_kills": light_kills, "dark_kills": dark_kills, "light_hold_s": light_hold_s,
		"dark_hold_s": dark_hold_s, "light_flags": light_flags, "dark_flags": dark_flags,
		"light_owned_s": light_owned_s, "dark_owned_s": dark_owned_s, "commands": commands,
		"state_hash": state_hash, "wall_ms": wall_ms, "notes": Array(notes),
	}


## A result from what to_dict wrote (and JSON read back), or null if it isn't
## one.
static func from_dict(d: Variant) -> SkirmishResult:
	if not d is Dictionary:
		return null
	var data: Dictionary = d
	for key: String in [
		"matrix", "map", "mode", "minutes", "budget", "light_template", "dark_template", "light_start",
		"winner", "end_tick", "light_deployed", "dark_deployed", "light_alive", "dark_alive",
	]:
		if not data.has(key):
			return null
	var r: SkirmishResult = SkirmishResult.new()
	r.matrix = str(data["matrix"])
	r.map_id = StringName(str(data["map"]))
	r.mode = str(data["mode"])
	r.minutes = int(data["minutes"])
	r.budget = int(data["budget"])
	r.light_template = StringName(str(data["light_template"]))
	r.dark_template = StringName(str(data["dark_template"]))
	r.light_start = int(data["light_start"])
	r.world_seed = int(str(data.get("world_seed", "0")))
	r.pilot = str(data.get("pilot", AI))
	r.winner = str(data["winner"])
	r.end_reason = str(data.get("end_reason", ""))
	r.end_tick = int(data["end_tick"])
	r.light_deployed = int(data["light_deployed"])
	r.dark_deployed = int(data["dark_deployed"])
	r.light_alive = int(data["light_alive"])
	r.dark_alive = int(data["dark_alive"])
	r.light_kills = int(data.get("light_kills", 0))
	r.dark_kills = int(data.get("dark_kills", 0))
	r.light_hold_s = int(data.get("light_hold_s", 0))
	r.dark_hold_s = int(data.get("dark_hold_s", 0))
	r.light_flags = int(data.get("light_flags", 0))
	r.dark_flags = int(data.get("dark_flags", 0))
	r.light_owned_s = int(data.get("light_owned_s", 0))
	r.dark_owned_s = int(data.get("dark_owned_s", 0))
	r.commands = int(data.get("commands", 0))
	r.state_hash = str(data.get("state_hash", ""))
	r.wall_ms = int(data.get("wall_ms", 0))
	r.notes = PackedStringArray(data.get("notes", []))
	return r
