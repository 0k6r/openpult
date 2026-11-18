"""PNG previews with matplotlib: assembly, interior, exploded view, sections, nose angles.

Run: .venv/bin/python render.py [--variant NAME ...]  → out/<variant>/render_*.png
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import trimesh  # noqa: E402
from matplotlib.patches import PathPatch  # noqa: E402
from matplotlib.path import Path as MPath  # noqa: E402
from mpl_toolkits.mplot3d.art3d import Poly3DCollection  # noqa: E402

from params import BUILD_DEFAULT, VARIANT_NOTES, VARIANTS, variant  # noqa: E402
from parts import Builder, M, beam_cone, to_trimesh  # noqa: E402

OUT = Path(__file__).resolve().parent / "out"

COLORS = {
    "tray": "#b9c6d6",
    "lid": "#dfe5ec",
    "nose": "#f0a35e",
    "power": "#5aa469",
    "board": "#2f6db5",
    "switch": "#444444",
    "button": "#8a8a8a",
    "led": "#d62f2f",
    "hinge": "#a0a0a8",
    "screw0": "#a0a0a8",
    "screw1": "#a0a0a8",
    "diode": "#222222",
    "ir": "#6b3fa0",
    "driver": "#c9a227",
    "wires": "#b03a2e",
    "beam": "#ff4d4d",
}
LIGHT = np.array([0.4, -0.6, 0.9]) / np.linalg.norm([0.4, -0.6, 0.9])
HIDDEN = ("board.top", "board.bottom", "switch.solder", "driver.parts", "driver.solder")


def _color(name: str) -> str:
    return COLORS.get(name, COLORS.get(name.split(".")[0], "#999999"))


def _shaded(tm, color, alpha=1.0):
    rgb = np.array(matplotlib.colors.to_rgb(color))
    k = 0.45 + 0.55 * np.clip(tm.face_normals @ LIGHT, 0, 1)
    cols = np.clip(rgb[None, :] * k[:, None], 0, 1)
    return np.hstack([cols, np.full((len(cols), 1), alpha)])


def draw3d(ax, items, elev=28, azim=-58, lims=None, max_edge=4.0, zoom=1.25):
    """items: [(Manifold, colour, alpha)], drawn as one collection.

    Large triangles are split down to max_edge: matplotlib sorts whole polygons by depth,
    and big ones get painted over nearer faces.
    """
    polys, cols, allv = [], [], []
    for m, color, alpha in items:
        if m.is_empty():
            continue
        tm = to_trimesh(m)
        v, f = trimesh.remesh.subdivide_to_size(tm.vertices, tm.faces, max_edge=max_edge, max_iter=12)
        tm = trimesh.Trimesh(v, f, process=False)
        polys.append(tm.vertices[tm.faces])
        cols.append(_shaded(tm, color, alpha))
        allv.append(tm.vertices)
    cols = np.concatenate(cols)
    # edges in the face colour hide the anti-aliasing seams between triangles
    ax.add_collection3d(Poly3DCollection(np.concatenate(polys), facecolors=cols, edgecolors=cols, linewidths=0.3))
    v = np.concatenate(allv)
    lo, hi = (v.min(0), v.max(0)) if lims is None else (np.asarray(lims[0]), np.asarray(lims[1]))
    ax.set_xlim(lo[0], hi[0])
    ax.set_ylim(lo[1], hi[1])
    ax.set_zlim(lo[2], hi[2])
    ax.set_box_aspect(tuple(np.maximum(hi - lo, 1e-3)), zoom=zoom)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off()


def _section_polys(m: M, axis: str, value: float):
    if axis == "y":  # (x, y, z) → (x, z, −y): the slice is drawn in X–Z
        cs = m.transform([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0]]).slice(-value)
    elif axis == "x":  # (x, y, z) → (y, z, x): the slice is drawn in Y–Z
        cs = m.transform([[0, 1, 0, 0], [0, 0, 1, 0], [1, 0, 0, 0]]).slice(value)
    else:
        cs = m.slice(value)
    return [np.asarray(poly) for poly in cs.to_polygons()]


def draw_section(ax, solids, axis, value, title, beams=()):
    for _name, m, color, alpha in solids:
        polys = _section_polys(m, axis, value)
        if not polys:
            continue
        verts, codes = [], []
        for poly in polys:
            verts += [*poly, poly[0]]
            codes += [MPath.MOVETO] + [MPath.LINETO] * (len(poly) - 1) + [MPath.CLOSEPOLY]
        ax.add_patch(PathPatch(MPath(verts, codes), facecolor=color, edgecolor="#333333",
                               linewidth=0.4, alpha=alpha))
    for (a0, b0), (da, db), half, length in beams:
        for s in (-1, 0, 1):
            ang = math.atan2(db, da) + s * math.radians(half)
            ax.plot([a0, a0 + length * math.cos(ang)], [b0, b0 + length * math.sin(ang)],
                    color=COLORS["beam"], lw=0.8 if s else 1.2, ls="--" if s else "-")
    ax.set_aspect("equal")
    ax.autoscale_view()
    ax.set_title(title, fontsize=9)
    ax.tick_params(labelsize=7)
    ax.grid(True, lw=0.3, alpha=0.5)


def _solids(b: Builder, angle: float, with_lid=True, offsets=None):
    a = b.assembly(angle)
    offsets = offsets or {}
    items = []
    for name, m in a.parts.items():
        if name == "lid" and not with_lid:
            continue
        items.append((name, m.translate(offsets.get(name, (0, 0, 0))), _color(name), 1.0))
    for ph in a.phantoms:
        if ph.name in HIDDEN:
            continue
        off = offsets.get(ph.group, offsets.get("phantoms", (0, 0, 0)))
        items.append((ph.name, ph.solid.translate(off), _color(ph.name), 1.0))
    return items


def render_variant(name: str, outdir: Path) -> list[Path]:
    p = variant(name)
    b = Builder(p)
    lay = b.lay
    outdir.mkdir(parents=True, exist_ok=True)
    files = []
    head = f"{name}: {VARIANT_NOTES.get(name, '')}  |  case {lay.L:.1f} × {lay.W:.1f} × {lay.H:.1f} mm"
    u_die = p.led_step_u - p.led_flange_h + p.led_die_h

    # 1. assembly from the front-right (nose, switch) and the back-left (USB-C)
    fig = plt.figure(figsize=(13, 6), dpi=130)
    items = [(m, c, a) for _, m, c, a in _solids(b, p.nose_angle)]
    draw3d(fig.add_subplot(121, projection="3d"), items, elev=24, azim=40)
    draw3d(fig.add_subplot(122, projection="3d"), items, elev=24, azim=-130)
    fig.suptitle(head + f"\nassembly, nose at {p.nose_angle:.0f}°: front-right and back-left views", fontsize=9)
    fig.subplots_adjust(left=0, right=1, bottom=0, top=0.9, wspace=0)
    files.append(_save(fig, outdir / "render_assembly.png"))

    # 2. lid removed: layout
    fig = plt.figure(figsize=(11, 8), dpi=130)
    draw3d(fig.add_subplot(111, projection="3d"),
           [(m, c, a) for _, m, c, a in _solids(b, p.nose_angle, with_lid=False)], elev=58, azim=-70, zoom=1.0)
    fig.suptitle(head + "\nlid removed: power, spine with diode, board bay, switch, RST button, LED wire path", fontsize=9)
    fig.subplots_adjust(left=0, right=1, bottom=0, top=0.92)
    files.append(_save(fig, outdir / "render_interior.png"))

    # 3. exploded view
    off = {"lid": (0, 0, 28), "nose": (0, 18, 0), "led": (0, 18, 0), "hinge": (0, 18, 0),
           "phantoms": (0, 0, 14), "screw0": (0, 0, 40), "screw1": (0, 0, 40)}
    fig = plt.figure(figsize=(11, 9), dpi=130)
    draw3d(fig.add_subplot(111, projection="3d"),
           [(m, c, a) for _, m, c, a in _solids(b, 20.0, offsets=off)], elev=22, azim=-60, zoom=1.05)
    fig.suptitle(head + "\nexploded view", fontsize=9)
    fig.subplots_adjust(left=0, right=1, bottom=0, top=0.93)
    files.append(_save(fig, outdir / "render_exploded.png"))

    # 4. sections
    secs = [(n, m, c, 0.85) for n, m, c, _ in _solids(b, p.nose_angle)]
    fig, axs = plt.subplots(4, 1, figsize=(9, 15), dpi=130)
    yc = (lay.by0 + lay.by1) / 2
    draw_section(axs[0], secs, "y", yc, f"XZ section at y = {yc:.1f} (through the board and the power source)")
    axs[0].set_xlabel("X, mm", fontsize=8)
    draw_section(axs[1], secs, "x", lay.bxc,
                 f"YZ section at x = {lay.bxc:.1f} (board centre: USB-C window, lid fingers and tooth)")
    axs[1].set_xlabel("Y, mm", fontsize=8)
    xs = lay.nose_x + lay.led_xs[0]
    die = lay.led_point(u_die, p.nose_angle, lay.led_xs[0])
    draw_section(axs[2], secs, "x", xs,
                 f"YZ section at x = {xs:.1f} (LED axis: wire passage, wire path, nose at {p.nose_angle:.0f}°)",
                 beams=[((die[1], die[2]), lay.beam_dir(p.nose_angle), p.led_beam_half, 40.0)])
    axs[2].set_xlabel("Y, mm", fontsize=8)
    zc = lay.zp + lay.board.pcb_t / 2
    draw_section(axs[3], [(n, m, c, 0.85) for n, m, c, _ in _solids(b, 0.0)], "z", zc,
                 f"XY section at z = {zc:.1f} (top view at board level, nose at 0°)")
    axs[3].set_xlabel("X, mm", fontsize=8)
    fig.suptitle(head, fontsize=9)
    fig.tight_layout()
    files.append(_save(fig, outdir / "render_sections.png"))

    # 5. nose angles
    fig = plt.figure(figsize=(13, 8.5), dpi=130)
    near = (np.array([lay.nose_x - 22, lay.W - 22, -2.0]), np.array([lay.nose_x + 22, lay.W + 30, 40.0]))
    for i, ang in enumerate((0.0, 45.0, 90.0)):
        ax = fig.add_subplot(2, 3, i + 1)
        die = lay.led_point(u_die, ang, lay.led_xs[0])
        draw_section(ax, [(n, m, c, 0.85) for n, m, c, _ in _solids(b, ang)], "x", xs,
                     f"nose at {ang:.0f}°, section through the LED axis",
                     beams=[((die[1], die[2]), lay.beam_dir(ang), p.led_beam_half, 35.0)])
        ax.set_xlim(lay.W - 30, lay.W + 45)
        ax.set_ylim(-3, 50)
        ax3 = fig.add_subplot(2, 3, i + 4, projection="3d")
        items = [(m, c, a) for _, m, c, a in _solids(b, ang)]
        items.append((beam_cone(lay, ang, 25.0), COLORS["beam"], 0.35))
        draw3d(ax3, items, elev=20, azim=35, lims=near, max_edge=2.5, zoom=1.0)
    fig.suptitle(head + f"\nnose at 0° / 45° / 90°; red: beam cone ±{p.led_beam_half:.0f}°", fontsize=9)
    fig.tight_layout()
    files.append(_save(fig, outdir / "render_nose_angles.png"))
    return files


def _save(fig, path: Path) -> Path:
    fig.savefig(path)
    plt.close(fig)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variant", action="append", choices=sorted(VARIANTS))
    ap.add_argument("--all", action="store_true", help="render every variant, not only the default set")
    args = ap.parse_args()
    names = args.variant or (list(VARIANTS) if args.all else list(BUILD_DEFAULT))
    for name in names:
        for f in render_variant(name, OUT / name):
            print(f)


if __name__ == "__main__":
    main()
