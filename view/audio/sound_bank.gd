class_name SoundBank
extends Resource
## Every sound cue by id. A cue the game asks for but the bank lacks is silent
## and warns once, so a missing sound never breaks play. View only.

const PATH: String = "res://data/audio/sound_bank.tres"

@export var cues: Array[SoundCue] = []

## The session's bank, loaded once and never freed (an empty one if PATH is missing).
static var _shared: SoundBank = null

var _index: Dictionary[StringName, SoundCue] = {}
var _indexed: int = -1
var _warned: Array[StringName] = []


static func shared() -> SoundBank:
	if _shared == null:
		if ResourceLoader.exists(PATH):
			_shared = load(PATH) as SoundBank
		if _shared == null:
			push_warning("SoundBank: %s is missing; every sound will be silent" % PATH)
			_shared = SoundBank.new()
	return _shared


## The cue, or null (with one warning per id per bank).
func cue(id: StringName) -> SoundCue:
	var found: SoundCue = _lookup(id)
	if found == null and not _warned.has(id):
		_warned.append(id)
		push_warning("SoundBank: no cue '%s'" % id)
	return found


## True if the bank declares the id, whether or not it has streams.
func declares(id: StringName) -> bool:
	return _lookup(id) != null


## True if the id is declared with at least one stream. Never warns.
func has(id: StringName) -> bool:
	var found: SoundCue = _lookup(id)
	return found != null and not found.streams.is_empty()


## A random variant of the cue, or null if it has none.
func pick(id: StringName, rng: RandomNumberGenerator) -> AudioStream:
	var found: SoundCue = cue(id)
	if found == null or found.streams.is_empty():
		return null
	return found.streams[rng.randi_range(0, found.streams.size() - 1)]


func ids() -> Array[StringName]:
	_reindex()
	return _index.keys()


## Ids asked for but missing, in the order first asked. For tests.
func warned() -> Array[StringName]:
	return _warned


func _lookup(id: StringName) -> SoundCue:
	_reindex()
	return _index.get(id)


func _reindex() -> void:
	if _indexed == cues.size():
		return
	_index.clear()
	for c: SoundCue in cues:
		if c != null:
			_index[c.id] = c
	_indexed = cues.size()
