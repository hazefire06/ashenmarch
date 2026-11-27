class_name MapTrails
extends Resource
## Every trail a map's generator recorded, saved as trails.tres beside the
## map's height.png. View only.

@export var records: Array[TrailRecord] = []


## The trails beside a heightmap, or null when it has none.
static func load_beside(heightmap_path: String) -> MapTrails:
	var path: String = heightmap_path.get_base_dir().path_join("trails.tres")
	if not ResourceLoader.exists(path):
		return null
	return load(path) as MapTrails
