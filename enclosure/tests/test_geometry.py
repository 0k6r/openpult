"""Geometry tests for every enclosure variant plus a few self-tests of the checkers."""

from __future__ import annotations

import math
from functools import lru_cache

import pytest
import trimesh

import build
import check
from params import BOARDS, POWERS, VARIANTS, Layout, Params, variant
from parts import Builder, beam_cone, bbox, box, to_trimesh

ALL = sorted(VARIANTS)


@lru_cache(maxsize=None)
def results(name: str) -> tuple[check.Result, ...]:
    return tuple(check.run_checks(variant(name)))


def find(name: str, prefix: str) -> list[check.Result]:
    found = [r for r in results(name) if r.name.startswith(prefix)]
    assert found, f"no check starting with {prefix!r}"
    return found


def assert_ok(name: str, prefix: str):
    for r in find(name, prefix):
        assert r.ok, f"{name}: {r.name}: {r.detail}"


# --------------------------------------------------------------------------- every variant


@pytest.mark.parametrize("name", ALL)
def test_all_checks_pass(name):
    failed = [r for r in results(name) if not r.ok and r.level == "error"]
    assert not failed, "\n".join(r.line() for r in failed)


@pytest.mark.parametrize("name", ALL)
@pytest.mark.parametrize("part", ["tray", "lid", "nose"])
def test_part_is_one_closed_solid(name, part):
    m = Builder(variant(name)).print_parts()[part]
    assert m.volume() > 0
    assert len(m.decompose()) == 1
    tm = to_trimesh(m)
    assert tm.is_watertight and tm.is_winding_consistent and tm.volume > 0
    assert bbox(m)[0][2] == pytest.approx(0.0, abs=1e-6), "print pose must sit on z = 0"


@pytest.mark.parametrize("name", ALL)
def test_stl_round_trip(name, tmp_path):
    written = build.build_variant(name, tmp_path)
    names = sorted(p.name for p, _ in written)
    assert names == ["assembly.stl", "lid.stl", "nose.stl", "tray.stl"]
    for path, _ in written:
        tm = trimesh.load(path, force="mesh")
        assert len(tm.faces) > 100
        if path.name != "assembly.stl":
            assert tm.is_watertight
            assert 5.0 < tm.extents.max() < 200.0


@pytest.mark.parametrize("name", ALL)
@pytest.mark.parametrize("prefix", [
    "no interference", "clearances", "components keep", "beam cone", "centre of mass",
    "antenna", "case height", "nose clears", "USB-C plug", "USB-C stays", "switch lever",
])
def test_named_check(name, prefix):
    assert_ok(name, prefix)


@pytest.mark.parametrize("name", ALL)
@pytest.mark.parametrize("part", ["tray", "lid", "nose"])
def test_part_fits_bed_and_prints_without_support(name, part):
    assert_ok(name, f"{part}: fits")
    assert_ok(name, f"{part}: overhangs")


# --------------------------------------------------------------------------- layout and parameters


def test_default_size_is_compact():
    lay = Layout(Params())
    assert 80 < lay.L < 100
    assert 45 < lay.W < 60
    assert lay.H <= 25


@pytest.mark.parametrize("board", sorted(BOARDS))
@pytest.mark.parametrize("power", sorted(POWERS))
def test_every_board_power_combination_lays_out(board, power):
    lay = Layout(Params(board=board, power=power))
    assert lay.pw_x1 < lay.spine_x0 <= lay.bc_x0 < lay.bx0 < lay.bx1 < lay.bc_x1 < lay.L
    assert lay.by1 < lay.sw_yc - lay.sw_half_y, "board must end before the switch pocket"
    assert lay.H >= lay.power.h + lay.p.floor + lay.p.lid_t


OPTION_SETS = {
    "plain": {},
    "back_ir_driver_2led_snaps": {"ir_rx": "back", "driver": True, "led_count": 2, "lid_fastening": "snaps"},
    "lid_ir_driver_no_button": {"ir_rx": "lid", "driver": True, "reset_button": False},
}


@pytest.mark.parametrize("board", sorted(BOARDS))
@pytest.mark.parametrize("power", sorted(POWERS))
@pytest.mark.parametrize("options", sorted(OPTION_SETS))
def test_every_combination_passes_the_checks(board, power, options):
    p = Params(board=board, power=power, **OPTION_SETS[options])
    failed = [r for r in check.run_checks(p) if not r.ok and r.level == "error"]
    assert not failed, "\n".join(r.line() for r in failed)


def test_bigger_battery_holder_grows_the_case_and_still_passes():
    p = Params(power_overrides={"l": 62.0, "w": 52.0, "h": 17.5})
    base = Layout(Params())
    lay = Layout(p)
    assert lay.L == pytest.approx(base.L + 4.0)
    assert lay.W == pytest.approx(base.W + 4.0)
    assert lay.H == pytest.approx(base.H + 1.5)
    failed = [r for r in check.run_checks(p) if not r.ok and r.level == "error"]
    assert not failed, "\n".join(r.line() for r in failed)


def test_custom_board_length():
    p = Params(board_overrides={"pcb_l": 36.0})
    lay = Layout(p)
    assert lay.by1 - lay.by0 == pytest.approx(36.0)
    failed = [r for r in check.run_checks(p) if not r.ok and r.level == "error"]
    assert not failed, "\n".join(r.line() for r in failed)


@pytest.mark.parametrize("bad", [
    {"board": "esp32"}, {"power": "9v"}, {"lid_fastening": "glue"}, {"ir_rx": "front"}, {"led_count": 3},
])
def test_invalid_options_raise(bad):
    with pytest.raises(ValueError):
        Layout(Params(**bad))


def test_hinge_bolt_length_matches_the_stack():
    one = Layout(Params())
    two = Layout(Params(led_count=2))
    assert one.bolt_len == 20
    assert two.bolt_len == 30
    for lay in (one, two):
        stack = 2 * lay.cheek_out - lay.p.nut_pocket_depth + lay.p.m3_nut_h
        assert lay.bolt_len >= stack


# --------------------------------------------------------------------------- nose kinematics


@pytest.mark.parametrize("angle", [0.0, 30.0, 60.0, 90.0])
def test_led_points_along_the_beam(angle):
    b = Builder(Params())
    lay = b.lay
    lo, hi = bbox(b.led(angle).solid)
    tip = lay.led_point(lay.p.led_step_u - lay.p.led_flange_h + lay.p.led_len, angle)
    assert lo[1] - 0.01 <= tip[1] <= hi[1] + 0.01
    assert lo[2] - 0.01 <= tip[2] <= hi[2] + 0.01
    dy, dz = lay.beam_dir(angle)
    assert math.degrees(math.atan2(dz, dy)) == pytest.approx(angle)


def test_required_angle_grows_with_sensor_height():
    lay = Layout(Params())
    a = [check.required_angle(lay, 100, h) for h in (30, 50, 80)]
    assert a[0] < a[1] < a[2]
    assert 0 < a[0] and a[2] < 90


# --------------------------------------------------------------------------- the checkers catch real problems


def test_overhang_detector_flags_a_cantilever_and_accepts_a_short_bridge():
    post = box(0, 0, 0, 4, 10, 10)
    shelf = box(4, 0, 8, 16, 10, 10)  # 12 mm cantilever
    regions = check.overhang_regions(post + shelf)
    assert regions and regions[0][0] == pytest.approx(12.0, abs=0.2)
    assert regions[0][3] == "cantilever"
    bridge = box(0, 0, 0, 3, 10, 10) + box(11, 0, 0, 14, 10, 10) + box(3, 0, 8, 11, 10, 10)
    regions = check.overhang_regions(bridge)
    assert regions and regions[0][0] == pytest.approx(4.0, abs=0.2)
    assert regions[0][3] == "bridge"


def test_beam_check_detects_a_blocker():
    lay = Layout(Params())
    cone = beam_cone(lay, 0.0)
    _, y, z = lay.led_point(30.0, 0.0)
    wall = box(lay.nose_x - 10, y, z - 10, lay.nose_x + 10, y + 2, z + 10)
    assert check.inter_volume(cone, wall) > 1.0


def test_interference_and_gap_helpers():
    a = box(0, 0, 0, 10, 10, 10)
    assert check.inter_volume(a, box(9, 0, 0, 19, 10, 10)) == pytest.approx(100.0)
    assert check.inter_volume(a, box(10, 0, 0, 20, 10, 10)) == pytest.approx(0.0)
    assert check.gap(a, box(10.3, 0, 0, 20, 10, 10), 1.0) == pytest.approx(0.3, abs=1e-6)


def test_nose_too_close_to_the_wall_is_reported():
    res = {r.name.split(" (")[0]: r for r in check.run_checks(Params(nose_back_gap=0.2))}
    assert not res["no interference"].ok and "nose" in res["no interference"].detail
    assert not res["clearances"].ok and "nose / case without cheeks" in res["clearances"].detail
