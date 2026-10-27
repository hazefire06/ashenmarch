class_name UnitArtBuilder
extends RefCounted
## Turns a packed sidecar (assets/units/<id>/<id>.json, written by
## scripts/art/pack_unit_art.gd) and its sheets into a UnitArt. Each frame is
## an AtlasTexture whose region is the frame's packed rect and whose margin
## puts back the rest of its cell, so every frame is `cell` px square again
## (UnitArtPacker says how a grid render is packed). Only the animations the
## game plays are kept: an alternate auditioned on the contact sheet stays out.

const GAME_ANIMS: Array[StringName] = [
	&"idle", &"walk", &"attack", &"die", &"shoot", &"throw", &"cast", &"place",
]

## What build() and layout_errors() read from a packed sidecar without a default.
const SIDECAR_KEYS: Array[String] = ["unit", "cell", "feet_px", "pixels_per_meter", "animations", "layout"]
const ANIMATION_KEYS: Array[String] = ["sheet", "frames", "fps", "loop", "rects", "sheet_size"]


## Which keys the packed sidecar lacks, or an empty array if it has all that
## build() and layout_errors() need. Run before them: a missing key would be a
## script error deep inside them, far from its cause. Only the animations the
## game plays are checked, and each one's sheet must be its own file
## (UnitArtPacker.sheet_error). A grid sidecar, straight from the renderer, has
## no "layout": make art-build packs it first.
static func sidecar_errors(sidecar: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	for key: String in SIDECAR_KEYS:
		if not sidecar.has(key):
			errors.append("no \"%s\"" % key)
	if sidecar.has("layout") and sidecar["layout"] != UnitArtPacker.LAYOUT:
		errors.append("layout is \"%s\", not \"%s\"" % [sidecar["layout"], UnitArtPacker.LAYOUT])
	if not sidecar.get("animations") is Dictionary:
		if sidecar.has("animations"):
			errors.append("\"animations\" is not an object")
		return errors
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		if StringName(key) not in GAME_ANIMS:
			continue
		if not anims[key] is Dictionary:
			errors.append("%s: not an object" % key)
			continue
		for needed: String in ANIMATION_KEYS:
			if not (anims[key] as Dictionary).has(needed):
				errors.append("%s: no \"%s\"" % [key, needed])
		if (anims[key] as Dictionary).has("sheet"):
			var bad_sheet: String = UnitArtPacker.sheet_error(key, anims[key]["sheet"])
			if not bad_sheet.is_empty():
				errors.append(bad_sheet)
	return errors


## Why the packed sidecar doesn't fit its sheets, or an empty array if it
## does. Only the animations the game plays are checked. A sheet must be
## exactly the size the pack made it (sheet_size): a stale sheet beside a newer
## sidecar would be cut in the wrong places without a word. Every rect must be
## [x, y, w, h, cell_x, cell_y], lie inside its sheet and inside the cell, and
## there must be one per frame per direction. sheets is as for build().
static func layout_errors(sidecar: Dictionary, sheets: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var cell: int = int(sidecar["cell"])
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		var anim: StringName = StringName(key)
		if anim not in GAME_ANIMS:
			continue
		var info: Dictionary = anims[key]
		var count: int = int(info["frames"])
		var sheet: Texture2D = sheets.get(anim) as Texture2D
		if sheet == null:
			errors.append("%s: no sheet" % key)
			continue
		var size: Vector2i = Vector2i(sheet.get_size())
		var packed_size: Array = info["sheet_size"]
		if packed_size.size() != 2 or size != Vector2i(int(packed_size[0]), int(packed_size[1])):
			errors.append("%s: the sheet is %dx%d, but the sidecar packed it %s" % [key, size.x, size.y, packed_size])
			continue
		var rects: Array = info["rects"]
		if rects.size() != UnitArt.DIRECTIONS * count:
			errors.append("%s: %d rects for %d frames in %d directions" % [key, rects.size(), count, UnitArt.DIRECTIONS])
			continue
		for k: int in rects.size():
			var r: Variant = rects[k]
			if not r is Array or (r as Array).size() != 6:
				errors.append("%s: rect %d is not [x, y, w, h, cell_x, cell_y]" % [key, k])
				break
			var x: int = int(r[0])
			var y: int = int(r[1])
			var w: int = int(r[2])
			var h: int = int(r[3])
			if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > size.x or y + h > size.y:
				errors.append("%s: rect %d (%d, %d, %d, %d) is not inside the %dx%d sheet" % [key, k, x, y, w, h, size.x, size.y])
				break
			if int(r[4]) < 0 or int(r[5]) < 0 or int(r[4]) + w > cell or int(r[5]) + h > cell:
				errors.append("%s: rect %d sits outside the %d px cell" % [key, k, cell])
				break
	return errors


## sheets maps each animation name (StringName) to its Texture2D.
static func build(sidecar: Dictionary, sheets: Dictionary) -> UnitArt:
	var art: UnitArt = UnitArt.new()
	art.unit_id = StringName(sidecar["unit"])
	art.cell_px = int(sidecar["cell"])
	art.feet_px = int(sidecar["feet_px"])
	art.figure_height_m = float(sidecar.get("figure_height_m", 0.0))
	art.pixels_per_meter = float(sidecar["pixels_per_meter"])
	art.bursts_on_death = bool(sidecar.get("bursts_on_death", false))
	art.die_falls_forward = bool(sidecar.get("die_falls_forward", false))
	var gib: Array = sidecar.get("gib_color", [0.5, 0.5, 0.5])
	art.gib_color = Color(float(gib[0]), float(gib[1]), float(gib[2]))
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation(&"default")
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		var anim: StringName = StringName(key)
		if anim not in GAME_ANIMS:
			continue
		var info: Dictionary = anims[key]
		var sheet: Texture2D = sheets[anim]
		var count: int = int(info["frames"])
		var rects: Array = info["rects"]
		for dir: int in UnitArt.DIRECTIONS:
			var name: StringName = UnitArt.anim_name(anim, dir)
			frames.add_animation(name)
			frames.set_animation_speed(name, float(info["fps"]))
			frames.set_animation_loop(name, bool(info["loop"]))
			for i: int in count:
				var r: Array = rects[dir * count + i]
				var frame: AtlasTexture = AtlasTexture.new()
				frame.atlas = sheet
				frame.region = Rect2(r[0], r[1], r[2], r[3])
				# What the trim took, put back: every frame is the whole cell again.
				frame.margin = Rect2(r[4], r[5], art.cell_px - int(r[2]), art.cell_px - int(r[3]))
				frames.add_frame(name, frame)
		var impact: int = int(info.get("impact_frame", -1))
		if impact >= 0:
			art.impact_frames[anim] = impact
		if anim == &"walk":
			art.stride_m = float(info.get("stride_m", 1.0))
	art.frames = frames
	return art
