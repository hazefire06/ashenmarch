#!/usr/bin/env bash
# Checks the layout rules in docs/specs/2026-10-01-art-audio-design.md §4: LFS
# covers only assets/, art-src/ and audio-src/; maps/ stays plain git (the sim
# decodes those PNGs itself); Godot skips the source folders; local secrets
# and Claude's folder stay out of git.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

lfs() { [[ "$(git check-attr filter -- "$1" | awk '{print $NF}')" == "lfs" ]]; }
expect_lfs() { if lfs "$1"; then echo "ok: $1 in LFS"; else echo "FAIL: $1 should be in LFS"; fail=1; fi; }
expect_plain() { if lfs "$1"; then echo "FAIL: $1 must stay plain git"; fail=1; else echo "ok: $1 plain"; fi; }
expect_ignored() { if git check-ignore -q "$1"; then echo "ok: $1 ignored"; else echo "FAIL: $1 should be ignored"; fail=1; fi; }
expect_file() { if [[ -f "$1" ]]; then echo "ok: $1"; else echo "FAIL: $1 missing"; fail=1; fi; }

expect_lfs assets/units/shieldman/walk.png
expect_lfs assets/audio/sfx/hit_1.wav
expect_lfs assets/audio/music/riverside_calm.ogg
expect_lfs art-src/units/shieldman/model/rigged.glb
expect_lfs art-src/units/shieldman/review/contact.png
expect_lfs art-src/units/shieldman/review/walk.gif
expect_lfs audio-src/raw/hit_1.mp3
expect_plain maps/riverside/height.png
expect_plain assets/units/shieldman/walk.png.import
expect_plain art-src/units/shieldman/spec.toml
expect_plain art-src/units/shieldman/manifest.json
expect_file art-src/.gdignore
expect_file audio-src/.gdignore
expect_file assets/LICENSES.md
expect_ignored .env
expect_ignored .env.local
expect_ignored .claude/settings.local.json
exit $fail
