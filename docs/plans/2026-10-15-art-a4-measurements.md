# A4 measurements

Raw `BUDGET` lines from the budget check (`view/budget/budget_run.gd`). Before is `main` at 46ab149 plus the check; after is this branch. All runs are on the M4 Max.

## Before

- editor, macOS arm64: `BUDGET video=576 textures=563 static=130 art=554 types=10 art_load=483 ticks=1800 seconds=60 on=macos`
- release app, macOS arm64: `BUDGET video=576 textures=563 static=0 art=554 types=10 art_load=178 ticks=1800 seconds=60 on=macos`
- Web, Chrome (`scripts/serve_web.py`, no compression): `BUDGET tab=1330 limit=1000 FAIL js_wasm=719 (measured) video=611 textures=584 art=554 types=10 art_load=443 pck=558 wire=558 s3tc=yes ticks=1800 seconds=61 on=web`

## After (2026-10-27)

- editor, macOS arm64: `BUDGET video=159 textures=147 static=130 art=138 types=10 art_load=348 ticks=1800 seconds=60 on=macos`
- release app, macOS arm64: `BUDGET video=159 textures=147 static=0 art=138 types=10 art_load=72 ticks=1800 seconds=60 on=macos`
- Web, Chrome (`scripts/serve_web.py`, no compression): `BUDGET tab=374 limit=1000 PASS js_wasm=183 (measured) video=191 textures=168 art=138 types=10 art_load=98 pck=142 wire=142 s3tc=yes ticks=1800 seconds=63 on=web`

Other numbers after:
- Web and macOS pck 141.7 MB (gzip 39.4 MB); Windows exe 250.9 MB with the pck embedded. Each carries S3TC only, with no `art-src` file and no unit sidecar.
- Riverside in campaign: `unit art: 6 types, 78.8 MB of sheets, loaded in 233 ms` (the editor's `make capture` run).
- `make verify-replays`: the four goldens are OK, with the same final hashes as `main`.
- `make art-probe` over the ten units: `cases=270 close_bad=0 far_bad=171 aabb_bad=0`.
- Safari and Firefox weren't measured (see the plan's ledger).

A release build reports `static=0`: it doesn't track static memory.
