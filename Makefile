GODOT ?= godot
MAC_APP := build/mac/Ashenmarch.app

.PHONY: import run demo demo-projectiles demo-abilities demo-ai test check-sim export-mac maps fixtures playtest skirmish-playtest capture capture-skirmish hooks check-leaks check-layout test-art art-candidates art-render art-attach art-prop-candidates art-build

# Builds the .godot/ import and class_name cache. A fresh clone has none, and
# GUT can't resolve class_name types without it.
import:
	$(GODOT) --headless --path . --import

# The game: the main scene is the App (Phase 8), so this opens the main menu
# (Campaign, Skirmish, Settings, Quit), not a mission. The demos below load the
# sandbox MainView directly and never show the menu.
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

# Skirmish balance playtest: plays skirmishes headless through the real sim and
# prints a line per run, then win/length/loss tables. Matrix A is commander
# against commander (each Light army template against dark_balanced, and
# light_balanced against each Dark one, from both starts); matrix B is a
# playtest pilot as Light against the Dark commander. Settings are environment
# variables, all optional:
#   MATRIX=A,B                            which matrices (default both)
#   MAPS=riverside,the_ford,old_mill      which maps (default all)
#   MODES=body_count,king_of_the_hill,capture_the_flags   which modes (default all)
#   SEEDS=2                               runs per cell (default 2 for A, 5 for B)
#   SEED_BASE=1000                        first world seed; run i uses SEED_BASE+i, so
#                                         SEED_BASE=<seed> SEEDS=1 replays one run
#   BUDGET=1000                           points each army is bought with
#   MINUTES=10                            the skirmish's time limit in game minutes
#   PILOTS=competent,naive                (B) which bots (default both)
#   PAIRINGS=light_balanced:dark_horde,.. (A) <light template>:<dark template> list
#                                         (default 7: each Light vs dark_balanced, and
#                                         light_balanced vs each other Dark)
#   DARK_TEMPLATES=dark_horde,..          (B) the commander's armies (default all four)
#   LIGHT_TEMPLATES=light_siege,..        (B) the pilot's armies (default light_balanced)
#   STARTS=A,B                            the starts Light plays from, each run once per
#                                         start (default: A both; B alternates by seed parity)
#   RAW=runs.jsonl                        write each run as a JSON line as it finishes
#   REPORT=a.jsonl,b.jsonl                merge RAW files into tables instead of playing
#   OUT=tables.md                         write the tables here (Markdown)
#   TRACE=10                              print a status line every 10 game seconds
# e.g. MATRIX=B MAPS=old_mill MODES=king_of_the_hill SEEDS=10 PILOTS=competent make skirmish-playtest
skirmish-playtest: import
	$(GODOT) --headless --path . -s scripts/skirmish_playtest.gd

# Visual check, windowed: launches each mission the way the campaign does and
# saves three screenshots of it (the opening view, the overhead map, and a
# mid-battle frame after the competent playtest pilot has played 90 s of game
# time, stepped as fast as the machine goes) into CAPTURE. The settings are
# environment variables; see the head of scripts/capture_missions.gd:
#   CAPTURE=<dir>   where the PNGs go (required)
#   MISSIONS=...    which missions (default all)   TIER=2   SEED=1000
#   SECONDS=90      game seconds played            FIRST=40 (number of the first file)
# e.g. CAPTURE=shots MISSIONS=old_mill SECONDS=180 make capture
capture: import
	$(GODOT) --path . -s scripts/capture_missions.gd

# Visual check of skirmish, windowed: the setup screen, then per map and mode
# the opening view, the F7 scoreboard, the overhead map, a mid-battle frame and
# the end with its banner, into CAPTURE. See the head of
# scripts/capture_skirmish.gd: CAPTURE=<dir> (required), MAPS, MODES,
# SIDE=light|dark, SEED, SECONDS, FIRST.
# e.g. CAPTURE=shots MAPS=old_mill SIDE=dark make capture-skirmish
capture-skirmish: import
	$(GODOT) --path . -s scripts/capture_skirmish.gd

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

# Installs the leak-scan pre-commit hook into the repo's shared hooks folder.
# It runs in every worktree, and does nothing in a checkout without
# .gitleaks.toml (see scripts/hooks/pre-commit). Refuses to overwrite a
# different hook.
hooks:
	@hooks_dir="$$(git rev-parse --git-common-dir)/hooks"; \
	if [ -e "$$hooks_dir/pre-commit" ] && ! cmp -s scripts/hooks/pre-commit "$$hooks_dir/pre-commit"; then \
		echo "hooks: $$hooks_dir/pre-commit exists and differs; not overwriting it"; exit 1; \
	fi; \
	cp scripts/hooks/pre-commit "$$hooks_dir/pre-commit"; \
	chmod +x "$$hooks_dir/pre-commit"; \
	echo "hooks: installed $$hooks_dir/pre-commit"
	git lfs install --local

check-layout:
	scripts/check_asset_layout.sh

check-leaks:
	scripts/check_leak_rules.sh

BLENDER ?= /Applications/Blender.app/Contents/MacOS/Blender
BLENDER_RUN = $(BLENDER) -b --factory-startup --python-exit-code 1

# Python and Blender tests for the art pipeline (scripts/art/). Not part of
# `make test`, so the game's tests never need Blender.
test-art:
	python3 -m unittest discover -s scripts/art -p "test_*.py"
	$(BLENDER_RUN) --python scripts/art/blender_test_render.py

# Renders UNIT's Meshy candidates into art-src/units/UNIT/review/candidates.png (free).
art-candidates:
	$(BLENDER_RUN) --python scripts/art/render_sprites.py -- $(UNIT) --candidates

# Renders UNIT's animations into assets/units/UNIT/ plus its review sheets (free).
art-render:
	$(BLENDER_RUN) --python scripts/art/render_sprites.py -- $(UNIT)

# Renders UNIT's idle and attacks with its props into art-src/units/UNIT/review/attach.png,
# for tuning the [[attach]] offsets and rotations by eye (free).
art-attach:
	$(BLENDER_RUN) --python scripts/art/render_sprites.py -- $(UNIT) --attach

# Renders PROP's Meshy candidates into art-src/props/PROP/review/candidates.png (free).
art-prop-candidates:
	$(BLENDER_RUN) --python scripts/art/render_sprites.py -- $(PROP) --prop-candidates

# Builds data/art/UNIT.tres from the render and lists it in data/art/catalog.tres.
art-build: import
	$(GODOT) --headless --path . -s scripts/art/build_unit_art.gd -- $(UNIT)
