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
## Every art has these; die too, unless the body bursts.
const REQUIRED: Array[StringName] = [&"idle", &"walk", &"attack"]

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


## Meters per pixel for the sprite.
func pixel_size() -> float:
	return 1.0 / pixels_per_meter


## Offset in pixels that puts the feet on the node's origin (sprite centered).
func feet_offset() -> Vector2:
	return Vector2(0.0, cell_px * 0.5 - feet_px)


func has_anim(anim: StringName) -> bool:
	return frames != null and frames.has_animation(anim_name(anim, 0))


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
	if has_anim(&"attack") and not impact_frames.has(&"attack"):
		errors.append("%s: attack has no impact frame" % who)
	return errors


# The animations present, from their "<anim>_<dir>" names.
func _anims() -> Array[StringName]:
	var out: Array[StringName] = []
	for name: String in frames.get_animation_names():
		var anim: StringName = StringName(name.rsplit("_", true, 1)[0])
		if anim not in out:
			out.append(anim)
	return out
