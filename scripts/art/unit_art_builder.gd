class_name UnitArtBuilder
extends RefCounted
## Turns the Blender render's sidecar (assets/units/<id>/<id>.json) and sprite
## sheets into a UnitArt. A sheet has rows_per_direction rows for each of the
## 8 directions and `columns` columns; frame i of direction d sits at column
## i % columns and row d * rows_per_direction + i / columns (a long animation
## wraps, to keep the sheet under the 4096 px texture limit). A cell sits a
## gutter inside its stride, so mipmaps don't bleed between frames. Only the
## animations the game plays are kept: an alternate auditioned on the contact
## sheet stays out.

const GAME_ANIMS: Array[StringName] = [
	&"idle", &"walk", &"attack", &"die", &"shoot", &"throw", &"cast", &"place",
]

## What build() and layout_errors() read from the sidecar without a default.
const SIDECAR_KEYS: Array[String] = ["unit", "cell", "stride", "gutter", "feet_px", "pixels_per_meter", "animations"]
const ANIMATION_KEYS: Array[String] = ["sheet", "frames", "fps", "loop"]


## Which keys the sidecar lacks, or an empty array if it has all that build()
## and layout_errors() need. Run before them: a missing key would be a script
## error deep inside them, far from its cause. Only the animations the game
## plays are checked.
static func sidecar_errors(sidecar: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	for key: String in SIDECAR_KEYS:
		if not sidecar.has(key):
			errors.append("no \"%s\"" % key)
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
	return errors


## Why the sidecar's layout doesn't fit its sheets, or an empty array if it
## does. Only the animations the game plays are checked. Run before build():
## a sidecar that disagrees with its sheets would otherwise cut cells from
## past a texture's edge (or divide by zero) and fail far from the cause.
## sheets is as for build().
static func layout_errors(sidecar: Dictionary, sheets: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var cell: int = int(sidecar["cell"])
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		var anim: StringName = StringName(key)
		if anim not in GAME_ANIMS:
			continue
		var info: Dictionary = anims[key]
		var count: int = int(info["frames"])
		var columns: int = int(info.get("columns", count))
		var rows_per_direction: int = int(info.get("rows_per_direction", 1))
		if columns <= 0:
			errors.append("%s: columns must be positive, not %d" % [key, columns])
		if rows_per_direction <= 0:
			errors.append("%s: rows_per_direction must be positive, not %d" % [key, rows_per_direction])
		if columns <= 0 or rows_per_direction <= 0:
			continue
		if columns * rows_per_direction < count:
			errors.append("%s: %d columns x %d rows hold %d frames, not %d" % [key, columns, rows_per_direction, columns * rows_per_direction, count])
			continue
		var sheet: Texture2D = sheets.get(anim) as Texture2D
		if sheet == null:
			errors.append("%s: no sheet" % key)
			continue
		# The far corner of the last frame of the last direction.
		@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
		var last_row: int = (UnitArt.DIRECTIONS - 1) * rows_per_direction + (count - 1) / columns
		var right: int = (mini(count, columns) - 1) * stride + gutter + cell
		var bottom: int = last_row * stride + gutter + cell
		var size: Vector2 = sheet.get_size()
		if right > size.x or bottom > size.y:
			errors.append("%s: frames reach outside the %dx%d sheet, which would need %dx%d" % [key, int(size.x), int(size.y), right, bottom])
	return errors


## sheets maps each animation name (StringName) to its Texture2D.
static func build(sidecar: Dictionary, sheets: Dictionary) -> UnitArt:
	var art: UnitArt = UnitArt.new()
	art.unit_id = StringName(sidecar["unit"])
	art.cell_px = int(sidecar["cell"])
	art.feet_px = int(sidecar["feet_px"])
	art.pixels_per_meter = float(sidecar["pixels_per_meter"])
	art.bursts_on_death = bool(sidecar.get("bursts_on_death", false))
	art.die_falls_forward = bool(sidecar.get("die_falls_forward", false))
	var gib: Array = sidecar.get("gib_color", [0.5, 0.5, 0.5])
	art.gib_color = Color(float(gib[0]), float(gib[1]), float(gib[2]))
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
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
		# Without the keys, the old layout: one row per direction.
		var columns: int = int(info.get("columns", count))
		var rows_per_direction: int = int(info.get("rows_per_direction", 1))
		for dir: int in UnitArt.DIRECTIONS:
			var name: StringName = UnitArt.anim_name(anim, dir)
			frames.add_animation(name)
			frames.set_animation_speed(name, float(info["fps"]))
			frames.set_animation_loop(name, bool(info["loop"]))
			for i: int in count:
				var col: int = i % columns
				@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
				var row: int = dir * rows_per_direction + i / columns
				var cell: AtlasTexture = AtlasTexture.new()
				cell.atlas = sheet
				cell.region = Rect2(col * stride + gutter, row * stride + gutter, art.cell_px, art.cell_px)
				frames.add_frame(name, cell)
		var impact: int = int(info.get("impact_frame", -1))
		if impact >= 0:
			art.impact_frames[anim] = impact
		if anim == &"walk":
			art.stride_m = float(info.get("stride_m", 1.0))
	art.frames = frames
	return art
