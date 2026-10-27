extends SceneTree
## Packs one unit's grid render, art-src/units/<unit>/sheets/ (the sidecar
## <unit>.json and a sheet per animation, from make art-render), into
## assets/units/<unit>/: a trimmed sheet per clip the game plays, its
## .png.import (written only when missing, so a repacked sheet keeps its uid),
## and the packed sidecar <unit>.json. UnitArtPacker says how. Run
## `make art-build UNIT=<unit>`, which packs, imports, then builds the UnitArt.
## Nothing is read or written through a symlink.

const SOURCE: String = "res://art-src/units/%s/sheets/"
const OUTPUT: String = "res://assets/units/%s/"
## Mipmapped, VRAM-compressed sprite sheets; Godot fills in the rest on import.
const IMPORT_SETTINGS: String = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
mipmaps/generate=true
mipmaps/limit=-1
process/fix_alpha_border=true
process/premult_alpha=false
detect_3d/compress_to=0
"""


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: godot --headless --path . -s scripts/art/pack_unit_art.gd -- <unit_id>")
		quit(2)
		return
	quit(0 if _pack(args[0]) else 1)


## True when the unit was packed. As in build_unit_art.gd, false is the failure
## value, so an unforeseen script error exits non-zero instead of looking like
## success.
func _pack(unit: String) -> bool:
	if RegEx.create_from_string("^[a-z0-9_]+$").search(unit) == null:
		printerr("pack_unit_art: %s is not a unit name (lowercase letters, digits and _)" % unit)
		return false
	var source: String = SOURCE % unit
	var output: String = OUTPUT % unit
	var links: PackedStringArray = UnitArtPacker.planted_links(PackedStringArray([source, output]))
	if not links.is_empty():
		printerr("pack_unit_art: refusing to read or write through a symlink: %s" % ", ".join(links))
		return false
	var sidecar_path: String = source + unit + ".json"
	var sidecar: Variant = null
	if FileAccess.file_exists(sidecar_path):
		sidecar = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	if not sidecar is Dictionary:
		printerr("pack_unit_art: %s is missing or not JSON; run make art-render UNIT=%s" % [sidecar_path, unit])
		return false
	var missing: PackedStringArray = UnitArtPacker.sidecar_errors(sidecar)
	if not missing.is_empty():
		printerr("pack_unit_art: %s is incomplete; run make art-render UNIT=%s\n%s" % [sidecar_path, unit, "\n".join(missing)])
		return false
	if String(sidecar["unit"]) != unit:
		printerr("pack_unit_art: %s is for unit \"%s\", not \"%s\"" % [sidecar_path, sidecar["unit"], unit])
		return false
	var grids: Dictionary = {}
	for key: String in sidecar["animations"]:
		if StringName(key) not in UnitArtBuilder.GAME_ANIMS:
			continue
		var path: String = source + String(sidecar["animations"][key]["sheet"])
		var grid: Image = Image.load_from_file(ProjectSettings.globalize_path(path)) if FileAccess.file_exists(path) else null
		if grid == null:
			printerr("pack_unit_art: %s did not load" % path)
			return false
		grids[StringName(key)] = grid
	var layout: PackedStringArray = UnitArtPacker.layout_errors(sidecar, grids)
	if not layout.is_empty():
		printerr("pack_unit_art: %s does not fit its sheets:\n%s" % [sidecar_path, "\n".join(layout)])
		return false
	var packed: Dictionary = UnitArtPacker.pack(sidecar, grids)
	var errors: PackedStringArray = packed["errors"]
	if not errors.is_empty():
		printerr("pack_unit_art: %s" % "\n".join(errors))
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var before: int = 0
	var after: int = 0
	var sheets: Dictionary = packed["sheets"]
	for anim: StringName in sheets:
		var image: Image = sheets[anim]
		var sheet: String = output + String(packed["sidecar"]["animations"][String(anim)]["sheet"])
		if image.save_png(ProjectSettings.globalize_path(sheet)) != OK:
			printerr("pack_unit_art: could not write %s" % sheet)
			return false
		if not FileAccess.file_exists(sheet + ".import"):
			var settings: FileAccess = FileAccess.open(sheet + ".import", FileAccess.WRITE)
			if settings == null:
				printerr("pack_unit_art: could not write %s.import" % sheet)
				return false
			settings.store_string(IMPORT_SETTINGS)
			settings.close()
		var grid: Image = grids[anim]
		before += UnitArt.texture_bytes(grid.get_width(), grid.get_height(), Image.FORMAT_DXT5, true)
		after += UnitArt.texture_bytes(image.get_width(), image.get_height(), Image.FORMAT_DXT5, true)
	var out_sidecar: FileAccess = FileAccess.open(output + unit + ".json", FileAccess.WRITE)
	if out_sidecar == null:
		printerr("pack_unit_art: could not write %s%s.json" % [output, unit])
		return false
	out_sidecar.store_string(JSON.stringify(packed["sidecar"], "  ", true) + "\n")
	out_sidecar.close()
	print("packed %s: %d sheets, %.1f MB -> %.1f MB at DXT5 with mipmaps, into %s" % [unit, sheets.size(), before / 1e6, after / 1e6, output])
	return true
