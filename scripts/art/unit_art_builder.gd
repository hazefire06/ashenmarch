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
