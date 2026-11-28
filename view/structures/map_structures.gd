class_name MapStructures
extends Resource
## Every structure a map's generator recorded, saved as structures.tres beside
## the map's height.png. View only.

@export var records: Array[StructureRecord] = []


## The structures beside a heightmap, or null when it has none.
static func load_beside(heightmap_path: String) -> MapStructures:
	var path: String = heightmap_path.get_base_dir().path_join("structures.tres")
	if not ResourceLoader.exists(path):
		return null
	return load(path) as MapStructures


## For every sample a record covers, the ground height under the structure in
## milli-units: a house's base, a wall's sim height minus its own. Where two
## records cover a sample, the later wins.
func view_heights(terrain: Terrain) -> Dictionary[int, int]:
	var result: Dictionary[int, int] = {}
	for record: StructureRecord in records:
		for k: int in record.samples:
			if record.kind == &"wall":
				result[k] = terrain.heights[k] - roundi(record.height_m * 1000.0)
			else:
				result[k] = roundi(record.base_m * 1000.0)
	return result
