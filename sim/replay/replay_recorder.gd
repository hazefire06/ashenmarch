class_name ReplayRecorder
extends RefCounted
## Fills a Replay as its world plays. World.enqueue hands it every command
## queued from outside, and World.step a chance to take a checkpoint.
##
## Attach it (world.recorder) after the world is built, never before: the
## setup's own tick-0 commands (the deploy, the herb plants) are rebuilt from
## the setup on playback, so recording them would apply them twice.

## Ticks between checkpoints (10 s). Each costs one state_hash() and one
## subsystem_hashes(), about 1.5 ms on the 512² maps.
const CHECKPOINT_TICKS: int = 10 * World.TICK_RATE

var replay: Replay


func _init(into: Replay) -> void:
	replay = into


## Called by World.enqueue for every command it accepts.
func record(command: SimCommand) -> void:
	var record_data: Array = CommandCodec.encode(command)
	if not record_data.is_empty():
		replay.commands.append(record_data)


## Called by World.step after each tick.
func after_step(world: World) -> void:
	if world.tick % CHECKPOINT_TICKS == 0:
		replay.checkpoints.append([world.tick, world.state_hash(), plain_hashes(world)])


## Stamps where the recording stops: the world's tick and hash now. Call it
## again to move the end, for a game that went on after an earlier stamp.
func finish(world: World) -> void:
	replay.end_tick = world.tick
	replay.final_hash = world.state_hash()


## World.subsystem_hashes() as an untyped Dictionary, which is what a replay
## stores (no typed containers in the file).
static func plain_hashes(world: World) -> Dictionary:
	var plain: Dictionary = {}
	var typed: Dictionary[String, String] = world.subsystem_hashes()
	for part: String in typed:
		plain[part] = typed[part]
	return plain
