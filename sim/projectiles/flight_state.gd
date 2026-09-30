class_name FlightState
extends RefCounted
## Position and velocity of a flying object at micrometre precision, and the
## one integrator every projectile path goes through: the live flight, the
## aiming solver, and the clear-path check all call advance(), so an aim
## solved here is exactly the flight that happens.
##
## Micrometres because milli-units are too coarse for drag: a grenade loses
## well under 1 mm/tick per tick to the air, which would round to nothing.
## Positions are micrometres, velocities micrometres per tick; to_mm() gives
## the milli-unit coordinates everything else in the sim uses.
##
## advance() is semi-implicit Euler: gravity and drag change the velocity,
## then the position moves by the new velocity. Magnitudes stay far inside
## 64 bits: a 90 m/s velocity is 3e6 um/tick, and the largest product (drag,
## v * |v| * ppm) is under 1e18 even at 100000 ppm/m.

## Micrometres per milli-unit.
const SUB: int = 1000
## 9.81 m/s^2 in micrometres per tick per tick at 30 ticks/s: exactly
## 9_810_000 / 900.
const GRAVITY: int = 10_900
## drag_ppm_per_m * |v| (um/tick) / DRAG_DIVISOR is the share of speed lost
## this tick: ppm is 1e6, and a metre is 1e6 um.
const DRAG_DIVISOR: int = 1_000_000 * 1_000_000

var px: int
var py: int
var pz: int
var vx: int
var vy: int
var vz: int


func _init(
	pos_x: int = 0, pos_y: int = 0, pos_z: int = 0, vel_x: int = 0, vel_y: int = 0, vel_z: int = 0
) -> void:
	px = pos_x
	py = pos_y
	pz = pos_z
	vx = vel_x
	vy = vel_y
	vz = vel_z


## A flight state at milli-unit position (x, y, z) with velocity in um/tick.
static func at_mm(x: int, y: int, z: int, vel_x: int, vel_y: int, vel_z: int) -> FlightState:
	return FlightState.new(x * SUB, y * SUB, z * SUB, vel_x, vel_y, vel_z)


## Milli-units per second to micrometres per tick.
static func speed_from_mm_per_s(mm_per_s: int) -> int:
	return FixedMath.div_round(mm_per_s * SUB, World.TICK_RATE)


## Micrometres to milli-units, floored (heights under a crater and positions
## off the map edge can be negative).
static func to_mm(micrometres: int) -> int:
	return FixedMath.div_floor(micrometres, SUB)


## One tick of free flight: gravity, then quadratic drag against the new
## velocity, then move.
func advance(drag_ppm_per_m: int) -> void:
	vy -= GRAVITY
	if drag_ppm_per_m > 0:
		var magnitude: int = FixedMath.isqrt(vx * vx + vy * vy + vz * vz)
		var k: int = magnitude * drag_ppm_per_m
		vx -= FixedMath.div_round(vx * k, DRAG_DIVISOR)
		vy -= FixedMath.div_round(vy * k, DRAG_DIVISOR)
		vz -= FixedMath.div_round(vz * k, DRAG_DIVISOR)
	px += vx
	py += vy
	pz += vz


func speed() -> int:
	return FixedMath.isqrt(vx * vx + vy * vy + vz * vz)


func copy() -> FlightState:
	return FlightState.new(px, py, pz, vx, vy, vz)


func hash_fields() -> PackedInt64Array:
	return PackedInt64Array([px, py, pz, vx, vy, vz])
