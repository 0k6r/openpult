"""Tests for import_flipper_irdb.py, its golden files and, if generated, the files in profiles/.

Run: python3 -I -m unittest discover -s tools/profiles
Set OPENPULT_IRDB=<Flipper-IRDB checkout at the commit in profiles/index.json> to also check that profiles/ is
exactly what the importer produces.
"""
import importlib.util
import json
import os
import pathlib
import re
import shutil
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FIXTURES = HERE / "fixtures" / "irdb"
PROFILES = ROOT / "profiles"
COMMIT = "0123456789abcdef0123456789abcdef01234567"

_spec = importlib.util.spec_from_file_location("import_flipper_irdb", HERE / "import_flipper_irdb.py")
imp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(imp)
ALIASES = imp.Aliases.load(imp.DEFAULT_ALIASES)
_gen_spec = importlib.util.spec_from_file_location("gen_import_vectors", HERE / "gen_import_vectors.py")
gen = importlib.util.module_from_spec(_gen_spec)
_gen_spec.loader.exec_module(gen)

APP_KEYS = [
    "power", "powerOff", "wakeUp", "input", "home", "back", "options", "up", "down", "left", "right", "confirm",
    "volumeUp", "volumeDown", "mute", "channelUp", "channelDown", "play", "pause", "stop", "rewind", "forward",
    "previous", "next", "red", "green", "yellow", "blue", "num0", "num1", "num2", "num3", "num4", "num5", "num6",
    "num7", "num8", "num9", "display", "subtitles", "audioTrack", "guide", "hdmi1", "hdmi2", "hdmi3", "hdmi4",
    "menu", "exit", "teletext", "lastChannel",
]

# Independent copy of the Flipper protocol widths, so the validator does not trust the importer.
WIDTHS = {
    "NEC": (8, 8), "NECext": (16, 16), "NEC42": (13, 8), "NEC42ext": (26, 16), "Samsung32": (8, 8),
    "RC5": (5, 6), "RC5X": (5, 7), "RC6": (8, 8), "SIRC": (5, 7), "SIRC15": (8, 7), "SIRC20": (13, 7),
    "Kaseikyo": (26, 10), "RCA": (4, 8), "Pioneer": (8, 8),
}


def nec(a, c):
    return {"p": "NEC", "a": a, "c": c}


def run(out, **kwargs):
    kwargs.setdefault("commit", COMMIT)
    kwargs.setdefault("contrib", None)
    return imp.run_import(FIXTURES, out, **kwargs)


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def tree_bytes(root):
    root = pathlib.Path(root)
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


# --------------------------------------------------------------------------------------------------------------
# Schema validator (profiles/SCHEMA.md)


def leb_len(v):
    n = 1
    while v >= 0x80:
        v >>= 7
        n += 1
    return n


def check_cmd(tc, cmd, where):
    tc.assertIsInstance(cmd, dict, where)
    if "raw" in cmd:
        tc.assertEqual(set(cmd), {"raw"}, where)
        raw = cmd["raw"]
        tc.assertEqual(set(raw), {"f", "d", "i", "r"}, where)
        tc.assertTrue(20000 <= raw["f"] <= 65535, where)
        tc.assertTrue(10 <= raw["d"] <= 50, where)
        intro, repeat = raw["i"], raw["r"]
        for section in (intro, repeat):
            tc.assertIsInstance(section, list, where)
            tc.assertEqual(len(section) % 2, 0, where)
            tc.assertTrue(all(type(v) is int and 50 <= v <= 500000 for v in section), where)
            tc.assertLessEqual(sum(section), 1_000_000, where)
            tc.assertTrue(all(m <= 30000 for m in section[0::2]), where)
        tc.assertTrue(repeat, where)
        tc.assertTrue(2 <= len(intro) + len(repeat) <= 1024, where)
        table = list(dict.fromkeys(intro + repeat))
        tc.assertLessEqual(len(table), 16, where)
        blob = 9 + sum(leb_len(v) for v in table) + (len(intro) + 1) // 2 + (len(repeat) + 1) // 2
        tc.assertLessEqual(blob, 576, where)
    else:
        tc.assertEqual(set(cmd), {"p", "a", "c"}, where)
        tc.assertIn(cmd["p"], WIDTHS, where)
        abits, cbits = WIDTHS[cmd["p"]]
        tc.assertTrue(type(cmd["a"]) is int and 0 <= cmd["a"] < 1 << abits, where)
        tc.assertTrue(type(cmd["c"]) is int and 0 <= cmd["c"] < 1 << cbits, where)


def validate_profiles_dir(tc, root):
    root = pathlib.Path(root)
    index = load(root / "index.json")
    tc.assertEqual(set(index), {"schema", "source", "brands"})
    tc.assertEqual(index["schema"], 1)
    src = index["source"]
    tc.assertTrue({"db", "url", "commit", "license"} <= set(src) <= {"db", "url", "commit", "license", "note"})
    tc.assertRegex(src["commit"], r"^[0-9a-f]{40}$")
    tc.assertEqual(src["license"], "CC0-1.0")
    ids = [b["id"] for b in index["brands"]]
    tc.assertEqual(ids, sorted(set(ids)))
    tc.assertEqual({p.name for p in (root / "brands").glob("*.json")}, {f"{i}.json" for i in ids})
    names_by_brand, profiles = {}, []
    for b in index["brands"]:
        tc.assertEqual(set(b), {"id", "name", "file", "profiles"})
        tc.assertRegex(b["id"], r"^[a-z0-9]+(-[a-z0-9]+)*$")
        tc.assertEqual(b["file"], f"brands/{b['id']}.json")
        items = load(root / b["file"])
        tc.assertIsInstance(items, list)
        tc.assertEqual(len(items), b["profiles"])
        tc.assertGreater(len(items), 0)
        names_by_brand[b["id"]] = b["name"]
        seen_names = set()
        for n, p in enumerate(items, 1):
            where = f"{b['file']}#{n}"
            tc.assertEqual(list(p), ["id", "brand", "name", "models", "weight", "source", "keys", "extra"], where)
            tc.assertEqual(p["id"], f"{b['id']}-{n}", where)
            tc.assertEqual(p["brand"], b["name"], where)
            tc.assertTrue(isinstance(p["name"], str) and 0 < len(p["name"]) <= 120, where)
            tc.assertNotIn(p["name"], seen_names, where)
            seen_names.add(p["name"])
            tc.assertTrue(all(isinstance(m, str) and m for m in p["models"]), where)
            tc.assertEqual(len(set(p["models"])), len(p["models"]), where)
            tc.assertEqual(p["weight"], len(p["source"]), where)
            tc.assertEqual(p["source"], sorted(set(p["source"])), where)
            tc.assertTrue(all(re.match(r"^(contrib/)?TVs/", s) for s in p["source"]), where)
            tc.assertTrue(p["keys"] or p["extra"], where)
            order = [k for k in APP_KEYS if k in p["keys"]]
            tc.assertEqual(list(p["keys"]), order, where)
            for k, cmd in p["keys"].items():
                check_cmd(tc, cmd, f"{where} {k}")
            for e in p["extra"]:
                tc.assertEqual(set(e), {"name", "cmd"}, where)
                tc.assertTrue(isinstance(e["name"], str) and 0 < len(e["name"]) <= 40, where)
                check_cmd(tc, e["cmd"], f"{where} extra {e['name']}")
            profiles.append(p)

    scan = load(root / "power_scan.json")
    tc.assertIsInstance(scan, list)
    weights = [e["weight"] for e in scan]
    tc.assertEqual(weights, sorted(weights, reverse=True))
    expected = {}
    for p in profiles:
        cmd = p["keys"].get("power") or p["keys"].get("wakeUp")
        if cmd:
            key = json.dumps(cmd, sort_keys=True)
            entry = expected.setdefault(key, [0, set()])
            entry[0] += p["weight"]
            entry[1].add(p["brand"])
    got = {}
    for e in scan:
        tc.assertEqual(set(e), {"cmd", "brands", "weight"})
        check_cmd(tc, e["cmd"], "power_scan")
        key = json.dumps(e["cmd"], sort_keys=True)
        tc.assertNotIn(key, got)
        tc.assertEqual(len(set(e["brands"])), len(e["brands"]))
        got[key] = [e["weight"], set(e["brands"])]
    tc.assertEqual(got, expected)

    tc.assertIn("CC0 1.0 Universal", (root / "LICENSE").read_text(encoding="utf-8"))
    return index, profiles, scan


# --------------------------------------------------------------------------------------------------------------


class AliasTests(unittest.TestCase):
    def keys_of(self, *names):
        buttons = [(n, nec(4, i)) for i, n in enumerate(names)]
        keys, extra, _ = imp.map_buttons(buttons, ALIASES)
        return {k: names[v["c"]] for k, v in keys.items()}, [e["name"] for e in extra]

    def test_alias_file_covers_app_keys_in_order(self):
        self.assertEqual(ALIASES.key_order, APP_KEYS)

    def test_alias_file_matches_remote_key_enum(self):
        swift = ROOT / "app" / "BraviaKit" / "Sources" / "BraviaKit" / "RemoteKey.swift"
        if not swift.exists():
            self.skipTest("RemoteKey.swift not present")
        text = swift.read_text(encoding="utf-8")
        body = text.split("enum RemoteKey", 1)[1].split("public var", 1)[0]
        cases = re.findall(r"case ([^\n]+)", body)
        swift_keys = [k.strip() for line in cases for k in line.split(",")]
        self.assertTrue(set(swift_keys) <= set(APP_KEYS), set(swift_keys) - set(APP_KEYS))

    def test_normalize(self):
        n = imp.normalize_name
        self.assertEqual(n("Vol_up"), "volup")
        self.assertEqual(n("VOL +"), "vol+")
        self.assertEqual(n("VOL -"), "vol-")
        self.assertEqual(n("Power-Off"), "poweroff")
        self.assertEqual(n("  Ch Next "), "chnext")
        self.assertEqual(n("-"), "-")
        self.assertEqual(n("_"), "")

    def test_common_names(self):
        cases = {
            "volumeUp": ["Vol_up", "VOL+", "Volume Up", "vol +"],
            "volumeDown": ["Vol_dn", "VOL-", "Vol_down", "VOL -"],
            "channelUp": ["Ch_next", "CH+", "Ch_up", "P+"],
            "channelDown": ["Ch_prev", "CH-", "Ch_down", "P-"],
            "confirm": ["Ok", "Enter", "Select", "OK"],
            "input": ["Source", "Input", "AV", "TV/AV"],
            "exit": ["Exit"], "menu": ["Menu", "Settings"],
            "display": ["Info", "Display"], "back": ["Return", "Back"], "mute": ["Mute", "MUTE"],
            "power": ["Power", "Pwr", "POWER"], "wakeUp": ["Power_on", "Power On"],
            "powerOff": ["Power_off", "Power-Off"],
            "num0": ["0"], "num9": ["9"], "teletext": ["Text", "TTX"], "lastChannel": ["Pre_ch", "Recall"],
            "guide": ["Guide", "EPG"], "subtitles": ["Subtitle", "CC"], "audioTrack": ["Audio", "MTS"],
            "home": ["Home", "Smart_hub"], "options": ["Tools", "Options"],
            "rewind": ["Rewind", "Fast_ba"], "forward": ["Fast_forward", "Ff"], "hdmi1": ["Hdmi_1", "HDMI 1"],
        }
        for key, names in cases.items():
            for name in names:
                keys, extra = self.keys_of(name)
                self.assertIn(key, keys, name)
                self.assertEqual(extra, [], name)

    def test_priority_and_extra(self):
        keys, extra = self.keys_of("Enter", "Ok", "Settings", "Menu", "Netflix", "Return", "Back")
        self.assertEqual(keys["confirm"], "Ok")
        self.assertEqual(keys["menu"], "Menu")
        self.assertEqual(keys["back"], "Back")
        self.assertEqual(extra, ["Enter", "Settings", "Netflix", "Return"])

    def test_first_of_equal_names_wins(self):
        buttons = [("Power", nec(4, 8)), ("Power", nec(4, 9))]
        keys, extra, dropped = imp.map_buttons(buttons, ALIASES)
        self.assertEqual(keys["power"], nec(4, 8))
        self.assertEqual(extra, [{"name": "Power", "cmd": nec(4, 9)}])
        self.assertEqual(dropped, 0)

    def test_duplicate_codes_dropped(self):
        buttons = [("Power", nec(4, 8)), ("Power2", nec(4, 8)), ("Sleep", nec(4, 7)), ("Timer", nec(4, 7))]
        keys, extra, dropped = imp.map_buttons(buttons, ALIASES)
        self.assertEqual(extra, [{"name": "Sleep", "cmd": nec(4, 7)}])
        self.assertEqual(dropped, 2)

    def test_play_pause_toggle_fills_both(self):
        keys, _ = self.keys_of("Play_pause")
        self.assertEqual((keys["play"], keys["pause"]), ("Play_pause", "Play_pause"))
        keys, extra = self.keys_of("Play", "Pause", "Play/Pause")
        self.assertEqual((keys["play"], keys["pause"]), ("Play", "Pause"))
        self.assertEqual(extra, ["Play/Pause"])

    def test_dual_label_buttons(self):
        keys, extra = self.keys_of("Blue_|_epg", "Pause_|_zoom", "16:9_|_wide")
        self.assertEqual((keys["blue"], keys["guide"], keys["pause"]), ("Blue_|_epg", "Blue_|_epg", "Pause_|_zoom"))
        self.assertEqual(extra, ["16:9_|_wide"])
        keys, extra = self.keys_of("Green_|_subtitle", "Subtitle")
        self.assertEqual((keys["green"], keys["subtitles"]), ("Green_|_subtitle", "Subtitle"))
        keys, _ = self.keys_of("Vol-_|_Left", "CH-_|_Down")
        self.assertEqual((keys["volumeDown"], keys["left"]), ("Vol-_|_Left", "Vol-_|_Left"))
        self.assertEqual((keys["channelDown"], keys["down"]), ("CH-_|_Down", "CH-_|_Down"))

    def test_letter_colors_need_the_whole_group(self):
        keys, _ = self.keys_of("A", "B", "C", "D")
        self.assertEqual([keys[k] for k in ("red", "green", "yellow", "blue")], ["A", "B", "C", "D"])
        keys, _ = self.keys_of("R", "G", "Y", "B")
        self.assertEqual([keys[k] for k in ("red", "green", "yellow", "blue")], ["R", "G", "Y", "B"])
        keys, extra = self.keys_of("A", "B")
        self.assertNotIn("red", keys)
        self.assertEqual(extra, ["A", "B"])
        keys, extra = self.keys_of("Red", "A", "B", "C", "D")
        self.assertEqual(keys["red"], "Red")
        self.assertEqual(extra, ["A"])

    def test_aliases_reject_duplicates(self):
        with self.assertRaises(ValueError):
            imp.Aliases({"keys": {"power": ["Power", "POWER"]}})
        with self.assertRaises(ValueError):
            imp.Aliases({"keys": {"power": ["power"]}, "letterColors": [{"a": "red"}]})


class RawTests(unittest.TestCase):
    def raw(self, data, f=38000, duty=0.33):
        cmd, reason = imp.normalize_raw(f, duty, data)
        self.assertIsNone(reason)
        return cmd["raw"]

    def reason(self, data, f=38000, duty=0.33):
        cmd, reason = imp.normalize_raw(f, duty, data)
        self.assertIsNone(cmd)
        return reason

    def test_single_frame_goes_to_repeat_with_tail_gap(self):
        r = self.raw([9000, 4500, 560, 1690, 560])
        self.assertEqual(r, {"f": 38000, "d": 33, "i": [], "r": [9000, 4500, 560, 1690, 560, 40000]})

    def test_even_recording_keeps_its_gap(self):
        self.assertEqual(self.raw([3488, 3488, 872, 34008])["r"], [3488, 3488, 872, 34008])

    def test_cut_off_recording_gets_tail_gap(self):
        self.assertEqual(self.raw([4500, 4500, 560, 537])["r"], [4500, 4500, 560, 40000])

    def test_equal_frames_kept_once(self):
        data = [2400, 600, 1200, 600, 600, 25800, 2380, 610, 1210, 590, 610, 25790, 2410, 600, 1190, 600, 600]
        r = self.raw(data)
        self.assertEqual((r["i"], r["r"]), ([], [2400, 600, 1200, 600, 600, 25800]))

    def test_frame_plus_repeat_code(self):
        frame = [9000, 4500, 560, 1690, 560, 560, 560, 30000]
        r = self.raw(frame + [9000, 2250, 560, 96000, 9000, 2250, 560])
        self.assertEqual(r["i"], frame)
        self.assertEqual(r["r"], [9000, 2250, 560, 96000])
        r = self.raw(frame + [9000, 2250, 560])
        self.assertEqual((r["i"], r["r"]), (frame, [9000, 2250, 560, 40000]))

    def test_frame_pairs(self):
        a = [300, 1800, 300, 800, 300, 45000]
        b = [300, 800, 300, 1800, 300, 45000]
        r = self.raw(a + b + a + b[:-1])
        self.assertEqual((r["i"], r["r"]), ([], a + b))
        r = self.raw(a + b + a + b + a[:-1])
        self.assertEqual((r["i"], r["r"]), ([], a + b))
        # A period of two frames needs two full periods; A B A is kept whole.
        r = self.raw(a + b + a[:-1])
        self.assertEqual((r["i"], r["r"]), ([], a + b + a[:-1] + [40000]))

    def test_cut_off_last_frame_is_dropped(self):
        frame = [2710, 880, 440, 920, 300, 99800]
        r = self.raw(frame + [2050])  # a lone mark after the frame (880/920 cluster to 900)
        self.assertEqual((r["i"], r["r"]), ([], [2710, 900, 440, 900, 300, 99800]))
        nec = [9000, 4500] + [560, 560, 560, 1690] * 8 + [560, 40000]
        r = self.raw(nec + nec[:23])  # NEC frame + a truncated copy
        self.assertEqual((r["i"], r["r"]), ([], nec))
        sirc = [2400, 600, 1200, 600, 600, 600, 1200, 600, 600, 25800]
        r = self.raw(sirc * 3 + sirc[:5])  # A A A + fragment
        self.assertEqual((r["i"], r["r"]), ([], sirc))
        # A real repeat code is shorter but does not match the start of the frame: kept.
        r = self.raw(nec + [9000, 2250, 560])
        self.assertEqual((r["i"], r["r"]), (nec, [9000, 2250, 560, 40000]))

    def test_irregular_recording_is_kept_whole(self):
        data = [1000, 1000, 1000, 30000, 2000, 500, 2000, 30000, 500, 500, 500, 500, 500]
        r = self.raw(data)
        self.assertEqual((r["i"], r["r"]), ([], data + [40000]))

    def test_clustering_within_five_percent(self):
        values = [560, 540, 580, 1690, 1650, 1720, 9000, 4500, 4400]
        mapping = imp.cluster_map(values)
        for v, c in mapping.items():
            self.assertLessEqual(abs(v - c), 0.05 * c)
        self.assertEqual(len(set(mapping.values())), 4)
        self.assertEqual(mapping[540], mapping[580])
        self.assertNotEqual(imp.cluster_map([1000, 1200])[1000], imp.cluster_map([1000, 1200])[1200])

    def test_clustered_output_is_within_table_limit(self):
        jitter = [9000, 4500] + [v + (i % 9) * 5 for i, v in enumerate([560, 560, 560, 1690] * 16)] + [560]
        self.assertGreater(len(set(jitter)), 16)
        r = self.raw(jitter)
        self.assertLessEqual(len(set(r["r"])), 16)

    def test_duty_and_carrier(self):
        self.assertEqual(self.raw([500, 500, 500], duty=0.330000)["d"], 33)
        self.assertEqual(self.raw([500, 500, 500], duty=0.25)["d"], 25)
        self.assertEqual(self.raw([500, 500, 500], f=36700)["f"], 36700)

    def test_limits(self):
        self.assertEqual(self.reason([500, 500, 500], f=15000), "raw: carrier outside 20000..65535 Hz")
        self.assertEqual(self.reason([500, 500, 500], f=70000), "raw: carrier outside 20000..65535 Hz")
        self.assertEqual(self.reason([500, 500, 500], duty=0.6), "raw: duty cycle outside 10..50 %")
        self.assertEqual(self.reason([31000, 1000, 500]), "raw: mark longer than 30 ms")
        self.assertEqual(self.reason([560, 1690] * 520), "raw: more than 1024 durations")
        self.assertEqual(self.reason([1000, 500, 1000, 600000, 1000, 500, 1000]), "raw: duration outside 50..500000 us")
        self.assertEqual(self.reason([1000, 500, 1000, 400000, 2000, 500, 2000, 400000, 3000, 500, 3000, 400000]),
                         "raw: section longer than 1 s")
        many = [1000, 1200, 1440, 1730, 2070, 2490, 2990, 3580, 4300, 5160, 6190, 7430, 8920, 10700, 12840,
                15410, 18490]
        self.assertEqual(self.reason([v for m in many for v in (m, 500)]),
                         "raw: more than 16 distinct durations after clustering")
        self.assertEqual(self.reason([]), "raw: empty data")
        self.assertEqual(self.reason([500, 0, 500]), "raw: non-positive duration")
        # The longest accepted press: 1024 durations.
        self.assertEqual(len(self.raw([300, 600] * 511 + [300])["r"]), 1024)

    def test_blob_size_matches_protocol_vector(self):
        # PROTOCOL.md: Sony Power, table [2400, 600, 1200, 25800], 26 repeat symbols -> 35 bytes incl. 4-byte header.
        repeat = [2400, 600] + [1200, 600, 600, 600, 1200, 600, 600, 600, 1200, 600, 600, 600, 1200, 600, 600, 600,
                                600, 600, 1200, 600, 600, 600, 600, 25800]
        self.assertEqual(imp.blob_size([], repeat), 31)

    def test_noise_pulses_rejected(self):
        self.assertEqual(self.reason([9000, 4500, 560, 30, 560]), "raw: duration outside 50..500000 us")
        self.assertEqual(self.reason([181, 66010, 1102]), "raw: isolated pulses only (noise)")
        self.assertEqual(self.reason([500]), "raw: isolated pulses only (noise)")
        # Trailing lone marks after a real frame are dropped.
        r = self.raw([182, 5010, 176, 7320, 175, 61200, 180, 29870, 180])
        self.assertEqual((r["i"], r["r"]), ([], [178, 5010, 178, 7320, 178, 61200]))  # marks clustered

    def test_hostile_sizes_are_cheap(self):
        import time
        start = time.monotonic()
        spread = [1_000_000 + 2 * i for i in range(4000)]
        mapping = imp.cluster_map(spread)
        self.assertEqual(len(mapping), 4000)
        for v, c in mapping.items():
            self.assertLessEqual(abs(v - c), 0.05 * c)
        self.assertEqual(self.reason([500] * 4097), "raw: recording longer than 4096 durations")
        frames = [v for i in range(1000) for v in (500 + (i % 2) * 300, 500, 500, 25000)]   # 1000 frames: kept whole
        self.assertEqual(self.reason(frames), "raw: more than 1024 durations")
        self.assertLess(time.monotonic() - start, 2.0)


class ParseTests(unittest.TestCase):
    def test_junk_is_skipped_and_counted(self):
        text = (FIXTURES / "TVs" / "Acme" / "Acme_junk.ir").read_text(encoding="utf-8")
        buttons, errors = imp.parse_ir_text(text)
        self.assertEqual([n for n, _ in buttons], ["Power", "Mute"])
        self.assertEqual(dict(errors), {
            "parsed: malformed address/command": 2,
            "parsed: unknown protocol": 1,
            "parsed: address/command wider than the protocol": 1,
            "parsed: missing field": 1,
            "block: unknown type": 1,
            "raw: malformed number": 1,
            "raw: non-positive duration": 1,
            "block: button without a name": 1,
            "recovered: missing type inferred from the fields": 1,
        })

    def test_little_endian_and_header(self):
        text = ("Filetype: IR signals file\r\nVersion: 1\r\n#\r\nname: Power\r\ntype: parsed\r\n"
                "protocol: NECext\r\naddress: 86 05 00 00\r\ncommand: 0F F0 00 00\r\n")
        buttons, errors = imp.parse_ir_text(text)
        self.assertEqual(buttons, [("Power", {"p": "NECext", "a": 0x0586, "c": 0xF00F})])
        self.assertFalse(errors)
        _, errors = imp.parse_ir_text("hello\nname: Power\n")
        self.assertEqual(dict(errors), {"file: not an IR signals file": 1})

    def test_numbers_are_plain_ascii(self):
        self.assertEqual(imp.parse_number("38000", int), 38000)
        self.assertEqual(imp.parse_number("0.330000", float), 0.33)
        for bad in ("38_000", "+38000", "٣٨٠٠٠", "1e5", "38k", "", "9" * 10):
            self.assertIsNone(imp.parse_number(bad, int), bad)
        for bad in ("inf", "nan", "1e999", "0,33", "-0.33"):
            self.assertIsNone(imp.parse_number(bad, float), bad)

    def test_names_are_cleaned(self):
        text = ("Filetype: IR signals file\nVersion: 1\nname: Vol\u202e_up\u0007   now\ntype: parsed\n"
                "protocol: NEC\naddress: 04 00 00 00\ncommand: 02 00 00 00\n")
        buttons, _ = imp.parse_ir_text(text)
        self.assertEqual(buttons[0][0], "Vol_up now")

    def test_models_from_file_names(self):
        self.assertEqual(imp.file_label("Samsung/Samsung_BN59-01175N.ir", "Samsung"), (["BN59-01175N"], "BN59-01175N"))
        self.assertEqual(imp.file_label("LG/LG_OLED48C37LA (LG_OLED C3 models).ir", "LG")[0], ["OLED48C37LA"])
        self.assertEqual(imp.file_label("LG/LG_Hotel_TV_Home2.ir", "LG"), ([], "Hotel Home2"))
        self.assertEqual(imp.file_label("LG/LG.ir", "LG"), ([], ""))
        self.assertEqual(imp.file_label("DuraBrand DU-1301", "DuraBrand"), (["DU-1301"], "DU-1301"))
        self.assertEqual(imp.brand_of("DuraBrand DU-1301"), "DuraBrand")
        self.assertEqual(imp.brand_of("Syntax-Brillian/x.ir"), "Syntax-Brillian")
        self.assertEqual(imp.slugify("Syntax-Brillian"), "syntax-brillian")


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="openpult-profiles-"))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_fixture_import(self):
        report = run(self.tmp / "out")
        index, profiles, scan = validate_profiles_dir(self, self.tmp / "out")
        self.assertEqual([b["id"] for b in index["brands"]],
                         ["acme", "fizeo", "kumo", "nova", "nova-tek", "oddbrand", "olmann", "zenco", "zeta"])
        self.assertFalse((self.tmp / "out" / "SOURCES.md").exists())
        self.assertEqual(index["source"]["commit"], COMMIT)
        self.assertIn("abc1234", index["source"]["note"])
        acme = load(self.tmp / "out" / "brands" / "acme.json")

        merged = acme[0]
        self.assertEqual(merged["id"], "acme-1")
        self.assertEqual(merged["weight"], 2)
        self.assertEqual(merged["models"], ["AB-1000", "AB-2000"])
        self.assertEqual(merged["name"], "Acme TV (AB-1000, AB-2000)")
        self.assertEqual(merged["source"], ["TVs/Acme/Acme_AB-1000.ir", "TVs/Acme/Acme_AB-2000.ir"])
        k = merged["keys"]
        self.assertEqual(k["power"], nec(4, 8))
        self.assertEqual((k["wakeUp"], k["powerOff"]), (nec(4, 0xC4), nec(4, 0xC5)))
        self.assertEqual((k["volumeUp"], k["volumeDown"]), (nec(4, 2), nec(4, 3)))
        self.assertEqual((k["channelUp"], k["channelDown"]), (nec(4, 0), nec(4, 1)))
        self.assertEqual((k["confirm"], k["input"], k["back"]), (nec(4, 0x44), nec(4, 0x0B), nec(4, 0x28)))
        self.assertEqual((k["red"], k["blue"]), (nec(4, 0x60), nec(4, 0x63)))
        self.assertEqual(k["play"], k["pause"])
        self.assertEqual([e["name"] for e in merged["extra"]], ["Enter", "Netflix"])

        self.assertEqual([p["name"] for p in acme[1:]], ["Acme TV (Hotel)", "Acme TV (junk)"])
        odd = load(self.tmp / "out" / "brands" / "oddbrand.json")
        self.assertEqual(odd[0]["source"], ["TVs/Oddbrand OB-77"])
        self.assertEqual(odd[0]["keys"]["mute"], {"p": "RC5", "a": 0, "c": 13})

        zenco = load(self.tmp / "out" / "brands" / "zenco.json")[0]
        self.assertEqual(sorted(zenco["keys"]), sorted(["power", "volumeUp", "volumeDown", "mute", "channelUp",
                                                       "channelDown"]))
        self.assertEqual(zenco["keys"]["volumeUp"]["raw"]["i"], [9000, 4500, 560, 1690, 560, 560, 560, 39000])
        self.assertEqual(zenco["extra"], [{"name": "Netflix", "cmd": {"p": "Samsung32", "a": 7, "c": 0x56}}])

        self.assertEqual(scan[0], {"cmd": nec(4, 8), "brands": ["Acme", "Oddbrand"], "weight": 5})
        self.assertEqual([e["brands"] for e in scan if e["cmd"] == zenco["keys"]["power"]], [["Zenco"]])
        self.assertEqual(len(scan), 20)

        self.assertEqual(report["skipped_files"], {"file: brand name without letters or digits": 2,
                                                   "file: no usable buttons": 1, "file: not an IR signals file": 2})
        codes = report["skipped_codes"]
        for reason, count in {
            "raw: carrier outside 20000..65535 Hz": 1, "raw: duty cycle outside 10..50 %": 1,
            "raw: mark longer than 30 ms": 1, "raw: more than 1024 durations": 1,
            "raw: section longer than 1 s": 1, "raw: duration outside 50..500000 us": 1,
            "raw: more than 16 distinct durations after clustering": 1,
            "raw: isolated pulses only (noise)": 1,
        }.items():
            self.assertEqual(codes.get(reason), count, reason)
        self.assertEqual(report["duplicates_dropped"], 1)  # the second, identical Power in AB-1000
        self.assertEqual(report["files_used"], 25)
        self.assertEqual(report["profiles"], 23)

    def test_fixture_edge_cases(self):
        run(self.tmp / "out")
        out = self.tmp / "out"
        index = load(out / "index.json")
        names = {b["id"]: b["name"] for b in index["brands"]}
        # os.walk lists TVs/nova_NV-1.ir before TVs/Nova/: the first spelling of an id names the brand.
        self.assertEqual((names["nova"], names["nova-tek"], names["olmann"], names["fizeo"]),
                         ("nova", "Nova Tek", "\u00d6lmann", "\ufb01zeo"))
        nova = load(out / "brands" / "nova.json")
        self.assertEqual(nova[0]["models"], ["NV-30A", "nv-30b", "NV-31", "nv-31"])
        self.assertEqual(nova[0]["name"], "nova TV (NV-30A, nv-30b, NV-31 +1)")
        zeta = {p["source"][0].split("/")[-1]: p for p in load(out / "brands" / "zeta.json")}
        self.assertEqual([zeta[f]["name"] for f in ("Zeta_Hotel (2019).ir", "Zeta_Hotel (old).ir", "Zeta_Hotel.ir")],
                         ["Zeta TV (Hotel)", "Zeta TV (Hotel) #2", "Zeta TV (Hotel) #3"])
        long_name = next(p["name"] for p in zeta.values() if p["name"].endswith("\u2026)"))
        self.assertEqual(len(long_name), 98 + len("\u2026)"))
        protocols = zeta["Zeta_Protocols.ir"]
        self.assertEqual(sorted({c["p"] for c in protocols["keys"].values()}), sorted(imp.PROTOCOLS))
        raw = {k: v["raw"] for k, v in zeta["Zeta_RAW-2.ir"]["keys"].items()}
        # duty_cycle 0.125 / 0.505 / 0.345 / 32.5 / 0.105: round half to even.
        self.assertEqual([raw[k]["d"] for k in ("up", "down", "left", "right", "confirm")], [12, 50, 34, 32, 10])
        self.assertEqual(raw["channelUp"]["r"][:3], [1000, 500, 1000])     # 950 and 1050: exactly +-5 %
        self.assertEqual(raw["channelDown"]["r"][:3], [949, 500, 1051])    # 949 and 1051: just outside
        self.assertEqual(raw["volumeUp"]["r"], [9000, 2250, 560, 96000])   # A B B
        self.assertEqual(len(raw["volumeDown"]["r"]), 12)                  # A B A B
        self.assertEqual(raw["mute"]["r"], [2400, 600, 1200, 600, 600, 25800])   # A A + cut-off tail
        olmann = load(out / "brands" / "olmann.json")
        self.assertEqual(olmann[0]["keys"]["volumeUp"], {"p": "NECext", "a": 0x7E10, "c": 0xFE02})  # NBSP, CRLF
        self.assertEqual(olmann[1]["source"], ["TVs/\u00d6lmann/\u00d6lmann_\u00d6L-60.ir"])  # BOM
        self.assertIn("Info\ufffd\ufffd\ufffdx", [e["name"] for e in olmann[2]["extra"]])  # broken UTF-8
        z1 = zeta["Zeta_Z-1.ir"]["keys"]
        self.assertEqual((z1["power"], z1["volumeUp"]), (nec(0x31, 1), nec(0x31, 2)))  # \x1c, \x85, \u2028 ...

    def test_fixture_matches_golden(self):
        """tools/profiles/fixtures/expected is what the Swift port is compared with."""
        files, report = gen.golden()
        expected = {p.relative_to(gen.EXPECTED).as_posix(): p.read_bytes() for p in gen.EXPECTED.rglob("*")
                    if p.is_file() and not p.name.startswith(".")}
        self.assertEqual(files, expected, "run: python3 -I tools/profiles/gen_import_vectors.py")
        self.assertEqual(report, load(gen.EXPECTED_REPORT))

    def test_vectors_are_current(self):
        self.assertEqual(gen.stale(), [], "run: python3 -I tools/profiles/gen_import_vectors.py")

    def test_reimport_is_identical(self):
        run(self.tmp / "a")
        run(self.tmp / "b")
        self.assertEqual(tree_bytes(self.tmp / "a"), tree_bytes(self.tmp / "b"))
        before = tree_bytes(self.tmp / "a")
        run(self.tmp / "a")
        self.assertEqual(tree_bytes(self.tmp / "a"), before)

    def test_reimport_in_new_processes_is_identical(self):
        # Each `python3 -I` process gets its own string-hash seed, so set/dict ordering bugs would show here.
        import subprocess
        import sys
        script = str(HERE / "import_flipper_irdb.py")
        for name in ("p1", "p2", "p3"):
            subprocess.run([sys.executable, "-I", script, "--irdb", str(FIXTURES), "--out", str(self.tmp / name),
                            "--commit", COMMIT, "--contrib", str(self.tmp / "none")],
                           check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(tree_bytes(self.tmp / "p1"), tree_bytes(self.tmp / "p2"))
        self.assertEqual(tree_bytes(self.tmp / "p2"), tree_bytes(self.tmp / "p3"))
        run(self.tmp / "inproc")
        self.assertEqual(tree_bytes(self.tmp / "p1"), tree_bytes(self.tmp / "inproc"))

    def test_stale_brand_files_removed(self):
        out = self.tmp / "out"
        (out / "brands").mkdir(parents=True)
        (out / "brands" / "gone.json").write_text("[]\n")
        (out / "SCHEMA.md").write_text("kept\n")
        run(out)
        self.assertFalse((out / "brands" / "gone.json").exists())
        self.assertEqual((out / "SCHEMA.md").read_text(), "kept\n")

    def test_symlinks_are_not_followed(self):
        db = self.tmp / "db"
        shutil.copytree(FIXTURES, db)
        secret = self.tmp / "outside.ir"
        secret.write_text((FIXTURES / "TVs" / "Acme" / "Acme_Hotel.ir").read_text())
        try:
            os.symlink(secret, db / "TVs" / "Acme" / "Acme_Link.ir")
            os.symlink(self.tmp, db / "TVs" / "Loop")
        except OSError:
            self.skipTest("symlinks not supported")
        report = imp.run_import(db, self.tmp / "out", commit=COMMIT, contrib=None)
        self.assertEqual(report["skipped_files"].get("file: symlink or special file"), 1)
        index = load(self.tmp / "out" / "index.json")
        self.assertNotIn("loop", [b["id"] for b in index["brands"]])

    def test_contrib_folder(self):
        contrib = self.tmp / "contrib"
        (contrib / "TVs" / "Acme").mkdir(parents=True)
        shutil.copy(FIXTURES / "TVs" / "Acme" / "Acme_Hotel.ir", contrib / "TVs" / "Acme" / "Acme_Hotel2.ir")
        run(self.tmp / "out", contrib=contrib)
        _, profiles, _ = validate_profiles_dir(self, self.tmp / "out")
        hotel = next(p for p in profiles if "TVs/Acme/Acme_Hotel.ir" in p["source"])
        self.assertEqual(hotel["source"], ["TVs/Acme/Acme_Hotel.ir", "contrib/TVs/Acme/Acme_Hotel2.ir"])
        self.assertEqual(hotel["weight"], 2)

    def test_commit_from_git_metadata(self):
        repo = self.tmp / "repo"
        (repo / ".git" / "refs" / "heads").mkdir(parents=True)
        (repo / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
        self.assertIsNone(imp.read_git_commit(repo))
        (repo / ".git" / "packed-refs").write_text(f"# pack-refs\n{COMMIT} refs/heads/main\n")
        self.assertEqual(imp.read_git_commit(repo), COMMIT)
        (repo / ".git" / "HEAD").write_text("ref: refs/../../etc/passwd\n")
        self.assertIsNone(imp.read_git_commit(repo))
        (repo / ".git" / "HEAD").write_text(COMMIT.replace("0", "f") + "\n")
        self.assertEqual(imp.read_git_commit(repo), COMMIT.replace("0", "f"))

    def test_missing_commit_or_license_fails(self):
        with self.assertRaises(SystemExit):
            imp.run_import(FIXTURES, self.tmp / "out", commit=None, contrib=None)
        db = self.tmp / "db"
        shutil.copytree(FIXTURES, db)
        (db / "LICENSE").write_text("All rights reserved\n")
        with self.assertRaises(SystemExit):
            imp.run_import(db, self.tmp / "out2", commit=COMMIT, contrib=None)
        self.assertFalse((self.tmp / "out2").exists())

    def test_output_and_url_checks(self):
        db = self.tmp / "db"
        shutil.copytree(FIXTURES, db)
        with self.assertRaises(SystemExit):
            imp.run_import(db, db / "profiles", commit=COMMIT, contrib=None)
        with self.assertRaises(SystemExit):
            run(self.tmp / "out", url="https://example.com/x; rm -rf ~")
        with self.assertRaises(SystemExit):
            run(self.tmp / "out", url="https://example.com/x\n")
        os.symlink(self.tmp, self.tmp / "link")
        with self.assertRaises(SystemExit):
            run(self.tmp / "link")

    def test_hostile_files_are_skipped_not_fatal(self):
        db = self.tmp / "db"
        shutil.copytree(FIXTURES, db)
        head = "Filetype: IR signals file\nVersion: 1\n"
        (db / "TVs" / "Acme" / "Acme_Inf.ir").write_text(
            head + "name: Power\ntype: raw\nfrequency: 38000\nduty_cycle: inf\ndata: 500 500 500\n")
        (db / "TVs" / "Acme" / "Acme_\u202eevil.ir").write_text(head + "name: Power\ntype: parsed\nprotocol: NEC\n"
                                                                "address: 04 00 00 00\ncommand: 01 00 00 00\n")
        many = "".join(f"name: B{i}\ntype: parsed\nprotocol: NECext\naddress: 04 00 00 00\n"
                       f"command: {i & 0xFF:02X} {i >> 8:02X} 00 00\n" for i in range(300))
        (db / "TVs" / "Acme" / "Acme_Many.ir").write_text(head + many)
        deep = db / "TVs" / "Deep"
        for i in range(10):
            deep = deep / f"d{i}"
        deep.mkdir(parents=True)
        (deep / "x.ir").write_text(head + "name: Power\ntype: parsed\nprotocol: NEC\n"
                                          "address: 05 00 00 00\ncommand: 01 00 00 00\n")
        report = imp.run_import(db, self.tmp / "out", commit=COMMIT, contrib=None)
        self.assertEqual(report["skipped_codes"].get("raw: malformed number"), 2)  # fixture junk + inf
        self.assertEqual(report["skipped_files"].get("file: unsafe file name"), 1)
        self.assertEqual(report["skipped_files"].get("file: folder nested too deep"), 1)
        self.assertEqual(report["skipped_codes"].get("block: more than 256 buttons in one file"), 44)
        _, profiles, _ = validate_profiles_dir(self, self.tmp / "out")
        many_profile = next(p for p in profiles if p["source"] == ["TVs/Acme/Acme_Many.ir"])
        self.assertEqual(len(many_profile["extra"]), 256)
        self.assertFalse(any("\u202e" in s for p in profiles for s in p["source"]))

    def test_git_metadata_must_be_regular_files(self):
        repo = self.tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        if not hasattr(os, "mkfifo"):
            self.skipTest("no FIFOs")
        os.mkfifo(repo / ".git" / "HEAD")
        self.assertIsNone(imp.read_git_commit(repo))


class RepositoryProfilesTests(unittest.TestCase):
    def test_profiles_match_schema(self):
        if not (PROFILES / "index.json").exists():
            self.skipTest("profiles/ not generated")
        index, profiles, scan = validate_profiles_dir(self, PROFILES)
        self.assertEqual(index["source"]["db"], "Flipper-IRDB")
        self.assertTrue((PROFILES / "SCHEMA.md").exists())
        size = sum(p.stat().st_size for p in PROFILES.rglob("*") if p.is_file())
        self.assertLess(size, 3_000_000)

    def test_profiles_are_reproducible(self):
        irdb = os.environ.get("OPENPULT_IRDB")
        if not irdb:
            self.skipTest("set OPENPULT_IRDB to a Flipper-IRDB checkout to compare")
        if not (PROFILES / "index.json").exists():
            self.skipTest("profiles/ not generated")
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="openpult-profiles-"))
        try:
            commit = load(PROFILES / "index.json")["source"]["commit"]
            imp.run_import(irdb, tmp, commit=commit)
            hand_written = {"SCHEMA.md", "SOURCES.md"}
            expected = {k: v for k, v in tree_bytes(PROFILES).items() if k not in hand_written}
            self.assertEqual(tree_bytes(tmp), expected)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
