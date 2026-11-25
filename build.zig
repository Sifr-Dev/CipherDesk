// sifr-apps — applications built ON the Cipher framework as an external
// dependency. The framework sources are not copied here; its modules are
// referenced by path from the sibling sifr-native checkout, exactly like an
// app linking against a framework library.
//
// Framework location: defaults to ../sifr-native (the documented layout) and
// can be pointed at any verified framework checkout:
//
//   zig build -Dcipher-root=/path/to/cipher-checkout
//
// That keeps this repository independent of one developer's directory
// layout and lets CI test this repo against a pinned framework candidate
// without moving or copying framework sources into it.
const std = @import("std");

const default_fw_root = "../sifr-native";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fw_root = b.option(
        []const u8,
        "cipher-root",
        "Path to a Cipher framework checkout (default: ../sifr-native)",
    ) orelse default_fw_root;
    // Absolute paths are accepted verbatim; relative ones stay relative to
    // the repository root so `zig build` works from the checkout directory.
    const fw_src = struct {
        fn file(root: []const u8, bld: *std.Build, name: []const u8) []const u8 {
            return bld.fmt("{s}/src/{s}", .{ root, name });
        }
    }.file;

    // Framework modules, imported by path from the framework checkout.
    const cipher_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = fw_src(fw_root, b, "cipher.zig") },
        .target = target,
        .optimize = optimize,
    });
    cipher_mod.link_libc = true;
    cipher_mod.addAnonymousImport("resources", .{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{fw_root}) } });

    const term_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = fw_src(fw_root, b, "term_api.zig") },
        .target = target,
        .optimize = optimize,
    });
    term_mod.link_libc = true;
    term_mod.addAnonymousImport("resources", .{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{fw_root}) } });

    const audio_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = fw_src(fw_root, b, "audio_api.zig") },
        .target = target,
        .optimize = optimize,
    });
    audio_mod.link_libc = true;
    audio_mod.addAnonymousImport("resources", .{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{fw_root}) } });

    // The shared multiplexer wire contract (apps/mux/protocol.zig). Both the
    // engine CLI and the unit tests use this one module, so the protocol
    // cannot drift between them.
    const mux_mod = b.createModule(.{
        .root_source_file = b.path("apps/mux/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    mux_mod.link_libc = true;
    mux_mod.addImport("term", term_mod);

    // rex — the multiplexer server + scriptable CLI (JSON-lines over a unix socket).
    const rex_mod = b.createModule(.{
        .root_source_file = b.path("apps/rex.zig"),
        .target = target,
        .optimize = optimize,
    });
    rex_mod.link_libc = true;
    rex_mod.addImport("term", term_mod);
    rex_mod.addImport("mux", mux_mod);
    const rex = b.addExecutable(.{ .name = "rex", .root_module = rex_mod });
    b.installArtifact(rex);
    const run_rex = b.addRunArtifact(rex);
    b.step("run-rex", "Run the rex CLI (args after --)").dependOn(&run_rex.step);

    // Janus — the Cipher GPU-native terminal (panes, themes, status bar).
    const janus_mod = b.createModule(.{
        .root_source_file = b.path("apps/janus/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    janus_mod.link_libc = true;
    janus_mod.addImport("term", term_mod);
    const janus = b.addExecutable(.{ .name = "janus", .root_module = janus_mod });
    b.installArtifact(janus);
    const run_janus = b.addRunArtifact(janus);
    b.step("run-janus", "Run the Janus terminal (args after --)").dependOn(&run_janus.step);

    // nocturne — offline music player (FLAC, lyrics, crossfade, playlists).
    // bench-hello — heavy-scene runtime-performance benchmark (not shipped UI).
    const bh_mod = b.createModule(.{
        .root_source_file = b.path("apps/bench_hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    bh_mod.link_libc = true;
    bh_mod.addImport("cipher", cipher_mod);
    const bh = b.addExecutable(.{ .name = "bench-hello", .root_module = bh_mod });
    b.installArtifact(bh);

    const noc_mod = b.createModule(.{
        .root_source_file = b.path("apps/nocturne.zig"),
        .target = target,
        .optimize = optimize,
    });
    noc_mod.link_libc = true;
    noc_mod.addImport("cipher", cipher_mod);
    noc_mod.addImport("audio", audio_mod);
    const noc = b.addExecutable(.{ .name = "nocturne", .root_module = noc_mod });
    b.installArtifact(noc);
    const run_noc = b.addRunArtifact(noc);
    b.step("run-nocturne", "Run the nocturne music player (args after --)").dependOn(&run_noc.step);

    // ---- tests -------------------------------------------------------
    //
    // `test` runs pure unit tests for the multiplexer wire contract: no
    // display, no GPU, no sockets, no process spawn, so it is safe to run
    // anywhere. It does not run the GUI apps.
    const test_step = b.step("test", "Run unit tests (multiplexer protocol contract)");

    const protocol_tests = b.addTest(.{
        .name = "mux-protocol-test",
        .root_module = mux_mod,
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    const e2e_step = b.step("test-e2e", "Run the headless multiplexer product test (real rex engine)");

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("rex_exe", rex.getEmittedBin());
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("apps/mux/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.link_libc = true;
    e2e_mod.addImport("term", term_mod);
    e2e_mod.addImport("build_options", e2e_options.createModule());
    const e2e_tests = b.addTest(.{
        .name = "mux-e2e-test",
        .root_module = e2e_mod,
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    e2e_step.dependOn(&run_e2e_tests.step);
    // The test spawns this exact artifact, so build it first.
    e2e_tests.step.dependOn(&rex.step);
}
