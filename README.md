<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/banner-dark.svg">
    <img alt="sifr-apps — built from zero" src=".github/banner-light.svg" width="100%">
  </picture>
</p>

# sifr-apps

[![ci](https://github.com/Sifr-Dev/CipherDesk/actions/workflows/ci.yml/badge.svg)](https://github.com/Sifr-Dev/CipherDesk/actions/workflows/ci.yml)

Applications built on the **Cipher** framework (in `../sifr-native`) the way an
app is built on Qt or GTK — except Cipher has no toolkit baggage: the GPU
(Wayland + Vulkan), the flexbox UI, the text engine, the widgets, the terminal
stack and the audio stack are all ours, and the apps consume the framework as
a path dependency. No dependency is allowed to sneak in: every exe here links
only libc and dlopen()s what it needs at runtime.

| App | What it is |
| --- | --- |
| `janus` | The flagship terminal — GPU-native, panes, tabs, themes (void/paper/ember), status bar with live RSS/throughput. Multiplexing is a built-in feature (panes), not a second app. Standalone: needs only the system Wayland loader and Vulkan (dlopen), nothing else |
| `rex` | Multiplexer *engine* (framework-level): JSON-lines over a unix socket — spawn/split/run/capture/attach, scrollback, 0600 socket, auto-spawn. Being folded in-process so Janus is fully self-contained; today Janus attaches to it |
| `nocturne` | Offline music player — from-zero FLAC decoder (bit-exact vs flac/ffmpeg), synced lyrics (LRC + embedded VORBIS LYRICS), M3U playlists, sample-exact crossfade, PulseAudio-simple output via dlopen; live: exit 0, track auto-advance at track end; offline WAV exactly 5.000000 s |

Build: `zig build` (requires the sibling `../sifr-native` checkout). Run:
`zig build run-janus` / `zig build run-nocturne -- arg`

## naming

Janus replaces the earlier `cipherterm` name. `rex` was our multiplexer — the
same name as the external terminal from the Ghostty team, which was a naming
collision; Janus is the Ghostty-terminal competitor and rex stays as Janus's
internal multiplexer engine until it is folded in-process.

## Create your own app

Any app you write gets the same treatment these four apps get: Vulkan on the
GPU, zero dependencies bundled, one binary that needs nothing installed but
the system Wayland loader (`libwayland-client`, present on every Wayland
session). Copy this repo as a template: path-depend on the framework like we
do (see `build.zig`), implement `onInit`/`onEvent`/`onFrame` on a struct,
call `cipher.runtime.run(...)`. `apps/hello.zig` in the framework repo is the
60-line canonical version of exactly that.

Janus is the reference terminal implementation; nocturne the reference
audio-heavy implementation; bench-hello the reference performance harness.

## benchmark

`bench/BENCH.md` — cipher vs GTK4 vs Qt6, same hello window, method + raw
numbers + honest reading. TL;DR: vibe is not the argument; the table is.

## license
`MIT` — see `LICENSE`.
