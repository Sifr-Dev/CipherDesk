# Cipher framework — speed & footprint vs GTK4 / Qt6

Machine: Arch Linux, Ryzen 7 7435HS, RTX 4060 (NVIDIA 620.70.06), umbriel
compositor, Wayland. Date: 2026-11-17.

## What is compared

A minimal "hello" window with one button + one frame counter, 120 frames, then
quit — identical scope in all three:

| App | Built with | Source |
| --- | --- | --- |
| cipher-hello | Cipher framework (debug, zig 0.17.1), Vulkan+Wayland | `sifr-native/apps/hello.zig` |
| bench_gtk | GTK 4.24.1, C, `gcc -O2` | `bench/bench_gtk.c` |
| bench_qt | Qt 6.12, C++, `g++ -O2 -fPIC` | `bench/bench_qt.cpp` |

## Results (3 runs each, umbriel/NVIDIA)

| Metric | cipher-hello | GTK4 | Qt6 |
| --- | --- | --- | --- |
| Frames self-timed to 120 | n/a (WAYLAND_PROTOCOL_OK) | 2125 / 2127 / 2283 ms | 1943 / 1945 / 1998 ms |
| Wall clock incl. process exec | 2344 / 2358 / 2386 ms | 2239 / 2268 / 2277 ms | 1961 / 1961 / 1962 ms |
| Peak RSS (VmHWM, external poll / self-report) | 286 MB | 300–326 MB | 47–48 MB |
| Linked libraries (`ldd`) | **4** (libc, libm, ld-linux, vdso) | 113 | 45 |
| Binary size (unstripped) | 13.2 MB (debug symbols) | 17.6 KB | 23.6 KB |
| Toolkit runtime deps | **none** (Wayland/Vulkan are dlopen'd) | libgtk-4 + cairo/pango/harfbuzz/gdk-pixbuf/… | libQt6Widgets/Gui/Core + libstdc++… |

## Honest interpretation

- **Dependency footprint is the decisive win.** A Cipher app links libc/libm
  only; Wayland and Vulkan are dlopen'd at runtime (so the ABI is whatever the
  driver exposes, and a missing GPU path degrades to software shm instead of
  failing to start). GTK4 pulls 113 runtime library mappings, Qt6 45.
- **Startup speed is on par, not better** — cipher is within ~5% of GTK4 and
  ~20% slower than Qt6 here (debug build; ReleaseFast is currently unstable on
  the NVIDIA Vulkan path, a tracked issue).
- **Peak RSS ≈ GTK4** (~285–305 MB). This is the NVIDIA Vulkan driver's
  allocation floor on this machine, not application memory: cipher-hello,
  cipherterm and nocturne all sit at ~250–305 MB, i.e. ~20 MB above the floor
  (10k-line slab grid + 64k quad buffer + text atlas + s16 audio copies).
  Qt6's ~48 MB reflects a different (lighter) driver path on this box; GTK4 on
  the same Vulkan path pays the same ~300 MB. We are not yet "leaner than Qt"
  here and we do not claim it.
- **Binary strip**: unstripped debug binaries are large; `-Dstrip` would drop
  tens of MB. Not measured yet.

## Reproduce

    gcc -O2 -o bench_gtk bench_gtk.c $(pkg-config --cflags --libs gtk4)
    g++ -O2 -fPIC -o bench_qt bench_qt.cpp $(pkg-config --cflags --libs Qt6Widgets)
    CIPHER_MAX_FRAMES=120 ../../sifr-native/zig-out/bin/cipher-hello
    ./bench_gtk && ./bench_qt

## Release-mode stability (fixed 2026-11-17, verified)

Root cause of the ReleaseFast segfaults: `Runtime`/`GpuText`/`FramePipeline`
were built from `undefined` bases — fields not covered by their literal/init
code contained stack garbage, and the GPU block sometimes failed outright
("GpuText.init: NoSuitableMemoryType" — DEVICE_LOCAL image reqs read from a
garbage `atlas_image` handle) or corrupted the teardown allocator
(`Ui.deinit` freeing a garbage vtable). Fixed by zero-initializing the three
bases (`core/types.zig: zeroed`, `gpu/vulkan/zero.zig: zeroed`) and keeping
complete field coverage thereafter. Evidence (2026-11-17):

- ReleaseFast: 10/10 consecutive `cipher-hello` runs `vulkan-gpu-ui`, exit 0
- ReleaseSafe: 3/3, Debug: exit 0, `zig build test` exit 0 (cached)
- Debug/Safe/ReleaseFast all render `WAYLAND_PROTOCOL_OK` frames and complete

## What would make Cipher strictly faster/leaner (tracked, not done)

- software-shm frame present (onFrame never runs there, so benchmarks/apps
  starve) — the fallback exists for correctness, not speed
- `-Dstrip` size measurement
- startup time parity with Qt6 (currently ~20% slower; debug build)
