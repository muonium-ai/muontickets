const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const builtin = @import("builtin");

const Command = enum {
    init,
    new,
    ls,
    show,
    pick,
    allocate_task,
    fail_task,
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
    version,
};

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "new")) return .new;
    if (std.mem.eql(u8, raw, "ls")) return .ls;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "pick")) return .pick;
    if (std.mem.eql(u8, raw, "allocate-task")) return .allocate_task;
    if (std.mem.eql(u8, raw, "fail-task")) return .fail_task;
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
    if (std.mem.eql(u8, raw, "version")) return .version;
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
        \\  allocate-task
        \\  fail-task
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
        \\  version
        \\ 
        \\Implemented: all listed commands
        \\ 
    , .{});
}

const statuses = [_][]const u8{ "ready", "claimed", "blocked", "needs_review", "done" };
const efforts = [_][]const u8{ "xs", "s", "m", "l" };
const priorities = [_][]const u8{ "p0", "p1", "p2" };
const ticket_types = [_][]const u8{ "spec", "code", "tests", "docs", "refactor", "chore" };

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

fn printStdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try std.io.getStdOut().writeAll(message);
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
    try std.fs.cwd().writeFile(path, text);
}

fn scanMaxTicketNumber(allocator: std.mem.Allocator, repo: []const u8) !u32 {
    const roots = [_][]const u8{ "tickets", "tickets/archive" };
    var max_num: u32 = 0;

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
    const today = try todayIsoDate(allocator);
    defer allocator.free(today);
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
        \\created: {s}
        \\updated: {s}
        \\depends_on: []
        \\branch: null
        \\---
        \\
        \\{s}
    ,
        .{ id, title, status, priority, ticket_type, effort, labels, today, today, body },
    );
    defer allocator.free(text);
    try std.fs.cwd().writeFile(path, text);
}

fn cmdInit(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);

    const tickets_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tickets_dir);

    if (!dirExists(tickets_dir)) {
        try std.fs.cwd().makePath(tickets_dir);
        try printStdout(allocator, "created {s}\n", .{tickets_dir});
    } else {
        try printStdout(allocator, "tickets dir exists: {s}\n", .{tickets_dir});
    }

    const template_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, "ticket.template" });
    defer allocator.free(template_path);
    if (!fileExists(template_path)) {
        try std.fs.cwd().writeFile(template_path, default_template);
        try printStdout(allocator, "created {s}\n", .{template_path});
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
        try printStdout(allocator, "created example ticket {s}\n", .{tid});
    } else {
        const tracked = try readLastTicketNumber(allocator, repo);
        const scanned = try scanMaxTicketNumber(allocator, repo);
        if (tracked == null or tracked.? < scanned) {
            try writeLastTicketNumber(allocator, repo, scanned);
            try printStdout(allocator, "updated tickets/last_ticket_id to T-{d:0>6}\n", .{scanned});
        }
    }
}

fn cmdNew(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    if (cmd_args.len < 1) {
        std.debug.print("usage: mt-zig new <title> [--priority <p0|p1|p2>] [--type <spec|code|tests|docs|refactor|chore>] [--effort <xs|s|m|l>] [--label <label>]... [--tag <tag>]... [--depends-on <T-xxxxxx>]... [--goal <text>]\n", .{});
        std.process.exit(2);
    }

    const title = std.mem.trim(u8, cmd_args[0], " \t\r\n");
    if (title.len == 0) {
        std.debug.print("new requires non-empty title\n", .{});
        std.process.exit(2);
    }

    var cli_priority = false;
    var cli_type = false;
    var cli_effort = false;
    var priority: []const u8 = "p1";
    var ticket_type: []const u8 = "code";
    var effort: []const u8 = "s";
    var status: []const u8 = "ready";
    var owner: []const u8 = "null";
    var branch: []const u8 = "null";
    var goal: []const u8 = "";
    var labels = try std.ArrayList([]u8).initCapacity(allocator, 4);
    defer freeListItems(allocator, &labels);
    var tags = try std.ArrayList([]u8).initCapacity(allocator, 4);
    defer freeListItems(allocator, &tags);
    var depends_on = try std.ArrayList([]u8).initCapacity(allocator, 4);
    defer freeListItems(allocator, &depends_on);

    var i: usize = 1;
    while (i < cmd_args.len) : (i += 1) {
        const a = cmd_args[i];
        if (std.mem.eql(u8, a, "--priority")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--priority requires a value\n", .{});
                std.process.exit(2);
            }
            priority = cmd_args[i + 1];
            cli_priority = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--type")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--type requires a value\n", .{});
                std.process.exit(2);
            }
            ticket_type = cmd_args[i + 1];
            cli_type = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--effort")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--effort requires a value\n", .{});
                std.process.exit(2);
            }
            effort = cmd_args[i + 1];
            cli_effort = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--label")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try labels.append(try allocator.dupe(u8, cmd_args[i + 1]));
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--tag")) {
            if (i + 1 >= cmd_args.len) {
                std.debug.print("--tag requires a value\n", .{});
                std.process.exit(2);
            }
            try tags.append(try allocator.dupe(u8, cmd_args[i + 1]));
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
            try depends_on.append(try allocator.dupe(u8, dep_id));
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

    const template_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, "ticket.template" });
    defer allocator.free(template_path);
    var template_content: ?[]u8 = null;
    defer if (template_content) |t| allocator.free(t);
    if (fileExists(template_path)) {
        template_content = try std.fs.cwd().readFileAlloc(allocator, template_path, 1024 * 1024);
    }

    if (template_content) |tpl| {
        if (!cli_priority) priority = parseMetaField(tpl, "priority") orelse priority;
        if (!cli_type) ticket_type = parseMetaField(tpl, "type") orelse ticket_type;
        if (!cli_effort) effort = parseMetaField(tpl, "effort") orelse effort;
        status = parseMetaField(tpl, "status") orelse status;
        owner = parseMetaField(tpl, "owner") orelse owner;
        branch = parseMetaField(tpl, "branch") orelse branch;

        if (labels.items.len == 0) {
            const raw = parseMetaField(tpl, "labels") orelse "[]";
            var vals = try listItems(allocator, raw);
            defer freeListItems(allocator, &vals);
            for (vals.items) |v| try labels.append(try allocator.dupe(u8, v));
        }
        if (tags.items.len == 0) {
            const raw = parseMetaField(tpl, "tags") orelse "[]";
            var vals = try listItems(allocator, raw);
            defer freeListItems(allocator, &vals);
            for (vals.items) |v| try tags.append(try allocator.dupe(u8, v));
        }
        if (depends_on.items.len == 0) {
            const raw = parseMetaField(tpl, "depends_on") orelse "[]";
            var vals = try listItems(allocator, raw);
            defer freeListItems(allocator, &vals);
            for (vals.items) |v| {
                if (!isTicketId(v)) {
                    std.debug.print("invalid dependency ticket id from template: {s}\n", .{v});
                    std.process.exit(2);
                }
                try depends_on.append(try allocator.dupe(u8, v));
            }
        }
    }

    if (!statusAllowed(status)) status = "ready";
    if (!std.mem.eql(u8, owner, "null") and owner.len == 0) owner = "null";
    if (!std.mem.eql(u8, branch, "null") and branch.len == 0) branch = "null";

    const tid = try nextTicketIdForRepo(allocator, repo);
    defer allocator.free(tid);
    const fname = try std.fmt.allocPrint(allocator, "{s}.md", .{tid});
    defer allocator.free(fname);
    const ticket_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, fname });
    defer allocator.free(ticket_path);

    const labels_literal = try listLiteral(allocator, @as([]const []const u8, @ptrCast(labels.items)));
    defer allocator.free(labels_literal);
    const tags_literal = try listLiteral(allocator, @as([]const []const u8, @ptrCast(tags.items)));
    defer allocator.free(tags_literal);
    const depends_literal = try listLiteral(allocator, @as([]const []const u8, @ptrCast(depends_on.items)));
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
    else if (template_content) |tpl|
        if (std.mem.trim(u8, frontmatterBody(tpl), " \t\r\n").len > 0)
            try allocator.dupe(u8, frontmatterBody(tpl))
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

    try writeTicketFile(allocator, ticket_path, tid, title, status, priority, ticket_type, effort, labels_literal, body);

    const written = try std.fs.cwd().readFileAlloc(allocator, ticket_path, 1024 * 1024);
    defer allocator.free(written);
    const with_depends = try setMetaField(allocator, written, "depends_on", depends_literal);
    defer allocator.free(with_depends);
    const with_tags = try setMetaField(allocator, with_depends, "tags", tags_literal);
    defer allocator.free(with_tags);
    const with_owner = try setMetaField(allocator, with_tags, "owner", owner);
    defer allocator.free(with_owner);
    const with_branch = try setMetaField(allocator, with_owner, "branch", branch);
    defer allocator.free(with_branch);
    const today = try todayIsoDate(allocator);
    defer allocator.free(today);
    const with_created = try setMetaField(allocator, with_branch, "created", today);
    defer allocator.free(with_created);
    const with_updated = try setMetaField(allocator, with_created, "updated", today);
    defer allocator.free(with_updated);
    try std.fs.cwd().writeFile(ticket_path, with_updated);

    try printStdout(allocator, "{s}\n", .{ticket_path});
}

fn frontmatterBody(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_frontmatter = false;
    var seen_first = false;
    var offset: usize = 0;
    while (lines.next()) |line| {
        const line_len = line.len;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            if (!seen_first) {
                seen_first = true;
                in_frontmatter = true;
                offset += line_len + 1;
                continue;
            }
            if (in_frontmatter) {
                offset += line_len + 1;
                if (offset > content.len) return "";
                return content[offset..];
            }
        }
        offset += line_len + 1;
    }
    return "";
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

fn frontmatterParseError(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first = lines.next() orelse return "Missing YAML frontmatter. Expected first line to be '---'.";
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "---")) {
        return "Missing YAML frontmatter. Expected first line to be '---'.";
    }
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "---")) {
            return null;
        }
    }
    return "Unterminated YAML frontmatter. Missing closing '---'.";
}

fn metaFieldRequired(content: []const u8, key: []const u8) bool {
    return parseMetaField(content, key) != null;
}

fn isNullOrNonEmpty(v: []const u8) bool {
    if (std.mem.eql(u8, v, "null")) return true;
    return std.mem.trim(u8, v, " \t\r").len > 0;
}

fn looksLikeListLiteral(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t\r");
    return t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']';
}

fn isIsoDateString(v: []const u8) bool {
    return parseIsoDateDays(v) != null;
}

fn bodyExcerptFirstLines(allocator: std.mem.Allocator, body: []const u8, max_lines: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    var out = try std.ArrayList(u8).initCapacity(allocator, @min(trimmed.len, 1024));
    errdefer out.deinit();

    var it = std.mem.splitScalar(u8, trimmed, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (count >= max_lines) break;
        if (count > 0) try out.append('\n');
        try out.appendSlice(std.mem.trimRight(u8, line, " \t\r"));
        count += 1;
    }
    return out.toOwnedSlice();
}

fn listJsonFromRaw(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var vals = try listItems(allocator, raw);
    defer freeListItems(allocator, &vals);

    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len + 8);
    errdefer out.deinit();
    try out.append('[');
    for (vals.items, 0..) |v, idx| {
        if (idx > 0) try out.appendSlice(", ");
        try appendJsonString(allocator, &out, v);
    }
    try out.append(']');
    return out.toOwnedSlice();
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => {
                if (ch < 0x20) {
                    const esc = try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{@as(u32, ch)});
                    defer allocator.free(esc);
                    try out.appendSlice(esc);
                } else {
                    try out.append(ch);
                }
            },
        }
    }
    try out.append('"');
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
        try out.append(try allocator.dupe(u8, value));
    }
    return out;
}

fn freeListItems(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |v| allocator.free(v);
    items.deinit();
}

fn setMetaField(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, content.len + 64);
    errdefer out.deinit();

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
                    try out.appendSlice(key);
                    try out.appendSlice(": ");
                    try out.appendSlice(value);
                    try out.append('\n');
                    replaced = true;
                }
                in_frontmatter = false;
            }
            try out.appendSlice(line);
            try out.append('\n');
            continue;
        }

        if (in_frontmatter and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), key)) {
            const t = std.mem.trimLeft(u8, line, " \t");
            if (t.len > key.len and t[key.len] == ':') {
                try out.appendSlice(key);
                try out.appendSlice(": ");
                try out.appendSlice(value);
                try out.append('\n');
                replaced = true;
                continue;
            }
        }

        try out.appendSlice(line);
        try out.append('\n');
    }

    if (!replaced) {
        return error.FieldNotReplaced;
    }
    return out.toOwnedSlice();
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

fn errorTicketPath(allocator: std.mem.Allocator, repo: []const u8, id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "errors", file_name });
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

fn priorityWeight(priority: []const u8) i64 {
    if (std.mem.eql(u8, priority, "p0")) return 300;
    if (std.mem.eql(u8, priority, "p1")) return 200;
    if (std.mem.eql(u8, priority, "p2")) return 100;
    return 0;
}

fn effortWeight(effort: []const u8) i64 {
    if (std.mem.eql(u8, effort, "xs")) return 40;
    if (std.mem.eql(u8, effort, "s")) return 30;
    if (std.mem.eql(u8, effort, "m")) return 20;
    if (std.mem.eql(u8, effort, "l")) return 10;
    return 0;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    y -= if (month <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseIsoDateDays(date: []const u8) ?i64 {
    if (date.len < 10) return null;
    if (date[4] != '-' or date[7] != '-') return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return daysFromCivil(y, m, d);
}

fn civilFromDays(days: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    var m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    y += if (m <= 2) 1 else 0;
    if (m <= 0) m += 12;
    return .{ .year = y, .month = m, .day = d };
}

fn todayIsoDate(allocator: std.mem.Allocator) ![]u8 {
    const now_days: i64 = @divFloor(std.time.timestamp(), 86400);
    const civil = civilFromDays(now_days);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ @as(u32, @intCast(civil.year)), @as(u8, @intCast(civil.month)), @as(u8, @intCast(civil.day)) },
    );
}

fn nowUtcIsoTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const now_ts = std.time.timestamp();
    const days = @divFloor(now_ts, 86400);
    const secs_of_day = @mod(now_ts, 86400);
    const civil = civilFromDays(days);
    const hour: i64 = @divFloor(secs_of_day, 3600);
    const minute: i64 = @divFloor(@mod(secs_of_day, 3600), 60);
    const second: i64 = @mod(secs_of_day, 60);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(civil.year)),
            @as(u8, @intCast(civil.month)),
            @as(u8, @intCast(civil.day)),
            @as(u8, @intCast(hour)),
            @as(u8, @intCast(minute)),
            @as(u8, @intCast(second)),
        },
    );
}

fn parseMajorMinorVersion(allocator: std.mem.Allocator, raw: []const u8) !struct { major: u64, minor: u64, text: []u8 } {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const dot_idx = std.mem.indexOfScalar(u8, trimmed, '.') orelse return error.InvalidVersionFormat;
    if (dot_idx == 0 or dot_idx + 1 >= trimmed.len) return error.InvalidVersionFormat;
    if (std.mem.indexOfScalarPos(u8, trimmed, dot_idx + 1, '.') != null) return error.InvalidVersionFormat;
    const major_raw = trimmed[0..dot_idx];
    const minor_raw = trimmed[dot_idx + 1 ..];
    const major = std.fmt.parseInt(u64, major_raw, 10) catch return error.InvalidVersionFormat;
    const minor = std.fmt.parseInt(u64, minor_raw, 10) catch return error.InvalidVersionFormat;
    return .{
        .major = major,
        .minor = minor,
        .text = try allocator.dupe(u8, trimmed),
    };
}

fn parseIsoTimestampSeconds(raw: []const u8) ?i64 {
    if (raw.len != 20) return null;
    if (raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':' or raw[19] != 'Z') return null;

    const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, raw[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, raw[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, raw[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, raw[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, raw[17..19], 10) catch return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour < 0 or hour > 23) return null;
    if (minute < 0 or minute > 59) return null;
    if (second < 0 or second > 59) return null;

    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn leaseExpired(content: []const u8, now_ts: i64) bool {
    const lease = parseMetaField(content, "lease_expires_at") orelse return false;
    if (std.mem.eql(u8, lease, "null") or lease.len == 0) return false;
    const lease_ts = parseIsoTimestampSeconds(lease) orelse return false;
    return now_ts >= lease_ts;
}

fn appendIncident(allocator: std.mem.Allocator, repo: []const u8, message: []const u8) !void {
    const tickets_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tickets_dir);
    if (!dirExists(tickets_dir)) try std.fs.cwd().makePath(tickets_dir);

    const incidents_path = try std.fs.path.join(allocator, &[_][]const u8{ tickets_dir, "incidents.log" });
    defer allocator.free(incidents_path);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    if (fileExists(incidents_path)) {
        const existing = try std.fs.cwd().readFileAlloc(allocator, incidents_path, 1024 * 1024);
        defer allocator.free(existing);
        try out.appendSlice(existing);
    }

    const now_iso = try nowUtcIsoTimestamp(allocator);
    defer allocator.free(now_iso);
    try out.writer().print("{s} {s}\n", .{ now_iso, message });
    try std.fs.cwd().writeFile(incidents_path, out.items);
}

fn computePickScore(repo: []const u8, allocator: std.mem.Allocator, content: []const u8, ignore_deps: bool) f64 {
    const pr = parseMetaField(content, "priority") orelse "p2";
    const eff = parseMetaField(content, "effort") orelse "s";
    const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
    const created = parseMetaField(content, "created") orelse "1970-01-01";

    var deps_count: i64 = 0;
    var deps = listItems(allocator, deps_raw) catch return -1e9;
    defer freeListItems(allocator, &deps);
    deps_count = @intCast(deps.items.len);

    if (!ignore_deps and !depsSatisfied(repo, allocator, content)) {
        return -1e9;
    }
    if (ignore_deps and !depsSatisfied(repo, allocator, content)) {
        return -1e9;
    }

    const base = priorityWeight(pr) + effortWeight(eff);
    const dep_penalty = 5 * deps_count;

    const now_days: i64 = @divFloor(std.time.timestamp(), 86400);
    const created_days = parseIsoDateDays(created) orelse now_days;
    var age_days: i64 = now_days - created_days;
    if (age_days < 0) age_days = 0;
    if (age_days > 365) age_days = 365;

    return @floatFromInt(base + age_days - dep_penalty);
}

fn listLiteral(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 32 + (items.len * 16));
    errdefer out.deinit();
    try out.append('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try out.appendSlice(", ");
        const trimmed = std.mem.trim(u8, item, " \t\r");
        const needs_quote =
            (trimmed.len != item.len) or
            (std.mem.indexOfScalar(u8, item, ':') != null) or
            (std.mem.indexOfScalar(u8, item, '"') != null);
        if (needs_quote) {
            try out.append('"');
            try out.appendSlice(item);
            try out.append('"');
        } else {
            try out.appendSlice(item);
        }
    }
    try out.append(']');
    return out.toOwnedSlice();
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
    defer buf.deinit();
    for (title) |ch| {
        const lower_ch = std.ascii.toLower(ch);
        if ((lower_ch >= 'a' and lower_ch <= 'z') or (lower_ch >= '0' and lower_ch <= '9')) {
            try buf.append(lower_ch);
        } else {
            if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '-') {
                try buf.append('-');
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
    try std.fs.cwd().writeFile(path, next3);
    try printStdout(allocator, "claimed {s} as {s} (branch: {s})\n", .{ id, owner, branch });
}

fn cmdSetStatus(allocator: std.mem.Allocator, id: []const u8, new_status: []const u8, force: bool, clear_owner: bool) !void {
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

    const final_text = if (std.mem.eql(u8, new_status, "ready") and clear_owner) blk: {
        const with_owner = try setMetaField(allocator, next, "owner", "null");
        defer allocator.free(with_owner);
        const with_branch = try setMetaField(allocator, with_owner, "branch", "null");
        break :blk with_branch;
    } else try allocator.dupe(u8, next);
    defer allocator.free(final_text);

    try std.fs.cwd().writeFile(path, final_text);
    try printStdout(allocator, "{s}: {s} -> {s}\n", .{ id, old, new_status });
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
    try std.fs.cwd().writeFile(path, next);
    try printStdout(allocator, "done {s}\n", .{id});
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
    defer {
        for (dependents.items) |dep| allocator.free(dep);
        dependents.deinit();
    }
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
            try dependents.append(try allocator.dupe(u8, dep_id));
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
    try printStdout(allocator, "archived {s} -> {s}\n", .{ id, rel });
}

fn cmdValidate(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const max_claimed_raw = getOptValue(cmd_args, "--max-claimed-per-owner") orelse "2";
    const max_claimed = std.fmt.parseInt(u32, max_claimed_raw, 10) catch {
        std.debug.print("invalid --max-claimed-per-owner: {s}\n", .{max_claimed_raw});
        std.process.exit(2);
    };
    const enforce_done_deps = hasFlag(cmd_args, "--enforce-done-deps");

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        try printStdout(allocator, "MuonTickets validation OK.\n", .{});
        return;
    }

    var errors = try std.ArrayList([]u8).initCapacity(allocator, 16);
    defer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit();
    }

    var owner_claims = std.StringHashMap(u32).init(allocator);
    defer {
        var key_it = owner_claims.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        owner_claims.deinit();
    }

    var dir2 = try std.fs.cwd().openDir(tdir, .{ .iterate = true });
    defer dir2.close();
    var it2 = dir2.iterate();
    while (try it2.next()) |entry| {
        if (entry.kind != .file or !isTicketFilename(entry.name)) continue;
        const p = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(p);
        const content = try std.fs.cwd().readFileAlloc(allocator, p, 1024 * 1024);
        defer allocator.free(content);

        if (frontmatterParseError(content)) |fm_err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ entry.name, fm_err });
            try errors.append(msg);
            continue;
        }

        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const status = parseMetaField(content, "status") orelse "";
        const owner = parseMetaField(content, "owner") orelse "";

        if (std.mem.eql(u8, status, "claimed") and owner.len > 0 and !std.mem.eql(u8, owner, "null")) {
            const existing = owner_claims.get(owner) orelse 0;
            if (existing == 0) {
                try owner_claims.put(try allocator.dupe(u8, owner), 1);
            } else {
                try owner_claims.put(owner, existing + 1);
            }
        }

        if (enforce_done_deps and (std.mem.eql(u8, status, "claimed") or std.mem.eql(u8, status, "needs_review") or std.mem.eql(u8, status, "done"))) {
            const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
            var deps = try listItems(allocator, deps_raw);
            defer freeListItems(allocator, &deps);
            if (deps.items.len > 0) {
                var missing = try std.ArrayList(u8).initCapacity(allocator, 32);
                defer missing.deinit();
                var first = true;
                for (deps.items) |dep| {
                    if (!depDone(repo, allocator, dep)) {
                        if (!first) try missing.appendSlice(", ");
                        first = false;
                        try missing.appendSlice(dep);
                    }
                }
                if (missing.items.len > 0) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} status {s} but deps not done: [{s}]", .{ id, status, missing.items });
                    try errors.append(msg);
                }
            }
        }
    }

    var owner_it = owner_claims.iterator();
    while (owner_it.next()) |entry| {
        if (entry.value_ptr.* > max_claimed) {
            const msg = try std.fmt.allocPrint(allocator, "owner '{s}' has {d} claimed tickets (max {d})", .{ entry.key_ptr.*, entry.value_ptr.*, max_claimed });
            try errors.append(msg);
        }
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

        if (frontmatterParseError(content)) |fm_err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ entry.name, fm_err });
            try errors.append(msg);
            continue;
        }

        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const status = parseMetaField(content, "status") orelse "";
        const owner = parseMetaField(content, "owner") orelse "null";
        const branch = parseMetaField(content, "branch") orelse "null";
        const title = parseMetaField(content, "title") orelse "";
        const priority = parseMetaField(content, "priority") orelse "";
        const ticket_type = parseMetaField(content, "type") orelse "";
        const created = parseMetaField(content, "created") orelse "";
        const updated = parseMetaField(content, "updated") orelse "";
        const effort = parseMetaField(content, "effort") orelse "s";

        const required_fields = [_][]const u8{ "id", "title", "status", "priority", "type", "labels", "owner", "created", "updated", "depends_on", "branch" };
        for (required_fields) |field| {
            if (!metaFieldRequired(content, field)) {
                const msg = try std.fmt.allocPrint(allocator, "{s}: missing required field '{s}'", .{ entry.name, field });
                try errors.append(msg);
            }
        }

        if (!isTicketId(id)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'id' does not match pattern ^T-\\d{{6}}$, got '{s}'", .{ entry.name, id });
            try errors.append(msg);
        }
        if (std.mem.trim(u8, title, " \t\r").len < 3) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'title' too short (min 3)", .{entry.name});
            try errors.append(msg);
        }
        if (!priorityAllowed(priority)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'priority' must be one of [p0, p1, p2], got '{s}'", .{ entry.name, priority });
            try errors.append(msg);
        }
        const type_ok = std.mem.eql(u8, ticket_type, "spec") or std.mem.eql(u8, ticket_type, "code") or std.mem.eql(u8, ticket_type, "tests") or std.mem.eql(u8, ticket_type, "docs") or std.mem.eql(u8, ticket_type, "refactor") or std.mem.eql(u8, ticket_type, "chore");
        if (!type_ok) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'type' must be one of [spec, code, tests, docs, refactor, chore], got '{s}'", .{ entry.name, ticket_type });
            try errors.append(msg);
        }
        const labels_raw = parseMetaField(content, "labels") orelse "[]";
        if (!looksLikeListLiteral(labels_raw)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'labels' must be an array/list", .{entry.name});
            try errors.append(msg);
        }
        if (!isNullOrNonEmpty(owner)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'owner' must satisfy oneOf, got '{s}'", .{ entry.name, owner });
            try errors.append(msg);
        }
        if (!isIsoDateString(created)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'created' does not match pattern ^\\d{{4}}-\\d{{2}}-\\d{{2}}$, got '{s}'", .{ entry.name, created });
            try errors.append(msg);
        }
        if (!isIsoDateString(updated)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'updated' does not match pattern ^\\d{{4}}-\\d{{2}}-\\d{{2}}$, got '{s}'", .{ entry.name, updated });
            try errors.append(msg);
        }
        const depends_raw = parseMetaField(content, "depends_on") orelse "[]";
        if (!looksLikeListLiteral(depends_raw)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'depends_on' must be an array/list", .{entry.name});
            try errors.append(msg);
        }
        if (!isNullOrNonEmpty(branch)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: field 'branch' must satisfy oneOf, got '{s}'", .{ entry.name, branch });
            try errors.append(msg);
        }
        if (isIsoDateString(created) and isIsoDateString(updated) and std.mem.order(u8, updated, created) == .lt) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: updated ({s}) is earlier than created ({s})", .{ entry.name, updated, created });
            try errors.append(msg);
        }

        if (!statusAllowed(status)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: invalid status {s}", .{ entry.name, status });
            try errors.append(msg);
        }
        if (!effortAllowed(effort)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: effort must be one of xs,s,m,l, got {s}", .{ entry.name, effort });
            try errors.append(msg);
        }
        if (std.mem.eql(u8, status, "claimed") and std.mem.eql(u8, owner, "null")) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: claimed ticket must have owner", .{entry.name});
            try errors.append(msg);
        }
        if ((std.mem.eql(u8, status, "needs_review") or std.mem.eql(u8, status, "done")) and std.mem.eql(u8, branch, "null")) {
            const msg = try std.fmt.allocPrint(allocator, "{s}: status {s} should have branch set", .{ entry.name, status });
            try errors.append(msg);
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
                        try errors.append(msg);
                    } else {
                        const msg = try std.fmt.allocPrint(allocator, "{s} depends_on missing ticket {s}", .{ id, dep });
                        try errors.append(msg);
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
    try printStdout(allocator, "MuonTickets validation OK.\n", .{});
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
    defer out.deinit();
    try out.appendSlice(content);
    if (!std.mem.containsAtLeast(u8, content, 1, "## Progress Log")) {
        if (!std.mem.endsWith(u8, content, "\n")) try out.append('\n');
        try out.appendSlice("\n## Progress Log\n");
    }
    try out.appendSlice("- 1970-01-01: ");
    try out.appendSlice(text);
    try out.append('\n');

    try std.fs.cwd().writeFile(path, out.items);
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
    defer required_labels.deinit();
    var avoid_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer avoid_labels.deinit();
    var arg_i: usize = 0;
    while (arg_i < cmd_args.len) : (arg_i += 1) {
        const a = cmd_args[arg_i];
        if (std.mem.eql(u8, a, "--label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try required_labels.append(cmd_args[arg_i + 1]);
            arg_i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--avoid-label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--avoid-label requires a value\n", .{});
                std.process.exit(2);
            }
            try avoid_labels.append(cmd_args[arg_i + 1]);
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

    const Candidate = struct {
        path: []u8,
        content: []u8,
        id: []u8,
        title: []u8,
        updated: []u8,
        score: f64,
    };

    var best: ?Candidate = null;

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
        const score = computePickScore(repo, allocator, content, ignore_deps);
        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const title = parseMetaField(content, "title") orelse "task";
        const updated = parseMetaField(content, "updated") orelse "";

        const better = if (best == null)
            true
        else blk: {
            const b = best.?;
            if (score > b.score) break :blk true;
            if (score < b.score) break :blk false;
            const upd_cmp = std.mem.order(u8, updated, b.updated);
            if (upd_cmp == .lt) break :blk true;
            if (upd_cmp == .gt) break :blk false;
            break :blk std.mem.order(u8, id, b.id) == .lt;
        };

        if (!better) continue;

        if (best) |b| {
            allocator.free(b.path);
            allocator.free(b.content);
            allocator.free(b.id);
            allocator.free(b.title);
            allocator.free(b.updated);
        }

        best = .{
            .path = try allocator.dupe(u8, path),
            .content = try allocator.dupe(u8, content),
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .updated = try allocator.dupe(u8, updated),
            .score = score,
        };
    }

    if (best == null) {
        std.debug.print("no claimable tickets found (ready + deps satisfied + filters).\n", .{});
        std.process.exit(3);
    }

    const chosen = best.?;
    defer {
        allocator.free(chosen.path);
        allocator.free(chosen.content);
        allocator.free(chosen.id);
        allocator.free(chosen.title);
        allocator.free(chosen.updated);
    }

    const branch = if (explicit_branch) |b| try allocator.dupe(u8, b) else try defaultBranch(allocator, chosen.id, chosen.title);
    defer allocator.free(branch);

    const next = try setMetaField(allocator, chosen.content, "status", "claimed");
    defer allocator.free(next);
    const next2 = try setMetaField(allocator, next, "owner", owner);
    defer allocator.free(next2);
    const next3 = try setMetaField(allocator, next2, "branch", branch);
    defer allocator.free(next3);
    const score_text = try std.fmt.allocPrint(allocator, "{d:.1}", .{chosen.score});
    defer allocator.free(score_text);
    const next4 = try setMetaField(allocator, next3, "score", score_text);
    defer allocator.free(next4);
    try std.fs.cwd().writeFile(chosen.path, next4);

    if (json_out) {
        try printStdout(allocator, "{{\"picked\":\"{s}\",\"owner\":\"{s}\",\"branch\":\"{s}\",\"score\":{d:.1}}}\n", .{ chosen.id, owner, branch, chosen.score });
    } else {
        try printStdout(allocator, "picked {s} (score {d:.1}) -> claimed as {s} (branch: {s})\n", .{ chosen.id, chosen.score, owner, branch });
    }
    return;
}

fn cmdAllocateTask(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const owner = getOptValue(cmd_args, "--owner") orelse {
        std.debug.print("allocate-task requires --owner <owner>\n", .{});
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
    const lease_minutes_raw = getOptValue(cmd_args, "--lease-minutes") orelse "5";
    var lease_minutes = std.fmt.parseInt(i64, lease_minutes_raw, 10) catch {
        std.debug.print("invalid --lease-minutes: {s}\n", .{lease_minutes_raw});
        std.process.exit(2);
    };
    if (lease_minutes < 1) lease_minutes = 1;

    var required_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit();
    var avoid_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer avoid_labels.deinit();
    var arg_i: usize = 0;
    while (arg_i < cmd_args.len) : (arg_i += 1) {
        const a = cmd_args[arg_i];
        if (std.mem.eql(u8, a, "--label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try required_labels.append(cmd_args[arg_i + 1]);
            arg_i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--avoid-label")) {
            if (arg_i + 1 >= cmd_args.len) {
                std.debug.print("--avoid-label requires a value\n", .{});
                std.process.exit(2);
            }
            try avoid_labels.append(cmd_args[arg_i + 1]);
            arg_i += 1;
            continue;
        }
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        std.debug.print("no allocatable tickets found (ready or lease-expired claimed + deps satisfied + filters).\n", .{});
        std.process.exit(3);
    }

    const now_ts = std.time.timestamp();

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
        if (std.mem.eql(u8, status, "claimed") and std.mem.eql(u8, ticket_owner, owner) and !leaseExpired(count_content, now_ts)) {
            claimed_count += 1;
        }
    }
    if (claimed_count >= max_claimed) {
        std.debug.print("owner '{s}' already has {d} active leases (max {d}).\n", .{ owner, claimed_count, max_claimed });
        std.process.exit(2);
    }

    const Candidate = struct {
        path: []u8,
        content: []u8,
        id: []u8,
        title: []u8,
        updated: []u8,
        score: f64,
    };

    var best: ?Candidate = null;

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
        if (!std.mem.eql(u8, status, "ready")) {
            if (!(std.mem.eql(u8, status, "claimed") and leaseExpired(content, now_ts))) {
                continue;
            }
        }

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

        const score = computePickScore(repo, allocator, content, ignore_deps);
        if (score <= -1e8) continue;

        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const title = parseMetaField(content, "title") orelse "task";
        const updated = parseMetaField(content, "updated") orelse "";

        const better = if (best == null)
            true
        else blk: {
            const b = best.?;
            if (score > b.score) break :blk true;
            if (score < b.score) break :blk false;
            const upd_cmp = std.mem.order(u8, updated, b.updated);
            if (upd_cmp == .lt) break :blk true;
            if (upd_cmp == .gt) break :blk false;
            break :blk std.mem.order(u8, id, b.id) == .lt;
        };
        if (!better) continue;

        if (best) |b| {
            allocator.free(b.path);
            allocator.free(b.content);
            allocator.free(b.id);
            allocator.free(b.title);
            allocator.free(b.updated);
        }

        best = .{
            .path = try allocator.dupe(u8, path),
            .content = try allocator.dupe(u8, content),
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .updated = try allocator.dupe(u8, updated),
            .score = score,
        };
    }

    if (best == null) {
        std.debug.print("no allocatable tickets found (ready or lease-expired claimed + deps satisfied + filters).\n", .{});
        std.process.exit(3);
    }

    const chosen = best.?;
    defer {
        allocator.free(chosen.path);
        allocator.free(chosen.content);
        allocator.free(chosen.id);
        allocator.free(chosen.title);
        allocator.free(chosen.updated);
    }

    const chosen_status = parseMetaField(chosen.content, "status") orelse "";
    const was_stale_reallocation = std.mem.eql(u8, chosen_status, "claimed") and leaseExpired(chosen.content, now_ts);
    const previous_owner = parseMetaField(chosen.content, "owner") orelse "";
    const previous_lease = parseMetaField(chosen.content, "lease_expires_at") orelse "";

    const branch = if (explicit_branch) |b| try allocator.dupe(u8, b) else try defaultBranch(allocator, chosen.id, chosen.title);
    defer allocator.free(branch);
    const now_iso = try nowUtcIsoTimestamp(allocator);
    defer allocator.free(now_iso);
    const lease_until_ts = now_ts + lease_minutes * 60;
    const lease_days = @divFloor(lease_until_ts, 86400);
    const lease_secs_of_day = @mod(lease_until_ts, 86400);
    const lease_civil = civilFromDays(lease_days);
    const lease_hour: i64 = @divFloor(lease_secs_of_day, 3600);
    const lease_minute: i64 = @divFloor(@mod(lease_secs_of_day, 3600), 60);
    const lease_second: i64 = @mod(lease_secs_of_day, 60);
    const lease_expires_at = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(lease_civil.year)),
            @as(u8, @intCast(lease_civil.month)),
            @as(u8, @intCast(lease_civil.day)),
            @as(u8, @intCast(lease_hour)),
            @as(u8, @intCast(lease_minute)),
            @as(u8, @intCast(lease_second)),
        },
    );
    defer allocator.free(lease_expires_at);

    const today = try todayIsoDate(allocator);
    defer allocator.free(today);

    const next1 = try setMetaField(allocator, chosen.content, "status", "claimed");
    defer allocator.free(next1);
    const next2 = try setMetaField(allocator, next1, "owner", owner);
    defer allocator.free(next2);
    const next3 = try setMetaField(allocator, next2, "branch", branch);
    defer allocator.free(next3);
    const next4 = try setMetaField(allocator, next3, "allocated_to", owner);
    defer allocator.free(next4);
    const next5 = try setMetaField(allocator, next4, "allocated_at", now_iso);
    defer allocator.free(next5);
    const next6 = try setMetaField(allocator, next5, "lease_expires_at", lease_expires_at);
    defer allocator.free(next6);
    const next7 = try setMetaField(allocator, next6, "last_attempted_at", now_iso);
    defer allocator.free(next7);
    const next8 = try setMetaField(allocator, next7, "updated", today);
    defer allocator.free(next8);
    const score_text = try std.fmt.allocPrint(allocator, "{d:.1}", .{chosen.score});
    defer allocator.free(score_text);
    const next9 = try setMetaField(allocator, next8, "score", score_text);
    defer allocator.free(next9);
    try std.fs.cwd().writeFile(chosen.path, next9);

    if (was_stale_reallocation) {
        const incident = try std.fmt.allocPrint(
            allocator,
            "stale-lease-reallocation id={s} from_owner={s} to_owner={s} prior_lease_expires_at={s}",
            .{ chosen.id, previous_owner, owner, previous_lease },
        );
        defer allocator.free(incident);
        try appendIncident(allocator, repo, incident);
    }

    if (json_out) {
        try printStdout(
            allocator,
            "{{\"ticket_id\":\"{s}\",\"owner\":\"{s}\",\"branch\":\"{s}\",\"lease_expires_at\":\"{s}\",\"score\":{d:.1}}}\n",
            .{ chosen.id, owner, branch, lease_expires_at, chosen.score },
        );
    } else {
        try printStdout(allocator, "{s}\n", .{chosen.id});
    }
}

fn cmdFailTask(allocator: std.mem.Allocator, id: []const u8, err_text: []const u8, retry_limit_opt: ?[]const u8, force: bool) !void {
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

    const status = parseMetaField(content, "status") orelse "";
    if (!std.mem.eql(u8, status, "claimed") and !force) {
        std.debug.print("Refusing to fail task: status is '{s}' (expected 'claimed'). Use --force to override.\n", .{status});
        std.process.exit(2);
    }

    const prev_retry_count_raw = parseMetaField(content, "retry_count") orelse "0";
    const prev_retry_count = std.fmt.parseInt(i64, prev_retry_count_raw, 10) catch 0;
    const retry_count = prev_retry_count + 1;

    const configured_retry_limit_raw = retry_limit_opt orelse (parseMetaField(content, "retry_limit") orelse "3");
    var configured_retry_limit = std.fmt.parseInt(i64, configured_retry_limit_raw, 10) catch {
        std.debug.print("invalid --retry-limit: {s}\n", .{configured_retry_limit_raw});
        std.process.exit(2);
    };
    if (configured_retry_limit < 1) configured_retry_limit = 1;

    const retry_count_text = try std.fmt.allocPrint(allocator, "{d}", .{retry_count});
    defer allocator.free(retry_count_text);
    const retry_limit_text = try std.fmt.allocPrint(allocator, "{d}", .{configured_retry_limit});
    defer allocator.free(retry_limit_text);
    const now_iso = try nowUtcIsoTimestamp(allocator);
    defer allocator.free(now_iso);
    const today = try todayIsoDate(allocator);
    defer allocator.free(today);

    const next1 = try setMetaField(allocator, content, "retry_count", retry_count_text);
    defer allocator.free(next1);
    const next2 = try setMetaField(allocator, next1, "retry_limit", retry_limit_text);
    defer allocator.free(next2);
    const next3 = try setMetaField(allocator, next2, "last_error", std.mem.trim(u8, err_text, " \t\r\n"));
    defer allocator.free(next3);
    const next4 = try setMetaField(allocator, next3, "last_attempted_at", now_iso);
    defer allocator.free(next4);
    const next5 = try setMetaField(allocator, next4, "updated", today);
    defer allocator.free(next5);

    if (retry_count >= configured_retry_limit) {
        const blocked1 = try setMetaField(allocator, next5, "status", "blocked");
        defer allocator.free(blocked1);
        const blocked2 = try setMetaField(allocator, blocked1, "owner", "null");
        defer allocator.free(blocked2);
        const blocked3 = try setMetaField(allocator, blocked2, "branch", "null");
        defer allocator.free(blocked3);
        const blocked4 = try setMetaField(allocator, blocked3, "allocated_to", "null");
        defer allocator.free(blocked4);
        const blocked5 = try setMetaField(allocator, blocked4, "allocated_at", "null");
        defer allocator.free(blocked5);
        const blocked6 = try setMetaField(allocator, blocked5, "lease_expires_at", "null");
        defer allocator.free(blocked6);
        try std.fs.cwd().writeFile(path, blocked6);

        const errors_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "errors" });
        defer allocator.free(errors_dir);
        if (!dirExists(errors_dir)) try std.fs.cwd().makePath(errors_dir);

        const error_path = try errorTicketPath(allocator, repo, id);
        defer allocator.free(error_path);
        if (fileExists(error_path)) {
            std.debug.print("Refusing to move to errors: destination already exists: {s}\n", .{error_path});
            std.process.exit(2);
        }

        try std.fs.cwd().rename(path, error_path);
        const incident = try std.fmt.allocPrint(
            allocator,
            "retry-limit-exhausted id={s} retries={d} moved_to=tickets/errors",
            .{ id, retry_count },
        );
        defer allocator.free(incident);
        try appendIncident(allocator, repo, incident);
        try printStdout(allocator, "{s} exceeded retry_limit ({d}) -> moved to tickets/errors/{s}.md\n", .{ id, configured_retry_limit, id });
        return;
    }

    const ready1 = try setMetaField(allocator, next5, "status", "ready");
    defer allocator.free(ready1);
    const ready2 = try setMetaField(allocator, ready1, "owner", "null");
    defer allocator.free(ready2);
    const ready3 = try setMetaField(allocator, ready2, "branch", "null");
    defer allocator.free(ready3);
    const ready4 = try setMetaField(allocator, ready3, "allocated_to", "null");
    defer allocator.free(ready4);
    const ready5 = try setMetaField(allocator, ready4, "allocated_at", "null");
    defer allocator.free(ready5);
    const ready6 = try setMetaField(allocator, ready5, "lease_expires_at", "null");
    defer allocator.free(ready6);
    try std.fs.cwd().writeFile(path, ready6);
    try printStdout(allocator, "{s} re-queued for retry ({d}/{d})\n", .{ id, retry_count, configured_retry_limit });
}

fn cmdGraph(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const mermaid = hasFlag(cmd_args, "--mermaid");
    const open_only = hasFlag(cmd_args, "--open-only");

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) return;

    if (mermaid) {
        try printStdout(allocator, "```mermaid\n", .{});
        try printStdout(allocator, "graph TD\n", .{});
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
        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const status = parseMetaField(content, "status") orelse "";
        if (open_only and std.mem.eql(u8, status, "done")) continue;
        const deps_raw = parseMetaField(content, "depends_on") orelse "[]";
        var deps = try listItems(allocator, deps_raw);
        defer freeListItems(allocator, &deps);
        for (deps.items) |dep| {
            if (mermaid) {
                try printStdout(allocator, "  {s} --> {s}\n", .{ dep, id });
            } else {
                try printStdout(allocator, "{s} -> {s}\n", .{ dep, id });
            }
        }
    }

    if (mermaid) try printStdout(allocator, "```\n", .{});
}

fn cmdExport(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const format = getOptValue(cmd_args, "--format") orelse "json";
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "jsonl")) {
        std.debug.print("Unsupported format: {s}\n", .{format});
        std.process.exit(2);
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    if (!dirExists(tdir)) {
        try printStdout(allocator, "[]\n", .{});
        return;
    }

    if (std.mem.eql(u8, format, "json")) try printStdout(allocator, "[\n", .{});
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
        if (frontmatterParseError(content) != null) continue;
        const id = parseMetaField(content, "id") orelse entry.name[0..8];
        const title = parseMetaField(content, "title") orelse "";
        const status = parseMetaField(content, "status") orelse "";
        const priority = parseMetaField(content, "priority") orelse "";
        const tp = parseMetaField(content, "type") orelse "";
        const effort = parseMetaField(content, "effort") orelse "";
        const labels = parseMetaField(content, "labels") orelse "[]";
        const tags = parseMetaField(content, "tags") orelse "[]";
        const owner = parseMetaField(content, "owner") orelse "null";
        const created = parseMetaField(content, "created") orelse "";
        const updated = parseMetaField(content, "updated") orelse "";
        const depends_on = parseMetaField(content, "depends_on") orelse "[]";
        const branch = parseMetaField(content, "branch") orelse "null";
        const body = frontmatterBody(content);
        const excerpt = try bodyExcerptFirstLines(allocator, body, 20);
        defer allocator.free(excerpt);
        const rel_path = try std.fmt.allocPrint(allocator, "tickets/{s}", .{entry.name});
        defer allocator.free(rel_path);
        const labels_json = try listJsonFromRaw(allocator, labels);
        defer allocator.free(labels_json);
        const tags_json = try listJsonFromRaw(allocator, tags);
        defer allocator.free(tags_json);
        const depends_json = try listJsonFromRaw(allocator, depends_on);
        defer allocator.free(depends_json);

        var line = try std.ArrayList(u8).initCapacity(allocator, 512);
        defer line.deinit();
        try line.append('{');
        try line.appendSlice("\"id\": ");
        try appendJsonString(allocator, &line, id);
        try line.appendSlice(", \"title\": ");
        try appendJsonString(allocator, &line, title);
        try line.appendSlice(", \"status\": ");
        try appendJsonString(allocator, &line, status);
        try line.appendSlice(", \"priority\": ");
        try appendJsonString(allocator, &line, priority);
        try line.appendSlice(", \"type\": ");
        try appendJsonString(allocator, &line, tp);
        try line.appendSlice(", \"effort\": ");
        try appendJsonString(allocator, &line, effort);
        try line.appendSlice(", \"labels\": ");
        try line.appendSlice(labels_json);
        try line.appendSlice(", \"tags\": ");
        try line.appendSlice(tags_json);
        try line.appendSlice(", \"owner\": ");
        if (std.mem.eql(u8, owner, "null")) {
            try line.appendSlice("null");
        } else {
            try appendJsonString(allocator, &line, owner);
        }
        try line.appendSlice(", \"created\": ");
        try appendJsonString(allocator, &line, created);
        try line.appendSlice(", \"updated\": ");
        try appendJsonString(allocator, &line, updated);
        try line.appendSlice(", \"depends_on\": ");
        try line.appendSlice(depends_json);
        try line.appendSlice(", \"branch\": ");
        if (std.mem.eql(u8, branch, "null")) {
            try line.appendSlice("null");
        } else {
            try appendJsonString(allocator, &line, branch);
        }
        try line.appendSlice(", \"excerpt\": ");
        try appendJsonString(allocator, &line, excerpt);
        try line.appendSlice(", \"path\": ");
        try appendJsonString(allocator, &line, rel_path);
        try line.append('}');

        if (std.mem.eql(u8, format, "json")) {
            if (!first) try printStdout(allocator, ",\n", .{});
            first = false;
            try printStdout(allocator, "  {s}", .{line.items});
        } else {
            try printStdout(allocator, "{s}\n", .{line.items});
        }
    }
    if (std.mem.eql(u8, format, "json")) try printStdout(allocator, "\n]\n", .{});
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
        rows.deinit();

        var key_it = seen_paths.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        seen_paths.deinit();
    }

    const roots = [_][]const u8{ "tickets", "tickets/archive", "tickets/errors", "tickets/backlogs" };
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

            try rows.append(.{
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
                .bucket = try allocator.dupe(u8, if (std.mem.eql(u8, root_rel, "tickets/archive")) "archive" else if (std.mem.eql(u8, root_rel, "tickets/errors")) "errors" else if (std.mem.eql(u8, root_rel, "tickets/backlogs")) "backlogs" else "tickets"),
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

    try printStdout(allocator, "report db: {s}\n", .{db_path});
    try printStdout(allocator, "indexed tickets: {d}\n", .{rows.items.len});

    if (summary) {
        try printStdout(allocator, "\nBy status:\n", .{});
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
            try printStdout(allocator, "  {s:<12} {d}\n", .{ status_text, count });
        }

        try printStdout(allocator, "\nBy priority:\n", .{});
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
            try printStdout(allocator, "  {s:<8} {d}\n", .{ priority_text, count });
        }

        try printStdout(allocator, "\nCompleted by owner:\n", .{});
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
            try printStdout(allocator, "  {s:<20} {d}\n", .{ owner_text, count });
        }
    }

    if (search.len > 0) {
        try printStdout(allocator, "\nSearch results for: '{s}'\n", .{search});
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

            try printStdout(allocator, "  {s}  {s:<12} {s:<12} {s}  ({s})\n", .{ id_text, status_text, owner_text, title_text, path_text });
        }
    }
}

fn cmdVersion(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    const as_json = hasFlag(cmd_args, "--json");
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const version_path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "VERSION" });
    defer allocator.free(version_path);
    const version_raw = std.fs.cwd().readFileAlloc(allocator, version_path, 1024) catch {
        std.debug.print("missing VERSION file at project root: {s}\n", .{version_path});
        std.process.exit(2);
    };
    defer allocator.free(version_raw);

    const parsed = parseMajorMinorVersion(allocator, version_raw) catch {
        std.debug.print("invalid VERSION format at project root (expected <major>.<minor>)\n", .{});
        std.process.exit(2);
    };
    defer allocator.free(parsed.text);

    if (as_json) {
        try printStdout(
            allocator,
            "{{\"implementation\":\"zig-mt\",\"version\":\"{s}\",\"version_major\":{d},\"version_minor\":{d},\"build_tools\":{{\"zig\":\"{s}\"}}}}\n",
            .{ parsed.text, parsed.major, parsed.minor, builtin.zig_version_string },
        );
    } else {
        try printStdout(allocator, "zig-mt {s}\n", .{parsed.text});
        try printStdout(allocator, "zig={s}\n", .{builtin.zig_version_string});
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
    const show_invalid = hasFlag(cmd_args, "--show-invalid");
    var required_labels = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit();
    var label_i: usize = 0;
    while (label_i < cmd_args.len) : (label_i += 1) {
        if (std.mem.eql(u8, cmd_args[label_i], "--label")) {
            if (label_i + 1 >= cmd_args.len) {
                std.debug.print("--label requires a value\n", .{});
                std.process.exit(2);
            }
            try required_labels.append(cmd_args[label_i + 1]);
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

        if (frontmatterParseError(content)) |fm_err| {
            if (show_invalid) {
                std.debug.print("{s}  PARSE_ERROR  {s}\n", .{ entry.name, fm_err });
            }
            continue;
        }

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
        try cmdVersion(allocator, &[_][:0]u8{});
        return;
    }

    const arg = args[1];
    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
        try cmdVersion(allocator, args[2..]);
        return;
    }
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
        .allocate_task => try cmdAllocateTask(allocator, args[2..]),
        .fail_task => {
            if (args.len < 3) {
                std.debug.print("usage: mt-zig fail-task <id> --error <text> [--retry-limit <n>] [--force]\n", .{});
                std.process.exit(2);
            }
            const err_text = getOptValue(args[3..], "--error") orelse {
                std.debug.print("fail-task requires --error <text>\n", .{});
                std.process.exit(2);
            };
            try cmdFailTask(allocator, args[2], err_text, getOptValue(args[3..], "--retry-limit"), hasFlag(args[3..], "--force"));
        },
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
                std.debug.print("usage: mt-zig set-status <id> <status> [--force] [--clear-owner]\n", .{});
                std.process.exit(2);
            }
            try cmdSetStatus(allocator, args[2], args[3], hasFlag(args[4..], "--force"), hasFlag(args[4..], "--clear-owner"));
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
        .graph => try cmdGraph(allocator, args[2..]),
        .@"export" => try cmdExport(allocator, args[2..]),
        .stats => try cmdStats(allocator),
        .validate => try cmdValidate(allocator, args[2..]),
        .report => try cmdReport(allocator, args[2..]),
        .version => try cmdVersion(allocator, args[2..]),
    }
}
