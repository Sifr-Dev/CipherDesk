//! Platform helpers for the Janus application — no terminal or UI logic.
const std = @import("std");
const runtime = @import("term").runtime;

/// Resident-set size (KB) by reading /proc/self/status.
pub fn rssKb() u64 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = std.c.close(fd);
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(fd, buf[0..]) catch return 0;
    const s = buf[0..n];
    const idx = std.mem.indexOf(u8, s, "VmRSS:") orelse return 0;
    const rest = s[idx + 6 ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1) {}
    return std.fmt.parseInt(u64, rest[start..i], 10) catch 0;
}

/// Best-effort monospace font resolution.
pub fn pickMonoFont() []const u8 {
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
        "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
        runtime.DEFAULT_FONT,
    };
    for (candidates) |c| {
        if (std.posix.openat(std.posix.AT.FDCWD, c, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            _ = std.c.close(fd);
            return c;
        } else |_| {}
    }
    return runtime.DEFAULT_FONT;
}

/// $SHELL when set, else /bin/sh.
pub fn defaultShell() []const u8 {
    if (std.c.getenv("SHELL")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return s;
    }
    return "/bin/sh";
}
