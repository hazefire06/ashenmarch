extends SceneTree
## Proves packed frames draw as the grid ones do (docs/specs/2026-10-15-art-a4-loading-design.md
## §8, step 2). Windowed, since headless has nothing to read back:
## `make art-probe` (UNITS=a,b for some units, OUT=<dir> to save pairs).
##
## For each unit with a grid render (art-src/units/<unit>/sheets/, or before
## A4's move assets/units/<unit>/), it packs the grid in memory with
## UnitArtPacker and draws chosen frames twice, set up as UnitSprite sets up an
## art body: once cut from the grid, once from the packed sheet (region plus
## margin). Both sheets are uncompressed ImageTextures with mipmaps, so only
## the packing differs. Each pair is drawn from the closest, the opening and
## the farthest camera distance and compared (Image.compute_image_metrics).
## One line each:
##   PROBE <unit> <anim>_<dir> frame=<i> d=<m> max=<0..255> mean=<x> differing=<px>/<figure px> aabb=<inside|OUTSIDE>
## then PROBE SUMMARY cases=<n> close_bad=<n> far_bad=<n> aabb_bad=<n>. Exit
## status 1 if a close case has more than CLOSE_SHARE of its figure's pixels
## differing by more than TOLERANCE, or a packed frame's box reaches outside
## its grid cell's (it is smaller by design: the packed quad covers only the
## region). A pixel or two at the figure's alpha-cut edge may flip on the
## packed quad's float rounding; a misplaced or miscut frame differs across
## most of the figure.
## Far differences are for a person to judge: OUT saves every pair over
## TOLERANCE, and one close pair per unit, side by side. CONTROL=1 compares
## the grid with itself moved 4 px in its sheet instead of with the pack: the
## differences any change of a frame's place in a sheet brings, since mipmaps
## average fixed squares of the sheet.

const DISTANCES: Array[float] = [RtsCamera.MIN_DISTANCE, MainView.CAMERA_START_DISTANCE, RtsCamera.MAX_DISTANCE]
const PITCH_DEG: float = 50.0
const SIZE: int = 1024
## The largest channel difference, of 255, still counted as the same pixel.
const TOLERANCE: float = 2.0
## The share of a close case's figure that may differ: edge pixels flipping
## on rounding, never a misplaced frame.
const CLOSE_SHARE: float = 0.001
const PROBE_ANIMS: Array[StringName] = [&"idle", &"walk", &"attack", &"shoot", &"throw", &"cast", &"place", &"die"]
const PROBE_DIRS: Array[int] = [1, 4]

var _viewport: SubViewport
var _camera: Camera3D
var _sprite: AnimatedSprite3D
var _out: String = OS.get_environment("OUT")
var _control: bool = OS.get_environment("CONTROL") == "1"
var _cases: int = 0
var _close_bad: int = 0
var _far_bad: int = 0
var _aabb_bad: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_build_stage()
	if not _out.is_empty():
		DirAccess.make_dir_recursive_absolute(_out)
	for unit: String in _units():
		await _probe_unit(unit)
	print("PROBE SUMMARY cases=%d close_bad=%d far_bad=%d aabb_bad=%d" % [_cases, _close_bad, _far_bad, _aabb_bad])
	quit(1 if _close_bad > 0 or _aabb_bad > 0 else 0)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_viewport.add_child(_camera)
	_sprite = AnimatedSprite3D.new()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_viewport.add_child(_sprite)


func _units() -> PackedStringArray:
	var asked: String = OS.get_environment("UNITS").strip_edges()
	if not asked.is_empty():
		return asked.split(",", false)
	var out: PackedStringArray = PackedStringArray()
	for unit: String in DirAccess.get_directories_at("res://art-src/units"):
		if not _grid_folder(unit).is_empty():
			out.append(unit)
	return out


# Where the unit's grid render is: art-src once A4 has moved it, else assets
# while its sidecar there is still a grid one.
func _grid_folder(unit: String) -> String:
	var moved: String = "res://art-src/units/%s/sheets/" % unit
	if FileAccess.file_exists(moved + unit + ".json"):
		return moved
	var old: String = "res://assets/units/%s/" % unit
	if FileAccess.file_exists(old + unit + ".json"):
		var side: Variant = JSON.parse_string(FileAccess.get_file_as_string(old + unit + ".json"))
		if side is Dictionary and not (side as Dictionary).has("layout"):
			return old
	return ""


func _probe_unit(unit: String) -> void:
	if not UnitArtPacker.is_unit_name(unit):
		print("PROBE %s SKIPPED not a unit name" % unit.c_escape())
		return
	var folder: String = _grid_folder(unit)
	if folder.is_empty():
		print("PROBE %s SKIPPED no grid render" % unit)
		return
	var links: PackedStringArray = UnitArtPacker.planted_links(PackedStringArray([folder]))
	if not links.is_empty():
		print("PROBE %s SKIPPED a symlink: %s" % [unit, ", ".join(links)])
		return
	var sidecar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder + unit + ".json"))
	var bad: PackedStringArray = UnitArtPacker.sidecar_errors(sidecar)
	if not bad.is_empty():
		print("PROBE %s SKIPPED its sidecar is unsound: %s" % [unit, "; ".join(bad)])
		return
	var grids: Dictionary = {}
	for key: String in sidecar["animations"]:
		if StringName(key) in UnitArtBuilder.GAME_ANIMS:
			var path: String = ProjectSettings.globalize_path(folder + String(sidecar["animations"][key]["sheet"]))
			grids[StringName(key)] = Image.load_from_file(path)
	var packed: Dictionary = UnitArtPacker.pack(sidecar, grids)
	var cell: int = int(sidecar["cell"])
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
	_sprite.pixel_size = 1.0 / float(sidecar["pixels_per_meter"])
	_sprite.offset = Vector2(0.0, cell * 0.5 - int(sidecar["feet_px"]))
	var saved_close: bool = false
	for anim: StringName in PROBE_ANIMS:
		if not grids.has(anim):
			continue
		var info: Dictionary = sidecar["animations"][String(anim)]
		var count: int = int(info["frames"])
		var columns: int = int(info.get("columns", count))
		var rows: int = int(info.get("rows_per_direction", 1))
		var grid_sheet: ImageTexture = _mipmapped(grids[anim])
		var packed_sheet: ImageTexture = _mipmapped(packed["sheets"][anim])
		var shifted_sheet: ImageTexture = _mipmapped(_shifted(grids[anim], 4)) if _control else null
		var rects: Array = packed["sidecar"]["animations"][String(anim)]["rects"]
		var frame: int = _probe_frame(anim, info)
		for dir: int in PROBE_DIRS:
			@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
			var row: int = dir * rows + frame / columns
			var from_grid: AtlasTexture = AtlasTexture.new()
			from_grid.atlas = grid_sheet
			from_grid.region = Rect2((frame % columns) * stride + gutter, row * stride + gutter, cell, cell)
			var r: Array = rects[dir * count + frame]
			var from_pack: AtlasTexture = AtlasTexture.new()
			from_pack.atlas = packed_sheet
			from_pack.region = Rect2(r[0], r[1], r[2], r[3])
			from_pack.margin = Rect2(r[4], r[5], cell - int(r[2]), cell - int(r[3]))
			if _control:
				from_pack = AtlasTexture.new()
				from_pack.atlas = shifted_sheet
				from_pack.region = Rect2(from_grid.region.position + Vector2(4.0, 4.0), from_grid.region.size)
			for d: float in DISTANCES:
				_aim(d)
				var a: Image = await _draw(from_grid)
				var aabb_a: AABB = _sprite.get_aabb()
				var b: Image = await _draw(from_pack)
				var aabb_b: AABB = _sprite.get_aabb()
				var metrics: Dictionary = a.compute_image_metrics(b, false)
				var worst: float = float(metrics["max"])
				var counts: Vector2i = _differing(a, b) if worst > TOLERANCE else Vector2i(0, -1)
				# A packed frame's quad covers only its region, so its box is smaller by
				# design; it must lie inside the whole cell's.
				var same_box: bool = aabb_a.grow(0.001).encloses(aabb_b)
				_cases += 1
				var close: bool = is_equal_approx(d, DISTANCES[0])
				if worst > TOLERANCE:
					if not close:
						_far_bad += 1
					elif counts.x > CLOSE_SHARE * counts.y:
						_close_bad += 1
				if not same_box:
					_aabb_bad += 1
				print("PROBE %s %s_%d frame=%d d=%.0f max=%.0f mean=%.4f differing=%d/%d aabb=%s" % [
					unit, anim, dir, frame, d, worst, float(metrics["mean"]), counts.x, counts.y,
					"inside" if same_box else "OUTSIDE",
				])
				if not _out.is_empty() and (worst > TOLERANCE or (close and not saved_close)):
					saved_close = saved_close or close
					_save_pair(a, b, "%s-%s_%d-d%.0f.png" % [unit, anim, dir, d])


# The frame a probe looks at: the middle of an idle, a third into a walk, a
# corpse, and a strike's impact.
func _probe_frame(anim: StringName, info: Dictionary) -> int:
	var count: int = int(info["frames"])
	match anim:
		&"walk":
			@warning_ignore("integer_division") # A frame index: floor on purpose.
			return count / 3
		&"die":
			return count - 1
		&"idle":
			@warning_ignore("integer_division") # A frame index: floor on purpose.
			return count / 2
	var impact: int = int(info.get("impact_frame", -1))
	@warning_ignore("integer_division") # A frame index: floor on purpose.
	return impact if impact >= 0 else count / 2


# The sheet as the importer makes it, short of the DXT compression: its
# transparent pixels' colour filled in from the figure (process/fix_alpha_border),
# then mipmapped.
func _mipmapped(image: Image) -> ImageTexture:
	var copy: Image = image.duplicate() as Image
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	copy.fix_alpha_edges()
	copy.generate_mipmaps()
	return ImageTexture.create_from_image(copy)


# (pixels of a and b that differ by more than TOLERANCE, pixels of the figure
# in a): the figure is every pixel unlike the background in the corner.
func _differing(a: Image, b: Image) -> Vector2i:
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	var step: int = 4 if a.get_format() == Image.FORMAT_RGBA8 else 3
	var limit: int = roundi(TOLERANCE)
	var differing: int = 0
	var figure: int = 0
	for i: int in range(0, da.size(), step):
		if da[i] != da[0] or da[i + 1] != da[1] or da[i + 2] != da[2]:
			figure += 1
		if absi(da[i] - db[i]) > limit or absi(da[i + 1] - db[i + 1]) > limit or absi(da[i + 2] - db[i + 2]) > limit:
			differing += 1
	return Vector2i(differing, figure)


# The grid moved by `by` px right and down in a sheet that much bigger (CONTROL).
func _shifted(grid: Image, by: int) -> Image:
	var moved: Image = Image.create_empty(grid.get_width() + by, grid.get_height() + by, false, Image.FORMAT_RGBA8)
	var source: Image = grid.duplicate() as Image
	source.convert(Image.FORMAT_RGBA8)
	moved.blit_rect(source, Rect2i(Vector2i.ZERO, source.get_size()), Vector2i(by, by))
	return moved


# The camera at distance d, pitched as a mission's, looking at the figure's middle.
func _aim(d: float) -> void:
	var target: Vector3 = Vector3(0.0, 0.7, 0.0)
	var pitch: float = deg_to_rad(PITCH_DEG)
	_camera.position = target + Vector3(0.0, sin(pitch), cos(pitch)) * d
	_camera.look_at(target)


func _draw(texture: Texture2D) -> Image:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.add_frame(&"default", texture)
	_sprite.sprite_frames = frames
	_sprite.animation = &"default"
	_sprite.frame = 0
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


func _save_pair(a: Image, b: Image, file: String) -> void:
	var pair: Image = Image.create_empty(SIZE * 2, SIZE, false, a.get_format())
	pair.blit_rect(a, Rect2i(Vector2i.ZERO, a.get_size()), Vector2i.ZERO)
	pair.blit_rect(b, Rect2i(Vector2i.ZERO, b.get_size()), Vector2i(SIZE, 0))
	pair.save_png(_out.path_join(file))
