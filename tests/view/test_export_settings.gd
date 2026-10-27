extends GutTest
## Project settings the exports depend on, which nothing else would catch
## before an export fails.


func test_the_macos_export_has_its_etc2_astc_imports() -> void:
	# Godot 4.7 refuses a universal or arm64 macOS export ("Cannot export for
	# universal or arm64 if ETC2 ASTC texture format is disabled"), although
	# the exported pck carries the S3TC copies only.
	assert_true(ProjectSettings.get_setting("rendering/textures/vram_compression/import_etc2_astc", false))
