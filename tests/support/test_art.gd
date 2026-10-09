class_name TestArt
extends RefCounted
## A small UnitArt for view tests, built the way the real one is
## (UnitArtBuilder, from a render sidecar) but from blank sheets, so a test
## pins exactly the frame counts, rates and impact frames it depends on.

const CELL: int = 8
const GUTTER: int = 1
const STRIDE: int = CELL + 2 * GUTTER
const STRIDE_M: float = 1.2


## anims maps an animation name to [frames, fps, loop, impact_frame]. Empty
## gives idle (1 frame), walk (12), attack (6, impact 3) and die (4), all at
## 12 fps. bursts drops the corpse, like a Blightbag.
static func art(unit_id: StringName = &"shieldman", anims: Dictionary = {}, bursts: bool = false) -> UnitArt:
	var side: Dictionary = sidecar(unit_id, anims, bursts)
	return UnitArtBuilder.build(side, sheets(side))


## The sidecar for those animations. Each sheet is one row per direction,
## frames across, until a test adds "columns" and "rows_per_direction" to an
## animation to wrap it.
static func sidecar(unit_id: StringName, anims: Dictionary = {}, bursts: bool = false) -> Dictionary:
	if anims.is_empty():
		anims = {
			"idle": [1, 12, true, -1],
			"walk": [12, 12, true, -1],
			"attack": [6, 12, false, 3],
			"die": [4, 12, false, -1],
		}
	var out: Dictionary = {}
	for anim: String in anims:
		var a: Array = anims[anim]
		out[anim] = {
			"sheet": anim + ".png", "frames": a[0], "fps": a[1], "loop": a[2],
			"impact_frame": a[3], "stride_m": STRIDE_M if anim == "walk" else 0.0,
		}
	return {
		"unit": String(unit_id), "cell": CELL, "gutter": GUTTER, "stride": STRIDE,
		"feet_px": 2, "pixels_per_meter": 4.0, "gib_color": [0.2, 0.4, 0.6],
		"bursts_on_death": bursts, "animations": out,
	}


## Blank sheets the size the sidecar implies: columns wide (the frame count
## when the sidecar gives none) and rows_per_direction rows (1) for each of the
## directions.
static func sheets(side: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for anim: String in side["animations"]:
		var info: Dictionary = side["animations"][anim]
		var columns: int = int(info.get("columns", info["frames"]))
		var rows: int = int(info.get("rows_per_direction", 1))
		var image: Image = Image.create_empty(columns * STRIDE, UnitArt.DIRECTIONS * rows * STRIDE, false, Image.FORMAT_RGBA8)
		out[StringName(anim)] = ImageTexture.create_from_image(image)
	return out
