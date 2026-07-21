#!/usr/bin/env python3
"""Strip non-essential custom sections from a wasm module (name, producers, .debug_*).

These sections are debug/metadata only — they carry no semantics, so removing them cannot change
execution. For our committed rustc.wasm the `name` section alone is ~30 MB (function names for
stack traces the browser never needs). Everything else is copied byte-for-byte, so this is far
safer than a full wasm-opt round-trip (no re-encoding of the code section).

Usage: strip-wasm-custom.py <in.wasm> <out.wasm>
"""
import sys

STRIP_EXACT = {"name", "producers"}


def uleb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            break
        s += 7
    return r, i


def main():
    inp, out = sys.argv[1], sys.argv[2]
    d = open(inp, "rb").read()
    assert d[:4] == b"\x00asm", "not a wasm module"
    o = bytearray(d[:8])  # magic + version
    i = 8
    dropped = 0
    while i < len(d):
        sid = d[i]
        size, k = uleb(d, i + 1)
        seg_start, seg_end = i, k + size
        drop = False
        if sid == 0:  # custom section
            nl, m = uleb(d, k)
            nm = d[m:m + nl].decode("utf8", "replace")
            if nm in STRIP_EXACT or nm.startswith(".debug_"):
                drop = True
        if drop:
            dropped += seg_end - seg_start
        else:
            o += d[seg_start:seg_end]
        i = seg_end
    open(out, "wb").write(o)
    print(f"in {len(d)/1048576:.2f} MB  out {len(o)/1048576:.2f} MB  dropped {dropped/1048576:.2f} MB")


if __name__ == "__main__":
    main()
