# Customizing the enclosure

The enclosure is a parametric Python model (no CAD program needed). Every size lives in
[`enclosure/params.py`](../../enclosure/params.py); the geometry is built with
[manifold3d](https://github.com/elalish/manifold) and checked automatically before you print.

## Setup

Python 3.13 or newer. From the repository root:

```sh
cd enclosure
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Building

| Command | What it does |
|---|---|
| `.venv/bin/python build.py` | writes STL files for `default`, `xiao`, `liion` into `out/<variant>/` |
| `.venv/bin/python build.py --all` | every variant |
| `.venv/bin/python build.py --variant aaa` | one variant (the option can be repeated) |
| `.venv/bin/python check.py` | checks every variant, prints a report, exits with 1 on failure |
| `.venv/bin/python render.py [--all]` | PNG previews into `out/<variant>/render_*.png` |
| `.venv/bin/python -m pytest tests` | the test suite (all variants) |

For each variant, `build.py` writes `tray.stl`, `lid.stl` and `nose.stl` in print orientation, plus
`assembly.stl` for viewing. It reloads every STL to make sure it is still a closed solid.

## Variants, boards and batteries

A variant is a name plus a set of parameter overrides, defined in `VARIANTS` in `params.py`:

```python
VARIANTS = {
    "default": {},
    "xiao": {"board": "xiao"},
    "liion": {"power": "lipo103450"},
    ...
}
```

Board presets (`BOARDS`):

| Key | Board | PCB, mm | USB-C | Notes |
|---|---|---|---|---|
| `supermini` | SuperMini nRF52840, nice!nano v2 and other Pro Micro–size nRF52840 boards | 18.0 × 33.3 × 1.6 | mid-mount, sticks out 0.8 mm | RST is an edge pad, so the case has an external reset button |
| `xiao` | Seeed XIAO nRF52840 / nRF52840 Sense | 17.8 × 21.0 × 1.2 | on top of the PCB, sticks out 1.2 mm | BAT± pads are on the bottom; the board has its own reset button next to USB-C |

Power presets (`POWERS`):

| Key | Source | Block, mm (X × Y × H) | Chemistry |
|---|---|---|---|
| `aa3` | 3×AA side-by-side holder with leads | 58 × 48 × 16 | alkaline/NiMH, needs the Schottky diode |
| `aaa3` | 3×AAA side-by-side holder | 53 × 38 × 13.5 | alkaline/NiMH, needs the diode |
| `lipo103450` | flat LiPo 103450 with protection board | 51 × 34.5 × 10.5 (+1 mm headroom) | Li-ion, charged by the board over USB-C |
| `li18650` | 1×18650 holder with leads | 76 × 21 × 19 | Li-ion, charged by the board over USB-C |

The boards charge a single Li-ion cell through their battery pads (SuperMini / nice!nano at about 100 mA,
XIAO at 50 or 100 mA). Use a cell with a protection circuit. Alkaline or NiMH packs must not see that charge
current, which is why AA/AAA builds have the series diode.

To make your own combination, add an entry to `VARIANTS`:

```python
VARIANTS["xiao_aaa"] = {"board": "xiao", "power": "aaa3", "ir_rx": "back"}
VARIANT_NOTES["xiao_aaa"] = "XIAO + 3×AAA + IR receiver"
```

then run `build.py --variant xiao_aaa` and `check.py --variant xiao_aaa`. New variants are picked up by the
tests automatically.

## Measure your parts

These parts vary between makers. Measure yours with calipers and override the preset:

| What | Parameter | Default | How to measure |
|---|---|---|---|
| Battery holder length / width / height | `power_overrides={"l", "w", "h"}` | 58 / 48 / 16 | outer body, without the leads; length is along the cells |
| PCB length | `board_overrides={"pcb_l": ...}` | 33.3 | from the USB-C edge to the far edge, **to ±0.2 mm**: the board is held between the back wall and a tooth on the lid, and the receptacle only reaches 0.6 mm into the wall window |
| PCB width / thickness | `pcb_w`, `pcb_t` | 18.0 / 1.6 | |
| USB-C overhang | `usb_overhang` | 0.8 | how far the receptacle sticks out past the PCB edge |
| USB-C height position | `usb_z0_rel` | −1.55 | receptacle bottom relative to the PCB top: 0 for a top-mount receptacle, about −1.5 for a mid-mount one |
| Component height | `top_h`, `bottom_h` | 3.0 / 1.5 | tallest part on top, solder joints and wires underneath |
| Switch | `sw_l`, `sw_w`, `sw_h`, `sw_lever_len` | 8.6, 3.6, 3.5, 4.0 | the SS12D00 "G3/G4/G5" suffix is the lever length in mm |
| LED | `led_d`, `led_flange_d`, `led_len` | 5.0, 5.9, 8.6 | flange diameter decides the channel the LED slides through |

Example — a 57 mm holder that is 17.5 mm tall and a board that is 33.0 mm long:

```python
# params.py
VARIANTS["mine"] = {
    "power_overrides": {"l": 57.0, "h": 17.5},
    "board_overrides": {"pcb_l": 33.0},
}
```

The case grows or shrinks around the parts; `check.py` tells you if something no longer fits (for example
the 25 mm height limit with a tall 18650 holder).

## Adding a board

Add a `BoardSpec` to `BOARDS`. The model assumes a rectangular board with USB-C on one short edge and the
antenna at the other; the board lies flat with USB-C towards the back wall.

```python
BOARDS["myboard"] = BoardSpec(
    label="My nRF52840 board",
    pcb_w=20.0, pcb_l=30.0, pcb_t=1.0,   # mm
    top_h=2.5, bottom_h=1.5,             # keep-out above and below the PCB
    usb_overhang=0.5, usb_z0_rel=0.0,    # top-mount receptacle
    shelf_w=9.0,                         # support under the antenna edge, keep it between the pin rows
    press_len=1.2,                       # strip at the antenna edge the lid finger presses on — keep it free of parts
    antenna_len=6.0,
)
```

How the board is held: the USB-C receptacle sits in a window in the back wall (0.25 mm clearance), the antenna
end rests on a narrow shelf between two guide posts, and two fingers on the lid press on the receptacle and on
the last `press_len` mm of the PCB. A tooth on the lid (`tooth_gap` behind the board) stops the board from
sliding away from the window; `check.py` makes sure the receptacle stays at least `usb_min_engage` deep in the
window even when the real board is `pcb_l_tol` shorter than `pcb_l`. If
your board has parts within `press_len` of the antenna edge, make `press_len` smaller or narrow the finger
with `finger_w`.

## Adding a power source

Add a `PowerSpec` to `POWERS`: the bounding block of the holder or battery, the number and mass of cells (used
for the balance check) and the chemistry:

```python
POWERS["aa2"] = PowerSpec("2×AA holder", 58.0, 32.0, 16.0, cells=2, cell_mass=23.0,
                          holder_mass=6.0, chemistry="alkaline")
```

The power block sits in the back-left corner with `power_gap` around it and `power_lead_gap` (1.5 mm) at the
right end, where holders usually bring out their leads. When it is narrower than the case, a low fence keeps it
in place. The divider to the right is full height only at its ends, so leads can cross it anywhere.

## Options

| Parameter | Values | Effect |
|---|---|---|
| `lid_fastening` | `"screws"` (default), `"snaps"` | two self-tapping screws into bosses between the bays, or three snap hooks |
| `ir_rx` | `None` (default), `"back"`, `"lid"` | IR receiver for learning codes from the original remote: a Ø6 mm window in the back wall (receiver stands up, lens facing the user) or in the lid (receiver lies on its back, lens up) |
| `driver` | `False` (default), `True` | slots for a 15 × 10 mm perfboard that stands upright, components ≤ 6 mm on one side |
| `led_count` | 1 (default), 2 | wider nose with two LEDs 7 mm apart (`led_pitch`) for more range; drive them through the transistor driver |
| `reset_button` | `True` (default), `False` | external 6 × 6 mm button under a paperclip hole in the lid; the XIAO also has its own button |

The IR receiver and the driver share an extra 13 mm bay (`aux_w`) between the battery and the board, so the
case gets longer when either is enabled.

## Nose height and angle

- `nose_axis_z` — height of the hinge axis. By default it is 13 mm, or lower for flat cases so that the
  cheeks stay below the lid top. The LED axis is `led_offset` (6 mm) below the hinge axis at 0°.
- `nose_back_gap` — gap between the knuckle and the front wall; 1.5 mm keeps the knuckle clear of the wall over
  the full 0–90° range.
- `nose_angle` — only used for the assembly preview and `assembly.stl`.
- `nose_x`, `wire_x_off` — the nose sits in line with the LED wire passage, 3 mm from the left edge of the board
  bay, so the wires run down the left side of the bay instead of across the antenna end.
- `nose_check_angles` — angles at which the checks look for collisions (every 2.5°).
- `led_beam_half` — half-angle of the beam cone that must stay clear of the case (10° by default).
- `cheek_t`, `hinge_gap` — cheek thickness and the knuckle-to-cheek gap that the bolt closes up for friction.

The check report has a table with the angle you need for a given sensor height and distance.

## Fit clearances

| Parameter | Default | Where |
|---|---|---|
| `fit_gap` | 0.2 | lid rim around the wall tongue |
| `power_gap` | 0.5 | battery holder to the walls (the headroom above it is the preset's `top_gap`) |
| `board_side_gap`, `board_end_gap` | 0.3, 0.2 | PCB to guides and back wall |
| `usb_window_gap` | 0.25 | around the USB-C receptacle |
| `usb_wall_thin` | auto | wall left behind the outside plug recess; by default it is thinned (down to `usb_wall_min`, 0.8 mm) until the receptacle face is flush with the recess |
| `press_gap` | 0.1 | lid fingers above the PCB, receptacle, switch |
| `hinge_gap` | 0.1 | nose to each cheek |
| `sw_gap`, `sw_slot_gap` | 0.15, 0.3 | switch in its pocket, lever in its slot |
| `led_bore` | 5.1 | grip for the 5 mm LED body |
| `m3_hole`, `pilot_d` | 3.2, 2.5 | hinge bolt hole, lid screw pilot hole |

If your printer prints holes small or parts fat, raise the gaps by 0.1 mm rather than scaling the model.

## Printer

`bed_x`, `bed_y` (180 × 180 by default) and `bed_margin` are used by the fit check. `max_overhang_deg` (45°),
`max_bridge` (10 mm, supported at both ends) and `max_cantilever` (2 mm, supported on one side) set what the
overhang check accepts.

## What the checks verify

`check.py` runs for every variant (and `pytest` repeats it):

- each printed part is a valid manifold, watertight after vertices are merged (as a slicer reads the STL), a
  single body with positive volume;
- each part fits the bed in its print orientation; every down-facing area steeper than 45° is either a bridge
  no longer than `max_bridge` or a one-sided ledge no longer than `max_cantilever`;
- the case is at most 25 mm tall without the nose;
- parts and components do not overlap in the assembly, with the nose every 2.5° from 0 to 90°;
- 25–40 named clearances (battery to walls and lid, USB-C to window, lever to slot, nose to wall and lid, the
  LED wire path, and so on) are at least the required value, and components keep at least 0.3 mm from each
  other; the parts that hold something (lid fingers, hinge cheeks) are also no farther than the press gap plus
  `hold_max_extra`;
- the USB-C receptacle stays in its wall window with the board pushed against the lid tooth;
- the switch lever sticks out of the wall;
- the ±10° beam cone misses the case, the lid, the nose and the hardware at every angle from 0° to 90°;
- the nose never goes below the bottom of the case;
- the USB-C receptacle face is no more than 0.3 mm behind the plug recess, so the cable seats fully;
- no metal part comes closer than 4 mm to the antenna end of the board (2.5 mm for the small diode);
- with the batteries' mass included, the centre of mass is at least 8 mm inside the outline of the feet.

## Layout and coordinates

X runs along the front edge (left to right when you look at the TV from behind the box), Y from the back wall
(facing the user, y = 0) to the front wall (facing the TV), Z up from the bottom of the case. Left to right:
power bay → spine (wiring channel with the diode, lid screw bosses) → optional aux bay (IR receiver, driver) →
board bay. The board's USB-C is at the back wall, the slide switch is in the right wall near the front, the
reset button is at the front of the board bay, the LED wires come in at its front-left corner, and the nose is
in front of that corner.

## Known limitations

- The components are bounding blocks taken from datasheets and shop listings, not exact models. Measure what
  you have — especially the battery holder and the board length.
- The lid fingers press on a 1.2 mm strip at the antenna end of the board. Check that your board has no parts
  there.
- The LED wires and the Schottky diode are only approximated as keep-out blocks; the wires still pass about 2 mm
  from the corner of the antenna end, and the lid finger sits right above it.
- The friction hinge relies on the bolt clamping the cheeks; on very smooth PLA a paper or rubber washer
  between the nose and a cheek adds grip.
- The battery holder has 0.5 mm of play under the lid; a thin foam pad stops it rattling.
- Only bare IR receivers fit, not receiver modules soldered to a small PCB.
- 18650 holders come 17.7–21.5 mm tall; above about 20 mm the case exceeds 25 mm and `check.py` reports it.
