class_name MapInfo
extends Resource
## Data-driven map descriptor, saved as maps/<name>/<name>.tres.
## Terrain.load_map() reads the files it names.

@export var display_name: String = ""
## Grayscale PNG, 16-bit (or 8-bit). Raw 0..max maps to 0..max_height.
@export_file("*.png") var heightmap_path: String = ""
## 8-bit RGB or RGBA PNG, same size as the heightmap. Terrain documents the
## channel encoding.
@export_file("*.png") var mask_path: String = ""
## Distance between heightmap samples, in milli-units.
@export var cell_size: int = 1000
## Height of the maximum raw heightmap value, in milli-units.
@export var max_height: int = 40000
## Steepest slope walking units can stand on, in permille (1000 = 45 degrees).
@export var max_walkable_slope: int = 1000
