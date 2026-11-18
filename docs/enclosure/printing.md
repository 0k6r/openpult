# Printing and assembling the enclosure

The openpult IR blaster lives in a small low box that stands on the table 5–15 cm in front of the TV, a bit to
the side of the sensor window so the original remote still reaches it. A hinged nose in front of the box holds
the IR LED and points it up at the TV's sensor block.

Inside: a controller board (SuperMini nRF52840 / nice!nano or Seeed XIAO nRF52840), a battery (3×AA holder by
default), a slide switch, a reset button and, optionally, an IR receiver for learning codes and a small
transistor driver. Everything is wired point to point, no headers.

This page covers the default build. To pick another board or battery, or to change sizes, see
[customizing.md](customizing.md).

## Which files to print

Ready STL files are in `enclosure/out/<variant>/`. Pick the variant that matches your modules:

| Variant | Board | Power | Case, mm (L × W × H) | Notes |
|---|---|---|---|---|
| `default` | SuperMini / nice!nano | 3×AA holder | 93.3 × 53.8 × 20.9 | recommended start |
| `xiao` | XIAO nRF52840 | 3×AA holder | 93.3 × 53.8 × 20.9 | |
| `liion` | SuperMini / nice!nano | LiPo 103450 | 86.3 × 53.8 × 18.4 | charges over USB-C |
| `aaa` | SuperMini / nice!nano | 3×AAA holder | 88.3 × 53.8 × 18.4 | |
| `li18650` | SuperMini / nice!nano | 1×18650 holder | 111.3 × 53.8 × 23.9 | charges over USB-C |
| `full` | SuperMini / nice!nano | 3×AA holder | 107.7 × 53.8 × 20.9 | IR receiver in the back wall, driver, 2 LEDs, snap lid |
| `xiao_ir_lid` | XIAO nRF52840 | 1×18650 holder | 124.3 × 41.5 × 23.9 | IR receiver in the lid, driver |

`build.py` writes `default`, `xiao` and `liion` by default; `build.py --all` writes every variant (see
[customizing.md](customizing.md#building)). The nose with the hinge cheeks adds about 15 mm to the depth.

**Measure your parts before printing.** Battery holders differ by a millimetre or two between makers, and
SuperMini clones are not all the same length. If your parts differ from the table in
[customizing.md](customizing.md#measure-your-parts), regenerate the STL files — it takes a second.

Each variant has three parts:

| File | Orientation on the bed | Approx. PETG | Approx. time |
|---|---|---|---|
| `tray.stl` | bottom down, as exported | 26 g | 1 h |
| `lid.stl` | outer (top) face down, as exported | 11 g | 25 min |
| `nose.stl` | flat back face down, LED hole up, as exported | 1 g | 5 min |

(Figures are for `default`; times are a rough estimate for a 0.4 mm nozzle at moderate speed.)
`assembly.stl` is the whole device with the components drawn as blocks, for viewing only — do not print it.

The STL files are already in print orientation. None of them needs supports: the small horizontal holes
(hinge bolt, LED wires) are teardrops, the nut pocket has a flat top, and everything else that hangs is a short
bridge — the USB-C window (~8 mm), the foot recesses (8 mm), the optional IR window (6 mm) — or a ledge under
2 mm.

## Print settings

- Material: PETG (preferred, it is less brittle for the hinge and the lid fit) or PLA.
- Nozzle 0.4 mm, layer 0.2 mm.
- Walls: 3–4 perimeters (the case walls are 2.4 mm), 5 top and 5 bottom layers, 20–30 % infill.
- Nose: 100 % infill or 5 perimeters — it is small and takes the hinge clamping force.
- Supports: off. Brim: not needed.
- Elephant-foot compensation 0.1–0.2 mm helps the lid, which prints top face down and has to fit over the
  wall tongue with a 0.2 mm gap.
- The default bed check is 180 × 180 mm; the largest part (`xiao_ir_lid` tray) is 124 × 54 mm.

## What to buy

| Part | Qty | Notes |
|---|---|---|
| Controller board | 1 | SuperMini nRF52840 / nice!nano v2, or Seeed XIAO nRF52840 |
| Battery | 1 | 3×AA side-by-side holder with leads (default), or see the table above |
| Slide switch SS12D00 | 1 | body 8.6 × 3.6 × 3.5 mm, no mounting ears; the suffix is the lever length — G4 (4 mm) sticks out 2.8 mm, G3 only 1.8 mm |
| Schottky diode 1N5817 or BAT43 | 1 | AA/AAA only, goes in the battery + wire |
| Tact switch 6 × 6 mm, 5 mm tall | 1 | RST, pressed with a paperclip through the lid |
| IR LED 5 mm, 940 nm | 1 (2 for `full`) | narrow beam (±10–20°) gives the best range |
| M3 × 20 bolt, ISO 4762 / DIN 912 | 1 | nose hinge; M3 × 30 for the two-LED nose |
| M3 nyloc nut, DIN 985 | 1 | sits in the pocket of the right cheek |
| Self-tapping screw for plastic, 3 × 10 mm, pan head | 2 | lid (not needed for the snap lid) |
| Stick-on rubber feet, Ø ≤ 8 mm, ~3 mm thick | 4 | go into the recesses under the case |
| Silicone wire 28–30 AWG, heat-shrink | | |
| IR receiver VS1838B / TSOP38238 | 1 | optional, bare 3-pin part, not a module on a PCB |
| Perfboard 15 × 10 mm, small NPN transistor or MOSFET, resistors | | optional LED driver |
| Thin foam pad | | optional, on top of the battery holder against rattling |

The `check.py` report prints the exact bolt length and screw list for each variant.

## Assembly

The picture `enclosure/out/<variant>/render_exploded.png` shows where everything goes;
`render_interior.png` shows the layout with the lid off.

1. **Test fit.** Put the lid on the tray (it drops onto the inner tongue of the wall), and slide the nose
   between the cheeks. If the lid is too tight, sand the lid rim or increase `fit_gap`
   ([customizing.md](customizing.md#fit-clearances)).
2. **Nut.** Press the M3 nyloc nut into the hexagonal pocket on the outside of the right cheek (the one
   without the angle scale). A drop of glue keeps it there.
3. **LED.** Solder ~10 cm wires to the LED leads, insulate them with heat-shrink and note which wire is the
   anode. Push the LED, dome first, into the round hole in the back face of the nose until the flange stops
   on the step inside; the dome sticks out of the front. The wires come out of the back face. Fix the LED with a
   drop of glue or hot glue at the back.
4. **Nose.** Feed the LED wires through the hole in the front wall into the left part of the board bay. Place
   the nose between the cheeks, LED tube below the bolt hole and pointing away from the box, and push the M3
   bolt in from the left (scale) side through the cheek, the nose and the other cheek into the nut. Tighten until the nose holds any angle but still turns by hand.
   The nyloc nut keeps that setting. Inside, run the LED wires back along the left side of the board bay into
   the channel between the bays, not across the antenna end of the board.
5. **Switch.** Solder wires to the switch, then drop it into the pocket in the right wall from above, lever
   first through the slot. The lid holds it down.
6. **Reset button.** Solder two wires to one pair of legs that switch (diagonal legs are always safe) and set the
   button on its post at the front of the board bay, plunger up, legs hanging down beside the post. The lid's
   guide tube holds it in place.
7. **Options.** IR receiver in the back wall: lower it into its cradle a little away from the wall, lens
   facing the wall and leads down, then push it forward until the lens sits in the round window; a wedge on the
   lid keeps it there. IR receiver in the lid: lay it on its back on the post, lens up and leads towards the
   front; the lid's hole goes over the lens. Driver: slide the perfboard down into the two slotted posts,
   components facing the board bay.
8. **Board.** Solder the wires to the board pads from the top. Lower the board into its bay a little forward,
   drop the antenna end onto the small shelf between the two guide posts, then slide it back so the USB-C
   receptacle enters the window in the back wall. A tooth on the lid stops it from sliding forward again. Do not
   route wires over the antenna end.
9. **Battery.** Put the holder into the left bay with its leads at the right end (towards the board). With
   AA/AAA cells, put the Schottky diode in the + lead (anode towards the battery) under heat-shrink: it stops
   the board's charger from feeding current into alkaline cells. Route the wires over the low middle part of the
   divider (it is full height only at its two ends) and along the channel between the bays. Li-ion cells
   connect straight to the board's battery pads through the switch, no diode.
10. **Lid.** Check that no wire sits over a lid finger or the top of the switch, close the lid and drive the two
   screws in until snug. Do not overtighten: the pilot holes are in plastic. The snap lid clicks in at three
   points; to open it, lift the edge near the left wall first.
11. **Feet.** Stick the four feet into the recesses under the case.

## Aiming the nose

The nose turns from 0° (beam level) to 90° (beam straight up). The left cheek has ticks every 15°, long ones at
0°, 45° and 90°; compare them with the LED tube. Rough settings for the default case (sensor height measured from
the table, distance from the LED to the TV sensor):

| Distance | Sensor at 30 mm | Sensor at 50 mm | Sensor at 80 mm |
|---|---|---|---|
| 50 mm | 21° | 38° | 54° |
| 100 mm | 11° | 22° | 35° |
| 150 mm | 8° | 15° | 25° |

`check.py` prints the same table for every variant. Start there, then fine-tune by watching the TV react; an
IR LED is visible as a faint purple glow through a phone camera.

## Reflashing and reset

The USB-C receptacle is reachable through the back wall. A recess on the outside thins the wall around it
(to 0.8 mm for the SuperMini, 1.0 mm for the XIAO) so the receptacle face is within 0.3 mm of the recess floor
and a normal cable plug seats fully.

To enter the bootloader, double-press the reset button with a straightened paperclip through the small hole in
the lid.
