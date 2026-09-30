class_name AimSolution
extends RefCounted
## A launch that Ballistics found to reach a target point, or a failure.

var ok: bool = false
## Launch velocity, micrometres per tick.
var vx: int = 0
var vy: int = 0
var vz: int = 0
## Ticks of flight until the projectile passes the target's horizontal
## distance, for leading a moving target.
var ticks: int = 0
## How far above (+) or below (-) the target point the flight passes,
## micrometres. Within Ballistics.AIM_REJECT for a solution that is ok.
var miss: int = 0


static func failed() -> AimSolution:
	return AimSolution.new()
