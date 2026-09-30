class_name MapInfo
extends Resource
## Data-driven map descriptor, saved as maps/<name>/<name>.tres.
## Terrain.load_map() reads the files it names. The numeric fields default to
## 0 (invalid) on purpose: Godot omits default values from .tres files, so a
## non-zero default would let a map's scale change silently if it changed.

@export var display_name: String = ""
## Grayscale PNG, 16-bit (or 8-bit). Raw 0..max maps to 0..max_height.
@export_file("*.png") var heightmap_path: String = ""
## 8-bit RGB or RGBA PNG, same size as the heightmap. Terrain documents the
## channel encoding.
@export_file("*.png") var mask_path: String = ""
## Distance between heightmap samples, in milli-units.
@export var cell_size: int = 0
## Height of the maximum raw heightmap value, in milli-units.
@export var max_height: int = 0
## Steepest slope walking units can stand on, in permille (1000 = 45 degrees).
@export var max_walkable_slope: int = 0
