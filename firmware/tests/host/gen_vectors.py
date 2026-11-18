#!/usr/bin/env python3
"""Turns testdata/ir_vectors.json into a C header for the host tests.

Usage: python3 -I gen_vectors.py <ir_vectors.json> <vectors.h>
"""
import json
import sys


def c_array(ctype, name, values):
    body = ", ".join(str(v) for v in values) or "0"
    return f"static const {ctype} {name}[] = {{{body}}};\n"


def ident(name):
    return "".join(c if c.isalnum() else "_" for c in name)


def writes(prefix, hex_list, out):
    names = []
    for i, h in enumerate(hex_list):
        data = bytes.fromhex(h)
        n = f"{prefix}_{i}"
        out.append(c_array("uint8_t", n, list(data)))
        names.append((n, len(data)))
    entries = ", ".join(f"{{{n}, {length}}}" for n, length in names)
    out.append(f"static const struct vec_write {prefix}[] = {{{entries}}};\n")
    return len(names)


def main(src, dst):
    with open(src) as f:
        vectors = json.load(f)

    out = [
        "/* Generated from testdata/ir_vectors.json by gen_vectors.py. Do not edit. */\n",
        "#include <stdint.h>\n\n",
        "struct vec_write { const uint8_t *data; uint16_t len; };\n",
        "struct vec_signal {\n"
        "\tconst char *name; uint16_t carrier_hz; uint8_t duty_pct; uint8_t min_repeats;\n"
        "\tconst uint32_t *intro; uint16_t intro_n; const uint32_t *repeat; uint16_t repeat_n;\n"
        "\tconst uint32_t *table; uint8_t table_n; const uint8_t *blob; uint16_t blob_len;\n"
        "\tconst struct vec_write *play; uint8_t play_n;\n"
        "\tconst struct vec_write *play_mtu23; uint8_t play_mtu23_n;\n"
        "};\n",
        "struct vec_sirc { const char *key; uint8_t bits; uint16_t device; uint8_t command;"
        " uint32_t value; };\n",
        "struct vec_hold { uint32_t unit_us; uint8_t count; };\n\n",
    ]

    signals = []
    for s in vectors["signals"]:
        p = ident(s["name"])
        out.append(c_array("uint32_t", f"{p}_intro", s["intro"]))
        out.append(c_array("uint32_t", f"{p}_repeat", s["repeat"]))
        out.append(c_array("uint32_t", f"{p}_table", s["table"]))
        blob = bytes.fromhex(s["blob_hex"])
        out.append(c_array("uint8_t", f"{p}_blob", list(blob)))
        n_play = writes(f"{p}_play", s["play_hex"], out)
        n_mtu = writes(f"{p}_mtu23", s["play_hex_mtu23"], out)
        signals.append(
            f'{{"{s["name"]}", {s["carrier_hz"]}, {s["duty_pct"]}, {s["min_repeats"]}, '
            f'{p}_intro, {len(s["intro"])}, {p}_repeat, {len(s["repeat"])}, '
            f'{p}_table, {len(s["table"])}, {p}_blob, {len(blob)}, '
            f"{p}_play, {n_play}, {p}_mtu23, {n_mtu}}}"
        )
    out.append("static const struct vec_signal vec_signals[] = {\n\t" + ",\n\t".join(signals)
               + "\n};\n")

    sirc = [f'{{"{e["key"]}", {e["bits"]}, {e["device"]}, {e["command"]}, {e["value"]}}}'
            for e in vectors["sirc"]]
    out.append("static const struct vec_sirc vec_sirc[] = {\n\t" + ",\n\t".join(sirc) + "\n};\n")

    hold = [f'{{{e["repeat_unit_us"]}, {e["count"]}}}' for e in vectors["hold"]["examples"]]
    out.append("static const struct vec_hold vec_hold[] = {" + ", ".join(hold) + "};\n")

    out.append("#define VEC_COUNT(a) (sizeof(a) / sizeof((a)[0]))\n")
    with open(dst, "w") as f:
        f.write("".join(out))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
