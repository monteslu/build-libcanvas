# build-libcanvas

Pre-built static libraries of [@napi-rs/canvas](https://github.com/Brooooooklyn/canvas)
(Skia + Rust N-API layer) for embedding via `node::AddLinkedBinding`.
Used by [jsgame-libretro](https://github.com/monteslu/jsgame-libretro).

Same model as build-libnode: build once per platform in CI, downstream fetches
binaries from GitHub Releases.

**Skia is built FROM SOURCE with the Ganesh GL backend** (`skia_use_gl=true`),
not the upstream CPU-only prebuilts — jsgame's 3D-composite path uses GPU-backed
Skia surfaces (`SkSurfaces::RenderTarget`) so `drawImage(webglCanvas)` + HUD
composite GPU-to-GPU with no readback. The GPU surface C/Rust API is added by
`patches/ganesh-gpu.patch`. The CPU raster path is unchanged (GPU is additive,
gated on a `GrDirectContext` being supplied).

Skia's GL dialect (`skia_gl_standard`) is chosen per platform in `build.sh`:
`gles` for Android (real GLES3), `gl` for desktop GL-core (linux/macos/windows).
A mismatch makes Ganesh shader-draws silently no-op at runtime.

## What's in each archive

```
libcanvas.a        # Rust crate as staticlib (exports napi_register_module_v1)
skia/*.a           # Skia + bundled third-party static archives
js/                # index.js, geometry.js, load-image.js,
                   # js-binding.js (patched: process._linkedBinding('canvas'))
include/skia_c.hpp
CANVAS_VERSION
```

## Embedding

```cpp
extern "C" napi_value napi_register_module_v1(napi_env env, napi_value exports);
node::AddLinkedBinding(env, "canvas", napi_register_module_v1);
```

Link `libcanvas.a` with `--whole-archive` (napi-rs registers classes via ctor
initializers; without it class constructors silently vanish) and the `skia/*.a`
archives normally. `canvas.data()` returns RGBA byte order.

## Build locally

```bash
./build.sh                      # current platform → out/libcanvas-<platform>.tar.gz
```

Requires clang/clang++ 19 (+ libc++-19-dev on Linux), rust, node 22, ninja,
python3, nasm (2.x — 3.x is rejected by libaom's probe; yasm also works), git.

## Pins

`versions.json` pins the upstream canvas commit, Skia commit, and depot_tools
commit. The skia pin may be newer than upstream's recorded submodule gitlink —
it pins the combination actually verified end-to-end.

## Releases

Tag push (`vX.Y.Z-jsgN`) builds all matrix targets and attaches archives to a
GitHub Release. Targets: linux-x86_64 live; linux-aarch64, windows-x86_64,
macos-x86_64, macos-aarch64, android-aarch64 planned (PLAN §15 in jsgame-libretro).
