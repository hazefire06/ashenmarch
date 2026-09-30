class_name Formations
extends RefCounted
## Formation shapes as target slots for a group of units. This is geometry
## only; SlotAssignment decides which unit takes which slot.
##
## Each shape is built as local (right, forward) offsets in milli-units around
## the click point, then turned into world space with FixedMath.rotate_local,
## so a shape looks the same whichever way the group faces. Row 0 is the
## frontmost row.

## The order is the key order: keys 1..9, 0 select these in turn.
enum Kind {
	SHORT_LINE,
	LONG_LINE,
	LOOSE_LINE,
	STAGGERED_LINE,
	BOX,
	RABBLE,
	SHALLOW_ENCIRCLEMENT,
	DEEP_ENCIRCLEMENT,
	WEDGE,
	CIRCLE,
}

## Short labels for UI buttons, indexed by Kind.
const DISPLAY_NAMES: Array[String] = [
	"Short line", "Long line", "Loose line", "Staggered", "Box",
	"Rabble", "Encircle", "Deep encircle", "Wedge", "Circle",
]

## Air left between the bodies of the two largest units in the group.
const SPACING_GAP: int = 600

## Extra angle bits for arcs and rings. sin_b steps 0.35 degrees, so rounding a
## slot angle to it makes neighbors on a 37-unit arc uneven by up to 10%; with
## these bits the error is under 0.1%.
const FINE_BITS: int = 8
const FINE_FULL: int = FixedMath.ANGLE_FULL << FINE_BITS

## Widest a circle grows before it adds inner rings, in spacings of radius.
const CIRCLE_MAX_RADIUS_SPACINGS: int = 6

## Rabble jitter, in permille of the rabble pitch, either way on each axis.
const RABBLE_JITTER_PERMILLE: int = 300

const LOCAL_FORWARD: Vector2i = Vector2i(0, FixedMath.DIR_ONE)
const NORTH: Vector2i = Vector2i(0, -FixedMath.DIR_ONE)


## Center-to-center distance that keeps bodies of the given radius apart.
static func spacing_for(max_body_radius: int) -> int:
	return 2 * max_body_radius + SPACING_GAP


## Exactly `count` slots for a formation of `kind` centered on the click point
## and facing (facing_x, facing_z), which is normalized here; a zero facing
## means north. Slot order is fixed: front to back, left to right (arcs left to
## right, rings outermost first), so the same input always gives the same
## output.
static func slots(
	kind: Kind,
	count: int,
	center_x: int,
	center_z: int,
	facing_x: int,
	facing_z: int,
	spacing: int
) -> Array[FormationSlot]:
	var result: Array[FormationSlot] = []
	if count <= 0:
		return result
	assert(spacing > 0, "formation spacing must be positive")
	var facing: Vector2i = FixedMath.normalize(facing_x, facing_z, FixedMath.DIR_ONE)
	if facing == Vector2i.ZERO:
		facing = NORTH

	# Local (right, forward) positions, and local facings of length DIR_ONE.
	var offsets: Array[Vector2i] = []
	var dirs: Array[Vector2i] = []
	match kind:
		Kind.SHORT_LINE:
			offsets = _rows(count, (count + 1) / 2, spacing, spacing, 0)
		Kind.LONG_LINE:
			offsets = _rows(count, count, spacing, spacing, 0)
		Kind.LOOSE_LINE:
			offsets = _rows(count, count, spacing * 5 / 2, spacing, 0)
		Kind.STAGGERED_LINE:
			offsets = _rows(count, (count + 1) / 2, spacing, spacing, spacing / 2)
		Kind.BOX:
			offsets = _rows(count, _box_columns(count), spacing, spacing, 0)
		Kind.RABBLE:
			offsets = _rabble(count, spacing)
		Kind.SHALLOW_ENCIRCLEMENT:
			_arc(count, FINE_FULL / 3, spacing, offsets, dirs)
		Kind.DEEP_ENCIRCLEMENT:
			_arc(count, FINE_FULL * 2 / 3, spacing, offsets, dirs)
		Kind.WEDGE:
			offsets = _wedge(count, spacing)
		Kind.CIRCLE:
			_rings(count, spacing, offsets, dirs)
	if dirs.is_empty():
		dirs.resize(count)
		dirs.fill(LOCAL_FORWARD)

	for i: int in count:
		var pos: Vector2i = FixedMath.rotate_local(offsets[i].x, offsets[i].y, facing.x, facing.y)
		var dir: Vector2i = FixedMath.rotate_local(dirs[i].x, dirs[i].y, facing.x, facing.y)
		result.append(FormationSlot.new(center_x + pos.x, center_z + pos.y, dir.x, dir.y))
	return result


## Rows of up to `width` slots, filled front to back. Each row is centered on
## the forward axis, so a short last row sits in the middle. Odd rows shift
## right by `odd_shift`. The block of rows is centered front to back.
static func _rows(
	count: int, width: int, lateral: int, row_pitch: int, odd_shift: int
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var rows: int = (count + width - 1) / width
	for r: int in rows:
		var n: int = mini(width, count - r * width)
		var forward: int = ((rows - 1) * row_pitch) / 2 - r * row_pitch
		var shift: int = odd_shift if r % 2 == 1 else 0
		for c: int in n:
			out.append(Vector2i((2 * c - (n - 1)) * lateral / 2 + shift, forward))
	return out


## Smallest column count whose square holds `count`.
static func _box_columns(count: int) -> int:
	var cols: int = FixedMath.isqrt(count)
	if cols * cols < count:
		cols += 1
	return cols


## Row r holds r + 1 slots and trails the apex by r * spacing, so the apex is
## exactly on the click point.
static func _wedge(count: int, spacing: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var r: int = 0
	while out.size() < count:
		var n: int = mini(r + 1, count - out.size())
		for c: int in n:
			out.append(Vector2i((2 * c - (n - 1)) * spacing / 2, -r * spacing))
		r += 1
	return out


## A loose box at 1.5x pitch with each slot nudged by a hash of its index.
## The hash is pure integer math, so a crowd looks random but replays the same.
static func _rabble(count: int, spacing: int) -> Array[Vector2i]:
	var pitch: int = spacing * 3 / 2
	var out: Array[Vector2i] = _rows(count, _box_columns(count), pitch, pitch, 0)
	for i: int in count:
		var h: int = _jitter_hash(i)
		var jx: int = _jitter_permille(h & 0xFFFF)
		var jz: int = _jitter_permille((h >> 16) & 0xFFFF)
		out[i] += Vector2i(pitch * jx / 1000, pitch * jz / 1000)
	return out


## Integer hash of a slot index into 32 bits. Every intermediate stays under
## 2^63, so it can't overflow.
static func _jitter_hash(index: int) -> int:
	var h: int = ((index + 1) * 0x9E3779B1) & 0xFFFFFFFF
	for _pass: int in 2:
		h = (((h >> 16) ^ h) * 0x45D9F3B) & 0xFFFFFFFF
	return (h >> 16) ^ h


## Maps 0..65535 to -RABBLE_JITTER_PERMILLE..+RABBLE_JITTER_PERMILLE.
static func _jitter_permille(sixteen_bits: int) -> int:
	return sixteen_bits * (2 * RABBLE_JITTER_PERMILLE + 1) / 65536 - RABBLE_JITTER_PERMILLE


## One arc of `span` fine angles, concave toward forward: slots on a circle
## whose center is `radius` in front of the click point, apex at the click
## point, each facing that center. The radius makes neighbors `spacing` apart
## along the arc. An even count has no slot at the apex; the middle pair
## straddles it.
static func _arc(
	count: int, span: int, spacing: int, offsets: Array[Vector2i], dirs: Array[Vector2i]
) -> void:
	if count == 1:
		offsets.append(Vector2i.ZERO)
		dirs.append(LOCAL_FORWARD)
		return
	var radius: int = maxi(
		spacing,
		(count - 1) * spacing * FINE_FULL * 1000 / (span * FixedMath.TWO_PI_MILLI)
	)
	for k: int in count:
		# -span/2 + k*span/(count-1), rounded symmetrically so the two ends
		# mirror each other and an odd count lands exactly on 0 at the apex.
		var phi: int = FixedMath.div_round((2 * k - (count - 1)) * span, 2 * (count - 1))
		var s: int = _sin_fine(phi)
		var c: int = _cos_fine(phi)
		offsets.append(Vector2i(
			FixedMath.div_round(radius * s, FixedMath.TRIG_ONE),
			radius - FixedMath.div_round(radius * c, FixedMath.TRIG_ONE)
		))
		dirs.append(FixedMath.normalize(-s, c, FixedMath.DIR_ONE))


## Hollow concentric rings centered on the click point, each slot facing out.
## Fills from the outermost ring in, so a small group is one ring and a big
## one is a thick wall around an empty middle.
static func _rings(
	count: int, spacing: int, offsets: Array[Vector2i], dirs: Array[Vector2i]
) -> void:
	if count == 1:
		offsets.append(Vector2i.ZERO)
		dirs.append(LOCAL_FORWARD)
		return
	# Radius at which one ring holds everyone, capped so a big group adds inner
	# rings instead of a huge circle, then grown only if the rings can't fit.
	var outer: int = maxi(
		spacing,
		(count * spacing * 1000 + FixedMath.TWO_PI_MILLI - 1) / FixedMath.TWO_PI_MILLI
	)
	outer = mini(outer, CIRCLE_MAX_RADIUS_SPACINGS * spacing)
	while _ring_total_capacity(outer, spacing) < count:
		outer += spacing

	var remaining: int = count
	var ring: int = 0
	var radius: int = outer
	while remaining > 0:
		if radius < spacing:
			# No room for another ring: the last slot goes in the middle.
			offsets.append(Vector2i.ZERO)
			dirs.append(LOCAL_FORWARD)
			remaining -= 1
			break
		var n: int = mini(remaining, _ring_capacity(radius, spacing))
		# Odd rings turn half a step so their slots sit between the ring outside.
		var stagger: int = FINE_FULL / 2 if ring % 2 == 1 else 0
		for i: int in n:
			var theta: int = FixedMath.div_round(i * FINE_FULL + stagger, n)
			var s: int = _sin_fine(theta)
			var c: int = _cos_fine(theta)
			offsets.append(Vector2i(
				FixedMath.div_round(radius * s, FixedMath.TRIG_ONE),
				FixedMath.div_round(radius * c, FixedMath.TRIG_ONE)
			))
			dirs.append(FixedMath.normalize(s, c, FixedMath.DIR_ONE))
		remaining -= n
		radius -= spacing
		ring += 1
	assert(remaining == 0, "ring capacity must cover the count")


## Slots that fit on a ring, `spacing` apart along its circumference.
static func _ring_capacity(radius: int, spacing: int) -> int:
	return maxi(1, radius * FixedMath.TWO_PI_MILLI / (spacing * 1000))


## Everything rings at `outer`, `outer - spacing`, ... (down to one spacing)
## hold, plus one slot in the middle.
static func _ring_total_capacity(outer: int, spacing: int) -> int:
	var total: int = 1
	var radius: int = outer
	while radius >= spacing:
		total += _ring_capacity(radius, spacing)
		radius -= spacing
	return total


## sin_b at FINE_BITS extra bits of angle, by linear interpolation between
## table entries (worst error about 0.3 in TRIG_ONE).
static func _sin_fine(angle_fine: int) -> int:
	var a: int = angle_fine & (FINE_FULL - 1)
	var whole: int = a >> FINE_BITS
	var frac: int = a & ((1 << FINE_BITS) - 1)
	var s0: int = FixedMath.sin_b(whole)
	var s1: int = FixedMath.sin_b(whole + 1)
	return s0 + FixedMath.div_round((s1 - s0) * frac, 1 << FINE_BITS)


static func _cos_fine(angle_fine: int) -> int:
	return _sin_fine(angle_fine + FINE_FULL / 4)
