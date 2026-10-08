"""Renders a unit's Meshy animations into 8-direction sprite sheets (spec §6.2).

Runs inside Blender, headless:

    $BLENDER -b --factory-startup --python-exit-code 1 \
        --python scripts/art/render_sprites.py -- <name> [--candidates | --attach | --prop-candidates] \
        [--engine EEVEE|WORKBENCH|CYCLES]

(`make art-render UNIT=shieldman`, `make art-candidates UNIT=shieldman`,
`make art-attach UNIT=shieldman`, `make art-prop-candidates PROP=broadsword`.)

Direction convention, shared with view/units/unit_art.gd: direction d shows
the unit facing d * 45 degrees counter-clockwise (seen from above) from the
camera's horizontal forward. 0 is seen from behind, 2 faces screen-left, 4
faces the camera, 6 faces screen-right. Meshy characters face glTF +Z, which
the importer turns into Blender -Y.

The camera is orthographic at a fixed elevation, with its lights riding on
it so every direction is lit alike. The root bone's horizontal travel is
cancelled, so the unit animates in place; the walk's travel per cycle is
saved as stride_m, so the game can play the legs at ground speed. A clip
that already plays in place (Meshy's rig walk) has its stride measured from
the planted foot instead. The unit's props (spec §6.2a) are fixed to their
bones after the height fit, so they never count toward it. Sheets wrap at
MAX_SHEET_PX wide. Sheets, import settings and a JSON sidecar go to
assets/units/<unit>/. The contact sheet, per-animation GIFs and the attach
preview go to art-src/units/<unit>/review/; a prop's candidate sheet to
art-src/props/<prop>/review/. Nothing is written, or read, through a symlink.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from clips import pick_clip  # noqa: E402
from unit_spec import NAME, AnimEntry, AttachEntry, PropSpec, UnitSpec, animation_file, load_prop_spec, load_spec  # noqa: E402

REPO = HERE.parent.parent
CELL = 160
GUTTER = 4
STRIDE = CELL + 2 * GUTTER
FEET_PX = 40
PIXELS_PER_METER = 52.0
# Web (WebGL) may cap textures at 4096 px, so a long animation's frames wrap onto more rows.
MAX_SHEET_PX = 4096
ELEVATION_DEG = 50.0
DIRECTIONS = 8
FPS = 12
CAMERA_DISTANCE = 30.0
FORWARD = Vector((0.0, -1.0, 0.0))
CANDIDATE_VIEWS = (0, 2, 4, 6)
ATTACH_VIEWS = (0, 2, 4, 6)
# A walk or run whose root travels less than this over the clip plays in place; its stride comes from the feet.
IN_PLACE_M = 0.05
PROP_CELL = 256
# (label, camera azimuth from the prop's front in degrees, elevation in degrees); a Meshy model faces -Y, like a unit.
PROP_VIEWS = (("front", 0.0, 0.0), ("side", 90.0, 0.0), ("back", 180.0, 0.0), ("three-quarter", 45.0, 35.0))
PROP_BACKDROP = (0.9, 0.9, 0.88)
PROP_CLAY = (0.6, 0.55, 0.5)
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


@dataclass(frozen=True)
class Prop:
    """One [[attach]] entry, with its recipe and model found and checked."""
    entry: AttachEntry
    spec: PropSpec
    glb: Path


@dataclass
class Staged:
    """One animation loaded, fitted and carrying its props, ready to pose."""
    camera: bpy.types.Object
    armature: bpy.types.Object
    holder: bpy.types.Object
    base: Vector
    action: bpy.types.Action | None
    start: float
    end: float
    frames: list[float]
    prop_meshes: list[bpy.types.Object] = field(default_factory=list)


@dataclass
class Extents:
    """How far the figure reaches in its cell, worst over every frame and direction: px above the
    cell's bottom edge (negative below it) and px either side of its centre line."""
    lowest: float = math.inf
    highest: float = -math.inf
    half_width: float = 0.0

    def add(self, points: np.ndarray, direction: int) -> None:
        if len(points) == 0:
            return
        x, y = project(points, direction)
        self.lowest = min(self.lowest, float(y.min()))
        self.highest = max(self.highest, float(y.max()))
        self.half_width = max(self.half_width, float(np.abs(x - CELL / 2).max()))

    def line(self, name: str) -> str:
        return (f"extents {name}: lowest {self.lowest:.1f} above the bottom, highest {self.highest:.1f}, "
                f"half-width {self.half_width:.1f} (cell {CELL})")


# --- safety -----------------------------------------------------------------

def repo_root(src_root: Path, repo: Path | None) -> Path:
    """The repo the renderer may read and write in: given, or the one holding art-src."""
    return repo if repo is not None else src_root.parent


def refuse_planted_links(repo: Path, folders: Iterable[Path]) -> None:
    """Raises RuntimeError if a folder is a symlink, isn't where its path says, or holds a symlink.

    The repo is public, so a PR could plant a symlinked review/ or sheet and
    have a render written over a file elsewhere. A folder must resolve to
    exactly its own path under the repo, so a symlink anywhere between the
    repo and it (art-src/units -> ../.git, say) is refused too, even one
    that stays inside the repo. Checked before anything is rendered or
    written. Folders that don't exist yet pass.
    """
    inside = repo.resolve()
    for folder in folders:
        if folder.is_symlink():  # also true for a dangling one
            raise RuntimeError(f"{folder} is a symlink; replace it with a real folder")
        try:
            expected = inside / folder.relative_to(repo)
        except ValueError:
            raise RuntimeError(f"{folder} is outside {repo}") from None
        if folder.resolve() != expected:
            raise RuntimeError(f"{folder} resolves to {folder.resolve()}, not {expected}: a folder on its path is a symlink")
        for here, dirs, files in os.walk(folder, followlinks=False):
            for name in dirs + files:
                if (Path(here) / name).is_symlink():
                    raise RuntimeError(f"{Path(here) / name} is a symlink; remove it and rerun")


# --- scene ---------------------------------------------------------------

def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def configure_render(engine: str, size: int = CELL) -> None:
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
    scene.render.resolution_x = size
    scene.render.resolution_y = size
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
    """The game camera. The image's size doesn't change its framing: a bigger
    one (the attach preview) just has more pixels per metre."""
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


def camera_matrix(direction: int) -> Matrix:
    location = camera_location(direction)
    return Matrix.Translation(location) @ (-location).to_track_quat("-Z", "Y").to_matrix().to_4x4()


def place_camera(camera: bpy.types.Object, direction: int) -> None:
    camera.matrix_world = camera_matrix(direction)


def project(points: np.ndarray, direction: int) -> tuple[np.ndarray, np.ndarray]:
    """World points (N, 3) to game-cell pixels seen from direction: x from the
    cell's left edge, y up from its bottom edge. The camera looks at the
    origin, which lands on the pivot (CELL / 2, FEET_PX)."""
    inverse = np.array(camera_matrix(direction).inverted())
    local = points @ inverse[:3, :3].T + inverse[:3, 3]
    return CELL / 2 + local[:, 0] * PIXELS_PER_METER, FEET_PX + local[:, 1] * PIXELS_PER_METER


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
    """Imports a GLB; returns its armature (None if it has none) and its actions."""
    before = set(bpy.data.actions)
    objects_before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    drop_importer_helpers()
    armature = next((o for o in bpy.context.scene.objects if o.type == "ARMATURE" and o not in objects_before), None)
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


def scene_fps() -> float:
    return bpy.context.scene.render.fps / bpy.context.scene.render.fps_base


def set_frame(frame: float) -> None:
    whole = math.floor(frame)
    bpy.context.scene.frame_set(int(whole), subframe=frame - whole)


def world_vertices(objects: Iterable[bpy.types.Object] | None = None) -> np.ndarray:
    """World-space positions (N, 3) of every mesh's vertices, or only objects', as deformed right now."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    chunks = [np.zeros((0, 3))]
    for obj in (bpy.context.scene.objects if objects is None else objects):
        if obj.type != "MESH":
            continue
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        co = np.empty(len(mesh.vertices) * 3, dtype=np.float32)
        mesh.vertices.foreach_get("co", co)
        matrix = np.array(evaluated.matrix_world)
        chunks.append(co.reshape(-1, 3).astype(np.float64) @ matrix[:3, :3].T + matrix[:3, 3])
        evaluated.to_mesh_clear()
    return np.concatenate(chunks)


def mesh_bounds(objects: Iterable[bpy.types.Object] | None = None) -> tuple[Vector, Vector]:
    """World-space min and max corners of every mesh (or only objects'), as deformed right now."""
    points = world_vertices(objects)
    if len(points) == 0:
        return Vector((math.inf,) * 3), Vector((-math.inf,) * 3)
    return Vector(points.min(axis=0)), Vector(points.max(axis=0))


def adopt_imports(camera: bpy.types.Object) -> bpy.types.Object:
    """Parents every imported root object to a new identity Empty, "Fit".

    The importer keeps the file's node hierarchy, so the model may hang under
    a scaled or offset parent. Moving and scaling Fit instead of the
    armature keeps fit() and the root-motion cancel in plain world space.
    """
    holder = bpy.data.objects.new("Fit", None)
    bpy.context.scene.collection.objects.link(holder)
    for obj in [o for o in bpy.context.scene.objects if o.parent is None and o not in (holder, camera)]:
        if obj.type != "LIGHT":
            obj.parent = holder
    bpy.context.view_layer.update()
    return holder


def fit(target: bpy.types.Object, height_m: float) -> None:
    """Scales target (an unparented object holding the meshes) so they stand
    height_m tall, feet on z = 0."""
    lo, hi = mesh_bounds()
    if hi.z - lo.z > 1e-6:
        target.scale = target.scale * (height_m / (hi.z - lo.z))
        bpy.context.view_layer.update()
    lo, _ = mesh_bounds()
    target.location.z -= lo.z
    bpy.context.view_layer.update()


def root_xy(armature: bpy.types.Object) -> Vector:
    """World-space horizontal position of the root bone's head, as posed right now.

    Read through the armature's world matrix, so motion keyed on the armature
    node itself counts as well as motion keyed on the bone.
    """
    evaluated = armature.evaluated_get(bpy.context.evaluated_depsgraph_get())
    root = next(b for b in evaluated.pose.bones if b.parent is None)
    head = evaluated.matrix_world @ root.head
    return Vector((head.x, head.y))


def bone_head(armature: bpy.types.Object, bone: str) -> Vector:
    """World-space head of a posed bone. Heads, not tails: the importer guesses tails."""
    evaluated = armature.evaluated_get(bpy.context.evaluated_depsgraph_get())
    return evaluated.matrix_world @ evaluated.pose.bones[bone].head


def bone_frame(armature: bpy.types.Object, bone: str) -> Matrix:
    """The posed bone's own axes at its head, in world space and metres: no scale from the armature or what holds it."""
    evaluated = armature.evaluated_get(bpy.context.evaluated_depsgraph_get())
    axes = (evaluated.matrix_world.to_3x3() @ evaluated.pose.bones[bone].matrix.to_3x3()).normalized().to_quaternion()
    return Matrix.Translation(bone_head(armature, bone)) @ axes.to_matrix().to_4x4()


def sample_frames(start: float, end: float, scene_rate: float, loop: bool) -> list[float]:
    seconds = max((end - start) / scene_rate, 1.0 / FPS)
    count = max(1, round(seconds * FPS))
    step = (end - start) / count
    return [start + i * step for i in range(count if loop else count + 1)]


def render_to(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


# --- props -------------------------------------------------------------------

def resolve_props(spec: UnitSpec, src_root: Path, repo: Path | None = None) -> list[Prop]:
    """Finds and loads each prop the unit carries, before anything is rendered."""
    folders = [src_root / "props" / entry.prop for entry in spec.attach]
    refuse_planted_links(repo_root(src_root, repo), folders)
    props: list[Prop] = []
    for entry, folder in zip(spec.attach, folders):
        recipe, glb = folder / "spec.toml", folder / "model" / "textured.glb"
        if not recipe.is_file():
            raise RuntimeError(f"{spec.id} carries {entry.prop}, but {recipe} is missing; write its recipe "
                               f"(spec §6.2a), then run meshy.py prop-candidates and prop-build {entry.prop}")
        if not glb.is_file():
            raise RuntimeError(f"{glb} is missing; buy {spec.id}'s {entry.prop} with "
                               f"`python3 scripts/art/meshy.py prop-build {entry.prop} --pick N` (after prop-candidates)")
        props.append(Prop(entry, load_prop_spec(recipe), glb))
    return props


def principal_length(points: np.ndarray) -> float:
    """How long points (N, 3) are along their longest principal axis: the
    spread of their projections onto the first right-singular vector of the
    centred points. A model can come out lying diagonally in its own frame
    (the bought broadsword did), and then its bounding box is shorter than
    it is."""
    centred = points - points.mean(axis=0)
    along = centred @ np.linalg.svd(centred, full_matrices=False)[2][0]
    return float(along.max() - along.min())


def attach_props(armature: bpy.types.Object, props: list[Prop], frame: float) -> list[bpy.types.Object]:
    """Imports each prop and fixes it to its bone; returns the props' meshes.

    The prop is sized so its length along its longest principal axis is
    length_m in world metres, and centred on its bounding box. Its centre
    sits at the posed bone's head (Blender would hang a bone child at the
    tail), moved by offset and turned by rotation in the bone's own axes,
    as the bone stands at frame (the clip's start). Neither the armature's scale nor Fit's reaches it. From
    then on it follows the bone, so the root-motion cancel and every pose
    carry it.
    """
    scene = bpy.context.scene
    meshes: list[bpy.types.Object] = []
    for prop in props:
        bone = prop.entry.bone
        if bone not in armature.pose.bones:
            raise RuntimeError(f"{prop.spec.id}: the rig has no bone {bone!r}; its bones are "
                               f"{', '.join(b.name for b in armature.pose.bones)}")
        before = set(scene.objects)
        import_glb(prop.glb, require_armature=False)
        added = [o for o in scene.objects if o not in before]
        set_frame(frame)
        points = world_vertices(added)
        length = principal_length(points) if len(points) > 1 else 0.0
        if not math.isfinite(length) or length <= 1e-9:
            raise RuntimeError(f"{prop.glb}: no mesh to attach")
        lo, hi = Vector(points.min(axis=0)), Vector(points.max(axis=0))
        mount = bpy.data.objects.new(f"Prop {prop.spec.id}", None)
        scene.collection.objects.link(mount)
        mount.parent = armature
        mount.parent_type = "BONE"
        mount.parent_bone = bone
        bpy.context.view_layer.update()
        # With no parent inverse, the mount sits where Blender hangs a bone
        # child. Inverting that cancels it at this frame, so the basis below
        # is the mount's world matrix now, and later poses carry it along.
        hang = mount.evaluated_get(bpy.context.evaluated_depsgraph_get()).matrix_world.copy()
        mount.matrix_parent_inverse = hang.inverted_safe()
        mount.matrix_basis = (bone_frame(armature, bone)
                              @ Matrix.Translation(prop.entry.offset)
                              @ Euler([math.radians(a) for a in prop.entry.rotation], "XYZ").to_matrix().to_4x4()
                              @ Matrix.Scale(prop.spec.length_m / length, 4)
                              @ Matrix.Translation(-(lo + hi) / 2))
        for obj in added:
            if obj.parent is None:  # the import's world space becomes the mount's
                obj.parent = mount
        bpy.context.view_layer.update()
        meshes += [o for o in added if o.type == "MESH"]
    return meshes


# --- stride ------------------------------------------------------------------

def foot_bones(armature: bpy.types.Object) -> list[str]:
    names = [b.name for b in armature.pose.bones if "foot" in b.name.lower() and "toe" not in b.name.lower()]
    if not names:
        raise RuntimeError(f"the clip plays in place, so its stride comes from the feet, but the rig has no foot bone "
                           f"(a name with 'foot' and not 'toe'); its bones are {', '.join(b.name for b in armature.pose.bones)}")
    return names


def stride_from_feet(armature: bpy.types.Object, start: float, end: float) -> float:
    """Metres per cycle of a walk that plays in place, from its planted foot.

    Sampled at the render rate, the lower foot (by its head's height) is the
    one on the ground. Where the same foot is lower at both ends of a step,
    it slid backward along the unit's facing at ground speed. The median of
    those slides over the step time is the speed; times the clip's length,
    the stride.
    """
    feet = foot_bones(armature)
    if end <= start:
        raise RuntimeError("the clip plays in place and has no length, so its stride can't be measured")
    samples = sample_frames(start, end, scene_fps(), loop=False)
    step_s = (samples[1] - samples[0]) / scene_fps()
    slides: list[float] = []
    previous: tuple[str, Vector] | None = None
    for frame in samples:
        set_frame(frame)
        heads = {name: bone_head(armature, name) for name in feet}
        low = min(feet, key=lambda name: heads[name].z)
        if previous is not None and previous[0] == low:
            slides.append((heads[low] - previous[1]).dot(-FORWARD))
        previous = (low, heads[low])
    if not slides:
        raise RuntimeError("the clip plays in place, and no foot stays lowest across a sampled step, so its stride can't be measured")
    return statistics.median(slides) / step_s * (end - start) / scene_fps()


def measure_stride(staged: Staged, entry: AnimEntry) -> float:
    """Metres the unit covers per cycle of a walk or run, at its fitted size."""
    set_frame(staged.start)
    first = root_xy(staged.armature)
    set_frame(staged.end)
    travel = (root_xy(staged.armature) - first).length
    if travel >= IN_PLACE_M:
        print(f"stride {entry.name}: {travel:.3f} m (the root's travel)")
        return travel
    stride = stride_from_feet(staged.armature, staged.start, staged.end)
    print(f"stride {entry.name}: {stride:.3f} m (from the feet; the root travels {travel:.3f} m)")
    return stride


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


def tile(cells: list[Path | None], columns: int, rows: int, dest: Path, size: int = CELL) -> None:
    """Pads each size-px cell by GUTTER and tiles them row-major into one PNG. None leaves a cell transparent."""
    with tempfile.TemporaryDirectory() as tmp:
        blank = Path(tmp) / "blank.png"
        if None in cells:
            ffmpeg("-f", "lavfi", "-i", f"color=c=black@0.0:s={size}x{size},format=rgba", "-frames:v", "1", str(blank))
        for k, path in enumerate(cells):
            shutil.copy(path if path is not None else blank, Path(tmp) / f"{k:05d}.png")
        dest.parent.mkdir(parents=True, exist_ok=True)
        padded = size + 2 * GUTTER
        ffmpeg("-i", str(Path(tmp) / "%05d.png"),
               "-vf", f"format=rgba,pad={padded}:{padded}:{GUTTER}:{GUTTER}:color=black@0,tile={columns}x{rows}",
               "-frames:v", "1", str(dest))


def sheet_layout(frames: int) -> tuple[int, int]:
    """(columns, rows per direction) for an animation's sheet, which wraps at MAX_SHEET_PX wide."""
    columns = min(frames, MAX_SHEET_PX // STRIDE)
    return columns, math.ceil(frames / columns)


def sheet_cells(frames_dir: Path, frames: int) -> list[Path | None]:
    """The sheet's cells, row-major: frame i of direction d sits at column
    i % columns, row d * rows_per_direction + i // columns. None pads a
    direction's last row."""
    columns, rows = sheet_layout(frames)
    return [frames_dir / f"d{d}" / f"f{i:03d}.png" if i < frames else None
            for d in range(DIRECTIONS) for i in range(rows * columns)]


def gif(frames_dir: Path, frames: int, dest: Path) -> None:
    """All 8 directions side by side, animated, for review."""
    inputs: list[str] = []
    for d in range(DIRECTIONS):
        inputs += ["-framerate", str(FPS), "-i", str(frames_dir / f"d{d}" / "f%03d.png")]
    streams = "".join(f"[{d}:v]" for d in range(DIRECTIONS))
    dest.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg(*inputs, "-filter_complex",
           f"{streams}hstack=inputs={DIRECTIONS},split[a][b];[a]palettegen=reserve_transparent=1[p];[b][p]paletteuse",
           "-frames:v", str(frames), "-loop", "0", str(dest))


def write_import_settings(sheet: Path) -> None:
    """Mipmapped, VRAM-compressed sprite sheets. Godot fills in the rest on import."""
    settings = sheet.with_name(sheet.name + ".import")
    if not settings.exists():
        settings.write_text(IMPORT_SETTINGS, encoding="utf-8")


# --- rendering --------------------------------------------------------------

def stage_animation(spec: UnitSpec, glb: Path, entry: AnimEntry, props: list[Prop], engine: str, size: int = CELL) -> Staged:
    """Loads one animation into a fresh scene, fits the body to height_m, then attaches the props."""
    reset_scene()
    configure_render(engine, size)
    camera = make_camera()
    armature, actions = import_glb(glb)
    holder = adopt_imports(camera)
    action = None
    if actions:
        name = pick_clip([a.name for a in actions], entry.clip)
        action = next(a for a in actions if a.name == name)
        assign(armature, action)
    start, end = (float(action.frame_range[0]), float(action.frame_range[1])) if action else (1.0, 1.0)
    set_frame(start)
    fit(holder, spec.height_m)
    prop_meshes = attach_props(armature, props, start)  # after fit(), so props never count toward the height
    if engine == "WORKBENCH":
        copy_base_colors()
    return Staged(camera, armature, holder, holder.location.copy(), action, start, end,
                  sample_frames(start, end, scene_fps(), entry.loop), prop_meshes)


def pose_at(staged: Staged, frame: float) -> None:
    """Poses the animation at frame, with the root's horizontal travel cancelled."""
    staged.holder.location = staged.base
    set_frame(frame)
    xy = root_xy(staged.armature)
    staged.holder.location = staged.base - Vector((xy.x, xy.y, 0.0))
    bpy.context.view_layer.update()


def impact_index(entry: AnimEntry, frames: int) -> int:
    return round(entry.impact * (frames - 1)) if entry.impact is not None else -1


def render_animation(spec: UnitSpec, glb: Path, entry: AnimEntry, props: list[Prop], frames_dir: Path, engine: str) -> dict[str, Any]:
    staged = stage_animation(spec, glb, entry, props, engine)
    stride_m = 0.0
    if staged.action is not None and entry.name in ("walk", "run"):
        stride_m = measure_stride(staged, entry)

    clipped: list[str] = []
    extents = Extents()
    for i, frame in enumerate(staged.frames):
        pose_at(staged, frame)
        points = world_vertices()
        for d in range(DIRECTIONS):
            place_camera(staged.camera, d)
            extents.add(points, d)
            path = frames_dir / f"d{d}" / f"f{i:03d}.png"
            render_to(path)
            if touches_border(path):
                clipped.append(f"{entry.name}/d{d}f{i}")
    print(extents.line(entry.name))
    frames = len(staged.frames)
    columns, rows = sheet_layout(frames)
    return {"sheet": f"{entry.name}.png", "frames": frames, "fps": FPS, "loop": entry.loop,
            "impact_frame": impact_index(entry, frames), "stride_m": round(stride_m, 4),
            "columns": columns, "rows_per_direction": rows, "clipped": clipped}


def key_frame(name: str, info: dict[str, Any]) -> int:
    if name == "idle":
        return 0
    if name in ("walk", "run"):
        return info["frames"] // 4
    if name == "die":
        return info["frames"] - 1
    return info["impact_frame"] if info["impact_frame"] >= 0 else info["frames"] // 2


def render_unit(unit: str, src_root: Path, out_root: Path, engine: str = "EEVEE", repo: Path | None = None) -> dict[str, Any]:
    unit_dir = src_root / "units" / unit
    out_dir = out_root / unit
    review = unit_dir / "review"
    repo = repo_root(src_root, repo)
    refuse_planted_links(repo, [unit_dir, review, out_dir])
    spec = load_spec(unit_dir / "spec.toml")
    props = resolve_props(spec, src_root, repo)
    # out_dir and review/ are made by their first write, so a render that
    # stops early (an unknown bone shows only once the rig is loaded) leaves
    # no empty folders behind.
    sidecar: dict[str, Any] = {
        "unit": spec.id, "cell": CELL, "gutter": GUTTER, "stride": STRIDE, "feet_px": FEET_PX,
        "pixels_per_meter": PIXELS_PER_METER, "elevation_deg": ELEVATION_DEG, "directions": DIRECTIONS,
        "die_falls_forward": spec.die_falls_forward, "bursts_on_death": spec.bursts_on_death,
        "gib_color": [0.5, 0.5, 0.5], "clipped": [], "animations": {},
    }
    work = Path(tempfile.mkdtemp(prefix=f"render-{unit}-"))
    try:
        contact: list[Path | None] = []
        for entry in spec.animations:
            frames_dir = work / entry.name
            info = render_animation(spec, animation_file(unit_dir, entry), entry, props, frames_dir, engine)
            sidecar["clipped"] += info.pop("clipped")
            sheet = out_dir / info["sheet"]
            tile(sheet_cells(frames_dir, info["frames"]), info["columns"], DIRECTIONS * info["rows_per_direction"], sheet)
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
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{unit}.json").write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if sidecar["clipped"]:
        print(f"WARNING: {len(sidecar['clipped'])} frames touch the cell edge (clipped): {sidecar['clipped'][:8]} ...")
    return sidecar


def render_attach(unit: str, src_root: Path, engine: str = "EEVEE", repo: Path | None = None) -> Path:
    """The attach preview, for tuning offsets by eye: review/attach.png.

    Columns are directions 0, 2, 4 and 6; rows are idle's first frame, then
    each attack* animation at its impact frame. Cells are twice the game
    cell, through the same camera and pivot, so twice the pixels per metre.
    """
    unit_dir = src_root / "units" / unit
    review = unit_dir / "review"
    repo = repo_root(src_root, repo)
    refuse_planted_links(repo, [unit_dir, review])
    spec = load_spec(unit_dir / "spec.toml")
    props = resolve_props(spec, src_root, repo)
    rows = [e for e in spec.animations if e.name == "idle"] + [e for e in spec.animations if e.name.startswith("attack")]
    if not rows:
        raise RuntimeError(f"{unit} has no idle or attack animation to preview")
    dest = review / "attach.png"
    size = 2 * CELL
    with tempfile.TemporaryDirectory() as tmp:
        cells: list[Path | None] = []
        for entry in rows:
            staged = stage_animation(spec, animation_file(unit_dir, entry), entry, props, engine, size)
            if not cells:
                print(f"bones of {unit}'s rig: {', '.join(b.name for b in staged.armature.pose.bones)}")
            count = len(staged.frames)
            pose_at(staged, staged.frames[key_frame(entry.name, {"frames": count, "impact_frame": impact_index(entry, count)})])
            for d in ATTACH_VIEWS:
                place_camera(staged.camera, d)
                path = Path(tmp) / f"{entry.name}_d{d}.png"
                render_to(path)
                cells.append(path)
        tile(cells, len(ATTACH_VIEWS), len(rows), dest, size)
    print(f"attach: {dest} (rows = {[e.name for e in rows]}; columns = directions {list(ATTACH_VIEWS)}: back, left, front, right)")
    return dest


def candidate_files(folder: Path) -> list[Path]:
    """The Meshy candidates in folder, cand-1.glb first."""
    return sorted(folder.glob("cand-*.glb"), key=lambda p: int(p.stem.split("-")[1]))


def render_candidates(unit: str, src_root: Path, engine: str = "EEVEE", repo: Path | None = None) -> Path:
    unit_dir = src_root / "units" / unit
    refuse_planted_links(repo_root(src_root, repo), [unit_dir, unit_dir / "review"])
    spec = load_spec(unit_dir / "spec.toml")
    files = candidate_files(unit_dir / "candidates")
    if not files:
        raise RuntimeError(f"no candidates in {unit_dir / 'candidates'}; run meshy.py candidates first")
    dest = unit_dir / "review" / "candidates.png"
    with tempfile.TemporaryDirectory() as tmp:
        cells: list[Path | None] = []
        for glb in files:
            reset_scene()
            configure_render(engine)
            camera = make_camera()
            import_glb(glb, require_armature=False)
            holder = adopt_imports(camera)
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


def configure_prop_review() -> bpy.types.Object:
    """Workbench studio light with cavity, clay on a plain light backdrop; returns the camera."""
    configure_render("WORKBENCH", PROP_CELL)
    scene = bpy.context.scene
    scene.render.film_transparent = False
    scene.world = bpy.data.worlds.new("Backdrop")
    scene.world.color = PROP_BACKDROP
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "SINGLE"
    shading.single_color = PROP_CLAY
    shading.show_cavity = True
    shading.cavity_type = "BOTH"
    data = bpy.data.cameras.new("PropCamera")
    data.type = "ORTHO"
    camera = bpy.data.objects.new("PropCamera", data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    return camera


def render_prop_candidates(prop: str, src_root: Path, repo: Path | None = None) -> Path:
    """A prop's candidate sheet: one row per candidates/cand-N.glb, seen from
    the front, side, back and three-quarter above, each framed to its bounds."""
    prop_dir = src_root / "props" / prop
    refuse_planted_links(repo_root(src_root, repo), [prop_dir, prop_dir / "review"])
    load_prop_spec(prop_dir / "spec.toml")  # checks the recipe is there and its id matches
    files = candidate_files(prop_dir / "candidates")
    if not files:
        raise RuntimeError(f"no candidates in {prop_dir / 'candidates'}; run meshy.py prop-candidates {prop} first")
    dest = prop_dir / "review" / "candidates.png"
    with tempfile.TemporaryDirectory() as tmp:
        cells: list[Path | None] = []
        for glb in files:
            reset_scene()
            camera = configure_prop_review()
            import_glb(glb, require_armature=False)
            lo, hi = mesh_bounds()
            centre, reach = (lo + hi) / 2, max((hi - lo).length, 1e-3)
            camera.data.ortho_scale = reach * 1.08  # the bounding sphere fits every view
            camera.data.clip_start = 0.1 * reach
            camera.data.clip_end = 4.0 * reach
            for label, azimuth, elevation in PROP_VIEWS:
                tilt = math.radians(elevation)
                away = Matrix.Rotation(math.radians(azimuth), 3, "Z") @ (FORWARD * math.cos(tilt) + Vector((0.0, 0.0, math.sin(tilt))))
                camera.matrix_world = Matrix.Translation(centre + away * 2.0 * reach) @ (-away).to_track_quat("-Z", "Y").to_matrix().to_4x4()
                path = Path(tmp) / f"{glb.stem}_{label}.png"
                render_to(path)
                cells.append(path)
        tile(cells, len(PROP_VIEWS), len(files), dest, PROP_CELL)
    print(f"prop candidates: {dest} (rows = {[f.stem for f in files]}; columns = {[v[0] for v in PROP_VIEWS]})")
    return dest


def main(argv: list[str]) -> int:
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    parser = argparse.ArgumentParser(prog="render_sprites.py")
    parser.add_argument("name", help="the unit, or with --prop-candidates the prop")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--candidates", action="store_true", help="the unit's Meshy candidates, side by side")
    mode.add_argument("--attach", action="store_true", help="idle and attacks with props, for tuning offsets")
    mode.add_argument("--prop-candidates", action="store_true", help="the prop's Meshy candidates, side by side (Workbench)")
    parser.add_argument("--engine", default="EEVEE", choices=sorted(GAME_ENGINES))
    parsed = parser.parse_args(args)
    if NAME.fullmatch(parsed.name) is None:  # it becomes a folder name under art-src and assets
        parser.error(f"{parsed.name!r} is not a unit or prop name (lowercase letters, digits and _)")
    if parsed.prop_candidates:
        render_prop_candidates(parsed.name, REPO / "art-src", REPO)
    elif parsed.candidates:
        render_candidates(parsed.name, REPO / "art-src", parsed.engine, REPO)
    elif parsed.attach:
        render_attach(parsed.name, REPO / "art-src", parsed.engine, REPO)
    else:
        sidecar = render_unit(parsed.name, REPO / "art-src", REPO / "assets" / "units", parsed.engine, REPO)
        print(f"rendered {parsed.name}: {sorted(sidecar['animations'])} -> assets/units/{parsed.name}/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
