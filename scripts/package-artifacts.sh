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
rm -rf "$OUT_DIR"
mkdir -p "$STAGE/rustc" "$RISCV_LIB_DST" "$STD_LIB_DST"

gen_manifest() { # <lib_dir> <out.json>
  python3 - "$1" "$2" <<'PY'
import json, os, sys
d, out = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    json.dump(sorted(f_ for f_ in os.listdir(d) if f_.endswith(".rlib")), f)
print(f"  manifest: {out}")
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
gen_manifest "$STD_LIB_DST" "$STAGE/std-sysroot/manifest.json"

# --- tar (zstd) each asset with the site's expected internal paths ---
tar --zstd -C "$STAGE" -cf "$OUT_DIR/rustc-wasm.tar.zst"      rustc/rustc.wasm
tar --zstd -C "$STAGE" -cf "$OUT_DIR/riscv64-sysroot.tar.zst" rustc/sysroot
tar --zstd -C "$STAGE" -cf "$OUT_DIR/std-sysroot.tar.zst"     std-sysroot
( cd "$OUT_DIR" && sha256sum *.tar.zst > SHA256SUMS )

echo "== artifacts in $OUT_DIR =="
ls -lh "$OUT_DIR"/*.tar.zst
echo "== SHA256SUMS (paste into the site's artifacts.lock) =="
cat "$OUT_DIR/SHA256SUMS"
