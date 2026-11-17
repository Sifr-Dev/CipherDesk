<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/banner-dark.svg">
    <img alt="sifr-apps — built from zero" src=".github/banner-light.svg" width="100%">
  </picture>
</p>

# sifr-apps

Applications built on the **Cipher** framework (in `../sifr-native`) the way an
app is built on Qt or GTK — except Cipher has no toolkit baggage: the GPU
(Wayland + Vulkan), the flexbox UI, the text engine, the widgets, the terminal
stack and the audio stack are all ours, and the apps consume the framework as
a path dependency. No dependency is allowed to sneak in: every exe here links
only libc and dlopen()s what it needs at runtime.

| App | What it is |
| --- | --- |
| `rex` | Multiplexer server + scriptable CLI (JSON-lines over a unix socket): spawn/split/run/capture/attach, scrollback, 0600 socket, auto-spawn |
| `cipherterm` | GPU terminal client — fork in spirit, not in code. Tab bar of panes, status bar with live RSS/throughput, runtime themes (void/paper/ember), Ctrl+Tab pane cycling, scrollback, drag-select clipboard, bracketed paste, file-drop→pane. Renders via the framework's `extra_quads` hook |
| `nocturne` | Offline music player — from-zero FLAC decoder (bit-exact vs flac/ffmpeg), synced lyrics (LRC + embedded VORBIS LYRICS), M3U playlists, sample-exact crossfade, PulseAudio-simple output via dlopen; live: exit 0, track auto-advance at track end; offline WAV exactly 5.000000 s |

Build: `zig build` (requires the sibling `../sifr-native` checkout). Run:
`zig build run-rex -- ls` / `zig build run-cipherterm` / `zig build run-nocturne -- arg`

## benchmark

`bench/BENCH.md` — cipher vs GTK4 vs Qt6, same hello window, method + raw
numbers + honest reading. TL;DR: vibe is not the argument; the table is.

## license
`MIT` — see `LICENSE`.
