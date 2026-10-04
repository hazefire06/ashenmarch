class_name AtmosphereView
extends RefCounted
## Applies an Atmosphere, a mission's look as data, to the scene that draws it:
## - the WorldEnvironment: the flat background color, the ambient light, and
##   depth fog (exponential; the Compatibility renderer does depth fog but not
##   the volumetric kind);
## - the sun: its color, energy, and rotation from the pitch and yaw;
## - the terrain shader, through TerrainView.set_grade: the ground's tint,
##   desaturation, and per-ground-type recolor, and the water's tint;
## - ash, through PrecipitationView.set_ash, a view-only fall that is
##   independent of the sim's snow.
## It reads the Atmosphere and never changes it, and the sim never sees any of
## it. MainView applies a mission's atmosphere once, after its views are set up.
##
## Applying the Atmosphere defaults reproduces what main.tscn has on its own
## (its sky, ambient light, and sun), so a mission with no atmosphere leaves the
## scene as it is, and `apply(Atmosphere.new())` puts it back.
##
## main.tscn's Environment is local to each scene instance, so applying here
## changes only this scene and never the next one made from the file.

var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _terrain: TerrainView
var _precipitation: PrecipitationView


## The nodes the atmosphere is applied to; any may be null, which skips that
## part (a test of the sky alone needs no terrain).
func _init(
	world_environment: WorldEnvironment, sun: DirectionalLight3D, terrain: TerrainView,
	precipitation: PrecipitationView
) -> void:
	_world_environment = world_environment
	_sun = sun
	_terrain = terrain
	_precipitation = precipitation


## Applies every part of the atmosphere. A null one is skipped, so the scene
## keeps the look it was built with.
func apply(atmosphere: Atmosphere) -> void:
	if atmosphere == null:
		return
	_apply_environment(atmosphere)
	_apply_sun(atmosphere)
	if _terrain != null:
		_terrain.set_grade(
			atmosphere.terrain_tint, atmosphere.terrain_desaturation, atmosphere.ground_recolor,
			atmosphere.water_tint
		)
	if _precipitation != null:
		_precipitation.set_ash(atmosphere.ash_fall, atmosphere.ash_color)


func _apply_environment(atmosphere: Atmosphere) -> void:
	if _world_environment == null:
		return
	var environment: Environment = _world_environment.environment
	if environment == null:
		environment = Environment.new()
		_world_environment.environment = environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = atmosphere.background_color
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = atmosphere.ambient_color
	environment.ambient_light_energy = atmosphere.ambient_energy
	environment.fog_enabled = atmosphere.fog_enabled
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_light_color = atmosphere.fog_color
	environment.fog_density = atmosphere.fog_density


func _apply_sun(atmosphere: Atmosphere) -> void:
	if _sun == null:
		return
	_sun.light_color = atmosphere.sun_color
	_sun.light_energy = atmosphere.sun_energy
	# Pitch about x (below the horizon is negative), yaw about the vertical.
	_sun.rotation_degrees = Vector3(atmosphere.sun_pitch_degrees, atmosphere.sun_yaw_degrees, 0.0)
