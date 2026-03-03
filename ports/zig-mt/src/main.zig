const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

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
const priorities = [_][]const u8{ "p0", "p1", "p2", "p3" };
const ticket_types = [_][]const u8{ "code", "doc", "test", "research", "ops", "chore" };

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
            if (std.mem.eql(u8, root_rel, "tickets") and std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) != null) {
                continue;
            }
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

fn cmdNew(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    if (cmd_args.len < 1) {
        std.debug.print("usage: mt-zig new <title> [--priority <p0|p1|p2|p3>] [--type <code|doc|test|research|ops|chore>] [--effort <xs|s|m|l>] [--label <label>]... [--depends-on <T-xxxxxx>]... [--goal <text>]\n", .{});
        std.process.exit(2);
    }

    const title = std.mem.trim(u8, cmd_args[0], " \t\r\n");
    if (title.len == 0) {
        std.debug.print("new requires non-empty title\n", .{});
        std.process.exit(2);
    }

    var priority: []const u8 = "p1";
    var ticket_type: []const u8 = "code";
    var effort: []const u8 = "s";
    var goal: []const u8 = "";
    var labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer labels.deinit(allocator);
    var depends_on = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer depends_on.deinit(allocator);

    var i: usize = 1;
    while (i < cmd_args.len) : (i += 1) {
        const a = cmd_args[i];
        if (std.mem.eql(u8, a, "--priority")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--priority requires a value\n", .{});
                std.process.exit(2);
            }
            priority = cmd_args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--type")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--type requires a value\n", .{});
                std.process.exit(2);
            }
            ticket_type = cmd_args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--effort")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--effort requires a value\n", .{});
                std.process.exit(2);
            }
            effort = cmd_args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--label")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try labels.append(allocator, cmd_args[i + 1]);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--depends-on")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--depends-on requires a value\n", .{});
                std.process.exit(2);
            }
            const dep_id = cmd_args[i + 1];
            if (!isTicketId(dep_id)) {
                std.debug.print("invalid dependency ticket id: {s}\n", .{dep_id});
                std.process.exit(2);
            }
            try depends_on.append(allocator, dep_id);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--goal")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--goal requires a value\n", .{});
                std.process.exit(2);
            }
            goal = cmd_args[i + 1];
            i += 1;
            continue;
        }
        std.debug.print("unknown option for new: {s}\n", .{a});
        std.process.exit(2);
    }

    if (!priorityAllowed(priority)) {
        std.debug.print("invalid priority: {s}\n", .{priority});
        std.process.exit(2);
    }
    if (!typeAllowed(ticket_type)) {
        std.debug.print("invalid type: {s}\n", .{ticket_type});
        std.process.exit(2);
    }
    if (!effortAllowed(effort)) {
        std.debug.print("invalid effort: {s}\n", .{effort});
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

    const labels_literal = try listLiteral(allocator, labels.items);
    defer allocator.free(labels_literal);
    const depends_literal = try listLiteral(allocator, depends_on.items);
    defer allocator.free(depends_literal);

    const body = if (goal.len > 0)
        try std.fmt.allocPrint(
            allocator,
            \\## Goal
            \\{s}
            \\
            \\## Acceptance Criteria
            \\- [ ] Define clear, testable checks (2–5 items)
            \\
            \\## Notes
            \\
        ,
            .{goal},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            \\## Goal
            \\Write a single-sentence goal.
            \\
            \\## Acceptance Criteria
            \\- [ ] Define clear, testable checks (2–5 items)
            \\
            \\## Notes
            \\
        ,
            .{},
        );
    defer allocator.free(body);

    try writeTicketFile(allocator, ticket_path, tid, title, "ready", priority, ticket_type, effort, labels_literal, body);

    const written = try std.fs.cwd().readFileAlloc(allocator, ticket_path, 1024 * 1024);
    defer allocator.free(written);
    const with_depends = try setMetaField(allocator, written, "depends_on", depends_literal);
    defer allocator.free(with_depends);
    try std.fs.cwd().writeFile(.{ .sub_path = ticket_path, .data = with_depends });

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

fn listItems(allocator: std.mem.Allocator, raw_list: []const u8) !std.ArrayList([]u8) {
    var out = try std.ArrayList([]u8).initCapacity(allocator, 8);
    const trimmed = std.mem.trim(u8, raw_list, " \t\r[]");
    if (trimmed.len == 0) return out;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const value = std.mem.trim(u8, item, " \t\r\"'");
        if (value.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, value));
    }
    return out;
}

fn freeListItems(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |v| allocator.free(v);
    items.deinit(allocator);
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

fn priorityAllowed(priority: []const u8) bool {
    for (priorities) |p| {
        if (std.mem.eql(u8, p, priority)) return true;
    }
    return false;
}

fn typeAllowed(ticket_type: []const u8) bool {
    for (ticket_types) |t| {
        if (std.mem.eql(u8, t, ticket_type)) return true;
    }
    return false;
}

fn listLiteral(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 32 + (items.len * 16));
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '"');
        try out.appendSlice(allocator, item);
        try out.append(allocator, '"');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
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
        const lower_ch = std.ascii.toLower(ch);
        if ((lower_ch >= 'a' and lower_ch <= 'z') or (lower_ch >= '0' and lower_ch <= '9')) {
            try buf.append(allocator, lower_ch);
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

fn depsSatisfied(repo: []const u8, allocator: std.mem.Allocator, content: []const u8) bool {
    const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
    var deps = listItems(allocator, deps_raw) catch return false;
    defer freeListItems(allocator, &deps);
    for (deps.items) |dep| {
        if (!depDone(repo, allocator, dep)) return false;
    }
    return true;
}

fn cmdClaim(allocator: std.mem.Allocator, id: []const u8, owner: []const u8, branch_opt: ?[]const u8, force: bool, ignore_deps: bool) !void {
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
    const branch = if (branch_opt) |b| try allocator.dupe(u8, b) else try defaultBranch(allocator, id, title);
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

fn cmdComment(allocator: std.mem.Allocator, id: []const u8, text: []const u8) !void {
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

    var out = try std.ArrayList(u8).initCapacity(allocator, content.len + text.len + 128);
    defer out.deinit(allocator);
    try out.appendSlice(allocator, content);
    if (!std.mem.containsAtLeast(u8, content, 1, "## Progress Log")) {
        if (!std.mem.endsWith(u8, content, "\n")) try out.append(allocator, '\n');
        try out.appendSlice(allocator, "\n## Progress Log\n");
    }
    try out.appendSlice(allocator, "- 1970-01-01: ");
    try out.appendSlice(allocator, text);
    try out.append(allocator, '\n');

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
    std.debug.print("commented on {s}\n", .{id});
}

fn cmdPick(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const owner = getOptValue(cmd_args, "--owner") orelse {
        std.debug.print("pick requires --owner <owner>\n", .{});
        std.process.exit(2);
    };
    const priority_filter = getOptValue(cmd_args, "--priority");
    if (priority_filter != null and !priorityAllowed(priority_filter.?)) {
        std.debug.print("invalid priority: {s}\n", .{priority_filter.?});
        std.process.exit(2);
    }
    const type_filter = getOptValue(cmd_args, "--type");
    if (type_filter != null and !typeAllowed(type_filter.?)) {
        std.debug.print("invalid type: {s}\n", .{type_filter.?});
        std.process.exit(2);
    }
    const explicit_branch = getOptValue(cmd_args, "--branch");
    const ignore_deps = hasFlag(cmd_args, "--ignore-deps");
    const json_out = hasFlag(cmd_args, "--json");
    const max_claimed_raw = getOptValue(cmd_args, "--max-claimed-per-owner") orelse "2";
    const max_claimed = std.fmt.parseInt(u32, max_claimed_raw, 10) catch {
        std.debug.print("invalid --max-claimed-per-owner: {s}\n", .{max_claimed_raw});
        std.process.exit(2);
    };

    var required_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit(allocator);
    var avoid_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer avoid_labels.deinit(allocator);
    var arg_i: usize = 0;
    while (arg_i < cmd_args.len) : (arg_i += 1) {
        const a = cmd_args[arg_i];
        if (std.mem.eql(u8, a, "--label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try required_labels.append(allocator, cmd_args[arg_i + 1]);
            arg_i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--avoid-label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--avoid-label requires a value\n", .{});
                std.process.exit(2);
            }
            try avoid_labels.append(allocator, cmd_args[arg_i + 1]);
            arg_i += 1;
            continue;
        }
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        std.debug.print("no claimable tickets found (ready + deps satisfied + filters).\n", .{});
        std.process.exit(3);
    }

    var claimed_count: u32 = 0;
    var count_dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer count_dir.close();
    var count_it = count_dir.iterate();
    while (try count_it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const count_path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(count_path);
        const count_content = try std.fs.cwd().readFileAlloc(allocator, count_path, 1024 * 1024);
        defer allocator.free(count_content);
        const status = parseMetaField(count_content, "status") orelse "";
        const ticket_owner = parseMetaField(count_content, "owner") orelse "";
        if (std.mem.eql(u8, status, "claimed") and std.mem.eql(u8, ticket_owner, owner)) {
            claimed_count += 1;
        }
    }
    if (claimed_count >= max_claimed) {
        std.debug.print("owner '{s}' already has {d} claimed tickets (max {d}).\n", .{ owner, claimed_count, max_claimed });
        std.process.exit(2);
    }

    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);
        const status = parseMetaField(content, "status") orelse "";
        if (!std.mem.eql(u8, status, "ready")) continue;

        if (priority_filter) |pf| {
            const p = parseMetaField(content, "priority") orelse "";
            if (!std.mem.eql(u8, p, pf)) continue;
        }
        if (type_filter) |tf| {
            const tp = parseMetaField(content, "type") orelse "";
            if (!std.mem.eql(u8, tp, tf)) continue;
        }
        var labels_ok = true;
        for (required_labels.items) |label| {
            if (!parseListContains(content, "labels", label)) {
                labels_ok = false;
                break;
            }
        }
        if (!labels_ok) continue;
        var avoid_hit = false;
        for (avoid_labels.items) |label| {
            if (parseListContains(content, "labels", label)) {
                avoid_hit = true;
                break;
            }
        }
        if (avoid_hit) continue;
        if (!ignore_deps and !depsSatisfied(repo, allocator, content)) continue;

        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const title = parseMetaField(content, "title") orelse "task";
        const branch = if (explicit_branch) |b| try allocator.dupe(u8, b) else try defaultBranch(allocator, id, title);
        defer allocator.free(branch);

        const next = try setMetaField(allocator, content, "status", "claimed");
        defer allocator.free(next);
        const next2 = try setMetaField(allocator, next, "owner", owner);
        defer allocator.free(next2);
        const next3 = try setMetaField(allocator, next2, "branch", branch);
        defer allocator.free(next3);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = next3 });
        if (json_out) {
            std.debug.print("{{\"picked\":\"{s}\",\"owner\":\"{s}\",\"branch\":\"{s}\",\"score\":0.0}}\n", .{ id, owner, branch });
        } else {
            std.debug.print("picked {s} (score 0.0) -> claimed as {s} (branch: {s})\n", .{ id, owner, branch });
        }
        return;
    }

    std.debug.print("no claimable tickets found (ready + deps satisfied + filters).\n", .{});
    std.process.exit(3);
}

fn cmdGraph(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) return;

    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);
        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
        var deps = try listItems(allocator, deps_raw);
        defer freeListItems(allocator, &deps);
        for (deps.items) |dep| {
            std.debug.print("{s} -> {s}\n", .{ dep, id });
        }
    }
}

fn cmdExport(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        std.debug.print("[]\n", .{});
        return;
    }

    std.debug.print("[\n", .{});
    var first = true;
    var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);
        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const title = parseMetaField(content, "title") orelse "";
        const status = parseMetaField(content, "status") orelse "";
        const priority = parseMetaField(content, "priority") orelse "";
        const tp = parseMetaField(content, "type") orelse "";
        const effort = parseMetaField(content, "effort") orelse "";
        if (!first) std.debug.print(",\n", .{});
        first = false;
        std.debug.print("  {{\"id\":\"{s}\",\"title\":\"{s}\",\"status\":\"{s}\",\"priority\":\"{s}\",\"type\":\"{s}\",\"effort\":\"{s}\"}}", .{ id, title, status, priority, tp, effort });
    }
    std.debug.print("\n]\n", .{});
}

fn cmdStats(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    var ready: u32 = 0;
    var claimed: u32 = 0;
    var blocked: u32 = 0;
    var needs_review: u32 = 0;
    var done: u32 = 0;
    if (dirExists(tdir)) {
        var dir = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
            const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
            defer allocator.free(path);
            const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
            defer allocator.free(content);
            const st = parseMetaField(content, "status") orelse "";
            if (std.mem.eql(u8, st, "ready")) ready += 1;
            if (std.mem.eql(u8, st, "claimed")) claimed += 1;
            if (std.mem.eql(u8, st, "blocked")) blocked += 1;
            if (std.mem.eql(u8, st, "needs_review")) needs_review += 1;
            if (std.mem.eql(u8, st, "done")) done += 1;
        }
    }
    std.debug.print("Status counts:\n", .{});
    std.debug.print("  ready        {d}\n", .{ready});
    std.debug.print("  claimed      {d}\n", .{claimed});
    std.debug.print("  blocked      {d}\n", .{blocked});
    std.debug.print("  needs_review {d}\n", .{needs_review});
    std.debug.print("  done         {d}\n", .{done});
}

const ReportRow = struct {
    id: []u8,
    title: []u8,
    status: []u8,
    priority: []u8,
    ticket_type: []u8,
    effort: []u8,
    owner: []u8,
    created: []u8,
    updated: []u8,
    branch: []u8,
    depends_on: []u8,
    labels: []u8,
    tags: []u8,
    bucket: []u8,
    is_archived: i32,
    path: []u8,
    body: []u8,
};

fn sqliteOk(rc: c_int) bool {
    return rc == c.SQLITE_OK or rc == c.SQLITE_DONE or rc == c.SQLITE_ROW;
}

fn sqliteCheck(db: *c.sqlite3, rc: c_int, context: []const u8) !void {
    if (sqliteOk(rc)) return;
    const msg_ptr = c.sqlite3_errmsg(db);
    const msg = if (msg_ptr != null) std.mem.span(msg_ptr) else "unknown sqlite error";
    std.debug.print("sqlite error ({s}): {s}\n", .{ context, msg });
    return error.SqliteError;
}

fn sqliteExec(db: *c.sqlite3, sql: []const u8) !void {
    const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
    defer std.heap.c_allocator.free(sql_z);
    const rc = c.sqlite3_exec(db, sql_z.ptr, null, null, null);
    if (rc != c.SQLITE_OK) {
        const msg_ptr = c.sqlite3_errmsg(db);
        const msg = if (msg_ptr != null) std.mem.span(msg_ptr) else "sqlite exec failed";
        std.debug.print("sqlite exec error: {s}\n", .{msg});
        return error.SqliteError;
    }
}

fn sqliteBindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) !void {
    const rc = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn cmdReport(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);

    var db_rel: []const u8 = "tickets/tickets_report.sqlite3";
    var search: []const u8 = "";
    var limit: usize = 30;
    var summary = true;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const a = cmd_args[i];
        if (std.mem.eql(u8, a, "--db")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--db requires a value\n", .{});
                std.process.exit(2);
            }
            db_rel = cmd_args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--search")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--search requires a value\n", .{});
                std.process.exit(2);
            }
            search = cmd_args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--limit")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--limit requires a value\n", .{});
                std.process.exit(2);
            }
            limit = std.fmt.parseInt(usize, cmd_args[i + 1], 10) catch {
                std.debug.print("invalid --limit: {s}\n", .{cmd_args[i + 1]});
                std.process.exit(2);
            };
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--summary")) {
            summary = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-summary")) {
            summary = false;
            continue;
        }
    }

    const db_path = if (std.fs.path.isAbsolute(db_rel))
        try allocator.dupe(u8, db_rel)
    else
        try std.fs.path.join(allocator, &[_][]const u8{ repo, db_rel });
    defer allocator.free(db_path);

    if (std.fs.path.dirname(db_path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    var rows = try std.ArrayList(ReportRow).initCapacity(allocator, 64);
    var seen_paths = std.StringHashMap(void).init(allocator);
    defer {
        for (rows.items) |row| {
            allocator.free(row.id);
            allocator.free(row.title);
            allocator.free(row.status);
            allocator.free(row.priority);
            allocator.free(row.ticket_type);
            allocator.free(row.effort);
            allocator.free(row.owner);
            allocator.free(row.created);
            allocator.free(row.updated);
            allocator.free(row.branch);
            allocator.free(row.depends_on);
            allocator.free(row.labels);
            allocator.free(row.tags);
            allocator.free(row.bucket);
            allocator.free(row.path);
            allocator.free(row.body);
        }
        rows.deinit(allocator);

        var key_it = seen_paths.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        seen_paths.deinit();
    }

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
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ root, entry.path });
            defer allocator.free(full_path);
            const content = try std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024);
            defer allocator.free(content);

            const rel = try std.fs.path.join(allocator, &[_][]const u8{ root_rel, entry.path });
            defer allocator.free(rel);
            if (seen_paths.contains(rel)) continue;
            try seen_paths.put(try allocator.dupe(u8, rel), {});

            try rows.append(allocator, .{
                .id = try allocator.dupe(u8, parseMetaField(content, "id") orelse base[0..8]),
                .title = try allocator.dupe(u8, parseMetaField(content, "title") orelse ""),
                .status = try allocator.dupe(u8, parseMetaField(content, "status") orelse ""),
                .priority = try allocator.dupe(u8, parseMetaField(content, "priority") orelse ""),
                .ticket_type = try allocator.dupe(u8, parseMetaField(content, "type") orelse ""),
                .effort = try allocator.dupe(u8, parseMetaField(content, "effort") orelse ""),
                .owner = try allocator.dupe(u8, parseMetaField(content, "owner") orelse ""),
                .created = try allocator.dupe(u8, parseMetaField(content, "created") orelse ""),
                .updated = try allocator.dupe(u8, parseMetaField(content, "updated") orelse ""),
                .branch = try allocator.dupe(u8, parseMetaField(content, "branch") orelse ""),
                .depends_on = try allocator.dupe(u8, parseMetaField(content, "depends_on") orelse "[]"),
                .labels = try allocator.dupe(u8, parseMetaField(content, "labels") orelse "[]"),
                .tags = try allocator.dupe(u8, parseMetaField(content, "tags") orelse "[]"),
                .bucket = try allocator.dupe(u8, if (std.mem.eql(u8, root_rel, "tickets/archive")) "archive" else if (std.mem.eql(u8, root_rel, "tickets/backlogs")) "backlogs" else "tickets"),
                .is_archived = if (std.mem.eql(u8, root_rel, "tickets/archive")) 1 else 0,
                .path = try allocator.dupe(u8, rel),
                .body = try allocator.dupe(u8, content),
            });
        }
    }

    var db_ptr: ?*c.sqlite3 = null;
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const open_rc = c.sqlite3_open(db_path_z.ptr, &db_ptr);
    if (open_rc != c.SQLITE_OK or db_ptr == null) {
        if (db_ptr) |db| {
            defer _ = c.sqlite3_close(db);
            const msg_ptr = c.sqlite3_errmsg(db);
            const msg = if (msg_ptr != null) std.mem.span(msg_ptr) else "unknown sqlite open error";
            std.debug.print("sqlite open error: {s}\n", .{msg});
        } else {
            std.debug.print("sqlite open error\n", .{});
        }
        return error.SqliteError;
    }
    const db = db_ptr.?;
    defer _ = c.sqlite3_close(db);

    const schema_sql =
        \\DROP TABLE IF EXISTS tickets;
        \\DROP TABLE IF EXISTS parse_errors;
        \\CREATE TABLE tickets (
        \\  id TEXT,
        \\  title TEXT,
        \\  status TEXT,
        \\  priority TEXT,
        \\  type TEXT,
        \\  effort TEXT,
        \\  owner TEXT,
        \\  created TEXT,
        \\  updated TEXT,
        \\  branch TEXT,
        \\  labels_json TEXT,
        \\  tags_json TEXT,
        \\  depends_on_json TEXT,
        \\  path TEXT PRIMARY KEY,
        \\  bucket TEXT,
        \\  is_archived INTEGER,
        \\  body TEXT
        \\);
        \\CREATE TABLE parse_errors (
        \\  path TEXT PRIMARY KEY,
        \\  error TEXT
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
        \\CREATE INDEX IF NOT EXISTS idx_tickets_priority ON tickets(priority);
        \\CREATE INDEX IF NOT EXISTS idx_tickets_owner ON tickets(owner);
    ;
    try sqliteExec(db, schema_sql);

    const insert_sql = "INSERT INTO tickets (id, title, status, priority, type, effort, owner, created, updated, branch, labels_json, tags_json, depends_on_json, path, bucket, is_archived, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
    const insert_sql_z = try allocator.dupeZ(u8, insert_sql);
    defer allocator.free(insert_sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    try sqliteCheck(db, c.sqlite3_prepare_v2(db, insert_sql_z.ptr, -1, &stmt, null), "prepare insert");
    defer _ = c.sqlite3_finalize(stmt);

    for (rows.items) |row| {
        try sqliteCheck(db, c.sqlite3_reset(stmt), "reset insert");
        try sqliteCheck(db, c.sqlite3_clear_bindings(stmt), "clear bindings");
        try sqliteBindText(stmt.?, 1, row.id);
        try sqliteBindText(stmt.?, 2, row.title);
        try sqliteBindText(stmt.?, 3, row.status);
        try sqliteBindText(stmt.?, 4, row.priority);
        try sqliteBindText(stmt.?, 5, row.ticket_type);
        try sqliteBindText(stmt.?, 6, row.effort);
        try sqliteBindText(stmt.?, 7, row.owner);
        try sqliteBindText(stmt.?, 8, row.created);
        try sqliteBindText(stmt.?, 9, row.updated);
        try sqliteBindText(stmt.?, 10, row.branch);
        try sqliteBindText(stmt.?, 11, row.labels);
        try sqliteBindText(stmt.?, 12, row.tags);
        try sqliteBindText(stmt.?, 13, row.depends_on);
        try sqliteBindText(stmt.?, 14, row.path);
        try sqliteBindText(stmt.?, 15, row.bucket);
        _ = c.sqlite3_bind_int(stmt.?, 16, row.is_archived);
        try sqliteBindText(stmt.?, 17, row.body);
        try sqliteCheck(db, c.sqlite3_step(stmt), "insert row");
    }

    std.debug.print("report db: {s}\n", .{db_path});
    std.debug.print("indexed tickets: {d}\n", .{rows.items.len});

    if (summary) {
        std.debug.print("\nBy status:\n", .{});
        const by_status_sql = "SELECT COALESCE(status, '<none>'), COUNT(*) FROM tickets GROUP BY status ORDER BY COUNT(*) DESC;";
        const by_status_sql_z = try allocator.dupeZ(u8, by_status_sql);
        defer allocator.free(by_status_sql_z);
        var status_stmt: ?*c.sqlite3_stmt = null;
        try sqliteCheck(db, c.sqlite3_prepare_v2(db, by_status_sql_z.ptr, -1, &status_stmt, null), "prepare by status");
        defer _ = c.sqlite3_finalize(status_stmt);
        while (true) {
            const rc = c.sqlite3_step(status_stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteError;
            const status_ptr = c.sqlite3_column_text(status_stmt, 0);
            const count = c.sqlite3_column_int(status_stmt, 1);
            const status_text: []const u8 = if (status_ptr != null) std.mem.span(status_ptr) else "<none>";
            std.debug.print("  {s:<12} {d}\n", .{ status_text, count });
        }

        std.debug.print("\nBy priority:\n", .{});
        const by_priority_sql = "SELECT COALESCE(priority, '<none>'), COUNT(*) FROM tickets GROUP BY priority ORDER BY COUNT(*) DESC;";
        const by_priority_sql_z = try allocator.dupeZ(u8, by_priority_sql);
        defer allocator.free(by_priority_sql_z);
        var priority_stmt: ?*c.sqlite3_stmt = null;
        try sqliteCheck(db, c.sqlite3_prepare_v2(db, by_priority_sql_z.ptr, -1, &priority_stmt, null), "prepare by priority");
        defer _ = c.sqlite3_finalize(priority_stmt);
        while (true) {
            const rc = c.sqlite3_step(priority_stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteError;
            const priority_ptr = c.sqlite3_column_text(priority_stmt, 0);
            const count = c.sqlite3_column_int(priority_stmt, 1);
            const priority_text: []const u8 = if (priority_ptr != null) std.mem.span(priority_ptr) else "<none>";
            std.debug.print("  {s:<8} {d}\n", .{ priority_text, count });
        }

        std.debug.print("\nCompleted by owner:\n", .{});
        const by_owner_sql =
            "SELECT COALESCE(NULLIF(owner, ''), '<unowned>'), COUNT(*) " ++
            "FROM tickets WHERE status = 'done' GROUP BY owner ORDER BY COUNT(*) DESC;";
        const by_owner_sql_z = try allocator.dupeZ(u8, by_owner_sql);
        defer allocator.free(by_owner_sql_z);
        var owner_stmt: ?*c.sqlite3_stmt = null;
        try sqliteCheck(db, c.sqlite3_prepare_v2(db, by_owner_sql_z.ptr, -1, &owner_stmt, null), "prepare by owner");
        defer _ = c.sqlite3_finalize(owner_stmt);
        while (true) {
            const rc = c.sqlite3_step(owner_stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteError;
            const owner_ptr = c.sqlite3_column_text(owner_stmt, 0);
            const count = c.sqlite3_column_int(owner_stmt, 1);
            const owner_text: []const u8 = if (owner_ptr != null) std.mem.span(owner_ptr) else "<unowned>";
            std.debug.print("  {s:<20} {d}\n", .{ owner_text, count });
        }
    }

    if (search.len > 0) {
        std.debug.print("\nSearch results for: '{s}'\n", .{search});
        const search_sql =
            "SELECT COALESCE(id, '<no-id>'), COALESCE(title, ''), COALESCE(status, ''), " ++
            "COALESCE(owner, ''), path FROM tickets " ++
            "WHERE id LIKE ?1 OR title LIKE ?1 OR body LIKE ?1 OR labels_json LIKE ?1 OR tags_json LIKE ?1 " ++
            "ORDER BY updated DESC, id ASC LIMIT ?2;";
        const search_sql_z = try allocator.dupeZ(u8, search_sql);
        defer allocator.free(search_sql_z);
        var search_stmt: ?*c.sqlite3_stmt = null;
        try sqliteCheck(db, c.sqlite3_prepare_v2(db, search_sql_z.ptr, -1, &search_stmt, null), "prepare search");
        defer _ = c.sqlite3_finalize(search_stmt);

        const q = try std.fmt.allocPrint(allocator, "%{s}%", .{search});
        defer allocator.free(q);
        try sqliteBindText(search_stmt.?, 1, q);
        _ = c.sqlite3_bind_int(search_stmt.?, 2, @intCast(limit));

        while (true) {
            const rc = c.sqlite3_step(search_stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteError;
            const id_ptr = c.sqlite3_column_text(search_stmt, 0);
            const title_ptr = c.sqlite3_column_text(search_stmt, 1);
            const status_ptr = c.sqlite3_column_text(search_stmt, 2);
            const owner_ptr = c.sqlite3_column_text(search_stmt, 3);
            const path_ptr = c.sqlite3_column_text(search_stmt, 4);

            const id_text: []const u8 = if (id_ptr != null) std.mem.span(id_ptr) else "<no-id>";
            const title_text: []const u8 = if (title_ptr != null) std.mem.span(title_ptr) else "";
            const status_text: []const u8 = if (status_ptr != null) std.mem.span(status_ptr) else "";
            const owner_text: []const u8 = if (owner_ptr != null) std.mem.span(owner_ptr) else "";
            const path_text: []const u8 = if (path_ptr != null) std.mem.span(path_ptr) else "";

            std.debug.print("  {s}  {s:<12} {s:<12} {s}  ({s})\n", .{ id_text, status_text, owner_text, title_text, path_text });
        }
    }
}

fn cmdLs(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const status_filter = getOptValue(cmd_args, "--status");
    if (status_filter != null and !statusAllowed(status_filter.?)) {
        std.debug.print("invalid status: {s}\n", .{status_filter.?});
        std.process.exit(2);
    }
    const owner_filter = getOptValue(cmd_args, "--owner");
    const priority_filter = getOptValue(cmd_args, "--priority");
    if (priority_filter != null and !priorityAllowed(priority_filter.?)) {
        std.debug.print("invalid priority: {s}\n", .{priority_filter.?});
        std.process.exit(2);
    }
    const type_filter = getOptValue(cmd_args, "--type");
    if (type_filter != null and !typeAllowed(type_filter.?)) {
        std.debug.print("invalid type: {s}\n", .{type_filter.?});
        std.process.exit(2);
    }
    var required_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit(allocator);
    var label_i: usize = 0;
    while (label_i < cmd_args.len) : (label_i += 1) {
        if (std.mem.eql(u8, cmd_args[label_i], "--label")) {
            if (label_i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try required_labels.append(allocator, cmd_args[label_i + 1]);
            label_i += 1;
        }
    }

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

        if (status_filter) |sf| {
            if (!std.mem.eql(u8, status, sf)) continue;
        }
        if (owner_filter) |of| {
            if (of.len == 0) {
                if (!std.mem.eql(u8, owner, "null")) continue;
            } else if (!std.mem.eql(u8, owner, of)) {
                continue;
            }
        }
        if (priority_filter) |pf| {
            if (!std.mem.eql(u8, pr, pf)) continue;
        }
        if (type_filter) |tf| {
            if (!std.mem.eql(u8, tp, tf)) continue;
        }
        var labels_ok = true;
        for (required_labels.items) |label| {
            if (!parseListContains(content, "labels", label)) {
                labels_ok = false;
                break;
            }
        }
        if (!labels_ok) continue;

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
        .new => try cmdNew(allocator, args[2..]),
        .ls => try cmdLs(allocator, args[2..]),
        .show => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig show <id>\n", .{});
                std.process.exit(2);
            }
            try cmdShow(allocator, args[2]);
        },
        .pick => try cmdPick(allocator, args[2..]),
        .claim => {
            if (args.len < 4) {
                std.debug.print("usage: mt-zig claim <id> --owner <owner> [--branch <name>] [--force] [--ignore-deps]\n", .{});
                std.process.exit(2);
            }
            const owner = getOptValue(args[3..], "--owner") orelse {
                std.debug.print("claim requires --owner <owner>\n", .{});
                std.process.exit(2);
            };
            const branch = getOptValue(args[3..], "--branch");
            try cmdClaim(allocator, args[2], owner, branch, hasFlag(args[3..], "--force"), hasFlag(args[3..], "--ignore-deps"));
        },
        .comment => {
            if (args.len < 4) {
                std.debug.print("usage: mt-zig comment <id> <text>\n", .{});
                std.process.exit(2);
            }
            try cmdComment(allocator, args[2], args[3]);
        },
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
        .graph => try cmdGraph(allocator),
        .@"export" => try cmdExport(allocator),
        .stats => try cmdStats(allocator),
        .validate => try cmdValidate(allocator),
        .report => try cmdReport(allocator, args[2..]),
    }
}
