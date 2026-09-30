GODOT ?= godot
MAC_APP := build/mac/Ashenmarch.app

.PHONY: import run demo test check-sim export-mac maps fixtures

# Builds the .godot/ import and class_name cache. A fresh clone has none, and
# GUT can't resolve class_name types without it.
import:
	$(GODOT) --headless --path . --import

run: import
	$(GODOT) --path .

# Combat showcase: stages each melee rule on Riverside with captions, then
# hands over control. DEMO_SPEED=2 make demo runs it faster.
demo: import
	$(GODOT) --path . -s scripts/demo_combat.gd

test: import check-sim
	$(GODOT) --headless -d --path . -s addons/gut/gut_cmdln.gd

check-sim:
	scripts/check_sim_purity.sh

# Regenerates maps/riverside from scripts/gen_riverside.gd. The output is
# committed; rerun only when the generator changes.
maps: import
	$(GODOT) --headless --path . -s scripts/gen_riverside.gd

# Regenerates the PNG test fixtures with an independent Python encoder.
fixtures:
	python3 tests/fixtures/png/make_png_fixtures.py

export-mac: import
	mkdir -p $(dir $(MAC_APP))
	$(GODOT) --headless --path . --export-release "macOS" $(MAC_APP)
