const std = @import("std");

const TIOCSPTLCK = 0x40045431;
const TIOCGPTN = 0x80045430;
const TIOCSCTTY = 0x540E;
const TIOCSWINSZ = 0x5414;

const max_scrollback = 500;

/// PTY-backed shell for the NvTerm-style bottom split. Deliberately a *dumb*
/// terminal: output is kept as plain-text lines; CSI/OSC escape sequences are
/// stripped, `\r` returns to column 0 (overwrite), `\b` steps back, `\n`
/// opens a new line. Enough for builds, git and test runs — not for curses.
pub const Term = struct {
    alloc: std.mem.Allocator,
    fd: std.posix.fd_t,
    pid: std.posix.pid_t,
    lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty ,
    col: usize = 0,
    esc: enum { none, esc, csi, osc, osc_esc } = .none,
    exited: bool = false,

    pub fn spawn(io: std.Io, alloc: std.mem.Allocator, cols: u16, rows: u16) !Term {
        const master = std.posix.system.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, @as(c_uint, 0));
        errdefer _ = std.posix.system.close(master);

        var unlock: c_int = 0;
        if (std.os.linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock)) != 0) return error.PtyUnlock;
        var ptn: c_uint = 0;
        if (std.os.linux.ioctl(master, TIOCGPTN, @intFromPtr(&ptn)) != 0) return error.PtyNumber;

        var path_buf: [32]u8 = undefined;
        const slave_path = try std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{ptn});

        const pid = std.posix.system.fork();
        if (pid == 0) {
            // Child: new session, adopt the slave as the controlling tty.
            _ = std.os.linux.setsid();
            const slave = try std.Io.Dir.openFileAbsolute(io, slave_path, .{.mode = .read_write});
            _ = std.os.linux.ioctl(slave.handle, TIOCSCTTY, 0);
            if (std.posix.system.dup2(slave.handle, 0) != 0) std.process.exit(1);
            if (std.posix.system.dup2(slave.handle, 1) != 0) std.process.exit(1);
            if (std.posix.system.dup2(slave.handle, 2) != 0) std.process.exit(1);
            if (slave.handle > 2) _ = std.posix.system.close(slave.handle);
            _ = std.posix.system.close(master);

            const shell = std.posix.system.getenv("SHELL") orelse "/bin/sh";
            var shell_buf: [128]u8 = undefined;
            const shell_z = std.fmt.bufPrintZ(&shell_buf, "{s}", .{shell}) catch std.process.exit(1);
            const argv = [_][]const u8{shell_z};
            var env_map = std.process.Environ.Map.init(alloc);
            env_map.put("TERM", "dumb") catch std.process.exit(1);
            env_map.put("PS1", "$") catch std.process.exit(1);
            std.process.replace(io, .{.argv = &argv, .environ_map = &env_map}) catch {};
            std.process.exit(1);
        }

        // Parent: non-blocking reads, initial window size.
        const fl = std.posix.system.fcntl(master, std.posix.F.GETFL, @as(c_int, 0));
        _ = std.posix.system.fcntl(master, std.posix.F.SETFL, fl | @as(c_int, 1 << 11)); // O_NONBLOCK

        var t: Term = .{ .alloc = alloc, .fd = master, .pid = pid };
        t.resize(cols, rows);
        try t.lines.append(alloc, .empty);
        return t;
    }

    pub fn deinit(self: *Term) void {
        if (self.pid > 0) {
            _ = std.posix.system.kill(self.pid, std.posix.SIG.HUP);
            _ = std.posix.system.waitpid(self.pid, null, std.posix.W.NOHANG);
        }
        if (self.fd >= 0) _ = std.posix.system.close(self.fd);
        for (self.lines.items) |*l| l.deinit(self.alloc);
        self.lines.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) void {
        const ws = extern struct { rows: u16, cols: u16, xp: u16 = 0, yp: u16 = 0 }{ .rows = rows, .cols = cols };
        _ = std.os.linux.ioctl(self.fd, TIOCSWINSZ, @intFromPtr(&ws));
    }

    pub fn write(self: *Term, bytes: []const u8) void {
        if (self.exited) return;
        _ = std.posix.system.write(self.fd, bytes.ptr, bytes.len);
    }

    /// Drain pending shell output. Returns true when the screen changed.
    pub fn poll(self: *Term) bool {
        if (self.exited) return false;
        var changed = false;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => {
                    self.exited = true;
                    break;
                },
            };
            if (n == 0) {
                self.exited = true;
                break;
            }
            for (buf[0..n]) |byte| self.feed(byte);
            changed = true;
        }
        return changed;
    }

    fn curLine(self: *Term) *std.ArrayListUnmanaged(u8) {
        return &self.lines.items[self.lines.items.len - 1];
    }

    fn feed(self: *Term, byte: u8) void {
        switch (self.esc) {
            .esc => {
                self.esc = switch (byte) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .none,
                };
                return;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.esc = .none;
                return;
            },
            .osc => {
                if (byte == 0x07) self.esc = .none;
                if (byte == 0x1b) self.esc = .osc_esc;
                return;
            },
            .osc_esc => {
                self.esc = if (byte == '\\') .none else .osc;
                return;
            },
            .none => {},
        }
        switch (byte) {
            0x1b => self.esc = .esc,
            '\n' => {
                self.lines.append(self.alloc, .empty) catch return;
                if (self.lines.items.len > max_scrollback) {
                    var first = self.lines.orderedRemove(0);
                    first.deinit(self.alloc);
                }
                self.col = 0;
            },
            '\r' => self.col = 0,
            0x08 => self.col -|= 1,
            '\t' => {
                const stop = (self.col / 8 + 1) * 8;
                while (self.col < stop) self.putByte(' ');
            },
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            else => self.putByte(byte),
        }
    }

    fn putByte(self: *Term, byte: u8) void {
        const line = self.curLine();
        if (self.col < line.items.len) {
            line.items[self.col] = byte;
        } else {
            while (line.items.len < self.col) line.append(self.alloc, ' ') catch return;
            line.append(self.alloc, byte) catch return;
        }
        self.col += 1;
    }
};
