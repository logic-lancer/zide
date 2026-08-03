const std = @import("std");

/// NvimTree-flavored workspace tree: flattened list of visible entries,
/// expand/collapse dirs, git status coloring (modified/added/untracked).
pub const GitStatus = enum { none, modified, added, untracked, deleted };

pub const Entry = struct {
    path: []u8, // relative path, owned by Tree.alloc
    name: []const u8, // basename, slice into `path`
    depth: u16,
    is_dir: bool,
    expanded: bool,
    git: GitStatus,
};

pub const Tree = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// Set of expanded dir paths (owned keys), persists across refresh.
    open_dirs: std.StringHashMapUnmanaged(void) = .{},
    /// path -> git status (owned keys), rebuilt on refresh.
    git: std.StringHashMapUnmanaged(GitStatus) = .{},
    selected: usize = 0,
    scroll: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Tree {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Tree) void {
        self.clearEntries();
        self.entries.deinit(self.alloc);
        var it = self.open_dirs.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.open_dirs.deinit(self.alloc);
        self.clearGit();
        self.git.deinit(self.alloc);
    }

    fn clearEntries(self: *Tree) void {
        for (self.entries.items) |e| self.alloc.free(e.path);
        self.entries.clearRetainingCapacity();
    }

    fn clearGit(self: *Tree) void {
        var it = self.git.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.git.clearRetainingCapacity();
    }

    /// Re-read git status and rescan the directory tree.
    pub fn refresh(self: *Tree) !void {
        self.loadGit();
        self.clearEntries();
        try self.scanDir(".", 0);
        if (self.entries.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.entries.items.len) {
            self.selected = self.entries.items.len - 1;
        }
    }

    fn skip(name: []const u8) bool {
        if (name.len == 0 or name[0] == '.') return true;
        return std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-cache");
    }

    /// Recursively collect project file paths (same ignore rules as the
    /// sidebar), for the telescope-style file finder. Paths owned by `alloc`.
    pub fn listFiles(
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged([]u8),
        max: usize,
    ) !void {
        try listFilesDir(alloc, out, ".", max);
        std.mem.sort([]u8, out.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);
    }

    fn listFilesDir(
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged([]u8),
        rel: []const u8,
        max: usize,
    ) !void {
        if (out.items.len >= max) return;
        var dir = std.fs.cwd().openDir(rel, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (out.items.len >= max) return;
            if (skip(ent.name)) continue;
            const child = if (std.mem.eql(u8, rel, "."))
                try alloc.dupe(u8, ent.name)
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel, ent.name });
            switch (ent.kind) {
                .directory => {
                    defer alloc.free(child);
                    try listFilesDir(alloc, out, child, max);
                },
                .file, .sym_link => try out.append(alloc, child),
                else => alloc.free(child),
            }
        }
    }

    fn scanDir(self: *Tree, rel: []const u8, depth: u16) !void {
        var dir = std.fs.cwd().openDir(rel, .{ .iterate = true }) catch return;
        defer dir.close();

        const Child = struct {
            name: []u8,
            is_dir: bool,
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                if (a.is_dir != b.is_dir) return a.is_dir; // dirs first
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        var names: std.ArrayListUnmanaged(Child) = .{};
        defer {
            for (names.items) |n| self.alloc.free(n.name);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (skip(ent.name)) continue;
            if (ent.kind != .file and ent.kind != .directory) continue;
            try names.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, ent.name),
                .is_dir = ent.kind == .directory,
            });
        }
        std.mem.sortUnstable(Child, names.items, {}, Child.lessThan);

        for (names.items) |n| {
            const path = if (std.mem.eql(u8, rel, "."))
                try self.alloc.dupe(u8, n.name)
            else
                try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ rel, n.name });
            errdefer self.alloc.free(path);

            const expanded = n.is_dir and self.open_dirs.contains(path);
            try self.entries.append(self.alloc, .{
                .path = path,
                .name = path[path.len - n.name.len ..],
                .depth = depth,
                .is_dir = n.is_dir,
                .expanded = expanded,
                .git = self.git.get(path) orelse .none,
            });
            if (expanded) try self.scanDir(path, depth + 1);
        }
    }

    /// Toggle expansion of the dir at entry index `idx`, then rescan.
    pub fn toggle(self: *Tree, idx: usize) !void {
        if (idx >= self.entries.items.len) return;
        const e = self.entries.items[idx];
        if (!e.is_dir) return;
        if (self.open_dirs.fetchRemove(e.path)) |kv| {
            self.alloc.free(kv.key);
        } else {
            try self.open_dirs.put(self.alloc, try self.alloc.dupe(u8, e.path), {});
        }
        const keep = try self.alloc.dupe(u8, e.path);
        defer self.alloc.free(keep);
        try self.refresh();
        // Keep selection on the same dir after rescan.
        for (self.entries.items, 0..) |ent, i| {
            if (std.mem.eql(u8, ent.path, keep)) {
                self.selected = i;
                break;
            }
        }
    }

    /// Index of the parent dir of entry `idx`, if any.
    pub fn parentOf(self: *Tree, idx: usize) ?usize {
        if (idx >= self.entries.items.len) return null;
        const depth = self.entries.items[idx].depth;
        if (depth == 0) return null;
        var i = idx;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].depth < depth) return i;
        }
        return null;
    }

    /// Run `git status --porcelain -uall` and index results by path.
    /// Parent dirs of dirty files are marked modified so closed dirs hint too.
    fn loadGit(self: *Tree) void {
        self.clearGit();
        const res = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{ "git", "status", "--porcelain", "-uall" },
            .max_output_bytes = 1 << 20,
        }) catch return;
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);
        if (res.term != .Exited or res.term.Exited != 0) return;

        var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len < 4) continue;
            const x = line[0];
            const y = line[1];
            var path = line[3..];
            if (std.mem.indexOf(u8, path, " -> ")) |arrow| path = path[arrow + 4 ..];
            if (path.len > 1 and path[0] == '"' and path[path.len - 1] == '"')
                path = path[1 .. path.len - 1];
            if (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];

            const st: GitStatus = if (x == '?' or y == '?')
                .untracked
            else if (x == 'A' or y == 'A')
                .added
            else if (x == 'D' or y == 'D')
                .deleted
            else
                .modified;
            self.putGit(path, st);

            // Propagate a "something changed below" hint to ancestors.
            var p = path;
            while (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| {
                p = p[0..slash];
                if (self.git.contains(p)) break;
                self.putGit(p, .modified);
            }
        }
    }

    fn putGit(self: *Tree, path: []const u8, st: GitStatus) void {
        const gop = self.git.getOrPut(self.alloc, path) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, path) catch {
                _ = self.git.remove(path);
                return;
            };
        }
        gop.value_ptr.* = st;
    }
};

test "tree scans project" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    try t.refresh();
    // repo root has at least build.zig and src/
    try std.testing.expect(t.entries.items.len >= 2);
}
