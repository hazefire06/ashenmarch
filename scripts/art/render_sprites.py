"""Renders a unit's Meshy animations into 8-direction sprite sheets (spec §6.2).

Runs inside Blender, headless:

    $BLENDER -b --factory-startup --python-exit-code 1 \
        --python scripts/art/render_sprites.py -- <unit> [--candidates] [--engine EEVEE|WORKBENCH|CYCLES]

(`make art-render UNIT=shieldman`, `make art-candidates UNIT=shieldman`.)

Direction convention, shared with view/units/unit_art.gd: direction d shows
the unit facing d * 45 degrees counter-clockwise (seen from above) from the
camera's horizontal forward. 0 is seen from behind, 2 faces screen-left, 4
faces the camera, 6 faces screen-right. Meshy characters face glTF +Z, which
the importer turns into Blender -Y.

The camera is orthographic at a fixed elevation, with its lights riding on
it so every direction is lit alike. The root bone's horizontal travel is
cancelled, so the unit animates in place; the walk's travel per cycle is
saved as stride_m, so the game can play the legs at ground speed. Sheets,
import settings and a JSON sidecar go to assets/units/<unit>/. The contact
sheet and per-animation GIFs for review go to art-src/units/<unit>/review/.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from clips import pick_clip  # noqa: E402
from unit_spec import AnimEntry, UnitSpec, load_spec  # noqa: E402

REPO = HERE.parent.parent
CELL = 128
GUTTER = 4
STRIDE = CELL + 2 * GUTTER
FEET_PX = 20
PIXELS_PER_METER = 52.0
ELEVATION_DEG = 50.0
DIRECTIONS = 8
FPS = 12
CAMERA_DISTANCE = 30.0
FORWARD = Vector((0.0, -1.0, 0.0))
CANDIDATE_VIEWS = (0, 2, 4, 6)
GAME_ENGINES = {
    "EEVEE": ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"),
    "WORKBENCH": ("BLENDER_WORKBENCH",),
    "CYCLES": ("CYCLES",),
}
IMPORT_SETTINGS = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
mipmaps/generate=true
mipmaps/limit=-1
process/fix_alpha_border=true
process/premult_alpha=false
detect_3d/compress_to=0
"""


# --- scene ---------------------------------------------------------------

def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def configure_render(engine: str) -> None:
    scene = bpy.context.scene
    # The class-level enum lists only EEVEE (Workbench and Cycles register at
    # runtime), so the only reliable probe is to try the assignment.
    for identifier in GAME_ENGINES[engine]:
        try:
            scene.render.engine = identifier
            break
        except TypeError:
            continue
    else:
        raise RuntimeError(f"render engine {engine} is not available (tried {GAME_ENGINES[engine]})")
    scene.render.resolution_x = CELL
    scene.render.resolution_y = CELL
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    if engine == "WORKBENCH":
        scene.display.shading.light = "FLAT"
        scene.display.shading.color_type = "MATERIAL"
    elif engine == "CYCLES":
        scene.cycles.samples = 32


def make_camera() -> bpy.types.Object:
    scene = bpy.context.scene
    data = bpy.data.cameras.new("SpriteCamera")
    data.type = "ORTHO"
    data.ortho_scale = CELL / PIXELS_PER_METER
    # Puts the origin (the unit's feet) FEET_PX above the image's bottom edge.
    data.shift_y = 0.5 - FEET_PX / CELL
    data.clip_start = 0.1
    data.clip_end = 100.0
    camera = bpy.data.objects.new("SpriteCamera", data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    # Lights ride on the camera, so every direction is lit the same way.
    for name, energy, rotation in (("Key", 3.0, (-35.0, -30.0, 0.0)), ("Fill", 1.0, (-10.0, 40.0, 0.0)), ("Rim", 2.0, (150.0, 0.0, 0.0))):
        light = bpy.data.objects.new(name, bpy.data.lights.new(name, "SUN"))
        light.data.energy = energy
        scene.collection.objects.link(light)
        light.parent = camera
        light.rotation_euler = tuple(math.radians(a) for a in rotation)
    return camera


def camera_location(direction: int) -> Vector:
    rel = math.radians(direction * 360.0 / DIRECTIONS)
    # The unit's facing is the camera's horizontal forward turned by rel, so
    # the forward is the facing turned back by rel.
    forward = Matrix.Rotation(-rel, 3, "Z") @ FORWARD
    elevation = math.radians(ELEVATION_DEG)
    return -forward * (CAMERA_DISTANCE * math.cos(elevation)) + Vector((0.0, 0.0, CAMERA_DISTANCE * math.sin(elevation)))


def place_camera(camera: bpy.types.Object, direction: int) -> None:
    camera.location = camera_location(direction)
    camera.rotation_euler = (-camera.location).to_track_quat("-Z", "Y").to_euler()


def drop_importer_helpers() -> None:
    """Deletes what the glTF importer adds besides the model.

    For a skinned model it makes an "Icosphere" bone-shape mesh, hidden from
    renders in the "glTF_not_exported" collection. It never renders, but it
    would count in mesh_bounds() and wreck the fit.
    """
    for collection in [c for c in bpy.data.collections if c.name.startswith("glTF_not_exported")]:
        for obj in list(collection.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.collections.remove(collection)


def import_glb(path: Path, require_armature: bool = True) -> tuple[bpy.types.Object | None, list[bpy.types.Action]]:
    before = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=str(path))
    drop_importer_helpers()
    armature = next((o for o in bpy.context.scene.objects if o.type == "ARMATURE"), None)
    if armature is None and require_armature:
        raise RuntimeError(f"{path.name}: no armature")
    if armature is not None:
        data = armature.animation_data or armature.animation_data_create()
        for track in data.nla_tracks:
            track.mute = True
    return armature, [a for a in bpy.data.actions if a not in before]


def assign(armature: bpy.types.Object, action: bpy.types.Action) -> None:
    data = armature.animation_data
    data.action = action
    if hasattr(data, "action_slot") and data.action_slot is None and len(action.slots) > 0:
        data.action_slot = action.slots[0]


def copy_base_colors() -> None:
    """Workbench shows a material's viewport colour; give it the base colour."""
    for material in bpy.data.materials:
        tree = material.node_tree
        bsdf = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None) if tree else None
        if bsdf is not None:
            material.diffuse_color = bsdf.inputs["Base Color"].default_value


def set_frame(frame: float) -> None:
    whole = math.floor(frame)
    bpy.context.scene.frame_set(int(whole), subframe=frame - whole)


def mesh_bounds() -> tuple[Vector, Vector]:
    """World-space min and max corners of every mesh, as deformed right now."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    lo = Vector((math.inf, math.inf, math.inf))
    hi = Vector((-math.inf, -math.inf, -math.inf))
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH":
            continue
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        for v in mesh.vertices:
            p = evaluated.matrix_world @ v.co
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
        evaluated.to_mesh_clear()
    return lo, hi


def fit(target: bpy.types.Object, height_m: float) -> None:
    """Scales target so the meshes stand height_m tall, feet on z = 0."""
    lo, hi = mesh_bounds()
    if hi.z - lo.z > 1e-6:
        target.scale = target.scale * (height_m / (hi.z - lo.z))
        bpy.context.view_layer.update()
    lo, _ = mesh_bounds()
    target.location.z -= lo.z
    bpy.context.view_layer.update()


def root_xy(armature: bpy.types.Object, base: Matrix) -> Vector:
    root = next(b for b in armature.pose.bones if b.parent is None)
    head = base @ root.head
    return Vector((head.x, head.y))


def sample_frames(start: float, end: float, scene_fps: float, loop: bool) -> list[float]:
    seconds = max((end - start) / scene_fps, 1.0 / FPS)
    count = max(1, round(seconds * FPS))
    step = (end - start) / count
    return [start + i * step for i in range(count if loop else count + 1)]


def render_to(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


# --- images ---------------------------------------------------------------

def read_rgba(path: Path) -> np.ndarray:
    """Pixels as a (height, width, 4) float array; row 0 is the image's bottom."""
    image = bpy.data.images.load(str(path), check_existing=False)
    try:
        width, height = image.size
        pixels = np.empty(width * height * 4, dtype=np.float32)
        image.pixels.foreach_get(pixels)
        return pixels.reshape(height, width, 4)
    finally:
        bpy.data.images.remove(image)


def touches_border(path: Path) -> bool:
    alpha = read_rgba(path)[..., 3] > 0.1
    return bool(alpha[0].any() or alpha[-1].any() or alpha[:, 0].any() or alpha[:, -1].any())


def opaque_mean_color(path: Path) -> list[float]:
    px = read_rgba(path)
    solid = px[px[..., 3] > 0.5]
    if len(solid) == 0:
        return [0.5, 0.5, 0.5]
    return [round(float(c), 3) for c in solid[:, :3].mean(axis=0)]


def ffmpeg(*args: str) -> None:
    exe = shutil.which("ffmpeg")
    if exe is None:
        raise RuntimeError("ffmpeg not found (brew install ffmpeg)")
    subprocess.run([exe, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def tile(cells: list[Path], columns: int, rows: int, dest: Path) -> None:
    """Pads each cell by GUTTER and tiles them row-major into one PNG."""
    with tempfile.TemporaryDirectory() as tmp:
        for k, path in enumerate(cells):
            shutil.copy(path, Path(tmp) / f"{k:05d}.png")
        dest.parent.mkdir(parents=True, exist_ok=True)
        ffmpeg("-i", str(Path(tmp) / "%05d.png"),
               "-vf", f"format=rgba,pad={STRIDE}:{STRIDE}:{GUTTER}:{GUTTER}:color=black@0,tile={columns}x{rows}",
               "-frames:v", "1", str(dest))


def gif(frames_dir: Path, frames: int, dest: Path) -> None:
    """All 8 directions side by side, animated, for review."""
    inputs: list[str] = []
    for d in range(DIRECTIONS):
        inputs += ["-framerate", str(FPS), "-i", str(frames_dir / f"d{d}" / "f%03d.png")]
    streams = "".join(f"[{d}:v]" for d in range(DIRECTIONS))
    ffmpeg(*inputs, "-filter_complex",
           f"{streams}hstack=inputs={DIRECTIONS},split[a][b];[a]palettegen=reserve_transparent=1[p];[b][p]paletteuse",
           "-frames:v", str(frames), "-loop", "0", str(dest))


def write_import_settings(sheet: Path) -> None:
    """Mipmapped, VRAM-compressed sprite sheets. Godot fills in the rest on import."""
    settings = sheet.with_name(sheet.name + ".import")
    if not settings.exists():
        settings.write_text(IMPORT_SETTINGS, encoding="utf-8")


# --- rendering --------------------------------------------------------------

def render_animation(spec: UnitSpec, glb: Path, entry: AnimEntry, frames_dir: Path, engine: str) -> dict[str, Any]:
    reset_scene()
    configure_render(engine)
    camera = make_camera()
    armature, actions = import_glb(glb)
    if engine == "WORKBENCH":
        copy_base_colors()
    action = None
    if actions:
        name = pick_clip([a.name for a in actions], entry.clip)
        action = next(a for a in actions if a.name == name)
        assign(armature, action)
    scene = bpy.context.scene
    start, end = (float(action.frame_range[0]), float(action.frame_range[1])) if action else (1.0, 1.0)
    set_frame(start)
    fit(armature, spec.height_m)
    base = armature.matrix_world.copy()
    base_location = armature.location.copy()

    stride_m = 0.0
    if action is not None and entry.name in ("walk", "run"):
        set_frame(start)
        first = root_xy(armature, base)
        set_frame(end)
        stride_m = (root_xy(armature, base) - first).length

    clipped: list[str] = []
    frames = sample_frames(start, end, scene.render.fps / scene.render.fps_base, entry.loop)
    for i, frame in enumerate(frames):
        armature.location = base_location
        set_frame(frame)
        xy = root_xy(armature, base)
        armature.location = base_location - Vector((xy.x, xy.y, 0.0))
        bpy.context.view_layer.update()
        for d in range(DIRECTIONS):
            place_camera(camera, d)
            path = frames_dir / f"d{d}" / f"f{i:03d}.png"
            render_to(path)
            if touches_border(path):
                clipped.append(f"{entry.name}/d{d}f{i}")
    impact = round(entry.impact * (len(frames) - 1)) if entry.impact is not None else -1
    return {"sheet": f"{entry.name}.png", "frames": len(frames), "fps": FPS, "loop": entry.loop,
            "impact_frame": impact, "stride_m": round(stride_m, 4), "clipped": clipped}


def key_frame(name: str, info: dict[str, Any]) -> int:
    if name == "idle":
        return 0
    if name in ("walk", "run"):
        return info["frames"] // 4
    if name == "die":
        return info["frames"] - 1
    return info["impact_frame"] if info["impact_frame"] >= 0 else info["frames"] // 2


def render_unit(unit: str, src_root: Path, out_root: Path, engine: str = "EEVEE") -> dict[str, Any]:
    unit_dir = src_root / "units" / unit
    spec = load_spec(unit_dir / "spec.toml")
    out_dir = out_root / unit
    review = unit_dir / "review"
    out_dir.mkdir(parents=True, exist_ok=True)
    review.mkdir(parents=True, exist_ok=True)
    sidecar: dict[str, Any] = {
        "unit": spec.id, "cell": CELL, "gutter": GUTTER, "stride": STRIDE, "feet_px": FEET_PX,
        "pixels_per_meter": PIXELS_PER_METER, "elevation_deg": ELEVATION_DEG, "directions": DIRECTIONS,
        "die_falls_forward": spec.die_falls_forward, "bursts_on_death": spec.bursts_on_death,
        "gib_color": [0.5, 0.5, 0.5], "clipped": [], "animations": {},
    }
    work = Path(tempfile.mkdtemp(prefix=f"render-{unit}-"))
    try:
        contact: list[Path] = []
        for entry in spec.animations:
            frames_dir = work / entry.name
            info = render_animation(spec, unit_dir / entry.file, entry, frames_dir, engine)
            sidecar["clipped"] += info.pop("clipped")
            sheet = out_dir / info["sheet"]
            tile([frames_dir / f"d{d}" / f"f{i:03d}.png" for d in range(DIRECTIONS) for i in range(info["frames"])],
                 info["frames"], DIRECTIONS, sheet)
            write_import_settings(sheet)
            gif(frames_dir, info["frames"], review / f"{entry.name}.gif")
            k = key_frame(entry.name, info)
            contact += [frames_dir / f"d{d}" / f"f{k:03d}.png" for d in range(DIRECTIONS)]
            sidecar["animations"][entry.name] = info
        tile(contact, DIRECTIONS, len(spec.animations), review / "contact.png")
        first = "idle" if "idle" in sidecar["animations"] else spec.animations[0].name
        sidecar["gib_color"] = opaque_mean_color(work / first / "d4" / "f000.png")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    (out_dir / f"{unit}.json").write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if sidecar["clipped"]:
        print(f"WARNING: {len(sidecar['clipped'])} frames touch the cell edge (clipped): {sidecar['clipped'][:8]} ...")
    return sidecar


def render_candidates(unit: str, src_root: Path, engine: str = "EEVEE") -> Path:
    unit_dir = src_root / "units" / unit
    spec = load_spec(unit_dir / "spec.toml")
    files = sorted((unit_dir / "candidates").glob("cand-*.glb"), key=lambda p: int(p.stem.split("-")[1]))
    if not files:
        raise RuntimeError(f"no candidates in {unit_dir / 'candidates'}; run meshy.py candidates first")
    dest = unit_dir / "review" / "candidates.png"
    with tempfile.TemporaryDirectory() as tmp:
        cells: list[Path] = []
        for glb in files:
            reset_scene()
            configure_render(engine)
            camera = make_camera()
            import_glb(glb, require_armature=False)
            holder = bpy.data.objects.new("Fit", None)
            bpy.context.scene.collection.objects.link(holder)
            for obj in [o for o in bpy.context.scene.objects if o.parent is None and o not in (holder, camera)]:
                if obj.type != "LIGHT":
                    obj.parent = holder
            fit(holder, spec.height_m)
            lo, hi = mesh_bounds()
            holder.location.x -= (lo.x + hi.x) / 2.0
            holder.location.y -= (lo.y + hi.y) / 2.0
            bpy.context.view_layer.update()
            for d in CANDIDATE_VIEWS:
                place_camera(camera, d)
                path = Path(tmp) / f"{glb.stem}_d{d}.png"
                render_to(path)
                cells.append(path)
        tile(cells, len(CANDIDATE_VIEWS), len(files), dest)
    print(f"candidates: {dest} (rows = {[f.stem for f in files]}; columns = back, left, front, right)")
    return dest


def main(argv: list[str]) -> int:
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    parser = argparse.ArgumentParser(prog="render_sprites.py")
    parser.add_argument("unit")
    parser.add_argument("--candidates", action="store_true")
    parser.add_argument("--engine", default="EEVEE", choices=sorted(GAME_ENGINES))
    parsed = parser.parse_args(args)
    if parsed.candidates:
        render_candidates(parsed.unit, REPO / "art-src", parsed.engine)
    else:
        sidecar = render_unit(parsed.unit, REPO / "art-src", REPO / "assets" / "units", parsed.engine)
        print(f"rendered {parsed.unit}: {sorted(sidecar['animations'])} -> assets/units/{parsed.unit}/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
