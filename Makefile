GODOT ?= godot
MAC_APP := build/mac/Ashenmarch.app

.PHONY: import run test check-sim export-mac

# Builds the .godot/ import and class_name cache. A fresh clone has none, and
# GUT can't resolve class_name types without it.
import:
	$(GODOT) --headless --path . --import

run: import
	$(GODOT) --path .

test: import check-sim
	$(GODOT) --headless -d --path . -s addons/gut/gut_cmdln.gd

check-sim:
	scripts/check_sim_purity.sh

export-mac: import
	mkdir -p $(dir $(MAC_APP))
	$(GODOT) --headless --path . --export-release "macOS" $(MAC_APP)
