//! cipherterm — the Cipher framework's own GPU terminal (not an xterm fork).
//!
//!   cipherterm [pane] [--socket PATH]
//!
//! Attaches to panes over the rex unix socket (auto-spawned if absent),
//! mirrors each pane's VT stream in local Grids, and renders per vsync as
//! GPU quads through the framework's extra_quads hook. Framework-afforded
//! features no standalone terminal gets for free:
//!   - pane tab bar (Ctrl+T cycles attached pane; framework UI widgets)
//!   - status bar: live RSS, throughput, theme name, server socket
//!   - runtime theme cycling (`t`): void / paper / ember
//!   - Ctrl+W closes pane, wheel = scrollback, drag-select = clipboard,
//!     paste / file-drop sent to the pane (bracketed paste aware).
//!   - Ctrl+F toggles follow mode (re-attach on server resize).
const std = @import("std");
const term = @import("term");

const runtime = term.runtime;
const input = term.input;
const gpu_text = term.gpu_text;
const json = term.json;
const grid_mod = term.grid;
const vt = term.vt;
const render = term.render;
const pty_mod = term.pty;

const MAX_QUADS: usize = 65536;

fn childFail() noreturn {
    _ = std.os.linux.exit(127);
}

fn sockConnect(path: []const u8) !i32 {
    const fd_rc = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_rc);
    var addr: std.os.linux.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.os.linux.AF.UNIX;
    if (path.len >= addr.path.len) {
        _ = std.os.linux.close(fd);
        return error.NameTooLong;
    }
    @memcpy(addr.path[0..path.len], path);
    const rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
    if (@as(i64, @bitCast(rc)) < 0) {
        const e = std.os.linux.errno(rc);
        _ = std.os.linux.close(fd);
        if (e == .AGAIN or e == .INPROGRESS) {
            // nonblocking connect: poll for writability
            var fds = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.OUT, .revents = 0 }};
            const prc = std.os.linux.poll(&fds, 1, 2000);
            if (@as(i64, @bitCast(prc)) <= 0) return error.ConnectFailed;
        } else return error.ConnectFailed;
    }
    return fd;
}

fn sockWriteAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (@as(i64, @bitCast(rc)) < 0) {
            const e = std.os.linux.errno(rc);
            if (e == .AGAIN or e == .INTR) {
                var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
                _ = std.os.linux.nanosleep(&ts, null);
                continue;
            }
            return error.WriteFailed;
        }
        off += @intCast(rc);
    }
}

/// Read one newline-terminated line with a deadline (socket is nonblocking;
/// poll drives the wait). Returns null on timeout.
fn sockReadLine(fd: i32, alloc: std.mem.Allocator, timeout_ms: i32) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    var remaining: i32 = timeout_ms;
    while (remaining > 0) {
        var fds = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const slice: i32 = 50;
        const rc = std.os.linux.poll(&fds, 1, slice);
        if (@as(i64, @bitCast(rc)) < 0) {
            if (std.os.linux.errno(rc) == .INTR) continue;
            return error.PollFailed;
        }
        remaining -= slice;
        if (rc == 0) continue;
        const n_rc = std.os.linux.read(fd, &buf, buf.len);
        if (@as(i64, @bitCast(n_rc)) < 0) {
            const e = std.os.linux.errno(n_rc);
            if (e == .AGAIN or e == .INTR) continue;
            return error.ReadFailed;
        }
        const n: usize = @intCast(n_rc);
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl| {
            try out.appendSlice(alloc, buf[0..nl]);
            const r = try out.toOwnedSlice(alloc);
            return r;
        }
        try out.appendSlice(alloc, buf[0..n]);
        if (out.items.len > 32 * 1024 * 1024) return error.LineTooLong;
    }
    if (out.items.len > 0) {
        const r = try out.toOwnedSlice(alloc);
        return r;
    }
    return null;
}

fn z(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    const b = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(b, s);
    return b.ptr;
}

/// Auto-spawn `rex serve` (the rex binary next to our own exe) if the socket
/// is not answering.
fn ensureServer(alloc: std.mem.Allocator, path: []const u8) !void {
    if (sockConnect(path)) |fd| {
        _ = std.os.linux.close(fd);
        return;
    } else |_| {}
    var exe_buf: [4096]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (@as(i64, @bitCast(n)) <= 0) return error.NoSelfExe;
    const exe_len: usize = @intCast(n);
    const dir_end = std.mem.lastIndexOfScalar(u8, exe_buf[0..exe_len], '/') orelse return error.NoSelfExe;
    const rex_path = try std.fmt.allocPrint(alloc, "{s}/rex", .{exe_buf[0..dir_end]});
    defer alloc.free(rex_path);
    if (std.posix.openat(std.posix.AT.FDCWD, rex_path, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
        _ = std.c.close(fd);
    } else |_| return error.NoRexBinary;
    const pid_rc = std.os.linux.fork();
    if (@as(i64, @bitCast(pid_rc)) < 0) return error.ForkFailed;
    if (pid_rc == 0) {
        _ = std.os.linux.setsid();
        const devnull = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch childFail();
        _ = std.os.linux.dup2(devnull, 0);
        _ = std.os.linux.dup2(devnull, 1);
        _ = std.os.linux.dup2(devnull, 2);
        const p0 = z(alloc, rex_path) catch childFail();
        const p1 = z(alloc, "serve") catch childFail();
        const p2 = z(alloc, "--socket") catch childFail();
        const p3 = z(alloc, path) catch childFail();
        var av = [_]?[*:0]const u8{ p0, p1, p2, p3, null };
        var envp = [_]?[*:0]const u8{null};
        _ = std.os.linux.execve(p0, @ptrCast(av[0..].ptr), @ptrCast(envp[0..].ptr));
        childFail();
    }
    const deadline = pty_mod.nowNs() + 3 * 1_000_000_000;
    while (pty_mod.nowNs() < deadline) {
        if (sockConnect(path)) |fd| {
            _ = std.os.linux.close(fd);
            return;
        } else |_| {}
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.ServerDidNotStart;
}

fn rssKb() u64 {
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

fn pickMonoFont() []const u8 {
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

const Expect = enum { none, split, ls };

pub const App = struct {
    alloc: std.mem.Allocator,
    fd: i32 = -1,
    pane: u32 = 0,
    pane_alive: bool = true,
    grid: grid_mod.Grid,
    parser: vt.Parser = .{},
    quads: []gpu_text.Quad = &.{},
    pending: std.ArrayList(u8) = .empty,
    await_attach: bool = false,
    expect: Expect = .none,
    no_panes: bool = false,
    // selection in cell coords
    sel_active: bool = false,
    sel_x0: i32 = 0,
    sel_y0: i32 = 0,
    sel_x1: i32 = 0,
    sel_y1: i32 = 0,
    // pane tabs + theme (framework-afforded chrome)
    panes: std.ArrayList(u32) = .empty,
    theme_idx: usize = 0,
    // bench
    frames: u64 = 0,
    frame_ns: u64 = 0,
    win_frames: u32 = 0,
    win_ns: u64 = 0,
    bytes_in: u64 = 0,

    fn sendRaw(self: *App, s: []const u8) void {
        sockWriteAll(self.fd, s) catch return;
        sockWriteAll(self.fd, "\n") catch {};
    }

    fn sendOpPane(self: *App, comptime op: []const u8, extra: []const u8) void {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"op\":\"{s}\",\"pane\":{d}{s}}}", .{ op, self.pane, extra }) catch return;
        self.sendRaw(line);
    }

    /// Send raw bytes to the pane's pty (as a JSON "data" string).
    fn sendData(self: *App, data: []const u8) void {
        const js = json.writeValue(self.alloc, .{ .str = data }) catch return;
        defer self.alloc.free(js);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        buf.print(self.alloc, "{{\"op\":\"send\",\"pane\":{d},\"data\":{s}}}", .{ self.pane, js }) catch return;
        self.sendRaw(buf.items);
    }

    fn cyclePane(self: *App, dir: i32) void {
        const n = self.panes.items.len;
        if (n == 0) return;
        var idx: i64 = -1;
        for (self.panes.items, 0..) |p, i| {
            if (p == self.pane) idx = @intCast(i);
        }
        if (idx < 0) idx = 0;
        const next = @mod(idx + dir, @as(i64, @intCast(n)));
        self.attachTo(self.panes.items[@intCast(next)]);
    }

    fn attachTo(self: *App, id: u32) void {
        self.pane = id;
        self.pane_alive = true;
        self.await_attach = true;
        self.sendOpPane("attach", "");
    }

    fn doSplit(self: *App) void {
        self.expect = .split;
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"op\":\"split\",\"pane\":{d},\"cmd\":[\"/bin/sh\"]}}", .{self.pane}) catch return;
        self.sendRaw(line);
    }

    fn doClosePane(self: *App) void {
        self.sendOpPane("close", "");
        self.expect = .ls;
        self.sendRaw("{\"op\":\"ls\"}");
    }

    fn handleLine(self: *App, line: []const u8) void {
        const v = json.Parser.parse(self.alloc, line) catch return;
        defer json.freeValue(self.alloc, v);
        if (v.get("event")) |ev| {
            const es = ev.strOf() orelse return;
            if (std.mem.eql(u8, es, "attach")) {
                self.await_attach = false;
                if (std.mem.indexOfScalar(u32, self.panes.items, self.pane) == null)
                    self.panes.append(self.alloc, self.pane) catch {};
                const cols: u32 = if (v.get("cols")) |c| @as(u32, @intFromFloat(c.numOf() orelse 80)) else 80;
                const rows: u32 = if (v.get("rows")) |r| @as(u32, @intFromFloat(r.numOf() orelse 24)) else 24;
                self.grid.deinit();
                self.grid = grid_mod.Grid.init(self.alloc, cols, rows) catch return;
                self.parser = .{};
                if (v.get("replay")) |r| {
                    if (r.strOf()) |b64| {
                        if (json.base64Decode(self.alloc, b64)) |raw| {
                            defer self.alloc.free(raw);
                            self.parser.feed(&self.grid, raw) catch {};
                            std.debug.print("CIPHERTERM_ATTACH_OK pane={d} cols={d} rows={d} replay_bytes={d}\n", .{ self.pane, cols, rows, raw.len });
                        } else |_| {}
                    }
                }
                self.grid.scrollToBottom();
                return;
            }
            if (std.mem.eql(u8, es, "output")) {
                const pid: u32 = if (v.get("pane")) |p| @as(u32, @intFromFloat(p.numOf() orelse 0)) else return;
                if (pid != self.pane) return;
                if (v.get("data")) |d| {
                    if (d.strOf()) |b64| {
                        if (json.base64Decode(self.alloc, b64)) |raw| {
                            defer self.alloc.free(raw);
                            self.bytes_in += raw.len;
                            self.parser.feed(&self.grid, raw) catch {};
                        } else |_| {}
                    }
                }
                return;
            }
            if (std.mem.eql(u8, es, "resize")) {
                const pid: u32 = if (v.get("pane")) |p| @as(u32, @intFromFloat(p.numOf() orelse 0)) else return;
                if (pid == self.pane) self.attachTo(self.pane); // re-sync mirror grid
                return;
            }
            if (std.mem.eql(u8, es, "exit")) {
                const pid: u32 = if (v.get("pane")) |p| @as(u32, @intFromFloat(p.numOf() orelse 0)) else return;
                if (pid == self.pane) {
                    self.pane_alive = false;
                    std.debug.print("CIPHERTERM_PANE_EXIT pane={d}\n", .{pid});
                }
                return;
            }
            return;
        }
        // op replies
        if (v.get("error")) |e| {
            if (e.strOf()) |msg| std.debug.print("cipherterm: server error: {s}\n", .{msg});
        }
        if (v.get("id")) |idv| {
            if (self.expect == .split) {
                self.expect = .none;
                self.attachTo(@as(u32, @intFromFloat(idv.numOf() orelse 0)));
            }
        }
        if (v.get("panes")) |pv| {
            if (self.expect == .ls and pv.* == .arr) {
                self.expect = .none;
                for (pv.arr) |pe| {
                    if (pe.get("alive")) |a| {
                        if (a.* == .bool and a.bool) {
                            if (pe.get("id")) |idv| {
                                self.attachTo(@as(u32, @intFromFloat(idv.numOf() orelse 0)));
                                return;
                            }
                        }
                    }
                }
                std.debug.print("cipherterm: no alive panes left\n", .{});
                self.no_panes = true;
            }
        }
    }

    fn drainSocket(self: *App) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const rc = std.os.linux.read(self.fd, &buf, buf.len);
            if (@as(i64, @bitCast(rc)) < 0) {
                const e = std.os.linux.errno(rc);
                if (e == .INTR) continue;
                break; // AGAIN = drained; anything else: stop (keep last frame)
            }
            const n: usize = @intCast(rc);
            if (n == 0) {
                std.debug.print("cipherterm: server closed the connection\n", .{});
                break;
            }
            self.bytes_in += n;
            self.pending.appendSlice(self.alloc, buf[0..n]) catch break;
            while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
                const copy = self.alloc.dupe(u8, self.pending.items[0..nl]) catch break;
                std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - nl - 1], self.pending.items[nl + 1 ..]);
                self.pending.items = self.pending.items[0 .. self.pending.items.len - nl - 1];
                self.handleLine(copy);
                self.alloc.free(copy);
            }
        }
    }

    fn cellAt(self: *App, rt: *runtime.Runtime, x: f32, y: f32) [2]i32 {
        if (rt.atlas == null) return .{ 0, 0 };
        const atlas = &rt.atlas.?;
        const cm = render.cellMetrics(atlas);
        var cx = @as(i32, @intFromFloat(x / cm.w));
        var cy = @as(i32, @intFromFloat((y - 38) / cm.h));
        cx = @max(@as(i32, 0), @min(cx, @as(i32, @intCast(self.grid.cols)) - 1));
        cy = @max(@as(i32, 0), @min(cy, @as(i32, @intCast(self.grid.rows)) - 1));
        return .{ cx, cy };
    }

    fn selectionText(self: *App) ![]u8 {
        var x0 = self.sel_x0;
        var y0 = self.sel_y0;
        var x1 = self.sel_x1;
        var y1 = self.sel_y1;
        if (y1 < y0 or (y1 == y0 and x1 < x0)) {
            const tx = x0;
            x0 = x1;
            x1 = tx;
            const ty = y0;
            y0 = y1;
            y1 = ty;
        }
        const lines = self.grid.screenLines();
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        var y: usize = @intCast(@max(@as(i32, 0), y0));
        const yend: usize = @intCast(@max(@as(i32, 0), y1));
        while (y <= yend and y < lines.len) : (y += 1) {
            const line = lines[y];
            const line_start = out.items.len;
            const start: usize = if (y == @as(usize, @intCast(@max(@as(i32, 0), y0)))) @intCast(@max(@as(i32, 0), @min(x0, @as(i32, @intCast(line.cells.len)) - 1))) else 0;
            const end: usize = if (y == yend) @intCast(@max(@as(i32, 0), @min(x1 + 1, @as(i32, @intCast(line.cells.len))))) else line.cells.len;
            var col = start;
            while (col < end and col < line.cells.len) : (col += 1) {
                const cp = line.cells[col].cp;
                var buf: [4]u8 = undefined;
                const n: usize = @intCast(std.unicode.utf8Encode(if (cp == 0) ' ' else @as(u21, @intCast(cp)), &buf) catch continue);
                try out.appendSlice(self.alloc, buf[0..n]);
            }
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            if (y < yend) try out.append(self.alloc, '\n');
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn copySelection(self: *App, rt: *runtime.Runtime) void {
        const text = self.selectionText() catch return;
        defer self.alloc.free(text);
        if (text.len > 0) rt.setClipboard(text) catch {};
    }

    fn onKey(self: *App, rt: *runtime.Runtime, k: input.KeyEvent) void {
        const g = &self.grid;
        if (k.key == .esc) {
            if (!g.atBottom()) g.scrollToBottom() else rt.requestQuit();
            return;
        }
        if (k.mods.ctrl() and k.key == .printable and k.char != null) {
            const c = k.char.?;
            if (k.mods.shift() and (c == 'C' or c == 'c')) {
                self.copySelection(rt);
                return;
            }
            if (k.mods.shift() and (c == 'V' or c == 'v')) return; // paste arrives as .paste
            if (k.code == 20) {
                self.doSplit();
                return;
            } // ctrl+t
            if (k.code == 17) {
                self.doClosePane();
                return;
            } // ctrl+w
            const b: u8 = @as(u8, @truncate(c | 0x20)) & 0x1f;
            const arr = [_]u8{b};
            self.sendData(arr[0..]);
            return;
        }
        switch (k.key) {
            .enter, .keypad_enter => self.sendData("\r"),
            .backspace => self.sendData("\x7f"),
            .tab => {
                if (k.mods.ctrl()) {
                    self.cyclePane(if (k.mods.shift()) -1 else 1);
                } else {
                    self.sendData(if (k.mods.shift()) "\x1b[Z" else "\t");
                }
            },
            .up => self.sendData("\x1b[A"),
            .down => self.sendData("\x1b[B"),
            .right => self.sendData("\x1b[C"),
            .left => self.sendData("\x1b[D"),
            .home => self.sendData("\x1b[H"),
            .end => self.sendData("\x1b[F"),
            .page_up => self.sendData("\x1b[5~"),
            .page_down => self.sendData("\x1b[6~"),
            .insert => self.sendData("\x1b[2~"),
            .delete => self.sendData("\x1b[3~"),
            .printable => {
                if (k.char) |c| {
                    var buf: [4]u8 = undefined;
                    const n: usize = @intCast(std.unicode.utf8Encode(c, &buf) catch return);
                    if (k.mods.alt()) {
                        var both: [5]u8 = undefined;
                        both[0] = 0x1b;
                        @memcpy(both[1..][0..n], buf[0..n]);
                        self.sendData(both[0 .. 1 + n]);
                    } else {
                        self.sendData(buf[0..n]);
                    }
                }
            },
            else => {},
        }
    }

    pub fn onInit(self: *App, rt: *runtime.Runtime) !void {
        // Fit the pane to the real window size (server grid follows).
        if (rt.atlas == null) return;
        const atlas = &rt.atlas.?;
        const cm = render.cellMetrics(atlas);
        const cols = @max(@as(u32, 10), @as(u32, @intFromFloat(@as(f32, @floatFromInt(rt.width)) / cm.w)));
        const rows = @max(@as(u32, 4), @as(u32, @intFromFloat(@as(f32, @floatFromInt(rt.height)) / cm.h)));
        if (cols != self.grid.cols or rows != self.grid.rows) {
            var buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{{\"op\":\"resize\",\"pane\":{d},\"cols\":{d},\"rows\":{d}}}", .{ self.pane, cols, rows }) catch return;
            self.sendRaw(line);
            self.attachTo(self.pane); // re-attach: server replays into the new grid
        }
    }

    pub fn onEvent(self: *App, rt: *runtime.Runtime, ev: input.Event) void {
        switch (ev) {
            .key => |k| {
                if (k.pressed) self.onKey(rt, k);
            },
            .wheel => |w| {
                if (w.dy != 0) {
                    var n: usize = @intFromFloat(@abs(w.dy));
                    if (n == 0) n = 1;
                    if (w.dy < 0) self.grid.viewScrollUp(n) else self.grid.viewScrollDown(n);
                }
            },
            .mouse_button => |b| {
                if (b.button == 0x110) { // BTN_LEFT
                    if (b.pressed) {
                        self.sel_active = true;
                        const c = self.cellAt(rt, rt.mouse_x, rt.mouse_y);
                        self.sel_x0 = c[0];
                        self.sel_y0 = c[1];
                        self.sel_x1 = c[0];
                        self.sel_y1 = c[1];
                    } else {
                        if (self.sel_active) self.copySelection(rt);
                        self.sel_active = false;
                    }
                }
            },
            .mouse_move => |m| {
                if (self.sel_active) {
                    const c = self.cellAt(rt, m.x, m.y);
                    self.sel_x1 = c[0];
                    self.sel_y1 = c[1];
                }
            },
            .resize => |r| {
                if (rt.atlas == null) return;
                const atlas = &rt.atlas.?;
                const cm = render.cellMetrics(atlas);
                const cols = @max(@as(u32, 10), @as(u32, @intFromFloat(@as(f32, @floatFromInt(r.w)) / cm.w)));
                const rows = @max(@as(u32, 4), @as(u32, @intFromFloat(@as(f32, @floatFromInt(r.h)) / cm.h)));
                if (cols != self.grid.cols or rows != self.grid.rows) {
                    var buf: [96]u8 = undefined;
                    const line = std.fmt.bufPrint(&buf, "{{\"op\":\"resize\",\"pane\":{d},\"cols\":{d},\"rows\":{d}}}", .{ self.pane, cols, rows }) catch return;
                    self.sendRaw(line);
                    self.attachTo(self.pane);
                }
            },
            .paste => |text| {
                // file drop arrives as newline-separated paths; text paste as-is
                var all_paths = text.len > 0 and text[0] == '/';
                var joined = std.ArrayList(u8).empty;
                defer joined.deinit(self.alloc);
                if (all_paths) {
                    var it = std.mem.splitScalar(u8, text, '\n');
                    var first = true;
                    while (it.next()) |ln| {
                        const t = std.mem.trim(u8, ln, " \t\r");
                        if (t.len == 0) continue;
                        if (t[0] != '/') {
                            all_paths = false;
                            break;
                        }
                        if (!first) joined.append(self.alloc, ' ') catch {};
                        joined.appendSlice(self.alloc, t) catch {};
                        first = false;
                    }
                }
                if (all_paths and joined.items.len > 0) {
                    self.sendData(joined.items);
                } else if (self.grid.bracketed_paste) {
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.alloc);
                    buf.appendSlice(self.alloc, "\x1b[200~") catch return;
                    buf.appendSlice(self.alloc, text) catch return;
                    buf.appendSlice(self.alloc, "\x1b[201~") catch return;
                    self.sendData(buf.items);
                } else {
                    self.sendData(text);
                }
            },
            .close => rt.requestQuit(),
            .focus => {},
        }
    }

    pub fn onFrame(self: *App, rt: *runtime.Runtime) !void {
        const t0 = pty_mod.nowNs();
        self.drainSocket();
        if (self.no_panes) rt.requestQuit();
        if (rt.atlas == null) return;
        const atlas = &rt.atlas.?;
        const cm = render.cellMetrics(atlas);
        const theme = render.THEMES[self.theme_idx % render.THEMES.len];
        const bar_h: f32 = 34;
        const grid_y: f32 = bar_h + 4;
        var n: usize = 0;
        // full-window background (theme)
        self.quads[0] = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(rt.width),
            .h = @floatFromInt(rt.height),
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .color = runtime.rgba01(theme.bg),
        };
        n = 1;
        // tab bar + status bar (framework UI chrome)
        if (rt.ui()) |u| {
            var tabbuf: [32][32]u8 = undefined;
            var tabs: [32][]const u8 = undefined;
            const pn = @min(self.panes.items.len, 32);
            var active_tab: i32 = -1;
            for (self.panes.items[0..pn], 0..) |pid, i| {
                const s = std.fmt.bufPrint(&tabbuf[i], "pane {d}", .{pid}) catch "pane";
                tabs[i] = s;
                if (pid == self.pane) active_tab = @intCast(i);
            }
            // runtime opens/closes the UI frame around onFrame
            try u.panel(.{ .fixed = @floatFromInt(rt.width) }, .{ .fixed = bar_h }, 6, 4);
            u.current().dir = .row;
            for (tabs[0..pn], 0..) |t, i| {
                if (try u.button(t)) {
                    if (i != @as(usize, @intCast(@max(active_tab, 0)))) self.attachTo(self.panes.items[i]);
                }
            }
            var tbuf: [64]u8 = undefined;
            const ts = std.fmt.bufPrint(&tbuf, "theme: {s}", .{theme.name}) catch "theme";
            if (try u.button(ts)) self.theme_idx +%= 1;
            if (try u.button("+")) self.doSplit();
            var sbuf: [160]u8 = undefined;
            const ss = std.fmt.bufPrint(&sbuf, "rss {d} MB  in {d} KB  panes {d}", .{ rssKb() / 1024, self.bytes_in / 1024, self.panes.items.len }) catch "rss";
            try u.label(ss, term.ui.COLOR_TEXT_DIM);
            u.endPanel();
        }
        // selection highlight (under the glyphs)
        if (self.sel_active) {
            var x0 = self.sel_x0;
            var y0 = self.sel_y0;
            var x1 = self.sel_x1;
            var y1 = self.sel_y1;
            if (y1 < y0 or (y1 == y0 and x1 < x0)) {
                const tx = x0;
                x0 = x1;
                x1 = tx;
                const ty = y0;
                y0 = y1;
                y1 = ty;
            }
            const cols_i: i32 = @intCast(self.grid.cols);
            const rows_i: i32 = @intCast(self.grid.rows);
            x0 = @max(@as(i32, 0), @min(x0, cols_i - 1));
            x1 = @max(@as(i32, 0), @min(x1, cols_i - 1));
            y0 = @max(@as(i32, 0), @min(y0, rows_i - 1));
            y1 = @max(@as(i32, 0), @min(y1, rows_i - 1));
            var y: i32 = y0;
            while (y <= y1) : (y += 1) {
                const sx: i32 = if (y == y0) x0 else 0;
                const ex: i32 = if (y == y1) x1 + 1 else cols_i;
                if (n < self.quads.len) {
                    self.quads[n] = .{
                        .x = @as(f32, @floatFromInt(sx)) * cm.w,
                        .y = grid_y + @as(f32, @floatFromInt(y)) * cm.h,
                        .w = @as(f32, @floatFromInt(ex - sx)) * cm.w,
                        .h = cm.h,
                        .u0 = 0,
                        .v0 = 0,
                        .u1 = 0,
                        .v1 = 0,
                        .color = runtime.rgba01(theme.sel),
                    };
                    n += 1;
                }
            }
        }
        n = try render.renderGridT(atlas, &self.grid, self.quads, n, 0, grid_y, cm.w, cm.h, theme);
        rt.extra_quads = self.quads[0..n];
        // bench
        const dt: u64 = @intCast(pty_mod.nowNs() - t0);
        self.frames += 1;
        self.frame_ns += dt;
        self.win_frames += 1;
        self.win_ns += dt;
        if (self.win_frames >= 120) {
            std.debug.print("CIPHERTERM_BENCH frames={d} avg_onframe_ms={d:.3} quads={d} rss_kb={d} pane={d} alive={} bytes_in={d}\n", .{ self.frames, @as(f64, @floatFromInt(self.win_ns)) / @as(f64, @floatFromInt(self.win_frames)) / 1e6, n, rssKb(), self.pane, self.pane_alive, self.bytes_in });
            self.win_frames = 0;
            self.win_ns = 0;
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    for (init.args.vector) |a| try args.append(alloc, std.mem.span(a));

    var sock_buf: [256]u8 = undefined;
    const sock_default: []const u8 = blk: {
        if (std.c.getenv("CIPHER_REX_SOCK")) |p| break :blk std.mem.span(p);
        if (std.c.getenv("XDG_RUNTIME_DIR")) |d| {
            const s = try std.fmt.bufPrint(&sock_buf, "{s}/cipher-rex.sock", .{std.mem.span(d)});
            break :blk sock_buf[0..s.len];
        }
        break :blk "/run/user/1000/cipher-rex.sock";
    };
    var sock: []const u8 = sock_default;
    var pane_arg: ?u32 = null;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (std.mem.eql(u8, args.items[i], "--socket") and i + 1 < args.items.len) {
            sock = args.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args.items[i], "--pane") and i + 1 < args.items.len) {
            pane_arg = try std.fmt.parseInt(u32, args.items[i + 1], 10);
            i += 1;
        } else {
            pane_arg = std.fmt.parseInt(u32, args.items[i], 10) catch pane_arg;
        }
    }

    try ensureServer(alloc, sock);
    const fd = try sockConnect(sock);
    defer _ = std.os.linux.close(fd);

    var pane: u32 = pane_arg orelse 0;
    if (pane == 0) {
        try sockWriteAll(fd, "{\"op\":\"ls\"}\n");
        const ls_line = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(ls_line);
        const ls_v = try json.Parser.parse(alloc, ls_line);
        defer json.freeValue(alloc, ls_v);
        if (ls_v.get("panes")) |pv| {
            if (pv.* == .arr) {
                for (pv.arr) |pe| {
                    if (pe.get("alive")) |a| {
                        if (a.* == .bool and a.bool) {
                            if (pe.get("id")) |idv| {
                                pane = @as(u32, @intFromFloat(idv.numOf() orelse 0));
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    if (pane == 0) {
        try sockWriteAll(fd, "{\"op\":\"spawn\",\"cols\":100,\"rows\":30,\"cmd\":[\"/bin/sh\"]}\n");
        const sp_line = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(sp_line);
        const sp_v = try json.Parser.parse(alloc, sp_line);
        defer json.freeValue(alloc, sp_v);
        pane = @as(u32, @intFromFloat(sp_v.get("id").?.numOf() orelse 0));
    }

    var abuf: [64]u8 = undefined;
    const aline = try std.fmt.bufPrint(&abuf, "{{\"op\":\"attach\",\"pane\":{d}}}", .{pane});
    try sockWriteAll(fd, aline);
    try sockWriteAll(fd, "\n");
    const at_line = try sockReadLine(fd, alloc, 10000) orelse return error.NoReply;
    defer alloc.free(at_line);
    const at_v = try json.Parser.parse(alloc, at_line);
    defer json.freeValue(alloc, at_v);
    const cols: u32 = if (at_v.get("cols")) |c| @as(u32, @intFromFloat(c.numOf() orelse 80)) else 80;
    const rows: u32 = if (at_v.get("rows")) |r| @as(u32, @intFromFloat(r.numOf() orelse 24)) else 24;

    var app = App{
        .alloc = alloc,
        .fd = fd,
        .pane = pane,
        .grid = try grid_mod.Grid.init(alloc, cols, rows),
    };
    defer app.grid.deinit();
    defer app.pending.deinit(alloc);
    if (at_v.get("replay")) |r| {
        if (r.strOf()) |b64| {
            if (json.base64Decode(alloc, b64)) |raw| {
                defer alloc.free(raw);
                try app.parser.feed(&app.grid, raw);
                std.debug.print("CIPHERTERM_ATTACH_OK pane={d} cols={d} rows={d} replay_bytes={d}\n", .{ pane, cols, rows, raw.len });
            } else |_| {}
        }
    }
    app.quads = try alloc.alloc(gpu_text.Quad, MAX_QUADS);
    defer alloc.free(app.quads);

    try runtime.runWith(App, &app, .{
        .title = "cipherterm",
        .app_id = "cipherterm",
        .font_path = pickMonoFont(),
        .ui_px = 18,
        .width = 1120,
        .height = 700,
    });
    std.debug.print("CIPHERTERM_EXIT frames={d} total_onframe_ms={d:.1} rss_kb={d} bytes_in={d}\n", .{ app.frames, @as(f64, @floatFromInt(app.frame_ns)) / 1e6, rssKb(), app.bytes_in });
}
