extends GutTest
## Project settings the exports depend on, which nothing else would catch
## before an export fails.


func test_the_macos_export_has_its_etc2_astc_imports() -> void:
	# Godot 4.7 refuses a universal or arm64 macOS export ("Cannot export for
	# universal or arm64 if ETC2 ASTC texture format is disabled"), although
	# the exported pck carries the S3TC copies only.
	assert_true(ProjectSettings.get_setting("rendering/textures/vram_compression/import_etc2_astc", false))


func test_the_web_audio_settings() -> void:
	# A2's Web measurements (docs/plans/2026-11-10-art-a2-measurements.md): 200 ms of output buffer kept the
	# streamed loops whole under the budget scenario's load (the default is 50).
	assert_eq(ProjectSettings.get_setting("audio/driver/output_latency.web", 0), 200)
	# The 32 kHz reserve lever (spec §4.4, Tim's OK 2026-11-17): Web decodes every sample as stereo float32 at the
	# mix rate, and at the browser's 48 kHz the bought bank with stand-ins came to 315 MB of a 270 MB audio cap.
	# Every SFX, loop and voice is bought at 32 kHz, so only the music's top band is lost.
	assert_eq(ProjectSettings.get_setting("audio/driver/mix_rate.web", 0), 32000)
