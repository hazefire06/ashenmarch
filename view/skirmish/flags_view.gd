class_name FlagsView
extends Node3D
## The skirmish's flags in the world: a pole, a banner and a ground ring at the
## flag's capture radius, one set per flag the mode puts on the map. Body Count
## has none, King of the Hill only the hill, Capture the Flags all of them
## (shown_flags). The ring and banner are in the color of whoever holds the
## flag (SideColors); the hill's flash between the two sides' colors while both
## are on it. In Capture the Flags a flag being captured is tinted toward the
## capturer, and its banner climbs the pole as the capture progresses
## (progress / capture_ticks) and sits at the top once the flag is owned.
## Reads the World; never writes it. MainView calls after_step() after every
## World.step(). The flash is real time and view-only: it runs in _process and
## no state the sim hashes depends on it. Floats and meters are fine here, this
## is view code.

## Meters: how tall a pole stands, and how thick it is.
const POLE_HEIGHT: float = 4.0
const POLE_THICKNESS: float = 0.14
## The banner's width and height in meters. It hangs from the pole to one side
## and always faces the camera (turning about the vertical axis only), so it
## reads from any angle.
const BANNER_SIZE: Vector2 = Vector2(2.0, 1.2)
## Meters between the ground and the bottom of a banner at the foot of its pole.
const BANNER_CLEARANCE: float = 0.2
## Meters the ring floats above the ground at the flag, clear of z-fighting.
const RING_LIFT: float = 0.15
## The ring's tube radius as a fraction of the flag radius: a thin line.
const RING_TUBE: float = 0.03
const RING_ALPHA: float = 0.6
## Real seconds each side's color shows while the hill is contested.
const CONTEST_FLASH_SECONDS: float = 0.25
const POLE_COLOR: Color = Color(0.36, 0.31, 0.26)

var _world: World
## Per shown flag: its index in the rules (rules.flags is x, z pairs).
var _flags: PackedInt32Array = PackedInt32Array()
var _roots: Array[Node3D] = []
var _banners: Array[MeshInstance3D] = []
var _banner_materials: Array[StandardMaterial3D] = []
var _ring_materials: Array[StandardMaterial3D] = []
var _ratios: PackedFloat32Array = PackedFloat32Array()
## Real seconds since setup, which side's color the contested hill is showing
## follows.
var _clock: float = 0.0


## Builds the flags of this world's skirmish. A world with none (a campaign
## mission, a sandbox) shows nothing. Calling it again replaces the flags.
func setup(world: World) -> void:
	_world = world
	for root: Node3D in _roots:
		remove_child(root)
		root.queue_free()
	_flags = PackedInt32Array()
	_roots.clear()
	_banners.clear()
	_banner_materials.clear()
	_ring_materials.clear()
	_ratios = PackedFloat32Array()
	if world.skirmish == null:
		return
	_flags = shown_flags(world.skirmish.rules)
	for flag: int in _flags:
		_build_flag(world.skirmish.rules, flag)
	_ratios.resize(_flags.size())
	after_step()


## Brings every flag in line with the tick just simulated: its color, and how
## high its banner has climbed.
func after_step() -> void:
	if _world == null or _world.skirmish == null:
		return
	for i: int in _flags.size():
		_apply(i)


## Only the contested hill needs the clock: its color flashes between the sides.
func _process(delta: float) -> void:
	_clock += delta
	if _world == null or _world.skirmish == null or _flags.is_empty():
		return
	if _world.skirmish.rules.mode == SkirmishRules.Mode.KING_OF_THE_HILL:
		if _world.skirmish.hill_holder == SkirmishRuntime.CONTESTED:
			_apply(0)


## How many flags are on show.
func flag_count_shown() -> int:
	return _flags.size()


## The rules index (into SkirmishRules.flags) of the i-th flag on show.
func shown_flag(i: int) -> int:
	return _flags[i]


## The color the i-th flag's banner has now.
func banner_color(i: int) -> Color:
	return _banner_materials[i].albedo_color


## The color the i-th flag's ring has now: the banner's, see-through.
func ring_color(i: int) -> Color:
	return _ring_materials[i].albedo_color


## How far up its pole the i-th banner is: 0 at the foot, 1 at the top.
func banner_height_ratio(i: int) -> float:
	return _ratios[i]


## Meters above the ground at its flag that the i-th banner's center is.
func banner_y(i: int) -> float:
	return _banners[i].position.y


## Where the i-th flag stands (meters): the foot of its pole.
func flag_position(i: int) -> Vector3:
	return _roots[i].position


## The rings' radius in meters, the flags' capture radius.
func ring_radius() -> float:
	return _world.skirmish.rules.flag_radius / float(World.UNITS_PER_METER)


## The flags a mode puts on the map, as indexes into rules.flags: none in Body
## Count, the hill in King of the Hill, every flag in Capture the Flags. The
## overhead map and the scoreboard use the same rule.
static func shown_flags(rules: SkirmishRules) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	match rules.mode:
		SkirmishRules.Mode.KING_OF_THE_HILL:
			out.append(rules.hill)
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			for flag: int in rules.flag_count():
				out.append(flag)
	return out


## Which side's color the contested hill shows `seconds` of real time in: Light
## and Dark in turn, CONTEST_FLASH_SECONDS each.
static func flash_side(seconds: float) -> int:
	if int(seconds / CONTEST_FLASH_SECONDS) % 2 == 0:
		return UnitType.Faction.LIGHT
	return UnitType.Faction.DARK


## The color a flag shows: its holder's (the hill's holder, or a flag's owner),
## neutral for nobody, the color `flash` names for the contested hill, and in
## Capture the Flags tinted toward whoever is capturing it by how far along
## the capture is.
static func flag_color(runtime: SkirmishRuntime, flag: int, flash: int) -> Color:
	var holder: int = SkirmishRuntime.NO_SIDE
	if runtime.rules.mode == SkirmishRules.Mode.KING_OF_THE_HILL:
		holder = flash if runtime.hill_holder == SkirmishRuntime.CONTESTED else runtime.hill_holder
		return SideColors.of(holder)
	holder = runtime.flag_owner[flag]
	var base: Color = SideColors.of(holder)
	if runtime.flag_capture_side[flag] == SkirmishRuntime.NO_SIDE:
		return base
	return base.lerp(SideColors.of(runtime.flag_capture_side[flag]), capture_ratio(runtime, flag))


## How far a capture is, 0 to 1: ticks the capturer has stood alone at the
## flag over the ticks it takes. 0 when nobody is capturing it.
static func capture_ratio(runtime: SkirmishRuntime, flag: int) -> float:
	if runtime.rules.mode != SkirmishRules.Mode.CAPTURE_THE_FLAGS:
		return 0.0
	if runtime.flag_capture_side[flag] == SkirmishRuntime.NO_SIDE:
		return 0.0
	return clampf(float(runtime.flag_progress[flag]) / maxf(runtime.rules.capture_ticks, 1), 0.0, 1.0)


## How high up its pole a flag's banner flies, 0 to 1. The hill's always flies
## at the top. A Capture the Flags flag's does once it is owned; before that it
## climbs with the capture, and rests at the foot when nobody is taking it.
static func banner_ratio(runtime: SkirmishRuntime, flag: int) -> float:
	if runtime.rules.mode == SkirmishRules.Mode.KING_OF_THE_HILL:
		return 1.0
	if runtime.flag_owner[flag] != SkirmishRuntime.NO_SIDE:
		return 1.0
	return capture_ratio(runtime, flag)


# One flag's nodes: the pole, the banner and the ring, at the ground there.
func _build_flag(rules: SkirmishRules, flag: int) -> void:
	var mm: float = float(World.UNITS_PER_METER)
	var x: int = rules.flags[2 * flag]
	var z: int = rules.flags[2 * flag + 1]
	var root: Node3D = Node3D.new()
	root.position = Vector3(x / mm, _world.terrain.height_at(x, z) / mm, z / mm)
	add_child(root)
	_roots.append(root)

	var pole_mesh: BoxMesh = BoxMesh.new()
	pole_mesh.size = Vector3(POLE_THICKNESS, POLE_HEIGHT, POLE_THICKNESS)
	var pole_material: StandardMaterial3D = _material(POLE_COLOR)
	var pole: MeshInstance3D = _instance(pole_mesh, pole_material)
	pole.position.y = POLE_HEIGHT * 0.5
	root.add_child(pole)

	var banner_mesh: QuadMesh = QuadMesh.new()
	banner_mesh.size = BANNER_SIZE
	# The pole is at the banner's left edge, wherever the camera is.
	banner_mesh.center_offset = Vector3(BANNER_SIZE.x * 0.5 + POLE_THICKNESS * 0.5, 0.0, 0.0)
	var banner_material: StandardMaterial3D = _material(SideColors.NEUTRAL)
	banner_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	banner_material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	var banner: MeshInstance3D = _instance(banner_mesh, banner_material)
	root.add_child(banner)
	_banners.append(banner)
	_banner_materials.append(banner_material)

	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 1.0 - 2.0 * RING_TUBE
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 4
	var ring_material: StandardMaterial3D = _material(Color(SideColors.NEUTRAL, RING_ALPHA))
	ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Over the grass and anyone standing on it, like the order markers.
	ring_material.no_depth_test = true
	var ring: MeshInstance3D = _instance(torus, ring_material)
	ring.scale = Vector3.ONE * (rules.flag_radius / mm)
	ring.position.y = RING_LIFT
	root.add_child(ring)
	_ring_materials.append(ring_material)


# Brings the i-th flag's banner and ring in line with the runtime and the flash.
func _apply(i: int) -> void:
	var runtime: SkirmishRuntime = _world.skirmish
	var flag: int = _flags[i]
	var color: Color = flag_color(runtime, flag, flash_side(_clock))
	if _banner_materials[i].albedo_color != color:
		_banner_materials[i].albedo_color = color
		_ring_materials[i].albedo_color = Color(color, RING_ALPHA)
	var ratio: float = banner_ratio(runtime, flag)
	_ratios[i] = ratio
	var bottom: float = BANNER_SIZE.y * 0.5 + BANNER_CLEARANCE
	var top: float = POLE_HEIGHT - BANNER_SIZE.y * 0.5
	_banners[i].position.y = lerpf(bottom, top, ratio)


# Unshaded and flat, so the flags read the same in any light.
static func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material


static func _instance(mesh: Mesh, material: StandardMaterial3D) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance
