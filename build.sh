#!/usr/bin/env bash
# Build @napi-rs/canvas as a static library (libcanvas.a + Skia archives) for
# linking into jsgame-libretro. CI calls this same script.
#
# Requires: clang/clang++ 19 (+libc++-19-dev on linux), rust, node, ninja,
#           python3, nasm or yasm, git.
set -euo pipefail
cd "$(dirname "$0")"

CANVAS_SHA=$(node -p "require('./versions.json').canvas")
SKIA_SHA=$(node -p "require('./versions.json').skia")
DEPOT_SHA=$(node -p "require('./versions.json').depot_tools")
CANVAS_VERSION=$(node -p "require('./versions.json').canvasVersion")
PLATFORM="${PLATFORM:-linux-x86_64}"

SRC=src/canvas
if [ ! -d "$SRC/.git" ]; then
    git clone --no-checkout https://github.com/Brooooooklyn/canvas.git "$SRC"
fi
git -C "$SRC" fetch -q origin "$CANVAS_SHA" 2>/dev/null || true
git -C "$SRC" checkout -q "$CANVAS_SHA"
git -C "$SRC" submodule init
git -C "$SRC" config submodule.skia.url https://github.com/google/skia.git
git -C "$SRC" submodule update --depth 1 depot_tools || \
    (cd "$SRC/depot_tools" && git fetch -q origin "$DEPOT_SHA" && git checkout -q "$DEPOT_SHA")
# skia: the pinned SHA may be newer than the recorded gitlink — fetch explicitly
if [ ! -e "$SRC/skia/.git" ]; then
    git clone --no-checkout https://github.com/google/skia.git "$SRC/skia"
fi
git -C "$SRC/skia" fetch -q origin "$SKIA_SHA" || git -C "$SRC/skia" fetch -q origin
git -C "$SRC/skia" checkout -q "$SKIA_SHA"

# staticlib patch (cdylib -> staticlib)
git -C "$SRC" checkout -q Cargo.toml
patch -d "$SRC" -p1 -s < patches/staticlib.patch

cd "$SRC"

# Skia static build (their script; host-native = no --target flag)
node scripts/build-skia.js

# Rust staticlib. strip=none keeps napi_register_module_v1; lto=false keeps
# the archive as real ELF objects (fat-LTO bitcode can't be linked by
# arbitrary downstream toolchains and is invisible to nm). Env vars, not
# --config: manifest [profile.release] outranks --config, env outranks both.
CARGO_PROFILE_RELEASE_LTO=false \
CARGO_PROFILE_RELEASE_STRIP=none \
cargo build --release

# ── Package ──────────────────────────────────────────────────────────────
cd ../..
OUT="out/$PLATFORM"
rm -rf "$OUT"
mkdir -p "$OUT/skia" "$OUT/js" "$OUT/include"
cp "$SRC/target/release/libcanvas.a" "$OUT/"
cp "$SRC"/skia/out/Static/*.a "$OUT/skia/"
cp "$SRC/skia-c/skia_c.hpp" "$OUT/include/"
cp "$SRC/index.js" "$SRC/geometry.js" "$SRC/load-image.js" "$OUT/js/"
printf "module.exports = process._linkedBinding('canvas');\n" > "$OUT/js/js-binding.js"
echo "$CANVAS_VERSION" > "$OUT/CANVAS_VERSION"

# note: no `grep -q` here — early-exit SIGPIPEs nm and pipefail reports failure
SYMS=$(nm "$OUT/libcanvas.a" 2>/dev/null | grep -c 'T napi_register_module_v1' || true)
[ "$SYMS" -ge 1 ] || { echo "FATAL: napi_register_module_v1 missing from libcanvas.a"; exit 1; }

tar czf "out/libcanvas-$PLATFORM.tar.gz" -C "$OUT" .
ls -lh "out/libcanvas-$PLATFORM.tar.gz"
