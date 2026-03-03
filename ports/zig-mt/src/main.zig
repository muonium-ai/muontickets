const std = @import("std");

const Command = enum {
    init,
    new,
    ls,
    show,
    pick,
    claim,
    comment,
    set_status,
    done,
    archive,
    graph,
    @"export",
    stats,
    validate,
    report,
};

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "new")) return .new;
    if (std.mem.eql(u8, raw, "ls")) return .ls;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "pick")) return .pick;
    if (std.mem.eql(u8, raw, "claim")) return .claim;
    if (std.mem.eql(u8, raw, "comment")) return .comment;
    if (std.mem.eql(u8, raw, "set-status")) return .set_status;
    if (std.mem.eql(u8, raw, "done")) return .done;
    if (std.mem.eql(u8, raw, "archive")) return .archive;
    if (std.mem.eql(u8, raw, "graph")) return .graph;
    if (std.mem.eql(u8, raw, "export")) return .@"export";
    if (std.mem.eql(u8, raw, "stats")) return .stats;
    if (std.mem.eql(u8, raw, "validate")) return .validate;
    if (std.mem.eql(u8, raw, "report")) return .report;
    return null;
}

fn printHelp() void {
    std.debug.print(
        \\MuonTickets CLI port (Zig scaffold)
        \\ 
        \\Usage:
        \\  mt-zig <command> [args]
        \\ 
        \\Commands:
        \\  init
        \\  new
        \\  ls
        \\  show
        \\  pick
        \\  claim
        \\  comment
        \\  set-status
        \\  done
        \\  archive
        \\  graph
        \\  export
        \\  stats
        \\  validate
        \\  report
        \\ 
        \\Implemented: init, new, ls, show, claim, set-status, done, archive, validate
        \\Note: remaining command handlers are scaffolded and will be implemented incrementally.
        \\ 
    , .{});
}

    const statuses = [_][]const u8{ "ready", "claimed", "blocked", "needs_review", "done" };
    const efforts = [_][]const u8{ "xs", "s", "m", "l" };

const default_template =
    \\\---
    \\\id: T-000000
    \\\title: Template: replace title
    \\\status: ready
    \\\priority: p1
    \\\type: code
    \\\effort: s
    \\\labels: []
    \\\tags: []
    \\\owner: null
    \\\created: 1970-01-01
    \\\updated: 1970-01-01
    \\\depends_on: []
    \\\branch: null
    \\\---
    \\
    \\\## Goal
    \\\Write a single-sentence goal.
    \\
    \\\## Acceptance Criteria
    \\\- [ ] Define clear, testable checks (2–5 items)
    \\
    \\\## Notes
    \\
;

const example_body =
    \\\## Goal
    \\\Replace this example with a real task.
    \\
    \\\## Acceptance Criteria
    \\\- [ ] Delete or edit this ticket
    \\\- [ ] Create at least one real ticket with `mt new`
    \\
    \\\## Notes
    \\\This repository uses MuonTickets for agent-friendly coordination.
    \\
;

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn isTicketId(id: []const u8) bool {
    if (id.len != 8) return false;
    if (!std.mem.eql(u8, id[0..2], "T-")) return false;
    for (id[2..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn isTicketFilename(name: []const u8) bool {
    if (name.len != 11) return false;
    if (!std.mem.endsWith(u8, name, ".md")) return false;
    return isTicketId(name[0..8]);
}

fn parseTicketNumber(id: []const u8) !u32 {
    if (!isTicketId(id)) return error.InvalidTicketId;
    return try std.fmt.parseInt(u32, id[2..8], 10);
}

fn findRepoRoot(allocator: std.mem.Allocator) ![]u8 {
    const start = try std.fs.cwd().realpathAlloc(allocator, ".");
    var cur = try allocator.dupe(u8, start);
    while (true) {
        const tickets_path = try std.fs.path.join(allocator, &[_][]const u8{ cur, "tickets" });
        defer allocator.free(tickets_path);
        if (dirExists(tickets_path)) {
            allocator.free(start);
            return cur;
        }

        const parent_opt = std.fs.path.dirname(cur);
        if (parent_opt == null) {
            allocator.free(cur);
            return start;
        }
        const parent = parent_opt.?;
        if (std.mem.eql(u8, parent, cur)) {
            allocator.free(cur);
            return start;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(cur);
        cur = next;
    }
}

fn readLastTicketNumber(allocator: std.mem.Allocator, repo: []const u8) !?u32 {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "last_ticket_id" });
    defer allocator.free(path);
    if (!fileExists(path)) return null;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (isTicketId(trimmed)) return try parseTicketNumber(trimmed);
    return null;
}

fn writeLastTicketNumber(allocator: std.mem.Allocator, repo: []const u8, number: u32) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "last_ticket_id" });
    defer allocator.free(path);
    const text = try std.fmt.allocPrint(allocator, "T-{d:0>6}\n", .{number});
    defer allocator.free(text);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
}

fn scanMaxTicketNumber(allocator: std.mem.Allocator, repo: []const u8) !u32 {
    var max_num: u32 = 0;
    const roots = [_][]const u8{ "tickets", "tickets/archive", "tickets/backlogs" };

    for (roots) |root_rel| {
        const root = try std.fs.path.join(allocator, &[_][]const u8{ repo, root_rel });
        defer allocator.free(root);
        if (!dirExists(root)) continue;

        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const base = std.fs.path.basename(entry.path);
            if (!isTicketFilename(base)) continue;
            const n = try parseTicketNumber(base[0..8]);
            if (n > max_num) max_num = n;
        }
    }
    return max_num;
}

fn nextTicketIdForRepo(allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    const tracked = try readLastTicketNumber(allocator, repo);
    const scanned = try scanMaxTicketNumber(allocator, repo);
    const base = if (tracked) |v| @max(v, scanned) else scanned;
    const next = base + 1;
    try writeLastTicketNumber(allocator, repo, next);
    return std.fmt.allocPrint(allocator, "T-{d:0>6}", .{next});
}

fn countActiveTicketFiles(allocator: std.mem.Allocator, repo: []const u8) !u32 {
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) return 0;

    var count: u32 = 0;
    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (isTicketFilename(entry.name)) count += 1;
    }
    return count;
}

fn writeTicketFile(allocator: std.mem.Allocator, path: []const u8, id: []const u8, title: []const u8, status: []const u8, priority: []const u8, ticket_type: []const u8, effort: []const u8, labels: []const u8, body: []const u8) !void {
    const text = try std.fmt.allocPrint(
        allocator,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: {s}
        \\priority: {s}
        \\type: {s}
        \\effort: {s}
        \\labels: {s}
        \\tags: []
        \\owner: null
        \\created: 1970-01-01
        \\updated: 1970-01-01
        \\depends_on: []
        \\branch: null
        \\---
        \\
        \\{s}
    ,
        .{ id, title, status, priority, ticket_type, effort, labels, body },
    );
    defer allocator.free(text);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
}

fn cmdInit(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);

    const tickets_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tickets_dir);

    if (!dirExists(tickets_dir)) {
        try std.fs.cwd().makePath(tickets_dir);
        std.debug.print("created {s}\n", .{tickets_dir});
    } else {
        std.debug.print("tickets dir exists: {s}\n", .{tickets_dir});
    }

    const template_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, "ticket.template" });
    defer allocator.free(template_path);
    if (!fileExists(template_path)) {
        try std.fs.cwd().writeFile(.{ .sub_path = template_path, .data = default_template });
        std.debug.print("created {s}\n", .{template_path});
    }

    const active_count = try countActiveTicketFiles(allocator, repo);
    if (active_count == 0) {
        const tid = try nextTicketIdForRepo(allocator, repo);
        defer allocator.free(tid);
        const fname = try std.fmt.allocPrint(allocator, "{s}.md", .{tid});
        defer allocator.free(fname);
        const ticket_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, fname });
        defer allocator.free(ticket_path);
        try writeTicketFile(allocator, ticket_path, tid, "Example: replace this ticket", "ready", "p2", "chore", "xs", "[example]", example_body);
        std.debug.print("created example ticket {s}\n", .{tid});
    } else {
        const tracked = try readLastTicketNumber(allocator, repo);
        const scanned = try scanMaxTicketNumber(allocator, repo);
        if (tracked == null or tracked.? < scanned) {
            try writeLastTicketNumber(allocator, repo, scanned);
            std.debug.print("updated tickets/last_ticket_id to T-{d:0>6}\n", .{scanned});
        }
    }
}

fn cmdNew(allocator: std.mem.Allocator, title_arg: []const u8) !void {
    const title = std.mem.trim(u8, title_arg, " \t\r\n");
    if (title.len == 0) {
        std.debug.print("new requires non-empty title\n", .{});
        std.process.exit(2);
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tickets_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tickets_dir);
    if (!dirExists(tickets_dir)) try std.fs.cwd().makePath(tickets_dir);

    const tid = try nextTicketIdForRepo(allocator, repo);
    defer allocator.free(tid);
    const fname = try std.fmt.allocPrint(allocator, "{s}.md", .{tid});
    defer allocator.free(fname);
    const ticket_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, fname });
    defer allocator.free(ticket_path);

    const body =
        \\## Goal
        \\Write a single-sentence goal.
        \\
        \\## Acceptance Criteria
        \\- [ ] Define clear, testable checks (2–5 items)
        \\
        \\## Notes
        \\
    ;
    try writeTicketFile(allocator, ticket_path, tid, title, "ready", "p1", "code", "s", "[]", body);
    std.debug.print("{s}\n", .{ticket_path});
}

fn parseMetaField(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_frontmatter = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            if (!in_frontmatter) {
                in_frontmatter = true;
                continue;
            }
            break;
        }
        if (!in_frontmatter) continue;
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        if (trimmed.len <= key.len + 1) continue;
        if (trimmed[key.len] != ':') continue;
        return std.mem.trim(u8, trimmed[key.len + 1 ..], " \t\r");
    }
    return null;
}

fn parseListContains(content: []const u8, key: []const u8, target: []const u8) bool {
    const raw = parseMetaField(content, key) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r[]");
    if (trimmed.len == 0) return false;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const v = std.mem.trim(u8, item, " \t\r\"'");
        if (std.mem.eql(u8, v, target)) return true;
    }
    return false;
}

fn setMetaField(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, content.len + 64);
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_frontmatter = false;
    var replaced = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            if (!in_frontmatter) {
                in_frontmatter = true;
            } else {
                if (!replaced) {
                    try out.appendSlice(allocator, key);
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, value);
                    try out.append(allocator, '\n');
                    replaced = true;
                }
                in_frontmatter = false;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }

        if (in_frontmatter and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), key)) {
            const t = std.mem.trimLeft(u8, line, " \t");
            if (t.len > key.len and t[key.len] == ':') {
                try out.appendSlice(allocator, key);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, value);
                try out.append(allocator, '\n');
                replaced = true;
                continue;
            }
        }

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    if (!replaced) {
        return error.FieldNotReplaced;
    }
    return out.toOwnedSlice(allocator);
}

fn ticketPath(allocator: std.mem.Allocator, repo: []const u8, id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", file_name });
}

fn archivedTicketPath(allocator: std.mem.Allocator, repo: []const u8, id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "archive", file_name });
}

fn statusAllowed(status: []const u8) bool {
    for (statuses) |s| {
        if (std.mem.eql(u8, s, status)) return true;
    }
    return false;
}

fn effortAllowed(effort: []const u8) bool {
    for (efforts) |e| {
        if (std.mem.eql(u8, e, effort)) return true;
    }
    return false;
}

fn transitionAllowed(old: []const u8, new: []const u8) bool {
    if (std.mem.eql(u8, old, "ready")) return std.mem.eql(u8, new, "claimed") or std.mem.eql(u8, new, "blocked");
    if (std.mem.eql(u8, old, "claimed")) return std.mem.eql(u8, new, "needs_review") or std.mem.eql(u8, new, "blocked") or std.mem.eql(u8, new, "ready");
    if (std.mem.eql(u8, old, "blocked")) return std.mem.eql(u8, new, "ready") or std.mem.eql(u8, new, "claimed");
    if (std.mem.eql(u8, old, "needs_review")) return std.mem.eql(u8, new, "done") or std.mem.eql(u8, new, "claimed");
    return false;
}

fn defaultBranch(allocator: std.mem.Allocator, id: []const u8, title: []const u8) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer buf.deinit(allocator);
    for (title) |ch| {
        const c = std.ascii.toLower(ch);
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            try buf.append(allocator, c);
        } else {
            if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '-') {
                try buf.append(allocator, '-');
            }
        }
        if (buf.items.len >= 40) break;
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
        _ = buf.pop();
    }
    const slug = if (buf.items.len == 0) "task" else buf.items;
    const id_lower = try std.ascii.allocLowerString(allocator, id);
    defer allocator.free(id_lower);
    return std.fmt.allocPrint(allocator, "bug/{s}-{s}", .{ id_lower, slug });
}

fn getOptValue(args: []const [:0]u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn hasFlag(args: []const [:0]u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn depDone(repo: []const u8, allocator: std.mem.Allocator, dep_id: []const u8) bool {
    const dep_path = ticketPath(allocator, repo, dep_id) catch return false;
    defer allocator.free(dep_path);
    if (!fileExists(dep_path)) return false;
    const content = std.fs.cwd().readFileAlloc(allocator, dep_path, 1024 * 1024) catch return false;
    defer allocator.free(content);
    const st = parseMetaField(content, "status") orelse return false;
    return std.mem.eql(u8, st, "done");
}

fn cmdClaim(allocator: std.mem.Allocator, id: []const u8, owner: []const u8, force: bool, ignore_deps: bool) !void {
    if (!isTicketId(id)) {
        std.debug.print("invalid ticket id: {s}\n", .{id});
        std.process.exit(2);
    }
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const path = try ticketPath(allocator, repo, id);
    defer allocator.free(path);
    if (!fileExists(path)) {
        std.debug.print("ticket not found: {s}\n", .{id});
        std.process.exit(2);
    }

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);
    const old = parseMetaField(content, "status") orelse "";
    if (!std.mem.eql(u8, old, "ready") and !force) {
        std.debug.print("Refusing to claim: status is '{s}' (expected 'ready'). Use --force to override.\n", .{old});
        std.process.exit(2);
    }

    if (!ignore_deps) {
        const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
        const deps = std.mem.trim(u8, deps_raw, " \t\r[]");
        if (deps.len > 0) {
            var it = std.mem.splitScalar(u8, deps, ',');
            while (it.next()) |dep_item| {
                const dep = std.mem.trim(u8, dep_item, " \t\r\"'");
                if (dep.len == 0) continue;
                if (!depDone(repo, allocator, dep)) {
                    std.debug.print("Refusing to claim: dependencies not done: [{s}]. Use --ignore-deps to override.\n", .{dep});
                    std.process.exit(2);
                }
            }
        }
    }

    const next = try setMetaField(allocator, content, "status", "claimed");
    defer allocator.free(next);
    const next2 = try setMetaField(allocator, next, "owner", owner);
    defer allocator.free(next2);
    const title = parseMetaField(content, "title") orelse "task";
    const branch = try defaultBranch(allocator, id, title);
    defer allocator.free(branch);
    const next3 = try setMetaField(allocator, next2, "branch", branch);
    defer allocator.free(next3);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = next3 });
    std.debug.print("claimed {s} as {s} (branch: {s})\n", .{ id, owner, branch });
}

fn cmdSetStatus(allocator: std.mem.Allocator, id: []const u8, new_status: []const u8, force: bool) !void {
    if (!isTicketId(id)) {
        std.debug.print("invalid ticket id: {s}\n", .{id});
        std.process.exit(2);
    }
    if (!statusAllowed(new_status)) {
        std.debug.print("invalid status: {s}\n", .{new_status});
        std.process.exit(2);
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const path = try ticketPath(allocator, repo, id);
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        std.debug.print("ticket not found: {s}\n", .{id});
        std.process.exit(2);
    };
    defer allocator.free(content);

    const old = parseMetaField(content, "status") orelse "";
    if (std.mem.eql(u8, old, new_status)) {
        std.debug.print("{s} already {s}\n", .{ id, new_status });
        return;
    }

    if (!force and !transitionAllowed(old, new_status)) {
        std.debug.print("Refusing: invalid transition '{s}' -> '{s}'. Use --force to override.\n", .{ old, new_status });
        std.process.exit(2);
    }

    const next = try setMetaField(allocator, content, "status", new_status);
    defer allocator.free(next);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = next });
    std.debug.print("{s}: {s} -> {s}\n", .{ id, old, new_status });
}

fn cmdDone(allocator: std.mem.Allocator, id: []const u8, force: bool) !void {
    if (!isTicketId(id)) {
        std.debug.print("invalid ticket id: {s}\n", .{id});
        std.process.exit(2);
    }
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const path = try ticketPath(allocator, repo, id);
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        std.debug.print("ticket not found: {s}\n", .{id});
        std.process.exit(2);
    };
    defer allocator.free(content);
    const old = parseMetaField(content, "status") orelse "";
    if (!std.mem.eql(u8, old, "needs_review") and !force) {
        std.debug.print("Refusing to mark done: status is '{s}' (expected 'needs_review'). Use set-status first or --force.\n", .{old});
        std.process.exit(2);
    }
    const next = try setMetaField(allocator, content, "status", "done");
    defer allocator.free(next);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = next });
    std.debug.print("done {s}\n", .{id});
}

fn cmdArchive(allocator: std.mem.Allocator, id: []const u8, force: bool) !void {
    if (!isTicketId(id)) {
        std.debug.print("invalid ticket id: {s}\n", .{id});
        std.process.exit(2);
    }
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const src = try ticketPath(allocator, repo, id);
    defer allocator.free(src);
    const dst = try archivedTicketPath(allocator, repo, id);
    defer allocator.free(dst);

    const content = std.fs.cwd().readFileAlloc(allocator, src, 1024 * 1024) catch {
        std.debug.print("ticket not found: {s}\n", .{id});
        std.process.exit(2);
    };
    defer allocator.free(content);
    const status = parseMetaField(content, "status") orelse "";
    if (!std.mem.eql(u8, status, "done") and !force) {
        std.debug.print("Refusing to archive: status is '{s}' (expected 'done'). Use --force to override.\n", .{status});
        std.process.exit(2);
    }

    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    var dependents = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer dependents.deinit(allocator);
    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        if (std.mem.eql(u8, entry.name[0..8], id)) continue;
        const p = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(p);
        const tcontent = try std.fs.cwd().readFileAlloc(allocator, p, 1024 * 1024);
        defer allocator.free(tcontent);
        if (parseListContains(tcontent, "depends_on", id)) {
            const dep_id = parseMetaField(tcontent, "id") orelse entry.name[0..8];
            try dependents.append(allocator, dep_id);
        }
    }

    if (dependents.items.len > 0 and !force) {
        std.debug.print("Refusing to archive: active tickets depend on this ticket: ", .{});
        for (dependents.items, 0..) |dep, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{dep});
        }
        std.debug.print(". Resolve/update their depends_on first. Warning: using --force can leave invalid active references to archived tickets.\n", .{});
        std.process.exit(2);
    }

    if (dependents.items.len > 0 and force) {
        std.debug.print("Warning: force-archiving with active dependents: ", .{});
        for (dependents.items, 0..) |dep, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{dep});
        }
        std.debug.print(". This can create invalid board state where active tickets depends_on archived tickets.\n", .{});
    }

    const archive_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "archive" });
    defer allocator.free(archive_dir);
    if (!dirExists(archive_dir)) try std.fs.cwd().makePath(archive_dir);
    if (fileExists(dst)) {
        std.debug.print("Refusing to archive: destination already exists: {s}\n", .{dst});
        std.process.exit(2);
    }
    try std.fs.cwd().rename(src, dst);
    const rel = try std.fmt.allocPrint(allocator, "tickets/archive/{s}.md", .{id});
    defer allocator.free(rel);
    std.debug.print("archived {s} -> {s}\n", .{ id, rel });
}

fn cmdValidate(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        std.debug.print("MuonTickets validation OK.\n", .{});
        return;
    }

    var errors = try std.ArrayList([]u8).initCapacity(allocator, 16);
    defer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit(allocator);
    }

    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const p = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(p);
        const content = try std.fs.cwd().readFileAlloc(allocator, p, 1024 * 1024);
        defer allocator.free(content);

        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const status = parseMetaField(content, "status") orelse "";
        const owner = parseMetaField(content, "owner") orelse "null";
        const branch = parseMetaField(content, "branch") orelse "null";
        const effort = parseMetaField(content, "effort") orelse "s";

        if (!statusAllowed(status)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: invalid status {s}", .{ entry.name, status });
            try errors.append(allocator, msg);
        }
        if (!effortAllowed(effort)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: effort must be one of xs,s,m,l, got {s}", .{ entry.name, effort });
            try errors.append(allocator, msg);
        }
        if (std.mem.eql(u8, status, "claimed") and std.mem.eql(u8, owner, "null")) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: claimed ticket must have owner", .{entry.name});
            try errors.append(allocator, msg);
        }
        if ((std.mem.eql(u8, status, "needs_review") or std.mem.eql(u8, status, "done")) and std.mem.eql(u8, branch, "null")) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: status {s} should have branch set", .{ entry.name, status });
            try errors.append(allocator, msg);
        }

        const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
        const deps = std.mem.trim(u8, deps_raw, " \t\r[]");
        if (deps.len > 0) {
            var dit = std.mem.splitScalar(u8, deps, ',');
            while (dit.next()) |dep_item| {
                const dep = std.mem.trim(u8, dep_item, " \t\r\"'");
                if (dep.len == 0) continue;
                const dep_active = try ticketPath(allocator, repo, dep);
                defer allocator.free(dep_active);
                if (!fileExists(dep_active)) {
                    const dep_archived = try archivedTicketPath(allocator, repo, dep);
                    defer allocator.free(dep_archived);
                    if (fileExists(dep_archived)) {
                        const msg = try std.fmt.allocPrint(allocator, "{s} depends_on archived ticket {s} (fix by unarchiving {s} or removing/updating {s}.depends_on; avoid mt archive --force when active dependents exist)", .{ id, dep, dep, id });
                        try errors.append(allocator, msg);
                    } else {
                        const msg = try std.fmt.allocPrint(allocator, "{s} depends_on missing ticket {s}", .{ id, dep });
                        try errors.append(allocator, msg);
                    }
                }
            }
        }
    }

    if (errors.items.len > 0) {
        std.debug.print("MuonTickets validation FAILED:\n", .{});
        for (errors.items) |e| {
            std.debug.print(" - {s}\n", .{e});
        }
        std.process.exit(1);
    }
    std.debug.print("MuonTickets validation OK.\n", .{});
}

fn cmdLs(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tickets_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tickets_dir);
    if (!dirExists(tickets_dir)) return;

    std.debug.print("ID       STATUS        PR TYPE     EF OWNER         TITLE  [LABELS]\n", .{});
    std.debug.print("--------------------------------------------------------------------------------------------------------------\n", .{});

    var dir = try std.fs.cwd().openDir(tickets_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isTicketFilename(entry.name)) continue;
        const full = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, entry.name });
        defer allocator.free(full);
        const content = try std.fs.cwd().readFileAlloc(allocator, full, 1024 * 1024);
        defer allocator.free(content);

        const id = parseMetaField(content, "id") orelse "?";
        const status = parseMetaField(content, "status") orelse "?";
        const pr = parseMetaField(content, "priority") orelse "?";
        const tp = parseMetaField(content, "type") orelse "?";
        const effort = parseMetaField(content, "effort") orelse "?";
        const owner = parseMetaField(content, "owner") orelse "";
        const title = parseMetaField(content, "title") orelse "";
        const labels = parseMetaField(content, "labels") orelse "[]";

        std.debug.print("{s}  {s}  {s} {s} {s} {s}  {s}  {s}\n", .{ id, status, pr, tp, effort, owner, title, labels });
    }
}

fn cmdShow(allocator: std.mem.Allocator, id: []const u8) !void {
    if (!isTicketId(id)) {
        std.debug.print("invalid ticket id: {s}\n", .{id});
        std.process.exit(2);
    }
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{id});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", file_name });
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        std.debug.print("ticket not found: {s}\n", .{id});
        std.process.exit(2);
    };
    defer allocator.free(content);
    std.debug.print("{s}", .{content});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const arg = args[1];
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        printHelp();
        return;
    }

    const command = parseCommand(arg) orelse {
        std.debug.print("unknown command: {s}\n\n", .{arg});
        printHelp();
        std.process.exit(2);
    };

    switch (command) {
        .init => try cmdInit(allocator),
        .new => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig new <title>\n", .{});
                std.process.exit(2);
            }
            try cmdNew(allocator, args[2]);
        },
        .ls => try cmdLs(allocator),
        .show => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig show <id>\n", .{});
                std.process.exit(2);
            }
            try cmdShow(allocator, args[2]);
        },
        .pick => std.debug.print("TODO: pick (zig port)\n", .{}),
        .claim => {
            if (args.len < 4) {
                std.debug.print("usage: mt-zig claim <id> --owner <owner> [--force] [--ignore-deps]\n", .{});
                std.process.exit(2);
            }
            const owner = getOptValue(args[3..], "--owner") orelse {
                std.debug.print("claim requires --owner <owner>\n", .{});
                std.process.exit(2);
            };
            try cmdClaim(allocator, args[2], owner, hasFlag(args[3..], "--force"), hasFlag(args[3..], "--ignore-deps"));
        },
        .comment => std.debug.print("TODO: comment (zig port)\n", .{}),
        .set_status => {
            if (args.len < 4) {
                std.debug.print("usage: mt-zig set-status <id> <status> [--force]\n", .{});
                std.process.exit(2);
            }
            try cmdSetStatus(allocator, args[2], args[3], hasFlag(args[4..], "--force"));
        },
        .done => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig done <id> [--force]\n", .{});
                std.process.exit(2);
            }
            try cmdDone(allocator, args[2], hasFlag(args[3..], "--force"));
        },
        .archive => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig archive <id> [--force]\n", .{});
                std.process.exit(2);
            }
            try cmdArchive(allocator, args[2], hasFlag(args[3..], "--force"));
        },
        .graph => std.debug.print("TODO: graph (zig port)\n", .{}),
        .@"export" => std.debug.print("TODO: export (zig port)\n", .{}),
        .stats => std.debug.print("TODO: stats (zig port)\n", .{}),
        .validate => try cmdValidate(allocator),
        .report => std.debug.print("TODO: report (zig port)\n", .{}),
    }
}
