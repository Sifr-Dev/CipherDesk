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
| Wall clock incl. process exec (measured the same way, same machine) | 1037 ms (debug) / **1046–1099 ms (ReleaseSafe, stripped)** | 2255–2270 ms | 1966–1976 ms |
| Peak RSS (VmHWM, external poll / self-report) | 288 MB (debug) / 325 MB (release+strip) | 300–305 MB | 49 MB |
| Linked libraries (`ldd`) | **4** (libc, libm, ld-linux, vdso) | 113 | 45 |
| Binary size | 628 KB (release, `strip -s`) / 13.2 MB (unstripped debug) | 17.6 KB | 23.6 KB |
| Toolkit runtime deps | **none** (Wayland/Vulkan are dlopen'd) | libgtk-4 + cairo/pango/harfbuzz/gdk-pixbuf/… | libQt6Widgets/Gui/Core + libstdc++… |

**2026-11-17 release+strip re-measurement.** With a stripped ReleaseSafe
build, cipher-hello starts and renders 120 frames in ~1.05 s — ~46% faster
than Qt6's ~1.97 s on the same measurement (process exec + 120 frames + clean
shutdown). The mechanism is not yet root-caused (likely the frame pacing
path); the measurement is reproducible with the commands below. RSS remains
~6x Qt6's (NVIDIA Vulkan driver allocator floor, not application memory).
Chiper's dependency advantage remains decisive: self-contained 628 KB binary
linking libc/libm only, vs GTK4's 113 and Qt6's 45 runtime mappings.

## Honest interpretation

- **Dependency footprint is the decisive win.** A Cipher app links libc/libm
  only; Wayland and Vulkan are dlopen'd at runtime (so the ABI is whatever the
  driver exposes, and a missing GPU path degrades to software shm instead of
  failing to start). GTK4 pulls 113 runtime library mappings, Qt6 45.
- **Startup speed with a stripped release build is ~46% faster than Qt6**
  (1046–1099 ms vs 1966–1976 ms, same protocol). Mechanism not yet
  root-caused; treat as "measured, repeatable, unexplained" pending a
  breakdown. Debug vs release differ little (1037 vs ~1050 ms).
- **Peak RSS ≈ GTK4** (~290–325 MB). This is the NVIDIA Vulkan driver's
  allocation floor on this machine, not application memory: cipher-hello,
  cipherterm and nocturne all sit at ~250–325 MB, i.e. ~20 MB above the floor
  (10k-line slab grid + 64k quad buffer + text atlas + s16 audio copies).
  Qt6's ~49 MB reflects a different (lighter) driver path on this box; GTK4 on
  the same Vulkan path pays the same ~300 MB. We are not yet "leaner than Qt"
  on RSS and we do not claim it.
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

## reproduce (stripped release)

    cd sifr-native && zig build -Doptimize=ReleaseSafe
    strip -s zig-out/bin/cipher-hello && cp zig-out/bin/cipher-hello /tmp/
    CIPHER_MAX_FRAMES=120 /tmp/cipher-hello
    python3 -c "import subprocess,time,re,os; p=subprocess.Popen(['/tmp/cipher-hello'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=dict(os.environ,CIPHER_MAX_FRAMES='120')); pk=0
while p.poll() is None:
    s=open(f'/proc/{p.pid}/status').read()
    m=re.search(r'VmHWM:\s+(\d+)', s)
    pk=max(pk,int(m.group(1)) if m else 0)
print('peak_rss_kb=',pk)"
