GODOT ?= godot
MAC_APP := build/mac/Ashenmarch.app

.PHONY: import run demo demo-projectiles demo-abilities demo-ai test check-sim export-mac maps fixtures

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

# Projectile showcase: volleys, bounces, grenades rolling back downhill, a
# satchel chain, then control. DEMO_SPEED=2 make demo-projectiles runs faster.
demo-projectiles: import
	$(GODOT) --path . -s scripts/demo_projectiles.gd

# Phase 6 showcase: gas, herbs, lightning, and Rippers scavenging, then
# control. DEMO_SPEED=2 make demo-abilities runs it faster.
demo-abilities: import
	$(GODOT) --path . -s scripts/demo_abilities.gd

# Phase 7 showcase: patrol, ambush, flank, standoff, cluster, retreat, and a
# trigger-driven finale, with the F5 AI overlay on. DEMO_SPEED=2 make demo-ai
# runs it faster; DEMO_STAGE=3 make demo-ai runs one stage alone.
demo-ai: import
	$(GODOT) --path . -s scripts/demo_ai.gd

test: import check-sim
	$(GODOT) --headless -d --path . -s addons/gut/gut_cmdln.gd

check-sim:
	scripts/check_sim_purity.sh

# Regenerates every map from its generator: each scripts/gen_<map>.gd writes
# maps/<map>/ (the shared tool code is scripts/mapgen/map_builder.gd). The
# output is committed; rerun only when a generator changes. A new map's
# generator is picked up by name, with no change here.
maps: import
	for script in scripts/gen_*.gd; do $(GODOT) --headless --path . -s $$script || exit 1; done

# Regenerates the PNG test fixtures with an independent Python encoder.
fixtures:
	python3 tests/fixtures/png/make_png_fixtures.py

export-mac: import
	mkdir -p $(dir $(MAC_APP))
	$(GODOT) --headless --path . --export-release "macOS" $(MAC_APP)
