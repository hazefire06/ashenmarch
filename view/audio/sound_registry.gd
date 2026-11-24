class_name SoundRegistry
extends RefCounted
## Registers a launch's one-shot sounds as Web Audio samples at mission load, so
## nothing decodes mid-battle (spec §4.3). Loops stream and are never listed.
## Desktop registers nothing but still reports the sizes. View only.

## Instance ids of the streams already registered this session. Registration is
## never released, and the shared bank holds the same stream objects across
## missions, so each registers once (spec §4.3.1).
static var _registered: Dictionary[int, bool] = {}

## Silent stand-ins by "<unit>/<voice>/<line>" (line ids repeat across units), kept for the session so a restart
## registers no new stand-in objects (a new object would register again).
static var _stand_in_cache: Dictionary[String, AudioStream] = {}

## Stand-ins are silent 16-bit mono at this rate. The Web decode runs at the
## browser's rate anyway, so the decoded size depends only on the length.
const STAND_IN_RATE: int = 8000


## For tests: forget what was registered.
static func reset_for_tests() -> void:
	_registered.clear()
	_stand_in_cache.clear()


## Every voiced bark stream of the types' voices, clan lines included.
static func bark_streams(
	types: Array[StringName], catalog: UnitCatalog, book: BarkBook, map: SoundMap
) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for pair: Array in _speakers(types, catalog, book, map):
		var line: BarkLine = pair[1]
		var stream: AudioStream = line.streams.get(pair[0])
		if stream != null:
			out.append(stream)
	return out


## A silent stream of BarkLine.estimate_seconds(text) for each unvoiced line and
## voice of the types, so the budget run measures barks before any are bought.
static func stand_ins(
	types: Array[StringName], catalog: UnitCatalog, book: BarkBook, map: SoundMap
) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for pair: Array in _speakers(types, catalog, book, map):
		var voice: StringName = pair[0]
		var line: BarkLine = pair[1]
		if line.streams.has(voice):
			continue
		var key: String = _key(voice, line)
		if not _stand_in_cache.has(key):
			_stand_in_cache[key] = _silent(BarkLine.estimate_seconds(line.text))
		out.append(_stand_in_cache[key])
	return out


## Every [voice, line] a launch's types can speak: each voice of each type with
## that type's own lines and every clan line, when the line lists the voice.
## Unique, in type and book order.
static func _speakers(
	types: Array[StringName], catalog: UnitCatalog, book: BarkBook, map: SoundMap
) -> Array[Array]:
	var out: Array[Array] = []
	var seen: Dictionary[String, bool] = {}
	for type_id: StringName in types:
		var type: UnitType = catalog.find(type_id)
		if type == null:
			continue
		var entry: UnitSound = map.for_unit(type)
		if entry == null:
			continue
		for voice: StringName in entry.voices:
			for line: BarkLine in book.lines:
				var key: String = _key(voice, line)
				if (line.clan or line.unit == type_id) and voice in line.voices and not seen.has(key):
					seen[key] = true
					out.append([voice, line])
	return out


static func _key(voice: StringName, line: BarkLine) -> String:
	return "%s/%s/%s" % [line.unit, voice, line.id]


static func _silent(seconds: float) -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = STAND_IN_RATE
	var data: PackedByteArray = PackedByteArray()
	data.resize(int(STAND_IN_RATE * seconds) * 2)
	wav.data = data
	return wav


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
