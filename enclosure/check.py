"""Geometry checks for every variant; prints a report, exits with 1 on errors.

Run: .venv/bin/python check.py [--variant NAME ...]
"""

from __future__ import annotations

import argparse
import itertools
import math
import sys
from dataclasses import dataclass

import numpy as np

from params import VARIANT_NOTES, VARIANTS, Layout, Params, variant
from parts import PRINT_NOTES, Builder, M, antenna_zone, bbox, beam_cone, box, to_trimesh

VOL_TOL = 1e-3  # mm³, numerical noise of boolean ops
GAP_TOL = 0.02  # mm


@dataclass
class Result:
    name: str
    ok: bool
    detail: str
    level: str = "error"  # "error" | "info"

    def line(self) -> str:
        mark = "info" if self.level == "info" else ("ok  " if self.ok else "FAIL")
        return f"  [{mark}] {self.name}: {self.detail}"


# --------------------------------------------------------------------------- helpers


def above(m: M, z: float) -> M:
    return m.trim_by_plane([0, 0, 1], z)


def boxes_overlap(a: M, b: M, pad: float = 0.0) -> bool:
    la, ha = bbox(a)
    lb, hb = bbox(b)
    return bool(np.all(la - pad <= hb) and np.all(lb - pad <= ha))


def inter_volume(a: M, b: M) -> float:
    if not boxes_overlap(a, b):
        return 0.0
    return (a ^ b).volume()


def gap(a: M, b: M, search: float) -> float:
    """Minimum distance between two solids, capped at `search`."""
    if not boxes_overlap(a, b, pad=search):
        return search
    return a.min_gap(b, search)


def solid_ok(m: M) -> tuple[bool, str]:
    st = m.status()
    if m.is_empty() or str(st) != "Error.NoError":
        return False, f"empty or invalid ({st})"
    vol = m.volume()
    comps = len(m.decompose())
    tm = to_trimesh(m)  # vertices merged by position, like a slicer reading the STL
    ok = vol > 0 and comps == 1 and tm.is_watertight and tm.is_winding_consistent and tm.volume > 0
    return ok, (f"V={vol / 1000:.2f} cm³, bodies {comps}, watertight={tm.is_watertight}, "
                f"winding={tm.is_winding_consistent}, {len(tm.faces)} triangles")


# --------------------------------------------------------------------------- overhangs


def _components(nodes: np.ndarray, edges: np.ndarray) -> list[np.ndarray]:
    """Connected components via union-find (no scipy/networkx needed)."""
    parent = {int(n): int(n) for n in nodes}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b in edges:
        ra, rb = find(int(a)), find(int(b))
        if ra != rb:
            parent[ra] = rb
    groups: dict[int, list[int]] = {}
    for n in parent:
        groups.setdefault(find(n), []).append(n)
    return [np.array(g) for g in groups.values()]


def _sample_triangles(tris: np.ndarray, step: float) -> np.ndarray:
    """Points on a barycentric grid inside every triangle, about `step` apart."""
    out = []
    for t in tris:
        edge = max(np.linalg.norm(t[1] - t[0]), np.linalg.norm(t[2] - t[1]), np.linalg.norm(t[0] - t[2]))
        n = int(min(max(math.ceil(edge / step), 1), 60))
        i, j = np.meshgrid(np.arange(n + 1), np.arange(n + 1), indexing="ij")
        keep = i + j <= n
        a, b = i[keep] / n, j[keep] / n
        out.append(t[0] + a[:, None] * (t[1] - t[0]) + b[:, None] * (t[2] - t[0]))
    return np.vstack(out)


def overhang_regions(m: M, max_deg: float = 45.0):
    """Down-facing areas steeper than max_deg from vertical, in print orientation.

    For every area returns (reach, area, centre, kind). Reach is the largest XY distance to an
    edge that has support below it (the neighbouring face continues downwards): half the span
    of a bridge, or the length of a cantilever. Kind is "bridge" when the farthest point has
    support on opposite sides, otherwise "cantilever".
    """
    tm = to_trimesh(m)
    n = tm.face_normals
    zmin = tm.bounds[0, 2]
    cz = tm.triangles_center[:, 2]
    lim = math.sin(math.radians(max_deg + 1.0))
    flagged = (-n[:, 2] > lim) & ~(cz < zmin + 1e-3)
    idx = np.nonzero(flagged)[0]
    if len(idx) == 0:
        return []
    adj = tm.face_adjacency
    adj_edges = tm.face_adjacency_edges
    sel = flagged[adj[:, 0]] & flagged[adj[:, 1]]
    verts = tm.vertices
    regions = []
    for g in _components(idx, adj[sel]):
        inside = np.zeros(len(tm.faces), bool)
        inside[g] = True
        border = inside[adj[:, 0]] ^ inside[adj[:, 1]]
        seg = []
        for (f0, f1), (v0, v1) in zip(adj[border], adj_edges[border]):
            other = f1 if inside[f0] else f0
            ez = min(verts[v0, 2], verts[v1, 2])
            if verts[tm.faces[other], 2].min() < ez - 1e-3:
                seg.append((verts[v0, :2], verts[v1, :2]))
        pts = _sample_triangles(tm.triangles[g][:, :, :2], step=0.5)
        kind = "cantilever"
        if not seg:
            span = math.inf
        else:
            a = np.array([s[0] for s in seg])
            ab = np.array([s[1] for s in seg]) - a
            ll = np.maximum((ab ** 2).sum(1), 1e-12)
            t = np.clip(((pts[:, None, :] - a[None]) * ab[None]).sum(2) / ll[None], 0, 1)
            vec = a[None] + t[..., None] * ab[None] - pts[:, None, :]
            dist = np.sqrt((vec ** 2).sum(2))
            k = int(dist.min(1).argmax())
            span = float(dist[k].min())
            v0 = vec[k, int(dist[k].argmin())]
            opposite = (vec[k] @ v0 < -0.25 * span * span) & (dist[k] <= 2 * span + 0.5)
            if span < 1e-6 or opposite.any():
                kind = "bridge"
        regions.append((span, float(tm.area_faces[g].sum()), tm.triangles_center[g].mean(0), kind))
    regions.sort(key=lambda r: -r[0])
    return regions


# --------------------------------------------------------------------------- clearance specs


def _lid_without_plate(b: Builder) -> M:
    lay = b.lay
    return b.lid - box(-1, -1, lay.z_lid - 0.01, lay.L + 1, lay.W + 1, lay.H + 1)


def clearance_specs(b: Builder, angle: float, nose_only: bool = False):
    """(label, solid A, solid B, min gap[, max gap]). Intended contacts are not listed here.

    A max gap is given for parts that hold something in place (lid fingers, hinge cheeks):
    a holder that has drifted away must fail as surely as one that collides.
    """
    hold = b.p.hold_max_extra
    lay, p = b.lay, b.p
    ph = {x.name: x.solid for x in b.static_phantoms}
    tray, lid = b.tray, b.lid
    nose = b.nose(angle)
    led = b.led(angle).solid
    specs = [
        ("nose / cheeks (clamp gap)", nose, tray, p.hinge_gap, p.hinge_gap + 0.05),
        ("nose / case without cheeks", nose, b.tray_body, 0.5),
        ("nose / lid", nose, lid, 0.5),
        ("nose / hinge bolt", nose, ph["hinge.bolt"], (p.m3_hole - p.m3_d) / 2),
        ("LED / case", led, tray, 0.5),
        ("LED / lid", led, lid, 0.5),
    ]
    if nose_only:
        return specs
    zf = p.floor + 0.01
    specs += [
        ("power / walls and ribs", ph["power"], above(tray, zf), p.power_gap),
        ("power / lid, sideways", ph["power"], lid, p.power_gap),
        ("LED wire path / case", ph["wires.led"], tray, 0.2),
        ("LED wire path / lid", ph["wires.led"], lid, 0.2),
        ("power / lid, above (swelling headroom)", ph["power"],
         lid ^ box(lay.pw_x0, lay.pw_y0, 0, lay.pw_x1, lay.pw_y1, lay.H + 1), lay.power.top_gap),
        ("PCB / walls and guides", ph["board.pcb"], above(tray, lay.zp + 0.01),
         min(p.board_end_gap, p.board_side_gap)),
        ("PCB / lid fingers", ph["board.pcb"], lid, p.press_gap, p.press_gap + hold),
        ("USB-C / wall window", ph["board.usb"], tray, p.usb_window_gap),
        ("USB-C / lid finger", ph["board.usb"], lid, p.press_gap, p.press_gap + hold),
        ("top components / case", ph["board.top"], tray, p.board_end_gap),
        ("top components / lid", ph["board.top"], lid, 0.25),
        ("bottom solder / case", ph["board.bottom"], tray, p.board_end_gap),
        ("switch lever / slot", ph["switch.lever"], tray, p.sw_slot_gap),
        ("switch / lid pad", ph["switch.body"], lid, p.press_gap, p.press_gap + hold),
        ("switch pins / case", ph["switch.pins"], tray, 0.3),
        ("switch solder / case", ph["switch.solder"], tray, 0.3),
        ("switch solder / lid", ph["switch.solder"], lid, 0.3),
    ]
    if p.reset_button:
        specs += [
            ("button / post rails", ph["button.body"], above(tray, lay.btn_z0 + 0.01), p.btn_gap),
            ("button legs / post", ph["button.legs"], tray, 0.3),
            ("button plunger / lid tube", ph["button.plunger"], lid, 0.2),
            ("button / lid tube", ph["button.body"], lid, p.btn_boss_gap, p.btn_boss_gap + hold),
        ]
    if "diode" in ph:
        specs += [("diode / case", ph["diode"], tray, 0.3), ("diode / lid", ph["diode"], lid, 0.3)]
    if p.ir_rx == "back":
        specs += [("IR lens / wall hole", ph["ir.dome"], tray, (p.ir_hole_d - p.ir_dome_d) / 2),
                  ("IR leads / case", ph["ir.leads"], tray, 0.25),
                  ("IR / lid pad and wedge", ph["ir.body"], lid, p.press_gap, p.press_gap + hold)]
    elif p.ir_rx == "lid":
        specs += [("IR lens / lid hole", ph["ir.dome"], lid, (p.ir_hole_d - p.ir_dome_d) / 2),
                  ("IR / post rails", ph["ir.body"], above(tray, lay.z_lid - 0.3 - p.ir_d + 0.01), p.ir_gap),
                  ("IR / lid", ph["ir.body"], lid, 0.25)]
    if p.driver:
        specs += [("driver parts / case", ph["driver.parts"], tray, 0.3),
                  ("driver parts / lid", ph["driver.parts"], lid, 0.3),
                  ("driver solder / case", ph["driver.solder"], tray, 0.3),
                  ("driver perfboard / lid finger", ph["driver.pcb"], lid, 0.15, 0.2 + hold)]
    need = 0.15 if lay.snaps else p.fit_gap
    specs.append(("lid rim and features / case", _lid_without_plate(b), tray, need))
    return specs


# --------------------------------------------------------------------------- checks


def run_checks(p: Params) -> list[Result]:
    b = Builder(p)
    lay: Layout = b.lay
    res: list[Result] = []
    add = res.append
    static = b.static_phantoms
    angles = p.nose_check_angles

    # overall size
    y_max0 = max(bbox(b.nose(0.0))[1][1], bbox(b.led(0.0).solid)[1][1])
    z_max90 = max(bbox(b.nose(90.0))[1][2], bbox(b.led(90.0).solid)[1][2])
    add(Result("size", True,
               f"case {lay.L:.1f} × {lay.W:.1f} × {lay.H:.1f} mm (no feet); depth with cheeks and nose at 0°: "
               f"{y_max0:.1f} mm; height with nose at 90°: {z_max90:.1f} mm; feet add {p.foot_protrusion:.1f} mm",
               level="info"))
    add(Result("case height without nose", lay.H <= p.max_body_height + 1e-6,
               f"{lay.H:.1f} mm (limit {p.max_body_height:.0f})"))

    # printed parts
    pp = b.print_parts()
    for pn, m in pp.items():
        ok, detail = solid_ok(m)
        add(Result(f"{pn}: manifold, watertight, one body", ok, detail))
        lo, hi = bbox(m)
        size = hi - lo
        room_x, room_y = p.bed_x - 2 * p.bed_margin, p.bed_y - 2 * p.bed_margin
        fits = (size[0] <= room_x and size[1] <= room_y) or (size[1] <= room_x and size[0] <= room_y)
        add(Result(f"{pn}: fits a {p.bed_x:.0f}×{p.bed_y:.0f} bed", fits,
                   f"{size[0]:.1f} × {size[1]:.1f} × {size[2]:.1f} mm, {PRINT_NOTES[pn]}"))
        regs = overhang_regions(m, p.max_overhang_deg)
        bridges = [r[0] for r in regs if r[3] == "bridge"]
        canti = [r[0] for r in regs if r[3] == "cantilever"]
        bad = [r for r in bridges if r > p.max_bridge / 2] + [r for r in canti if r > p.max_cantilever]
        add(Result(f"{pn}: overhangs > {p.max_overhang_deg:.0f}°", not bad,
                   (f"{len(regs)} areas, {sum(r[1] for r in regs):.1f} mm²; longest bridge "
                    f"{2 * max(bridges, default=0):.1f} mm (limit {p.max_bridge:.0f}), longest one-sided overhang "
                    f"{max(canti, default=0):.1f} mm (limit {p.max_cantilever:.0f})") if regs else "none"))

    # interference of parts and phantoms in the assembly, at several nose angles
    worst_v, worst_pair = 0.0, "-"
    for ang in angles:
        solids = [("tray", "tray", b.tray), ("lid", "lid", b.lid), ("nose", "nose", b.nose(ang))]
        solids += [(x.name, x.group, x.solid) for x in static]
        led = b.led(ang)
        solids.append((led.name, led.group, led.solid))
        for (na, ga, ma), (nb, gb, mb) in itertools.combinations(solids, 2):
            if ga == gb:
                continue
            moving = {"nose", "led"} & {na, nb}
            if ang != angles[0] and not moving:
                continue
            v = inter_volume(ma, mb)
            if v > max(worst_v, VOL_TOL / 10):
                worst_v, worst_pair = v, f"{na} ∩ {nb} at {ang:.0f}°"
    add(Result(f"no interference (all pairs, nose at {len(angles)} angles {angles[0]:.0f}…{angles[-1]:.0f}°)",
               worst_v <= VOL_TOL, f"max overlap {worst_v:.4f} mm³ ({worst_pair})"))

    # minimum clearances
    measured: dict[str, tuple[float, float, float | None, float, float]] = {}  # min, need, max, angle, max seen
    for ang in angles:
        for spec in clearance_specs(b, ang, nose_only=ang != angles[0]):
            label, ma, mb, need = spec[:4]
            most = spec[4] if len(spec) > 4 else None
            g = gap(ma, mb, (most if most is not None else need) + 1.0)
            cur = measured.get(label)
            if cur is None:
                measured[label] = (g, need, most, ang, g)
            else:
                lo = min(cur[0], g)
                measured[label] = (lo, need, most, cur[3] if lo == cur[0] else ang, max(cur[4], g))
    fails = []
    for k, (g, need, most, ang, g_max) in measured.items():
        if g < need - GAP_TOL:
            fails.append(f"{k} {g:.2f} < {need:.2f} (nose {ang:.1f}°)")
        if most is not None and g_max > most + GAP_TOL:
            fails.append(f"{k} {g_max:.2f} > {most:.2f}: holder too far away")
    detail = "; ".join(fails) if fails else "; ".join(
        f"{k} {g:.2f}" + (f"…{g_max:.2f}" if g_max - g > 0.005 else "")
        for k, (g, _n, _m, _a, g_max) in measured.items())
    add(Result(f"clearances ({len(measured)} specs, min and holder max)", not fails, detail))

    pg, pair = 9.9, "-"
    for x, y in itertools.combinations(static, 2):
        if x.group != y.group:
            g = gap(x.solid, y.solid, 1.0)
            if g < pg:
                pg, pair = g, f"{x.name} / {y.name}"
    add(Result("components keep ≥ 0.3 mm from each other", pg >= 0.3 - GAP_TOL,
               f"closest pair {pair}: {pg:.2f} mm" if pg < 1.0 else "all pairs ≥ 1 mm apart"))

    bd = lay.board
    engage = bd.usb_overhang - p.board_end_gap - p.tooth_gap - p.pcb_l_tol
    add(Result("USB-C stays in the wall window", engage >= p.usb_min_engage - 1e-6,
               f"with the board pushed against the lid tooth and {p.pcb_l_tol:.1f} mm shorter than pcb_l, the "
               f"receptacle is still {engage:.2f} mm into the window (need ≥ {p.usb_min_engage:.1f})"))
    lever = lay.sw_x_face + p.sw_lever_len - lay.L
    add(Result("switch lever reachable", lever >= 1.0,
               f"lever sticks out {lever:.1f} mm past the right wall (sw_lever_len {p.sw_lever_len:.1f}; "
               f"a 3 mm SS12D00G3 lever gives {lay.sw_x_face + 3.0 - lay.L:.1f} mm)"))
    recess = lay.usb_y0 - lay.usb_recess_y
    add(Result("USB-C plug seats fully", recess <= p.usb_face_max_recess + 1e-6,
               f"receptacle face {recess:.2f} mm behind the plug recess (limit {p.usb_face_max_recess:.1f}); "
               f"wall at the connector {p.wall - lay.usb_recess_y:.1f} mm"))

    zmin = min(bbox(b.nose(a))[0][2] for a in angles)
    add(Result("nose clears the table", zmin >= 0.0,
               f"lowest point of the nose z = {zmin:.2f} mm (table at z = −{p.foot_protrusion:.1f})"))

    # beam
    blockers = [b.tray, b.lid] + [x.solid for x in static if x.group == "hinge" or x.name.startswith("screw")]
    worst_b, worst_a = 0.0, None
    for ang in range(0, 91, 5):
        cone = beam_cone(lay, float(ang))
        for s in blockers + [b.nose(float(ang))]:
            v = inter_volume(cone, s)
            if v > worst_b:
                worst_b, worst_a = v, ang
    add(Result(f"beam cone ±{p.led_beam_half:.0f}° is clear at 0…90°", worst_b <= VOL_TOL,
               "150 mm cone misses the case, lid, nose and hardware" if worst_b <= VOL_TOL
               else f"overlap {worst_b:.2f} mm³ at {worst_a}°"))

    # antenna
    az = antenna_zone(lay)
    dmin, who = 99.0, ""
    worst, who, need_w = math.inf, "", 0.0
    for x in [x for x in static if x.antenna_gap > 0] + [b.led(0.0)]:
        g = gap(az, x.solid, 30.0)
        if g - x.antenna_gap < worst:
            worst, who, need_w, dmin = g - x.antenna_gap, x.name, x.antenna_gap, g
    plastic = gap(az, above(b.tray, lay.zp_top + p.guide_above + 0.01), 10.0)
    wires = gap(az, next(x.solid for x in static if x.name == "wires.led"), 30.0)
    add(Result("antenna keeps away from metal", worst >= -GAP_TOL,
               f"tightest: {who} at {dmin:.1f} mm (need ≥ {need_w:.1f}); LED wire path {wires:.1f} mm; "
               f"nearest wall {plastic:.1f} mm; above the antenna only the {p.lid_t:.1f} mm lid and the lid finger"))

    add(_center_of_mass(b))

    est = []
    for pn, m in pp.items():
        v = m.volume() / 1000 * p.fill_factor
        est.append(f"{pn} ≈ {v * p.density:.0f} g / {v * 1000 / p.print_flow_mm3s / 60:.0f} min")
    add(Result("print estimate (PETG)", True, "; ".join(est), level="info"))
    add(Result("nose angle to hit the TV sensor", True, _angle_table(lay), level="info"))
    add(Result("hardware", True, hardware_list(lay), level="info"))
    return res


def _center_of_mass(b: Builder) -> Result:
    p, lay = b.p, b.lay
    fixed = []
    for m in (b.tray, b.lid):
        fixed.append((m.volume() / 1000 * p.density * p.fill_factor, to_trimesh(m).center_mass))
    poly = np.array(lay.feet)[[0, 1, 3, 2]]
    worst, com_w, total = math.inf, None, 0.0
    for ang in (0.0, 90.0):
        items = list(fixed)
        n = b.nose(ang)
        items.append((n.volume() / 1000 * p.density * p.fill_factor, to_trimesh(n).center_mass))
        for ph in [*b.static_phantoms, b.led(ang)]:
            if ph.mass > 0:
                lo, hi = bbox(ph.solid)
                items.append((ph.mass, (lo + hi) / 2))
        items.append((p.hardware_mass, np.array([lay.L / 2, lay.W / 2, lay.H / 2])))
        mass = sum(w for w, _ in items)
        com = sum(w * np.asarray(c) for w, c in items) / mass
        d = _inside_margin(com[:2], poly)
        if d < worst:
            worst, com_w, total = d, com, mass
    return Result("centre of mass over the feet", worst >= p.com_margin,
                  f"mass ≈ {total:.0f} g with batteries, CoM ({com_w[0]:.1f}, {com_w[1]:.1f}, {com_w[2]:.1f}); "
                  f"{worst:.1f} mm inside the feet outline (need ≥ {p.com_margin:.0f})")


def _inside_margin(pt, poly) -> float:
    """Distance from a point to the boundary of a convex polygon (negative when outside)."""
    n = len(poly)
    area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))
    sgn = 1 if area > 0 else -1
    d = math.inf
    for i in range(n):
        a, c = np.asarray(poly[i], float), np.asarray(poly[(i + 1) % n], float)
        e = c - a
        nrm = np.array([e[1], -e[0]]) * sgn  # outward normal
        nrm /= np.linalg.norm(nrm)
        d = min(d, -float(np.dot(np.asarray(pt) - a, nrm)))
    return d


def required_angle(lay: Layout, dist: float, height: float) -> float:
    """Nose angle that puts the beam axis on the TV sensor.

    dist — horizontal distance from the LED to the sensor, height — sensor height above the table.
    """
    p = lay.p
    u_die = p.led_step_u - p.led_flange_h + p.led_die_h
    y0 = lay.led_point(u_die, 0.0)[1]
    ty, tz = y0 + dist, height - p.foot_protrusion
    th = 30.0
    for _ in range(50):
        _, y, z = lay.led_point(u_die, th)
        th = math.degrees(math.atan2(tz - z, ty - y))
    return th


def _angle_table(lay: Layout) -> str:
    rows = []
    for d in (50, 100, 150):
        cells = ", ".join(f"h {h} → {required_angle(lay, d, h):.0f}°" for h in (30, 50, 80))
        rows.append(f"{d} mm away: {cells}")
    return "; ".join(rows)


def hardware_list(lay: Layout) -> str:
    p = lay.p
    s = f"M3×{lay.bolt_len:.0f} bolt (ISO 4762 / DIN 912) + M3 nyloc nut (DIN 985) for the nose"
    if lay.snaps:
        s += "; lid: 3 snap hooks"
    else:
        s += f"; lid: 2 self-tapping screws for plastic, 3 × {p.lid_screw_len:.0f} mm pan head"
    s += f"; 4 stick-on feet Ø{p.foot_d:.0f} mm, ~{p.foot_depth + p.foot_protrusion:.0f} mm thick"
    return s


def report(name: str, results: list[Result]) -> bool:
    print(f"\n=== {name}: {VARIANT_NOTES.get(name, '')} ===")
    for r in results:
        print(r.line())
    errors = [r for r in results if not r.ok and r.level == "error"]
    print(f"  result: {'OK' if not errors else f'{len(errors)} failed'}")
    return not errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variant", action="append", choices=sorted(VARIANTS))
    args = ap.parse_args()
    ok = True
    for name in args.variant or list(VARIANTS):
        ok &= report(name, run_checks(variant(name)))
    print("\nALL CHECKS PASSED" if ok else "\nCHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
