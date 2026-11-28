class_name TrailRecord
extends Resource
## One worn route a map generator recorded (A5): a path people walk, such as
## the road to a building or the way to a ford, kept beside the map so the view
## can wear the grass down to dirt along it. View only: the sim never loads
## this, and recording one changes no sample of the map.

## The centre line, metres. One point is a worn disc (a yard or a square).
@export var points_m: PackedVector2Array = PackedVector2Array()
## Metres across the worn ground. TrailMask draws two wheel ruts on a trail at
## least TrailMask.RUT_MIN_WIDTH_M wide.
@export var width_m: float = 2.0
## Whether the wear fades out over the trail's last metres at each end (a
## path running out into the grass). A disc, or a trail ending under another,
## has no ends to fade.
@export var fade_ends: bool = true
