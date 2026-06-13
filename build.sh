#!/usr/bin/env bash
# Build @napi-rs/canvas as a static library for linking into jsgame-libretro.
# Skia comes PREBUILT from upstream's own skia-<sha> release (same pin we
# verified end-to-end) — only the Rust crate builds here. CI calls this script.
#
#   PLATFORM=linux-x86_64 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CANVAS_SHA=$(node -p "require('./versions.json').canvas")
SKIA_SHA=$(node -p "require('./versions.json').skia")
CANVAS_VERSION=$(node -p "require('./versions.json').canvasVersion")
PLATFORM="${PLATFORM:-linux-x86_64}"

# PLATFORM -> rust triple + upstream skia asset suffix
case "$PLATFORM" in
    linux-x86_64)   TRIPLE=x86_64-unknown-linux-gnu;  SUFFIX=linux-x64-gnu;    EXT=a ;;
    linux-aarch64)  TRIPLE=aarch64-unknown-linux-gnu; SUFFIX=linux-aarch64-gnu; EXT=a ;;
    android-aarch64) TRIPLE=aarch64-linux-android;    SUFFIX=android-aarch64;  EXT=a ;;
    macos-x86_64)   TRIPLE=x86_64-apple-darwin;       SUFFIX=darwin-x64;       EXT=a ;;
    macos-aarch64)  TRIPLE=aarch64-apple-darwin;      SUFFIX=darwin-aarch64;   EXT=a ;;
    windows-x86_64) TRIPLE=x86_64-pc-windows-msvc;    SUFFIX=win32-x64-msvc;   EXT=lib ;;
    *) echo "unknown PLATFORM=$PLATFORM"; exit 2 ;;
esac

SRC=src/canvas
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/Brooooooklyn/canvas.git "$SRC"
fi
git -C "$SRC" checkout -q "$CANVAS_SHA"
# skia headers (for skia-c compile) — sparse source checkout, no deps sync
if [ ! -e "$SRC/skia/.git" ]; then
    git clone --no-checkout https://github.com/google/skia.git "$SRC/skia"
fi
git -C "$SRC/skia" fetch -q --depth 1 origin "$SKIA_SHA" || git -C "$SRC/skia" fetch -q origin
git -C "$SRC/skia" checkout -q "$SKIA_SHA"

# staticlib patch (cdylib -> staticlib)
git -C "$SRC" checkout -q Cargo.toml
patch -d "$SRC" -p1 -s < "$PWD/patches/staticlib.patch"
# native-arm64 build.rs (upstream hardcodes a cross-sysroot Docker path)
git -C "$SRC" checkout -q build.rs
patch -d "$SRC" -p1 -s < "$PWD/patches/aarch64-native.patch"

# ── Prebuilt Skia archives from upstream's release ───────────────────────
SHORT=${SKIA_SHA:0:8}
STATIC="$SRC/skia/out/Static"
mkdir -p "$STATIC"
for lib in skia skshaper svg skottie sksg skresources skparagraph skunicode_core skunicode_icu jsonreader; do
    if [ "$EXT" = "lib" ]; then ASSET="${lib}-${SUFFIX}.lib"; LOCAL="${lib}.lib";
    else ASSET="lib${lib}-${SUFFIX}.a"; LOCAL="lib${lib}.a"; fi
    if [ ! -f "$STATIC/$LOCAL" ]; then
        echo "fetching $ASSET..."
        curl -sfL "https://github.com/Brooooooklyn/canvas/releases/download/skia-${SHORT}/${ASSET}" \
            -o "$STATIC/$LOCAL"
    fi
done
curl -sfL "https://github.com/Brooooooklyn/canvas/releases/download/skia-${SHORT}/icudtl.dat" \
    -o "$STATIC/icudtl.dat" || true

# ── Rust staticlib ───────────────────────────────────────────────────────
cd "$SRC"
rustup target add "$TRIPLE" 2>/dev/null || true
# lto=false: fat-LTO bitcode archives are unusable downstream; strip=none
# keeps napi_register_module_v1. Env vars outrank the manifest profile.
CARGO_PROFILE_RELEASE_LTO=false \
CARGO_PROFILE_RELEASE_STRIP=none \
cargo build --release --target "$TRIPLE"

# ── Package ──────────────────────────────────────────────────────────────
cd ../..
OUT="out/$PLATFORM"
rm -rf "$OUT"
mkdir -p "$OUT/skia" "$OUT/js" "$OUT/include"
if [ "$EXT" = "lib" ]; then
    cp "$SRC/target/$TRIPLE/release/canvas.lib" "$OUT/libcanvas.lib"
else
    cp "$SRC/target/$TRIPLE/release/libcanvas.a" "$OUT/"
fi
find "$STATIC" -maxdepth 1 -type f | xargs -I{} cp {} "$OUT/skia/"
cp "$SRC/skia-c/skia_c.hpp" "$OUT/include/"
cp "$SRC/index.js" "$SRC/geometry.js" "$SRC/load-image.js" "$OUT/js/"
printf "module.exports = process._linkedBinding('canvas');\n" > "$OUT/js/js-binding.js"
echo "$CANVAS_VERSION" > "$OUT/CANVAS_VERSION"

if [ "$EXT" = "a" ]; then
    NM=nm; command -v llvm-nm >/dev/null && NM=llvm-nm
    SYMS=$($NM "$OUT"/libcanvas.a 2>/dev/null | grep -c 'T _\?napi_register_module_v1' || true)
    [ "$SYMS" -ge 1 ] || { echo "FATAL: napi_register_module_v1 missing"; exit 1; }
fi

tar czf "out/libcanvas-$PLATFORM.tar.gz" -C "$OUT" .
ls -lh "out/libcanvas-$PLATFORM.tar.gz"
