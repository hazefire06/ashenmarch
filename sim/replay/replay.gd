class_name Replay
extends RefCounted
## A recorded game: what built the world, every command queued into it from
## outside (the player's orders), and hashes to check a playback against.
## ReplayRecorder fills one as a game is played; ReplayPlayer plays one back.
##
## Plain data. to_dict() holds only ints, bools, Strings, packed arrays, and
## Arrays and Dictionaries of those, so var_to_bytes stores it the same on
## every platform. The sim does no file IO: ReplayStore (view) reads and
## writes the files.
##
## A replay is only as good as the build that plays it. The same setup and
## commands on a build whose rules changed diverge, and the checkpoints say
## when and in which part of the state.

## The file format. Bump it when a field changes meaning; from_dict refuses a
## format it doesn't know. New command kinds don't need a bump (CommandCodec
## only ever appends kinds).
const FORMAT: int = 1
## The longest replay accepted (4 hours of play); a mission is capped at 25
## minutes, a skirmish at 20. A file claiming more is refused rather than
## played for ever.
const MAX_END_TICK: int = 4 * 60 * 60 * World.TICK_RATE
## Where the resources a replay names may live: shipped missions and maps.
const MISSION_DIR: String = "res://data/missions/"
const MAP_DIR: String = "res://maps/"

enum Kind {
	## A campaign mission: MissionSetup builds the world.
	MISSION = 1,
	## A skirmish: SkirmishSetup builds the world.
	SKIRMISH = 2,
}

var format: int = FORMAT
## application/config/version of the build that recorded it.
var game_version: String = ""
var kind: Kind = Kind.MISSION
## What builds the world. MISSION: "mission" (the MissionDef's resource path),
## "tier", "seed" and "deploy" (the tick-0 DeployCommand as a CommandCodec
## record, which carries the campaign's survivors, kills and wounds).
## SKIRMISH: SkirmishSetup.to_dict().
var setup: Dictionary = {}
## CommandCodec records in the order they were queued. Their ticks never go
## down.
var commands: Array = []
## Every ReplayRecorder.CHECKPOINT_TICKS: [tick, state_hash,
## {part: hash} from World.subsystem_hashes()], the tick being World.tick
## after that step.
var checkpoints: Array = []
## World.tick when recording stopped: the playback steps until here.
var end_tick: int = 0
## state_hash() at end_tick.
var final_hash: String = ""
## For the replays list, never for playing: "title", "mode", "outcome",
## "recorded_at" (unix seconds, set by the view). Any keys.
var summary: Dictionary = {}


## A replay of a campaign mission about to be played: `mission_path` is the
## MissionDef's resource path, the rest what MissionSetup.create_world was
## given. Empty commands and checkpoints; a ReplayRecorder fills them.
static func for_mission(mission_path: String, tier: int, world_seed: int, deploy: DeployCommand) -> Replay:
	var replay: Replay = Replay.new()
	replay.kind = Kind.MISSION
	replay.setup = {
		"mission": mission_path,
		"tier": tier,
		"seed": world_seed,
		"deploy": CommandCodec.encode(deploy),
	}
	return replay


## A replay of a skirmish about to be played from `skirmish_setup`.
static func for_skirmish(skirmish_setup: SkirmishSetup) -> Replay:
	var replay: Replay = Replay.new()
	replay.kind = Kind.SKIRMISH
	replay.setup = skirmish_setup.to_dict()
	return replay


## True for a path a replay may load: a .tres under `dir` (MISSION_DIR or
## MAP_DIR), already simplified and with no "..". A replay file is untrusted:
## "res://../" climbs out of the project, and load() runs a script's static
## code before any type check could refuse it, so nothing else is loaded.
static func is_safe_path(path: String, dir: String) -> bool:
	return (
		path.begins_with(dir) and not path.contains("..") and path.simplify_path() == path
		and path.get_extension() == "tres"
	)


## Seconds of game time it covers.
func seconds() -> int:
	return end_tick / World.TICK_RATE


func to_dict() -> Dictionary:
	return {
		"format": format,
		"game_version": game_version,
		"kind": int(kind),
		"setup": setup.duplicate(true),
		"commands": commands.duplicate(true),
		"checkpoints": checkpoints.duplicate(true),
		"end_tick": end_tick,
		"final_hash": final_hash,
		"summary": summary.duplicate(true),
	}


## The replay `data` describes, or null if it is malformed. A reason is
## appended to `problems` (if given) for the caller to report: a format this
## build doesn't know, a missing or wrongly typed field, a command record that
## doesn't decode, ticks out of order. Whether the setup still builds a world
## (the mission or map exists in this build) is ReplayPlayer's to find out.
static func from_dict(data: Variant, problems: Array[String] = []) -> Replay:
	if not data is Dictionary:
		problems.append("not a replay")
		return null
	var d: Dictionary = data
	if not d.get("format") is int:
		problems.append("not a replay")
		return null
	if d["format"] != FORMAT:
		problems.append("replay format %d; this build reads format %d" % [d["format"], FORMAT])
		return null
	if (
		not d.get("game_version") is String or not d.get("kind") is int
		or not d.get("setup") is Dictionary or not d.get("commands") is Array
		or not d.get("checkpoints") is Array or not d.get("end_tick") is int
		or not d.get("final_hash") is String or not d.get("summary") is Dictionary
	):
		problems.append("a field is missing or the wrong type")
		return null
	if not Kind.values().has(d["kind"]):
		problems.append("unknown replay kind %d" % d["kind"])
		return null
	var replay: Replay = Replay.new()
	replay.game_version = d["game_version"]
	replay.kind = d["kind"] as Kind
	replay.setup = d["setup"]
	replay.commands = d["commands"]
	replay.checkpoints = d["checkpoints"]
	replay.end_tick = d["end_tick"]
	replay.final_hash = d["final_hash"]
	replay.summary = d["summary"]
	var problem: String = replay._check()
	if problem != "":
		problems.append(problem)
		return null
	return replay


## Every command decoded, in order. Null entries never occur in a replay that
## came through from_dict, which rejects records that don't decode.
func decoded_commands() -> Array[SimCommand]:
	var decoded: Array[SimCommand] = []
	for record: Variant in commands:
		decoded.append(CommandCodec.decode(record as Array) if record is Array else null)
	return decoded


# Why the fields don't hold together, or "".
func _check() -> String:
	if end_tick < 0 or end_tick > MAX_END_TICK:
		return "a length out of range"
	if kind == Kind.MISSION:
		if (
			not setup.get("mission") is String or not setup.get("tier") is int
			or not setup.get("seed") is int or not setup.get("deploy") is Array
		):
			return "the mission setup is incomplete"
		if not is_safe_path(setup["mission"], MISSION_DIR):
			return "the mission's path isn't a shipped mission"
		if not CommandCodec.decode(setup["deploy"]) is DeployCommand:
			return "the mission's deploy doesn't decode"
	var last_tick: int = 0
	for record: Variant in commands:
		var command: SimCommand = CommandCodec.decode(record) if record is Array else null
		if command == null:
			return "a command record doesn't decode"
		if command.tick < last_tick or command.tick > end_tick:
			return "command ticks are out of order"
		last_tick = command.tick
	var last_checkpoint: int = 0
	for entry: Variant in checkpoints:
		if not entry is Array or (entry as Array).size() != 3:
			return "a checkpoint is malformed"
		var fields: Array = entry
		if not fields[0] is int or not fields[1] is String or not fields[2] is Dictionary:
			return "a checkpoint is malformed"
		if fields[0] <= last_checkpoint or fields[0] > end_tick:
			return "checkpoint ticks are out of order"
		last_checkpoint = fields[0]
	return ""
