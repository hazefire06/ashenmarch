extends SceneTree
## Builds data/art/<unit>.tres from the Blender render in assets/units/<unit>/
## and lists it in data/art/catalog.tres. Both are generated; never edit them
## by hand. Run `make art-build UNIT=shieldman`, which imports first so the
## sheets are textures Godot can load (with the mipmapped, VRAM-compressed
## settings render_sprites.py wrote beside them).

const SOURCE: String = "res://assets/units/%s/"
const OUTPUT: String = "res://data/art/%s.tres"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: godot --headless --path . -s scripts/art/build_unit_art.gd -- <unit_id>")
		quit(2)
		return
	quit(0 if _build(args[0]) else 1)


## True when the art was built and listed. A function that hits a script error
## returns its type's default, so _build returns bool: false is the failure
## value, and an unforeseen error exits non-zero instead of looking like success.
func _build(unit: String) -> bool:
	var folder: String = SOURCE % unit
	var sidecar_path: String = folder + unit + ".json"
	var sidecar: Variant = null
	if FileAccess.file_exists(sidecar_path):
		sidecar = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	if not sidecar is Dictionary:
		printerr("build_unit_art: %s is missing or not JSON; run make art-render UNIT=%s" % [sidecar_path, unit])
		return false
	var missing: PackedStringArray = UnitArtBuilder.sidecar_errors(sidecar)
	if not missing.is_empty():
		printerr("build_unit_art: %s is incomplete; run make art-render UNIT=%s\n%s" % [sidecar_path, unit, "\n".join(missing)])
		return false
	if String(sidecar["unit"]) != unit:
		printerr("build_unit_art: %s is for unit \"%s\", not \"%s\"" % [sidecar_path, sidecar["unit"], unit])
		return false
	var sheets: Dictionary = {}
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		if StringName(key) not in UnitArtBuilder.GAME_ANIMS:
			continue
		var path: String = folder + String(anims[key]["sheet"])
		var sheet: Texture2D = load(path) as Texture2D
		if sheet == null:
			printerr("build_unit_art: %s did not load; run `make import` first" % path)
			return false
		sheets[StringName(key)] = sheet
	var layout: PackedStringArray = UnitArtBuilder.layout_errors(sidecar, sheets)
	if not layout.is_empty():
		printerr("build_unit_art: %s does not fit its sheets:\n%s" % [sidecar_path, "\n".join(layout)])
		return false
	var art: UnitArt = UnitArtBuilder.build(sidecar, sheets)
	var errors: PackedStringArray = art.validate()
	if not errors.is_empty():
		printerr("build_unit_art: %s" % "\n".join(errors))
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/art"))
	var out: String = OUTPUT % unit
	if ResourceSaver.save(art, out) != OK:
		printerr("build_unit_art: could not save %s" % out)
		return false
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	# Read the saved file back: it must load as a UnitArt, and the catalog then
	# holds the file-backed resource, so it saves a reference to the file
	# instead of embedding a copy of the art.
	var saved: UnitArt = ResourceLoader.load(out, "", ResourceLoader.CACHE_MODE_REPLACE) as UnitArt
	if saved == null:
		printerr("build_unit_art: %s did not load back as a UnitArt" % out)
		return false
	catalog.put(saved)
	if ResourceSaver.save(catalog, UnitArtCatalog.DEFAULT_PATH) != OK:
		printerr("build_unit_art: could not save %s" % UnitArtCatalog.DEFAULT_PATH)
		return false
	print("built %s (%d animations) and listed it in %s" % [out, art.frames.get_animation_names().size(), UnitArtCatalog.DEFAULT_PATH])
	return true
