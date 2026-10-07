class_name ReplayPlayer
extends RefCounted
## Plays a Replay back. It builds the world the way the original was built
## (MissionSetup or SkirmishSetup, from the replay's setup), queues each
## recorded command just before the step of its tick, and checks the world
## against every checkpoint it passes. The view's replay viewer, the headless
## and web verifiers, and the tests all play replays through this.
##
## Commands are fed tick by tick, never all at once: state_hash() counts the
## pending commands, so queuing the whole stream up front would make every
## checkpoint differ from the recording.

var replay: Replay
## Null if the replay can't be played; `error` says why.
var world: World
var error: String = ""
## Checkpoints passed so far that matched.
var matched: int = 0
## The first checkpoint that didn't match: empty until one fails, then
## "tick", "expected", "actual" and "parts" (a PackedStringArray of the
## subsystem_hashes() parts that differ). Playback goes on after a divergence;
## only the first is kept.
var divergence: Dictionary = {}

var _commands: Array[SimCommand] = []
var _next_command: int = 0
var _next_checkpoint: int = 0


func _init(to_play: Replay, catalog: UnitCatalog) -> void:
	replay = to_play
	_commands = replay.decoded_commands()
	world = _build(catalog)


## True once the world has reached the replay's end (or there is no world).
func is_done() -> bool:
	return world == null or world.tick >= replay.end_tick


## Plays one tick: queues that tick's commands, steps, and checks a checkpoint
## if this was one. Does nothing once done.
func step() -> void:
	if is_done():
		return
	while _next_command < _commands.size() and _commands[_next_command].tick == world.tick:
		world.enqueue(_commands[_next_command])
		_next_command += 1
	world.step()
	_check_checkpoint()


## Plays up to `max_ticks` ticks, stopping at the end. Returns how many it
## played.
func advance(max_ticks: int) -> int:
	var played: int = 0
	while played < max_ticks and not is_done():
		step()
		played += 1
	return played


## True when played to the end with every checkpoint and the final hash
## matching.
func verified() -> bool:
	return (
		world != null and is_done() and divergence.is_empty()
		and world.state_hash() == replay.final_hash
	)


func _check_checkpoint() -> void:
	while _next_checkpoint < replay.checkpoints.size():
		var checkpoint: Array = replay.checkpoints[_next_checkpoint]
		var at: int = checkpoint[0]
		if at > world.tick:
			return
		_next_checkpoint += 1
		if at < world.tick:
			continue
		var actual: String = world.state_hash()
		if actual == checkpoint[1]:
			matched += 1
		elif divergence.is_empty():
			divergence = {
				"tick": at,
				"expected": checkpoint[1],
				"actual": actual,
				"parts": differing_parts(checkpoint[2], ReplayRecorder.plain_hashes(world)),
			}


## The parts whose hashes differ between two subsystem_hashes() dictionaries,
## sorted; a part present in only one counts as differing.
static func differing_parts(expected: Dictionary, actual: Dictionary) -> PackedStringArray:
	var parts: PackedStringArray = PackedStringArray()
	for part: Variant in expected:
		if actual.get(part) != expected[part]:
			parts.append(str(part))
	for part: Variant in actual:
		if not expected.has(part):
			parts.append(str(part))
	parts.sort()
	return parts


func _build(catalog: UnitCatalog) -> World:
	if catalog == null:
		error = "no unit catalog"
		return null
	match replay.kind:
		Replay.Kind.MISSION:
			var path: String = replay.setup["mission"]
			if not Replay.is_safe_path(path, Replay.MISSION_DIR) or not ResourceLoader.exists(path):
				error = "this build has no mission %s" % path
				return null
			var mission: MissionDef = load(path) as MissionDef
			if mission == null:
				error = "%s isn't a mission" % path
				return null
			var deploy: DeployCommand = CommandCodec.decode(replay.setup["deploy"]) as DeployCommand
			var built: World = MissionSetup.create_world(
				mission, replay.setup["tier"], replay.setup["seed"], deploy, catalog
			)
			if built == null:
				error = "the mission didn't start"
			return built
		Replay.Kind.SKIRMISH:
			var setup: SkirmishSetup = SkirmishSetup.from_dict(replay.setup)
			if setup == null:
				error = "the skirmish setup is malformed or its map is missing"
				return null
			var built: World = SkirmishSetup.create_world(setup, catalog)
			if built == null:
				error = "the skirmish didn't start"
			return built
	error = "unknown replay kind"
	return null
