#!/usr/bin/env python3
"""Generate the test data that keeps the Swift importer (app/BraviaKit/Sources/PultProfiles) byte-for-byte in step
with import_flipper_irdb.py, the reference implementation.

Writes
- tools/profiles/fixtures/expected/: index.json, brands/*.json and power_scan.json of the fixture import;
- tools/profiles/fixtures/expected-report.json: the report of that import (without sizes);
- testdata/profile_import_vectors.json: inputs and outputs of the importer's functions and of whole imports of
  small random trees, from a fixed seed.

Usage:
    python3 -I tools/profiles/gen_import_vectors.py            # rewrite the files
    python3 -I tools/profiles/gen_import_vectors.py --check    # exit 1 if any file is out of date (CI)

Standard library only. Random choices use nothing but random.Random(SEED).random(), whose sequence Python keeps
stable across versions, and the strings use characters assigned long ago, so other Python versions give the same
files. Every value is synthetic.
"""
import argparse
import base64
import importlib.util
import json
import os
import pathlib
import random
import shutil
import sys
import tempfile
import unicodedata

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FIXTURES = HERE / "fixtures" / "irdb"
EXPECTED = HERE / "fixtures" / "expected"
EXPECTED_REPORT = HERE / "fixtures" / "expected-report.json"
VECTORS = ROOT / "testdata" / "profile_import_vectors.json"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
SEED = 20261118

_spec = importlib.util.spec_from_file_location("import_flipper_irdb", HERE / "import_flipper_irdb.py")
imp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(imp)
ALIASES = imp.Aliases.load(imp.DEFAULT_ALIASES)
with open(imp.DEFAULT_ALIASES, encoding="utf-8") as _fh:
    ALIAS_DATA = json.load(_fh)

REPORT_FIELDS = ["files_seen", "files_used", "brands", "profiles", "buttons_in", "codes_out", "duplicates_dropped",
                 "skipped_files", "skipped_codes", "recovered", "skip_examples", "protocols", "power_scan_codes",
                 "top_brands", "name_stats"]


# --------------------------------------------------------------------------------------------------------------
# Importer runs


def import_outputs(irdb, contrib=None, **kwargs):
    """Run the Python importer; returns ({relative path: bytes} of the generated files, report subset)."""
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="openpult-vectors-"))
    try:
        out = tmp / "out"
        report = imp.run_import(irdb, out, contrib=contrib, **kwargs)
        files = {"index.json": (out / "index.json").read_bytes(),
                 "power_scan.json": (out / "power_scan.json").read_bytes()}
        for path in sorted((out / "brands").glob("*.json")):
            files[f"brands/{path.name}"] = path.read_bytes()
        subset = {k: report[k] for k in REPORT_FIELDS}
        subset["protocols"] = [[k, v] for k, v in report["protocols"].items()]
        return files, json.loads(json.dumps(subset))
    finally:
        shutil.rmtree(tmp)


def golden():
    return import_outputs(FIXTURES, commit=COMMIT)


# --------------------------------------------------------------------------------------------------------------
# Random inputs


class Rng:
    def __init__(self, seed):
        self._r = random.Random(seed)

    def f(self):
        return self._r.random()

    def below(self, n):
        return min(int(self._r.random() * n), n - 1)

    def between(self, lo, hi):
        return lo + self.below(hi - lo + 1)

    def pick(self, seq):
        return seq[self.below(len(seq))]

    def chance(self, p):
        return self._r.random() < p

    def mostly(self, good, bad, p=0.85):
        """A value from `good` with probability p, else one from `bad`."""
        return self.pick(good) if self.chance(p) else self.pick(bad)


LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
SEPARATORS = list(" _-./+|(),:#'\"\\&*")
SPACES = [chr(c) for c in (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x20, 0x20, 0x85, 0xA0,
                           0x1680, 0x2000, 0x2005, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000)]
# Control, format, private-use and unassigned code points (unicodedata category C*).
OTHER = ["\x00", "\x01", "\x07", "\x1b", "\x7f", "\x80", "\x9f", "\u00ad", "\u200b", "\u200c", "\u200d", "\u200e",
         "\u200f", "\u202a", "\u202e", "\u2060", "\ufeff", "\ue000", "\uf8ff", "\U000f0000", "\u0378", "\ufdd0",
         "\uffff", "\U0010ffff"]
# Assigned long ago: case mappings, decompositions and categories are the same in every recent Unicode version.
EXOTIC = (list("éÉßñÖöÿŸ\u00b5\u00aa\u00ba²³¹¼½¾©®°×÷\u0130\u0131ŁłŒœ\u017f\u01c5\u01c4\u03a3σςΑΩάΐ\u0345ТВтвЁёЖ中文あ")
          + ["\u0301", "\u0308", "\u0327", "\u0307", "\ufb01", "\ufb00", "\u2167", "\u2460", "\u338f", "\uff21",
             "\uff42", "\uff10", "\uff76", "\u2122", "\u212a", "\u212b", "\u2126", "\u2103", "한", "\U0001f600",
             "\U0001f44d", "\ufe0f", "\u1e9e", "\ufffd", "\u0663", "\u0969", "\u2044", "\u037e", "\u1fef", "\u03a3",
             "\u03a3", "\u03a3", "\u2024"])


def rand_char(rng, weights=(0.45, 0.17, 0.10, 0.08)):
    x = rng.f()
    letters, seps, spaces, other = weights
    if x < letters:
        return rng.pick(LETTERS)
    if x < letters + seps:
        return rng.pick(SEPARATORS)
    if x < letters + seps + spaces:
        return rng.pick(SPACES)
    if x < letters + seps + spaces + other:
        return rng.pick(OTHER)
    return rng.pick(EXOTIC)


def rand_text(rng, max_len, **kwargs):
    return "".join(rand_char(rng, **kwargs) for _ in range(rng.below(max_len + 1)))


def mutate(rng, name):
    """A spelling of a (normalized) alias as found in files: random case, separators, padding."""
    out = []
    for ch in name:
        out.append(ch.upper() if rng.chance(0.35) else ch)
        if rng.chance(0.08):
            out.append(rng.pick(["_", " ", "\u00a0", "-", "  ", "\t"]))
    s = "".join(out)
    if rng.chance(0.1):
        s = rng.pick([" ", "_", "\u3000"]) + s
    if rng.chance(0.1):
        s += rng.pick([" ", "_", "-", "\u00a0"])
    return s


ALIAS_NAMES = [n for k in ALIAS_DATA["keys"] for n in ALIAS_DATA["keys"][k]]
LETTER_NAMES = sorted({k for g in ALIAS_DATA.get("letterColors", []) for k in g})
EXTRA_NAMES = list(ALIAS_DATA.get("extraNames", []))


def rand_button_name(rng):
    x = rng.f()
    if x < 0.5:
        return mutate(rng, rng.pick(ALIAS_NAMES))
    if x < 0.6:
        return mutate(rng, rng.pick(LETTER_NAMES))
    if x < 0.7:
        return f"{mutate(rng, rng.pick(ALIAS_NAMES))}{rng.pick(['_|_', '|', ' | ', '||'])}" \
               f"{mutate(rng, rng.pick(ALIAS_NAMES + LETTER_NAMES))}"
    if x < 0.8:
        return mutate(rng, rng.pick(EXTRA_NAMES))
    return rand_text(rng, 14)


# Raw recordings


def bits_frame(rng, lead, mark, zero, one, nbits, gap):
    out = list(lead)
    for _ in range(nbits):
        out += [mark, one if rng.chance(0.5) else zero]
    return out + [mark, gap]


def template_frame(rng):
    kind = rng.below(6)
    if kind == 0:
        return bits_frame(rng, [9000, 4500], 560, 560, 1690, rng.pick([8, 16, 32]), rng.pick([40000, 30000, 96000]))
    if kind == 1:   # SIRC: the bits are in the marks
        out = [2400, 600]
        for _ in range(rng.pick([12, 15, 20])):
            out += [rng.pick([600, 1200]), 600]
        out[-1] = rng.pick([25800, 21000, 45000])
        return out
    if kind == 2:
        return bits_frame(rng, [3488, 1744], 436, 436, 1308, rng.pick([16, 24, 48]), rng.pick([74000, 30000]))
    if kind == 3:
        return bits_frame(rng, [], 300, 800, 1800, rng.pick([8, 15]), 45000)
    if kind == 4:   # random clusters, sometimes exactly +-5 % around a centre
        if rng.chance(0.5):
            c = 20 * rng.between(10, 400)
            values = [c - c // 20, c + c // 20, c - c // 20 - 1, c + c // 20 + 1, 500]
        else:
            values = [rng.between(50, 3000) for _ in range(rng.between(2, 10))]
        out = [rng.pick(values) for _ in range(2 * rng.between(1, 12))]
        out[-1] = rng.pick([25000, 30000, 20001, 20000, 19999])
        return out
    values = [rng.between(1, 600000) for _ in range(rng.between(1, 20))]
    return [rng.pick(values) for _ in range(rng.between(1, 40))]


def jitter(rng, frame, amount):
    if amount == 0:
        return list(frame)
    return [max(1, int(round(v * (1 + (rng.f() - 0.5) * 2 * amount)))) for v in frame]


def rand_recording(rng):
    a = template_frame(rng)
    b = template_frame(rng) if rng.chance(0.4) else [9000, 2250, 560, 96000]
    c = template_frame(rng)
    pattern = rng.pick(["A", "AA", "AAA", "AAAA", "AB", "ABB", "ABBB", "ABAB", "ABABA", "ABAC", "ABC", "AAAf", "Af",
                        "ABf", "ABBf", "ABABf", "noise", "lone"])
    if rng.chance(0.015):
        pattern = "many"
    amount = rng.pick([0, 0, 0.01, 0.03, 0.05, 0.08, 0.3])
    if pattern == "noise":
        data = [v for _ in range(rng.between(1, 4)) for v in (rng.between(1, 400), rng.between(20001, 90000))]
    elif pattern == "lone":
        data = a + [v for _ in range(rng.between(1, 3)) for v in (rng.between(100, 300), rng.between(20001, 90000))]
    elif pattern == "many":
        data = (a * rng.between(20, 80))[:rng.pick([1023, 1024, 1025, 2000, 4096, 4097])]
    else:
        frames = {"A": a, "B": b, "C": c}
        data = []
        for p in pattern:
            if p == "f":
                data += data_prefix(rng, a)
            else:
                data += jitter(rng, frames[p], amount)
    x = rng.f()
    if x < 0.3 and data:
        data = data[:-1]                               # ends with a mark
    elif x < 0.4 and data:
        data[-1] = rng.between(1, 20000)               # cut off inside a frame
    if rng.chance(0.06) and data:
        data[rng.below(len(data))] = rng.pick([0, -5, 600000, 31000, 500001, 49, 50, 30001])
    if rng.chance(0.03):
        data = []
    return data


def data_prefix(rng, frame):
    return list(frame[:rng.between(1, max(1, len(frame) - 1))])


DUTIES = [0.33, 0.330000, 0.5, 0.25, 0.125, 0.375, 0.505, 0.345, 0.105, 0.115, 0.095, 0.1, 10.0, 32.5, 33.5,
          49.5, 0.4999999999, 33.0]
BAD_DUTIES = [0.09, 0.0, 1.0, 1.5, 2.5, 50.5, 0.6, 0.515]
FREQUENCIES = [38000, 38000, 36000, 40000, 56000, 20000, 65535, 37900]
BAD_FREQUENCIES = [19999, 65536, 455000, 0, -38000]


# .ir text


def hex_bytes(value, n=4):
    return " ".join(f"{(value >> (8 * i)) & 0xFF:02X}" for i in range(n))


def rand_hex_field(rng, bits):
    x = rng.f()
    if x < 0.85:
        return hex_bytes(rng.below(1 << bits))
    if x < 0.9:
        return hex_bytes(rng.below(1 << 32))                     # usually too wide
    return rng.pick(["ZZ 00 00 00", "04 00", "04 00 00 00 00", "0a 0b 0c 0d", "4 0 0 0", "04\u00a000 00 00",
                     "04\t00  00 00", "\uff10４ 00 00 00", "04 00 00 0", "", "-1 00 00 00", "04-00-00-00"])


def valid_block(rng):
    lines = ["#", f"name: {rand_button_name(rng)}"]
    if rng.chance(0.75):
        proto, (abits, cbits) = rng.pick(list(imp.PROTOCOLS.items()))
        return lines + ["type: parsed", f"protocol: {proto}", f"address: {hex_bytes(rng.below(1 << abits))}",
                        f"command: {hex_bytes(rng.below(1 << cbits))}"]
    return lines + ["type: raw", "frequency: " + rng.pick(["38000", "36000", "40000"]),
                    "duty_cycle: " + rng.pick(["0.330000", "0.33", "0.25"]),
                    "data: " + " ".join(str(v) for v in rand_recording(rng))]


def rand_block(rng):
    if rng.chance(0.6):
        return valid_block(rng)
    lines = []
    if rng.chance(0.8):
        lines.append(rng.pick(["#", "# comment", "#", "  #x"]))
    name = rand_button_name(rng)
    lines.append(rng.mostly(["name: {}", "name:{}", "  name :  {}  "], ["Name: {}", "name {}"]).format(name))
    kind = rng.f()
    fields = []
    if kind < 0.5:
        proto, abits, cbits = rng.mostly([(k, a, c) for k, (a, c) in imp.PROTOCOLS.items()],
                                         [("Foo", 8, 8), ("\u212aaseikyo", 26, 10), ("nec", 8, 8)], 0.9)
        if rng.chance(0.9):
            fields.append("type: parsed")
        if rng.chance(0.95):
            fields.append(f"protocol: {proto}")
        if rng.chance(0.95):
            fields.append(f"address: {rand_hex_field(rng, abits)}")
        if rng.chance(0.95):
            fields.append(f"command: {rand_hex_field(rng, cbits)}")
    elif kind < 0.85:
        if rng.chance(0.9):
            fields.append("type: raw")
        if rng.chance(0.95):
            fields.append("frequency: " + rng.mostly(["38000", "36000", "40000", "56000", "0380000", "37900"],
                                                      ["15000", "38k", "-38000", "1234567890", "38000.0",
                                                       "\u0663\u0668000"]))
        if rng.chance(0.95):
            fields.append("duty_cycle: " + rng.mostly(["0.33", "0.330000", "0.5", "0.125", "0.505", "33.5", "1",
                                                       "0.345", "0.1234567891", "1.0"],
                                                      [".5", "inf", "-0.33", "0.6", "1e-1", "0,33", "1234567.0",
                                                       "0.12345678912"]))
        data = [str(v) for v in rand_recording(rng)]
        if rng.chance(0.05) and data:
            data[rng.below(len(data))] = rng.pick(["1e5", "+5", "\u0663", "5_0", "0x10", "1234567890", "-0"])
        if rng.chance(0.3) and len(data) > 4:
            cut = rng.below(len(data))
            fields.append("data: " + " ".join(data[:cut]))
            fields.append("data: " + " ".join(data[cut:]))
        elif rng.chance(0.97):
            fields.append("data: " + rng.pick([" ", "  ", "\t"]).join(data))
    elif kind < 0.92:
        fields.append(rng.pick(["type: pulse", "type:", "type: Parsed", "type: raw ", "protocol: NEC"]))
    if rng.chance(0.1) and fields:
        fields.append(rng.pick(fields).replace(": ", ": x"))   # a repeated field: the first one counts
    order = list(range(len(fields)))
    for i in range(len(order) - 1, 0, -1):
        if rng.chance(0.15):
            j = rng.below(i + 1)
            order[i], order[j] = order[j], order[i]
    lines += [fields[i] for i in order]
    if rng.chance(0.1):
        lines.insert(rng.below(len(lines) + 1), rng.pick(["random garbage", "", "   ", ":", "data:", "#name: x",
                                                          "frequency: 38000", "\u2028"]))
    return lines


def rand_ir_text(rng, max_blocks=8):
    header = rng.below(30)
    if header < 25:
        lines = ["Filetype: IR signals file", "Version: 1"]
    elif header == 25:
        lines = ["# leading comment", "", "  Filetype: IR signals file  ", "Version: 1"]
    elif header == 26:
        lines = ["Filetype: IR signal file", "Version: 1"]
    elif header == 27:
        lines = ["\ufeffFiletype: IR signals file", "Version: 1"]
    elif header == 28:
        lines = ["#", "#", "#", "#", "Filetype: IR signals file"]
    else:
        lines = ["Version: 1", "Filetype: IR signals file"]
    for _ in range(rng.below(max_blocks + 1)):
        lines += rand_block(rng)
    x = rng.f()
    if x < 0.6:
        seps = ["\n"]
    elif x < 0.75:
        seps = ["\r\n"]
    elif x < 0.8:
        seps = ["\r"]
    else:
        seps = ["\n", "\r\n", "\r", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"]
    out = ""
    for line in lines:
        out += line + rng.pick(seps)
    if rng.chance(0.2):
        out = out.rstrip("\n")
    return out


# Names


BRAND_WORDS = ["Acme", "ACME", "acme", "Zenco", "Nova", "Nova Tek", "nova-tek", "Ölmann", "Olmann", "\ufb01zeo",
               "Vega-Lumen", "TV", "星雲", "Brisa", "QX", "Hi_Fi", "K\u212aelvin", "Cafe\u0301", "Café", "X",
               "_", "-", "Brand.Name", "Brand (2)", "  Spaced  ", "\u03a3Α\u03a3"]
MODEL_TOKENS = ["AB-1000", "ab-1000", "43QX720Z", "QB71-03348K", "RC-ZK042", "1080p", "720I", "4k", "4KUHD",
                "55inch", "32in", "v2", "V10", "VLT-50Q", "X1", "XY", "x12", "AB12", "a1b2", "A.B.C1", "1-2-3",
                "+AB-1", "AB-1+", "./AB12", "AB12/", "Ab-10", "ZX-" + "0" * 29, "ZX-" + "0" * 30, "ÖL-55", "\uff21Ｂ12",
                "B\u0130-12", "AB-12\n", "A\u212a-12", "LUMA55X42QB", "X4", "Hotel", "Home2", "remote", "IR", "tv",
                "Tv", "TV", "Smart", "(old)", "(2019)", "(QX_LUMA X4 models)", "(a", "b)", "(x\ny)"]


def rand_model_token(rng):
    if rng.chance(0.6):
        return rng.pick(MODEL_TOKENS)
    parts = []
    for _ in range(rng.between(1, 4)):
        parts.append("".join(rng.pick(LETTERS) for _ in range(rng.between(1, 5))))
    token = rng.pick(["-", ".", "/", "+", ""]).join(parts)
    if rng.chance(0.2):
        token += rand_char(rng)
    return token


def rand_rel(rng):
    brand = rng.pick(BRAND_WORDS)
    tokens = [rand_model_token(rng) for _ in range(rng.below(6))]
    if rng.chance(0.6):
        tokens.insert(0, brand if rng.chance(0.7) else rng.pick(BRAND_WORDS))
    sep = rng.pick(["_", " ", "_", ",", ", ", "__", "\u00a0"])
    stem = sep.join(tokens)
    ext = rng.pick([".ir", ".ir", ".IR", ".Ir", "", ".txt", ".ir.ir"])
    if rng.chance(0.65):
        return f"{brand}/{stem}{ext}", brand
    return f"{stem}{ext}", brand


# --------------------------------------------------------------------------------------------------------------
# Vectors


def cmd_json(cmd):
    return json.loads(json.dumps(cmd))


def vec_strings(rng):
    out = {"normalize_name": [], "clean_text": [], "slugify": [], "brand_of": [], "looks_like_model": [],
           "file_label": [], "profile_name": []}
    for i in range(400):
        s = rand_button_name(rng) if i % 2 else rand_text(rng, 16)
        out["normalize_name"].append({"in": s, "out": imp.normalize_name(s)})
    for _ in range(400):
        s = rand_text(rng, 60, weights=(0.35, 0.1, 0.25, 0.15))
        limit = rng.pick([40, 40, 48, 300, 0, 1, 5])
        out["clean_text"].append({"in": s, "limit": limit, "out": imp.clean_text(s, limit)})
    for i in range(300):
        s = rng.pick(BRAND_WORDS) if i % 3 == 0 else rand_text(rng, 20)
        out["slugify"].append({"in": s, "out": imp.slugify(s)})
    for _ in range(300):
        rel, _ = rand_rel(rng)
        if rng.chance(0.2):
            rel = rand_text(rng, 30)
        out["brand_of"].append({"in": rel, "out": imp.brand_of(rel)})
    for _ in range(400):
        t = rand_model_token(rng) if rng.chance(0.8) else rand_text(rng, 12)
        out["looks_like_model"].append({"in": t, "out": imp.looks_like_model(t)})
    for _ in range(400):
        rel, brand = rand_rel(rng)
        if rng.chance(0.15):
            brand = rand_text(rng, 12)
        models, label = imp.file_label(rel, brand)
        out["file_label"].append({"rel": rel, "brand": brand, "models": models, "label": label})
    for _ in range(200):
        brand = imp.clean_text(rng.pick(BRAND_WORDS) if rng.chance(0.7) else rand_text(rng, 50))
        models = [imp.clean_text(rand_model_token(rng), 32) for _ in range(rng.pick([0, 0, 1, 2, 3, 4, 7]))]
        if rng.chance(0.3):
            models = ["ZX-" + "%029d" % rng.below(10 ** 9) for _ in range(rng.between(1, 5))]
        label = imp.clean_text(rand_text(rng, 60), 48) if rng.chance(0.6) else ""
        out["profile_name"].append({"brand": brand, "models": models, "label": label,
                                    "out": imp.profile_name(brand, models, label)})
    return out


def vec_raw(rng):
    out = []
    for _ in range(280):
        data = rand_recording(rng)
        f = rng.mostly(FREQUENCIES, BAD_FREQUENCIES, 0.92)
        d = rng.mostly(DUTIES, BAD_DUTIES, 0.9)
        cmd, reason = imp.normalize_raw(f, d, data)
        out.append({"f": f, "duty": d, "data": data, "cmd": cmd_json(cmd), "reason": reason})
    return out


def vec_parse(rng):
    out = []
    for _ in range(150):
        text = rand_ir_text(rng, max_blocks=6)
        buttons, errors = imp.parse_ir_text(text)
        out.append({"text": text, "buttons": [[n, c] for n, c in buttons],
                    "errors": dict(sorted(errors.items()))})
    return out


CMD_POOL = ([{"p": "NEC", "a": 4, "c": c} for c in range(10)]
            + [{"p": "Samsung32", "a": 7, "c": 2}, {"p": "RC5", "a": 0, "c": 12},
               {"raw": {"f": 38000, "d": 33, "i": [], "r": [500, 500, 1000, 25000]}},
               {"raw": {"f": 38000, "d": 33, "i": [9000, 4500, 560, 40000], "r": [9000, 2250, 560, 96000]}}])


def vec_map(rng):
    out = []
    for _ in range(140):
        buttons = [(rand_button_name(rng), rng.pick(CMD_POOL)) for _ in range(rng.below(22))]
        if rng.chance(0.2):
            group = rng.pick(ALIAS_DATA["letterColors"])
            buttons += [(mutate(rng, k), rng.pick(CMD_POOL)) for k in group]
        keys, extra, dropped = imp.map_buttons(buttons, ALIASES)
        out.append({"buttons": [[n, c] for n, c in buttons], "keys": [[k, c] for k, c in keys.items()],
                    "extra": [[e["name"], e["cmd"]] for e in extra], "dropped": dropped})
    return out


SOURCE_NAMES = ["a", "B", "\u00e9", "e\u0301", "Z"]
LABELS = ["Hotel", "Hotel", "Café", "Cafe\u0301", "K\u212a", "KK", "", "", "Smart", "x" * 48]
MODELS = ["AB-1000", "ab-1000", "AB-2000", "Ab-1000", "VLT-50Q", "vlt-50q", "X12", "ZX-" + "9" * 29]


def vec_build(rng):
    out = []
    keys_pool = ["power", "volumeUp", "volumeDown", "mute", "confirm", "red"]
    for n in range(50):
        brand = rng.pick(["Acme", "Ölmann", "Nova Tek", "x" * 40, "\u03a3Α\u03a3"])
        files = []
        for i in range(rng.between(1, 7)):
            keys = {}
            for k in ALIASES.key_order:
                if k in keys_pool and rng.chance(0.4):
                    keys[k] = rng.pick(CMD_POOL[:4])
            extra = [{"name": rng.pick(["Netflix", "Sleep", "Ölmann", "Info"]), "cmd": rng.pick(CMD_POOL[4:8])}
                     for _ in range(rng.below(3))]
            models = []
            for _ in range(rng.pick([0, 0, 1, 2, 4])):
                m = rng.pick(MODELS)
                if m not in models:
                    models.append(m)
            source = rng.pick(["TVs/", "contrib/TVs/"]) + f"{brand}/{rng.pick(SOURCE_NAMES)}{i}.ir"
            files.append({"source": source, "keys": keys, "extra": extra, "models": models,
                          "label": rng.pick(LABELS)})
        if len({f["source"] for f in files}) != len(files):
            continue
        brand_id = imp.slugify(brand) or "x"
        text = imp.format_profiles(imp.build_profiles(brand_id, brand, files, ALIASES.key_order))
        out.append({"brand_id": brand_id, "brand": brand,
                    "files": [{"source": f["source"], "keys": [[k, c] for k, c in f["keys"].items()],
                               "extra": [[e["name"], e["cmd"]] for e in f["extra"]], "models": f["models"],
                               "label": f["label"]} for f in files],
                    "out": text})
    return out


# Whole imports of small random trees.

TREE_DIRS = ["Acme", "Zenco", "Nova", "Nova Tek", "nova-tek", "Ölmann", "\ufb01zeo", "星雲", "Brisa", "QX", "x",
             ".hidden", "Deep", "Spaced Name", "Brand.Name", "-dash", "_under", "K\u212aelvin", "Évian",
             "\u202eevil", "a\u200bb", "tab\there", "\x01ctl"]
TREE_FILES = ["Acme_AB-1000.ir", "Acme_AB-2000.ir", "Hotel.ir", "Nova_NV-2.IR", "nova_NV-1.ir", "Remote",
              "x.ir", "notes.txt", ".hidden.ir", "_nameless.ir", "QX_Hotel_TV_Home2.ir", "Brisa (old).ir",
              "Zenco ZX-9.ir", "Ölmann_ÖL-55 (Küche).ir", "\u202eevil.ir", "zero\u200bwidth.ir", "bell\x07.ir",
              "nl\nnl.ir", "Café TV.ir", "\ufb01zeo_FZ-32.ir", "星雲_X1.ir", "a" * 120 + ".ir", "B" * 90 + "_" + "C" * 90]


def fold(name):
    return unicodedata.normalize("NFC", name).casefold()


def rand_tree(rng):
    """[(path, bytes)] with unique names per folder even on case- and normalization-insensitive file systems."""
    files = []
    taken = {}
    for _ in range(rng.between(1, 12)):
        depth = rng.pick([0, 1, 1, 1, 1, 2, 2, 3, 7, 8, 9])
        parts = [rng.pick(TREE_DIRS) for _ in range(depth)]
        if depth >= 7:
            parts = [rng.pick(TREE_DIRS[:5]) for _ in range(depth)]
        name = rng.pick(TREE_FILES) if rng.chance(0.8) else rand_rel(rng)[0].replace("/", "_")
        if not name or name in (".", ".."):
            continue
        # File systems refuse NUL and unassigned code points in names.
        name = "".join("?" if ch == "\x00" or unicodedata.category(ch) == "Cn" else ch for ch in name)
        path = parts + [name]
        # A folded name stands for one entry: the same spelling and kind, and a file only once.
        entries = [(tuple(fold(p) for p in path[:level]), fold(path[level]),
                    ("dir" if level < len(path) - 1 else "file", path[level])) for level in range(len(path))]
        if any(key in taken.get(parent, {}) and (taken[parent][key] != value or value[0] == "file")
               for parent, key, value in entries):
            continue
        if len("/".join(path).encode()) > 900 or any(len(p.encode()) > 250 for p in path):
            continue
        for parent, key, value in entries:
            taken.setdefault(parent, {})[key] = value
        text = rand_ir_text(rng, max_blocks=5)
        if rng.chance(0.5):   # shared power codes: power_scan entries with several brands
            text += f"\n#\nname: Power\ntype: parsed\nprotocol: NEC\naddress: 04 00 00 00\ncommand: 0{rng.below(4)} 00 00 00\n"
        x = rng.f()
        if x < 0.1:
            data = b"\xef\xbb\xbf" + text.encode("utf-8")
        elif x < 0.15:
            data = text.encode("utf-8") + b"\n# \xff\xfe\xed\xa0\x80\xe2\x82\n"
        elif x < 0.2:
            raw = bytearray(text.encode("utf-8"))
            if raw:
                raw[rng.below(len(raw))] = rng.pick([0x80, 0xC0, 0xED, 0xF4, 0xFF])
            data = bytes(raw)
        else:
            data = text.encode("utf-8")
        files.append(("/".join(path), data))
    return files


def write_tree(root, files):
    for rel, data in files:
        path = root.joinpath(*rel.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def encode_file(rel, data):
    body = data.rstrip(b" ")
    if len(data) - len(body) > 4096:   # a large file: text padded with spaces to pad_to bytes
        return {"path": rel, "text": body.decode("utf-8"), "pad_to": len(data)}
    try:
        text = data.decode("utf-8")
        if not text.startswith("\ufeff"):
            return {"path": rel, "text": text}
    except UnicodeDecodeError:
        pass
    return {"path": rel, "base64": base64.b64encode(data).decode("ascii")}


README_NOTES = ["", "> Commits prior to [abc1234](https://example.invalid) are not covered.\n",
                "commits prior to `0123456789abcdef0123456789abcdef0123456789abcdef` ok\n",
                "Commits prior to [`abc12`] and Commits prior to deadbeef1 x\n", "\ufeffCommits prior to 1234567\n"]
URLS = ["https://github.com/Lucaslhm/Flipper-IRDB", "https://example.invalid/a/b.c-d_e", "https://x"]


def tree_vector(files, contrib, readme, note, url):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="openpult-tree-"))
    try:
        db = tmp / "db"
        (db / "TVs").mkdir(parents=True)
        (db / "LICENSE").write_text("Creative Commons Legal Code\n\nCC0 1.0 Universal\n", encoding="utf-8")
        (db / "README.md").write_text(readme, encoding="utf-8")
        write_tree(db / "TVs", files)
        contrib_dir = None
        if contrib:
            contrib_dir = tmp / "contrib"
            (contrib_dir / "TVs").mkdir(parents=True)
            write_tree(contrib_dir / "TVs", contrib)
        outputs, report = import_outputs(db, contrib=contrib_dir, commit=COMMIT, url=url, license_note=note)
    finally:
        shutil.rmtree(tmp)
    return {"files": [encode_file(p, d) for p, d in files], "contrib": [encode_file(p, d) for p, d in contrib],
            "readme": readme, "license_note": note, "url": url,
            "out": {k: v.decode("utf-8") for k, v in outputs.items()}, "report": report}


def vec_trees(rng):
    out = []
    for n in range(20):
        files = rand_tree(rng)
        contrib = rand_tree(rng) if rng.chance(0.25) else []
        readme = rng.pick(README_NOTES)
        note = rng.pick([None, None, None, "", "  A note\twith\x00 control  " + "x" * 300, "Ölmann \u202e note"])
        out.append(tree_vector(files, contrib, readme, note, rng.pick(URLS)))
    out.append(edge_tree())
    return out


# Fixed edge cases: the limits random inputs rarely reach.

HEAD = "Filetype: IR signals file\nVersion: 1\n"


def parsed_block(name, proto, address, command):
    return (f"#\nname: {name}\ntype: parsed\nprotocol: {proto}\naddress: {hex_bytes(address)}\n"
            f"command: {hex_bytes(command)}\n")


def many_buttons(n):
    return HEAD + "".join(parsed_block(f"B{i}", "NECext", 4, i) for i in range(n))


def raw_block(freq, lines):
    return (f"#\nname: Power\ntype: raw\nfrequency: {freq}\nduty_cycle: 0.33\n"
            + "".join("data: " + " ".join(str(v) for v in line) + "\n" for line in lines))


EDGE_RECORDINGS = [
    [500, 500, 500, 25000] * 64,                 # 64 frames: A A A ... -> one frame
    [500, 500, 500, 25000] * 65,                 # 65 frames: kept whole -> longer than 1 s
    [300, 600] * 2048,                           # 4096 durations
    [300, 600] * 2048 + [300],                   # 4097 durations
    [9000, 4500, 560, 20000, 9000, 4500, 560, 20001, 9000, 4500, 560, 19999],
    [9000, 4500, 560, 20001, 9000, 4500, 560, 20001, 9000, 4500, 560, 20001],
    [50, 500000, 30000, 500],
    [49, 500, 30000, 500],
    [30001, 500, 500],
    [500000, 500001],
]


def edge_raw():
    out = []
    for data in EDGE_RECORDINGS:
        for duty in ((0.33, 0.145, 0.505, 9.5, 10.5) if len(data) < 100 else (0.33,)):
            cmd, reason = imp.normalize_raw(38000, duty, data)
            out.append({"f": 38000, "duty": duty, "data": data, "cmd": cmd_json(cmd), "reason": reason})
    return out


def edge_parse():
    long = [300, 600] * 2048 + [300]
    texts = [many_buttons(256), many_buttons(257), many_buttons(300),
             HEAD + raw_block("38k", [long]),                       # too long is checked before the numbers
             HEAD + raw_block("38k", [long[:2000], long[2000:]]),
             HEAD + raw_block("38000", [long[:2000], long[2000:-1]]),
             HEAD + raw_block("38000", [long[:3000], long[3000:]])]
    out = []
    for text in texts:
        buttons, errors = imp.parse_ir_text(text)
        out.append({"text": text, "buttons": [[n, c] for n, c in buttons], "errors": dict(sorted(errors.items()))})
    return out


def edge_tree():
    def doc(*blocks):
        return (HEAD + "".join(blocks)).encode("utf-8")
    power = parsed_block("Power", "NEC", 4, 8)
    mute = parsed_block("Mute", "NEC", 4, 9)
    big = doc(parsed_block("Power", "NEC", 4, 10))
    files = [
        ("Acme/Acme_Hotel.ir", doc(parsed_block("Power", "NEC", 4, 1))),
        ("Acme/Acme_Hotel (old).ir", doc(parsed_block("Power", "NEC", 4, 2))),
        ("Acme/Acme_Hotel (2019).ir", doc(parsed_block("Power", "NEC", 4, 3))),
        ("Acme/Acme_A-10.ir", doc(power, mute)),
        ("Acme/Acme_a-11_AB-12.ir", doc(power, mute)),
        ("Acme/Acme_max.ir", big + b" " * ((1 << 20) - len(big))),
        ("Acme/Acme_big.ir", big + b" " * ((1 << 20) + 1 - len(big))),
        ("Acme/Acme_Many.ir", many_buttons(300).encode("utf-8")),
        ("Zenco/Zenco_Z-1.ir", doc(power)),
        ("acme_Z-2.ir", doc(power, parsed_block("Mute", "NEC", 4, 11))),
    ]
    contrib = [("Acme/Acme_A-13.ir", doc(power, mute))]
    return tree_vector(files, contrib, README_NOTES[1], None, URLS[0])


def vectors():
    rng = Rng(SEED)
    sections = {"comment": ["Generated by tools/profiles/gen_import_vectors.py from import_flipper_irdb.py; do not "
                            "edit by hand. Checked by PultProfilesTests (Swift) and test_import.py."],
                "seed": SEED}
    sections.update(vec_strings(rng))
    sections["normalize_raw"] = vec_raw(rng) + edge_raw()
    sections["parse_ir_text"] = vec_parse(rng) + edge_parse()
    sections["map_buttons"] = vec_map(rng)
    sections["build_profiles"] = vec_build(rng)
    sections["import_tree"] = vec_trees(rng)
    parts = []
    for name, value in sections.items():
        if isinstance(value, list) and value and isinstance(value[0], dict):
            rows = ",\n".join("  " + json.dumps(v, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
                              for v in value)
            parts.append(f" {json.dumps(name)}: [\n{rows}\n ]")
        else:
            parts.append(f" {json.dumps(name)}: {json.dumps(value, ensure_ascii=True)}")
    return "{\n" + ",\n".join(parts) + "\n}\n"


# --------------------------------------------------------------------------------------------------------------


def report_text(report):
    return json.dumps(report, ensure_ascii=True, indent=1) + "\n"


def expected_tree():
    files, report = golden()
    return files, report_text(report).encode("ascii")


def write_all():
    files, report = expected_tree()
    if EXPECTED.exists():
        shutil.rmtree(EXPECTED)
    (EXPECTED / "brands").mkdir(parents=True)
    for rel, data in files.items():
        (EXPECTED / rel).write_bytes(data)
    EXPECTED_REPORT.write_bytes(report)
    VECTORS.parent.mkdir(parents=True, exist_ok=True)
    VECTORS.write_bytes(vectors().encode("ascii"))


def stale():
    """Paths that differ from what the generator would write now."""
    files, report = expected_tree()
    bad = []
    present = {}
    if EXPECTED.is_dir():
        present = {p.relative_to(EXPECTED).as_posix(): p for p in EXPECTED.rglob("*")
                   if p.is_file() and not p.name.startswith(".")}   # e.g. .DS_Store
    for rel in sorted(set(files) | set(present)):
        if rel not in files or rel not in present or present[rel].read_bytes() != files[rel]:
            bad.append(str(EXPECTED / rel))
    if not EXPECTED_REPORT.is_file() or EXPECTED_REPORT.read_bytes() != report:
        bad.append(str(EXPECTED_REPORT))
    if not VECTORS.is_file() or VECTORS.read_bytes() != vectors().encode("ascii"):
        bad.append(str(VECTORS))
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="only check that the files are up to date")
    args = ap.parse_args(argv)
    if args.check:
        bad = stale()
        for path in bad:
            sys.stderr.write(f"out of date: {path}\n")
        if bad:
            sys.stderr.write("run: python3 -I tools/profiles/gen_import_vectors.py\n")
            return 1
        return 0
    write_all()
    return 0


if __name__ == "__main__":
    sys.exit(main())
