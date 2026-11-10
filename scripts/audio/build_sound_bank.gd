extends SceneTree
## Builds data/audio/sound_bank.tres from the sidecar that `process.py build`
## writes (audio-src/build/bank.json). Generated; never edit the bank by hand.
## Run `make audio-build`, which writes the sidecar and imports the audio
## first, so every file is a stream Godot can load. A file that doesn't load,
## or a playback value this doesn't know, exits 1 and names the cue.

const SIDECAR: String = "res://audio-src/build/bank.json"


func _init() -> void:
	quit(0 if _build() else 1)


## True when the bank was built and saved. A function that hits a script error
## returns its type's default, so false is the failure value and an unforeseen
## error exits non-zero instead of looking like success.
func _build() -> bool:
	# audio-src/ has a .gdignore, so Godot never imports the sidecar, but
	# FileAccess still reads it.
	if not FileAccess.file_exists(SIDECAR):
		printerr("build_sound_bank: %s is missing; run make audio-build" % SIDECAR)
		return false
	var sidecar: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIDECAR))
	if not sidecar is Dictionary or not (sidecar as Dictionary).get("cues") is Array:
		printerr("build_sound_bank: %s is not a bank sidecar; run make audio-build" % SIDECAR)
		return false
	var bank: SoundBank = SoundBank.new()
	for entry: Variant in (sidecar as Dictionary)["cues"]:
		var cue: SoundCue = _cue(entry)
		if cue == null:
			return false
		bank.cues.append(cue)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SoundBank.PATH.get_base_dir()))
	if ResourceSaver.save(bank, SoundBank.PATH) != OK:
		printerr("build_sound_bank: could not save %s" % SoundBank.PATH)
		return false
	print("built %s (%d cues)" % [SoundBank.PATH, bank.cues.size()])
	return true


## The cue for one sidecar entry, or null (after naming it) if it can't be built.
func _cue(entry: Variant) -> SoundCue:
	if not entry is Dictionary:
		printerr("build_sound_bank: a cue entry is not an object")
		return null
	var e: Dictionary = entry
	var id: String = str(e.get("id", ""))
	var playback: String = str(e.get("playback", ""))
	var cue: SoundCue = SoundCue.new()
	cue.id = StringName(id)
	cue.category = StringName(str(e.get("category", "")))
	cue.bus = StringName(str(e.get("bus", "Effects")))
	cue.level_db = float(e.get("level_db", 0.0))
	cue.pitch_spread = float(e.get("pitch_spread", 0.0))
	cue.max_voices = int(e.get("max_voices", 3))
	cue.loop = bool(e.get("loop", false))
	match playback:
		"sample":
			cue.playback = AudioServer.PLAYBACK_TYPE_DEFAULT
		"stream":
			cue.playback = AudioServer.PLAYBACK_TYPE_STREAM
		_:
			printerr("build_sound_bank: cue %s has playback \"%s\", not sample or stream" % [id, playback.c_escape()])
			return null
	var files: Variant = e.get("files", [])
	if not files is Array:
		printerr("build_sound_bank: cue %s has no list of files" % id)
		return null
	for file: Variant in files:
		var path: String = str(file)
		var stream: AudioStream = load(path) as AudioStream
		if stream == null:
			printerr("build_sound_bank: cue %s: %s did not load; run make audio-build, which imports first" % [id, path])
			return null
		var bytes: int = _imported_bytes(path)
		if bytes <= 0:
			printerr("build_sound_bank: cue %s: no imported file found for %s" % [id, path])
			return null
		cue.streams.append(stream)
		cue.file_bytes += bytes
	return cue


## Size of the imported file behind a source: the [remap] path in its .import.
func _imported_bytes(source: String) -> int:
	var import: ConfigFile = ConfigFile.new()
	if import.load(source + ".import") != OK:
		return 0
	var imported: String = str(import.get_value("remap", "path", ""))
	if imported.is_empty() or not FileAccess.file_exists(imported):
		return 0
	var file: FileAccess = FileAccess.open(imported, FileAccess.READ)
	return file.get_length() if file != null else 0
