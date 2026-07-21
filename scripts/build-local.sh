#!/usr/bin/env bash
# Build the cranelift rustc.wasm + sysroots LOCALLY, mirroring .github/workflows/build.yml, to
# validate the recipe before trusting CI.
#
# Uses bjorn3/rust's shipped bootstrap.toml (download-ci-llvm=true → a PREBUILT LLVM is downloaded,
# so the host gcc/cmake version is irrelevant) + WASI SDK 32. No LLVM is compiled from source.
#
# Env: BRANCH (default compile_rustc_for_wasm20), WORK (default ~/.cache/riw-build/wasm-rustc),
#      OUT_DIR (default $WORK/out).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BRANCH="${BRANCH:-compile_rustc_for_wasm20}"
WORK="${WORK:-$HOME/.cache/riw-build/wasm-rustc}"
RUST_DIR="$WORK/rust"
WASI_DIR="wasi-sdk-32.0-x86_64-linux"
OUT_DIR="${OUT_DIR:-$WORK/out}"
mkdir -p "$WORK"

echo "==> [1/5] checkout bjorn3/rust @ $BRANCH   ($(date '+%H:%M:%S'))"
# Full history (download-ci-llvm needs it); NO submodules on clone — x.py auto-inits the ones it
# needs and skips llvm-project entirely when download-ci-llvm is on.
if [ ! -d "$RUST_DIR/.git" ]; then
  git clone --branch "$BRANCH" https://github.com/bjorn3/rust "$RUST_DIR"
else
  ( cd "$RUST_DIR" && git fetch origin "$BRANCH" && git checkout -B "$BRANCH" "origin/$BRANCH" )
fi

echo "==> [2/5] WASI SDK 32 into the checkout   ($(date '+%H:%M:%S'))"
if [ ! -x "$RUST_DIR/$WASI_DIR/bin/clang" ]; then
  curl -fL -o "$RUST_DIR/wasi-sdk.tar.gz" \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-32/${WASI_DIR}.tar.gz"
  tar -xzf "$RUST_DIR/wasi-sdk.tar.gz" -C "$RUST_DIR"
  rm -f "$RUST_DIR/wasi-sdk.tar.gz"
fi
test -x "$RUST_DIR/$WASI_DIR/bin/clang" && echo "    wasi clang OK"
# bootstrap REQUIRES this env var (not just bootstrap.toml paths) when building a -wasi target
# under CI (cc_detect.rs); export it here so build-local.sh matches the CI workflow.
export WASI_SDK_PATH="$RUST_DIR/$WASI_DIR"
export WASI_SYSROOT="$RUST_DIR/$WASI_DIR/share/wasi-sysroot"

# The branch patches libwild to a local ./wild/libwild ([patch.crates-io] in Cargo.toml) but does
# NOT vendor it or list it as a submodule, so we clone wild-linker/wild at the exact rev Cargo.lock
# pins (auto-extracted so it tracks the branch).
echo "==> [2b] provide the wild linker (patched to ./wild/libwild)   ($(date '+%H:%M:%S'))"
if [ ! -e "$RUST_DIR/wild/libwild/Cargo.toml" ]; then
  WILD_REV="$(grep -A3 'name = "libwild"' "$RUST_DIR/Cargo.lock" 2>/dev/null | grep -oE 'wild\.git#[0-9a-f]{7,40}' | head -1 | sed 's/.*#//')"
  echo "    wild rev: ${WILD_REV:-<none found, using default branch>}"
  git clone --quiet https://github.com/wild-linker/wild.git "$RUST_DIR/wild"
  [ -n "$WILD_REV" ] && git -C "$RUST_DIR/wild" checkout --quiet "$WILD_REV"
fi
test -e "$RUST_DIR/wild/libwild/Cargo.toml" && echo "    wild/libwild OK"

# Building the riscv64 no_std sysroot wants a target C compiler; the target's default is
# riscv64-unknown-elf-gcc (not installed). Use clang (a cross-compiler) + mark the target no_std,
# matching the original 1.83 spike. Appended after checkout so it survives the re-checkout reset.
echo "==> [2c] configure riscv64 target (cc=clang, no-std)   ($(date '+%H:%M:%S'))"
if ! grep -q 'riscv64gc-unknown-none-elf' "$RUST_DIR/bootstrap.toml"; then
  cat >> "$RUST_DIR/bootstrap.toml" <<'TOML'

[target."riscv64gc-unknown-none-elf"]
cc = "clang"
no-std = true
TOML
fi

echo "==> [3/5] x.py install (download CI LLVM + build cranelift rustc.wasm)   ($(date '+%H:%M:%S'))"
( cd "$RUST_DIR" && python3 x.py install )

echo "==> [4/5] riscv64 no_std sysroot   ($(date '+%H:%M:%S'))"
( cd "$RUST_DIR" && python3 x.py build library --target riscv64gc-unknown-none-elf )

echo "==> [5/5] package artifacts   ($(date '+%H:%M:%S'))"
RUST_DIR="$RUST_DIR" OUT_DIR="$OUT_DIR" "$here/package-artifacts.sh"

echo "==> DONE   ($(date '+%H:%M:%S')). Artifacts in $OUT_DIR"
