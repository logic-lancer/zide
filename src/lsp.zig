const std = @import("std");

/// Minimal LSP client for zls: JSON-RPC 2.0 over the child's stdio, framed
/// with Content-Length headers. Nothing here blocks the UI: both pipes are
/// O_NONBLOCK, writes queue in `out`, reads accumulate in `in` and are
/// parsed frame-by-frame from the editor's ~80ms poll tick.
pub const Lsp = struct {
    alloc: std.mem.Allocator,
    child: std.process.Child,
    in_fd: std.posix.fd_t,  // child stdout
    out_fd: std.posix.fd_t, // child stdin
    in: std.ArrayListUnmanaged(u8) = .{},
    out: std.ArrayListUnmanaged(u8) = .{},
    /// False once the child dies or the stream desynchronizes. The editor
    /// tears the client down on the next tick and never respawns.
    alive: bool = true,
    /// True after the `initialize` response; no notification may be sent
    /// before it (didOpen is deferred until then).
    initialized: bool = false,
    next_id: i64 = 1,
    init_id: i64 = 0,
    hover_id: i64 = 0,
    def_id: i64 = 0,
    /// A definition response landed; `def_loc` is its payload, null when the
    /// server answered `null`. The editor clears the flag when it consumes it —
    /// the flag is what distinguishes "no answer yet" from "answer: nothing".
    def_done: bool = false,
    def_loc: ?Loc = null,
    /// Inbox drained by the editor: one entry per publishDiagnostics.
    publishes: std.ArrayListUnmanaged(Publish) = .{},
    /// Last hover result, owned; the editor takes and frees it.
    hover_text: ?[]u8 = null,

    /// Runaway-server guard: a stream this far behind is desynchronized.
    const max_in = 8 * 1024 * 1024;
    /// JSON `{}` — an empty anonymous tuple would stringify as `[]`.
    const Empty = struct {};

    pub const Diag = struct {
        line: u32, // 0-based
        col: u32,  // 0-based byte column (utf-8 position encoding)
        severity: u8, // 1 error, 2 warning, 3 info, 4 hint
        message: []u8, // owned, newlines folded to spaces
    };
    /// One publishDiagnostics: absolute path (decoded from the uri) + list,
    /// both owned by whoever pops it off `publishes`.
    pub const Publish = struct { path: []u8, diags: []Diag };

    /// One resolved location: absolute path (decoded from the uri) + 0-based
    /// line and byte column (utf-8 encoding was negotiated). `path` is owned.
    pub const Loc = struct { path: []u8, line: u32, col: u32 };

    // ---- lifecycle --------------------------------------------------------

    /// Spawn `zls` from PATH and send `initialize`. Returns error.FileNotFound
    /// when zls is not installed — the caller degrades to no-LSP.
    pub fn spawn(alloc: std.mem.Allocator, root_abs: []const u8) !Lsp {
        var child = std.process.Child.init(&.{"zls"}, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore; // zls logs go to window/logMessage
        try child.spawn();
        errdefer _ = child.kill() catch {};

        var self: Lsp = .{
            .alloc = alloc,
            .child = child,
            .in_fd = child.stdout.?.handle,
            .out_fd = child.stdin.?.handle,
        };
        setNonBlock(self.in_fd);
        setNonBlock(self.out_fd);

        const uri = try uriFromPath(alloc, root_abs);
        defer alloc.free(uri);
        // positionEncodings utf-8: zls honors it, so every line/character in
        // this protocol is a byte offset — the editor's own coordinates.
        self.init_id = self.request("initialize", .{
            .processId = @as(i64, std.os.linux.getpid()),
            .rootUri = uri,
            .capabilities = .{
                .general = .{ .positionEncodings = [_][]const u8{"utf-8"} },
                .textDocument = .{
                    .synchronization = .{ .dynamicRegistration = false, .didSave = true },
                    .publishDiagnostics = .{ .relatedInformation = false },
                    .hover = .{ .contentFormat = [_][]const u8{"plaintext"} },
                },
            },
        });
        return self;
    }

    pub fn deinit(self: *Lsp) void {
        // Best effort, never blocking: shutdown+exit are tiny, so a single
        // non-blocking write clears them unless the pipe is already full.
        if (self.alive) {
            _ = self.request("shutdown", Empty{});
            self.notify("exit", Empty{});
            self.flush();
        }
        if (self.child.stdin) |f| {
            f.close(); // EOF makes zls exit on its own
            self.child.stdin = null;
        }
        if (self.child.stdout) |f| {
            f.close(); // otherwise the read end leaks one fd per teardown
            self.child.stdout = null;
        }
        _ = self.child.kill() catch {}; // SIGTERM + reap
        self.in.deinit(self.alloc);
        self.out.deinit(self.alloc);
        for (self.publishes.items) |p| {
            self.alloc.free(p.path);
            freeDiags(self.alloc, p.diags);
        }
        self.publishes.deinit(self.alloc);
        if (self.hover_text) |t| self.alloc.free(t);
        if (self.def_loc) |l| self.alloc.free(l.path);
        self.* = undefined;
    }

    pub fn freeDiags(alloc: std.mem.Allocator, diags: []Diag) void {
        for (diags) |d| alloc.free(d.message);
        alloc.free(diags);
    }

    fn setNonBlock(fd: std.posix.fd_t) void {
        const fl = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl | @as(usize, 1 << 11)) catch {}; // O_NONBLOCK
    }

    // ---- sending ----------------------------------------------------------

    pub fn request(self: *Lsp, method: []const u8, params: anytype) i64 {
        const id = self.next_id;
        self.next_id += 1;
        self.sendValue(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        return id;
    }

    pub fn notify(self: *Lsp, method: []const u8, params: anytype) void {
        self.sendValue(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    fn sendValue(self: *Lsp, value: anytype) void {
        if (!self.alive) return;
        var body: std.ArrayListUnmanaged(u8) = .{};
        defer body.deinit(self.alloc);
        std.json.stringify(value, .{}, body.writer(self.alloc)) catch return;
        var hbuf: [48]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "Content-Length: {d}\r\n\r\n", .{body.items.len}) catch return;
        self.out.appendSlice(self.alloc, hdr) catch return;
        self.out.appendSlice(self.alloc, body.items) catch return;
        self.flush();
    }

    /// Push as much of `out` as the pipe accepts. A full pipe (slow zls) just
    /// leaves the rest queued for the next tick — the editor never waits.
    fn flush(self: *Lsp) void {
        var sent: usize = 0;
        while (sent < self.out.items.len) {
            const n = std.posix.write(self.out_fd, self.out.items[sent..]) catch |e| switch (e) {
                error.WouldBlock => break,
                else => {
                    self.alive = false;
                    break;
                },
            };
            if (n == 0) break;
            sent += n;
        }
        if (sent > 0) self.out.replaceRange(self.alloc, 0, sent, &.{}) catch unreachable;
    }

    // ---- document sync (uri is borrowed; callers own it) -------------------

    pub fn didOpen(self: *Lsp, uri: []const u8, text: []const u8, version: i32) void {
        self.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = uri, .languageId = "zig", .version = version, .text = text,
        } });
    }

    /// Full-document sync (kind 1). zls advertises incremental but accepts
    /// this, and it needs no edit bookkeeping to stay correct.
    pub fn didChange(self: *Lsp, uri: []const u8, text: []const u8, version: i32) void {
        self.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = .{.{ .text = text }}, // tuple -> JSON array
        });
    }

    pub fn didSave(self: *Lsp, uri: []const u8) void {
        self.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    }

    pub fn didClose(self: *Lsp, uri: []const u8) void {
        self.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    }

    pub fn hover(self: *Lsp, uri: []const u8, line: usize, col: usize) void {
        self.hover_id = self.request("textDocument/hover", .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = @as(i64, @intCast(line)), .character = @as(i64, @intCast(col)) },
        });
    }

    pub fn definition(self: *Lsp, uri: []const u8, line: usize, col: usize) void {
        self.def_id = self.request("textDocument/definition", .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = @as(i64, @intCast(line)), .character = @as(i64, @intCast(col)) },
        });
    }

    // ---- receiving --------------------------------------------------------

    /// Drain the pipes and handle every complete frame. Returns true when
    /// something the editor can see changed.
    pub fn poll(self: *Lsp) bool {
        if (!self.alive) return false;
        self.flush();
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.in_fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => {
                    self.alive = false;
                    break;
                },
            };
            if (n == 0) { // EOF: zls exited
                self.alive = false;
                break;
            }
            self.in.appendSlice(self.alloc, buf[0..n]) catch {
                self.alive = false;
                break;
            };
            if (self.in.items.len > max_in) {
                self.alive = false;
                break;
            }
        }
        var changed = false;
        while (self.takeFrame()) |frame| {
            defer self.alloc.free(frame);
            self.handleFrame(frame);
            changed = true;
        }
        return changed;
    }

    /// Pop one complete Content-Length frame off `in`, or null when the
    /// buffer still holds a partial message.
    fn takeFrame(self: *Lsp) ?[]u8 {
        const hdr_end = std.mem.indexOf(u8, self.in.items, "\r\n\r\n") orelse return null;
        var len: ?usize = null;
        var it = std.mem.splitSequence(u8, self.in.items[0..hdr_end], "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue; // skips Content-Type
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
        }
        const body_len = len orelse {
            self.alive = false; // header without a length: desynchronized
            return null;
        };
        const total = hdr_end + 4 + body_len;
        if (self.in.items.len < total) return null; // partial frame, wait
        const body = self.alloc.dupe(u8, self.in.items[hdr_end + 4 .. total]) catch return null;
        self.in.replaceRange(self.alloc, 0, total, &.{}) catch unreachable;
        return body;
    }

    fn handleFrame(self: *Lsp, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (getStr(root, "method")) |m| {
            // Notifications; server->client requests (window/showMessageRequest,
            // client/registerCapability) are ignored — zls tolerates no reply.
            if (std.mem.eql(u8, m, "textDocument/publishDiagnostics")) {
                if (objGet(root, "params")) |p| self.onPublish(p) catch {};
            }
            return;
        }
        const id = getInt(root, "id") orelse return;
        if (self.init_id != 0 and id == self.init_id) {
            self.init_id = 0;
            self.initialized = true;
            self.notify("initialized", Empty{});
            return;
        }
        if (self.hover_id != 0 and id == self.hover_id) {
            self.hover_id = 0;
            self.onHover(root); // C4; consumed by the editor via hover_text
            return;
        }
        if (self.def_id != 0 and id == self.def_id) {
            self.def_id = 0;
            self.onDefinition(root);
            return;
        }
    }

    fn onPublish(self: *Lsp, params: std.json.Value) !void {
        const uri = getStr(params, "uri") orelse return;
        const arr = switch (objGet(params, "diagnostics") orelse return) {
            .array => |a| a,
            else => return,
        };
        var list: std.ArrayListUnmanaged(Diag) = .{};
        errdefer {
            for (list.items) |d| self.alloc.free(d.message);
            list.deinit(self.alloc);
        }
        for (arr.items) |item| {
            const range = objGet(item, "range") orelse continue;
            const start = objGet(range, "start") orelse continue;
            const line = getInt(start, "line") orelse continue;
            const ch = getInt(start, "character") orelse 0;
            const msg_src = getStr(item, "message") orelse continue;
            const sev: u8 = blk: {
                const s = getInt(item, "severity") orelse 1;
                break :blk @intCast(std.math.clamp(s, 1, 4));
            };
            const msg = try self.alloc.dupe(u8, msg_src);
            for (msg) |*c| { // the status line is one row
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            try list.append(self.alloc, .{
                .line = @intCast(@max(line, 0)),
                .col = @intCast(@max(ch, 0)),
                .severity = sev,
                .message = msg,
            });
        }
        // Sorted once here so ]d/[d and "k/n" counting are trivially correct.
        std.mem.sort(Diag, list.items, {}, lessDiag);
        const path = try pathFromUri(self.alloc, uri);
        errdefer self.alloc.free(path);
        try self.publishes.append(self.alloc, .{
            .path = path,
            .diags = try list.toOwnedSlice(self.alloc),
        });
    }

    fn lessDiag(_: void, a: Diag, b: Diag) bool {
        if (a.line != b.line) return a.line < b.line;
        return a.col < b.col;
    }

    // ---- hover (C4) -------------------------------------------------------

    fn onHover(self: *Lsp, root: std.json.Value) void {
        if (self.hover_text) |t| {
            self.alloc.free(t);
            self.hover_text = null;
        }
        const text = hoverText(root) orelse "(no hover info)";
        self.hover_text = self.alloc.dupe(u8, text) catch null;
    }

    /// contents: MarkupContent {kind,value} | MarkedString | MarkedString[].
    fn hoverText(root: std.json.Value) ?[]const u8 {
        const res = objGet(root, "result") orelse return null;
        const contents = objGet(res, "contents") orelse return null;
        return markedText(contents);
    }

    fn markedText(v: std.json.Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            .object => getStr(v, "value"),
            .array => |a| if (a.items.len > 0) markedText(a.items[0]) else null,
            else => null,
        };
    }

    // ---- goto-definition ---------------------------------------------------

    /// zls 0.14 answers with a single Location object (verified live); it only
    /// sends LocationLink to clients that advertise definition.linkSupport,
    /// which we don't. The array and LocationLink branches are one `orelse`
    /// each and keep any other server from silently doing nothing.
    fn onDefinition(self: *Lsp, root: std.json.Value) void {
        if (self.def_loc) |l| self.alloc.free(l.path);
        self.def_loc = null;
        self.def_done = true;
        const res = objGet(root, "result") orelse return;
        const first = switch (res) {
            .object => res,
            .array => |a| if (a.items.len > 0) a.items[0] else return,
            else => return, // null: no definition
        };
        self.def_loc = self.parseLoc(first);
    }

    /// Location {uri,range} or LocationLink {targetUri,targetSelectionRange}.
    fn parseLoc(self: *Lsp, v: std.json.Value) ?Loc {
        const uri = getStr(v, "uri") orelse getStr(v, "targetUri") orelse return null;
        const range = objGet(v, "range") orelse objGet(v, "targetSelectionRange") orelse
            objGet(v, "targetRange") orelse return null;
        const start = objGet(range, "start") orelse return null;
        const line = getInt(start, "line") orelse return null;
        const ch = getInt(start, "character") orelse 0;
        const path = pathFromUri(self.alloc, uri) catch return null;
        return .{ .path = path, .line = @intCast(@max(line, 0)), .col = @intCast(@max(ch, 0)) };
    }

    // ---- json helpers (switch-based: no tagged-union equality) ------------

    fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
        return switch (v) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
        return switch (objGet(v, key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    fn getInt(v: std.json.Value, key: []const u8) ?i64 {
        return switch (objGet(v, key) orelse return null) {
            .integer => |i| i,
            else => null,
        };
    }

    // ---- uri <-> path -----------------------------------------------------

    fn unreservedUri(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '.', '_', '~', '/' => true,
            else => false,
        };
    }

    /// `file:///abs/path`, percent-encoding everything outside the unreserved
    /// set (spaces, '#', '?', ...). `abs` must already be absolute.
    pub fn uriFromPath(alloc: std.mem.Allocator, abs: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "file://");
        for (abs) |c| {
            if (unreservedUri(c)) {
                try out.append(alloc, c);
            } else {
                var esc: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&esc, "%{X:0>2}", .{c}) catch unreachable;
                try out.appendSlice(alloc, &esc);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// Inverse: strip the scheme and percent-decode. Unknown schemes come
    /// back verbatim, which simply fails to match any buffer.
    pub fn pathFromUri(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
        const body = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '%' and i + 2 < body.len) {
                const hi = std.fmt.charToDigit(body[i + 1], 16) catch {
                    try out.append(alloc, body[i]);
                    continue;
                };
                const lo = std.fmt.charToDigit(body[i + 2], 16) catch {
                    try out.append(alloc, body[i]);
                    continue;
                };
                try out.append(alloc, hi * 16 + lo);
                i += 2;
            } else try out.append(alloc, body[i]);
        }
        return out.toOwnedSlice(alloc);
    }
};
