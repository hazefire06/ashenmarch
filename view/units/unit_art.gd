class_name UnitArt
extends Resource
## How one unit type looks when it has art: its animations as SpriteFrames,
## and the numbers the view needs to play them. Built by
## scripts/art/build_unit_art.gd from the Blender render and never edited by
## hand. View only; the sim never sees it. A type without a UnitArt keeps its
## placeholder quad.
##
## Animations are named "<anim>_<dir>". dir follows the renderer's
## convention: the unit faces dir * 45 degrees counter-clockwise (seen from
## above) from the camera's horizontal forward, so 0 is seen from behind, 2
## faces screen-left, 4 faces the camera, and 6 faces screen-right.

const DIRECTIONS: int = 8
const STEP: float = TAU / DIRECTIONS
## Every art has idle and walk, die unless the body bursts, and at least one
## strike clip.
const REQUIRED: Array[StringName] = [&"idle", &"walk"]
## A strike: the melee swing, or the release of a shot, a throw or a spell.
const STRIKE_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast"]
## Clips timed to land on a sim tick, so each needs its impact frame.
const TIMED_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast", &"place"]
## Bytes a 4x4 block takes in each block-compressed format the importer can
## write, by Image.Format. Any other format is counted per pixel.
const BLOCK_BYTES: Dictionary[int, int] = {
	Image.FORMAT_DXT1: 8, Image.FORMAT_DXT3: 16, Image.FORMAT_DXT5: 16, Image.FORMAT_BPTC_RGBA: 16,
	Image.FORMAT_ETC: 8, Image.FORMAT_ETC2_RGB8: 8, Image.FORMAT_ETC2_RGBA8: 16, Image.FORMAT_ETC2_RGB8A1: 8,
	Image.FORMAT_ASTC_4x4: 16,
}

@export var unit_id: StringName = &""
@export var frames: SpriteFrames
## Frame where the blow lands or the shot leaves, per strike animation.
@export var impact_frames: Dictionary[StringName, int] = {}
## Meters the walk cycle covers once.
@export var stride_m: float = 1.0
@export var pixels_per_meter: float = 52.0
@export var cell_px: int = 160
## Pixels from the cell's bottom edge to the feet.
@export var feet_px: int = 40
## Meters from the feet to the top of the drawn body (idle, props left out);
## 0 when the render didn't record it. Picking and overlays use it.
@export var figure_height_m: float = 0.0
@export var gib_color: Color = Color.GRAY
## The body becomes gibs instead of a corpse (a Blightbag), so there is no die.
@export var bursts_on_death: bool = false
## The death falls forward rather than backward; the body turns away from the
## blow instead of toward it.
@export var die_falls_forward: bool = false


static func anim_name(anim: StringName, dir: int) -> StringName:
	return StringName("%s_%d" % [anim, dir])


## Which direction's frames show a unit facing `facing` (ground x, z) to a
## camera whose horizontal forward is camera_forward. Any lengths; zero
## vectors give some valid direction rather than NaN.
static func direction_index(facing: Vector2, camera_forward: Vector2) -> int:
	# Counter-clockwise seen from above (+Y) turns +x toward -z, so with .y
	# holding z the signed angle from a to b is atan2(a.y*b.x - a.x*b.y, a.b).
	var a: Vector2 = camera_forward
	var angle: float = atan2(a.y * facing.x - a.x * facing.y, a.dot(facing))
	return posmod(roundi(angle / STEP), DIRECTIONS)


## GPU bytes of a width x height texture in this format, with its mipmaps down
## to 1x1 when mipmaps is set: block formats by their 4x4 blocks, others by
## their bytes per pixel. What the budget check counts per sheet; a driver may
## round or pad.
static func texture_bytes(width: int, height: int, format: Image.Format, mipmaps: bool) -> int:
	var block: int = BLOCK_BYTES.get(format, 0)
	var per_pixel: int = 0
	if block == 0:
		per_pixel = Image.create_empty(1, 1, false, format).get_data().size()
	var total: int = 0
	var w: int = width
	var h: int = height
	while true:
		total += ceili(w / 4.0) * ceili(h / 4.0) * block if block > 0 else w * h * per_pixel
		if not mipmaps or (w == 1 and h == 1):
			break
		w = maxi(1, w >> 1)
		h = maxi(1, h >> 1)
	return total


## GPU bytes of one sheet, from its size and format (texture_bytes). An
## imported sheet (CompressedTexture2D) and an ImageTexture (tests, the pack
## probe) say their format; anything else counts as RGBA8. An imported sheet
## counts its mipmaps: every unit sheet is imported with them, and
## CompressedTexture2D.has_mipmaps() says false in Godot 4.7 regardless.
static func texture_bytes_of(sheet: Texture2D) -> int:
	var format: Image.Format = Image.FORMAT_RGBA8
	var mipmaps: bool = sheet.has_mipmaps()
	if sheet is CompressedTexture2D:
		format = (sheet as CompressedTexture2D).get_format()
		mipmaps = true
	elif sheet is ImageTexture:
		format = (sheet as ImageTexture).get_format()
	return texture_bytes(sheet.get_width(), sheet.get_height(), format, mipmaps)


## Meters per pixel for the sprite.
func pixel_size() -> float:
	return 1.0 / pixels_per_meter


## Offset in pixels that puts the feet on the node's origin (sprite centered).
func feet_offset() -> Vector2:
	return Vector2(0.0, cell_px * 0.5 - feet_px)


func has_anim(anim: StringName) -> bool:
	return frames != null and frames.has_animation(anim_name(anim, 0))


## GPU bytes of every sheet this art's frames are cut from, each counted once.
func sheet_bytes() -> int:
	if frames == null:
		return 0
	var seen: Dictionary[Texture2D, bool] = {}
	var total: int = 0
	for name: String in frames.get_animation_names():
		for i: int in frames.get_frame_count(name):
			var texture: Texture2D = frames.get_frame_texture(name, i)
			var atlas: AtlasTexture = texture as AtlasTexture
			var sheet: Texture2D = atlas.atlas if atlas != null else texture
			if sheet != null and not seen.has(sheet):
				seen[sheet] = true
				total += texture_bytes_of(sheet)
	return total


## Problems that make this art unusable, or an empty array if it is fine.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var who: String = String(unit_id) if unit_id != &"" else resource_path
	if unit_id == &"":
		errors.append("%s: unit_id is empty" % who)
	if frames == null:
		errors.append("%s: no frames" % who)
		return errors
	if pixels_per_meter <= 0.0 or stride_m <= 0.0 or cell_px <= 0:
		errors.append("%s: pixels_per_meter, stride_m and cell_px must be positive" % who)
	var needed: Array[StringName] = REQUIRED.duplicate()
	if not bursts_on_death:
		needed.append(&"die")
	for anim: StringName in needed:
		if not has_anim(anim):
			errors.append("%s: missing %s" % [who, anim])
	if not STRIKE_ANIMS.any(func(strike: StringName) -> bool: return has_anim(strike)):
		errors.append("%s: no strike clip (attack, shoot, throw or cast)" % who)
	for anim: StringName in _anims():
		for dir: int in DIRECTIONS:
			var name: StringName = anim_name(anim, dir)
			if not frames.has_animation(name) or frames.get_frame_count(name) == 0:
				errors.append("%s: %s has no frames for direction %d" % [who, anim, dir])
	for anim: StringName in impact_frames:
		var count: int = frames.get_frame_count(anim_name(anim, 0)) if has_anim(anim) else 0
		var impact: int = impact_frames[anim]
		if impact < 0 or impact >= count:
			errors.append("%s: %s impact frame %d is outside 0..%d" % [who, anim, impact, count - 1])
	for anim: StringName in TIMED_ANIMS:
		if has_anim(anim) and not impact_frames.has(anim):
			errors.append("%s: %s has no impact frame" % [who, anim])
	if figure_height_m < 0.0:
		errors.append("%s: figure_height_m must not be negative, not %s" % [who, figure_height_m])
	return errors


# The animations present, from their "<anim>_<dir>" names.
func _anims() -> Array[StringName]:
	var out: Array[StringName] = []
	for name: String in frames.get_animation_names():
		var anim: StringName = StringName(name.rsplit("_", true, 1)[0])
		if anim not in out:
			out.append(anim)
	return out
