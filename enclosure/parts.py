"""Geometry of the printed parts and of phantom (bought) components, built with manifold3d.

Printed parts: tray (case body), lid, nose (LED holder).
Phantoms are bounding solids of the components and hardware, used for clearance
checks and renders; they only go into assembly.stl, never into the print files.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from functools import cached_property

import manifold3d as m3
import numpy as np
import trimesh

from params import Layout, Params

M = m3.Manifold
CS = m3.CrossSection


# --------------------------------------------------------------------------- primitives


def box(x0, y0, z0, x1, y1, z1) -> M:
    lo = np.minimum([x0, y0, z0], [x1, y1, z1])
    hi = np.maximum([x0, y0, z0], [x1, y1, z1])
    return M.cube((hi - lo).tolist()).translate(lo.tolist())


def union(items) -> M:
    items = [m for m in items if m is not None and not m.is_empty()]
    if not items:
        return M()
    return M.batch_boolean(items, m3.OpType.Add)


def cyl_z(r, z0, z1, x, y, seg) -> M:
    return M.cylinder(z1 - z0, r, r, seg).translate([x, y, z0])


def cyl_x(r, x0, x1, y, z, seg) -> M:
    return M.cylinder(x1 - x0, r, r, seg).rotate([0, 90, 0]).translate([x0, y, z])


def cyl_y(r, y0, y1, x, z, seg) -> M:
    return M.cylinder(y1 - y0, r, r, seg).rotate([-90, 0, 0]).translate([x, y0, z])


def prism_x(cs: CS, x0, x1) -> M:
    """Section (a, b) → plane (y, z), extruded along X from x0 to x1."""
    return M.extrude(cs, x1 - x0).transform([[0, 0, 1, x0], [1, 0, 0, 0], [0, 1, 0, 0]])


def prism_y(cs: CS, y0, y1) -> M:
    """Section (a, b) → plane (x, z), extruded along Y from y0 to y1."""
    return M.extrude(cs, y1 - y0).transform([[1, 0, 0, 0], [0, 0, -1, y1], [0, 1, 0, 0]])


def prism_z(cs: CS, z0, z1) -> M:
    return M.extrude(cs, z1 - z0).translate([0, 0, z0])


def rect(a0, b0, a1, b1) -> CS:
    return CS.square([a1 - a0, b1 - b0]).translate([a0, b0])


def circle(r, a, b, seg) -> CS:
    return CS.circle(r, seg).translate([a, b])


def polygon(points) -> CS:
    return CS([np.asarray(points, dtype=float)], m3.FillRule.NonZero)


def teardrop(r, a, b, seg, tip=(0.0, 1.0)) -> CS:
    """Circle with a 45° pointed top (towards `tip`): horizontal holes print without support."""
    tx, ty = tip
    k = r * math.sqrt(2.0)
    point = polygon([(a + tx * k - ty * 0.01, b + ty * k + tx * 0.01),
                     (a + tx * k + ty * 0.01, b + ty * k - tx * 0.01),
                     (a, b)])
    return CS.batch_hull([circle(r, a, b, seg), point])


def stadium(w, h, a, b, seg) -> CS:
    r = h / 2
    dx = max(w / 2 - r, 0.0)
    return CS.batch_hull([circle(r, a - dx, b, seg), circle(r, a + dx, b, seg)])


def hexagon(af, a, b) -> CS:
    """Hexagon with a flat on top (+b): a short horizontal bridge, the other faces at 60°."""
    rc = af / math.sqrt(3.0)
    return polygon([(a + rc * math.cos(math.radians(60 * i)), b + rc * math.sin(math.radians(60 * i)))
                    for i in range(6)])


def rounded_rect(x0, y0, x1, y1, r, seg) -> CS:
    return rect(x0 + r, y0 + r, x1 - r, y1 - r).offset(r, m3.JoinType.Round, 2.0, seg)


def to_trimesh(m: M) -> trimesh.Trimesh:
    mesh = m.to_mesh()
    return trimesh.Trimesh(
        vertices=np.asarray(mesh.vert_properties)[:, :3].astype(np.float64),
        faces=np.asarray(mesh.tri_verts).astype(np.int64),
        process=True,
    )


def bbox(m: M) -> np.ndarray:
    return np.asarray(m.bounding_box(), dtype=float).reshape(2, 3)


# --------------------------------------------------------------------------- shell outlines


def _outlines(lay: Layout):
    p = lay.p
    seg = p.segments
    outer = rounded_rect(0, 0, lay.L, lay.W, p.corner_r, seg)
    inner = rect(p.wall, p.wall, lay.L - p.wall, lay.W - p.wall)
    tongue = inner.offset(p.tongue_t, m3.JoinType.Round, 2.0, seg)
    return outer, inner, tongue


def _snap_specs(lay: Layout):
    """Snap hooks: (normal axis, inward sign, wall face coordinate, centre along the wall, width)."""
    p = lay.p
    sx = (lay.spine_x0 + lay.spine_x1) / 2
    w_spine = min(p.snap_w, p.spine_w - 0.6)
    return [
        ("x", +1, p.wall, (lay.in_y0 + lay.in_y1) / 2, p.snap_w),
        ("y", +1, lay.in_y0, sx, w_spine),
        ("y", -1, lay.in_y1, sx, w_spine),
    ]


def _wall_local(axis, sign, face, center, s0, s1, d0, d1, z0, z1) -> M:
    """Block in wall-local coordinates: s along the wall, d inward from the wall face."""
    if axis == "x":
        return box(face + sign * d0, center + s0, z0, face + sign * d1, center + s1, z1)
    return box(center + s0, face + sign * d0, z0, center + s1, face + sign * d1, z1)


def _wall_prism(axis, sign, face, center, half_w, profile_dz) -> M:
    """Prism running along a wall; profile_dz is a list of (d, z), d measured inward."""
    pts = [(face + sign * d, z) for d, z in profile_dz]
    cs = polygon(pts)
    if axis == "x":
        return prism_y(cs, center - half_w, center + half_w)
    return prism_x(cs, center - half_w, center + half_w)


def _snap_zb(lay: Layout) -> float:
    p = lay.p
    return lay.z_lid - p.snap_len + p.snap_bump + 0.5


# --------------------------------------------------------------------------- tray


def tray(lay: Layout, with_cheeks: bool = True) -> M:
    p = lay.p
    seg = p.segments
    w = p.wall
    b = lay.board
    outer, inner, tongue = _outlines(lay)
    # Shell = outer prism + tongue − interior. Internal features start inside the floor
    # (z0) so no faces of the union are coplanar: coplanar unions leave pinched
    # vertices that turn into non-manifold edges once the STL is re-merged.
    shell = prism_z(outer, 0, lay.z_step) + prism_z(tongue, lay.z_step - 0.5, lay.z_lid)
    shell -= prism_z(inner, p.floor, lay.H + 1)
    z0 = p.floor / 2
    add = [shell]
    cut = []

    # recesses for stick-on feet
    for fx, fy in lay.feet:
        cut.append(cyl_z(p.foot_d / 2, -1, p.foot_depth, fx, fy, seg))

    # power bay: divider, full height only at its ends so the holder's leads can cross it
    # anywhere; a front fence when the pocket is deeper than the power source
    div_h = min(p.divider_h, lay.power.h * 0.6)
    dy0, dy1 = lay.in_y0, lay.in_y1
    if lay.snaps:
        dy0, dy1 = dy0 + 2.0, dy1 - 2.0  # leave room for the spine snap hooks
    dx0, dx1 = lay.spine_x0, lay.spine_x0 + p.divider_t
    add.append(box(dx0, dy0, z0, dx1, dy1, p.floor + p.divider_low_h))
    add.append(box(dx0, dy0, z0, dx1, dy0 + p.divider_post_w, p.floor + div_h))
    add.append(box(dx0, dy1 - p.divider_post_w, z0, dx1, dy1, p.floor + div_h))
    if lay.has_fence:
        fy = lay.pw_y1 + p.power_gap
        add.append(box(w - 0.5, fy, z0, lay.spine_x0 + 0.01, fy + p.fence_t, p.floor + lay.fence_h))

    # lid fastening: screw bosses, or grooves for the snap hooks
    if not lay.snaps:
        r = p.boss_d / 2
        for (bx, by), toward in zip(lay.boss_xy, (-1, +1)):
            add.append(cyl_z(r, z0, lay.z_lid, bx, by, seg))
            add.append(box(bx - r, by, z0, bx + r, by + toward * (r + 0.5), lay.z_lid))
            cut.append(cyl_z(p.pilot_d / 2, lay.z_lid - p.pilot_depth, lay.z_lid + 1, bx, by, seg))
    else:
        zb = _snap_zb(lay)
        g = p.snap_groove
        for axis, sign, face, center, sw in _snap_specs(lay):
            cut.append(_wall_prism(axis, sign, face, center, sw / 2 + 0.5,
                                   [(0.01, zb - g - 0.01), (-g, zb), (0.01, zb + g + 0.01)]))

    # board: USB-C window with a recess outside for the plug, shelf and guides at the antenna edge
    win = stadium(b.usb_w + 2 * p.usb_window_gap, b.usb_h + 2 * p.usb_window_gap, lay.bxc, lay.usb_zc, seg)
    cut.append(prism_y(win, -1, lay.in_y0 + 0.5))
    plug = stadium(p.usb_plug_w, p.usb_plug_h, lay.bxc, lay.usb_zc, seg)
    cut.append(prism_y(plug, -1, lay.usb_recess_y))
    add.append(box(lay.bxc - b.shelf_w / 2, lay.by1 - b.shelf_d, z0, lay.bxc + b.shelf_w / 2, lay.by1, lay.zp))
    gz = lay.zp_top + p.guide_above
    g0 = p.board_side_gap
    add.append(box(lay.bx0 - g0 - p.guide_t, lay.by1 - p.guide_len, z0, lay.bx0 - g0, lay.by1, gz))
    add.append(box(lay.bx1 + g0, lay.by1 - p.guide_len, z0, lay.bx1 + g0 + p.guide_t, lay.by1, gz))

    # slide switch: pocket in the right wall, open at the top; the lid holds the body down
    yc, hy = lay.sw_yc, lay.sw_half_y
    add.append(box(lay.sw_plate_x0, yc - hy, z0, lay.bc_x1 + 0.5, yc + hy, lay.sw_z1))
    cut.append(box(lay.sw_cav_x0, yc - (p.sw_l / 2 + p.sw_gap), lay.sw_z0,
                   lay.sw_x_face, yc + (p.sw_l / 2 + p.sw_gap), lay.H + 1))
    cut.append(box(lay.sw_plate_x0 - 0.1, yc - (p.sw_pin_pitch + 1.0), lay.sw_z0 + 0.5,
                   lay.sw_cav_x0 + 0.01, yc + (p.sw_pin_pitch + 1.0), lay.H + 1))
    slot_l = p.sw_lever_w + p.sw_travel + 2 * p.sw_slot_gap
    cut.append(box(lay.sw_x_face - 0.01, yc - slot_l / 2, lay.sw_zc - p.sw_lever_t / 2 - p.sw_slot_gap,
                   lay.L + 1, yc + slot_l / 2, lay.H + 1))

    # RST button: post with side rails; the legs hang down beside the post
    if p.reset_button:
        hx = p.btn_rib_w / 2
        hy = p.btn_size / 2 + p.btn_gap + p.btn_rail_t
        add.append(box(lay.btn_xc - hx, lay.btn_yc - hy, z0, lay.btn_xc + hx, lay.btn_yc + hy, lay.btn_z0))
        for s in (-1, 1):
            y_in = lay.btn_yc + s * (p.btn_size / 2 + p.btn_gap)
            add.append(box(lay.btn_xc - hx, y_in, lay.btn_z0 - 0.01, lay.btn_xc + hx,
                           y_in + s * p.btn_rail_t, lay.btn_z0 + p.btn_rail_h))

    # IR receiver
    if p.ir_rx == "back":
        c, zi, y0 = lay.aux_xc, lay.ir_z0, lay.in_y0
        hw = p.ir_w / 2 + p.ir_gap
        # The receiver is lowered in set back from the wall, then pushed forward so the lens enters
        # the hole; a wedge on the lid then fills the space behind it. Side posts guide both.
        add.append(box(c - hw, y0 - 0.5, z0, c + hw, y0 + 1.2, zi))  # ledge in front of the leads
        y_post = y0 + p.ir_d + p.ir_dome_h + 0.4 + p.ir_wedge_t
        for s in (-1, 1):
            add.append(box(c + s * hw, y0 - 0.5, z0, c + s * (hw + p.ir_post_t), y_post, zi + p.ir_h - 0.5))
        zl = zi + p.ir_lens_z
        cut.append(cyl_y(p.ir_hole_d / 2, -1, y0 + 0.5, c, zl, seg))
        ch = 0.8  # 45° chamfer outside widens the acceptance angle
        cone = M.cylinder(ch, p.ir_hole_d / 2, p.ir_hole_d / 2 + ch, seg)
        cut.append(cone.rotate([90, 0, 0]).translate([c, ch, zl]))
        cut.append(cyl_y(p.ir_hole_d / 2 + ch, -1, 0.0, c, zl, seg))
    elif p.ir_rx == "lid":
        c = lay.aux_xc
        hw = p.ir_w / 2 + p.ir_gap
        zb = lay.z_lid - 0.3 - p.ir_d
        yb0, yb1 = lay.ir_yb0, lay.ir_yb0 + p.ir_h
        ys = yb0 - p.ir_gap - 1.2
        add.append(box(c - hw - p.btn_rail_t, ys, z0, c + hw + p.btn_rail_t, yb1 - 1.0, zb))
        for s in (-1, 1):
            add.append(box(c + s * hw, ys, zb - 0.01, c + s * (hw + p.btn_rail_t), yb1 - 1.0, zb + 2.0))
        add.append(box(c - hw - p.btn_rail_t, ys, zb - 0.01, c + hw + p.btn_rail_t, yb0 - p.ir_gap, zb + 2.0))

    # driver: the perfboard stands upright in the slots of two posts
    if p.driver:
        x, t, gq = lay.drv_x, p.drv_t, p.drv_slot_gap
        top = lay.drv_z0 + p.drv_h - 1.0
        posts = [
            (lay.drv_y1 - 1.2, lay.in_y1 + 0.5, lay.drv_y1 - 1.21, lay.drv_y1 + gq),
            (lay.drv_y0 - gq - 1.5, lay.drv_y0 + 1.2, lay.drv_y0 - gq, lay.drv_y0 + 1.21),
        ]
        for ya, yb, ga, gb in posts:
            add.append(box(x - 2.0, ya, z0, x + 2.0, yb, top))
            cut.append(box(x - t / 2 - gq / 2, ga, lay.drv_z0, x + t / 2 + gq / 2, gb, lay.H))

    # LED wire passage through the front wall
    zw = lay.z_A - p.led_offset
    cut.append(prism_y(teardrop(lay.wire_hole_d / 2, lay.wire_x, zw, seg), lay.in_y1 - 0.5, lay.W + 0.5))

    body = union(add) - union(cut)
    if not with_cheeks:
        return body
    return body + cheeks(lay)


def cheeks(lay: Layout) -> M:
    """Two hinge cheeks in front of the front wall; the axle is an M3 bolt with a nyloc nut."""
    p = lay.p
    seg = p.segments
    prof = CS.batch_hull([
        rect(lay.W - 1.0, 0, lay.y_A + 2.0, lay.z_A),
        circle(p.cheek_r, lay.y_A, lay.z_A, seg),
    ])
    xl0, xl1 = lay.nose_x - lay.cheek_out, lay.nose_x - lay.cheek_in
    xr0, xr1 = lay.nose_x + lay.cheek_in, lay.nose_x + lay.cheek_out
    c = prism_x(prof, xl0, xl1) + prism_x(prof, xr0, xr1)
    # above the rebate the cheeks stand clear of the lid
    c -= box(xl0 - 1, lay.W - 3, lay.z_step, xr1 + 1, lay.W + 0.3, lay.H + 5)
    c -= prism_x(teardrop(p.m3_hole / 2, lay.y_A, lay.z_A, seg), xl0 - 1, xr1 + 1)
    # nut pocket on the outside of the right cheek
    hexcs = hexagon(p.m3_nut_af + p.nut_pocket_gap, lay.y_A, lay.z_A)
    c -= prism_x(hexcs, xr1 - p.nut_pocket_depth, xr1 + 1)
    # angle scale on the left cheek: ticks every 15°, long ones at 0/45/90
    for ang in range(0, 91, 15):
        r0 = 4.0 if ang % 45 == 0 else 4.7
        r1 = p.cheek_r - 0.5
        tick = rect(r0, -p.tick_w / 2, r1, p.tick_w / 2).rotate(ang).translate([lay.y_A, lay.z_A])
        c -= prism_x(tick, xl0 - 0.1, xl0 + p.tick_depth)
    return c


# --------------------------------------------------------------------------- lid


def lid(lay: Layout) -> M:
    p = lay.p
    seg = p.segments
    b = lay.board
    outer, inner, _tongue = _outlines(lay)
    # a single offset from the interior: offsetting an already rounded contour adds slivers
    rim_in = inner.offset(p.tongue_t + p.fit_gap, m3.JoinType.Round, 2.0, seg)
    add = [prism_z(outer, lay.z_step + p.fit_gap, lay.H) - prism_z(rim_in, lay.z_step, lay.z_lid)]
    cut = []
    top = lay.z_lid + 0.01

    # finger on the USB-C shell
    hx = min(p.finger_w / 2, b.usb_w / 2 - 0.5)
    add.append(box(lay.bxc - hx, lay.by0 + 0.5, lay.usb_z1 + p.press_gap,
                   lay.bxc + hx, lay.by0 + 0.5 + p.usb_finger_len, top))
    # finger on the antenna edge of the PCB, with a tooth that stops the board sliding forward
    hx = p.finger_w / 2
    add.append(box(lay.bxc - hx, lay.by1 - b.press_len, lay.zp_top + p.press_gap,
                   lay.bxc + hx, lay.by1 + p.tooth_gap, top))
    add.append(box(lay.bxc - hx, lay.by1 + p.tooth_gap, lay.zp - p.tooth_below,
                   lay.bxc + hx, lay.by1 + p.tooth_gap + p.tooth_t, top))
    # hold-down pad for the slide switch
    add.append(box(lay.sw_cav_x0 + 0.2, lay.sw_yc - (p.sw_l / 2 + p.sw_gap - 0.2), lay.sw_z1 + p.press_gap,
                   lay.sw_x_face - 0.2, lay.sw_yc + (p.sw_l / 2 + p.sw_gap - 0.2), top))
    # paperclip guide tube over the RST button
    if p.reset_button:
        zt = lay.btn_z1 + p.btn_boss_gap
        tube = cyl_z(p.btn_boss_od / 2, zt, top, lay.btn_xc, lay.btn_yc, seg)
        tube -= cyl_z(p.btn_boss_id / 2, zt - 1, lay.z_lid, lay.btn_xc, lay.btn_yc, seg)
        add.append(tube)
        cut.append(cyl_z(p.btn_hole_d / 2, lay.z_lid - 1, lay.H + 1, lay.btn_xc, lay.btn_yc, seg))
    # IR receiver
    if p.ir_rx == "back":
        c, y0 = lay.aux_xc, lay.in_y0
        hw = p.ir_w / 2 - 0.3
        add.append(box(c - hw, y0 + 0.3, lay.ir_z0 + p.ir_h + p.press_gap, c + hw, y0 + p.ir_d - 0.3, top))
        # wedge behind the receiver keeps the lens in the wall hole
        yw = y0 + p.ir_d + p.press_gap
        add.append(box(c - hw, yw, lay.ir_z0 + 1.0, c + hw, yw + p.ir_wedge_t, top))
    elif p.ir_rx == "lid":
        yl = lay.ir_yb0 + p.ir_h - p.ir_lens_z
        cut.append(cyl_z(p.ir_hole_d / 2, lay.z_lid - 1, lay.H + 1, lay.aux_xc, yl, seg))
    # hold-down for the driver perfboard (kept off the component side)
    if p.driver:
        add.append(box(lay.drv_x - 1.0, lay.drv_y0 + 2.0, lay.drv_z0 + p.drv_h + 0.2,
                       lay.drv_x + p.drv_t / 2 - 0.3, lay.drv_y1 - 2.0, top))
    # fastening
    if lay.snaps:
        zb = _snap_zb(lay)
        g, t = p.snap_bump, p.fit_gap
        for axis, sign, face, center, sw in _snap_specs(lay):
            add.append(_wall_local(axis, sign, face, center, -sw / 2, sw / 2, t, t + p.snap_t,
                                   lay.z_lid - p.snap_len, top))
            add.append(_wall_prism(axis, sign, face, center, sw / 2,
                                   [(t + 0.01, zb - g), (t - g, zb), (t + 0.01, zb + g)]))
    else:
        for bx, by in lay.boss_xy:
            cut.append(cyl_z(p.lid_screw_hole / 2, lay.z_lid - 1, lay.H + 1, bx, by, seg))
    return union(add) - union(cut)


# --------------------------------------------------------------------------- nose


def nose_profile(lay: Layout) -> CS:
    """Nose profile in the rotation plane: u along the beam, v across it, hinge axis at 0."""
    p = lay.p
    R, e, rt, ch = p.knuckle_r, p.led_offset, lay.tube_r, p.nose_chamfer
    # (-R, R·(√2−1)) is the 45° tangent to the knuckle circle: printable on the back face,
    # and it keeps the swept radius small so the knuckle clears the front wall at any angle.
    pts = [(-R, R * (math.sqrt(2.0) - 1.0)), (-R, -e - rt + ch), (-R + ch, -e - rt),
           (lay.u_front, -e - rt), (lay.u_front, -e + rt)]
    return CS.batch_hull([circle(R, 0, 0, p.segments), polygon(pts)])


def nose_local(lay: Layout) -> M:
    """Nose in its local frame: X is the hinge axis, Y = u, Z = v."""
    p = lay.p
    seg = p.segments
    hw = lay.knuckle_w / 2
    n = prism_x(nose_profile(lay), -hw, hw)
    n -= prism_x(teardrop(p.m3_hole / 2, 0, 0, seg, tip=(1.0, 0.0)), -hw - 1, hw + 1)
    for x in lay.led_xs:
        # Ø channel for the flange from the back face (the LED goes in from behind), Ø grip in front
        n -= cyl_y(p.led_channel_d / 2, -p.knuckle_r - 1, p.led_step_u, x, -p.led_offset, seg)
        n -= cyl_y(p.led_bore / 2, p.led_step_u - 0.01, lay.u_front + 1, x, -p.led_offset, seg)
    return n


def led_local(lay: Layout) -> M:
    p = lay.p
    seg = p.segments
    e = -p.led_offset
    r = p.led_d / 2
    u0 = p.led_step_u - p.led_flange_h
    dome_c = u0 + p.led_len - r
    out = []
    for x in lay.led_xs:
        out += [
            cyl_y(p.led_flange_d / 2, u0, p.led_step_u, x, e, seg),
            cyl_y(r, p.led_step_u - 0.01, dome_c, x, e, seg),
            M.sphere(r, seg).translate([x, dome_c, e]),
        ]
        for s in (-1, 1):  # leads, up to the back face of the knuckle
            out.append(box(x + s * 1.27 - 0.25, -p.knuckle_r + 0.2, e - 0.25, x + s * 1.27 + 0.25, u0, e + 0.25))
    return union(out)


def nose_transform(lay: Layout, angle: float):
    def f(m: M) -> M:
        return m.rotate([angle, 0, 0]).translate([lay.nose_x, lay.y_A, lay.z_A])
    return f


def beam_cone(lay: Layout, angle: float, length: float = 150.0) -> M:
    """Beam cone (half-angle led_beam_half) from the LED die, in assembly coordinates."""
    p = lay.p
    u_die = p.led_step_u - p.led_flange_h + p.led_die_h
    r1 = length * math.tan(math.radians(p.led_beam_half))
    cones = [M.cylinder(length, 0.01, r1, p.segments).rotate([-90, 0, 0]).translate([x, u_die, -p.led_offset])
             for x in lay.led_xs]
    return nose_transform(lay, angle)(union(cones))


# --------------------------------------------------------------------------- phantoms


@dataclass
class Phantom:
    name: str
    group: str  # phantoms of one group (one component) may touch each other
    solid: M
    mass: float = 0.0
    antenna_gap: float = 0.0  # metal: required distance from the antenna end of the board (0: not checked)


def phantoms_static(lay: Layout) -> list[Phantom]:
    """Components that do not move with the nose angle."""
    p = lay.p
    seg = p.segments
    b = lay.board
    pw = lay.power
    metal = p.antenna_metal_gap
    out: list[Phantom] = [
        Phantom("power", "power", box(lay.pw_x0, lay.pw_y0, p.floor, lay.pw_x1, lay.pw_y1, p.floor + pw.h),
                pw.mass, metal),
    ]

    # board and its keep-out zones
    pcb = box(lay.bx0, lay.by0, lay.zp, lay.bx1, lay.by1, lay.zp_top)
    usb = prism_y(stadium(b.usb_w, b.usb_h, lay.bxc, lay.usb_zc, seg), lay.usb_y0, lay.usb_y1)
    top = box(lay.bx0, lay.by0, lay.zp_top, lay.bx1, lay.by1, lay.zp_top + b.top_h)
    top -= box(lay.bxc - p.finger_w / 2 - 0.3, lay.by1 - b.press_len - 0.3, lay.zp_top - 1,
               lay.bxc + p.finger_w / 2 + 0.3, lay.by1 + 1, lay.H)  # strip under the lid finger
    top -= box(lay.bxc - b.usb_w / 2 - 0.3, lay.usb_y0 - 1, lay.zp_top - 1,
               lay.bxc + b.usb_w / 2 + 0.3, lay.usb_y1 + 0.3, lay.H)  # the receptacle is its own phantom
    bot = box(lay.bx0, lay.by0, lay.zp - b.bottom_h, lay.bx1, lay.by1, lay.zp)
    bot -= box(lay.bxc - b.shelf_w / 2 - 0.3, lay.by1 - b.shelf_d - 0.3, 0,
               lay.bxc + b.shelf_w / 2 + 0.3, lay.by1 + 1, lay.zp + 1)  # area resting on the shelf
    out += [
        Phantom("board.pcb", "board", pcb, b.mass),
        Phantom("board.usb", "board", usb),
        Phantom("board.top", "board", top),
        Phantom("board.bottom", "board", bot),
    ]

    # slide switch (the lever phantom covers its full travel)
    yc = lay.sw_yc
    sweep = (p.sw_lever_w + p.sw_travel) / 2
    out += [
        Phantom("switch.body", "switch", box(lay.sw_x_in, yc - p.sw_l / 2, lay.sw_z0,
                                             lay.sw_x_face, yc + p.sw_l / 2, lay.sw_z1), 0.5, metal),
        Phantom("switch.lever", "switch", box(lay.sw_x_face - 0.01, yc - sweep, lay.sw_zc - p.sw_lever_t / 2,
                                              lay.sw_x_face + p.sw_lever_len, yc + sweep,
                                              lay.sw_zc + p.sw_lever_t / 2)),
        Phantom("switch.pins", "switch", box(lay.sw_x_in - p.sw_pin_len, yc - p.sw_pin_pitch - 0.3,
                                             lay.sw_zc - 0.3, lay.sw_x_in + 0.01, yc + p.sw_pin_pitch + 0.3,
                                             lay.sw_zc + 0.3)),
        Phantom("switch.solder", "switch", box(lay.sw_plate_x0 - 0.4 - p.sw_solder_len, yc - 3.8, lay.sw_zc - 1.5,
                                               lay.sw_plate_x0 - 0.4, yc + 3.8, lay.sw_zc + 1.5)),
    ]

    # RST button
    if p.reset_button:
        s = p.btn_size / 2
        legs = []
        for sx in (-1, 1):
            for sy in (-1, 1):
                lx = lay.btn_xc + sx * p.btn_leg_px / 2
                ly = lay.btn_yc + sy * p.btn_leg_py / 2
                legs.append(box(lx - 0.4, ly - 0.4, lay.btn_z0 - p.btn_leg_len, lx + 0.4, ly + 0.4, lay.btn_z0))
        out += [
            Phantom("button.body", "button", box(lay.btn_xc - s, lay.btn_yc - s, lay.btn_z0,
                                                 lay.btn_xc + s, lay.btn_yc + s, lay.btn_z1), 0.4, metal),
            Phantom("button.plunger", "button", cyl_z(p.btn_plunger_d / 2, lay.btn_z1 - 0.01,
                                                      lay.btn_z1 + p.btn_plunger_h, lay.btn_xc, lay.btn_yc, seg)),
            Phantom("button.legs", "button", union(legs)),
        ]

    # hinge hardware
    x_head = lay.nose_x - lay.cheek_out
    x_nut = lay.nose_x + lay.cheek_out - p.nut_pocket_depth
    bolt = cyl_x(p.m3_head_d / 2, x_head - p.m3_head_h, x_head, lay.y_A, lay.z_A, seg)
    bolt += cyl_x(p.m3_d / 2, x_head - 0.01, x_head + lay.bolt_len, lay.y_A, lay.z_A, seg)
    nut = prism_x(hexagon(p.m3_nut_af, lay.y_A, lay.z_A), x_nut, x_nut + p.m3_nut_h)
    nut -= cyl_x(p.m3_d / 2 + 0.01, x_nut - 1, x_nut + p.m3_nut_h + 1, lay.y_A, lay.z_A, seg)
    out += [Phantom("hinge.bolt", "hinge", bolt, 1.2, metal),
            Phantom("hinge.nut", "hinge", nut, 0.5, metal)]

    # lid screws (core diameter, since the thread cuts into the pilot hole)
    if not lay.snaps:
        for i, (bx, by) in enumerate(lay.boss_xy):
            scr = cyl_z(p.lid_screw_head_d / 2, lay.H, lay.H + p.lid_screw_head_h, bx, by, seg)
            scr += cyl_z(1.2, lay.H - p.lid_screw_len, lay.H + 0.01, bx, by, seg)
            out.append(Phantom(f"screw{i}", f"screw{i}", scr, 0.6, metal))

    # Schottky diode in heat-shrink, in the spine channel (small metal: its own antenna gap)
    if pw.chemistry == "alkaline":
        dy = lay.diode_y
        out.append(Phantom("diode", "diode", cyl_y(p.diode_d / 2, dy - p.diode_l / 2, dy + p.diode_l / 2,
                                                   lay.diode_x, lay.diode_z, seg), 0.3, p.antenna_small_metal_gap))

    # LED wires: from the front wall passage back past the lid tooth, along the left of the board bay
    zw = lay.z_A - p.led_offset
    y0w = lay.by1 + p.tooth_gap + p.tooth_t + 0.5
    out.append(Phantom("wires.led", "wires", box(lay.wire_x - 1.5, y0w, zw - 1.5,
                                                 lay.wire_x + 1.5, lay.in_y1 + 0.01, zw + 1.5)))

    # IR receiver
    if p.ir_rx == "back":
        c, zi, y0 = lay.aux_xc, lay.ir_z0, lay.in_y0
        out += [
            Phantom("ir.body", "ir", box(c - p.ir_w / 2, y0, zi, c + p.ir_w / 2, y0 + p.ir_d, zi + p.ir_h), 0.4),
            Phantom("ir.dome", "ir", cyl_y(p.ir_dome_d / 2, y0 - p.ir_dome_h, y0 + 0.01, c, zi + p.ir_lens_z, seg)),
            Phantom("ir.leads", "ir", box(c - 2.84, y0 + p.ir_d / 2 - 0.4, zi - 2.5, c + 2.84,
                                          y0 + p.ir_d / 2 + 0.4, zi + 0.01)),
        ]
    elif p.ir_rx == "lid":
        c = lay.aux_xc
        zb = lay.z_lid - 0.3 - p.ir_d
        yb0, yb1 = lay.ir_yb0, lay.ir_yb0 + p.ir_h
        out += [
            Phantom("ir.body", "ir", box(c - p.ir_w / 2, yb0, zb, c + p.ir_w / 2, yb1, zb + p.ir_d), 0.4),
            Phantom("ir.dome", "ir", cyl_z(p.ir_dome_d / 2, zb + p.ir_d - 0.01, zb + p.ir_d + p.ir_dome_h,
                                           c, yb1 - p.ir_lens_z, seg)),
            Phantom("ir.leads", "ir", box(c - 2.84, yb1 - 0.01, zb + p.ir_d / 2 - 0.4, c + 2.84,
                                          yb1 + p.ir_lead_len, zb + p.ir_d / 2 + 0.4)),
        ]

    # perfboard driver
    if p.driver:
        x, t = lay.drv_x, p.drv_t
        y0, y1, zd0, zd1 = lay.drv_y0, lay.drv_y1, lay.drv_z0, lay.drv_z0 + p.drv_h
        out += [
            Phantom("driver.pcb", "driver", box(x - t / 2, y0, zd0, x + t / 2, y1, zd1), 1.0),
            Phantom("driver.parts", "driver", box(x + t / 2 - 0.01, y0 + 1.5, zd0, x + t / 2 + p.drv_comp,
                                                  y1 - 1.5, zd1)),
            Phantom("driver.solder", "driver", box(x - t / 2 - p.drv_solder, y0 + 1.5, zd0, x - t / 2 + 0.01,
                                                   y1 - 1.5, zd1)),
        ]
    return out


def antenna_zone(lay: Layout) -> M:
    b = lay.board
    return box(lay.bx0, lay.by1 - b.antenna_len, lay.zp, lay.bx1, lay.by1, lay.zp_top + b.top_h)


# --------------------------------------------------------------------------- assembly


@dataclass
class Assembly:
    lay: Layout
    angle: float
    parts: dict[str, M]
    phantoms: list[Phantom] = field(default_factory=list)


class Builder:
    """Caches the fixed solids; the nose and the LED are re-posed per angle."""

    def __init__(self, p: Params):
        self.p = p
        self.lay = Layout(p)

    @cached_property
    def tray(self) -> M:
        return tray(self.lay)

    @cached_property
    def tray_body(self) -> M:
        return tray(self.lay, with_cheeks=False)

    @cached_property
    def lid(self) -> M:
        return lid(self.lay)

    @cached_property
    def nose_local(self) -> M:
        return nose_local(self.lay)

    @cached_property
    def led_local(self) -> M:
        return led_local(self.lay)

    @cached_property
    def static_phantoms(self) -> list[Phantom]:
        return phantoms_static(self.lay)

    def nose(self, angle: float) -> M:
        return nose_transform(self.lay, angle)(self.nose_local)

    def led(self, angle: float) -> Phantom:
        return Phantom("led", "led", nose_transform(self.lay, angle)(self.led_local),
                       0.3 * self.p.led_count, self.p.antenna_metal_gap)

    def assembly(self, angle: float | None = None) -> Assembly:
        a = self.p.nose_angle if angle is None else angle
        parts = {"tray": self.tray, "lid": self.lid, "nose": self.nose(a)}
        return Assembly(self.lay, a, parts, [*self.static_phantoms, self.led(a)])

    def print_parts(self) -> dict[str, M]:
        """Parts in print orientation: bottom on z = 0, centred on the XY origin."""
        posed = {
            "tray": self.tray,
            "lid": self.lid.rotate([180, 0, 0]),  # top face down
            "nose": self.nose_local.transform([[1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0]]),  # back face down
        }
        out = {}
        for name, m in posed.items():
            lo, hi = bbox(m)
            c = (lo + hi) / 2
            out[name] = m.translate([-c[0], -c[1], -lo[2]])
        return out


PRINT_NOTES = {
    "tray": "bottom on the bed, no supports",
    "lid": "top (outer) face on the bed, no supports",
    "nose": "flat back face on the bed (LED bore pointing up), no supports",
}
