# A4 measurements

Raw `BUDGET` lines from the budget check (`view/budget/budget_run.gd`). Before is `main` at 46ab149 plus the check; after is this branch. All runs are on the M4 Max.

## Before

- editor, macOS arm64: `BUDGET video=576 textures=563 static=130 art=554 types=10 art_load=483 ticks=1800 seconds=60 on=macos`
- release app, macOS arm64: `BUDGET video=576 textures=563 static=0 art=554 types=10 art_load=178 ticks=1800 seconds=60 on=macos`
- Web, Chrome (`scripts/serve_web.py`, no compression): `BUDGET tab=1330 limit=1000 FAIL js_wasm=719 (measured) video=611 textures=584 art=554 types=10 art_load=443 pck=558 wire=558 s3tc=yes ticks=1800 seconds=61 on=web`

A release build reports `static=0`: it doesn't track static memory.
