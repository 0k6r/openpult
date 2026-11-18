"""openpult enclosure: every dimension in one place (mm, grams, degrees).

Assembly coordinates:
  X — along the front edge, left to right as seen from behind the box looking at the TV;
  Y — from the back wall (y = 0, faces the user) to the front wall (faces the TV);
  Z — up; z = 0 is the bottom of the case (without feet).

Layout, left to right: power bay → "spine" (wiring channel, lid screw bosses) →
[aux bay: IR receiver / LED driver] → board bay. The board lies with USB-C to the
back wall and the antenna to the front. The LED nose is hinged in front of the
front wall, opposite the board bay.

Module presets live in BOARDS and POWERS, ready-made combinations in VARIANTS.
Custom sizes: `Params(board_overrides={"pcb_l": 33.0}, power_overrides={...})`
or edit the preset values below. See docs/enclosure/customizing.md.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, replace


@dataclass(frozen=True)
class BoardSpec:
    """Controller board. USB-C on one short edge, antenna at the opposite one."""

    label: str
    pcb_w: float  # across the board (X)
    pcb_l: float  # from the USB edge to the antenna edge (Y)
    pcb_t: float
    top_h: float  # component height above the PCB (USB excluded)
    bottom_h: float  # solder joints and wires below the PCB
    usb_w: float = 8.94  # USB-C receptacle shell
    usb_h: float = 3.26
    usb_l: float = 7.35
    usb_overhang: float = 1.0  # receptacle sticks out past the PCB edge
    usb_z0_rel: float = 0.0  # receptacle bottom relative to the PCB top (< 0: mid-mount)
    shelf_w: float = 9.0  # support shelf under the antenna edge, between the pin rows
    shelf_d: float = 2.0
    press_len: float = 1.2  # strip at the antenna edge pressed by the lid finger
    antenna_len: float = 6.0  # antenna zone measured from the far edge
    mass: float = 3.0
    note: str = ""


BOARDS: dict[str, BoardSpec] = {
    # nice!nano v2 and SuperMini clones: 18 × 33.3 mm (shops list 18.3 × 34.1 — that
    # includes the USB-C overhang), 1.6 mm PCB, mid-mount USB-C, 3.3 mm total height.
    "supermini": BoardSpec(
        label="SuperMini nRF52840 / nice!nano v2",
        pcb_w=18.0,
        pcb_l=33.3,
        pcb_t=1.6,
        top_h=3.0,
        bottom_h=1.5,
        usb_overhang=0.8,
        usb_z0_rel=-1.55,
        note="mid-mount USB-C; RST is an edge pad, reset button is external",
    ),
    # Seeed XIAO nRF52840 (and Sense): 21 × 17.8 mm, top-mount USB-C on the narrow
    # edge, BAT+/BAT− pads on the bottom — leave room for wires under the board.
    "xiao": BoardSpec(
        label="Seeed XIAO nRF52840",
        pcb_w=17.8,
        pcb_l=21.0,
        pcb_t=1.2,
        top_h=3.0,
        bottom_h=2.0,
        usb_overhang=1.2,
        usb_z0_rel=0.0,
        shelf_w=8.0,
        mass=3.0,
        note="top-mount USB-C; BAT± pads on the bottom",
    ),
}


@dataclass(frozen=True)
class PowerSpec:
    """Power source (holder with cells, or a battery) as a bounding block."""

    label: str
    l: float  # along X
    w: float  # along Y
    h: float
    cells: int
    cell_mass: float
    holder_mass: float
    chemistry: str  # "alkaline" — needs a series Schottky diode; "liion" — charged by the board
    top_gap: float = 0.5  # gap to the lid
    note: str = ""

    @property
    def mass(self) -> float:
        return self.cells * self.cell_mass + self.holder_mass


POWERS: dict[str, PowerSpec] = {
    # 3×AA side-by-side holders with leads: 57–58 × 47–48 × 15–17 mm depending on the maker.
    "aa3": PowerSpec("3×AA holder", 58.0, 48.0, 16.0, 3, 23.0, 8.0, "alkaline"),
    # 3×AAA side-by-side: 51.8–53 × 37–38 × 12.7–14 mm.
    "aaa3": PowerSpec("3×AAA holder", 53.0, 38.0, 13.5, 3, 11.5, 5.0, "alkaline"),
    # Flat LiPo 103450 with protection board: ~10 × 34 × 50 mm (+1 mm for the PCM),
    # 1 mm headroom for swelling.
    "lipo103450": PowerSpec("LiPo 103450 (flat)", 51.0, 34.5, 10.5, 1, 40.0, 0.0, "liion", top_gap=1.0),
    # 1×18650 holder with leads: 74.5–77.9 × 20.9–21.5 × 17.7–21.5 mm.
    "li18650": PowerSpec("18650 holder", 76.0, 21.0, 19.0, 1, 47.0, 7.0, "liion"),
}


@dataclass(frozen=True)
class Params:
    # --- modules and options ----------------------------------------------------------
    board: str = "supermini"
    power: str = "aa3"
    board_overrides: dict = field(default_factory=dict)
    power_overrides: dict = field(default_factory=dict)
    lid_fastening: str = "screws"  # "screws" (2 self-tapping M3) | "snaps" (3 snap hooks)
    ir_rx: str | None = None  # None | "back" (window in the back wall) | "lid" (in the lid)
    driver: bool = False  # slot for a perfboard transistor driver
    led_count: int = 1  # 1 or 2 LEDs in the nose
    reset_button: bool = True  # external 6×6 tact switch for RST, pressed with a paperclip

    # --- printer ------------------------------------------------------------------------
    bed_x: float = 180.0
    bed_y: float = 180.0
    bed_margin: float = 5.0
    nozzle: float = 0.4
    layer: float = 0.2
    segments: int = 64
    max_overhang_deg: float = 45.0
    max_bridge: float = 10.0  # span of a bridge supported at both ends
    max_cantilever: float = 2.0  # reach of an overhang supported on one side only
    max_body_height: float = 25.0

    # --- shell --------------------------------------------------------------------------
    wall: float = 2.4
    floor: float = 2.4
    lid_t: float = 2.0
    corner_r: float = 3.0
    joint_h: float = 2.0  # height of the wall/lid rebate
    tongue_t: float = 1.2  # inner tongue of the wall the lid sits on
    fit_gap: float = 0.2  # lid fit clearance
    interior_min_h: float = 14.0

    # --- power bay ------------------------------------------------------------------------
    power_gap: float = 0.5
    power_lead_gap: float = 1.5  # at the divider end, where the holder's leads come out
    fence_t: float = 1.6
    fence_h: float = 6.0
    divider_t: float = 1.6
    divider_h: float = 8.0
    divider_post_w: float = 3.0  # full-height posts at the ends of the divider; low in between for wires
    divider_low_h: float = 2.0

    # --- spine and lid fastening -------------------------------------------------------------
    spine_w: float = 6.5
    boss_d: float = 6.5
    pilot_d: float = 2.5  # for an M3 / 3 mm self-tapping screw in PLA/PETG
    pilot_depth: float = 12.0
    lid_screw_hole: float = 3.4
    lid_screw_len: float = 10.0
    lid_screw_head_d: float = 5.6
    lid_screw_head_h: float = 2.4
    snap_w: float = 8.0
    snap_t: float = 1.2
    snap_len: float = 8.0
    snap_bump: float = 0.6  # hook bump height from the snap tongue
    snap_groove: float = 0.7  # groove depth in the wall

    # --- board bay ----------------------------------------------------------------------------
    board_comp_min_w: float = 22.0
    board_z: float = 5.0  # PCB bottom above the floor
    board_end_gap: float = 0.2  # PCB edge to the back wall
    board_side_gap: float = 0.3
    guide_t: float = 1.5
    guide_len: float = 3.0
    guide_above: float = 0.6
    usb_window_gap: float = 0.25
    usb_wall_thin: float | None = None  # wall left at the connector; None: thin it until the
    usb_wall_min: float = 0.8  #   receptacle face is flush with the recess floor, but not below this
    usb_face_max_recess: float = 0.3  # receptacle face may sit this far behind the recess floor
    usb_plug_w: float = 12.5  # recess for the plug overmold
    usb_plug_h: float = 7.0
    press_gap: float = 0.1  # lid fingers above the PCB / receptacle
    finger_w: float = 8.0
    usb_finger_len: float = 4.0
    tooth_gap: float = 0.2
    pcb_l_tol: float = 0.2  # how much shorter than pcb_l the real board may be
    usb_min_engage: float = 0.2  # receptacle must stay this deep in the wall window
    hold_max_extra: float = 0.15  # hold-down fingers: gap at most press gap + this
    tooth_t: float = 1.5
    tooth_below: float = 1.0
    front_region_min: float = 15.5  # from the antenna edge to the front wall

    # --- SS12D00G3 slide switch -----------------------------------------------------------------
    sw_l: float = 8.6
    sw_w: float = 3.6
    sw_h: float = 3.5
    sw_lever_len: float = 4.0
    sw_lever_w: float = 2.0  # along the travel
    sw_lever_t: float = 1.5
    sw_travel: float = 1.5
    sw_pin_len: float = 3.5
    sw_pin_pitch: float = 2.54
    sw_gap: float = 0.15
    sw_wall_left: float = 1.2  # wall under the lever after the inside pocket
    sw_top_gap: float = 1.8  # switch body top below the lid
    sw_plate_t: float = 1.5
    sw_post_t: float = 1.5
    sw_slot_gap: float = 0.3
    sw_solder_len: float = 4.0

    # --- 6×6×5 RST button -----------------------------------------------------------------------
    btn_size: float = 6.0
    btn_body_h: float = 3.5
    btn_plunger_d: float = 3.5
    btn_plunger_h: float = 1.5
    btn_leg_px: float = 6.5
    btn_leg_py: float = 4.5
    btn_leg_len: float = 3.5
    btn_hole_d: float = 2.0
    btn_boss_od: float = 5.6
    btn_boss_id: float = 4.0
    btn_boss_len: float = 3.0
    btn_boss_gap: float = 0.3
    btn_rib_w: float = 5.0
    btn_rail_t: float = 1.2
    btn_rail_h: float = 2.5
    btn_gap: float = 0.15
    btn_x_off: float = 10.0  # button centre from the left edge of the board bay
    btn_front_off: float = 5.5  # button centre from the front wall

    # --- nose -----------------------------------------------------------------------------------
    nose_x: float | None = None  # None: in line with the LED wire passage (wire_x_off)
    wire_x_off: float = 3.0  # LED wire passage from the left edge of the board bay
    nose_axis_z: float | None = None  # None: auto (≤ 13 mm, cheeks below the lid top)
    nose_back_gap: float = 1.5  # knuckle to the front wall
    knuckle_r: float = 4.5
    hinge_gap: float = 0.1  # knuckle to cheek, per side (closed up by the bolt)
    cheek_t: float = 4.0
    cheek_r: float = 6.5
    led_offset: float = 6.0  # LED axis below the hinge axis at 0°
    led_pitch: float = 7.0  # for two LEDs
    led_d: float = 5.0
    led_bore: float = 5.1
    led_flange_d: float = 5.9
    led_flange_h: float = 1.0
    led_len: float = 8.6  # flange bottom to dome tip
    led_channel_d: float = 6.3
    led_step_u: float = 2.0  # flange seat, along the beam from the hinge axis
    led_grip: float = 4.5  # length of the led_bore grip
    tube_wall: float = 1.6
    nose_chamfer: float = 2.75
    led_beam_half: float = 10.0
    led_die_h: float = 4.0  # die above the flange bottom (apex of the beam cone)
    led_wire_hole_d: float = 5.0
    nose_angle: float = 30.0  # angle used for the assembly and renders
    nose_check_angles: tuple = tuple(2.5 * i for i in range(37))  # 0, 2.5, …, 90°
    tick_depth: float = 0.4
    tick_w: float = 0.6

    # --- M3 hinge hardware ---------------------------------------------------------------------
    m3_hole: float = 3.2
    m3_d: float = 3.0
    m3_head_d: float = 5.5
    m3_head_h: float = 3.0
    m3_nut_af: float = 5.5
    m3_nut_h: float = 4.0  # nyloc
    nut_pocket_depth: float = 3.0
    nut_pocket_gap: float = 0.3
    hinge_bolt_len: float | None = None  # None: shortest standard length that fits

    # --- IR receiver (envelope of VS1838B / TSOP38238) -------------------------------------------
    ir_w: float = 6.4
    ir_h: float = 7.4
    ir_d: float = 3.8  # without the lens
    ir_dome_d: float = 5.0
    ir_dome_h: float = 1.3
    ir_lens_z: float = 4.6  # lens centre from the body bottom (lead side)
    ir_hole_d: float = 6.0
    ir_gap: float = 0.2
    ir_post_t: float = 1.2
    ir_wedge_t: float = 2.0  # lid wedge behind the receiver ("back" mounting)
    ir_lead_len: float = 6.0

    # --- perfboard driver ----------------------------------------------------------------------------
    drv_l: float = 15.0
    drv_h: float = 10.0
    drv_t: float = 1.6
    drv_comp: float = 6.0
    drv_solder: float = 1.5
    drv_slot_gap: float = 0.3
    aux_w: float = 13.0

    # --- misc ---------------------------------------------------------------------------------------
    diode_d: float = 4.0  # Schottky diode in heat-shrink
    diode_l: float = 12.0
    foot_d: float = 8.0
    foot_depth: float = 1.0
    foot_inset: float = 6.5
    foot_protrusion: float = 2.0  # how far a stick-on foot sticks out of its recess
    com_margin: float = 8.0
    antenna_metal_gap: float = 4.0
    antenna_small_metal_gap: float = 2.5  # for the small axial diode

    # --- material and estimates ------------------------------------------------------------------
    density: float = 1.27  # PETG; PLA ≈ 1.24
    fill_factor: float = 0.8
    print_flow_mm3s: float = 6.0  # average volumetric flow including travel
    hardware_mass: float = 4.0  # wires, solder, heat-shrink

    def with_(self, **kw) -> "Params":
        return replace(self, **kw)


VARIANTS: dict[str, dict] = {
    "default": {},
    "xiao": {"board": "xiao"},
    "liion": {"power": "lipo103450"},
    "aaa": {"power": "aaa3"},
    "li18650": {"power": "li18650"},
    "full": {"ir_rx": "back", "driver": True, "led_count": 2, "lid_fastening": "snaps"},
    "xiao_ir_lid": {"board": "xiao", "power": "li18650", "ir_rx": "lid", "driver": True},
}

VARIANT_NOTES: dict[str, str] = {
    "default": "SuperMini/nice!nano + 3×AA, 1 LED, screws",
    "xiao": "XIAO nRF52840 + 3×AA",
    "liion": "SuperMini/nice!nano + LiPo 103450 (charged over USB-C)",
    "aaa": "SuperMini/nice!nano + 3×AAA",
    "li18650": "SuperMini/nice!nano + 18650 holder",
    "full": "SuperMini + 3×AA + IR receiver in the back wall + driver + 2 LEDs, snap lid",
    "xiao_ir_lid": "XIAO + 18650 + IR receiver in the lid + driver",
}

# Variants that build.py writes by default (all are checked and tested).
BUILD_DEFAULT = ("default", "xiao", "liion")


def variant(name: str, **extra) -> Params:
    return Params(**{**VARIANTS[name], **extra})


class Layout:
    """Derived sizes and coordinates, computed once from Params."""

    def __init__(self, p: Params):
        if p.board not in BOARDS:
            raise ValueError(f"unknown board {p.board!r}, known: {sorted(BOARDS)}")
        if p.power not in POWERS:
            raise ValueError(f"unknown power {p.power!r}, known: {sorted(POWERS)}")
        if p.lid_fastening not in ("screws", "snaps"):
            raise ValueError("lid_fastening must be 'screws' or 'snaps'")
        if p.ir_rx not in (None, "back", "lid"):
            raise ValueError("ir_rx must be None, 'back' or 'lid'")
        if p.led_count not in (1, 2):
            raise ValueError("led_count must be 1 or 2")

        self.p = p
        b = self.board = replace(BOARDS[p.board], **p.board_overrides)
        pw = self.power = replace(POWERS[p.power], **p.power_overrides)
        w = p.wall
        self.snaps = p.lid_fastening == "snaps"

        # --- heights
        self.z_floor = p.floor
        self.inner_h = max(pw.h + pw.top_gap, p.interior_min_h)
        self.z_lid = p.floor + self.inner_h  # lid underside = top of the tongue
        self.H = self.z_lid + p.lid_t
        self.z_step = self.z_lid - p.joint_h  # top of the outer part of the wall

        # --- X
        gap_left = p.power_gap
        if self.snaps:
            gap_left = max(gap_left, p.fit_gap + p.snap_t + 0.5)
        self.pw_x0 = w + gap_left
        self.pw_x1 = self.pw_x0 + pw.l
        self.spine_x0 = self.pw_x1 + p.power_lead_gap
        self.spine_x1 = self.spine_x0 + p.spine_w
        self.has_aux = p.ir_rx is not None or p.driver
        self.aux_x0 = self.spine_x1
        self.aux_x1 = self.aux_x0 + (p.aux_w if self.has_aux else 0.0)
        self.bc_x0 = self.aux_x1
        self.bc_w = max(p.board_comp_min_w, b.pcb_w + 2 * (p.board_side_gap + p.guide_t) + 0.4)
        self.bc_x1 = self.bc_x0 + self.bc_w
        self.L = self.bc_x1 + w

        # --- Y
        self.in_y0 = w
        need_board = p.board_end_gap + b.pcb_l + p.front_region_min
        need_power = pw.w + 2 * p.power_gap
        self.in_y1 = w + max(need_board, need_power)
        self.W = self.in_y1 + w
        self.pw_y0 = w + p.power_gap
        self.pw_y1 = self.pw_y0 + pw.w
        self.has_fence = self.in_y1 - self.pw_y1 > p.power_gap + p.fence_t + 0.5
        self.fence_h = min(p.fence_h, pw.h * 0.6)

        # --- board
        self.bx0 = self.bc_x0 + (self.bc_w - b.pcb_w) / 2
        self.bx1 = self.bx0 + b.pcb_w
        self.bxc = (self.bx0 + self.bx1) / 2
        self.by0 = self.in_y0 + p.board_end_gap
        self.by1 = self.by0 + b.pcb_l
        self.zp = self.z_floor + p.board_z
        self.zp_top = self.zp + b.pcb_t
        self.usb_z0 = self.zp_top + b.usb_z0_rel
        self.usb_z1 = self.usb_z0 + b.usb_h
        self.usb_y0 = self.by0 - b.usb_overhang
        self.usb_y1 = self.usb_y0 + b.usb_l
        self.usb_zc = (self.usb_z0 + self.usb_z1) / 2
        # floor of the outside recess for the plug overmold (y from the outer face)
        if p.usb_wall_thin is not None:
            self.usb_recess_y = w - p.usb_wall_thin
        else:
            self.usb_recess_y = min(max(self.usb_y0, 0.0), w - p.usb_wall_min)

        # --- slide switch (right wall, next to the front wall)
        self.sw_x_face = self.bc_x1 + (w - p.sw_wall_left)  # lever-side face of the body
        self.sw_x_in = self.sw_x_face - p.sw_h
        self.sw_cav_x0 = self.sw_x_in - p.sw_gap
        self.sw_plate_x0 = self.sw_cav_x0 - p.sw_plate_t
        self.sw_half_y = p.sw_l / 2 + p.sw_gap + p.sw_post_t
        self.sw_yc = self.in_y1 - self.sw_half_y
        self.sw_z1 = self.z_lid - p.sw_top_gap
        self.sw_z0 = self.sw_z1 - p.sw_w
        self.sw_zc = (self.sw_z0 + self.sw_z1) / 2

        # --- RST button (on a post, pressed from the top through the lid)
        self.btn_xc = self.bc_x0 + p.btn_x_off
        self.btn_yc = self.in_y1 - p.btn_front_off
        self.btn_z1 = self.z_lid - p.btn_boss_len - p.btn_boss_gap
        self.btn_z0 = self.btn_z1 - p.btn_body_h

        # --- nose
        self.wire_x = self.bc_x0 + p.wire_x_off
        self.nose_x = p.nose_x if p.nose_x is not None else self.wire_x
        self.knuckle_w = max(10.0, (p.led_count - 1) * p.led_pitch + p.led_channel_d + 2 * p.tube_wall)
        self.y_A = self.W + p.nose_back_gap + p.knuckle_r
        self.z_A = p.nose_axis_z if p.nose_axis_z is not None else min(13.0, self.H - p.cheek_r - 0.5)
        self.cheek_in = self.knuckle_w / 2 + p.hinge_gap  # nose centre to the inner cheek face
        self.cheek_out = self.cheek_in + p.cheek_t
        self.u_front = p.led_step_u + p.led_grip
        self.tube_r = p.led_channel_d / 2 + p.tube_wall
        self.led_xs = tuple((i - (p.led_count - 1) / 2) * p.led_pitch for i in range(p.led_count))
        self.wire_hole_d = p.led_wire_hole_d + (1.0 if p.led_count > 1 else 0.0)
        need = 2 * self.cheek_out - p.nut_pocket_depth + p.m3_nut_h + 0.5
        if p.hinge_bolt_len is not None:
            self.bolt_len = p.hinge_bolt_len
        else:
            self.bolt_len = next(n for n in (12, 16, 20, 25, 30, 35, 40, 45, 50) if n >= need)

        # --- IR receiver and driver (aux bay)
        self.aux_xc = (self.aux_x0 + self.aux_x1) / 2
        self.ir_z0 = self.z_floor + 3.0  # body bottom, "back" mounting
        self.ir_yb0 = self.in_y0 + 1.5  # body top end, "lid" mounting (lying on its back)
        self.drv_x = self.aux_x0 + 3.0
        self.drv_y1 = self.in_y1 - 1.8
        self.drv_y0 = self.drv_y1 - p.drv_l
        self.drv_z0 = self.z_floor + 1.0

        # --- diode: the spot in the spine channel farthest from the antenna end of the board
        ant_lo = (self.bx0, self.by1 - b.antenna_len, self.zp)
        ant_hi = (self.bx1, self.by1, self.zp_top + b.top_h)
        self.diode_x = (self.spine_x0 + p.divider_t + self.spine_x1) / 2
        self.diode_z = p.floor + p.diode_d / 2 + 0.5
        r, hl = p.diode_d / 2, p.diode_l / 2
        y_lo = self.in_y0 + (p.boss_d + 1.0 if not self.snaps else 1.0) + hl
        y_hi = self.in_y1 - (p.boss_d + 1.0 if not self.snaps else 1.0) - hl

        def _score(yc):
            lo = (self.diode_x - r, yc - hl, self.diode_z - r)
            hi = (self.diode_x + r, yc + hl, self.diode_z + r)
            gaps = [max(a0 - b1, b0 - a1, 0.0) for a0, a1, b0, b1 in zip(lo, hi, ant_lo, ant_hi)]
            signed_y = max(ant_lo[1] - hi[1], lo[1] - ant_hi[1])
            return (round(math.hypot(*gaps), 3), signed_y)

        steps = max(int((y_hi - y_lo) / 0.5), 1)
        self.diode_y = max((y_lo + (y_hi - y_lo) * i / steps for i in range(steps + 1)), key=_score)

        # --- lid screw bosses
        sx = (self.spine_x0 + self.spine_x1) / 2
        r = p.boss_d / 2
        self.boss_xy = ((sx, self.in_y0 + r), (sx, self.in_y1 - r))

        # --- feet
        fi = p.foot_inset
        self.feet = ((fi, fi), (self.L - fi, fi), (fi, self.W - fi), (self.L - fi, self.W - fi))

    @staticmethod
    def beam_dir(theta_deg: float) -> tuple[float, float]:
        """Beam direction in the (Y, Z) plane at nose angle θ."""
        t = math.radians(theta_deg)
        return math.cos(t), math.sin(t)

    def led_point(self, u: float, theta_deg: float, x_local: float = 0.0):
        """Point on the LED axis (u — along the beam from the hinge axis) in assembly coordinates."""
        t = math.radians(theta_deg)
        v = -self.p.led_offset
        y = self.y_A + u * math.cos(t) - v * math.sin(t)
        z = self.z_A + u * math.sin(t) + v * math.cos(t)
        return (self.nose_x + x_local, y, z)
