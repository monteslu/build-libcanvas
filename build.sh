#!/usr/bin/env bash
# Build @napi-rs/canvas as a static library for linking into jsgame-libretro.
#
# Skia is built FROM SOURCE with the Ganesh GL backend (skia_use_gl=true) so the
# jsgame 3D-composite path can use GPU-backed surfaces (no readback). Upstream's
# prebuilt skia-<sha> archives are CPU-only, so we can't use them. The GPU
# surface API + the Ganesh GN flags are added by patches/ganesh-gpu.patch.
#
#   PLATFORM=linux-x86_64 ./build.sh
#
# Skia GL dialect (skia_gl_standard) is chosen per platform: "gles" for Android
# (real GLES3 at runtime) and "gl" for desktop GL-core (linux/macos/windows
# RetroArch). A MISMATCH makes Ganesh emit the wrong shader dialect and every
# shader-based Skia draw silently no-ops at runtime (clear() still works).
set -euo pipefail
cd "$(dirname "$0")"

CANVAS_SHA=$(node -p "require('./versions.json').canvas")
SKIA_SHA=$(node -p "require('./versions.json').skia")
CANVAS_VERSION=$(node -p "require('./versions.json').canvasVersion")
PLATFORM="${PLATFORM:-linux-x86_64}"

# PLATFORM -> rust triple + Skia GL dialect. Desktop GL-core -> "gl"; Android
# real GLES3 -> "gles".
case "$PLATFORM" in
    linux-x86_64)    TRIPLE=x86_64-unknown-linux-gnu;  EXT=a;   GL_STD=gl ;;
    linux-aarch64)   TRIPLE=aarch64-unknown-linux-gnu; EXT=a;   GL_STD=gl ;;
    android-aarch64) TRIPLE=aarch64-linux-android;     EXT=a;   GL_STD=gles ;;
    macos-x86_64)    TRIPLE=x86_64-apple-darwin;       EXT=a;   GL_STD=gl ;;
    macos-aarch64)   TRIPLE=aarch64-apple-darwin;      EXT=a;   GL_STD=gl ;;
    windows-x86_64)  TRIPLE=x86_64-pc-windows-msvc;    EXT=lib; GL_STD=gl ;;
    *) echo "unknown PLATFORM=$PLATFORM"; exit 2 ;;
esac

SRC=src/canvas
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/Brooooooklyn/canvas.git "$SRC"
fi
git -C "$SRC" checkout -q "$CANVAS_SHA"

# Full Skia source checkout (needed to BUILD, not just headers).
if [ ! -e "$SRC/skia/.git" ]; then
    git clone https://github.com/google/skia.git "$SRC/skia"
fi
git -C "$SRC/skia" fetch -q origin "$SKIA_SHA" || git -C "$SRC/skia" fetch -q origin
git -C "$SRC/skia" checkout -q "$SKIA_SHA"

# ── Patches (idempotent: revert tracked files first) ─────────────────────────
git -C "$SRC" checkout -q Cargo.toml build.rs scripts/build-skia.js skia-c/skia_c.cpp skia-c/skia_c.hpp src/sk.rs src/ctx.rs src/lib.rs 2>/dev/null || true
patch -d "$SRC" -p1 -s < "$PWD/patches/staticlib.patch"
patch -d "$SRC" -p1 -s < "$PWD/patches/aarch64-native.patch"
# Ganesh GPU surface API + GN flags (skia_use_gl/enable_ganesh/gl_standard).
patch -d "$SRC" -p1 -s < "$PWD/patches/ganesh-gpu.patch"

# ── Skia build deps (gn, ninja, depot_tools sync) ────────────────────────────
SK="$SRC/skia"
export PATH="$PWD/$SK/bin:$PATH"
# Windows GHA bash has `python`, not `python3`; macOS/Linux have `python3`.
PY=python3; command -v python3 >/dev/null || PY=python
if [ ! -x "$SK/bin/gn" ] && [ ! -x "$SK/bin/gn.exe" ]; then
    "$PY" "$SK/bin/fetch-gn"
fi
command -v ninja >/dev/null || "$PY" "$SK/bin/fetch-ninja" || true
# Sync third_party/externals (the part the old header-only checkout skipped).
# Skip if already synced — git-sync-deps also runs DEPS hooks (e.g. emsdk
# activation) we don't need for a native build, and those can fail on newer
# python. We only need the source externals, not the WASM/emsdk toolchain.
if [ ! -d "$SK/third_party/externals/harfbuzz" ] || \
   [ ! -d "$SK/third_party/externals/freetype" ]; then
    # GIT_SYNC_DEPS_SKIP_EMSDK: skip the emsdk activation hook — it's only for
    # Skia's WASM build (we build native) and fails on newer python (3.14).
    # Retry: git-sync-deps fetches ~40 repos from googlesource and gives up on
    # the first DNS/network hiccup (seen flaking on CI runners), so retry a few
    # times — re-runs are cheap (already-synced repos are skipped).
    synced=0
    for attempt in 1 2 3 4 5; do
        if GIT_SYNC_DEPS_SKIP_EMSDK=1 "$PY" "$SK/tools/git-sync-deps"; then
            synced=1; break
        fi
        echo "git-sync-deps attempt $attempt failed; retrying in 15s..."
        sleep 15
    done
    [ "$synced" = 1 ] || { echo "FATAL: git-sync-deps failed after retries"; exit 1; }
fi

# ── Build Skia from source with Ganesh (per-platform GL dialect) ─────────────
# scripts/build-skia.js drives gn gen + ninja with the patched (Ganesh) GN args.
# It reads CANVAS_SKIA_GL_STANDARD for the dialect and the cross target via its
# own --target arg (android/aarch64 handling lives there).
# Only pass a cross --target when actually cross-compiling. linux-aarch64 runs on
# a NATIVE arm64 runner (ubuntu-22.04-arm), so passing the cross target makes
# build-skia.js use a cross-sysroot path that doesn't exist (sys/types.h not
# found). Android is a genuine cross-compile (NDK).
SKIA_TARGET_ARG=""
case "$PLATFORM" in
    android-aarch64) SKIA_TARGET_ARG="--target=aarch64-linux-android" ;;
esac
( cd "$SRC" && SKIP_SYNC_SK_DEPS=0 CANVAS_SKIA_GL_STANDARD="$GL_STD" \
    node scripts/build-skia.js $SKIA_TARGET_ARG ) || true
# build-skia.js may exit non-zero on the unrelated fiddle_examples link target;
# the .a archives we need are produced regardless. Build them explicitly to be
# sure (and to surface a REAL failure if libskia.a is missing).
STATIC="$SK/out/Static"
ninja -C "$STATIC" skia skshaper svg skottie sksg skresources skparagraph \
    skunicode_core skunicode_icu jsonreader
# Skia's main archive is libskia.a (Unix) or skia.lib (Windows/MSVC).
if [ "$EXT" = "lib" ]; then SKIA_LIB="$STATIC/skia.lib"; else SKIA_LIB="$STATIC/libskia.a"; fi
[ -f "$SKIA_LIB" ] || { echo "FATAL: $(basename "$SKIA_LIB") not built"; exit 1; }
# Sanity: confirm Ganesh got compiled in (GPU backend symbols present). The
# names are C++-mangled in the archive, so match the mangled substrings. Use
# grep -c (not -q): under `set -o pipefail`, grep -q exits on first match and
# SIGPIPEs the large nm output (141), which would fail the pipeline spuriously.
# llvm-nm reads both ELF .a and COFF .lib; fall back to nm on Unix.
NM=nm; command -v llvm-nm >/dev/null && NM=llvm-nm
GANESH_SYMS=$($NM "$SKIA_LIB" 2>/dev/null | grep -c "GrDirectContext" || true)
[ "$GANESH_SYMS" -ge 1 ] \
    || { echo "FATAL: Ganesh symbols missing from $(basename "$SKIA_LIB") (CPU-only build?)"; exit 1; }

# ── Rust staticlib (CANVAS_SKIA_GANESH=1 -> SK_GANESH/SK_GL compile defines) ──
cd "$SRC"
rustup target add "$TRIPLE" 2>/dev/null || true
# lto=false: fat-LTO bitcode archives are unusable downstream; strip=none
# keeps napi_register_module_v1. Env vars outrank the manifest profile.
CANVAS_SKIA_GANESH=1 \
CARGO_PROFILE_RELEASE_LTO=false \
CARGO_PROFILE_RELEASE_STRIP=none \
cargo build --release --target "$TRIPLE"

# ── Package ──────────────────────────────────────────────────────────────────
cd ../..
OUT="out/$PLATFORM"
rm -rf "$OUT"
mkdir -p "$OUT/skia" "$OUT/js" "$OUT/include"
if [ "$EXT" = "lib" ]; then
    cp "$SRC/target/$TRIPLE/release/canvas.lib" "$OUT/libcanvas.lib"
else
    cp "$SRC/target/$TRIPLE/release/libcanvas.a" "$OUT/"
fi
# Ship the Ganesh-built Skia archives (.a on Unix, .lib on Windows), matching
# the layout downstream CMake globs.
for f in "$STATIC"/*."$EXT"; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/skia/$(basename "$f")"
done
cp "$STATIC/icudtl.dat" "$OUT/skia/" 2>/dev/null || true
cp "$SRC/skia-c/skia_c.hpp" "$OUT/include/"
cp "$SRC/index.js" "$SRC/geometry.js" "$SRC/load-image.js" "$OUT/js/"
printf "module.exports = process._linkedBinding('canvas');\n" > "$OUT/js/js-binding.js"
echo "$CANVAS_VERSION" > "$OUT/CANVAS_VERSION"
echo "$GL_STD" > "$OUT/SKIA_GL_STANDARD"

if [ "$EXT" = "a" ]; then
    SYMS=$($NM "$OUT"/libcanvas.a 2>/dev/null | grep -c 'T _\?napi_register_module_v1' || true)
    [ "$SYMS" -ge 1 ] || { echo "FATAL: napi_register_module_v1 missing"; exit 1; }
    # Confirm the GPU surface API made it in (Ganesh build, not the CPU stub).
    GPU_SYMS=$($NM "$OUT"/libcanvas.a 2>/dev/null | grep -c 'T _\?skiac_grcontext_make_gl' || true)
    [ "$GPU_SYMS" -ge 1 ] || { echo "FATAL: GPU surface API missing (Ganesh build?)"; exit 1; }
fi

tar czf "out/libcanvas-$PLATFORM.tar.gz" -C "$OUT" .
ls -lh "out/libcanvas-$PLATFORM.tar.gz"
