# Art track A2: audio

Status: approved 2026-11-10. Brainstormed with Tim from 2026-10-27 to 2026-11-09, part by part. Branch `feature/PHASE-A2-audio`, worktree `~/Projects/ashenmarch-a2`, from `main` at fe9722d.

This spec replaces §8 of `2026-10-01-art-audio-design.md` wherever the two differ. Some parts of the earlier spec still hold where this one says nothing new:
- §4: repository hygiene and secrets.
- §8.4: the trigger list, the Shieldman's 35 draft lines, the starting lines for the rest of the clan, the originality rule and the clan-wide line.

In this spec, "Tim's call" marks Tim's decisions. "Claude's call" marks a default Claude chose that Tim can overturn in review. "Forced" marks a constraint of Godot 4.7.2 or a vendor.

## 1. Goal

Replace Phase 10's 16 placeholder sounds with a real sound bank, and make the light side talk. Give the battlefield ambience and Riverside its music. All of it fits the Web memory budget A4 set up.

Success looks like this:

- **Every event in §6 has a cue.** Melee, projectiles, deaths, UI, marching and ambience each have a sound chosen by Tim, at an audition.
- **The clan talks.** Barks show as text over the speaker for all five light-side units, and all five are voiced. The gate's listening build comes once the Shieldman is voiced. The PR stays open until the other four are voiced too, and A2 merges with all five (Tim's call).
- **Riverside has music.** A calm layer and a combat layer crossfade as the fighting rises and falls.
- **No leaks through sound.** A unit hidden from you makes no sound. Explosions and lightning are always heard.
- **The Web build fits.** Audio uses at most **270 MB** of tab memory in the worst case, measured by the budget check, and its share is reported.
- **Nothing else moves.** `sim/` and `data/units/` are untouched. `make verify-replays` matches `main`, and GUT passes.

### What comes after A2

The queue Tim set: the dwarf's sim size, then better world textures. World textures get whatever Web memory audio leaves unused (§4.1).

### Non-goals

| Item | Why |
|---|---|
| Music for The Ford, Old Mill, skirmish and the menus, plus victory and defeat stingers | A2 makes one music loop, for Riverside. Other launches play Riverside's music (§7.4), and later tracks are data |
| Voices for the dark side | The undead don't talk. They get a death cry per type and occasional groans |
| Barks for the villager | It isn't a clan unit and can't be ordered |
| Bus effects (reverb, filters) | Forced: Web's Sample playback ignores them |
| A darker outdoor bed per mission as the campaign darkens | One outdoor bed for now. A per-mission bed is a data change later |
| Snow underfoot in the marching sound | No v1 mission has snow on the ground |
| Upgrading to Godot 4.8 for its Web audio fixes | 4.8's fix (PR #123996) isn't released. A2 works around 4.7.2 |
| Mobile Web | As in A4 |

## 2. What changes from §8

| §8 said | A2 does | Why |
|---|---|---|
| A new `AudioDirector` | Extend Phase 10's `SfxPlayer`, `Ambience` and `UiSounds`, and add `Barks` and `Music` beside them | Tim's prompt. The existing nodes can carry it (§7) |
| `AudioStreamRandomizer` per cue | `SfxPlayer` picks the variant and jitters the pitch itself, as it already does | Forced: meta streams can't be sampled on Web, and fall back to mixing on the main thread, which garbles single-threaded Web audio (§4.2) |
| `AudioStreamInteractive` for music | Two plain looping players that crossfade | Forced, for the same reason |
| Buses Master → Music, SFX, Ambience, Voice, UI | Keep Phase 10's Effects, Ambient and Interface. Add **Music** and **Voice**, each with a slider | The existing names are in saved settings. Claude's call |
| A 32-voice pool | Keep 24 SFX voices, and add 3 voices for barks | Each Web voice costs main-thread messages (§4.2). Claude's call |
| Victory bark: a stub until Phase 8 | A real bark, fired by the mission's or skirmish's WON | Phase 8 is done |
| An order-given signal (to add) | `order_given` exists but carries nothing. It gains the ordered ids and the order kind | Code fact |
| Music from Suno or ElevenLabs Music | ElevenLabs Music first. Buy a month of Suno Pro only if it doesn't satisfy Tim. The combat layer is generated fresh, never remixed | Cost, and Suno's Remix clause (§5.3) |
| Positional audio on Web checked "in Phase 10" | Checked by ear in A2's Web step (§11, step 2) | Never done |

## 3. Sound direction (Tim's call)

- **Grounded and gritty:** heavy steel, wet hits, and real weight in the blasts.
- **Comedy only in the barks.** The effects are never cartoonish.
- **The undead** sound dry, rasping and wrong, not like monster roars. *(Claude's call.)*
- **One shared style suffix** goes on every SFX prompt in `cues.toml`, the way `art-src/style.toml` keeps the unit art consistent. *(Claude's call.)*
- **Riverside's music** has two layers in the same key and tempo:
  - Calm: sparse and brooding, with low strings or a drone, a frame drum, and a lone fiddle or pipes for the clan.
  - Combat: heavier drums and more urgency, with no Hollywood orchestra.

## 4. The Web budget

### 4.1 The cap (Tim's call)

Audio gets at most **270 MB** of the Web tab's memory, in A4's worst-case launch: an AI-against-AI skirmish on Old Mill with every type, after 60 s. A4 measured 374 MB of the 1,000 MB limit, which leaves 626 MB. The cap is a ceiling, not a reservation: any room audio doesn't use passes to world textures.

### 4.2 How Godot 4.7.2 holds sound on Web (forced)

The facts below come from reading the 4.7.2-stable source; none was observed running. The Web export is single-threaded and plays sounds as Web Audio samples by default.

- **Decoded size.** A sound is decoded into the browser as stereo float32 at the browser's own rate: `mix_rate.web` is 0, so the browser chooses, usually 48 kHz. That costs **about 0.38 MB per second of audio**, whatever the file. Mono, a low source rate and compression save nothing once a sound is decoded.
- **Registration.** A sound is decoded on its first `play()`, or ahead of time with `AudioServer.register_stream_as_sample()`. It is **never released** in 4.7.2 (upstream issue #106098). A stream object that is freed and loaded again registers a second time.
- **Every play copies the whole buffer** while it plays (#124856).
- **Loop points are ignored.** A looping sample restarts from the top on a browser event, so a gap at the seam is likely, and its pitch resets on the second and later passes (#123786).
- **Meta streams aren't sampled.** `AudioStreamRandomizer`, `Interactive`, `Synchronized` and `Playlist` fall back silently to Godot's own mixing on the main thread.
- **Stream mode, which A2 uses for loops (§4.3),** mixes on the main thread into a ring buffer sized by `audio/driver/output_latency.web`, which defaults to 50 ms (about 43 ms of buffer). A main-thread stall longer than that drops audio.
- **3D samples** pan by per-channel gains, which the engine pushes on each physics tick. That has three consequences:
  - A 3D voice may start silent for up to one tick.
  - Attenuation filters and doppler don't apply.
  - Bus volume and mute work. `max_polyphony` works.
- **Each playing voice** costs Web Audio nodes, and a position worklet that messages the main thread about 375 times a second.
- **Desktop is unaffected.** It mixes normally, and none of this applies.

### 4.3 What A2 does about it

1. **One stream object per sound, kept for the session.** The bank is one resource, loaded once and never freed, so no sound registers twice. *(Claude's call.)*
2. **One-shots are registered at mission load** on Web: SFX, UI and barks, for the types the launch can bring on (`MissionLaunch.unit_types()`) plus the shared cues. Nothing decodes mid-battle, and the worst-case launch (every type) registers everything. *(Claude's call. The approach Tim heard was "decode everything at load"; registering per launch keeps the worst case the same and spreads the load time.)*
3. **Every loop streams; every one-shot is a sample.**
   - Loops are the beds, the marching loops and the music. Their players are set to `PLAYBACK_TYPE_STREAM`, so they cost no decoded memory and loop seamlessly through Godot's own mixer.
   - `output_latency.web` is raised for them; start at 200 ms and measure (§11, step 2). Latency doesn't matter for beds and music, and samples don't use that buffer.
   - **If streams drop out under heavy ticks (the main risk), step 2 becomes a decision point with Tim before any spend.** A stall drops every loop, not just the music. Turning all 12 loops into samples costs about 46 MB for the beds and marching loops and 34 to 46 MB for shortened music. That's roughly 330 MB, over the cap, and a sampled loop may also gap at its seam. Claude brings Tim the measured options:
     - beds and marching stay streamed, with their dropouts accepted, and the music becomes shortened samples (about 45 to 60 s a layer);
     - every loop becomes a sample, with shorter beds and the 32 kHz lever;
     - a threaded Web export, which moves mixing off the main thread but reopens Tim's single-threaded decision (`serve_web.py` already sends COOP/COEP).

     Each player takes its playback type from one setting per category, so whichever option is chosen is a configuration change, not a rewrite. *(Claude's call.)*
4. **No meta streams anywhere.**
5. **Reserve lever:** force `audio/driver/mix_rate.web` to 32000, which cuts decoded memory by a third, about 70 MB here. It's used only if needed, and only with Tim's OK.

### 4.4 Estimate

The counts come from §6's cue list and §8's bark counts. Decoded sizes assume a 48 kHz browser.

| Content | Seconds | Web memory |
|---|---|---|
| SFX one-shots: 54 cues, mostly 3 variants | ~175 decoded | ~67 MB |
| Barks: ~192 recordings | ~345 decoded | ~133 MB |
| Loops: 6 beds, 4 marching loops, 2 music layers | streamed | 0 decoded |
| Compressed files, held twice: the resident pck, then the loaded resources | — | ~25 MB |
| Per-play copies: the allowance in §4.5, every voice playing its longest sound | — | up to ~20 MB |
| **Total** | | **~245 MB of 270** |

**If the measured figure is over the cap,** the levers apply in this order:
1. Tighter trims.
2. Two variants instead of three on rarely heard cues.
3. Shorter or fewer bark lines, never lower quality *(Claude's call)*.
4. The 32 kHz reserve lever, with Tim's OK.

### 4.5 The budget check

A4's check (`view/budget/budget_run.gd`, `?budget=1`) gains audio fields. The exact field names are the builder's call; the line must carry:
- **audio:** the computed total, the decoded part (Σ registered seconds × mix rate × 8 bytes) and the files part;
- **the mix rate** the browser chose;
- **audio_load:** the registration time at mission load, in ms;
- **desktop:** the files part and the load time.

**What is held to the 270 MB cap** *(Claude's call)*. The cap applies to the computed audio total: decoded, plus files, plus a per-play allowance. The allowance is the decoded size of the 27 longest one-shot variants, as if every SFX and bark voice were playing its longest sound at once. The audio figure gets its own PASS or FAIL against 270, beside the tab verdict against 1,000. The with/without difference measured in Chrome is recorded at step 2 and at the final run as a cross-check, not as the verdict.

**Unvoiced lines** *(Claude's call)*. A budget run made while some bark lines have no voice yet registers stand-in audio (silence) of each unvoiced line's estimated length. Every gate run therefore measures the finished bank.

**The with/without experiment.** It isn't known whether Chrome's `measureUserAgentSpecificMemory` counts decoded AudioBuffers. A `?budget=1&audio=0` run skips registration and one-shot playback. The two runs use the same build, with synthetic test audio large enough to see (§11, step 2).
- **If Chrome counts decoded audio:** the measured tab figure already includes it.
- **If it doesn't:** the verdict adds the computed decoded figure to `tab`, and the line says so. A FAIL can never hide behind memory Chrome doesn't report.

Measured in Chrome on this Mac through the chrome-devtools MCP. Only a `measured` line has a verdict. The PR reports audio's share.

## 5. Sources and vendors

### 5.1 ElevenLabs (Tim's plan: Starter)

These facts were checked on 2026-11-05 and 2026-11-09 against elevenlabs.io docs, partly through a summarizer, so treat them as medium confidence.

- **Key.** A dedicated `ashenmarch` key, set up by Tim:
  - **Scope restriction:** sound effects, text to speech, voice design, and music. Saving a designed voice may also need voices write access, which is unconfirmed.
  - **Credit quota:** set to the next batch's estimate and raised batch by batch. This is the real spending control. The script's guards prevent mistakes, but Claude writes and runs that script, so they aren't a security boundary.
- **Formats** (settled by the probes on 2026-11-16, §11 step 5):
  - Sound effects, loops and voices download as `wav_32000`. The SFX probe was accepted on Starter. `audio-src/format.txt` can switch them to `mp3_44100_128`, and nothing needs it.
  - Music downloads as `mp3_48000_192`, whatever `format.txt` says. `/v1/music` has no WAV format: `wav_32000` got an HTTP 422, and the docs list only MP3, PCM, Opus and μ-law/A-law. `mp3_48000_192` is the API's own default for `music_v2`, it matches the 48 kHz mix, and the music probe was accepted on Starter. A music batch refuses to buy until that probe has succeeded.
  - 32 kHz keeps everything up to 16 kHz with no MP3 artifacts on sharp hits. Music's MP3 is encoded once more, to Ogg; at 192 kbps under a game mix that isn't heard.
  - On Web, the rate costs nothing: every sound is resampled to the browser's rate.
- **Sound effects:**
  - `POST /v1/sound-generation`, with `text`, `duration_seconds` (0.5 to 30), `prompt_influence`, `loop` and `model_id`. The model is `eleven_text_to_sound_v2` or `_v3`, and v3 makes sounds that loop.
  - 40 credits a second with a set duration (confirmed).
- **Voices:**
  - `POST /v1/text-to-voice/design` returns previews as base64 audio, each with a `generated_voice_id`. `POST /v1/text-to-voice` saves the chosen one, using a voice slot (Starter has 10, and A2 needs 6).
  - Speech uses `eleven_v4` or `eleven_v4_turbo`, both launched 28 Sep 2026. Both take audio tags such as `[laughs]` and `[shouting]`.
  - API price: $0.08 and $0.04 per 1,000 characters. In credits: "1 credit per character, depending on model", with no per-model figure published.
- **Music:**
  - `POST /v1/music`, with `prompt`, `music_length_ms` (3 s to 10 min), `force_instrumental` and `model_id` (`music_v1`, `music_v2` or `music_v2_5`). A `composition_plan` can replace the prompt.
  - 900 credits a minute. There is no loop option, so `process.py` makes the loop.
- **Terms.**
  - Paid plans grant commercial use with no attribution. Indie games aren't "Studio Games".
  - Starter bars music "streaming distribution", which Claude reads as releasing to streaming services; the definition is unconfirmed.
  - Pay-as-you-go means prepaid top-ups from $5, expiring after 12 months.
- **Unresolved:** whether API calls draw on Tim's credits or bill in dollars; the docs contradict each other. The probe and the usage page settle it.

### 5.2 Credits

Tim had a 90,000-credit balance on 2026-11-09, and 73,000 available on 2026-11-16, after the probes. Starter adds about 30,000 a month. The rates below are assumed and flagged; `generate.py plan` prints each batch's estimate before anything is bought.

| Batch | Basis | Credits |
|---|---|---|
| Probe | one 1 s SFX | 40 |
| SFX one-shots | 54 cues, about 2 takes per variant kept, ~350 s at 40/s | ~14k |
| Loops | 10 loops × 2 takes × 12 s at 40/s | ~10k |
| Voice design | 6 voices, about 2 rounds of previews each | unknown, flagged |
| v4 against v4 Turbo A/B test | ~6 lines × 2 models × 2 takes | <1k |
| Barks | ~192 recordings × 3 takes × ~30 characters at 1 credit/character | ~17k (v4 may cost more per character) |
| Music | 2 layers × 3 takes × ~110 s at 900/min | ~10k |
| **Total** | | **~52k, plus voice design** |

### 5.3 Suno (fallback only)

Checked on 2026-11-05 (medium confidence):
- **Price:** Pro is $10 a month, or $8 a month billed yearly.
- **Downloads:** 20 a month across the whole library (since 3 Sep 2026). WAV downloads are on the web only.
- **Stems:** Pro can split a song into stems.
- **Models:** v6 only. There is no public API, so Tim works by hand on suno.com.
- **Rights:** commercial rights attach only to songs downloaded on a paid plan. So only keepers get downloaded.
- **Remix clause:** Suno's terms limit Remix output (cover, extend, replace section) to personal, non-commercial use. A combat layer is therefore generated fresh from the same style prompt, never remixed.
- **Unconfirmed:** whether the terms allow posting the files in a public repo. Claude reads "remain yours to use commercially or personally" as covering it, and records that in `LICENSES.md`.

## 6. What makes sound

Each sound is a cue in `audio-src/cues.toml`. **Per type** means one cue per unit type, through the sound map (§7.1), falling back to `_living` or `_undead`.

**Melee** (`CombatEvent`)

| Event | Cue |
|---|---|
| `SWING`, `MISS` | `swing_<class>`: blade, heavy, staff, claw or stomp, by the attacker's weapon class |
| `HIT` | `hit_flesh` or `hit_dry`, by the target's body |
| `BLOCK` | `block_shield` |
| `KILL` | The hit, plus `death_<type>` (per type). On a viewer-side unit, its death bark replaces the cry when the bark plays (§8) |
| `HEAL` | `heal`. On an undead target, `heal_sear` |

**Projectiles** (`ProjectileEvent`), mapped by projectile id in the sound map:

| Event | Cue |
|---|---|
| `LAUNCH` | `bow_release` (arrow), `bow_release_fire` (fire arrow), `throw_bottle` (grenade, gas packet), `throw_herb`, `throw_heavy` (body part), `lightning_charge` |
| `STICK` | `arrow_thunk`, or `arrow_splash` when `depth > 0` |
| `HIT` | `arrow_flesh`. A body part plays `thud_flesh` |
| `BOUNCE` | `bottle_clink` or `thud_flesh`, louder with `speed` |
| `EXPLODE` | `explosion_small` or `explosion_large` by `radius`, `explosion_water` in water, `gas_burst` for a Blightbag's burst |
| `FIZZLE` | `fizzle_hiss`, or `fizzle_water` when `depth > 0` |
| `DROP` | `satchel_thud` |
| `IGNITE` | `fire_whoomp` |
| `PICK_UP` | `grab` |
| `BOLT` | `thunder` |
| `CANT_REACH` | `ui_deny` |

**Derived in the view**
- **A new gas cloud:** `gas_release`.
- **Undead groans:** `groan_<type>` (per type, falling back to `groan_undead`), from seen undead near the focus that have a unit of the other side within 20 m, picked by a view-only RNG and rate-limited. The 20 m rule was added at Tim's first Riverside listen (2026-11-17): the opening camera looks at a Husk patrol across the creek, 70 m from the squads, and they groaned from the first second.
- **Marching loops,** by ground: `march_grass` (grass, brush, wood), `march_sand`, `march_rock` and `march_water` (water depth 1 or more).
- **Beds:**
  - `bed_outdoor`, always on and low;
  - `bed_rain`;
  - `bed_snow`, with wind;
  - `bed_fire`;
  - `bed_water`, a creek near the focus;
  - `bed_gas`, a hiss while clouds are near.
- **UI:**
  - `ui_click`, for buttons;
  - `ui_select`, for a selection the player made;
  - `ui_formation`;
  - `ui_group`, for recalling or saving a group;
  - `ui_deny`, for an invalid order: a blocked marker or `CANT_REACH`;
  - `order_ack`, a short kit rattle for an order.

That makes 54 one-shot cues and 10 loops. The builder may merge or split a few one-shots: the test (§12) requires that every event and kind above reaches a cue, not this exact list.

## 7. In game

**Where the code goes.** All code lives in `view/audio/`, with small hooks in files §3 of the earlier spec allows. The extended touch list:
- Phase 10's existing files in `view/audio/`;
- `view/main.gd`'s audio wiring block, where `SfxPlayer` and `Ambience` are wired today;
- `selection_controller.gd`, `unit_sprite.gd` and `units_view.gd`;
- `view/settings/settings.gd` (`VOLUMES_DEFAULT`) and `default_bus_layout.tres`;
- `view/budget/budget_run.gd`;
- `project.godot` (an `[audio]` section for `output_latency.web`);
- the Makefile, `scripts/gen_sfx.py` (retired), `assets/LICENSES.md`, and `data/audio/`, `assets/audio/`, `audio-src/`, `scripts/audio/`, `tests/` and docs.

Never touched: `sim/`, `data/units/`, `data/missions/`.

### 7.1 Data

- **`data/audio/sound_bank.tres`** (`SoundBank`), generated (§9.5). For each cue it holds the variant streams, its bus, `level_db`, its pitch spread, its concurrent voice cap and its category.
  - It replaces `SfxBank`'s hand-written table.
  - A missing cue plays nothing and warns once. That keeps the "works before assets exist" rule for audio.
- **`data/audio/barks.tres`**, generated from the voice files. It holds every line's id, its voice, its trigger, its text, and its stream once voiced. Text barks work from it with no audio at all.
- **`data/audio/sound_map.tres`** (`SoundMap`), written by hand, because `UnitType` has no weapon class and must not gain one. *(Claude's call.)*
  - **Per unit type id:** weapon class, body (`flesh` or `dry`, which defaults by nature; the Stormcaller is a skeleton and sounds dry), death cue, groan cue, and voices (two for the Shieldman).
  - **Per projectile id:** its launch, stick, hit and bounce cues.
  - **Per mission or skirmish map id:** the music pair, defaulting to Riverside's.

### 7.2 `SfxPlayer`, extended

- Phase 10's pool of 24 voices stays, with the caps of 3 per sound and 8 per tick, the 4 m melee reach and the 160 m cull. A2 adds:
  - each cue's concurrent voice cap, so a chain of five satchels doesn't stack five full blasts;
  - the variant pick and pitch jitter, from a view-only RNG that tests can seed.
- **The no-leak rule.** `SfxPlayer` gains a viewer side (`set_viewer`), wired like `UnitsView`'s: through `side_changed`, and from the player's faction in a skirmish.
  - A sound a unit makes plays only if `Visibility.seen_by(world, unit, viewer)`. The unit is the attacker for swings and misses, the target for hits, blocks and heals, the dying unit for deaths, the shooter for launches, and the groaner for groans.
  - Projectile impacts, blasts, bolts, fire and gas are always heard.
  - This fixes a live leak: today a Husk hidden in deep water can be heard.
- **The listener** is an `AudioListener3D` at the camera's ground focus, turned to the camera's yaw, so loudness follows distance across the ground, not the zoom (from §8). `unit_size` is retuned to match.
- **On Web,** one-shots are registered at mission load (§4.3).

### 7.3 `Ambience`, extended

- The beds of §6 run as streamed loops on the Ambient bus. Each eases toward a target and stops once it has faded out, as rain and fire do today.
- **Targets:**
  - rain and snow from `weather.rain` and `weather.snow`;
  - fire from the burning cells within about 50 m of the focus, not the whole map;
  - water from a coarse sample of `water_depth_at` around the focus;
  - gas from the clouds near the focus;
  - outdoor always on, ducked under heavy rain.
- **Marching:**
  - Count the moving units the viewer can see within about 40 m of the focus.
  - Level is about √(n / 12), capped at 1.
  - Ground is the majority under the movers. Water depth 1 or more counts as water, and brush and wood count as grass.
  - Crossfade between the ground loops.
  - This replaces per-unit footsteps.

### 7.4 `Music` (new, `view/audio/music.gd`)

- **Players.** Two streamed players on the Music bus, calm and combat. They start together and loop, and only their volumes crossfade.
- **Combat trigger.** Count the units the viewer can see in `ATTACKING` or `SHOOTING`, either side, smoothed with hysteresis. The starting numbers, tuned at the listening build:
  - combat comes in at 4 or more for 1.5 s, fading in over 2 s;
  - it goes out at 1 or fewer for 10 s, fading out over 6 s.
- **Track per launch.** The sound map chooses the pair by mission or skirmish map id. Everything plays Riverside's until more music exists.
- **Layer lengths.** `process.py` cuts both layers to the same length, so they stay in step. If Tim prefers the combat layer to restart on entry, that's a one-line choice at the listening build.

### 7.5 `UiSounds` and the order tone

- **Buttons:** `UiSounds` keeps clicking every button.
- **Selection, formation, group recall and blocked orders:** sounds hooked to `UnitSelection.changed`, `formation_changed`, `group_changed` and the blocked marker.
- **The order tone** plays on every order. A bark may play on top (§8).

### 7.6 Buses and settings

- **Buses:** Master, Effects, Ambient, Interface, **Music** and **Voice**, all sending to Master, with no effects.
- **Settings:** `VOLUMES_DEFAULT` gains Music (start at 70) and Voice (100). The sliders build themselves from it. The four-bus settings test becomes a six-bus test.

### 7.7 `order_given` and the notice label

- **`order_given`** gains arguments: the ordered unit ids and an order kind.
  - The kinds must tell apart move (including patrol and waypoints), attack (attack-move, ground attack, and a move order onto an enemy unit, if the controller can tell it apart), special, retreat, and other orders such as stop, guard, scatter, turn and reissue.
  - Every place that emits it today passes them. `SfxPlayer.acknowledge` takes and ignores them.
- **`UnitSprite.show_notice`** gains a colour and a duration, with defaults that keep today's callers unchanged. Barks use their own colour, distinct from the orange notice.

## 8. Barks (light side)

### 8.1 Triggers

| Trigger | Fired by |
|---|---|
| select | a selection the player made (`UnitSelection.changed`, not empty and changed) |
| move, attack, special, retreat | `order_given(ids, kind)` |
| formation | `formation_changed(kind)`, for formations with lines (rabble and wedge, for the Shieldman) |
| kill | `KILL` with a viewer-side attacker |
| hurt | HP first drops below 35% of the maximum. It re-arms once the unit is healed above 50% *(Claude's call)* |
| death | `KILL` on a viewer-side target |
| annoyed | the same unit selected 4 or more times within 3 s (replaces select) |
| status | burning, paralyzed or confused begins. The view tracks each unit's status from the previous tick |
| victory | `MissionEvent.WON`, or a skirmish won by the viewer's side. A surviving unit near the screen centre speaks |
| unit-specific | for example the Sapper's fizzle and the Warden's heal on undead, as each unit's lines need |

### 8.2 How chatty (Tim's call)

- **Orders:** the first order to a squad gets a spoken answer. A repeat order to the same squad (the same set of ids) within 5 s gets only the order tone.
- **Selection:** barks less often, with a cooldown of 10 s *(Claude's number)*.
- **Kill, hurt and death:** always get through, within a side-wide limit of about one every 4 s.

### 8.3 Rules (from §8.4)

- **The speaker** is the selected or ordered unit nearest the screen centre.
- **No repeats:** each voice and trigger has a shuffle bag, so no line repeats until all of them have played.
- **Cooldowns:** each trigger has its own.
- **Clan-wide lines:** about 1 bark in 10 is a clan-wide line from `_clan.toml`, spoken in the speaker's own voice. A clan-wide line is never followed by another.
- **One bark at a time,** side-wide. A bark that would start while another is sounding is dropped, text and all, except a death. *(Claude's call.)*
- **Text:** every bark floats over the speaker in the bark colour, for about as long as the line takes to say. Barks are 3D at the speaker, on the Voice bus.
- **Two Shieldman voices,** older and younger. Each Shieldman speaks in one of them, chosen by id, so a squad doesn't sound like one man.

### 8.4 Lines and voices

- **`audio-src/voices/<unit>.toml`** holds:
  - the unit's voice descriptions (Voice Design prompts);
  - each line's id, trigger and text;
  - an optional delivery tag (spoken, not shown);
  - Tim's picks, once made.
- **`_clan.toml`** holds the clan-wide lines, starting with "Crivens!".
- **The Shieldman:** §8.4's 35 lines, plus about 2 victory lines (the 35 have none). Tim gives them a final OK before any voice spend.
- **The other four** (Reaver, Longbow, Sapper, Warden): Claude drafts about 20 to 25 lines each, from §8.4's starting lines. Each set covers select, move, attack, kill, hurt, death and annoyed, plus the unit's specials. Tim reviews them before any spend.
- **Originality rule:** §8.4's rule applies unchanged. Real Scots dialect is welcome; no Discworld names, catchphrases or characters.
- **Voice model:** before the Shieldman's first batch, Tim hears an A/B test on a few shouted and laughing lines, `eleven_v4` against `eleven_v4_turbo`, and picks by ear. Turbo is half the price; both take audio tags.

## 9. The offline pipeline

### 9.1 Files

```
audio-src/cues.toml              every cue: category, prompt, duration_s, loop, takes, keep, bus, level_db, max_voices, picks
audio-src/voices/<unit>.toml     voice descriptions, lines by trigger, picks
audio-src/voices/_clan.toml      clan-wide lines
audio-src/music/prompts.toml     the Riverside layers' prompts and lengths
audio-src/manifest.json          allowlisted fields only; reruns never re-buy
audio-src/raw/                   downloads (LFS)
audio-src/music/inbox/           Suno downloads, if Suno is used (LFS)
audio-src/audition/              audition pages and their preview files
scripts/audio/generate.py        plan (free) | probe | sfx | voices | music   (paid: Tim runs them in Terminal.app)
scripts/audio/process.py         trim, level, convert, loop, audition, picks (free: Claude runs it)
scripts/audio/build_sound_bank.gd headless Godot builder: sound_bank.tres and barks.tres
assets/audio/                    game-ready files (LFS)
```

### 9.2 `cues.toml`

- A `[style]` table holds the shared suffix, and a `[defaults]` table the usual values: takes are twice the variants kept, 3 variants are kept, and the bus is Effects.
- Each cue is a `[cue.<id>]` table. Ids match `[a-z0-9_]+`, and so do line ids; the scripts refuse anything else, since ids become file names.
- Loops set `loop = true` and the v3 model. `process.py` always makes the seam itself.

### 9.3 `generate.py` (paid, except `plan`)

- **Structure.** It follows `scripts/art/meshy.py`:
  - stdlib only (`urllib.request`);
  - the key read through `scripts/art/secrets_file.py` (`ELEVENLABS_API_KEY`, the same folder and mode checks, no fallback);
  - a resumable manifest whose interrupted entries must be resolved by hand before a rerun;
  - `--max-credits` on every paid command, refused before anything is bought if the estimate is over.
- **Subcommands:**
  - `plan`: free, prints every batch's cost and what is already bought.
  - `probe`: one 1 s SFX at `wav_32000`. It reports whether the format was accepted, and Tim checks the usage page for credits against dollars.
  - `sfx`: by cue or category.
  - `voices design <unit>`: previews, saved for audition.
  - `voices save <unit> --pick N`: saves the chosen design as a voice. Voice ids aren't secret and go in the manifest.
  - `voices lines <unit>`: takes for every line.
  - `voices ab`: the model test.
  - `music <layer>`.
- **Writes** only under `audio-src/raw/`:
  - downloads are size-capped and checked for an audio content type;
  - design previews are decoded from base64, and the JSON is never written;
  - nothing from response bodies or headers is kept beyond the allowlisted fields.
- **Security review.** The `security-reviewer` reads it before Tim sees it.
- **No make target** runs a paid step. Tim runs paid steps as `python3 scripts/audio/generate.py …`.

### 9.4 `process.py` (free)

It uses ffmpeg, checked before it starts as `render_sprites.py` does. It:

- **Trims** leading and trailing silence, with a short fade on the tail.
- **Levels** each category. One-shots are peak-normalised, then mixed by each cue's `level_db`. Barks are loudness-normalised to one target, and beds and music to another. The exact targets are set by ear.
- **Converts:**
  - one-shots to mono 16-bit WAV, imported QOA-compressed (`compress/mode=2`);
  - barks to mono Ogg Vorbis;
  - beds, marching loops and music to stereo Ogg Vorbis with loop on.
- **Makes loops seamless** by crossfading each loop's tail into its head (equal power), and cuts the two music layers to the same length.
- **Writes the Godot import settings.**
- **Writes an audition page per batch** (`audio-src/audition/<batch>.html`, a local file):
  - every take has a play button and its prompt;
  - Tim ticks the keepers, and "Save picks" downloads `picks-<batch>.json`.
- **`process.py picks <file>`** validates the file's ids and take numbers, then writes the picks into the `picks = [...]` line of each cue's table in `cues.toml`, or each line's in its voice file. Nothing else in the file changes, comments included, and a test proves it.
- **`process.py build`** writes the picked takes to `assets/audio/` and hands the builder a JSON sidecar.

### 9.5 The bank builder and make targets

- **The builder.** `scripts/audio/build_sound_bank.gd` (headless Godot, like `build_unit_art.gd`) builds `sound_bank.tres` and `barks.tres` from the sidecar and the imported files.
- **`make audio-build`** runs `process.py build` and then the builder. It's free, and Claude runs it.
- **Retiring the placeholders.** Once the bank's SFX land, `scripts/gen_sfx.py`, `make sfx` and the 16 placeholder WAVs are removed. Until then, the placeholders are migrated into the new bank, so nothing regresses. *(Claude's call.)*
- **`LICENSES.md`** gets a row for every shipped file: source, terms, date, and the prompt or line id it came from.
- **LFS:** about 150 MB more in raw downloads and assets.

## 10. The listening build (Claude's call)

- **The build:** a macOS export.
- **The route:**
  - Riverside, for the music and the first fights;
  - Old Mill, for the rain;
  - a skirmish with all ten types, so every unit is heard.
- **Single sounds:** the audition pages stay available, for hearing any sound on its own.
- **Web:** Tim also listens once, in Chrome, during §11 step 2, for streamed music under load and for 3D sample panning.

## 11. Order of work (for the plan)

1. **Free foundation, with no new audio:**
   - the Music and Voice buses and sliders;
   - the bank resource and builder, with the 16 placeholders migrated;
   - the sound map, and `SfxPlayer`'s viewer and visibility;
   - the listener at the focus;
   - `order_given` with arguments, and `show_notice` with a colour.
2. **Web facts, before any spend.** Synthetic test audio from ffmpeg (tones and noise, never shipped):
   - a with/without run, to learn whether Chrome counts decoded audio;
   - streamed music under the budget scenario's load, at `output_latency.web` 50 and 200 ms. Long main-thread tasks are checked in a devtools trace against the buffer, and Tim listens.
   - The budget line's audio fields go in here. The result settles streaming against the fallback (§4.3).
3. **Text barks in game.**
   - The Shieldman's lines, plus the starting lines for the other four.
   - Tim plays a build with text barks, and gives the Shieldman's lines a final OK.
4. **The pipeline:**
   - `generate.py`, `process.py`, the audition page, picks, and the builder, each with Python tests;
   - the security review of `generate.py`;
   - Tim creates the key, with its scope and quota.
5. **Probe** (Tim, 40 credits): settles the format and the billing.
6. **SFX one-shots** (Tim runs them), batch by category, then audition, picks and build. The placeholders are retired.
7. **Loops:** beds and marching. `Ambience` is extended, and marching added.
8. **Music:**
   - Claude writes the prompts. Tim runs `generate.py music`, or uses Suno Pro if ElevenLabs Music doesn't satisfy him.
   - Audition and loop it, and add the `Music` node.
9. **The Shieldman's voices:**
   - design the two voices, and Tim picks;
   - the v4 against v4 Turbo test, and Tim picks;
   - the lines, then audition, picks and build;
   - **the gate:** the budget check in the Web export (Chrome, through the chrome-devtools MCP, with stand-ins for the four's lines), and Tim's listening build (§10). The PR opens here, with the docs so far.
10. **The other four,** on the same branch and PR (Tim's call). Claude's drafts go to Tim for review, then design, lines, audition, picks and build.
11. **Finish:**
    - the budget check again, with every line voiced and no stand-ins, and audio's share;
    - Tim hears the four in a skirmish;
    - `LICENSES.md` and the docs completed, and the PR ready to merge.

## 12. Tests

**GUT** (`tests/view/`, headless with the dummy driver, never with `-d`):
- **Events to cues:** every `CombatEvent` and `ProjectileEvent` kind reaches its cue:
  - swing by weapon class, hit by body;
  - stick, fizzle and explode chosen by `depth`, `radius` and projectile id;
  - bounce louder with `speed`;
  - per-type fallbacks.
- **No leaks:** a submerged Husk's swing and death are silent, a hit on a seen unit plays, and explosions and bolts are always heard. The viewer follows `side_changed`.
- **Caps:** each cue's concurrent cap, as well as the existing per-tick caps. When the pool is full, the oldest voice is cut.
- **Ambience and marching:** targets from rain and snow, from fire and water near the focus, and from gas. Marching level and ground follow the visible movers.
- **Music:** hysteresis in and out, and the fades.
- **Barks:**
  - the shuffle bag;
  - each trigger's cooldown, the 5 s rule for the same squad, the 10 s selection cooldown and the 4 s side-wide limit;
  - the speaker is the unit nearest the centre;
  - the annoyed counter;
  - the 35% hurt line and its re-arm;
  - clan-wide lines at about 1 in 10 and never back to back (seeded);
  - one bark at a time;
  - the victory bark on WON;
  - the text shows in the bark colour with no voice stream.
- **`order_given`** carries the right ids and kind from each place that emits it.
- **The bank:**
  - every cue the code and the sound map name exists with at least one stream;
  - every catalog unit type and projectile id is in the sound map;
  - every light-side voice file covers the required triggers;
  - a missing cue is silent and warns once.
- **Registration:** the cues a launch registers on Web come from its `unit_types()` and the shared set. The registration call itself only runs on Web.
- **Budget:** the audio fields and the verdict arithmetic, with and without the decoded figure added.
- **Settings:** six buses, and a slider for each.

**Python** (`scripts/audio/test_*.py`, stdlib `unittest`, like `scripts/art/`):
- `plan` costs, the refusal over `--max-credits`, and resuming after an interruption;
- the manifest allowlist, with no network access in `plan` (urllib mocked);
- ids validated before they become paths;
- the loop crossfade's length and its seam;
- the trim;
- picks written without changing anything else in the file.

**Existing checks:** the whole suite, the sim purity check, and `make verify-replays`, which must match `main`.

## 13. Docs

- This spec, and the A2 plan in `docs/plans/`.
- **`architecture.md`, "Sound":**
  - the bank, the sound map and the buses;
  - visibility, the listener, marching and the beds;
  - music and barks;
  - Web registration, streaming and the measured budget;
  - a rewritten "Not yet".
- **`2026-10-01-art-audio-design.md`:** its status line, plus a note at §8 pointing here.
- **`docs/prompts.md`, A2:** drop `AudioDirector`.
- **`assets/LICENSES.md`.**

## 14. Risks and unverified items

| Item | Mitigation |
|---|---|
| Streamed loops drop out on Web when a heavy sim tick stalls the main thread | §11 step 2 measures this at 200 ms latency, before any spend. If they drop out, Tim chooses from measured options (§4.3) |
| Chrome's memory figure may not count decoded audio | With/without run. If uncounted, the verdict adds the computed figure (§4.5) |
| The decoded total runs over 270 MB | The levers in §4.4, in order. The 32 kHz lever only with Tim's OK |
| Registration at mission load is slow on Web (hundreds of seconds of audio decoded on the main thread) | `audio_load` in the budget line. If too slow, register across loading frames |
| A 3D sample starts silent for up to one tick, which can clip a short hit's attack. A voice out of range keeps its last gains | Tim listens on Web in step 2. Fallback on Web: non-positional players with our own distance level |
| `wav_32000` not open on Starter | The probe. Fallback `mp3_44100_128` |
| API billed in dollars, not credits | The probe and the usage page. The key's quota caps spend either way |
| Credits per character for `eleven_v4` and Turbo; voice design preview cost; whether saving a voice needs voices write access | Small first batches under a tight quota, with costs read from the usage page |
| Calm and combat layers that don't sit well together | Tim picks the pair by ear. Restarting combat on entry is the alternative (§7.4) |
| Suno's public-repo terms, if Suno is used | Recorded in `LICENSES.md` |
| LFS growth (about 150 MB) | Reported in the PR |

## 15. Done criteria (the gate)

- Tim's CLAUDE.md definition of done: the plan approved before code, GUT passing, running on the macOS export, docs updated, and a PR opened against `main`.
- Every event and kind in §6 reaches a cue, and the bank test passes.
- The Shieldman's barks are voiced. All five light-side units bark as text. Ambience and the Riverside music play.
- Before merge, the other four are voiced too (Tim's call), and the last budget run has no stand-ins.
- `make verify-replays` matches `main`, and the sim purity check passes.
- In the Web export in Chrome, the budget check is `measured` and PASS. Audio is at most 270 MB, with its share reported.
- Tim approves the listening build.

## 16. Left to the builder

- **Code layout:** the class and file split inside `view/audio/`, CLI flag names beyond the subcommands, the sidecar's location, and the budget line's exact field names.
- **Numbers:** the loudness targets, the radii (50 m fire, 40 m marching), and the music and groan thresholds. These are constants tuned by ear at the listening build.
- **Bark display time,** within "about as long as the line takes to say".
- **The order kind enum's names,** within §7.7's distinctions.
- **The look of the audition page.**
