class_name SoundRegistry
extends RefCounted
## Registers a launch's one-shot sounds as Web Audio samples at mission load, so
## nothing decodes mid-battle (spec §4.3). Loops stream and are never listed.
## Desktop registers nothing but still reports the sizes. View only.

## Instance ids of the streams already registered this session. Registration is
## never released, and the shared bank holds the same stream objects across
## missions, so each registers once (spec §4.3.1).
static var _registered: Dictionary[int, bool] = {}


## For tests: forget what was registered.
static func reset_for_tests() -> void:
	_registered.clear()


## The one-shot cues a launch can need: every declared cue that isn't a loop and
## isn't a death or groan, plus each type's own death and groan. Sorted, unique.
static func one_shot_cues(
	types: Array[StringName], catalog: UnitCatalog, bank: SoundBank, map: SoundMap
) -> Array[StringName]:
	var found: Dictionary[StringName, bool] = {}
	for id: StringName in bank.ids():
		var c: SoundCue = bank.cue(id)
		if c != null and not c.loop and c.category != &"death" and c.category != &"groan":
			found[id] = true
	for type_id: StringName in types:
		var type: UnitType = catalog.find(type_id)
		if type == null:
			continue
		for id: StringName in [map.death_cue(type, bank), map.groan_cue(type, bank)]:
			if id != &"" and bank.declares(id):
				found[id] = true
	var out: Array[StringName] = found.keys()
	out.sort()
	return out


## Registers the one-shots' streams and extra (on Web, when enabled). Returns
## {"seconds", "lengths", "file_bytes", "load_ms", "streams"}: the registered
## seconds and each stream's length, every bank cue's file bytes plus
## extra_file_bytes (loading the bank loads every stream, spec §4.4), the time
## taken, and the streams. Desktop and a disabled run report but don't register.
static func load_for(
	types: Array[StringName], catalog: UnitCatalog, bank: SoundBank, map: SoundMap,
	extra: Array[AudioStream] = [], extra_file_bytes: int = 0,
	on_web: bool = OS.has_feature("web"), enabled: bool = true,
	registrar: Callable = AudioServer.register_stream_as_sample
) -> Dictionary:
	var started: int = Time.get_ticks_msec()
	var streams: Array[AudioStream] = []
	var seen: Dictionary[int, bool] = {}
	for id: StringName in one_shot_cues(types, catalog, bank, map):
		for s: AudioStream in bank.cue(id).streams:
			if s != null and not seen.has(s.get_instance_id()):
				seen[s.get_instance_id()] = true
				streams.append(s)
	for s: AudioStream in extra:
		if s != null and not seen.has(s.get_instance_id()):
			seen[s.get_instance_id()] = true
			streams.append(s)
	var lengths: PackedFloat32Array = PackedFloat32Array()
	var seconds: float = 0.0
	for s: AudioStream in streams:
		lengths.append(s.get_length())
		seconds += s.get_length()
		if on_web and enabled and not _registered.has(s.get_instance_id()):
			_registered[s.get_instance_id()] = true
			registrar.call(s)
	var file_bytes: int = extra_file_bytes
	for c: SoundCue in bank.cues:
		if c != null:
			file_bytes += c.file_bytes
	return {
		"seconds": seconds, "lengths": lengths, "file_bytes": file_bytes,
		"load_ms": Time.get_ticks_msec() - started, "streams": streams,
	}
