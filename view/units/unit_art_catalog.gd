class_name UnitArtCatalog
extends Resource
## Where each unit type's art is: its id to its data/art/<id>.tres, as
## data/art/catalog.tres, rewritten by scripts/art/build_unit_art.gd. It holds
## paths, not the art, so loading it loads no sheets: a game loads only the
## types it can show (UnitArtSet). A type missing here keeps its placeholder
## quad, so new units work before their art exists.

const DEFAULT_PATH: String = "res://data/art/catalog.tres"

@export var paths: Dictionary[StringName, String] = {}


func has(unit_id: StringName) -> bool:
	return paths.has(unit_id)


## The unit's art file, or "" when it has none.
func path_of(unit_id: StringName) -> String:
	return paths.get(unit_id, "")


## Every unit listed, sorted by id.
func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(paths.keys())
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


## Lists unit_id's art at path, replacing any. Kept sorted by id, so the file
## diffs cleanly.
func put(unit_id: StringName, path: String) -> void:
	paths[unit_id] = path
	var sorted: Dictionary[StringName, String] = {}
	for id: StringName in ids():
		sorted[id] = paths[id]
	paths = sorted


## The unit's art, loaded now, or null when it isn't listed or its file isn't
## a UnitArt. The caller validates it.
func load_art(unit_id: StringName) -> UnitArt:
	var path: String = path_of(unit_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as UnitArt


## The catalog at path, or an empty one when there is none yet or the file
## isn't a catalog. Every unit is then drawn as a placeholder.
static func load_or_new(path: String = DEFAULT_PATH) -> UnitArtCatalog:
	if not ResourceLoader.exists(path):
		return UnitArtCatalog.new()
	var catalog: UnitArtCatalog = load(path) as UnitArtCatalog
	return catalog if catalog != null else UnitArtCatalog.new()
