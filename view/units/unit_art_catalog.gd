class_name UnitArtCatalog
extends Resource
## Every unit type that has art, as data/art/catalog.tres, rewritten by
## scripts/art/build_unit_art.gd. A type missing here, or whose art fails
## validation, keeps its placeholder quad, so new units work before their
## art exists.

const DEFAULT_PATH: String = "res://data/art/catalog.tres"

@export var arts: Array[UnitArt] = []


func find(unit_id: StringName) -> UnitArt:
	for art: UnitArt in arts:
		if art != null and art.unit_id == unit_id:
			return art
	return null


## Adds art, replacing any for the same unit. Kept sorted by unit id.
func put(art: UnitArt) -> void:
	var kept: Array[UnitArt] = []
	for existing: UnitArt in arts:
		if existing != null and existing.unit_id != art.unit_id:
			kept.append(existing)
	kept.append(art)
	kept.sort_custom(func(a: UnitArt, b: UnitArt) -> bool: return String(a.unit_id) < String(b.unit_id))
	arts = kept


## Why each unusable entry is unusable, for the caller to report.
func invalid_reasons() -> PackedStringArray:
	var reasons: PackedStringArray = PackedStringArray()
	for art: UnitArt in arts:
		if art == null:
			reasons.append("an empty entry")
		else:
			reasons.append_array(art.validate())
	return reasons


## The entries that pass validation.
func without_invalid() -> UnitArtCatalog:
	var usable: UnitArtCatalog = UnitArtCatalog.new()
	for art: UnitArt in arts:
		if art != null and art.validate().is_empty():
			usable.arts.append(art)
	return usable


## The catalog at path, or an empty one when there is none yet or the file
## isn't a catalog. Every unit is then drawn as a placeholder.
static func load_or_new(path: String = DEFAULT_PATH) -> UnitArtCatalog:
	if not ResourceLoader.exists(path):
		return UnitArtCatalog.new()
	var catalog: UnitArtCatalog = load(path) as UnitArtCatalog
	return catalog if catalog != null else UnitArtCatalog.new()
