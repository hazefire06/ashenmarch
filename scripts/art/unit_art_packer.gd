class_name UnitArtPacker
extends RefCounted
## Packs the renderer's grid sheets (art-src/units/<id>/sheets/): every frame
## trimmed to the part of its cell that holds the figure, then shelf-packed
## into a sheet at most MAX_SHEET px a side. A grid frame's figure fills about
## a quarter of its cell, so a packed sheet takes about a third of its grid's
## GPU memory (docs/specs/2026-10-15-art-a4-loading-design.md §3, §4).
##
## A frame keeps region_in_cell: its used alpha box grown by PAD px, out to
## the cell's 4 px block grid, inside the cell. Every pixel the figure draws is
## kept byte for byte, and every 4x4 DXT block holds the pixels it held in the
## grid. Beside a region the sheet adds transparency only where the cell's
## edge cut the region short (slot_margins), so two figures always lie at least
## 2 * PAD px apart and mipmaps through level 2 never mix them.
##
## The packed sidecar says, per frame, where its region sits in the sheet and
## in the cell. The builder makes each frame an AtlasTexture whose region is
## the first and whose margin puts back the rest of the cell.

const PAD: int = 8
## DXT blocks are 4x4: regions start and end on this grid.
const ALIGN: int = 4
const MAX_SHEET: int = 4096
## A packed sidecar's "layout".
const LAYOUT: String = "packed"
## Grid-only keys a packed sidecar drops.
const GRID_KEYS: Array[String] = ["stride", "gutter"]
const GRID_ANIMATION_KEYS: Array[String] = ["columns", "rows_per_direction"]


## The part of a cell a packed frame keeps, in cell coordinates. used is the
## cell's used alpha box (Image.get_used_rect); a cell with nothing drawn keeps
## one transparent block at its corner.
static func region_in_cell(used: Rect2i, cell: int) -> Rect2i:
	if not used.has_area():
		return Rect2i(0, 0, ALIGN, ALIGN)
	var left: int = _floor_to_block(maxi(used.position.x - PAD, 0))
	var top: int = _floor_to_block(maxi(used.position.y - PAD, 0))
	var right: int = mini(_ceil_to_block(used.end.x + PAD), cell)
	var bottom: int = mini(_ceil_to_block(used.end.y + PAD), cell)
	return Rect2i(left, top, right - left, bottom - top)


## The transparency the sheet adds around a region, as [left, top, right,
## bottom] px: enough that PAD px lie between the figure and its slot's edge on
## every side, rounded up to whole blocks. The region holds them already unless
## the cell's edge cut it short.
static func slot_margins(used: Rect2i, region: Rect2i) -> PackedInt32Array:
	if not used.has_area():
		return PackedInt32Array([0, 0, 0, 0])
	return PackedInt32Array([
		_ceil_to_block(maxi(PAD - (used.position.x - region.position.x), 0)),
		_ceil_to_block(maxi(PAD - (used.position.y - region.position.y), 0)),
		_ceil_to_block(maxi(PAD - (region.end.x - used.end.x), 0)),
		_ceil_to_block(maxi(PAD - (region.end.y - used.end.y), 0)),
	])


## Where each box goes on shelves at most max_width wide: tallest first, then
## widest, then in list order, so the same boxes always pack the same way.
## Boxes whose sides are whole blocks land on whole blocks.
static func shelf_pack(sizes: Array[Vector2i], max_width: int) -> Array[Vector2i]:
	var order: Array[int] = []
	for i: int in sizes.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		if sizes[a].y != sizes[b].y:
			return sizes[a].y > sizes[b].y
		if sizes[a].x != sizes[b].x:
			return sizes[a].x > sizes[b].x
		return a < b
	)
	var positions: Array[Vector2i] = []
	positions.resize(sizes.size())
	var x: int = 0
	var y: int = 0
	var shelf: int = 0
	for i: int in order:
		if x > 0 and x + sizes[i].x > max_width:
			y += shelf
			x = 0
			shelf = 0
		positions[i] = Vector2i(x, y)
		x += sizes[i].x
		shelf = maxi(shelf, sizes[i].y)
	return positions


## The smallest sheet that holds every box at its position.
static func sheet_size(sizes: Array[Vector2i], positions: Array[Vector2i]) -> Vector2i:
	var size: Vector2i = Vector2i.ZERO
	for i: int in sizes.size():
		size = size.max(positions[i] + sizes[i])
	return size


## One animation of a grid sheet, packed: {"image": an RGBA8 Image, "rects":
## per frame, direction-major (frame i of direction d is entry d * frames + i),
## [x, y, w, h, cell_x, cell_y]: the region's place in the sheet, its size,
## and its place in the cell}, or {"error": String} when the sheet would be
## taller than max_sheet. grid holds `frames` frames per direction, columns
## across and rows_per_direction rows each, every cell a gutter inside its
## stride; the caller has checked that layout (layout_errors).
static func pack_animation(
	grid: Image, frames: int, columns: int, rows_per_direction: int, cell: int, stride: int, gutter: int,
	max_sheet: int = MAX_SHEET
) -> Dictionary:
	var source: Image = grid
	if source.get_format() != Image.FORMAT_RGBA8:
		source = grid.duplicate() as Image
		source.convert(Image.FORMAT_RGBA8)
	var origins: Array[Vector2i] = []
	var regions: Array[Rect2i] = []
	var margins: Array[PackedInt32Array] = []
	var slots: Array[Vector2i] = []
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
			var row: int = dir * rows_per_direction + i / columns
			var origin: Vector2i = Vector2i((i % columns) * stride + gutter, row * stride + gutter)
			var used: Rect2i = source.get_region(Rect2i(origin, Vector2i(cell, cell))).get_used_rect()
			var region: Rect2i = region_in_cell(used, cell)
			var margin: PackedInt32Array = slot_margins(used, region)
			origins.append(origin)
			regions.append(region)
			margins.append(margin)
			slots.append(region.size + Vector2i(margin[0] + margin[2], margin[1] + margin[3]))
	var positions: Array[Vector2i] = shelf_pack(slots, max_sheet)
	var size: Vector2i = sheet_size(slots, positions)
	if size.y > max_sheet:
		return {"error": "the packed sheet would be %d px tall, over %d" % [size.y, max_sheet]}
	var image: Image = Image.create_empty(maxi(size.x, ALIGN), maxi(size.y, ALIGN), false, Image.FORMAT_RGBA8)
	var rects: Array = []
	for k: int in regions.size():
		var at: Vector2i = positions[k] + Vector2i(margins[k][0], margins[k][1])
		image.blit_rect(source, Rect2i(origins[k] + regions[k].position, regions[k].size), at)
		rects.append([at.x, at.y, regions[k].size.x, regions[k].size.y, regions[k].position.x, regions[k].position.y])
	return {"image": image, "rects": rects}


## A grid sidecar and its sheets (Images by animation), packed: {"sidecar":
## the packed sidecar, "sheets": Dictionary[StringName, Image], "errors":
## PackedStringArray}. Only the clips the game plays are packed. The packed
## sidecar keeps the grid one's other keys, drops its own (GRID_KEYS,
## GRID_ANIMATION_KEYS), and adds "layout", "pad", and per animation "rects"
## and "sheet_size". The grid sidecar is left as it was. Call it on a sidecar
## that sidecar_errors and layout_errors pass.
static func pack(sidecar: Dictionary, grids: Dictionary) -> Dictionary:
	var packed: Dictionary = sidecar.duplicate(true)
	for key: String in GRID_KEYS:
		packed.erase(key)
	packed["layout"] = LAYOUT
	packed["pad"] = PAD
	var cell: int = int(sidecar["cell"])
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
	var anims: Dictionary = {}
	var sheets: Dictionary[StringName, Image] = {}
	var errors: PackedStringArray = PackedStringArray()
	for key: String in sidecar["animations"]:
		if StringName(key) not in UnitArtBuilder.GAME_ANIMS:
			continue
		var info: Dictionary = (sidecar["animations"][key] as Dictionary).duplicate(true)
		var count: int = int(info["frames"])
		var out: Dictionary = pack_animation(
			grids[StringName(key)], count, int(info.get("columns", count)), int(info.get("rows_per_direction", 1)),
			cell, stride, gutter
		)
		if out.has("error"):
			errors.append("%s: %s" % [key, out["error"]])
			continue
		for grid_key: String in GRID_ANIMATION_KEYS:
			info.erase(grid_key)
		var image: Image = out["image"]
		info["rects"] = out["rects"]
		info["sheet_size"] = [image.get_width(), image.get_height()]
		anims[key] = info
		sheets[StringName(key)] = image
	packed["animations"] = anims
	return {"sidecar": packed, "sheets": sheets, "errors": errors}


static func _floor_to_block(v: int) -> int:
	return v - posmod(v, ALIGN)


static func _ceil_to_block(v: int) -> int:
	return _floor_to_block(v + ALIGN - 1)
