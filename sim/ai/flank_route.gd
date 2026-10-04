class_name FlankRoute
extends RefCounted
## The geometry of a flank (AiFlank): whether enemy melee (the screen) stands
## in the way from a group to the unit it is after (the target), and a way
## round the end of it. Static, pure integer 2D math on Vector2i (x, z)
## points in milli-units, so it is tested without a world.
##
## A route is planned in the target's frame: forward d is the way from the
## group to the target (length FixedMath.DIR_ONE), and lateral p is forward
## turned a quarter, (-d.y, d.x); side +1 goes along p, side -1 against it.
## It has two waypoints:
## - W1: SIDE_MARGIN short of the screen's front (its point nearest the
##   group, measured along d) and out past the screen's end on that side by
##   SIDE_MARGIN, so the group comes round the end without brushing it;
## - W2: level with the target, the same distance out to the side, from
##   where the group strikes the target's flank.

## Milli-units from the straight way (group to target) within which a screen
## point counts as standing in it.
const CLEARANCE: int = 6000
## Milli-units a route keeps from the screen: out past its end, and short of
## its front. A group walks it with its center on the line, so its nearest
## member passes the screen's end at this less two body radii and half the
## group's width, edge to edge; that must stay above AiFlank.CONTACT, or the
## approach is found out by the end of the very screen it is rounding and
## strikes across its corner. Equal to CLEARANCE, it leaves 3800 for a box of
## five 0.4 m Rippers (1.4 m half-width) against a CONTACT of 3000.
const SIDE_MARGIN: int = 6000


## Milli-units from p to the nearest point of the segment a-b, floored. The
## products stay inside 64 bits for segments up to about 2 km.
static func distance_to_segment(p: Vector2i, a: Vector2i, b: Vector2i) -> int:
	var dx: int = b.x - a.x
	var dz: int = b.y - a.y
	var length2: int = dx * dx + dz * dz
	var along: int = (p.x - a.x) * dx + (p.y - a.y) * dz
	var cx: int = a.x
	var cz: int = a.y
	if length2 > 0 and along >= length2:
		cx = b.x
		cz = b.y
	elif length2 > 0 and along > 0:
		cx += FixedMath.div_floor(dx * along, length2)
		cz += FixedMath.div_floor(dz * along, length2)
	return FixedMath.length(p.x - cx, p.y - cz)


## True if some screen point is within CLEARANCE of the straight way from
## from to target.
static func blocked(from: Vector2i, target: Vector2i, screen: Array[Vector2i]) -> bool:
	for point: Vector2i in screen:
		if distance_to_segment(point, from, target) <= CLEARANCE:
			return true
	return false


## The route round screen on side (+1 or -1, see the class doc) as
## [w1x, w1z, w2x, w2z]. An empty screen has no front, so W1 is SIDE_MARGIN
## short of the target.
static func route(from: Vector2i, target: Vector2i, screen: Array[Vector2i], side: int) -> PackedInt64Array:
	var d: Vector2i = FixedMath.normalize(target.x - from.x, target.y - from.y, FixedMath.DIR_ONE)
	var p: Vector2i = Vector2i(-d.y, d.x)
	var out: int = lateral_reach(from, target, screen, side)
	var front: int = 0
	for i: int in screen.size():
		var fwd: int = _along(screen[i] - target, d)
		front = fwd if i == 0 else mini(front, fwd)
	var w1_forward: int = front - SIDE_MARGIN
	var w2: Vector2i = Vector2i(
		target.x + FixedMath.div_floor(p.x * side * out, FixedMath.DIR_ONE),
		target.y + FixedMath.div_floor(p.y * side * out, FixedMath.DIR_ONE)
	)
	var w1: Vector2i = Vector2i(
		w2.x + FixedMath.div_floor(d.x * w1_forward, FixedMath.DIR_ONE),
		w2.y + FixedMath.div_floor(d.y * w1_forward, FixedMath.DIR_ONE)
	)
	return PackedInt64Array([w1.x, w1.y, w2.x, w2.y])


## How far out to the side (+1 or -1) a route round screen goes: the
## farthest any screen point stands out on that side of the target (0 if
## none does), plus SIDE_MARGIN. The caller tries the shorter side first.
static func lateral_reach(from: Vector2i, target: Vector2i, screen: Array[Vector2i], side: int) -> int:
	var d: Vector2i = FixedMath.normalize(target.x - from.x, target.y - from.y, FixedMath.DIR_ONE)
	var p: Vector2i = Vector2i(-d.y, d.x)
	var reach: int = 0
	for point: Vector2i in screen:
		reach = maxi(reach, side * _along(point - target, p))
	return reach + SIDE_MARGIN


# Length of v along the unit direction dir (length FixedMath.DIR_ONE),
# floored.
static func _along(v: Vector2i, dir: Vector2i) -> int:
	return FixedMath.div_floor(v.x * dir.x + v.y * dir.y, FixedMath.DIR_ONE)
