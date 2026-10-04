GODOT ?= godot
MAC_APP := build/mac/Ashenmarch.app

.PHONY: import run demo demo-projectiles demo-abilities demo-ai test check-sim export-mac maps fixtures playtest

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

# Balance playtest: a bot plays the campaign headless through the real sim and
# prints a line per run, then win/length/loss tables. Settings are environment
# variables, all optional:
#   MISSIONS=riverside,the_ford,old_mill  which missions (default all)
#   TIERS=2                               difficulty tiers 0..4 (default 2, the middle)
#   SEEDS=20                              runs per mission, tier and pilot
#   SEED_BASE=1000                        first campaign seed; run i uses SEED_BASE+i, so
#                                         SEED_BASE=<seed> SEEDS=1 replays one run
#   PILOTS=competent,naive                which bots (default both)
#   CHAIN=1                               play the whole campaign per seed, survivors
#                                         carrying over (default 0: fresh recruits)
#   MAX_MINUTES=25                        game minutes before a run counts as a timeout
#   OUT=tables.md                         write the tables here (Markdown)
#   TRACE=10                              print a status line every 10 game seconds
#   RAW=runs.jsonl                        write each run as a JSON line as it finishes
#   REPORT=a.jsonl,b.jsonl                merge RAW files into tables instead of playing
# e.g. MISSIONS=old_mill TIERS=0,2,4 SEEDS=10 PILOTS=competent make playtest
playtest: import
	$(GODOT) --headless --path . -s scripts/playtest.gd

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
