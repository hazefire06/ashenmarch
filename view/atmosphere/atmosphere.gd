class_name Atmosphere
extends Resource
## A mission's look as plain data, one .tres per look: the sky, the light, the
## fog, how the ground and water are tinted, and the ash that falls. It holds
## no Nodes and the sim never reads it: the view applies it, and a MissionDef
## carries one the way a UnitType carries its placeholder_color.
##
## Defaults are the pastoral daytime look main.tscn had before missions chose
## their own (its sky, ambient light, and sun), so a mission with no atmosphere
## looks as it always did. Several defaults are therefore not zero, on purpose,
## and Godot leaves a value equal to its default out of a .tres, so changing
## one here would change every mission that relies on it. The neutral values
## (white tint, no desaturation, no recolor, no blend, no ash) make a mission's
## own file list only what it changes.

@export_group("Sky and light")
## The flat color behind the world.
@export var background_color: Color = Color(0.52, 0.6, 0.68, 1.0)
## The color of the light that falls on everything alike.
@export var ambient_color: Color = Color(0.75, 0.75, 0.8, 1.0)
## How much of that ambient light there is. At least 0.
@export var ambient_energy: float = 0.5
## The color of the sun's light.
@export var sun_color: Color = Color(1.0, 1.0, 1.0, 1.0)
## How bright the sun is. At least 0; 0 is no sun.
@export var sun_energy: float = 1.0
## The sun's DirectionalLight3D rotation in degrees, as rotation_degrees.x:
## how far below the horizon it shines (-90 straight down, 0 along the ground;
## main.tscn's sun is -30). Validated to -90..0.
@export var sun_pitch_degrees: float = -30.0
## The sun's rotation about the vertical, as rotation_degrees.y (main.tscn's sun
## is -30).
@export var sun_yaw_degrees: float = -30.0

@export_group("Fog")
## Whether there is fog at all.
@export var fog_enabled: bool = false
## The color the world fades to in the distance.
@export var fog_color: Color = Color(0.7, 0.75, 0.8, 1.0)
## Godot's exponential fog density (0.01 is a light haze). At least 0.
@export var fog_density: float = 0.01

@export_group("Ground and water")
## Multiplied into the terrain's color: white leaves it as it is.
@export var terrain_tint: Color = Color(1.0, 1.0, 1.0, 1.0)
## 0 keeps the terrain's colors, 1 drains them to gray.
@export var terrain_desaturation: float = 0.0
## A color to blend over each ground type, indexed by Terrain.Ground; its alpha
## is how much (0 none, 1 replaces). Empty means no recolor; otherwise there
## is one entry per ground type (Terrain.GROUND_COUNT).
@export var ground_recolor: Array[Color] = []
## A color to blend over water; its alpha is how much. Alpha 0 (the default)
## leaves the water alone.
@export var water_tint: Color = Color(0.1, 0.2, 0.3, 0.0)

@export_group("Ash")
## How thick the falling ash is, 0 (none) to 1 (a storm of it). Particles
## only: it changes nothing in the sim.
@export var ash_fall: float = 0.0
## The color of the falling ash.
@export var ash_color: Color = Color(0.25, 0.23, 0.22, 1.0)


## Problems that make the atmosphere unusable, or an empty array if it is
## valid. Every one is listed. Each field is read by name in code, not looked up
## by a string, so a renamed field is a parse error here rather than a check
## that quietly passes.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if ambient_energy < 0.0:
		errors.append("ambient_energy must be >= 0")
	if sun_energy < 0.0:
		errors.append("sun_energy must be >= 0")
	if fog_density < 0.0:
		errors.append("fog_density must be >= 0")
	if terrain_desaturation < 0.0 or terrain_desaturation > 1.0:
		errors.append("terrain_desaturation must be 0..1")
	if ash_fall < 0.0 or ash_fall > 1.0:
		errors.append("ash_fall must be 0..1")
	if sun_pitch_degrees < -90.0 or sun_pitch_degrees > 0.0:
		errors.append("sun_pitch_degrees must be -90..0 (the sun shines down)")
	if water_tint.a < 0.0 or water_tint.a > 1.0:
		errors.append("water_tint's alpha (how much it blends) must be 0..1")
	if not ground_recolor.is_empty():
		if ground_recolor.size() != Terrain.GROUND_COUNT:
			errors.append(
				"ground_recolor needs 0 or %d colors (one per ground type), not %d"
				% [Terrain.GROUND_COUNT, ground_recolor.size()]
			)
		else:
			for i: int in ground_recolor.size():
				if ground_recolor[i].a < 0.0 or ground_recolor[i].a > 1.0:
					errors.append("ground_recolor[%d]'s alpha (how much it blends) must be 0..1" % i)
	return errors
