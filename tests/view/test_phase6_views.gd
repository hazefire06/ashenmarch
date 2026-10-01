extends GutTest
## The Phase 6 drawing: sprites name and tint their status effects and flash
## green when healed; gas clouds get a dome that fades out; lightning leaves
## a short-lived bolt; herb plants wither once struck; loose objects are
## labeled by what they are and can be picked on screen.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _world: World


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), _catalog)


func test_a_sprite_names_its_status_effects() -> void:
	var unit: Unit = _world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 10 * M, 10 * M, 1, 0)
	var view: UnitsView = UnitsView.new()
	add_child_autofree(view)
	view.setup(_world, UnitSelection.new(), null)
	var sprite: UnitSprite = view.sprites()[0]
	assert_eq(sprite.status_text(), "")
	_world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([unit.id]), StatusEffects.Kind.PARALYSIS, 60))
	_world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([unit.id]), StatusEffects.Kind.BURNING, 60))
	_world.step()
	view.after_step()
	assert_eq(sprite.status_text(), "Paralyzed · Burning")
	for _t: int in 60:
		_world.step()
	view.after_step()
	assert_eq(sprite.status_text(), "", "worn off")


func test_a_gas_cloud_gets_a_dome_that_fades_and_goes() -> void:
	var view: GasCloudsView = GasCloudsView.new()
	add_child_autofree(view)
	view.setup(_world)
	var t: ProjectileType = _catalog.find_projectile(&"gas_packet")
	_world.spawn_cloud(10 * M, 0, 10 * M, t, 0)
	view.after_step()
	assert_eq(view.cloud_count(), 1)
	assert_almost_eq(GasCloudsView.alpha_for(t.gas_ticks), GasCloudsView.ALPHA, 0.001, "full while young")
	assert_lt(GasCloudsView.alpha_for(10), GasCloudsView.ALPHA / 2.0, "fading at the end")
	for _tick: int in t.gas_ticks + 1:
		_world.step()
	view.after_step()
	assert_eq(view.cloud_count(), 0)


func test_lightning_leaves_a_bolt_for_a_moment() -> void:
	var view: ExplosionsView = ExplosionsView.new()
	add_child_autofree(view)
	view.setup(_world, null, null)
	var caster: Unit = _world.spawn_unit(_catalog.index_of(&"stormcaller"), DARK, 5 * M, 20 * M, 1, 0)
	Lightning.strike(_world, caster, _catalog.projectile_index_of(&"lightning"), 25 * M, 1000, 20 * M, 40 * M)
	view.after_step()
	assert_eq(view.effect_count(), 2, "the bolt and its flash")


func test_a_struck_herb_plant_withers() -> void:
	var view: HerbPlantsView = HerbPlantsView.new()
	add_child_autofree(view)
	var plant: HerbPlant = _world.spawn_herb_plant(10 * M, 10 * M)
	view.setup(_world)
	assert_eq(view.plant_count(), 1)
	assert_false(view.is_withered(plant.id))
	plant.spent = true
	view.after_step()
	assert_true(view.is_withered(plant.id))


func test_loose_things_are_labeled_by_what_they_are() -> void:
	assert_eq(ProjectilesView.label_for(_catalog.find_projectile(&"satchel")), "Charge")
	assert_eq(ProjectilesView.label_for(_catalog.find_projectile(&"herb")), "Healing herb")
	assert_eq(ProjectilesView.label_for(_catalog.find_projectile(&"gas_packet")), "Gas packet")


func test_a_loose_object_can_be_picked_on_screen() -> void:
	var camera: Camera3D = Camera3D.new()
	add_child_autofree(camera)
	camera.position = Vector3(20.0, 30.0, 20.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.make_current()
	var view: ProjectilesView = ProjectilesView.new()
	add_child_autofree(view)
	var herb: Projectile = _world.drop_object(_catalog.projectile_index_of(&"herb"), 20 * M, 20 * M, 0)
	view.setup(_world)
	view._process(0.0)
	var at: Vector2 = camera.unproject_position(Vector3(20.0, 0.08, 20.0))
	assert_eq(view.object_at(camera, at), herb.id)
	assert_eq(view.object_at(camera, at + Vector2(100.0, 0.0)), -1, "nothing there")
