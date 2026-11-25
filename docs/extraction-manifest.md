# Extracting the applications into their own repositories

This is the work list, ordered by what blocks what. It is grounded in the
current sources on `main` (`9756b41`) and in PR #1 (`689ccc8`); nothing here
claims a remote repository already exists.

Each step ends with something that can be checked locally. A step is done
when its check passes, not when a document says it is done.

## Step 1 — take the terminal off the engine socket

**Blocks:** a `janus` repository that can be installed on its own.

Today `janus` cannot start a pane without a `rex` binary beside it. The fix
already exists on `portfolio/janus-module-split` (PR #1, `689ccc8`): each pane
spawns its PTY in-process, so there is no engine process, no socket and no
`cipher-rex` string in the binary.

- **Prerequisite:** PR #1 is merged, or its Janus modules are re-applied on a
  new branch. This branch deliberately does not copy them, because that would
  duplicate an open review.
- **Check:** build `janus` alone, run it with no `rex` present, open a pane,
  run a command in it, close the pane. No engine process is started
  (`pgrep -f 'rex serve'` stays empty).
- **Then:** `janus` depends on the framework's `term` module only, and can be
  moved with its own `build.zig` and a test that renders a frame offscreen.

## Step 2 — move Nebula into its own product repository

**Blocks:** the independent Nebula multiplexer; also blocks the README being
truthful about names. Nebula is the product name. Rex is an external
competitor, not a SIFR project. The existing `rex` executable and protocol are
legacy compatibility details that need a deliberate migration.

`apps/rex.zig` is a CLI whose `serve` subcommand runs an engine implemented in
the framework (`src/term/server.zig`, 984 lines). Extracting only the CLI
yields a package that cannot function without the framework, which is where
the engine already lives.

- **Decide:** the product name (no rename is done here), and whether the
  server stays in the framework as a reusable library or moves into the
  product repository.
- **Check:** the chosen arrangement builds with the CLI and a server in one
  tree or one declared dependency, and `zig build test-e2e` still passes from
  this repository against it.
- **Then:** move `apps/rex.zig` plus `apps/mux/protocol.zig` (already shared
  and tested here) into that repository.

## Step 3 — decide where the audio stack lives

**Blocks:** a `nocturne` repository that can play a file.

`nocturne` imports 1146 lines of framework audio code (`src/audio/flac.zig`,
`lrc.zig`, `wav.zig`, `pulse.zig`, `playlist.zig`, `player.zig`) and contains
almost no decoding of its own.

- **Decide:** keep audio as a framework library that `nocturne` depends on
  (simplest, and consistent with the other apps), or move it into the player.
- **Check:** whichever is chosen, the FLAC decode path has a test that
  compares decoded samples against a reference and runs without audio
  hardware.
- **Then:** `nocturne` can be moved, with its dependency stated in its own
  `build.zig`.

## Step 4 — one repository per shipped program

**Blocks:** independent release schedules and independent CI.

- **Prerequisite:** steps 1–3 resolved for the program being moved.
- **Check:** the new repository builds from a clean clone with only a
  documented framework path, its tests pass, and it produces the same binary
  as this repository did.
- **Then:** remove the moved program from this repository's `build.zig` in the
  same change that adds it to its new home, so there is never a period with
  two sources of truth.

`bench-hello` is a benchmark, not a shipped program. It should stay with the
benchmark documentation until it has a reason to ship.

## What is already done here

- The build takes the framework location as an option, so a program can be
  built against a specific framework checkout from another directory.
- The multiplexer wire protocol is written down once (`apps/mux/protocol.zig`)
  and used by the CLI, with 17 unit tests.
- The multiplexer lifecycle has a headless test (`zig build test-e2e`) that
  spawns, runs, captures, resizes, splits and closes real panes: 18 checks.

Those three are useful to any of the extraction steps above; none of them
pretends a repository exists.
