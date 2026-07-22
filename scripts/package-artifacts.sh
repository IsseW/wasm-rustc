#!/usr/bin/env bash
# Package a built bjorn3/rust tree into the three Release tarballs + SHA256SUMS that the playground
# site consumes. Each tarball's internal layout matches what the site's fetch-artifacts.sh extracts
# into app/public/. Run from the wasm-rustc repo root (or anywhere) with:
#   RUST_DIR=<built bjorn3/rust checkout>  OUT_DIR=<output dir>  scripts/package-artifacts.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="${RUST_DIR:?set RUST_DIR to the built bjorn3/rust checkout}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
STAGE="$OUT_DIR/stage"

RISCV_LIB_DST="$STAGE/rustc/sysroot/lib/rustlib/riscv64gc-unknown-none-elf/lib"
STD_LIB_DST="$STAGE/std-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/lib"
WASIP1_DST="$STAGE/rustc/sysroot-wasip1/lib/rustlib/wasm32-wasip1/lib"
# PACKAGE_SET=main   -> rustc.wasm + riscv64 + x86_64-std tarballs (the long job)
# PACKAGE_SET=wasip1 -> wasip1 std sysroot + bundle tarball (the parallel job)
# PACKAGE_SET=all    -> everything (local runs)
PACKAGE_SET="${PACKAGE_SET:-all}"
rm -rf "$OUT_DIR"
mkdir -p "$STAGE/rustc" "$RISCV_LIB_DST" "$STD_LIB_DST" "$WASIP1_DST/self-contained"

gen_manifest() { # <lib_dir> <out.json> [ext,ext]
  python3 - "$1" "$2" ${3:-} <<'PY'
import json, os, sys
d, out = sys.argv[1], sys.argv[2]
exts = tuple(sys.argv[3].split(",")) if len(sys.argv) > 3 else (".rlib",)
names = sorted(f for f in os.listdir(d) if f.endswith(exts))
with open(out, "w") as f:
    json.dump(names, f)
print(f"  manifest: {len(names)} entries -> {out}")
PY
}

pick_dir() { # print first existing dir matching any of the given -path globs, in order
  local pat d
  for pat in "$@"; do
    d="$(find "$RUST_DIR" -type d -path "$pat" 2>/dev/null | sort | head -1)"
    if [ -n "$d" ]; then echo "$d"; return 0; fi
  done
  return 1
}

# --- locate build outputs ---
if [ "$PACKAGE_SET" != "wasip1" ]; then
RUSTC_WASM="$(find "$RUST_DIR" -name rustc.wasm -path '*dist*' 2>/dev/null | head -1)"
[ -n "$RUSTC_WASM" ] || RUSTC_WASM="$(find "$RUST_DIR" -name rustc.wasm 2>/dev/null | head -1)"
[ -n "$RUSTC_WASM" ] || { echo "error: rustc.wasm not found under $RUST_DIR" >&2; exit 1; }

# Prefer the installed (dist) sysroot, else the highest stage — NEVER stage0. stage0 is the
# downloaded beta compiler; its rlib metadata version won't match our rustc.wasm, which would
# silently break the trainer's --emit metadata type-check.
RISCV_LIB_SRC="$(pick_dir \
  '*dist*/rustlib/riscv64gc-unknown-none-elf/lib' \
  '*stage2*/rustlib/riscv64gc-unknown-none-elf/lib' \
  '*stage1*/rustlib/riscv64gc-unknown-none-elf/lib')" || true
STD_LIB_SRC="$(pick_dir \
  '*dist*/lib/rustlib/x86_64-unknown-linux-gnu/lib' \
  '*stage2*/lib/rustlib/x86_64-unknown-linux-gnu/lib' \
  '*stage1*/lib/rustlib/x86_64-unknown-linux-gnu/lib')" || true
[ -n "$RISCV_LIB_SRC" ] || { echo "error: riscv64 sysroot lib dir not found (non-stage0)" >&2; exit 1; }
[ -n "$STD_LIB_SRC" ]   || { echo "error: x86_64 std lib dir not found (non-stage0)" >&2; exit 1; }
echo "rustc.wasm  : $RUSTC_WASM"
echo "riscv64 lib : $RISCV_LIB_SRC"
echo "std lib     : $STD_LIB_SRC"

# --- rustc.wasm (stripped) ---
python3 "$here/strip-wasm-custom.py" "$RUSTC_WASM" "$STAGE/rustc/rustc.wasm"

# --- riscv64 no_std sysroot (core/alloc/compiler_builtins/rustc_std_workspace_core) ---
cp "$RISCV_LIB_SRC"/*.rlib "$RISCV_LIB_DST/"
gen_manifest "$RISCV_LIB_DST" "$STAGE/rustc/sysroot/manifest.json"

# --- x86_64 std sysroot (metadata rlibs, for the trainer's type-check) ---
cp "$STD_LIB_SRC"/*.rlib "$STD_LIB_DST/"
cp "$STD_LIB_SRC"/*.rmeta "$STD_LIB_DST/" 2>/dev/null || true
gen_manifest "$STD_LIB_DST" "$STAGE/std-sysroot/manifest.json" ".rlib,.rmeta"
fi

# --- wasm32-wasip1 STD sysroot (Phase B: the browser links user programs against
# this). Whitelist ONLY the std crates: the stage1 target dir also holds rustc's
# own dependency rmeta (rustc.wasm is built FOR wasip1), which must not ship.
# rlibs carry STUB metadata (pipelined builds) — the .rmeta files ship too.
if [ "$PACKAGE_SET" != "main" ]; then
WASIP1_LIB_SRC="$(pick_dir '*stage1/lib/rustlib/wasm32-wasip1/lib')" || true
[ -n "$WASIP1_LIB_SRC" ] || { echo "error: wasm32-wasip1 std lib dir not found in stage1" >&2; exit 1; }
echo "wasip1 lib  : $WASIP1_LIB_SRC"
STD_CRATES="std core alloc compiler_builtins panic_abort panic_unwind wasi cfg_if rustc_demangle std_detect hashbrown rustc_std_workspace_core rustc_std_workspace_alloc miniz_oxide adler2 unwind libc test getopts unicode_width rustc_std_workspace_std"
for c in $STD_CRATES; do
  found_rlib=0
  for rlib in "$WASIP1_LIB_SRC"/lib$c-*.rlib; do
    [ -e "$rlib" ] || continue
    found_rlib=1
    cp "$rlib" "$WASIP1_DST/"
    # rmeta only for the SAME hash (orphan rmeta from other build units would
    # create ambiguous-candidate errors)
    rmeta="${rlib%.rlib}.rmeta"
    [ -e "$rmeta" ] && cp "$rmeta" "$WASIP1_DST/"
  done
  # rmeta-only crates (e.g. unicode_width): metadata suffices for type-checking
  if [ "$found_rlib" = 0 ]; then
    cp "$WASIP1_LIB_SRC"/lib$c-*.rmeta "$WASIP1_DST/" 2>/dev/null || true
  fi
done
cp "$WASIP1_LIB_SRC/self-contained/crt1-command.o" "$WASIP1_LIB_SRC/self-contained/libc.a"    "$WASIP1_DST/self-contained/"
python3 - "$STAGE/rustc/sysroot-wasip1" <<'PY'
import json, os, sys
root = sys.argv[1]
files = []
for dirpath, _dirs, names in os.walk(root):
    for n in sorted(names):
        files.append(os.path.relpath(os.path.join(dirpath, n), root))
json.dump({"files": files}, open(f"{root}/manifest.json", "w"))
print(f"  wasip1 manifest: {len(files)} files")
PY
# Single-file bundle (kills the request waterfall; the playground preloads it).
python3 - "$STAGE/rustc/sysroot-wasip1" "$STAGE/rustc/sysroot-wasip1.bundle" <<'PY'
import json, os, struct, sys
root, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(root, "manifest.json")))
files, blobs, off = [], [], 0
for rel in manifest["files"]:
    data = open(os.path.join(root, rel), "rb").read()
    files.append({"p": rel, "o": off, "l": len(data)})
    blobs.append(data)
    off += len(data)
index = json.dumps({"files": files, "total": off}).encode()
with open(out, "wb") as f:
    f.write(b"RIWB1\n")
    f.write(struct.pack("<I", len(index)))
    f.write(index)
    for b in blobs:
        f.write(b)
print(f"  wasip1 bundle: {len(files)} files, {(10 + len(index) + off) / 1e6:.1f} MB")
PY
fi

# --- tar (zstd) each asset with the site's expected internal paths ---
if [ "$PACKAGE_SET" != "wasip1" ]; then
tar --zstd -C "$STAGE" -cf "$OUT_DIR/rustc-wasm.tar.zst"      rustc/rustc.wasm
tar --zstd -C "$STAGE" -cf "$OUT_DIR/riscv64-sysroot.tar.zst" rustc/sysroot
tar --zstd -C "$STAGE" -cf "$OUT_DIR/std-sysroot.tar.zst"     std-sysroot
fi
if [ "$PACKAGE_SET" != "main" ]; then
tar --zstd -C "$STAGE" -cf "$OUT_DIR/wasip1-sysroot.tar.zst"  rustc/sysroot-wasip1 rustc/sysroot-wasip1.bundle
fi
( cd "$OUT_DIR" && sha256sum *.tar.zst > SHA256SUMS )

echo "== artifacts in $OUT_DIR =="
ls -lh "$OUT_DIR"/*.tar.zst
echo "== SHA256SUMS (paste into the site's artifacts.lock) =="
cat "$OUT_DIR/SHA256SUMS"
