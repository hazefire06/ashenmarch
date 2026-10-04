# Art and audio track: design

Status: draft for review, 2026-10-01. Decided with Tim in one brainstorming session, section by section.

## 1. Goal

Replace the placeholder quads with pre-rendered 8-direction animated sprites. Add sound effects for every action, voiced barks for the player's units, ambience, and music. Run this as a parallel track that never blocks or conflicts with the numbered phases (Phase 7 AI is in progress).

Success looks like this:

- Every v1 unit is drawn from art: walking, attacking, and dying in 8 directions, correct under the orbiting camera at every zoom.
- A unit with no art still works and looks exactly as it does today. The placeholder pipeline stays.
- Every combat, projectile, and UI event has a sound. The light side talks, and the battlefield has weather, fire, and music.
- `sim/` is untouched. Determinism, the sim purity check, and every existing test are unaffected.

### Non-goals (deferred)

| Item | Waits for |
|---|---|
| Map and environment art: terrain textures, village, mill, gate, props | Phase 8, when The Ford and Old Mill exist |
| Music per mission, chosen by mission data | Phase 8 mission format |
| Volume sliders | Phase 10 settings |
| Checking Web audio and export size | Phase 10 |
| Roster expansion units | After v1 |

## 2. Decisions

| Decision | Why |
|---|---|
| **Pre-rendered 3D sprites, not pixel art** | The camera zooms freely and pitches 35°–65°, so pixel art shimmers at non-integer scales. Pre-rendered sprites scale cleanly with mipmaps, and any unit can be re-rendered (new angle, resolution, lighting) by rerunning a script. |
| **Hybrid generation**: scripted APIs, with Tim choosing by eye | Volume work is scripted and reproducible. The judgment calls (which model, which take) stay human. |
| **Meshy API** for models, rigging and animation; **Blender** (headless) for rendering | Meshy's API covers generation, auto-rigging, and an animation library of 697 presets. Blender guarantees that all 8 directions match, because they are one model rotated. |
| **ElevenLabs API** for SFX and voices. **Music is auditioned on Suno and ElevenLabs Music**, and Tim picks by ear. | ElevenLabs covers SFX and voices from one account (90k credits). Suno is well suited to full songs; it has no official public API, so Tim uses it by hand on suno.com. Udio is out: its downloads have been disabled since 2025-10-29. |
| **The whole light side is one Scots clan** (working name *Clan Cairnbrae*) | Tim's call: a brawling, boastful clan with funny war cries. All names and lines are original, with no Discworld names, lines, or characters (see §8.4). |
| **Art data lives apart from `UnitType`** (`data/art/`, `data/audio/`) | Phase 7 is editing `unit_type.gd` and `data/units/`. Keeping art out of them means no conflicts and no sim changes. |
| **Only owned or CC0 sources** | The repo is public. Sonniss is out: its license v2.0 (2026-08-27) bans supplying its sounds "as sound effects to any other person… modified or re-designed". Paid Meshy output is "customer owned". |

## 3. Structure and isolation

**Worktree.** The track lives in `../ashenmarch-art`, a git worktree beside the main checkout. Run `godot --headless --import` once in it before testing (see the fresh-clone note in `architecture.md`).

**Branches.** These follow the phase rules: plan, GUT tests, PR, squash-merge.

| Branch | Contents | Gate before merge |
|---|---|---|
| `feature/PHASE-A0-art-audio-design` | This spec. The A-track in `docs/prompts.md`. Replace CLAUDE.md's "Do not spend time on art until told to" with a pointer to this spec. `.gitattributes` (LFS), `assets/LICENSES.md`, `.gitignore` additions, gitleaks hook and workflow. | Tim approves this spec |
| `feature/PHASE-A1-unit-sprites` | Meshy script, Blender render script, `UnitArt`, sprite integration. Shieldman only. | **Tim approves the Shieldman contact sheet before any Godot code is written**, then reviews in-engine |
| `feature/PHASE-A2-audio` | Generation and processing scripts, sound bank, `AudioDirector`, ambience, barks, the Shieldman's voice, one music loop | Tim listens to a test build |
| `feature/PHASE-A3-roster` | The other 9 units' art and voices. Assets only; may be several PRs. | A contact sheet per unit |

**What the track may touch:**
- `view/units/unit_sprite.gd` and `view/units/units_view.gd`
- new files under `view/units/` and `view/audio/`
- one line in `view/main.gd` to add the audio node
- `view/units/selection_controller.gd`, for an order-given signal for barks
- `data/art/` and `data/audio/`
- `assets/units/` and `assets/audio/`
- `art-src/` and `audio-src/`
- `scripts/art/` and `scripts/audio/`
- `tests/view/`
- docs

**Never touched:** `sim/`, `data/units/`, `sim/units/unit_type.gd`. The unused `UnitType.sprite` field stays until both tracks have merged; removing it touches sim code. Conflicts expected with Phase 7: `view/main.gd` at most. Whichever branch merges second rebases.

## 4. Repository hygiene and secrets

- **LFS covers `assets/` and `art-src/` and `audio-src/` only.** `maps/*.png` stays plain git: the sim decodes those PNGs itself, and a clone without LFS would break the tests. GitHub Free includes 10 GiB of LFS storage and 10 GiB of bandwidth per month. Note that LFS downloads by forks of a public repo count against the owner's bandwidth.
- **`art-src/` and `audio-src/` each get a `.gdignore`.** Without one, Godot would try to import the FBX, GLB, .blend, and raw audio files in them.
- **`assets/LICENSES.md`** lists every shipped asset: file, source (Meshy, ElevenLabs, Kenney CC0, self-made), date, and the prompt file or task id that made it.
- **Keys** live in `~/.config/ashenmarch/secrets.env` (folder 700, file 600, outside every repo), as `MESHY_API_KEY` and `ELEVENLABS_API_KEY`.
  - Scripts read the file themselves and refuse to run if its permissions are wider than 600. There is no fallback.
  - Claude is denied reading that folder by user-level rules `Read(~/.config/ashenmarch/**)` and `Bash(*.config/ashenmarch*)`. These were added 2026-10-01 and the Bash rule was verified to block.
- **The real limit on spending is on each vendor's side, as a dedicated `ashenmarch` key per vendor:**
  - Meshy: a monthly credit limit, 150 during the Shieldman test and about 700 for the roster.
  - ElevenLabs: a credit quota, and the key restricted to the sound-effects, music, text-to-speech, and voice-design endpoints.
  - Local guards (`plan` dry runs, `--max-credits`, resumable manifests) prevent mistakes. They are not a security control, because Claude writes and runs these scripts.
- **Tim runs every paid command** in Terminal.app. Claude runs the free steps: dry runs, Blender, ffmpeg, Godot builders, tests.
- **Scripts use the Python standard library only** (`urllib.request`). No third-party packages.
- **Manifests keep allowlisted fields only:** task id, prompt, status, credits, timestamps, local paths. Raw API responses and signed URLs (including tokens in URL paths) are never written.
- **Leak backstops:**
  - a gitleaks pre-commit hook with custom rules for `msy_…` and ElevenLabs keys;
  - a gitleaks GitHub Action, since `--no-verify` skips local hooks;
  - GitHub secret scanning and push protection, turned on by Tim (free for public repos).
- **`.gitignore` adds** `.env`, `.env.*`, and `.claude/`.

## 5. Art direction

**Look.**
- Stylized, chunky proportions with hand-painted textures and strong silhouettes that read at about 100 px tall.
- Muted, earthy palette. The light side is warm: tartan reds and greens, steel, woad blue. The dark side is cold: bog brown, bone, a sickly green glow.
- One shared style prompt in `art-src/style.toml` is appended to every unit's prompt, so all ten look like one game.

**Light side: Clan Cairnbrae** (working name, easy to change):

| Unit | Look | Voice and personality |
|---|---|---|
| Shieldman | Kilt, round targe, basket-hilted broadsword, blue woad, wild ginger beard, bonnet | Boastful brawler. Gruff and loud; two voices, older and younger |
| Reaver | Bare-chested berserker with a two-handed claymore and a wild mane (a nod to the Border reivers) | Few words, lots of roaring, manic glee |
| Longbow | Hooded plaid, longbow, quiver; the clan's gamekeeper and poacher | Dry, laconic, deadpan |
| Sapper | Satchel of clinking bottles, singed eyebrows, leather apron; the clan's tinkerer | Excitable, proud of his "brews" and bangs. Slow, like the unit |
| Warden | Herb-wife with a staff and herb pouch | Stern, motherly, scolds the lads. A woman's voice |

**Dark side** (original designs, no voices; non-verbal sounds only):

| Unit | Look |
|---|---|
| Husk | Shambling corpse in rotted peat-bog wrappings |
| Ripper | Gaunt, long-clawed ghoul, hunched and fast |
| Blightbag | Bloated corpse with swollen green gas sacs |
| Drifter | Hooded spectre in trailing robes, bow in hand; the robes hide its legs |
| Stormcaller | Gaunt caster with a crackling, lightning-scarred staff |

## 6. Sprite pipeline (offline)

### 6.1 Meshy: `scripts/art/meshy.py`

```
art-src/style.toml                shared style prompt and palette notes
art-src/units/<id>/spec.toml      prompt, height_m, candidate count and tier, animation ids
art-src/units/<id>/manifest.json  allowlisted fields only; reruns check existing tasks, never re-buy
art-src/units/<id>/               downloaded GLB/FBX and candidate thumbnails (LFS)
```

| Command | Paid | What it does |
|---|---|---|
| `plan <id>` | no | Prints the tasks it would run and their credit cost |
| `candidates <id>` | yes | Text-to-3D previews: mesh only, A-pose, remeshed to about 20–30k triangles. Downloads each candidate's mesh; `make art-candidates` (free, Blender) renders them from the back, left, front and right, at the game camera's angle and true scale, into a candidate sheet. |
| `build <id> --pick N` | yes | Texture (2K), rig (`height_meters` from the unit's height), animate (one request, up to 10 actions). Downloads everything at once, because Meshy links expire after about 3 days. |

**Credits, from Meshy's API pricing:**
- Preview: 20 on `meshy-7.1`, 5 on `meshy-6-lite`.
- Texture: 10. Rig: 5, including basic walk and run. Animation: 3 per action. Custom text-to-motion: 10.
- The Shieldman test (2 lite and 2 `meshy-7.1` candidates) costs about 77. A full roster on lite costs about 600.
- Tim has 1,000 API credits.

**Rigging constraints** (from Meshy's docs):
- Only textured humanoids with clearly defined limbs can be rigged. The model must face +Z and have at most 300k faces.
- The Drifter is designed as a robed humanoid. It has no hover preset, so it gets a procedural bob in Blender, or a 10-credit text-to-motion clip.
- The Blightbag may fail to rig because of its shape. The fallback is rigging in Mixamo (free with an Adobe ID).

**Initial animation picks** (Meshy library ids, final choices made from the contact sheet):

| Unit | Idle | Move | Attack / ranged | Special | Die |
|---|---|---|---|---|---|
| Shieldman | 89 Combat_Stance | rig walk | 219 Right_Hand_Sword_Slash (alt 97) | — | 189 dying_backwards |
| Reaver | 89 | rig run | 237 Charged_Axe_Chop (alt 128) | — | 183 Shot_and_Fall_Backward |
| Longbow | 0 Idle | rig walk | 224 Archery_Shot; melee 97 Left_Slash | fire arrow reuses 224 | 184 Shot_and_Fall_Forward |
| Sapper | 0 | rig walk, slowed | 239 Crouch_Pull_and_Throw (alt 421) | place satchel: 274 | 8 Dead |
| Warden | 0 | rig walk | 219 | heal: 129 mage spell cast | 189 |
| Husk | 0 | 123 Unsteady_Walk (alt 119) | 198 Punch_Combo | idle variant: 386 Zombie_Scream | 187 Knock_Down |
| Ripper | 0 | 16 RunFast | 192 jab | pick up 276, throw 421 | 182 Shot_and_Blown_Back |
| Blightbag | 0 | 119 Slow_Orc_Walk | wind-up: 255 Angry_Ground_Stomp | — | none: it bursts into gibs |
| Drifter | 0 plus bob | bob, legs hidden | 224 | — | 8 |
| Stormcaller | 0 | rig walk | 131 mage spell cast | — | 181 Electrocuted_Fall |

### 6.2 Blender: `scripts/art/render_sprites.py`

This runs headless in Blender 5.2.2 LTS (`/Applications/Blender.app/Contents/MacOS/Blender`, overridable with `$BLENDER`). It is free, and Claude runs it.

- **Camera:** orthographic at a fixed 50° elevation (the middle of the in-game 35–65°), 8 yaw angles 45° apart, feet pinned to a fixed pivot.
- **Lighting is fixed relative to the camera,** so every direction reads the same.
- **Root motion is stripped** so characters animate in place. Walk stride (metres per cycle) is measured and saved.
- **Frames:** 12 fps by default (configurable per clip), 128 px cells with a 4 px transparent gap so mipmaps don't bleed between frames.
- **Output:**
  - one PNG sheet per animation, 8 rows (one per direction), into `assets/units/<id>/`;
  - a JSON sidecar with frame counts, fps, impact frame, stride, figure height in px, and gib colour;
  - the **contact sheet** for Tim's approval.

### 6.3 Godot builder: `scripts/art/build_unit_art.gd`

Run headless. It turns the sheets and sidecar into `data/art/<id>.tres` and rewrites `data/art/catalog.tres`. The catalog is an explicit list, like the unit catalog. These files are generated and never edited by hand.

## 7. Sprites in game

### 7.1 Data

`UnitArt` (`view/units/unit_art.gd`, a Resource, view-only) holds:
- `unit_id` (matches `UnitType.id`);
- `frames: SpriteFrames` with animations named `<anim>_<dir>`, dir 0–7. `idle`, `walk` and `attack` are required. `die` is required unless `bursts_on_death` is set (the Blightbag, whose body becomes gibs). `shoot`, `throw`, `cast` and `place` are optional;
- the impact frame of each attack-type animation;
- `stride_m`, `pixels_per_meter`, `cell_px`, `feet_px` (together these give the sprite's scale and its pivot at the feet), `gib_color`, `die_falls_forward`;
- `validate()`: every required animation has all 8 directions, and impact frames are in range.

### 7.2 Body

`UnitSprite` keeps every overlay as it is: ring, name label, HP bar, status tag, notices. Only the body changes.

- **Choosing the body:** at setup, the unit's id is looked up in the art catalog. If it's found, the body is an `AnimatedSprite3D` billboard. If not, it's today's placeholder quad, with that code unchanged.
- **Fallbacks:** a missing optional animation falls back to `attack`, then `idle`.
- **Debug key:** one key forces every unit back to placeholders.
- **Facing tick:** art units hide the tick on the ground, because the art shows facing.
- **Rendering:**
  - alpha-cutout edges, so overlapping sprites sort correctly;
  - linear filtering with mipmaps;
  - one draw call per unit, enough for Phase 10's 100-unit target. Batching with MultiMesh only if profiling says so.

### 7.3 Direction

Every frame: `posmod(round((facing_angle − camera_yaw) / 45°), 8)`, as a pure static function. The camera orbits continuously, so this runs in `_process`. Hysteresis gets added only if the Shieldman test shows flicker.

### 7.4 Animation from sim state

The view reads the sim after every tick and never writes to it.

| Sim | Animation |
|---|---|
| `MOVING` | `walk`, speed scale = interpolated ground speed ÷ `stride_m`, so wading and slopes slow the legs |
| `IDLE`, or cooldown between blows | `idle` |
| `windup_left` 0 → N (melee, with the `SWING` event) | `attack`, time-stretched so the impact frame lands on the tick the blow lands |
| `aim_left` 0 → N (ranged) | `shoot` / `throw` / `cast`; the release frame lands on the `LAUNCH` tick |
| `act_left` 0 → N (heal, pick up, strike) | `cast` / `place` |
| paralyzed | the current frame freezes (`speed_scale = 0`) |
| `DEAD` | `die` once, facing the source of the killing blow so the body falls away from it; the last frame stays as the corpse |

Timing is recomputed from sim numbers every time, so rebalancing wind-ups and veterancy attack-rate bonuses never desync it.

- **Flashes and status tints** use the sprite's `modulate`, with the same colours as today.
- **Gibs** use `gib_color`.
- **Corpses:** an art corpse stays a billboard, not a quad laid flat. Picking a corpse uses its footprint on the ground.

### 7.5 Tests (GUT, `tests/view/`)

- Direction picking: all 8 sectors, camera yaw offsets, wrap-around.
- State-to-animation mapping, including fallbacks.
- Impact-frame time-stretch: the impact frame lands on the blow tick for several wind-up lengths.
- A missing catalog entry gives a placeholder body; existing placeholder tests pass unchanged.
- `UnitArt.validate()` catches a missing direction, an out-of-range impact frame, and a missing `die` on a unit that doesn't burst.

## 8. Audio

### 8.1 Offline pipeline

```
audio-src/cues.toml            every sound: id, prompt, duration_s, loop, variants (default 3), bus, max_voices, category
audio-src/voices/<unit>.toml   bark lines by trigger, plus the voice description for Voice Design
audio-src/manifest.json        allowlisted fields only; reruns never re-buy
audio-src/raw/                 downloaded originals (LFS)
audio-src/music/inbox/         music Tim downloads from Suno (LFS)
scripts/audio/generate.py      plan (free) | sfx | voices | music   (paid; Tim runs these in Terminal.app)
scripts/audio/process.py       ffmpeg (free; Claude runs it)
assets/audio/                  game-ready: short SFX as mono WAV; loops and music as OGG with loop points
```

**`process.py`:**
- trims silence;
- level-matches within each category, peak-normalising short SFX rather than LUFS-normalising them;
- converts the files;
- writes Godot import settings with loop points.

ElevenLabs returns looping SFX as MP3 only, so loops are converted to OGG.

**Credit budget** (90,000 ElevenLabs credits):

| Item | Estimate |
|---|---|
| SFX, durations set explicitly at 40 credits/s instead of 200 per automatic-length generation | about 20k |
| Voices: 6 designed voices with several takes per line, from text-to-speech at $0.022 per 1,000 characters on v4 at pay-as-you-go rates (credits per character unverified) | about 30k |
| Music auditions on ElevenLabs Music, at 900 credits/min | about 10k |
| Reserve | about 30k |

`plan` prints the estimate before any paid run.

**Music** comes from **Suno** (manual) and ElevenLabs Music, picked by ear:
- **Plan:** Suno Pro is $10/month ($8 billed yearly), with 20 downloads a month and commercial rights on paid downloads. Use Pro, not the free tier: the free tier is non-commercial and capped at 7 downloads in total, and the repo is public.
- **Saving downloads:** audition in the browser and download only the keepers, so the cap isn't spent on rejects. About 10 tracks are needed: a calm and a combat track for each of the 3 maps, a menu theme, and victory and defeat stingers.
- **Instrumental mode.** For a combat version, use Suno's remix tools on the calm track if the plan has them, for a shared theme. Otherwise reuse the same style prompt. Use stems for layering only if Pro can download them; that's unverified.
- **Getting files in:** Tim saves downloads to `audio-src/music/inbox/`. `process.py` makes each track loop seamlessly by crossfading its tail into its head, then converts it to OGG with loop points. Each track gets a row in `LICENSES.md`.

### 8.2 What makes sound

**Melee** (`CombatEvent`):
- `SWING`: a whoosh by weapon class.
- `HIT`: flesh, or a dry undead hit.
- `BLOCK`: shield clang.
- `MISS`: whoosh only.
- `KILL`: a death cry per unit type.
- `HEAL`: herb rustle and chime.

**Projectiles** (`ProjectileEvent`):
- `LAUNCH` per projectile type: bow release, bottle throw, lightning charge.
- `STICK`: thunk, or a splash when `depth > 0`.
- `HIT`: arrow into flesh.
- `BOUNCE`: glass clink, louder with speed.
- `EXPLODE`: small or large by radius, and a separate cue in water.
- `FIZZLE`: hiss. `DROP`: satchel thud. `IGNITE`: whoomp. `PICK_UP`: grab.
- `BOLT`: thunder crack. `CANT_REACH`: UI "no".

**Derived in the view:**
- **Barks** (§8.4) and occasional undead groans, using a view-only RNG.
- **Marching:** a loop that scales with how many units are moving near the camera, switched by ground type (grass, sand, rock, shallow water). It replaces per-unit footsteps.
- **Ambience loops:**
  - rain and snow, crossfading with `Weather` intensity;
  - fire crackle, by burning cells near the camera focus;
  - water near the camera, gas-cloud hiss, and an outdoor background bed.
- **UI:** clicks, selection, formation change, group recall, invalid order.

### 8.3 In game

- **Sound bank:** `data/audio/sound_bank.tres` is generated from `cues.toml`. Each cue is an `AudioStreamRandomizer` (its variants plus pitch and volume jitter), a bus, `max_voices`, and a range.
  - Per-unit-type cues (death cry, barks, weapon class) fall back to generic ones.
  - A missing cue is silent and warns once. That keeps the placeholder pipeline for audio.
- **`AudioDirector`** (`view/audio/audio_director.gd`): `MainView` calls its `after_step()` after every `World.step()`, as it does for `UnitsView`. It turns that tick's events into cues.
- **Voice pool:** a fixed set of about 32 `AudioStreamPlayer3D`.
  - Each cue has a voice cap, so a chain of 5 satchels doesn't stack 5 full-volume blasts.
  - When the pool is full, the oldest or quietest voice is cut first.
  - Sounds beyond range are skipped.
- **The listener** (`AudioListener3D`) sits at the camera's ground focus, not at the camera.
- **No leaks through sound:** a cue that a unit makes plays only if `Visibility.seen_by(world, unit, viewer)` is true, so a Husk in deep water stays silent. Explosions and lightning are always heard.
- **Determinism:** audio never reads or writes `world.rng` and never writes to the sim.
- **Music:**
  - one `AudioStreamInteractive` per map, with a calm clip and a combat clip and crossfades between them;
  - "combat" is triggered by the number of visible units in `ATTACKING`/`SHOOTING`, smoothed with hysteresis;
  - Riverside gets a default track now; choosing music per mission waits for Phase 8.
- **Buses:** Master → Music, SFX, Ambience, Voice, UI, in `default_bus_layout.tres`. **No bus effects**, because Web's default Sample playback doesn't support them.
- **Web:**
  - SFX use Sample playback; music players are set to Stream.
  - Audio starts on the first input (browser autoplay rules).
  - Godot documents positional audio as "may not always work correctly" in Sample mode. That's checked in Phase 10, with a fallback of non-positional players panned by screen position.

### 8.4 Barks (light side)

**Triggers and the code that fires them:**

| Trigger | Fired by |
|---|---|
| select | selection changed |
| move / attack-move / ground attack | `SelectionController` emits an order-given signal |
| formation change | formation key or bar button |
| kill | `KILL` with a viewer-side attacker |
| hurt | HP first drops below 35% |
| death | `KILL` on a viewer-side target |
| clicked too often | the same unit selected 4 or more times within 3 s |
| status | burning, paralyzed or confused begins |
| victory | stub until Phase 8 |

**Rules:**
- One speaker per command: the selected unit nearest the screen centre.
- Lines are a shuffle bag, with no repeats until all have played.
- Each trigger has a cooldown. Kill and hurt barks are limited to about one every 4 s across the whole side.
- **Barks also show as floating text** over the speaker, using the notice label in a bark colour. Barks then work before any audio exists, which is the placeholder pipeline for voice.

**Voices:** ElevenLabs Voice Design creates one designed voice per unit type (two for the Shieldman), described in `audio-src/voices/<unit>.toml`, and that voice is used for every line so it stays consistent.

**Originality rule:**
- The clan is inspired by the "tiny furious Scots clan" archetype and uses real Scots dialect (aye, cannae, skelp, stramash, gie it laldy, crivens).
- No Discworld names, catchphrases, or characters: no "Feegle", "Nac Mac", "Nae king! Nae quin!…", "Wee Free Men", "kelda" or "hag".
- "Crivens" is allowed. It is a Scots exclamation, a corruption of "Christ" (OED), first recorded in print in 1894 (Dictionary of the Scots Language), so it is not Pratchett's coinage.
- Every line is original.

**Clan-wide random line:**
- `audio-src/voices/_clan.toml` holds lines any clan unit may say on any trigger, in its own voice. It starts with **"Crivens!"**.
- About 1 bark in 10 is replaced by a clan-wide line.
- A clan-wide line never plays twice in a row across the whole side, so it stays a surprise.

**Shieldman lines (draft, 35 lines):**

| Trigger | Lines |
|---|---|
| select | "Aye? Whit is it?" · "Point me at somethin' ugly." · "Shield's up, heid's doon. Whit's the plan?" · "Somebody need a wallop?" · "Ah'm listenin'. Make it quick, there's fightin' tae dae." |
| move | "Right ye are!" · "Quick march, ya numpties!" · "Marchin'. Grumblin'. Same thing." · "If it's a trap, ah'm blamin' you." · "Onward! Mind the puddles." |
| attack | "Get intae them!" · "Gie it laldy, lads!" · "Time fer a stramash!" · "Ah'll skelp ye intae next week!" · "Charge! Ach, wait, ah'm already chargin'!" |
| kill | "An' STAY doon!" · "Ye were deid already, ye just didnae ken." · "Is that it? Ah've had fiercer porridge." · "That's one fer the sang!" · "Next!" |
| hurt | "It's just a scratch! A big scratch!" · "Ah've had worse frae ma granny!" · "Warden! Ah need a wee herb!" · "Ah'm fine! Ah'm fine! Ah'm no' fine." |
| death | "Tell ma mither… ah wis braw…" · "Avenge me… or don't, ah'm no' fussy…" · "Ach… no' like this…" |
| clicked too often | "Poke me again an' see whit happens." · "Ah've got a shield, no' a lot o' patience." · "Ye know ah can see ye, aye?" |
| status | burning: "Whit's that smell? Ach, it's me, ah'm on fire!" · paralyzed: "Cannae… move… ma… legs…" · confused: "Which side am ah on again?" |
| formation | rabble: "Rabble? Finally, somethin' we're good at." · wedge: "Pointy end first!" |

**Starting lines for the rest of the clan** (full sets are drafted in A3 and reviewed by Tim):

| Unit | Starting lines |
|---|---|
| Reaver | "Ah've no' had a guid fight since Tuesday!" · "Who wants tae be first?" · "Ah'll split ye like kindlin'!" · lots of roaring |
| Longbow | "Ah see it. It'll no' see me." · "One arrow, one less problem." · fire arrow: "Wan fire arrow. Better be worth it." |
| Sapper | "Mind yer heids, this one's a bit lively!" · "Stand back! Further! Further than that!" · satchel: "Leavin' a wee present." · fizzle: "Ach. Damp." |
| Warden | "Haud still, ya big wean, it's only a herb." · healing undead: "Here's a tonic fer ye. Ye'll no' like it." · "Ah didnae pick herbs all mornin' fer ye tae get stabbed again." |

### 8.5 Tests (GUT, `tests/view/`, headless with a dummy audio driver)

- Event-to-cue mapping, including per-unit-type fallback.
- The voice pool: caps and which voice gets cut first.
- Hidden units stay silent; explosions are always heard.
- The combat-music trigger's hysteresis.
- Weather intensity to ambience loop volumes.
- Bark rules: shuffle bag, cooldowns, choosing the speaker, the clicked-too-often counter, about a 1-in-10 clan-wide line that never repeats back to back.
- Bank validation: every referenced cue exists and has at least one variant; every unit's voice file covers the required triggers.

## 9. Risks and unverified items

| Item | Mitigation |
|---|---|
| One 50° render may look wrong at the 35° and 65° pitch extremes | Contact sheet plus in-engine check on the Shieldman. Fallback: two render elevations blended by pitch, added only if needed. |
| Alpha cutout with mipmaps on the Compatibility renderer | Checked in the Shieldman test |
| Meshy rigging may fail on the Blightbag or Drifter | Design as humanoids; Mixamo fallback |
| Whether credits bought for Meshy's API carry the web plan's "customer owned" license | Low risk for a personal project; recorded in `LICENSES.md` |
| Whether ElevenLabs API calls draw from the 90k account credits; credits per character for speech; pay-as-you-go commercial terms | First cheap call shows it on the usage page; the key's quota caps spend |
| Music quality for orchestral dark fantasy | Audition Suno and ElevenLabs Music side by side; A2 listening gate |
| Suno's monthly download cap (20 on Pro); whether Pro can download stems; whether remixing can make a combat version on a shared theme | Audition in the browser and download only keepers; fall back to the same style prompt; upgrade to Premier (60 downloads a month) only if needed |
| Positional audio on Web in Sample mode | Phase 10 check; screen-pan fallback |
| `AnimatedSprite3D` performance at 300 units on Compatibility | Profile in Phase 10; MultiMesh path if needed |

## 10. Done criteria

- **A0:**
  - this spec approved;
  - prompts.md and CLAUDE.md updated;
  - LFS, `.gdignore`, `LICENSES.md`, `.gitignore`, and gitleaks hook plus workflow in place;
  - PR opened.
- **A1:**
  - Shieldman contact sheet approved;
  - Shieldman renders from art in all states in-engine;
  - placeholders still work for the other 9 units;
  - new GUT tests pass, and the full suite and sim purity check pass;
  - runs on the macOS export.
- **A2:**
  - every event in §8.2 has a cue;
  - Shieldman barks are voiced; ambience and the Riverside music loop play;
  - GUT tests pass;
  - Tim approves a listening build.
- **A3:** every v1 unit has art, and every light-side unit has barks, each with an approved contact sheet or line list.

Each branch gets its own implementation plan. The first plan covers A0 and A1.
