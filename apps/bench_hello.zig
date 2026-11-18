//! bench-hello — heavy immediate-mode scene used for runtime performance
//! comparisons. Declares a panel with ~100 controls (40 buttons, 10
//! checkboxes, 10 sliders, ~10 labels) every frame, lays out and emits quads
//! via the framework, and reports per-frame CPU time (declaration + layout +
//! quad emission). The widget workload is fixed at runtime — identical
//! declaration cost every frame; pair with bench/bench_qt_heavy.cpp for the
//! Qt6 side of the comparison.
const std = @import("std");
const cipher = @import("cipher");

const BTN_N = 40;
const CHK_N = 10;
const SLD_N = 10;

fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

pub const Bench = struct {
    clicks: u32 = 0,
    checks: [CHK_N]bool = undefined,
    sliders: [SLD_N]f32 = undefined,
    frames: u32 = 0,
    frame_ns: u64 = 0,
    win_frames: u32 = 0,
    win_ns: u64 = 0,

    pub fn onEvent(self: *Bench, rt: *cipher.runtime.Runtime, ev: cipher.input.Event) void {
        switch (ev) {
            .key => |k| {
                if (k.pressed and k.key == .esc) rt.requestQuit();
            },
            .close => rt.requestQuit(),
            else => {},
        }
        _ = self;
    }

    pub fn onFrame(self: *Bench, rt: *cipher.runtime.Runtime) !void {
        const t0 = nowNs();
        const u = rt.ui() orelse return;
        self.frames += 1;
        try u.panel(.{ .fixed = 900 }, .{ .fixed = 560 }, 6, 2);
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            var buf: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "bench row {d} — the quick brown fox jumps over the lazy dog {d}", .{ i, i }) catch unreachable;
            try u.label(s, cipher.ui.COLOR_TEXT_DIM);
        }
        i = 0;
        while (i < BTN_N) : (i += 1) {
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "Button {d}", .{i}) catch unreachable;
            if (try u.button(s)) self.clicks += 1;
        }
        i = 0;
        while (i < CHK_N) : (i += 1) {
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "check {d}", .{i}) catch unreachable;
            _ = try cipher.widgets.checkbox(u, s, &self.checks[i]);
        }
        i = 0;
        while (i < SLD_N) : (i += 1) {
            _ = try cipher.widgets.slider(u, 200, 0, 100, &self.sliders[i]);
        }
        u.endPanel();
        const dt: u64 = @intCast(nowNs() - t0);
        self.frame_ns += dt;
        self.win_frames += 1;
        self.win_ns += dt;
        if (self.win_frames >= 120) {
            const avg_ms = @as(f64, @floatFromInt(self.win_ns)) / @as(f64, @floatFromInt(self.win_frames)) / 1e6;
            std.debug.print("BENCHHELLO frames={d} avg_onframe_ms={d:.3} total_ns={d}\n", .{ self.frames, avg_ms, self.frame_ns });
            self.win_frames = 0;
            self.win_ns = 0;
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var app = Bench{};
    for (&app.checks) |*c| c.* = false;
    for (&app.sliders) |*s| s.* = 50;
    try cipher.runtime.run(Bench, &app);
}
