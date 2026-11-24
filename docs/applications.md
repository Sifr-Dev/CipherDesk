# Application products in this repository

This repository currently builds four programs against the Cipher framework:

| Program | Source | Size | Framework modules | What it is |
| --- | --- | --- | --- | --- |
| `janus` | `apps/janus.zig` | 857 lines | `term` | GPU terminal window: renders a VT grid, tabs, status bar, selection |
| `rex` | `apps/rex.zig` | 459 lines | `term`, `mux` | Multiplexer engine and CLI: owns PTYs, serves JSON lines on a unix socket |
| `nocturne` | `apps/nocturne.zig` | 545 lines | `cipher`, `audio` | Offline music player: FLAC, lyrics, playlists, crossfade |
| `bench-hello` | `apps/bench_hello.zig` | 88 lines | `cipher` | Window benchmark used in `bench/BENCH.md`, not shipped to users |

`apps/mux/protocol.zig` is shared by `rex` and the tests. `apps/mux/e2e_test.zig`
is a test only.

## What is already separate

Each program is its own executable with its own `main`. `zig build` produces
four independent binaries, and nothing links them together:

```
zig build -Dcipher-root=/path/to/cipher
zig-out/bin/{janus,rex,nocturne,bench-hello}
```

`janus`, `nocturne` and `bench-hello` link only `libc`; Wayland and Vulkan are
opened at runtime with `dlopen`. None of them includes another app's source.

## What is not separate yet

Three concrete dependencies exist today. Each is a prerequisite for moving a
program into its own repository, and each can be resolved on its own.

### 1. The terminal starts the multiplexer

`apps/janus.zig` is a client of the `rex` engine, not a self-contained
terminal. When no engine answers on the socket it looks for a `rex` binary
next to itself and executes it:

```
apps/janus.zig:128-170   ensureServer(): reads /proc/self/exe, execs "<dir>/rex serve --socket PATH"
apps/janus.zig:37-118   sockConnect/sockWriteAll/sockReadLine: JSON-lines client
apps/janus.zig:759-762   default socket: $CIPHER_REX_SOCK, else $XDG_RUNTIME_DIR/cipher-rex.sock
```

The dependency is visible in the source: on `main`, 9 lines of `apps/janus.zig`
mention `rex` and 2 contain the `cipher-rex` socket name. The Janus code on the
`portfolio/janus-module-split` branch (`689ccc8`, PR #1) removes it: it spawns
one PTY per pane in-process and has no socket, engine reference or
`cipher-rex` string at all (`git grep -c cipher-rex origin/portfolio/janus-module-split -- apps/janus/`
finds nothing). The built binaries agree: `strings zig-out/bin/janus` contains
`/cipher-rex.sock` and `/run/user/1000/cipher-rex.sock` on `main`, and no
`cipher-rex` string on the PR #1 branch (checked in ReleaseSafe for both, so
the comparison is not a build-mode artifact).

So the two products are separable — but the separation lives in PR #1, not on
`main`. Until that work is merged, `janus` and `rex` must ship and version
together.

### 2. `rex` is both an engine and a CLI

`apps/rex.zig` contains the `serve` subcommand that runs the engine, and the
client subcommands (`ls`, `spawn`, `send`, ...) that talk to it. The engine
implementation itself lives in the framework (`term.server`); this repository
only has the front end.

Before the engine can be its own repository, it needs an owner for the server
side. Moving the front end alone would produce a package that cannot start
anything without the framework, which is where the server code already is.

### 3. `nocturne`'s audio stack is framework code

`nocturne` imports `audio` (FLAC decoder, LRC parser, WAV reader, PulseAudio
binding, playlist, player) from the framework, 1306 lines in
`src/audio/`. It contains almost no decoder logic of its own. Moving the app
without moving or depending on that module yields a player that cannot play.

## Naming

`rex` is our multiplexer engine's current name. The same name is used by an
unrelated external terminal project, and it has been read as the product name
for this repository's multiplexer. The multiplexer product needs its own name
chosen deliberately; a search-and-replace is not a decision, and no rename is
made here. `README.md` still describes `rex` and should be corrected when the
product name is settled.

## Rules that keep this from drifting

- One program, one `main`, one repository when it ships on its own schedule.
- A shared module goes in `apps/mux/` (or the framework) and is imported, never
  copied between apps.
- Product behaviour is covered by a test that runs without a display before
  the product is called independent.
- `zig build test` and `zig build test-e2e` must keep passing; they are the
  current evidence that the multiplexer still works.
