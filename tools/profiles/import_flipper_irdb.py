#!/usr/bin/env python3
"""Import TV remote codes from Flipper-IRDB into openpult profiles.

Usage:
    python3 -I tools/profiles/import_flipper_irdb.py --irdb <Flipper-IRDB checkout> --out profiles/

The Flipper-IRDB checkout is treated as untrusted data: it is only read, never executed. Symlinks are not
followed, oversized files are skipped and every malformed block is skipped and counted.

Output (see profiles/SCHEMA.md): index.json, brands/<brand-id>.json, power_scan.json and a copy of LICENSE.
profiles/SOURCES.md is written by hand and never touched. The output depends only on the input files, the aliases
and the arguments, so a re-import of the same commit is byte-identical.

The app builds the same files on the device with a Swift port of this script (app/BraviaKit/Sources/PultProfiles);
tools/profiles/gen_import_vectors.py keeps the two byte-for-byte in step.

Python 3.8+, standard library only.
"""
import argparse
import collections
import json
import math
import os
import pathlib
import re
import stat
import sys
import tempfile
import unicodedata

SCHEMA_VERSION = 1
DEFAULT_URL = "https://github.com/Lucaslhm/Flipper-IRDB"
DB_NAME = "Flipper-IRDB"
LICENSE_ID = "CC0-1.0"
HERE = pathlib.Path(__file__).resolve().parent
# The single copy of the aliases lives in the Swift package that ships them to the app.
DEFAULT_ALIASES = HERE.parent.parent / "app" / "BraviaKit" / "Sources" / "PultProfiles" / "Resources" / "key_aliases.json"
DEFAULT_CONTRIB = HERE / "contrib"
CONTRIB_PREFIX = "contrib/"

# Protocol v2 limits (firmware/PROTOCOL.md, "Signal blob").
CARRIER_MIN, CARRIER_MAX = 20000, 65535
DUTY_MIN, DUTY_MAX = 10, 50
SYMBOLS_MIN, SYMBOLS_MAX = 2, 1024
MARK_MAX_US = 30000
SECTION_MAX_US = 1_000_000
DURATION_MAX_US = 500000
TABLE_MAX = 16
BLOB_MAX = 576
BLOB_HEADER = 9

# Raw normalization.
FRAME_GAP_US = 20000        # a space longer than this separates frames
TAIL_GAP_US = 40000         # appended when a recording ends with a mark
CLUSTER_TOLERANCE = 0.05    # every duration stays within +-5 % of its cluster value
FRAME_MATCH_TOLERANCE = 0.25
FRAME_MATCH_MIN_US = 200    # first marks of a recording are often shortened by the receiver
DURATION_MIN_US = 50        # shorter than two carrier periods: receiver noise, not a signal
MAX_FRAMES = 64             # more frames than this cannot fit a 1 s section anyway (gaps > 20 ms)

# Input hygiene.
MAX_FILE_BYTES = 1 << 20
MAX_LICENSE_BYTES = 16 << 10
MAX_NAME_CHARS = 40
MAX_PATH_CHARS = 200
MAX_DEPTH = 8
MAX_BUTTONS_PER_FILE = 256
MAX_RAW_DURATIONS = 4096
URL_RE = re.compile(r"https://[A-Za-z0-9.-]+(/[A-Za-z0-9._-]+)*")  # used with fullmatch: no trailing "\n"

# Flipper Zero protocol table: name -> (address bits, command bits), as validated by the Flipper firmware.
PROTOCOLS = {
    "NEC": (8, 8),
    "NECext": (16, 16),
    "NEC42": (13, 8),
    "NEC42ext": (26, 16),
    "Samsung32": (8, 8),
    "RC5": (5, 6),
    "RC5X": (5, 7),
    "RC6": (8, 8),
    "SIRC": (5, 7),
    "SIRC15": (8, 7),
    "SIRC20": (13, 7),
    "Kaseikyo": (26, 10),
    "RCA": (4, 8),
    "Pioneer": (8, 8),
}

MODEL_RE = re.compile(r"^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9][A-Za-z0-9.\-/+]{2,31}$")
NOT_MODEL_RE = re.compile(r"^(\d{3,4}[pi]|[248]k(uhd)?|\d+(inch|in)|v\d+)$", re.IGNORECASE)
LABEL_STOPWORDS = {"tv", "remote", "ir"}


# --------------------------------------------------------------------------------------------------------------
# Names


def normalize_name(name):
    """Lowercase, drop whitespace and '_', drop '-' unless it is the last character."""
    s = re.sub(r"[\s_]+", "", name.lower())
    return re.sub(r"-(?=.)", "", s)


def clean_text(text, limit=MAX_NAME_CHARS):
    """Remove control/format characters (incl. bidi overrides), collapse whitespace, cap the length."""
    out = "".join(ch for ch in text if unicodedata.category(ch)[0] != "C")
    out = re.sub(r"\s+", " ", out).strip()
    return out[:limit].rstrip()


def slugify(name):
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


class Aliases:
    def __init__(self, data):
        keys = data.get("keys")
        if not isinstance(keys, dict) or not keys:
            raise ValueError("aliases: 'keys' must be a non-empty object")
        self.key_order = list(keys)
        self.by_key = {}
        for key, names in keys.items():
            if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
                raise ValueError(f"aliases: '{key}' must be a list of strings")
            normalized = [normalize_name(n) for n in names]
            if len(set(normalized)) != len(normalized):
                raise ValueError(f"aliases: duplicate alias under '{key}'")
            self.by_key[key] = normalized
        self.letter_groups = []
        for group in data.get("letterColors", []):
            norm = {normalize_name(k): v for k, v in group.items()}
            for target in norm.values():
                if target not in self.by_key:
                    raise ValueError(f"aliases: letterColors target '{target}' is not a key")
            self.letter_groups.append(norm)
        self.extra_names = {normalize_name(n) for n in data.get("extraNames", [])}
        self.known = set()
        for names in self.by_key.values():
            self.known.update(names)
        for group in self.letter_groups:
            self.known.update(group)

    @classmethod
    def load(cls, path):
        with open(path, encoding="utf-8") as fh:
            return cls(json.load(fh))


# --------------------------------------------------------------------------------------------------------------
# Raw signals


def cluster_map(values, tolerance=CLUSTER_TOLERANCE):
    """Map every duration to the count-weighted mean of its cluster; all members stay within +-tolerance."""
    counts = collections.Counter(values)

    def center(total, weighted):
        return (2 * weighted + total) // (2 * total)

    # Greedy over sorted values with running sums: linear time. The center lies between the smallest and the
    # largest member, so checking those two bounds every member.
    clusters = []  # [members, total count, weighted sum]
    for value in sorted(counts):
        if clusters:
            members, total, weighted = clusters[-1]
            t, w = total + counts[value], weighted + value * counts[value]
            c = center(t, w)
            if abs(members[0] - c) <= tolerance * c and abs(value - c) <= tolerance * c:
                members.append(value)
                clusters[-1][1:] = [t, w]
                continue
        clusters.append([[value], counts[value], value * counts[value]])
    mapping = {}
    for members, total, weighted in clusters:
        c = center(total, weighted)
        for v in members:
            mapping[v] = c
    return mapping


def split_frames(seq):
    """Split an even mark/space sequence after every space longer than FRAME_GAP_US."""
    frames, start = [], 0
    for i in range(1, len(seq), 2):
        if seq[i] > FRAME_GAP_US:
            frames.append(seq[start:i + 1])
            start = i + 1
    if start < len(seq):
        frames.append(seq[start:])
    return frames


def frames_match(a, b):
    """Same structure and timings within tolerance; the trailing gap is not compared."""
    if len(a) != len(b):
        return False
    for x, y in zip(a[:-1], b[:-1]):
        if abs(x - y) > max(FRAME_MATCH_MIN_US, FRAME_MATCH_TOLERANCE * max(x, y)):
            return False
    return True


def is_fragment(tail, prev):
    """A last frame cut off by the end of the recording: a shorter copy of the start of prev."""
    if len(tail) >= len(prev):
        return False
    return all(abs(x - y) <= max(FRAME_MATCH_MIN_US, FRAME_MATCH_TOLERANCE * max(x, y))
               for x, y in zip(tail[:-1], prev[:len(tail) - 1]))


def trim_tail(frames):
    """Drop trailing lone marks (when the recording has a real frame) and one cut-off last frame."""
    while len(frames) >= 2 and len(frames[-1]) == 2 and any(len(f) > 2 for f in frames[:-1]):
        frames = frames[:-1]
    if len(frames) >= 2 and is_fragment(frames[-1], frames[-2]):
        frames = frames[:-1]
    return frames


def raw_sections(seq):
    """(intro, repeat) for one recorded press; seq has even length and ends with a space.

    The recording is split into frames at long spaces. A cut-off last frame is dropped, then repeated frames
    are kept once:
    - A A A      -> repeat A
    - A B B, A B -> intro A, repeat B (e.g. NEC frame + repeat code)
    - A B A B    -> repeat A B (frame pairs such as Sharp's normal + inverted frame)
    - otherwise  -> the whole recording as the repeat section.
    The repeat keeps the recorded gap that follows it, so the repetition period stays as recorded.
    """
    frames = split_frames(seq)
    if len(frames) > MAX_FRAMES:
        return [], list(seq)
    frames = trim_tail(frames)
    if len(frames) == 1:
        return [], list(frames[0])
    for skip in (0, 1):
        body = frames[skip:]
        for period in range(1, len(body) + 1):
            if period > 1 and len(body) < 2 * period:
                break
            if all(frames_match(body[k], body[k % period]) for k in range(period, len(body))):
                intro = list(frames[0]) if skip else []
                return intro, [v for f in body[:period] for v in f]
    return [], [v for f in frames for v in f]


def leb128_len(value):
    n = 1
    while value >= 0x80:
        value >>= 7
        n += 1
    return n


def blob_size(intro, repeat):
    table = list(dict.fromkeys(intro + repeat))
    return (BLOB_HEADER + sum(leb128_len(v) for v in table)
            + (len(intro) + 1) // 2 + (len(repeat) + 1) // 2)


def check_sections(carrier, duty, intro, repeat):
    """Protocol v2 limits; returns a skip reason or None."""
    if not CARRIER_MIN <= carrier <= CARRIER_MAX:
        return "raw: carrier outside 20000..65535 Hz"
    if not DUTY_MIN <= duty <= DUTY_MAX:
        return "raw: duty cycle outside 10..50 %"
    n = len(intro) + len(repeat)
    if n < SYMBOLS_MIN:
        return "raw: fewer than 2 durations"
    if n > SYMBOLS_MAX:
        return "raw: more than 1024 durations"
    if len(intro) % 2 or len(repeat) % 2:
        return "raw: section with odd length"
    if any(m > MARK_MAX_US for m in intro[0::2] + repeat[0::2]):
        return "raw: mark longer than 30 ms"
    if any(not DURATION_MIN_US <= v <= DURATION_MAX_US for v in intro + repeat):
        return "raw: duration outside 50..500000 us"
    if sum(intro) > SECTION_MAX_US or sum(repeat) > SECTION_MAX_US:
        return "raw: section longer than 1 s"
    if len(set(intro + repeat)) > TABLE_MAX:
        return "raw: more than 16 distinct durations after clustering"
    if blob_size(intro, repeat) > BLOB_MAX:
        return "raw: blob larger than 576 bytes"
    return None


def normalize_raw(frequency, duty_cycle, data):
    """Flipper raw recording -> ({"raw": {...}}, None) or (None, reason)."""
    carrier = int(round(frequency))
    duty = int(round(duty_cycle * 100)) if duty_cycle <= 1 else int(round(duty_cycle))
    if not data:
        return None, "raw: empty data"
    if len(data) > MAX_RAW_DURATIONS:
        return None, "raw: recording longer than 4096 durations"
    if any(v <= 0 for v in data):
        return None, "raw: non-positive duration"
    seq = list(data)
    if len(seq) % 2:
        seq.append(TAIL_GAP_US)               # Flipper recordings end with a mark
    elif seq[-1] <= FRAME_GAP_US:
        seq[-1] = TAIL_GAP_US                 # cut off inside a frame: give the press its trailing gap
    if all(len(f) == 2 for f in split_frames(seq)):
        return None, "raw: isolated pulses only (noise)"
    intro, repeat = raw_sections(seq)
    mapping = cluster_map(intro + repeat)
    intro = [mapping[v] for v in intro]
    repeat = [mapping[v] for v in repeat]
    reason = check_sections(carrier, duty, intro, repeat)
    if reason:
        return None, reason
    return {"raw": {"f": carrier, "d": duty, "i": intro, "r": repeat}}, None


# --------------------------------------------------------------------------------------------------------------
# .ir parsing


def parse_hex_u32(text):
    parts = text.split()
    if len(parts) != 4 or not all(re.fullmatch(r"[0-9A-Fa-f]{2}", p) for p in parts):
        return None
    return int.from_bytes(bytes(int(p, 16) for p in parts), "little")


INT_RE = re.compile(r"-?[0-9]{1,9}")
FLOAT_RE = re.compile(r"[0-9]{1,6}(\.[0-9]{1,9})?")


def parse_number(text, kind):
    """Plain ASCII decimals only (no '_', '+', exponents or non-ASCII digits), bounded in size."""
    if not (INT_RE if kind is int else FLOAT_RE).fullmatch(text):
        return None
    value = kind(text)
    if kind is float and not math.isfinite(value):
        return None
    return value


def parse_ir_text(text):
    """Parse Flipper .ir text. Returns (buttons, errors): buttons = [(name, cmd)], errors = Counter."""
    errors = collections.Counter()
    buttons = []
    lines = text.splitlines()
    header = [ln.strip() for ln in lines[:4] if ln.strip() and not ln.strip().startswith("#")]
    if not header or header[0] != "Filetype: IR signals file":
        errors["file: not an IR signals file"] += 1
        return buttons, errors

    blocks, current = [], None
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if key == "name":
            current = {"name": value, "data": []}
            blocks.append(current)
        elif current is None:
            continue  # file header fields
        elif key == "data":
            current["data"].append(value)
        else:
            current.setdefault(key, value)

    for block in blocks:
        name = clean_text(block["name"])
        kind = block.get("type")
        if kind is None and ("protocol" in block or block["data"]):
            kind = "parsed" if "protocol" in block else "raw"
            errors["recovered: missing type inferred from the fields"] += 1
        if kind == "parsed":
            cmd, reason = parse_parsed_block(block)
        elif kind == "raw":
            cmd, reason = parse_raw_block(block)
        elif kind is None:
            cmd, reason = None, "block: missing type"
        else:
            cmd, reason = None, "block: unknown type"
        if reason:
            errors[reason] += 1
            continue
        if not normalize_name(name):
            errors["block: button without a name"] += 1
            continue
        if len(buttons) >= MAX_BUTTONS_PER_FILE:
            errors["block: more than 256 buttons in one file"] += 1
            continue
        buttons.append((name, cmd))
    return buttons, errors


def parse_parsed_block(block):
    protocol = block.get("protocol")
    if protocol is None or "address" not in block or "command" not in block:
        return None, "parsed: missing field"
    if protocol not in PROTOCOLS:
        return None, "parsed: unknown protocol"
    address = parse_hex_u32(block["address"])
    command = parse_hex_u32(block["command"])
    if address is None or command is None:
        return None, "parsed: malformed address/command"
    address_bits, command_bits = PROTOCOLS[protocol]
    if address >> address_bits or command >> command_bits:
        return None, "parsed: address/command wider than the protocol"
    return {"p": protocol, "a": address, "c": command}, None


def parse_raw_block(block):
    if "frequency" not in block or "duty_cycle" not in block or not block["data"]:
        return None, "raw: missing field"
    frequency = parse_number(block["frequency"], int)
    duty_cycle = parse_number(block["duty_cycle"], float)
    tokens = " ".join(block["data"]).split()
    if len(tokens) > MAX_RAW_DURATIONS:
        return None, "raw: recording longer than 4096 durations"
    if frequency is None or duty_cycle is None or duty_cycle < 0:
        return None, "raw: malformed number"
    data = [parse_number(t, int) for t in tokens]
    if any(v is None for v in data):
        return None, "raw: malformed number"
    return normalize_raw(frequency, duty_cycle, data)


# --------------------------------------------------------------------------------------------------------------
# Key mapping


def map_buttons(buttons, aliases):
    """[(name, cmd)] in file order -> (keys, extra, duplicates dropped)."""
    norms = [normalize_name(n) for n, _ in buttons]
    present = set(norms)
    letter_alias = collections.defaultdict(list)
    for group in aliases.letter_groups:
        if all(letter in present for letter in group):
            for letter, key in group.items():
                letter_alias[key].append(letter)

    # Dual-label buttons such as 'Blue_|_epg' also answer to each label, after every full-name match.
    parts = [[q for q in (normalize_name(p) for p in name.split("|")) if q] if "|" in name else []
             for name, _ in buttons]

    keys, used = {}, set()
    for key in aliases.key_order:
        names = aliases.by_key[key] + letter_alias.get(key, [])
        rank = {n: i for i, n in enumerate(names)}
        best = None
        for pos, norm in enumerate(norms):
            score = rank.get(norm)
            if score is None:
                score = min((len(names) + rank[p] for p in parts[pos] if p in rank), default=None)
            if score is not None and (best is None or (score, pos) < best):
                best = (score, pos)
        if best is not None:
            pos = best[1]
            keys[key] = buttons[pos][1]
            used.add(pos)

    seen = {canonical(cmd) for cmd in keys.values()}
    extra, dropped = [], 0
    for pos, (name, cmd) in enumerate(buttons):
        if pos in used:
            continue
        c = canonical(cmd)
        if c in seen:
            dropped += 1
            continue
        seen.add(c)
        extra.append({"name": name, "cmd": cmd})
    return keys, extra, dropped


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


# --------------------------------------------------------------------------------------------------------------
# Files, brands and models


def safe_path_text(rel):
    """File names end up in the JSON and in the report: no control/format/surrogate characters, bounded length."""
    return len(rel) <= MAX_PATH_CHARS and all(unicodedata.category(ch)[0] != "C" for ch in rel)


def iter_ir_files(tvs_dir, stats):
    """Yield (relative path under tvs_dir, absolute path); no symlinks, no hidden entries, sorted."""
    tvs_dir = str(tvs_dir)
    for dirpath, dirnames, filenames in os.walk(tvs_dir, followlinks=False):
        depth = 0 if dirpath == tvs_dir else os.path.relpath(dirpath, tvs_dir).count(os.sep) + 1
        if depth >= MAX_DEPTH:
            if dirnames or filenames:
                stats.skip("file: folder nested too deep", ascii(os.path.relpath(dirpath, tvs_dir))[:80])
            dirnames[:] = []
            continue
        dirnames[:] = sorted(d for d in dirnames
                             if not d.startswith(".") and not os.path.islink(os.path.join(dirpath, d)))
        for fn in sorted(filenames):
            if fn.startswith("."):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, tvs_dir).replace(os.sep, "/")
            if not safe_path_text(rel):
                stats.skip("file: unsafe file name", ascii(rel)[:80])
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                stats.skip("file: symlink or special file", rel)
                continue
            yield rel, path


def brand_of(rel):
    """Brand display name: the folder under TVs/, or the first word of a file placed directly in TVs/."""
    parts = rel.split("/")
    if len(parts) > 1:
        return clean_text(parts[0])
    stem = parts[0][:-3] if parts[0].lower().endswith(".ir") else parts[0]
    return clean_text(re.split(r"[\s_]+", stem.strip())[0])


def looks_like_model(token):
    """'BN59-01175N', '32LF650V', 'RM-YD018': letters and digits, and either 2+ digits or upper-case letters."""
    if not MODEL_RE.match(token) or NOT_MODEL_RE.match(token):
        return False
    digits = sum(ch.isdigit() for ch in token)
    letters = [ch for ch in token if ch.isalpha()]
    return digits >= 2 or all(ch.isupper() for ch in letters)


def file_label(rel, brand):
    """(models, label) taken from the file name."""
    name = rel.split("/")[-1]
    stem = name[:-3] if name.lower().endswith(".ir") else name
    stem = re.sub(r"\(.*?\)", " ", stem)
    tokens = [t for t in re.split(r"[\s_,]+", stem) if t]
    brand_tokens = {normalize_name(t) for t in re.split(r"[\s_\-]+", brand)} | {normalize_name(brand)}
    tokens = [t for t in tokens if normalize_name(t) not in brand_tokens]
    models = []
    for t in tokens:
        t = clean_text(t.strip(".-/+"))
        if looks_like_model(t) and t not in models:
            models.append(t)
    words = [t for t in tokens if t.lower() not in LABEL_STOPWORDS]
    return models, clean_text(" ".join(words), 48)


MAX_PROFILE_NAME = 100  # before a possible ' #N' suffix


def profile_name(brand, models, label):
    if models:
        shown = ", ".join(models[:3])
        if len(models) > 3:
            shown += f" +{len(models) - 3}"
        name = f"{brand} TV ({shown})"
    elif label:
        name = f"{brand} TV ({label})"
    else:
        name = f"{brand} TV"
    if len(name) > MAX_PROFILE_NAME:
        name = name[:MAX_PROFILE_NAME - 2].rstrip() + "…)"
    return name


# --------------------------------------------------------------------------------------------------------------
# Import


class Stats:
    def __init__(self):
        self.files_seen = 0
        self.files_used = 0
        self.skipped_files = collections.Counter()
        self.skipped_codes = collections.Counter()
        self.recovered = collections.Counter()
        self.examples = collections.defaultdict(list)
        self.buttons_in = collections.Counter()       # parsed / raw buttons accepted from files
        self.duplicates_dropped = 0
        self.names = collections.Counter()            # normalized name -> number of files using it
        self.name_examples = {}

    def skip(self, reason, where):
        if reason.startswith("file:"):
            target = self.skipped_files
        elif reason.startswith("recovered:"):
            target = self.recovered
        else:
            target = self.skipped_codes
        target[reason] += 1
        if len(self.examples[reason]) < 3:
            self.examples[reason].append(where)


def read_text(path):
    with open(path, "rb") as fh:
        data = fh.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        return None
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", errors="replace")


def collect(sources, aliases, stats):
    """sources: [(prefix, tvs_dir)] -> {brand_id: {"name": str, "files": [file entry]}}."""
    brands = {}
    for prefix, tvs_dir in sources:
        for rel, path in iter_ir_files(tvs_dir, stats):
            stats.files_seen += 1
            source = f"{prefix}TVs/{rel}"
            try:
                text = read_text(path)
                if text is None:
                    stats.skip("file: larger than 1 MiB", source)
                    continue
                buttons, errors = parse_ir_text(text)
            except (OSError, ValueError, OverflowError, RecursionError) as exc:
                stats.skip(f"file: unreadable ({type(exc).__name__})", source)
                continue
            for reason, count in sorted(errors.items()):
                for _ in range(count):
                    stats.skip(reason, source)
            if "file: not an IR signals file" in errors:
                continue
            if not buttons:
                stats.skip("file: no usable buttons", source)
                continue
            brand = brand_of(rel)
            brand_id = slugify(brand)
            if not brand_id:
                stats.skip("file: brand name without letters or digits", source)
                continue
            for norm in {normalize_name(n) for n, _ in buttons}:
                stats.names[norm] += 1
            for name, cmd in buttons:
                stats.name_examples.setdefault(normalize_name(name), name)
                stats.buttons_in["raw" if "raw" in cmd else "parsed"] += 1
            keys, extra, dropped = map_buttons(buttons, aliases)
            stats.duplicates_dropped += dropped
            models, label = file_label(rel, brand)
            entry = brands.setdefault(brand_id, {"name": brand, "files": []})
            entry["files"].append({"source": source, "keys": keys, "extra": extra,
                                   "models": models, "label": label})
            stats.files_used += 1
    return brands


def build_profiles(brand_id, brand, files, key_order):
    groups = collections.OrderedDict()
    for f in sorted(files, key=lambda f: f["source"]):
        sig = (canonical([[k, f["keys"][k]] for k in key_order if k in f["keys"]]),
               canonical(sorted(canonical(e["cmd"]) for e in f["extra"])))
        groups.setdefault(sig, []).append(f)
    profiles = []
    for members in groups.values():
        first = members[0]
        models = sorted({m for f in members for m in f["models"]}, key=lambda m: (m.lower(), m))
        label = next((f["label"] for f in members if f["label"]), "")
        profiles.append({
            "brand": brand,
            "name": profile_name(brand, models, label),
            "models": models,
            "weight": len(members),
            "source": sorted(f["source"] for f in members),
            "keys": {k: first["keys"][k] for k in key_order if k in first["keys"]},
            "extra": first["extra"],
        })
    profiles.sort(key=lambda p: (-p["weight"], -len(p["keys"]), -len(p["extra"]), p["source"][0]))
    seen = collections.Counter()
    for p in profiles:
        seen[p["name"]] += 1
        if seen[p["name"]] > 1:
            p["name"] = f"{p['name']} #{seen[p['name']]}"
    return [dict([("id", f"{brand_id}-{i}")] + list(p.items())) for i, p in enumerate(profiles, 1)]


def build_power_scan(all_profiles):
    codes = collections.OrderedDict()
    for p in all_profiles:
        cmd = p["keys"].get("power") or p["keys"].get("wakeUp")
        if cmd is None:
            continue
        entry = codes.setdefault(canonical(cmd), {"cmd": cmd, "brands": collections.Counter(), "weight": 0})
        entry["brands"][p["brand"]] += p["weight"]
        entry["weight"] += p["weight"]
    out = []
    for c, e in codes.items():
        brands = sorted(e["brands"], key=lambda b: (-e["brands"][b], b.lower(), b))
        out.append((c, {"cmd": e["cmd"], "brands": brands, "weight": e["weight"]}))
    out.sort(key=lambda item: (-item[1]["weight"], -len(item[1]["brands"]), item[0]))
    return [e for _, e in out]


# --------------------------------------------------------------------------------------------------------------
# Output


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def format_profiles(profiles):
    out = ["["]
    for pi, p in enumerate(profiles):
        lines = ["  {"]
        for field in ("id", "brand", "name", "models", "weight", "source"):
            lines.append(f"    {dumps(field)}: {dumps(p[field])},")
        if p["keys"]:
            lines.append('    "keys": {')
            items = list(p["keys"].items())
            for i, (k, cmd) in enumerate(items):
                lines.append(f"      {dumps(k)}: {dumps(cmd)}" + ("," if i < len(items) - 1 else ""))
            lines.append("    },")
        else:
            lines.append('    "keys": {},')
        if p["extra"]:
            lines.append('    "extra": [')
            for i, e in enumerate(p["extra"]):
                lines.append(f"      {dumps(e)}" + ("," if i < len(p['extra']) - 1 else ""))
            lines.append("    ]")
        else:
            lines.append('    "extra": []')
        lines.append("  }" + ("," if pi < len(profiles) - 1 else ""))
        out.extend(lines)
    out.append("]")
    return "\n".join(out) + "\n"


def format_power_scan(entries):
    if not entries:
        return "[]\n"
    rows = [f"  {dumps(e)}" for e in entries]
    return "[\n" + ",\n".join(rows) + "\n]\n"


def format_index(index):
    head = {k: v for k, v in index.items() if k != "brands"}
    lines = ["{"]
    for k, v in head.items():
        lines.append(f"  {dumps(k)}: {json.dumps(v, ensure_ascii=False, separators=(', ', ': '))},")
    lines.append('  "brands": [')
    rows = [f"    {json.dumps(b, ensure_ascii=False, separators=(', ', ': '))}" for b in index["brands"]]
    lines.append(",\n".join(rows))
    lines.append("  ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_if_changed(path, text):
    path = pathlib.Path(path)
    data = text.encode("utf-8")
    if path.is_file() and not path.is_symlink() and path.read_bytes() == data:
        return
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_regular(path, limit):
    """Text of a regular file (not a symlink, FIFO or device) of at most `limit` bytes, else None."""
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
            return None
        with open(path, "rb") as fh:
            data = fh.read(limit + 1)
    except OSError:
        return None
    if len(data) > limit:
        return None
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", errors="replace")


def check_license(text):
    """The CC0 legal code starts with these two lines; anything else needs a human review first."""
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()][:2]
    return lines == ["Creative Commons Legal Code", "CC0 1.0 Universal"]


def readme_license_note(repo):
    """The upstream README excludes early commits from CC0; keep that remark next to the license id."""
    text = read_regular(pathlib.Path(repo) / "README.md", MAX_FILE_BYTES) or ""
    m = re.search(r"[Cc]ommits prior to \[?`?([0-9a-f]{7,40})", text)
    if not m:
        return None
    return (f"The upstream README states that commits prior to {m.group(1)} are not covered by the CC0-1.0 "
            "license; see docs/ir/profiles.md.")


def read_git_commit(repo):
    """Resolve HEAD of a checkout without running git."""
    git = pathlib.Path(repo) / ".git"
    head = (read_regular(git / "HEAD", 4096) or "").strip()
    if re.fullmatch(r"[0-9a-f]{40}", head):
        return head
    m = re.fullmatch(r"ref: (refs/[A-Za-z0-9._/\-]+)", head)
    if not m or ".." in m.group(1):
        return None
    ref = m.group(1)
    value = (read_regular(git / ref, 4096) or "").strip()
    if re.fullmatch(r"[0-9a-f]{40}", value):
        return value
    for line in (read_regular(git / "packed-refs", MAX_FILE_BYTES) or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == ref and re.fullmatch(r"[0-9a-f]{40}", parts[0]):
            return parts[0]
    return None


def run_import(irdb, out, commit=None, url=DEFAULT_URL, aliases_path=DEFAULT_ALIASES, contrib=None,
               license_note=None):
    """Import and write the profiles. Returns a report dict."""
    irdb = pathlib.Path(irdb)
    out = pathlib.Path(out)
    tvs = irdb / "TVs"
    if not tvs.is_dir() or tvs.is_symlink():
        raise SystemExit(f"error: {tvs} is not a directory")
    if out.is_symlink() or (out / "brands").is_symlink():
        raise SystemExit(f"error: {out} must not be a symlink")
    out_abs, irdb_abs = out.resolve(), irdb.resolve()
    if out_abs == irdb_abs or irdb_abs in out_abs.parents:
        raise SystemExit("error: --out must not be inside the database checkout")
    if not URL_RE.fullmatch(url):
        raise SystemExit("error: --url must be a plain https URL")
    commit = commit or read_git_commit(irdb)
    if not commit or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("error: cannot determine the commit; pass --commit <40-char sha>")
    aliases = Aliases.load(aliases_path)
    stats = Stats()
    license_text = read_regular(irdb / "LICENSE", MAX_LICENSE_BYTES)
    if not check_license(license_text):
        raise SystemExit("error: the database LICENSE is missing or not the CC0 1.0 legal code; review it first")
    if license_note is None:
        license_note = readme_license_note(irdb)
    else:
        license_note = clean_text(license_note, 300) or None

    sources = [("", tvs)]
    contrib_tvs = pathlib.Path(contrib) / "TVs" if contrib else None
    if contrib_tvs and contrib_tvs.is_dir():
        sources.append((CONTRIB_PREFIX, contrib_tvs))
    brands = collect(sources, aliases, stats)

    out.mkdir(parents=True, exist_ok=True)
    brands_dir = out / "brands"
    brands_dir.mkdir(exist_ok=True)

    index_brands, all_profiles = [], []
    for brand_id in sorted(brands):
        entry = brands[brand_id]
        # Folders that differ only in case/punctuation share an id; the name of the first one wins.
        profiles = build_profiles(brand_id, entry["name"], entry["files"], aliases.key_order)
        write_if_changed(brands_dir / f"{brand_id}.json", format_profiles(profiles))
        index_brands.append({"id": brand_id, "name": entry["name"], "file": f"brands/{brand_id}.json",
                             "profiles": len(profiles)})
        all_profiles.extend(profiles)
    for stale in sorted(brands_dir.glob("*.json")):
        if stale.stem not in brands:
            stale.unlink()

    source = {"db": DB_NAME, "url": url, "commit": commit, "license": LICENSE_ID}
    if license_note:
        source["note"] = license_note
    index = {"schema": SCHEMA_VERSION, "source": source, "brands": index_brands}
    write_if_changed(out / "index.json", format_index(index))
    power = build_power_scan(all_profiles)
    write_if_changed(out / "power_scan.json", format_power_scan(power))

    write_if_changed(out / "LICENSE", license_text)

    codes_out = collections.Counter()
    for p in all_profiles:
        for cmd in list(p["keys"].values()) + [e["cmd"] for e in p["extra"]]:
            codes_out["raw" if "raw" in cmd else "parsed"] += 1

    protocols = collections.Counter()
    for p in all_profiles:
        for cmd in list(p["keys"].values()) + [e["cmd"] for e in p["extra"]]:
            protocols[cmd.get("p", "raw")] += 1
    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    return {
        "commit": commit,
        "files_seen": stats.files_seen,
        "files_used": stats.files_used,
        "brands": len(brands),
        "profiles": len(all_profiles),
        "buttons_in": dict(stats.buttons_in),
        "codes_out": dict(codes_out),
        "duplicates_dropped": stats.duplicates_dropped,
        "skipped_files": dict(sorted(stats.skipped_files.items())),
        "skipped_codes": dict(sorted(stats.skipped_codes.items())),
        "recovered": dict(sorted(stats.recovered.items())),
        "skip_examples": {k: v for k, v in sorted(stats.examples.items())},
        "protocols": dict(protocols.most_common()),
        "power_scan_codes": len(power),
        "top_brands": [(b["name"], b["profiles"]) for b in
                       sorted(index_brands, key=lambda b: (-b["profiles"], b["id"]))[:20]],
        "size_bytes": size,
        "name_stats": [(n, c, stats.name_examples.get(n, n), describe_name(n, aliases))
                       for n, c in sorted(stats.names.items(), key=lambda x: (-x[1], x[0]))],
    }


def describe_name(norm, aliases):
    keys = [k for k in aliases.key_order if norm in aliases.by_key[k]]
    if keys:
        return ",".join(keys)
    letters = sorted({g[norm] for g in aliases.letter_groups if norm in g})
    if letters:
        return "letter:" + "/".join(letters)
    return "extra (reviewed)" if norm in aliases.extra_names else "extra (UNREVIEWED)"


def print_report(report, name_stats):
    w = sys.stdout.write
    w(f"commit            {report['commit']}\n")
    w(f"files             {report['files_used']} used of {report['files_seen']}\n")
    w(f"brands/profiles   {report['brands']} / {report['profiles']}\n")
    w(f"buttons in        {report['buttons_in']}\n")
    w(f"codes out         {report['codes_out']} (duplicates dropped: {report['duplicates_dropped']})\n")
    w(f"power_scan        {report['power_scan_codes']} codes\n")
    w(f"size              {report['size_bytes']} bytes\n")
    for title, key in (("skipped files", "skipped_files"), ("skipped codes", "skipped_codes"),
                       ("recovered", "recovered")):
        for reason, count in report[key].items():
            w(f"{title:17} {count:5}  {reason}  e.g. {', '.join(report['skip_examples'][reason])}\n")
    w(f"protocols         {report['protocols']}\n")
    if name_stats:
        unreviewed = 0
        for i, (norm, files, example, target) in enumerate(report["name_stats"][:name_stats], 1):
            unreviewed += target.endswith("(UNREVIEWED)")
            w(f"{i:4} {files:4}  {example!r:28} {target}\n")
        w(f"unreviewed names in top {name_stats}: {unreviewed}\n")
    if report["size_bytes"] > 3_000_000:
        w("warning: profiles/ is larger than 3 MB\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--irdb", required=True, help="Flipper-IRDB checkout (contains TVs/ and LICENSE)")
    ap.add_argument("--out", required=True, help="output folder, e.g. profiles/")
    ap.add_argument("--commit", help="commit sha of the checkout (default: read from <irdb>/.git)")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--aliases", default=str(DEFAULT_ALIASES))
    ap.add_argument("--contrib", default=str(DEFAULT_CONTRIB),
                    help="folder with openpult additions in the same layout (<dir>/TVs/<Brand>/*.ir)")
    ap.add_argument("--license-note", default=None, help="extra license remark stored in index.json")
    ap.add_argument("--report", help="write the import report as JSON to this file")
    ap.add_argument("--name-stats", type=int, default=0, metavar="N", help="print the N most frequent names")
    args = ap.parse_args(argv)
    report = run_import(args.irdb, args.out, args.commit, args.url, args.aliases, args.contrib, args.license_note)
    print_report(report, args.name_stats)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, ensure_ascii=False)
            fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
