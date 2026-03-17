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
    maintain,
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
    if (std.mem.eql(u8, raw, "maintain")) return .maintain;
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
        \\  maintain
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
    \\---
    \\id: T-000000
    \\title: Template: replace title
    \\status: ready
    \\priority: p1
    \\type: code
    \\effort: s
    \\labels: []
    \\tags: []
    \\owner: null
    \\created: 1970-01-01T00:00:00Z
    \\updated: 1970-01-01T00:00:00Z
    \\depends_on: []
    \\branch: null
    \\retry_count: 0
    \\retry_limit: 3
    \\allocated_to: null
    \\allocated_at: null
    \\lease_expires_at: null
    \\last_error: null
    \\last_attempted_at: null
    \\---
    \\
    \\## Goal
    \\Write a single-sentence goal.
    \\
    \\## Acceptance Criteria
    \\- [ ] Define clear, testable checks (2–5 items)
    \\
    \\## Notes
    \\
    \\## Agent Assignment
    \\- Suggested owner: agent-name
    \\- Suggested branch: feature/short-name
    \\
    \\## Implementation Plan
    \\- [ ] Describe 2-4 concrete execution steps
    \\- [ ] List test/validation commands to run
    \\- [ ] Note any dependency handoff requirements
    \\
    \\## Queue Lifecycle (if allocated)
    \\- [ ] Add progress with `mt comment <id> "..."`
    \\- [ ] If blocked/failing, run `mt fail-task <id> --error "..."`
    \\- [ ] On completion, move to `needs_review` then `done`
    \\
;

const example_body =
    \\## Goal
    \\Replace this example with a real task.
    \\
    \\## Acceptance Criteria
    \\- [ ] Delete or edit this ticket
    \\- [ ] Create at least one real ticket with `mt new`
    \\
    \\## Notes
    \\This repository uses MuonTickets for agent-friendly coordination.
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
    try std.fs.File.stdout().writeAll(message);
}

fn writeFileText(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = data,
    });
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
    try writeFileText(path, text);
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
        \\retry_count: 0
        \\retry_limit: 3
        \\allocated_to: null
        \\allocated_at: null
        \\lease_expires_at: null
        \\last_error: null
        \\last_attempted_at: null
        \\---
        \\
        \\{s}
    ,
        .{ id, title, status, priority, ticket_type, effort, labels, today, today, body },
    );
    defer allocator.free(text);
    try writeFileText(path, text);
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
        try writeFileText(template_path, default_template);
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
    var labels = try std.array_list.Managed([]u8).initCapacity(allocator, 4);
    defer freeListItems(allocator, &labels);
    var tags = try std.array_list.Managed([]u8).initCapacity(allocator, 4);
    defer freeListItems(allocator, &tags);
    var depends_on = try std.array_list.Managed([]u8).initCapacity(allocator, 4);
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
    try writeFileText(ticket_path, with_updated);

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
    var out = try std.array_list.Managed(u8).initCapacity(allocator, @min(trimmed.len, 1024));
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

    var out = try std.array_list.Managed(u8).initCapacity(allocator, raw.len + 8);
    errdefer out.deinit();
    try out.append('[');
    for (vals.items, 0..) |v, idx| {
        if (idx > 0) try out.appendSlice(", ");
        try appendJsonString(allocator, &out, v);
    }
    try out.append(']');
    return out.toOwnedSlice();
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), value: []const u8) !void {
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

fn listItems(allocator: std.mem.Allocator, raw_list: []const u8) !std.array_list.Managed([]u8) {
    var out = try std.array_list.Managed([]u8).initCapacity(allocator, 8);
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

fn freeListItems(allocator: std.mem.Allocator, items: *std.array_list.Managed([]u8)) void {
    for (items.items) |v| allocator.free(v);
    items.deinit();
}

fn setMetaField(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, content.len + 64);
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

const PickProfile = struct {
    labels: []const []const u8,
    types: []const []const u8,
};

fn skillPickProfile(skill: []const u8) ?PickProfile {
    const profiles = .{
        .{ "design", PickProfile{ .labels = &.{"design"}, .types = &.{ "spec", "docs" } } },
        .{ "database", PickProfile{ .labels = &.{"database"}, .types = &.{ "code", "refactor", "tests" } } },
        .{ "review", PickProfile{ .labels = &.{"review"}, .types = &.{ "tests", "docs" } } },
    };
    inline for (profiles) |entry| {
        if (std.mem.eql(u8, skill, entry[0])) return entry[1];
    }
    return null;
}

fn rolePickProfile(role: []const u8) ?PickProfile {
    const profiles = .{
        .{ "architect", PickProfile{ .labels = &.{"design"}, .types = &.{ "spec", "docs", "refactor" } } },
        .{ "devops", PickProfile{ .labels = &.{"devops"}, .types = &.{ "code", "chore", "docs" } } },
        .{ "developer", PickProfile{ .labels = &.{"feature"}, .types = &.{ "code", "tests", "refactor" } } },
        .{ "reviewer", PickProfile{ .labels = &.{"review"}, .types = &.{ "tests", "docs" } } },
    };
    inline for (profiles) |entry| {
        if (std.mem.eql(u8, role, entry[0])) return entry[1];
    }
    return null;
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
    const second_dot_idx_opt = std.mem.indexOfScalarPos(u8, trimmed, dot_idx + 1, '.');
    const major_raw = trimmed[0..dot_idx];
    const minor_raw = if (second_dot_idx_opt) |second_dot_idx| trimmed[dot_idx + 1 .. second_dot_idx] else trimmed[dot_idx + 1 ..];
    const major = std.fmt.parseInt(u64, major_raw, 10) catch return error.InvalidVersionFormat;
    const minor = std.fmt.parseInt(u64, minor_raw, 10) catch return error.InvalidVersionFormat;
    if (second_dot_idx_opt) |second_dot_idx| {
        if (second_dot_idx + 1 >= trimmed.len) return error.InvalidVersionFormat;
        const patch_raw = trimmed[second_dot_idx + 1 ..];
        _ = std.fmt.parseInt(u64, patch_raw, 10) catch return error.InvalidVersionFormat;
    }
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

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    if (fileExists(incidents_path)) {
        const existing = try std.fs.cwd().readFileAlloc(allocator, incidents_path, 1024 * 1024);
        defer allocator.free(existing);
        try out.appendSlice(existing);
    }

    const now_iso = try nowUtcIsoTimestamp(allocator);
    defer allocator.free(now_iso);
    try out.writer().print("{s} {s}\n", .{ now_iso, message });
    try writeFileText(incidents_path, out.items);
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
    var out = try std.array_list.Managed(u8).initCapacity(allocator, 32 + (items.len * 16));
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
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 64);
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
    try writeFileText(path, next3);
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

    try writeFileText(path, final_text);
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
    try writeFileText(path, next);
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
    var dependents = try std.array_list.Managed([]const u8).initCapacity(allocator, 8);
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

    var errors = try std.array_list.Managed([]u8).initCapacity(allocator, 16);
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
                var missing = try std.array_list.Managed(u8).initCapacity(allocator, 32);
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

    var out = try std.array_list.Managed(u8).initCapacity(allocator, content.len + text.len + 128);
    defer out.deinit();
    try out.appendSlice(content);
    if (!std.mem.containsAtLeast(u8, content, 1, "## Progress Log")) {
        if (!std.mem.endsWith(u8, content, "\n")) try out.append('\n');
        try out.appendSlice("\n## Progress Log\n");
    }
    try out.appendSlice("- 1970-01-01: ");
    try out.appendSlice(text);
    try out.append('\n');

    try writeFileText(path, out.items);
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
    const skill_flag = getOptValue(cmd_args, "--skill");
    const role_flag = getOptValue(cmd_args, "--role");
    const explicit_branch = getOptValue(cmd_args, "--branch");
    const ignore_deps = hasFlag(cmd_args, "--ignore-deps");
    const json_out = hasFlag(cmd_args, "--json");
    const max_claimed_raw = getOptValue(cmd_args, "--max-claimed-per-owner") orelse "2";
    const max_claimed = std.fmt.parseInt(u32, max_claimed_raw, 10) catch {
        std.debug.print("invalid --max-claimed-per-owner: {s}\n", .{max_claimed_raw});
        std.process.exit(2);
    };

    var required_labels = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit();
    var avoid_labels = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
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

    // Build type_candidates from --type, --skill, --role with intersection
    var type_candidates = try std.array_list.Managed([]const u8).initCapacity(allocator, 8);
    defer type_candidates.deinit();
    var has_type_candidates = false;

    if (type_filter) |tf| {
        try type_candidates.append(tf);
        has_type_candidates = true;
    }

    if (skill_flag) |sk| {
        const prof = skillPickProfile(sk) orelse {
            std.debug.print("unknown --skill value: {s}\n", .{sk});
            std.process.exit(2);
        };
        for (prof.labels) |lbl| {
            var already = false;
            for (required_labels.items) |existing| {
                if (std.mem.eql(u8, existing, lbl)) { already = true; break; }
            }
            if (!already) try required_labels.append(lbl);
        }
        if (has_type_candidates) {
            var intersected = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
            defer intersected.deinit();
            for (type_candidates.items) |tc| {
                for (prof.types) |pt| {
                    if (std.mem.eql(u8, tc, pt)) { try intersected.append(tc); break; }
                }
            }
            type_candidates.clearRetainingCapacity();
            try type_candidates.appendSlice(intersected.items);
        } else {
            try type_candidates.appendSlice(prof.types);
        }
        has_type_candidates = true;
    }

    if (role_flag) |ro| {
        const prof = rolePickProfile(ro) orelse {
            std.debug.print("unknown --role value: {s}\n", .{ro});
            std.process.exit(2);
        };
        for (prof.labels) |lbl| {
            var already = false;
            for (required_labels.items) |existing| {
                if (std.mem.eql(u8, existing, lbl)) { already = true; break; }
            }
            if (!already) try required_labels.append(lbl);
        }
        if (has_type_candidates) {
            var intersected = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
            defer intersected.deinit();
            for (type_candidates.items) |tc| {
                for (prof.types) |pt| {
                    if (std.mem.eql(u8, tc, pt)) { try intersected.append(tc); break; }
                }
            }
            type_candidates.clearRetainingCapacity();
            try type_candidates.appendSlice(intersected.items);
        } else {
            try type_candidates.appendSlice(prof.types);
        }
        has_type_candidates = true;
    }

    if (has_type_candidates and type_candidates.items.len == 0) {
        std.debug.print("no compatible type filter remains after combining --type/--skill/--role\n", .{});
        std.process.exit(2);
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
        if (has_type_candidates) {
            const tp = parseMetaField(content, "type") orelse "";
            var type_match = false;
            for (type_candidates.items) |tc| {
                if (std.mem.eql(u8, tp, tc)) { type_match = true; break; }
            }
            if (!type_match) continue;
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
    try writeFileText(chosen.path, next4);

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
    const skill_flag = getOptValue(cmd_args, "--skill");
    const role_flag = getOptValue(cmd_args, "--role");
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

    var required_labels = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
    defer required_labels.deinit();
    var avoid_labels = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
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

    // Build type_candidates from --type, --skill, --role with intersection
    var type_candidates = try std.array_list.Managed([]const u8).initCapacity(allocator, 8);
    defer type_candidates.deinit();
    var has_type_candidates = false;

    if (type_filter) |tf| {
        try type_candidates.append(tf);
        has_type_candidates = true;
    }

    if (skill_flag) |sk| {
        const prof = skillPickProfile(sk) orelse {
            std.debug.print("unknown --skill value: {s}\n", .{sk});
            std.process.exit(2);
        };
        for (prof.labels) |lbl| {
            var already = false;
            for (required_labels.items) |existing| {
                if (std.mem.eql(u8, existing, lbl)) { already = true; break; }
            }
            if (!already) try required_labels.append(lbl);
        }
        if (has_type_candidates) {
            var intersected = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
            defer intersected.deinit();
            for (type_candidates.items) |tc| {
                for (prof.types) |pt| {
                    if (std.mem.eql(u8, tc, pt)) { try intersected.append(tc); break; }
                }
            }
            type_candidates.clearRetainingCapacity();
            try type_candidates.appendSlice(intersected.items);
        } else {
            try type_candidates.appendSlice(prof.types);
        }
        has_type_candidates = true;
    }

    if (role_flag) |ro| {
        const prof = rolePickProfile(ro) orelse {
            std.debug.print("unknown --role value: {s}\n", .{ro});
            std.process.exit(2);
        };
        for (prof.labels) |lbl| {
            var already = false;
            for (required_labels.items) |existing| {
                if (std.mem.eql(u8, existing, lbl)) { already = true; break; }
            }
            if (!already) try required_labels.append(lbl);
        }
        if (has_type_candidates) {
            var intersected = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
            defer intersected.deinit();
            for (type_candidates.items) |tc| {
                for (prof.types) |pt| {
                    if (std.mem.eql(u8, tc, pt)) { try intersected.append(tc); break; }
                }
            }
            type_candidates.clearRetainingCapacity();
            try type_candidates.appendSlice(intersected.items);
        } else {
            try type_candidates.appendSlice(prof.types);
        }
        has_type_candidates = true;
    }

    if (has_type_candidates and type_candidates.items.len == 0) {
        std.debug.print("no compatible type filter remains after combining --type/--skill/--role\n", .{});
        std.process.exit(2);
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
        if (has_type_candidates) {
            const tp = parseMetaField(content, "type") orelse "";
            var type_match = false;
            for (type_candidates.items) |tc| {
                if (std.mem.eql(u8, tp, tc)) { type_match = true; break; }
            }
            if (!type_match) continue;
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
    try writeFileText(chosen.path, next9);

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
        try writeFileText(path, blocked6);

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
    try writeFileText(path, ready6);
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

        var line = try std.array_list.Managed(u8).initCapacity(allocator, 512);
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

    var rows = try std.array_list.Managed(ReportRow).initCapacity(allocator, 64);
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
        std.debug.print("invalid VERSION format at project root (expected <major>.<minor>[.<patch>])\n", .{});
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
    var required_labels = try std.array_list.Managed([]const u8).initCapacity(allocator, 4);
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

    // Collect matching rows first so we can suppress the header when there are none.
    var rows = try std.array_list.Managed([]u8).initCapacity(allocator, 16);
    defer {
        for (rows.items) |r| allocator.free(r);
        rows.deinit();
    }

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
                const row = try std.fmt.allocPrint(allocator, "{s}  PARSE_ERROR  {s}\n", .{ entry.name, fm_err });
                try rows.append(row);
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

        const row = try std.fmt.allocPrint(allocator, "{s}  {s}  {s} {s} {s} {s}  {s}  {s}\n", .{ id, status, pr, tp, effort, owner, title, labels });
        try rows.append(row);
    }

    if (rows.items.len > 0) {
        try printStdout(allocator, "ID       STATUS        PR TYPE     EF OWNER         TITLE  [LABELS]\n", .{});
        try printStdout(allocator, "--------------------------------------------------------------------------------------------------------------\n", .{});
        for (rows.items) |row| {
            try std.fs.File.stdout().writeAll(row);
        }
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
    try std.fs.File.stdout().writeAll(content);
}

// ========== Maintain command group ==========

const MaintenanceRule = struct {
    id: i32,
    title: []const u8,
    category: []const u8,
    detection: []const u8,
    action: []const u8,
    default_priority: []const u8,
    default_type: []const u8,
    default_effort: []const u8,
    labels: []const []const u8,
    external_tool: []const u8,
};

const maint_categories = [_][]const u8{
    "security",        "deps",     "code-health",      "performance",
    "database",        "infrastructure", "observability",
    "testing",         "docs",
};

const maintenance_rules = [_]MaintenanceRule{
    .{ .id = 1, .title = "CVE Dependency Vulnerability", .category = "security", .detection = "dependency version < secure version from CVE DB", .action = "upgrade dependency and run tests", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "npm audit | pip-audit | cargo audit | osv-scanner | trivy | grype" },
    .{ .id = 2, .title = "Exposed Secrets in Repo", .category = "security", .detection = "regex patterns (AKIA..., private_key)", .action = "remove secret and move to vault", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "" },
    .{ .id = 3, .title = "Expired SSL Certificate", .category = "security", .detection = "ssl_expiry_date < now + 14 days", .action = "renew certificate", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "openssl s_client -connect host:443 | openssl x509 -noout -dates" },
    .{ .id = 4, .title = "Missing Security Headers", .category = "security", .detection = "missing CSP, X-Frame-Options, X-XSS-Protection", .action = "add headers", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "curl -I <url> (check response headers for CSP, X-Frame-Options, X-XSS-Protection)" },
    .{ .id = 5, .title = "Insecure Hashing Algorithm", .category = "security", .detection = "md5 or sha1 usage", .action = "migrate to argon2/bcrypt", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "grep -rn 'md5\\|sha1\\|MD5\\|SHA1' --include='*.py' --include='*.js' --include='*.go'" },
    .{ .id = 6, .title = "Hardcoded Password", .category = "security", .detection = "password=\"...\" pattern", .action = "move to environment variable", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "" },
    .{ .id = 7, .title = "Open Debug Ports", .category = "security", .detection = "container exposing debug ports (9229, 3000)", .action = "disable in production", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "docker inspect <container> | grep -i port; kubectl get svc -o json" },
    .{ .id = 8, .title = "Unauthenticated Admin Endpoint", .category = "security", .detection = "/admin route without auth middleware", .action = "enforce auth guard", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "review route definitions for /admin paths without auth middleware" },
    .{ .id = 9, .title = "Excessive IAM Privileges", .category = "security", .detection = "policy contains \"*\"", .action = "restrict permissions", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "aws iam list-policies --only-attached | grep '\"*\"'; gcloud iam policies" },
    .{ .id = 10, .title = "Unencrypted DB Connection", .category = "security", .detection = "connection string missing TLS flag", .action = "enforce encrypted connections", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "grep -rn 'sslmode=disable\\|ssl=false\\|useSSL=false' (connection strings)" },
    .{ .id = 11, .title = "Weak JWT Secret", .category = "security", .detection = "JWT secret length < 32 characters or common value", .action = "rotate to strong secret", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "grep -rn 'jwt.sign\\|JWT_SECRET\\|jwt_secret' and check secret length/entropy" },
    .{ .id = 12, .title = "Missing Rate Limiting", .category = "security", .detection = "API endpoints without rate limit middleware", .action = "add rate limiting", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "review API framework middleware config for rate-limit setup" },
    .{ .id = 13, .title = "Disabled CSRF Protection", .category = "security", .detection = "CSRF middleware disabled or missing", .action = "enable CSRF protection", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "review framework config for CSRF middleware (csrf_exempt, disable_csrf)" },
    .{ .id = 14, .title = "Dependency Signature Mismatch", .category = "security", .detection = "package checksum does not match registry", .action = "verify and re-fetch dependency", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "npm audit signatures | pip hash --verify | cargo verify-project" },
    .{ .id = 15, .title = "Container Running as Root", .category = "security", .detection = "Dockerfile missing USER directive", .action = "add non-root user", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "" },
    .{ .id = 16, .title = "Outdated OpenSSL", .category = "security", .detection = "OpenSSL version < latest stable", .action = "upgrade OpenSSL", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "openssl version; dpkg -l openssl; brew info openssl" },
    .{ .id = 17, .title = "Public Cloud Bucket", .category = "security", .detection = "storage bucket with public access enabled", .action = "restrict bucket access", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "aws s3api get-bucket-acl --bucket <name>; gsutil iam get gs://<bucket>" },
    .{ .id = 18, .title = "Exposed .env File", .category = "security", .detection = ".env file tracked in git or publicly accessible", .action = "remove from tracking and add to .gitignore", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "" },
    .{ .id = 19, .title = "Missing MFA for Admin", .category = "security", .detection = "admin accounts without MFA enabled", .action = "enforce MFA", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "aws iam get-login-profile; review admin user MFA status in cloud console" },
    .{ .id = 20, .title = "Suspicious Login Activity", .category = "security", .detection = "unusual login patterns or locations", .action = "investigate and rotate credentials", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "security" }, .external_tool = "review auth/access logs for unusual IPs, times, or geolocations" },
    .{ .id = 21, .title = "Outdated Dependency", .category = "deps", .detection = "npm/pip/cargo outdated", .action = "upgrade version", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm outdated | pip list --outdated | cargo outdated | uv pip list --outdated" },
    .{ .id = 22, .title = "Deprecated Library", .category = "deps", .detection = "upstream marked deprecated", .action = "migrate to replacement", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm info <pkg> deprecated; check PyPI/crates.io status page" },
    .{ .id = 23, .title = "Unmaintained Dependency", .category = "deps", .detection = "last commit > 3 years", .action = "replace library", .default_priority = "p1", .default_type = "chore", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "check GitHub last commit date via API; npm info <pkg> time.modified" },
    .{ .id = 24, .title = "Duplicate Libraries", .category = "deps", .detection = "multiple versions installed", .action = "consolidate version", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ls --all | grep deduped; pip list | sort | uniq -d" },
    .{ .id = 25, .title = "Vulnerable Transitive Dependency", .category = "deps", .detection = "nested CVE scan", .action = "update dependency tree", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm audit | pip-audit | cargo audit | osv-scanner (transitive deps)" },
    .{ .id = 26, .title = "Lockfile Drift", .category = "deps", .detection = "mismatch with installed packages", .action = "rebuild lockfile", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ci --dry-run; pip freeze > /tmp/freeze.txt && diff requirements.txt /tmp/freeze.txt" },
    .{ .id = 27, .title = "Outdated Build Toolchain", .category = "deps", .detection = "compiler older than LTS", .action = "upgrade toolchain", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "rustc --version; python3 --version; node --version; go version; zig version" },
    .{ .id = 28, .title = "Runtime EOL", .category = "deps", .detection = "runtime end-of-life version", .action = "upgrade runtime", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "check endoflife.date API for runtime EOL dates (python, node, ruby, etc.)" },
    .{ .id = 29, .title = "Dependency Size Explosion", .category = "deps", .detection = "bundle size threshold exceeded", .action = "audit dependency", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm pack --dry-run; du -sh node_modules; cargo bloat" },
    .{ .id = 30, .title = "Unused Dependency", .category = "deps", .detection = "static import analysis", .action = "remove package", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "depcheck (npm) | vulture (python) | cargo-udeps (rust)" },
    .{ .id = 31, .title = "License Change Detection", .category = "deps", .detection = "dependency license changed in new version", .action = "review license compatibility", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "license-checker (npm) | pip-licenses | cargo-license; diff against previous" },
    .{ .id = 32, .title = "Conflicting Version Ranges", .category = "deps", .detection = "dependency resolution conflicts", .action = "resolve version conflicts", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ls --all 2>&1 | grep 'ERESOLVE\\|peer dep'; pip check" },
    .{ .id = 33, .title = "Unused Peer Dependencies", .category = "deps", .detection = "peer dependency declared but unused", .action = "remove peer dependency", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ls --all | grep 'peer dep'" },
    .{ .id = 34, .title = "Broken Registry References", .category = "deps", .detection = "package registry URL unreachable", .action = "fix registry reference", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ping; pip config list (check index-url reachability)" },
    .{ .id = 35, .title = "Checksum Mismatch", .category = "deps", .detection = "package checksum mismatch on install", .action = "re-fetch and verify package", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm cache verify; pip hash --verify; cargo verify-project" },
    .{ .id = 36, .title = "Incompatible Binary Architecture", .category = "deps", .detection = "native module built for wrong arch", .action = "rebuild for target architecture", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "file node_modules/**/*.node; check platform/arch in native bindings" },
    .{ .id = 37, .title = "Outdated WASM Runtime", .category = "deps", .detection = "WASM runtime version behind stable", .action = "upgrade WASM runtime", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "check wasmtime/wasmer version against latest stable release" },
    .{ .id = 38, .title = "Outdated GPU Drivers", .category = "deps", .detection = "GPU driver version behind stable", .action = "upgrade GPU drivers", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "nvidia-smi; check driver version against CUDA compatibility matrix" },
    .{ .id = 39, .title = "Mirror Outage Fallback", .category = "deps", .detection = "primary package mirror unreachable", .action = "configure fallback mirror", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm ping --registry <mirror>; pip install --dry-run -i <mirror>" },
    .{ .id = 40, .title = "Corrupted Dependency Cache", .category = "deps", .detection = "dependency cache integrity check fails", .action = "clear and rebuild cache", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "deps" }, .external_tool = "npm cache clean --force; pip cache purge; cargo clean" },
    .{ .id = 41, .title = "High Cyclomatic Complexity", .category = "code-health", .detection = "cyclomatic complexity > 15", .action = "refactor into smaller functions", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "radon cc -a (python) | eslint --rule complexity (js) | gocyclo (go)" },
    .{ .id = 42, .title = "File Too Large", .category = "code-health", .detection = "file > 1000 lines", .action = "split into modules", .default_priority = "p2", .default_type = "refactor", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "" },
    .{ .id = 43, .title = "Duplicate Code Blocks", .category = "code-health", .detection = "repeated code blocks detected", .action = "extract shared function", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "jscpd | flay (ruby) | PMD CPD (java); semgrep --config=p/duplicate-code" },
    .{ .id = 44, .title = "Dead Code Detection", .category = "code-health", .detection = "unreachable or unused code paths", .action = "remove dead code", .default_priority = "p2", .default_type = "refactor", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "vulture (python) | ts-prune (typescript) | deadcode (go)" },
    .{ .id = 45, .title = "Deprecated API Usage", .category = "code-health", .detection = "calls to deprecated functions/methods", .action = "migrate to replacement API", .default_priority = "p1", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "grep -rn '@deprecated\\|DeprecationWarning\\|DEPRECATED'" },
    .{ .id = 46, .title = "Missing Error Handling", .category = "code-health", .detection = "unhandled exceptions or missing error checks", .action = "add error handling", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "pylint --disable=all --enable=W0702,W0703 | eslint no-empty-catch" },
    .{ .id = 47, .title = "Logging Inconsistency", .category = "code-health", .detection = "inconsistent log levels or formats", .action = "standardize logging", .default_priority = "p2", .default_type = "refactor", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "grep -rn 'console.log\\|print(\\|log.Debug' and review log level consistency" },
    .{ .id = 48, .title = "Excessive TODO Comments", .category = "code-health", .detection = "TODO/FIXME/HACK count exceeds threshold", .action = "address or create tickets for TODOs", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "" },
    .{ .id = 49, .title = "Long Parameter Lists", .category = "code-health", .detection = "function parameters > 6", .action = "refactor to use parameter objects", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "pylint --disable=all --enable=R0913 | eslint max-params" },
    .{ .id = 50, .title = "Circular Imports", .category = "code-health", .detection = "circular import dependency detected", .action = "restructure module dependencies", .default_priority = "p1", .default_type = "refactor", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "python -c 'import importlib; importlib.import_module(\"pkg\")' | madge --circular (js)" },
    .{ .id = 51, .title = "Missing Type Hints", .category = "code-health", .detection = "functions without type annotations", .action = "add type hints", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "mypy --strict | pyright; check function signatures for missing annotations" },
    .{ .id = 52, .title = "Unused Imports", .category = "code-health", .detection = "imported modules never referenced", .action = "remove unused imports", .default_priority = "p2", .default_type = "refactor", .default_effort = "xs", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "autoflake --check (python) | eslint no-unused-vars (js)" },
    .{ .id = 53, .title = "Inconsistent Formatting", .category = "code-health", .detection = "code style deviates from project standard", .action = "run formatter", .default_priority = "p2", .default_type = "chore", .default_effort = "xs", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "black --check (python) | prettier --check (js) | rustfmt --check (rust)" },
    .{ .id = 54, .title = "Poor Naming Patterns", .category = "code-health", .detection = "variable/function names unclear or inconsistent", .action = "rename for clarity", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "pylint naming-convention | eslint camelcase/naming-convention" },
    .{ .id = 55, .title = "Missing Docstrings", .category = "code-health", .detection = "public functions without documentation", .action = "add docstrings", .default_priority = "p2", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "pydocstyle | darglint | interrogate (python)" },
    .{ .id = 56, .title = "Nested Loops", .category = "code-health", .detection = "deeply nested loops (> 3 levels)", .action = "refactor to reduce nesting", .default_priority = "p2", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "review code for nested for/while loops > 3 levels deep" },
    .{ .id = 57, .title = "Unsafe Pointer Operations", .category = "code-health", .detection = "raw pointer usage without safety checks", .action = "add bounds checking or use safe alternatives", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "clippy (rust) | cppcheck (c/c++) | review unsafe blocks" },
    .{ .id = 58, .title = "Unbounded Recursion", .category = "code-health", .detection = "recursive function without base case limit", .action = "add recursion depth limit", .default_priority = "p1", .default_type = "code", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "review recursive functions for missing base case or depth limit" },
    .{ .id = 59, .title = "Magic Numbers", .category = "code-health", .detection = "unexplained numeric literals in code", .action = "extract to named constants", .default_priority = "p2", .default_type = "refactor", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "pylint --disable=all --enable=W0612 | eslint no-magic-numbers" },
    .{ .id = 60, .title = "Mutable Global State", .category = "code-health", .detection = "global variables modified at runtime", .action = "refactor to local/injected state", .default_priority = "p1", .default_type = "refactor", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "code-health" }, .external_tool = "grep -rn 'global ' (python) | review mutable module-level state" },
    .{ .id = 61, .title = "Slow Database Query", .category = "performance", .detection = "query execution > 500ms", .action = "optimize query or add index", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "EXPLAIN ANALYZE <query>; pg_stat_statements; slow query log" },
    .{ .id = 62, .title = "N+1 Query Pattern", .category = "performance", .detection = "repeated queries in loop", .action = "batch or join queries", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "django-debug-toolbar | bullet gem (rails) | review ORM queries in loops" },
    .{ .id = 63, .title = "Memory Leak Detection", .category = "performance", .detection = "heap growth without release", .action = "fix memory leak", .default_priority = "p0", .default_type = "code", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "valgrind --leak-check=full | heaptrack | node --inspect + Chrome DevTools" },
    .{ .id = 64, .title = "High API Latency", .category = "performance", .detection = "p95 latency exceeds threshold", .action = "profile and optimize endpoint", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "check APM dashboards (Datadog, New Relic, Grafana) for p95 latency" },
    .{ .id = 65, .title = "Cache Miss Ratio", .category = "performance", .detection = "cache miss ratio > 0.6", .action = "tune cache strategy", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "redis-cli INFO stats | memcached stats; check cache hit/miss metrics" },
    .{ .id = 66, .title = "Large Response Payloads", .category = "performance", .detection = "API response size exceeds threshold", .action = "add pagination or compression", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "curl -s <api> | wc -c; check API response sizes in APM" },
    .{ .id = 67, .title = "O(n^2) Algorithms", .category = "performance", .detection = "quadratic complexity in hot paths", .action = "replace with efficient algorithm", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "review hot-path code for nested loops; profile with py-spy/perf/flamegraph" },
    .{ .id = 68, .title = "Unbounded Job Queue", .category = "performance", .detection = "job queue grows without limit", .action = "add backpressure or queue limits", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "check job queue metrics (Sidekiq, Celery, Bull) for queue depth trends" },
    .{ .id = 69, .title = "Excessive Logging Overhead", .category = "performance", .detection = "high-frequency logging in hot paths", .action = "reduce log verbosity or sample", .default_priority = "p2", .default_type = "code", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "review logging in hot paths; check log volume metrics" },
    .{ .id = 70, .title = "Slow Cold Start", .category = "performance", .detection = "service startup > threshold", .action = "optimize initialization", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "time service startup; profile with py-spy/perf during init" },
    .{ .id = 71, .title = "Thread Starvation", .category = "performance", .detection = "thread pool exhaustion detected", .action = "increase pool size or reduce blocking", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "jstack (java) | py-spy dump | review thread pool configs" },
    .{ .id = 72, .title = "Lock Contention", .category = "performance", .detection = "high lock wait times", .action = "reduce critical section scope", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "lock contention profiling; review mutex/lock usage in hot paths" },
    .{ .id = 73, .title = "Blocking IO in Async Code", .category = "performance", .detection = "synchronous IO in async context", .action = "convert to async IO", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "review async code for sync IO calls (requests, open, subprocess)" },
    .{ .id = 74, .title = "Oversized Images", .category = "performance", .detection = "image assets exceed size threshold", .action = "compress or resize images", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "find . -name '*.png' -o -name '*.jpg' | xargs identify -format '%f %wx%h %b\n'" },
    .{ .id = 75, .title = "Redundant Network Calls", .category = "performance", .detection = "duplicate API calls for same data", .action = "deduplicate or cache results", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "review network calls in code; check for duplicate HTTP requests in APM" },
    .{ .id = 76, .title = "Inefficient Serialization", .category = "performance", .detection = "slow serialization format in hot path", .action = "switch to efficient format", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "benchmark serialization (json vs msgpack vs protobuf) in hot paths" },
    .{ .id = 77, .title = "Slow WASM Execution Path", .category = "performance", .detection = "WASM module performance below threshold", .action = "profile and optimize WASM code", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "wasm profiling tools; review WASM module execution times" },
    .{ .id = 78, .title = "GPU Underutilization", .category = "performance", .detection = "GPU compute usage below capacity", .action = "optimize GPU workload distribution", .default_priority = "p2", .default_type = "code", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "nvidia-smi dmon; review GPU utilization metrics" },
    .{ .id = 79, .title = "Excessive Disk Writes", .category = "performance", .detection = "write IOPS exceeds threshold", .action = "batch or buffer writes", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "iostat; check write IOPS metrics; review fsync/flush patterns" },
    .{ .id = 80, .title = "Poor Pagination", .category = "performance", .detection = "unbounded result sets returned", .action = "implement cursor-based pagination", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "performance" }, .external_tool = "review API endpoints for unbounded SELECT/find queries without LIMIT" },
    .{ .id = 81, .title = "Missing Index", .category = "database", .detection = "frequent query without supporting index", .action = "add database index", .default_priority = "p1", .default_type = "code", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "EXPLAIN ANALYZE <query>; pg_stat_user_tables (seq_scan count); slow query log" },
    .{ .id = 82, .title = "Unused Index", .category = "database", .detection = "index with zero reads", .action = "drop unused index", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_indexes (idx_scan = 0); MySQL sys.schema_unused_indexes" },
    .{ .id = 83, .title = "Table Bloat", .category = "database", .detection = "dead tuple ratio exceeds threshold", .action = "vacuum or repack table", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_tables (n_dead_tup); VACUUM VERBOSE" },
    .{ .id = 84, .title = "Fragmented Index", .category = "database", .detection = "index fragmentation > threshold", .action = "rebuild index", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_indexes; DBCC SHOWCONTIG (SQL Server); OPTIMIZE TABLE (MySQL)" },
    .{ .id = 85, .title = "Orphan Records", .category = "database", .detection = "records referencing deleted parents", .action = "clean up orphan records", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT orphans with LEFT JOIN ... WHERE parent.id IS NULL" },
    .{ .id = 86, .title = "Duplicate Rows", .category = "database", .detection = "duplicate records detected", .action = "deduplicate data", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT columns, COUNT(*) GROUP BY columns HAVING COUNT(*) > 1" },
    .{ .id = 87, .title = "Data Format Drift", .category = "database", .detection = "column data deviates from expected format", .action = "normalize data format", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "sample column data and check format consistency; pg_typeof()" },
    .{ .id = 88, .title = "Backup Failure", .category = "database", .detection = "last backup older than policy threshold", .action = "investigate and fix backup", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_archiver; check backup tool logs (pg_dump, mysqldump, mongodump)" },
    .{ .id = 89, .title = "Failed Migration", .category = "database", .detection = "migration in failed/partial state", .action = "fix and rerun migration", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "check migration status table; rails db:migrate:status | alembic current" },
    .{ .id = 90, .title = "Slow Join Queries", .category = "database", .detection = "join query exceeding time threshold", .action = "optimize join or denormalize", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "EXPLAIN ANALYZE for JOIN queries; check pg_stat_statements for slow joins" },
    .{ .id = 91, .title = "Oversized JSON Columns", .category = "database", .detection = "JSON column average size exceeds threshold", .action = "normalize into relational columns", .default_priority = "p2", .default_type = "refactor", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT avg(pg_column_size(json_col)) FROM table; check JSON column sizes" },
    .{ .id = 92, .title = "Unused Tables", .category = "database", .detection = "tables with no recent reads or writes", .action = "archive or drop unused tables", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_tables (last_autovacuum, seq_scan, idx_scan for zero-activity tables)" },
    .{ .id = 93, .title = "Table Scan Alerts", .category = "database", .detection = "full table scan on large table", .action = "add index or optimize query", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_tables (seq_scan on large tables); MySQL slow query log" },
    .{ .id = 94, .title = "Encoding Mismatch", .category = "database", .detection = "mixed character encodings across tables", .action = "standardize encoding", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT table_name, character_set_name FROM information_schema.columns" },
    .{ .id = 95, .title = "Unbounded Table Growth", .category = "database", .detection = "table row count growing without retention policy", .action = "implement retention or archival", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC" },
    .{ .id = 96, .title = "Missing Partitioning", .category = "database", .detection = "large table without partitioning scheme", .action = "add table partitioning", .default_priority = "p2", .default_type = "chore", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "check table sizes; review partitioning strategy for tables > 10M rows" },
    .{ .id = 97, .title = "Outdated Statistics", .category = "database", .detection = "query planner statistics stale", .action = "analyze/update statistics", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_stat_user_tables (last_analyze); ANALYZE VERBOSE" },
    .{ .id = 98, .title = "Corrupted Index Pages", .category = "database", .detection = "index corruption detected", .action = "rebuild corrupted index", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "pg_catalog.pg_index (indisvalid = false); REINDEX" },
    .{ .id = 99, .title = "Replication Lag", .category = "database", .detection = "replica behind primary by threshold", .action = "investigate replication lag", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "SELECT * FROM pg_stat_replication; check replica lag metrics" },
    .{ .id = 100, .title = "Foreign Key Inconsistencies", .category = "database", .detection = "orphaned foreign key references", .action = "fix referential integrity", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "database" }, .external_tool = "check foreign key constraints; SELECT with LEFT JOIN for orphaned references" },
    .{ .id = 101, .title = "Container Image Outdated", .category = "infrastructure", .detection = "base image version behind latest", .action = "update container base image", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "docker pull <image>:latest --dry-run; compare Dockerfile FROM tag to latest" },
    .{ .id = 102, .title = "Missing OS Security Patches", .category = "infrastructure", .detection = "OS packages with available security updates", .action = "apply security patches", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "apt list --upgradable | yum check-update | apk version -l '<'" },
    .{ .id = 103, .title = "Low Disk Space", .category = "infrastructure", .detection = "disk usage > 85%", .action = "clean up or expand storage", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "df -h; kubectl top nodes; cloud console storage metrics" },
    .{ .id = 104, .title = "CPU Saturation", .category = "infrastructure", .detection = "sustained CPU usage > 90%", .action = "scale or optimize workload", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "top; kubectl top pods; cloud monitoring CPU metrics" },
    .{ .id = 105, .title = "Memory Pressure", .category = "infrastructure", .detection = "memory usage > 90% or OOM events", .action = "investigate memory usage and scale", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "free -h; kubectl top pods; check OOM events in dmesg/journal" },
    .{ .id = 106, .title = "CrashLoop Pods", .category = "infrastructure", .detection = "pod in CrashLoopBackOff state", .action = "diagnose and fix crash loop", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "kubectl get pods --field-selector=status.phase!=Running; kubectl describe pod" },
    .{ .id = 107, .title = "Orphan Containers", .category = "infrastructure", .detection = "stopped containers consuming resources", .action = "remove orphan containers", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "docker ps -a --filter status=exited; docker system df" },
    .{ .id = 108, .title = "Stale Storage Volumes", .category = "infrastructure", .detection = "unattached volumes with no recent access", .action = "clean up stale volumes", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "kubectl get pv --no-headers | grep Available; aws ec2 describe-volumes --filters Name=status,Values=available" },
    .{ .id = 109, .title = "Expired DNS Records", .category = "infrastructure", .detection = "DNS records pointing to decommissioned resources", .action = "update DNS records", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "dig <hostname>; nslookup; check DNS records against active infrastructure" },
    .{ .id = 110, .title = "Misconfigured Load Balancer", .category = "infrastructure", .detection = "health check failures or routing errors", .action = "fix load balancer configuration", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "kubectl describe ingress; aws elb describe-target-health; health check logs" },
    .{ .id = 111, .title = "High Network Latency", .category = "infrastructure", .detection = "inter-service latency exceeds threshold", .action = "investigate network path", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "ping; traceroute; mtr; check network latency metrics in monitoring" },
    .{ .id = 112, .title = "Unused Cloud Resources", .category = "infrastructure", .detection = "idle VMs, IPs, or load balancers", .action = "decommission unused resources", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped; cloud cost reports" },
    .{ .id = 113, .title = "Broken CI Runners", .category = "infrastructure", .detection = "CI runner offline or failing jobs", .action = "repair or replace CI runner", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "check CI dashboard for offline runners; gitlab-runner verify; gh api /repos/{owner}/{repo}/actions/runners" },
    .{ .id = 114, .title = "Container Restart Loops", .category = "infrastructure", .detection = "container restart count exceeds threshold", .action = "diagnose restart cause", .default_priority = "p0", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "docker inspect --format='{{.RestartCount}}'; kubectl describe pod (restart count)" },
    .{ .id = 115, .title = "Unused Security Groups", .category = "infrastructure", .detection = "security groups not attached to resources", .action = "remove unused security groups", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "aws ec2 describe-security-groups; check for unattached security groups" },
    .{ .id = 116, .title = "Expired API Gateway Cert", .category = "infrastructure", .detection = "API gateway certificate expiring soon", .action = "renew API gateway certificate", .default_priority = "p0", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "aws apigateway get-domain-names; check certificate expiry dates" },
    .{ .id = 117, .title = "Infrastructure Drift", .category = "infrastructure", .detection = "live config differs from IaC definitions", .action = "reconcile infrastructure state", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "terraform plan | pulumi preview | compare live state vs IaC definitions" },
    .{ .id = 118, .title = "Registry Cleanup Required", .category = "infrastructure", .detection = "container registry storage exceeds threshold", .action = "prune old images from registry", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "docker system df; cloud registry storage metrics; skopeo list-tags" },
    .{ .id = 119, .title = "Log Storage Overflow", .category = "infrastructure", .detection = "log volume approaching storage limit", .action = "rotate or archive logs", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "du -sh /var/log; check log rotation config; cloud logging storage metrics" },
    .{ .id = 120, .title = "Node Version Drift", .category = "infrastructure", .detection = "cluster nodes running different versions", .action = "align node versions", .default_priority = "p1", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "infrastructure" }, .external_tool = "kubectl get nodes -o wide; compare node versions across cluster" },
    .{ .id = 121, .title = "Missing Metrics", .category = "observability", .detection = "service endpoints without metrics instrumentation", .action = "add metrics collection", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review service endpoints for metrics instrumentation; check Prometheus targets" },
    .{ .id = 122, .title = "Broken Alerts", .category = "observability", .detection = "alert rules referencing missing metrics", .action = "fix alert configuration", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "promtool check rules; review alert rule YAML for missing metric references" },
    .{ .id = 123, .title = "Missing Distributed Tracing", .category = "observability", .detection = "services without trace propagation", .action = "add trace instrumentation", .default_priority = "p1", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review code for trace context propagation (OpenTelemetry, Jaeger, Zipkin)" },
    .{ .id = 124, .title = "Log Retention Overflow", .category = "observability", .detection = "log retention exceeding storage policy", .action = "adjust retention policy", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "check log retention policies; du -sh log storage; cloud logging config" },
    .{ .id = 125, .title = "Missing Uptime Checks", .category = "observability", .detection = "production endpoints without health monitoring", .action = "add uptime checks", .default_priority = "p1", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review uptime monitoring config (Pingdom, UptimeRobot, cloud health checks)" },
    .{ .id = 126, .title = "Alert Fatigue Detection", .category = "observability", .detection = "high volume of non-actionable alerts", .action = "tune alert thresholds", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review alert history for frequency; check PagerDuty/Opsgenie alert volume" },
    .{ .id = 127, .title = "Missing Error Classification", .category = "observability", .detection = "errors logged without categorization", .action = "add error classification", .default_priority = "p2", .default_type = "code", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review error logging for categorization (error codes, error types)" },
    .{ .id = 128, .title = "Inconsistent Log Schema", .category = "observability", .detection = "log format varies across services", .action = "standardize log schema", .default_priority = "p2", .default_type = "chore", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "compare log formats across services; check structured logging config" },
    .{ .id = 129, .title = "Missing Service Map", .category = "observability", .detection = "no service dependency map available", .action = "generate service map", .default_priority = "p2", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review service dependencies; generate from traces or config (Kiali, Jaeger)" },
    .{ .id = 130, .title = "Outdated Dashboards", .category = "observability", .detection = "dashboards referencing deprecated metrics", .action = "update dashboards", .default_priority = "p2", .default_type = "chore", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "observability" }, .external_tool = "review Grafana/Datadog dashboards for deprecated metric references" },
    .{ .id = 131, .title = "Failing Tests", .category = "testing", .detection = "test suite has persistent failures", .action = "fix failing tests", .default_priority = "p0", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "run test suite and check exit code; review CI pipeline history for failures" },
    .{ .id = 132, .title = "Flaky Tests", .category = "testing", .detection = "tests with intermittent pass/fail", .action = "stabilize flaky tests", .default_priority = "p1", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "run tests multiple times; check CI history for intermittent failures" },
    .{ .id = 133, .title = "Missing Regression Tests", .category = "testing", .detection = "recent bug fixes without regression tests", .action = "add regression tests", .default_priority = "p1", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "review recent bug-fix commits for associated test additions" },
    .{ .id = 134, .title = "Low Coverage Modules", .category = "testing", .detection = "modules below coverage threshold", .action = "add tests for low coverage areas", .default_priority = "p2", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "coverage run -m pytest; nyc; go test -cover; review coverage report" },
    .{ .id = 135, .title = "Outdated Snapshot Tests", .category = "testing", .detection = "snapshot tests not updated after code changes", .action = "update snapshot tests", .default_priority = "p2", .default_type = "tests", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "jest --updateSnapshot --dry-run; check snapshot diff against code changes" },
    .{ .id = 136, .title = "Slow Test Suite", .category = "testing", .detection = "test suite execution exceeds threshold", .action = "optimize slow tests", .default_priority = "p2", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "time test suite execution; pytest --durations=10; jest --verbose" },
    .{ .id = 137, .title = "Missing Integration Tests", .category = "testing", .detection = "critical paths without integration test coverage", .action = "add integration tests", .default_priority = "p1", .default_type = "tests", .default_effort = "l", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "review critical user paths for integration test coverage" },
    .{ .id = 138, .title = "Broken CI Pipeline", .category = "testing", .detection = "CI pipeline failing on main branch", .action = "fix CI pipeline", .default_priority = "p0", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "check CI pipeline status on main branch; review recent CI logs" },
    .{ .id = 139, .title = "Missing Edge Case Tests", .category = "testing", .detection = "boundary conditions untested", .action = "add edge case tests", .default_priority = "p2", .default_type = "tests", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "review test cases for boundary values, null inputs, empty collections" },
    .{ .id = 140, .title = "Inconsistent Test Data", .category = "testing", .detection = "test fixtures with hardcoded or stale data", .action = "standardize test data", .default_priority = "p2", .default_type = "tests", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "testing" }, .external_tool = "review test fixtures for hardcoded dates, IDs, or stale data" },
    .{ .id = 141, .title = "Outdated API Docs", .category = "docs", .detection = "API documentation does not match implementation", .action = "update API documentation", .default_priority = "p1", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "diff API implementation against API docs; check OpenAPI spec freshness" },
    .{ .id = 142, .title = "Broken Documentation Links", .category = "docs", .detection = "dead links in documentation", .action = "fix broken links", .default_priority = "p2", .default_type = "docs", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "" },
    .{ .id = 143, .title = "Outdated Onboarding Docs", .category = "docs", .detection = "onboarding guide references removed features", .action = "update onboarding documentation", .default_priority = "p1", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "review onboarding docs against current setup/install process" },
    .{ .id = 144, .title = "Missing Architecture Diagram", .category = "docs", .detection = "no architecture diagram or diagram is outdated", .action = "create or update architecture diagram", .default_priority = "p2", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "check for architecture diagrams in docs/; compare against current system" },
    .{ .id = 145, .title = "Missing CLI Examples", .category = "docs", .detection = "CLI commands without usage examples", .action = "add CLI usage examples", .default_priority = "p2", .default_type = "docs", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "review CLI --help output against documentation examples" },
    .{ .id = 146, .title = "Outdated Deployment Guide", .category = "docs", .detection = "deployment guide does not match current process", .action = "update deployment guide", .default_priority = "p1", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "compare deployment docs against current deploy scripts/CI config" },
    .{ .id = 147, .title = "Undocumented Endpoints", .category = "docs", .detection = "API endpoints without documentation", .action = "document undocumented endpoints", .default_priority = "p1", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "list API routes and compare against documented endpoints" },
    .{ .id = 148, .title = "Stale README", .category = "docs", .detection = "README last updated significantly before repo activity", .action = "update README", .default_priority = "p2", .default_type = "docs", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "" },
    .{ .id = 149, .title = "Outdated SDK Docs", .category = "docs", .detection = "SDK documentation does not match current API", .action = "update SDK documentation", .default_priority = "p1", .default_type = "docs", .default_effort = "m", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "diff SDK methods against API documentation; check SDK version alignment" },
    .{ .id = 150, .title = "Missing Changelog", .category = "docs", .detection = "no changelog or changelog not updated for recent releases", .action = "update changelog", .default_priority = "p2", .default_type = "docs", .default_effort = "s", .labels = &[_][]const u8{ "maintenance", "docs" }, .external_tool = "check CHANGELOG.md last entry date vs latest release tag" },
};

const builtin_scanner_ids = [_]i32{ 2, 6, 15, 18, 42, 48, 142, 148 };

fn hasBuiltinScanner(rule_id: i32) bool {
    for (&builtin_scanner_ids) |id| {
        if (id == rule_id) return true;
    }
    return false;
}

fn filterMaintenanceRules(allocator: std.mem.Allocator, cats: []const []const u8, rule_ids: []const i32) ![]const MaintenanceRule {
    var result = std.array_list.Managed(MaintenanceRule).init(allocator);
    for (&maintenance_rules) |rule| {
        if (cats.len > 0) {
            var cat_match = false;
            for (cats) |cat| {
                if (std.mem.eql(u8, cat, rule.category)) {
                    cat_match = true;
                    break;
                }
            }
            if (!cat_match) continue;
        }
        if (rule_ids.len > 0) {
            var id_match = false;
            for (rule_ids) |rid| {
                if (rid == rule.id) {
                    id_match = true;
                    break;
                }
            }
            if (!id_match) continue;
        }
        try result.append(rule);
    }
    return result.toOwnedSlice();
}

const default_maintain_config =
    \\# tickets/maintain.yaml
    \\# Enable/disable categories and configure external tools for mt maintain scan.
    \\
    \\# Global settings
    \\settings:
    \\  log_file: tickets/maintain.log
    \\  timeout: 60
    \\  enabled: true
    \\
    \\# Per-category tool configuration
    \\# Set enabled: true and provide the command for your stack.
    \\# Use {repo} as placeholder for the repository root path.
    \\
    \\security:
    \\  cve_scanner:
    \\    enabled: false
    \\    # command: pip-audit --format=json
    \\  secret_scanner:
    \\    enabled: false
    \\    # command: gitleaks detect --source={repo} --report-format=json --no-git
    \\  ssl_check:
    \\    enabled: false
    \\
    \\deps:
    \\  outdated_check:
    \\    enabled: false
    \\  license_check:
    \\    enabled: false
    \\  unused_deps:
    \\    enabled: false
    \\
    \\code_health:
    \\  complexity:
    \\    enabled: false
    \\  linter:
    \\    enabled: false
    \\  formatter_check:
    \\    enabled: false
    \\  type_check:
    \\    enabled: false
    \\
    \\performance:
    \\  profiler:
    \\    enabled: false
    \\  bundle_size:
    \\    enabled: false
    \\
    \\database:
    \\  migration_check:
    \\    enabled: false
    \\  query_analyzer:
    \\    enabled: false
    \\
    \\infrastructure:
    \\  container_scan:
    \\    enabled: false
    \\  k8s_health:
    \\    enabled: false
    \\  terraform_drift:
    \\    enabled: false
    \\
    \\observability:
    \\  prometheus_check:
    \\    enabled: false
    \\  alert_check:
    \\    enabled: false
    \\
    \\testing:
    \\  coverage:
    \\    enabled: false
    \\  test_runner:
    \\    enabled: false
    \\
    \\documentation:
    \\  link_checker:
    \\    enabled: false
    \\  openapi_diff:
    \\    enabled: false
    \\
;

const source_extensions = [_][]const u8{
    ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".c", ".h",
    ".cpp", ".java", ".rb", ".sh", ".bash", ".zsh", ".yaml", ".yml",
    ".toml", ".cfg", ".ini", ".json", ".xml", ".zig",
};

const skip_dir_names = [_][]const u8{
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    "target", "zig-out", "zig-cache", "build", "dist", ".tox",
};

fn isMaintSkipDir(name: []const u8) bool {
    for (&skip_dir_names) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

fn hasSourceExt(name: []const u8) bool {
    for (&source_extensions) |ext| {
        if (name.len > ext.len and std.mem.eql(u8, name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

const Finding = struct {
    file: []const u8,
    line: usize,
    detail: []const u8,
};

fn collectSourceFiles(allocator: std.mem.Allocator, repo: []const u8) ![][]const u8 {
    var result = std.array_list.Managed([]const u8).init(allocator);
    try walkSourceFiles(allocator, repo, repo, &result);
    return result.toOwnedSlice();
}

fn walkSourceFiles(allocator: std.mem.Allocator, base: []const u8, dir_path: []const u8, result: *std.array_list.Managed([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        if (entry.kind == .directory) {
            if (!isMaintSkipDir(entry.name)) {
                try walkSourceFiles(allocator, base, full, result);
            }
            allocator.free(full);
        } else if (entry.kind == .file) {
            if (hasSourceExt(entry.name)) {
                if (full.len > base.len + 1) {
                    const rel = try allocator.dupe(u8, full[base.len + 1 ..]);
                    allocator.free(full);
                    try result.append(rel);
                } else {
                    try result.append(full);
                }
            } else {
                allocator.free(full);
            }
        } else {
            allocator.free(full);
        }
    }
}

fn scanExposedSecrets(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    const files = try collectSourceFiles(allocator, repo);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    var findings = std.array_list.Managed(Finding).init(allocator);
    for (files) |rel| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ repo, rel });
        defer allocator.free(full);
        const content = std.fs.cwd().readFileAlloc(allocator, full, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);
        var lineno: usize = 1;
        var line_start: usize = 0;
        for (content, 0..) |ch, i| {
            const is_newline = ch == '\n';
            const is_last = i == content.len - 1;
            if (is_newline or is_last) {
                const line_end = if (is_newline) i else i + 1;
                const line = content[line_start..line_end];
                if (containsAWSKey(line)) {
                    try findings.append(.{ .file = try allocator.dupe(u8, rel), .line = lineno, .detail = "AWS access key pattern detected" });
                } else if (containsHardcodedPassword(line)) {
                    try findings.append(.{ .file = try allocator.dupe(u8, rel), .line = lineno, .detail = "hardcoded password detected" });
                } else if (containsPrivateKey(line)) {
                    try findings.append(.{ .file = try allocator.dupe(u8, rel), .line = lineno, .detail = "private key detected" });
                } else if (containsHardcodedSecretKey(line)) {
                    try findings.append(.{ .file = try allocator.dupe(u8, rel), .line = lineno, .detail = "hardcoded secret_key detected" });
                }
                lineno += 1;
                line_start = i + 1;
            }
        }
    }
    return findings.toOwnedSlice();
}

fn containsAWSKey(line: []const u8) bool {
    if (line.len < 20) return false;
    var i: usize = 0;
    while (i + 20 <= line.len) : (i += 1) {
        if (std.mem.eql(u8, line[i .. i + 4], "AKIA")) {
            var valid = true;
            var j: usize = i + 4;
            while (j < i + 20) : (j += 1) {
                if (!std.ascii.isUpper(line[j]) and !std.ascii.isDigit(line[j])) {
                    valid = false;
                    break;
                }
            }
            if (valid) return true;
        }
    }
    return false;
}

fn containsHardcodedPassword(line: []const u8) bool {
    const idx = std.mem.indexOf(u8, line, "password") orelse return false;
    var i = idx + 8;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len or line[i] != '=') return false;
    i += 1;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len) return false;
    if (line[i] == '"' or line[i] == '\'') {
        const quote = line[i];
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, quote) orelse return false;
        return (end - start) >= 3;
    }
    return false;
}

fn containsPrivateKey(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "-----BEGIN") != null and std.mem.indexOf(u8, line, "PRIVATE KEY-----") != null;
}

fn containsHardcodedSecretKey(line: []const u8) bool {
    const idx = std.mem.indexOf(u8, line, "secret_key") orelse return false;
    var i = idx + 10;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len or line[i] != '=') return false;
    i += 1;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len) return false;
    if (line[i] == '"' or line[i] == '\'') {
        const quote = line[i];
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, quote) orelse return false;
        return (end - start) >= 3;
    }
    return false;
}

fn scanContainerRoot(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    var findings = std.array_list.Managed(Finding).init(allocator);
    var dockerfiles = std.array_list.Managed([]const u8).init(allocator);
    try findDockerfiles(allocator, repo, &dockerfiles);
    defer {
        for (dockerfiles.items) |f| allocator.free(f);
        dockerfiles.deinit();
    }
    for (dockerfiles.items) |df| {
        const content = std.fs.cwd().readFileAlloc(allocator, df, 1024 * 1024) catch continue;
        defer allocator.free(content);
        if (std.mem.indexOf(u8, content, "FROM ") != null and !containsUserDirective(content)) {
            const rel = if (df.len > repo.len + 1) df[repo.len + 1 ..] else df;
            try findings.append(.{
                .file = try allocator.dupe(u8, rel),
                .line = 0,
                .detail = "Dockerfile missing USER directive (runs as root)",
            });
        }
    }
    return findings.toOwnedSlice();
}

fn containsUserDirective(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        // Find start of line
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        if (i + 4 < content.len and std.mem.eql(u8, content[i .. i + 4], "USER")) {
            if (i + 4 < content.len and content[i + 4] == ' ') return true;
        }
        // Skip to next line
        while (i < content.len and content[i] != '\n') : (i += 1) {}
        if (i < content.len) i += 1;
    }
    return false;
}

fn findDockerfiles(allocator: std.mem.Allocator, dir_path: []const u8, results: *std.array_list.Managed([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.name, ".git") and !std.mem.eql(u8, entry.name, "node_modules")) {
                try findDockerfiles(allocator, full, results);
            }
            allocator.free(full);
        } else if (entry.kind == .file) {
            if (std.mem.startsWith(u8, entry.name, "Dockerfile")) {
                try results.append(full);
            } else {
                allocator.free(full);
            }
        } else {
            allocator.free(full);
        }
    }
}

fn scanExposedEnv(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    var findings = std.array_list.Managed(Finding).init(allocator);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "ls-files", "--error-unmatch", ".env" },
        .cwd = repo,
    }) catch {
        return findings.toOwnedSlice();
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term.Exited == 0) {
        try findings.append(.{
            .file = try allocator.dupe(u8, ".env"),
            .line = 0,
            .detail = ".env file is tracked in git",
        });
    }
    return findings.toOwnedSlice();
}

fn scanLargeFiles(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    const threshold: usize = 1000;
    const files = try collectSourceFiles(allocator, repo);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    var findings = std.array_list.Managed(Finding).init(allocator);
    for (files) |rel| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ repo, rel });
        defer allocator.free(full);
        const content = std.fs.cwd().readFileAlloc(allocator, full, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);
        var count: usize = 0;
        for (content) |ch| {
            if (ch == '\n') count += 1;
        }
        if (count > threshold) {
            const detail = try std.fmt.allocPrint(allocator, "{d} lines (threshold: {d})", .{ count, threshold });
            try findings.append(.{
                .file = try allocator.dupe(u8, rel),
                .line = 0,
                .detail = detail,
            });
        }
    }
    return findings.toOwnedSlice();
}

fn scanTodoDensity(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    const threshold: usize = 10;
    const files = try collectSourceFiles(allocator, repo);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    var findings = std.array_list.Managed(Finding).init(allocator);
    const markers = [_][]const u8{ "TODO", "FIXME", "HACK", "XXX" };
    for (files) |rel| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ repo, rel });
        defer allocator.free(full);
        const content = std.fs.cwd().readFileAlloc(allocator, full, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);
        var count: usize = 0;
        var line_start: usize = 0;
        for (content, 0..) |ch, i| {
            if (ch == '\n' or i == content.len - 1) {
                const line = content[line_start..if (ch == '\n') i else i + 1];
                for (&markers) |m| {
                    if (std.mem.indexOf(u8, line, m) != null) {
                        count += 1;
                        break;
                    }
                }
                line_start = i + 1;
            }
        }
        if (count >= threshold) {
            const detail = try std.fmt.allocPrint(allocator, "{d} TODO/FIXME/HACK comments", .{count});
            try findings.append(.{
                .file = try allocator.dupe(u8, rel),
                .line = 0,
                .detail = detail,
            });
        }
    }
    return findings.toOwnedSlice();
}

fn scanBrokenDocLinks(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    var findings = std.array_list.Managed(Finding).init(allocator);
    var md_files = std.array_list.Managed([]const u8).init(allocator);
    try findMdFiles(allocator, repo, &md_files);
    defer {
        for (md_files.items) |f| allocator.free(f);
        md_files.deinit();
    }
    for (md_files.items) |md| {
        const content = std.fs.cwd().readFileAlloc(allocator, md, 1024 * 1024) catch continue;
        defer allocator.free(content);
        const rel = if (md.len > repo.len + 1) md[repo.len + 1 ..] else md;
        const fdir = std.fs.path.dirname(md) orelse repo;
        var lineno: usize = 1;
        var line_start: usize = 0;
        for (content, 0..) |ch, i| {
            if (ch == '\n' or i == content.len - 1) {
                const line = content[line_start..if (ch == '\n') i else i + 1];
                // Find markdown links [text](target)
                var pos: usize = 0;
                while (pos < line.len) {
                    const bracket = std.mem.indexOfScalarPos(u8, line, pos, '[') orelse break;
                    const close_bracket = std.mem.indexOfScalarPos(u8, line, bracket + 1, ']') orelse break;
                    if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                        const close_paren = std.mem.indexOfScalarPos(u8, line, close_bracket + 2, ')') orelse break;
                        const target = line[close_bracket + 2 .. close_paren];
                        if (!std.mem.startsWith(u8, target, "http://") and
                            !std.mem.startsWith(u8, target, "https://") and
                            !std.mem.startsWith(u8, target, "#") and
                            !std.mem.startsWith(u8, target, "mailto:") and
                            target.len > 0)
                        {
                            // Strip fragment and query
                            var clean = target;
                            if (std.mem.indexOfScalar(u8, clean, '#')) |h| clean = clean[0..h];
                            if (std.mem.indexOfScalar(u8, clean, '?')) |q| clean = clean[0..q];
                            if (clean.len > 0) {
                                const full_path = std.fs.path.join(allocator, &[_][]const u8{ fdir, clean }) catch {
                                    pos = close_paren + 1;
                                    continue;
                                };
                                defer allocator.free(full_path);
                                if (!fileExists(full_path) and !dirExists(full_path)) {
                                    const detail = std.fmt.allocPrint(allocator, "broken link to {s}", .{clean}) catch {
                                        pos = close_paren + 1;
                                        continue;
                                    };
                                    findings.append(.{
                                        .file = allocator.dupe(u8, rel) catch {
                                            pos = close_paren + 1;
                                            continue;
                                        },
                                        .line = lineno,
                                        .detail = detail,
                                    }) catch {};
                                }
                            }
                        }
                        pos = close_paren + 1;
                    } else {
                        pos = close_bracket + 1;
                    }
                }
                lineno += 1;
                line_start = i + 1;
            }
        }
    }
    return findings.toOwnedSlice();
}

fn findMdFiles(allocator: std.mem.Allocator, dir_path: []const u8, results: *std.array_list.Managed([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.name, ".git") and !std.mem.eql(u8, entry.name, "node_modules")) {
                try findMdFiles(allocator, full, results);
            }
            allocator.free(full);
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".md")) {
                try results.append(full);
            } else {
                allocator.free(full);
            }
        } else {
            allocator.free(full);
        }
    }
}

fn scanStaleReadme(allocator: std.mem.Allocator, repo: []const u8) ![]Finding {
    var findings = std.array_list.Managed(Finding).init(allocator);
    const readme_path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "README.md" });
    defer allocator.free(readme_path);
    if (!fileExists(readme_path)) {
        try findings.append(.{
            .file = try allocator.dupe(u8, "README.md"),
            .line = 0,
            .detail = "README.md does not exist",
        });
        return findings.toOwnedSlice();
    }
    const readme_stat = std.fs.cwd().statFile(readme_path) catch return findings.toOwnedSlice();
    const readme_mtime = readme_stat.mtime;

    const files = try collectSourceFiles(allocator, repo);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    var latest: i128 = 0;
    for (files) |rel| {
        const full = try std.fs.path.join(allocator, &[_][]const u8{ repo, rel });
        defer allocator.free(full);
        const stat = std.fs.cwd().statFile(full) catch continue;
        if (stat.mtime > latest) latest = stat.mtime;
    }
    if (latest == 0) return findings.toOwnedSlice();
    if (latest > readme_mtime) {
        const diff_ns = latest - readme_mtime;
        const days = @divFloor(diff_ns, @as(i128, 86400) * 1_000_000_000);
        if (days > 90) {
            const detail = try std.fmt.allocPrint(allocator, "README.md is {d} days behind latest source change", .{@as(i64, @intCast(days))});
            try findings.append(.{
                .file = try allocator.dupe(u8, "README.md"),
                .line = 0,
                .detail = detail,
            });
        }
    }
    return findings.toOwnedSlice();
}

fn runBuiltinScanner(allocator: std.mem.Allocator, rule_id: i32, repo: []const u8) !?[]Finding {
    return switch (rule_id) {
        2, 6 => try scanExposedSecrets(allocator, repo),
        15 => try scanContainerRoot(allocator, repo),
        18 => try scanExposedEnv(allocator, repo),
        42 => try scanLargeFiles(allocator, repo),
        48 => try scanTodoDensity(allocator, repo),
        142 => try scanBrokenDocLinks(allocator, repo),
        148 => try scanStaleReadme(allocator, repo),
        else => null,
    };
}

fn detectProjectStack(allocator: std.mem.Allocator, repo: []const u8) ![][]const u8 {
    const checks = [_]struct { name: []const u8, markers: []const []const u8 }{
        .{ .name = "python", .markers = &[_][]const u8{ "pyproject.toml", "setup.py", "requirements.txt", "Pipfile" } },
        .{ .name = "node", .markers = &[_][]const u8{"package.json"} },
        .{ .name = "rust", .markers = &[_][]const u8{"Cargo.toml"} },
        .{ .name = "go", .markers = &[_][]const u8{"go.mod"} },
        .{ .name = "docker", .markers = &[_][]const u8{"Dockerfile"} },
        .{ .name = "terraform", .markers = &[_][]const u8{"main.tf"} },
        .{ .name = "k8s", .markers = &[_][]const u8{ "k8s", "kubernetes" } },
    };
    var detected = std.array_list.Managed([]const u8).init(allocator);
    for (&checks) |check| {
        for (check.markers) |marker| {
            const marker_path = try std.fs.path.join(allocator, &[_][]const u8{ repo, marker });
            defer allocator.free(marker_path);
            if (fileExists(marker_path) or dirExists(marker_path)) {
                try detected.append(check.name);
                break;
            }
        }
    }
    return detected.toOwnedSlice();
}

fn generateDetectedConfig(allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    const stacks = try detectProjectStack(allocator, repo);
    defer allocator.free(stacks);
    var has_python = false;
    var has_node = false;
    var has_rust = false;
    var has_go = false;
    var has_docker = false;
    var has_terraform = false;
    var stack_names = std.array_list.Managed(u8).init(allocator);
    defer stack_names.deinit();
    for (stacks, 0..) |s, i| {
        if (i > 0) try stack_names.appendSlice(", ");
        try stack_names.appendSlice(s);
        if (std.mem.eql(u8, s, "python")) has_python = true;
        if (std.mem.eql(u8, s, "node")) has_node = true;
        if (std.mem.eql(u8, s, "rust")) has_rust = true;
        if (std.mem.eql(u8, s, "go")) has_go = true;
        if (std.mem.eql(u8, s, "docker")) has_docker = true;
        if (std.mem.eql(u8, s, "terraform")) has_terraform = true;
    }
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();
    try w.print("# tickets/maintain.yaml\n# Auto-generated by mt maintain init-config --detect\n# Detected stacks: {s}\n\n", .{if (stacks.len == 0) "none" else stack_names.items});
    try w.writeAll("settings:\n  log_file: tickets/maintain.log\n  timeout: 60\n  enabled: true\n\n");

    if (has_python) {
        try w.writeAll("security:\n  cve_scanner:\n    enabled: true\n    command: pip-audit --format=json\n  secret_scanner:\n    enabled: true\n    command: gitleaks detect --source={repo} --report-format=json --no-git\n\ndeps:\n  outdated_check:\n    enabled: true\n    command: pip list --outdated --format=json\n\ncode_health:\n  linter:\n    enabled: true\n    command: pylint {repo} --output-format=json --exit-zero\n  formatter_check:\n    enabled: true\n    command: black --check {repo} --quiet\n\ntesting:\n  test_runner:\n    enabled: true\n    command: pytest {repo} --tb=short -q\n  coverage:\n    enabled: true\n    command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout\n\n");
    } else if (has_node) {
        try w.writeAll("security:\n  cve_scanner:\n    enabled: true\n    command: npm audit --json\n  secret_scanner:\n    enabled: true\n    command: gitleaks detect --source={repo} --report-format=json --no-git\n\ndeps:\n  outdated_check:\n    enabled: true\n    command: npm outdated --json\n\ncode_health:\n  linter:\n    enabled: true\n    command: eslint src --format=json\n  formatter_check:\n    enabled: true\n    command: \"prettier --check 'src/**/*.{ts,tsx,js}'\"\n\ntesting:\n  test_runner:\n    enabled: true\n    command: npm test -- --json\n  coverage:\n    enabled: true\n    command: nyc --reporter=json npm test\n\n");
    } else if (has_rust) {
        try w.writeAll("security:\n  cve_scanner:\n    enabled: true\n    command: cargo audit --json\n  secret_scanner:\n    enabled: true\n    command: gitleaks detect --source={repo} --report-format=json --no-git\n\ndeps:\n  outdated_check:\n    enabled: true\n    command: cargo outdated --format=json\n\ncode_health:\n  formatter_check:\n    enabled: true\n    command: cargo fmt --check\n\ntesting:\n  test_runner:\n    enabled: true\n    command: cargo test --message-format=json\n\n");
    } else if (has_go) {
        try w.writeAll("security:\n  cve_scanner:\n    enabled: true\n    command: govulncheck ./...\n  secret_scanner:\n    enabled: true\n    command: gitleaks detect --source={repo} --report-format=json --no-git\n\ntesting:\n  test_runner:\n    enabled: true\n    command: go test ./...\n  coverage:\n    enabled: true\n    command: go test -coverprofile=coverage.out ./...\n\n");
    } else {
        try w.writeAll("security:\n  secret_scanner:\n    enabled: false\n    # command: gitleaks detect --source={repo} --report-format=json --no-git\n\n");
    }

    if (has_docker) {
        try w.writeAll("infrastructure:\n  container_scan:\n    enabled: true\n    command: trivy image --format=json\n\n");
    }
    if (has_terraform) {
        try w.writeAll("infrastructure:\n  terraform_drift:\n    enabled: true\n    command: terraform plan -detailed-exitcode -json\n\n");
    }
    try w.writeAll("documentation:\n  link_checker:\n    enabled: false\n    # command: markdown-link-check {repo}/docs/**/*.md --json\n\n");

    return buf.toOwnedSlice();
}

fn loadMaintainConfig(allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets", "maintain.yaml" });
    defer allocator.free(config_path);
    return std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return try allocator.dupe(u8, "");
}

fn yamlGetValue(content: []const u8, key: []const u8) ?[]const u8 {
    // Simple YAML key: value lookup (single level only)
    var line_start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n' or i == content.len - 1) {
            const line_end = if (ch == '\n') i else i + 1;
            const line = content[line_start..line_end];
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, key)) {
                const after_key = trimmed[key.len..];
                if (after_key.len > 0 and after_key[0] == ':') {
                    const val = std.mem.trimLeft(u8, after_key[1..], " \t");
                    const val_trimmed = std.mem.trimRight(u8, val, " \t\r\n");
                    if (val_trimmed.len > 0) return val_trimmed;
                }
            }
            line_start = i + 1;
        }
    }
    return null;
}

fn configGetBool(content: []const u8, key: []const u8) bool {
    const val = yamlGetValue(content, key) orelse return false;
    return std.mem.eql(u8, val, "true");
}

const EnabledTool = struct {
    name: []const u8,
    command: []const u8,
    rule_ids: []const i32,
};

const config_category_map = [_]struct { key: []const u8, slug: []const u8 }{
    .{ .key = "security", .slug = "security" },
    .{ .key = "deps", .slug = "deps" },
    .{ .key = "code_health", .slug = "code-health" },
    .{ .key = "performance", .slug = "performance" },
    .{ .key = "database", .slug = "database" },
    .{ .key = "infrastructure", .slug = "infrastructure" },
    .{ .key = "observability", .slug = "observability" },
    .{ .key = "testing", .slug = "testing" },
    .{ .key = "documentation", .slug = "docs" },
};

const ToolRuleMapping = struct { name: []const u8, rule_ids: []const i32 };
const config_tool_rule_map = [_]ToolRuleMapping{
    .{ .name = "cve_scanner", .rule_ids = &[_]i32{ 1, 25 } },
    .{ .name = "secret_scanner", .rule_ids = &[_]i32{ 2, 6 } },
    .{ .name = "ssl_check", .rule_ids = &[_]i32{3} },
    .{ .name = "outdated_check", .rule_ids = &[_]i32{21} },
    .{ .name = "license_check", .rule_ids = &[_]i32{31} },
    .{ .name = "unused_deps", .rule_ids = &[_]i32{30} },
    .{ .name = "complexity", .rule_ids = &[_]i32{41} },
    .{ .name = "linter", .rule_ids = &[_]i32{ 44, 45, 47 } },
    .{ .name = "formatter_check", .rule_ids = &[_]i32{53} },
    .{ .name = "type_check", .rule_ids = &[_]i32{55} },
    .{ .name = "profiler", .rule_ids = &[_]i32{63} },
    .{ .name = "bundle_size", .rule_ids = &[_]i32{29} },
    .{ .name = "migration_check", .rule_ids = &[_]i32{89} },
    .{ .name = "query_analyzer", .rule_ids = &[_]i32{61} },
    .{ .name = "container_scan", .rule_ids = &[_]i32{101} },
    .{ .name = "k8s_health", .rule_ids = &[_]i32{106} },
    .{ .name = "terraform_drift", .rule_ids = &[_]i32{117} },
    .{ .name = "prometheus_check", .rule_ids = &[_]i32{121} },
    .{ .name = "alert_check", .rule_ids = &[_]i32{122} },
    .{ .name = "coverage", .rule_ids = &[_]i32{134} },
    .{ .name = "test_runner", .rule_ids = &[_]i32{131} },
    .{ .name = "link_checker", .rule_ids = &[_]i32{142} },
    .{ .name = "openapi_diff", .rule_ids = &[_]i32{141} },
};

fn getToolRuleIds(tool_name: []const u8) []const i32 {
    for (&config_tool_rule_map) |mapping| {
        if (std.mem.eql(u8, mapping.name, tool_name)) return mapping.rule_ids;
    }
    return &[_]i32{};
}

fn getEnabledExternalTools(allocator: std.mem.Allocator, config: []const u8) ![]EnabledTool {
    // Simple YAML parsing: look for tool blocks with enabled: true and command: ...
    // This is a simplified version that looks for patterns in the config
    var tools = std.array_list.Managed(EnabledTool).init(allocator);
    // For the simplified port, we parse the YAML config to find enabled tools
    // The config structure is: category: tool_name: enabled: true/command: ...
    // We scan line by line tracking indentation context
    var lines_iter = std.mem.splitScalar(u8, config, '\n');
    var current_tool: ?[]const u8 = null;
    var tool_enabled = false;
    var tool_command: ?[]const u8 = null;

    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Count indentation
        var indent: usize = 0;
        for (line) |ch| {
            if (ch == ' ') {
                indent += 1;
            } else break;
        }

        if (indent == 2) {
            // Tool name level - save previous tool if valid
            if (current_tool != null and tool_enabled and tool_command != null) {
                try tools.append(.{
                    .name = current_tool.?,
                    .command = tool_command.?,
                    .rule_ids = getToolRuleIds(current_tool.?),
                });
            }
            // Parse new tool name
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                current_tool = trimmed[0..colon];
                tool_enabled = false;
                tool_command = null;
            }
        } else if (indent >= 4 and current_tool != null) {
            // Tool property
            if (std.mem.startsWith(u8, trimmed, "enabled:")) {
                const val = std.mem.trimLeft(u8, trimmed[8..], " \t");
                tool_enabled = std.mem.eql(u8, val, "true");
            } else if (std.mem.startsWith(u8, trimmed, "command:")) {
                const val = std.mem.trimLeft(u8, trimmed[8..], " \t");
                if (val.len > 0) tool_command = val;
            }
        } else if (indent == 0 and trimmed.len > 0) {
            // Category level - save previous tool if valid
            if (current_tool != null and tool_enabled and tool_command != null) {
                try tools.append(.{
                    .name = current_tool.?,
                    .command = tool_command.?,
                    .rule_ids = getToolRuleIds(current_tool.?),
                });
            }
            current_tool = null;
            tool_enabled = false;
            tool_command = null;
        }
    }
    // Save last tool if valid
    if (current_tool != null and tool_enabled and tool_command != null) {
        try tools.append(.{
            .name = current_tool.?,
            .command = tool_command.?,
            .rule_ids = getToolRuleIds(current_tool.?),
        });
    }
    return tools.toOwnedSlice();
}

fn runExternalTool(allocator: std.mem.Allocator, command: []const u8, repo: []const u8) !struct { code: u8, stdout: []u8, stderr: []u8 } {
    // Replace {repo} in command
    var cmd_buf = std.array_list.Managed(u8).init(allocator);
    defer cmd_buf.deinit();
    var i: usize = 0;
    while (i < command.len) {
        if (i + 6 <= command.len and std.mem.eql(u8, command[i .. i + 6], "{repo}")) {
            try cmd_buf.appendSlice(repo);
            i += 6;
        } else {
            try cmd_buf.append(command[i]);
            i += 1;
        }
    }
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", cmd_buf.items },
        .cwd = repo,
        .max_output_bytes = 1024 * 1024,
    }) catch |e| {
        return .{
            .code = 255,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(allocator, "{}", .{e}),
        };
    };
    const code: u8 = switch (result.term) {
        .Exited => |ec| ec,
        else => 255,
    };
    return .{
        .code = code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

const ScanResult = struct {
    rule_id: i32,
    status: []const u8,
    title: []const u8,
    category: []const u8,
    findings: []Finding,
    reason: ?[]const u8,
};

fn scanRuleWithConfig(allocator: std.mem.Allocator, rule: MaintenanceRule, config: []const u8, repo: []const u8) !ScanResult {
    // Try built-in scanner
    if (try runBuiltinScanner(allocator, rule.id, repo)) |findings| {
        const status: []const u8 = if (findings.len == 0) "pass" else "fail";
        return .{
            .rule_id = rule.id,
            .status = status,
            .title = rule.title,
            .category = rule.category,
            .findings = findings,
            .reason = null,
        };
    }

    // Try external tool
    const ext_tools = try getEnabledExternalTools(allocator, config);
    defer allocator.free(ext_tools);
    for (ext_tools) |tool| {
        for (tool.rule_ids) |rid| {
            if (rid == rule.id) {
                const result = try runExternalTool(allocator, tool.command, repo);
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.code == 0) {
                    return .{
                        .rule_id = rule.id,
                        .status = "pass",
                        .title = rule.title,
                        .category = rule.category,
                        .findings = &[_]Finding{},
                        .reason = null,
                    };
                } else {
                    const detail_src = if (result.stdout.len > 0) result.stdout else result.stderr;
                    const detail_len = @min(detail_src.len, 200);
                    const detail = try std.fmt.allocPrint(allocator, "external tool '{s}' reported issue: {s}", .{ tool.name, detail_src[0..detail_len] });
                    var findings = try allocator.alloc(Finding, 1);
                    findings[0] = .{
                        .file = try allocator.dupe(u8, ""),
                        .line = 0,
                        .detail = detail,
                    };
                    return .{
                        .rule_id = rule.id,
                        .status = "fail",
                        .title = rule.title,
                        .category = rule.category,
                        .findings = findings,
                        .reason = null,
                    };
                }
            }
        }
    }

    // No scanner
    var reason_buf = std.array_list.Managed(u8).init(allocator);
    try reason_buf.appendSlice("no built-in scanner");
    if (rule.external_tool.len > 0) {
        try reason_buf.appendSlice("; try: ");
        try reason_buf.appendSlice(rule.external_tool);
    }
    return .{
        .rule_id = rule.id,
        .status = "skip",
        .title = rule.title,
        .category = rule.category,
        .findings = &[_]Finding{},
        .reason = try reason_buf.toOwnedSlice(),
    };
}

fn formatSuggestionBody(allocator: std.mem.Allocator, rule: MaintenanceRule) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();
    try w.print("## Goal\nInvestigate and remediate: {s}\n\n## Detection Heuristic\n{s}\n", .{ rule.title, rule.detection });
    if (rule.external_tool.len > 0) {
        try w.print("\n## External Tool\n```\n{s}\n```\n", .{rule.external_tool});
    }
    try w.print("\n## Recommended Action\n{s}\n\n## Acceptance Criteria\n- [ ] Run detection heuristic against codebase\n- [ ] Fix any issues found, or close ticket if none exist\n- [ ] Verify fix passes CI\n\n## Notes\nAuto-generated by `mt maintain create` (rule {d}, category: {s})\n", .{ rule.action, rule.id, rule.category });
    return buf.toOwnedSlice();
}

fn formatFindingBody(allocator: std.mem.Allocator, rule: MaintenanceRule, findings: []const Finding) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();
    try w.print("## Goal\nFix detected issue: {s}\n\n## Findings\n", .{rule.title});
    for (findings) |f| {
        if (f.line > 0) {
            try w.print("- `{s}` (line {d}): {s}\n", .{ f.file, f.line, f.detail });
        } else {
            try w.print("- `{s}` (file): {s}\n", .{ f.file, f.detail });
        }
    }
    try w.print("\n## Recommended Action\n{s}\n\n## Acceptance Criteria\n- [ ] Address all findings listed above\n- [ ] Verify fix passes CI\n\n## Notes\nAuto-detected by `mt maintain scan` (rule {d}, category: {s})\n", .{ rule.action, rule.id, rule.category });
    return buf.toOwnedSlice();
}

fn collectExistingMaintTags(allocator: std.mem.Allocator, repo: []const u8) ![][]const u8 {
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    var tags = std.array_list.Managed([]const u8).init(allocator);
    if (!dirExists(tdir)) return tags.toOwnedSlice();
    var dir = std.fs.cwd().openDir(tdir, .{ .iterate = true }) catch return tags.toOwnedSlice();
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isTicketFilename(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, entry.name });
        defer allocator.free(path);
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch continue;
        defer allocator.free(content);
        const status = parseMetaField(content, "status") orelse "ready";
        if (std.mem.eql(u8, status, "done")) continue;
        // Parse tags field for maint-rule-* entries
        const tags_field = parseMetaField(content, "tags") orelse continue;
        if (tags_field.len < 2) continue;
        // Parse [tag1, tag2] format
        const inner = if (tags_field[0] == '[' and tags_field[tags_field.len - 1] == ']')
            tags_field[1 .. tags_field.len - 1]
        else
            continue;
        var tag_iter = std.mem.splitScalar(u8, inner, ',');
        while (tag_iter.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " \t'\"");
            if (std.mem.startsWith(u8, tag, "maint-rule-")) {
                try tags.append(try allocator.dupe(u8, tag));
            }
        }
    }
    return tags.toOwnedSlice();
}

fn hasMaintTag(tags: []const []const u8, tag: []const u8) bool {
    for (tags) |t| {
        if (std.mem.eql(u8, t, tag)) return true;
    }
    return false;
}

fn cmdMaintain(allocator: std.mem.Allocator, cmd_args: []const [:0]u8) !void {
    if (cmd_args.len == 0) {
        std.debug.print("usage: mt-zig maintain <subcommand>\nsubcommands: init-config, doctor, list, scan, create\n", .{});
        std.process.exit(2);
    }

    const subcmd = cmd_args[0];
    const sub_args = cmd_args[1..];

    if (std.mem.eql(u8, subcmd, "init-config")) {
        try cmdMaintainInitConfig(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "doctor")) {
        try cmdMaintainDoctor(allocator);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try cmdMaintainList(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "scan")) {
        try cmdMaintainScan(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "create")) {
        try cmdMaintainCreate(allocator, sub_args);
    } else {
        std.debug.print("unknown maintain subcommand: {s}\n", .{subcmd});
        std.process.exit(2);
    }
}

fn cmdMaintainInitConfig(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const force = hasFlag(args, "--force");
    const detect = hasFlag(args, "--detect");
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    std.fs.cwd().makePath(tdir) catch {};
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, "maintain.yaml" });
    defer allocator.free(config_path);
    if (fileExists(config_path) and !force) {
        std.debug.print("config already exists: {s}\nuse --force to overwrite\n", .{config_path});
        std.process.exit(1);
    }
    if (detect) {
        const stacks = try detectProjectStack(allocator, repo);
        defer allocator.free(stacks);
        std.debug.print("detected stacks: ", .{});
        if (stacks.len == 0) {
            std.debug.print("none\n", .{});
        } else {
            for (stacks, 0..) |s, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{s});
            }
            std.debug.print("\n", .{});
        }
        const content = try generateDetectedConfig(allocator, repo);
        defer allocator.free(content);
        try writeFileText(config_path, content);
    } else {
        try writeFileText(config_path, default_maintain_config);
    }
    try printStdout(allocator, "{s}\n", .{config_path});
}

fn cmdMaintainDoctor(allocator: std.mem.Allocator) !void {
    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const config = try loadMaintainConfig(allocator, repo);
    defer allocator.free(config);
    if (config.len == 0) {
        std.debug.print("no tickets/maintain.yaml found. run: mt maintain init-config\n", .{});
        std.process.exit(2);
    }
    const ext_tools = try getEnabledExternalTools(allocator, config);
    defer allocator.free(ext_tools);
    if (ext_tools.len == 0) {
        std.debug.print("no external tools enabled in maintain.yaml\n", .{});
        return;
    }
    var ok_count: usize = 0;
    var fail_count: usize = 0;
    for (ext_tools) |tool| {
        // Extract binary name from command
        var binary_end: usize = 0;
        while (binary_end < tool.command.len and tool.command[binary_end] != ' ') : (binary_end += 1) {}
        const binary = tool.command[0..binary_end];
        // Check if binary exists using which
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "which", binary },
        }) catch {
            try printStdout(allocator, "[MISS]  {s:<20} {s} -- not found on PATH\n", .{ tool.name, binary });
            fail_count += 1;
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited == 0) {
            const found = std.mem.trimRight(u8, result.stdout, "\n\r ");
            try printStdout(allocator, "[OK]    {s:<20} {s} -> {s}\n", .{ tool.name, binary, found });
            ok_count += 1;
        } else {
            try printStdout(allocator, "[MISS]  {s:<20} {s} -- not found on PATH\n", .{ tool.name, binary });
            fail_count += 1;
        }
    }
    std.debug.print("\n{d} tool(s) checked: {d} available, {d} missing\n", .{ ok_count + fail_count, ok_count, fail_count });
    if (fail_count > 0) std.process.exit(1);
}

fn cmdMaintainList(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var cats = std.array_list.Managed([]const u8).init(allocator);
    defer cats.deinit();
    var rule_ids = std.array_list.Managed(i32).init(allocator);
    defer rule_ids.deinit();
    try parseMaintainFilterArgs(args, &cats, &rule_ids);

    const rules = try filterMaintenanceRules(allocator, cats.items, rule_ids.items);
    defer allocator.free(rules);
    if (rules.len == 0) {
        std.debug.print("no rules match the given filters.\n", .{});
        std.process.exit(1);
    }
    for (rules) |rule| {
        const scanner_tag: []const u8 = if (hasBuiltinScanner(rule.id)) "built-in" else "external";
        try printStdout(allocator, "  {d:>3}  [{s:<16}] {s}  ({s})\n", .{ rule.id, rule.category, rule.title, scanner_tag });
        try printStdout(allocator, "        detection: {s}\n", .{rule.detection});
        if (rule.external_tool.len > 0) {
            try printStdout(allocator, "        tool: {s}\n", .{rule.external_tool});
        }
    }
}

fn parseMaintainFilterArgs(args: []const [:0]u8, cats: *std.array_list.Managed([]const u8), rule_ids: *std.array_list.Managed(i32)) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--category") and i + 1 < args.len) {
            i += 1;
            try cats.append(args[i]);
        } else if (std.mem.eql(u8, args[i], "--rule") and i + 1 < args.len) {
            i += 1;
            const rid = std.fmt.parseInt(i32, args[i], 10) catch continue;
            try rule_ids.append(rid);
        }
    }
}

fn cmdMaintainScan(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var cats = std.array_list.Managed([]const u8).init(allocator);
    defer cats.deinit();
    var rule_ids = std.array_list.Managed(i32).init(allocator);
    defer rule_ids.deinit();
    try parseMaintainFilterArgs(args, &cats, &rule_ids);

    const all = hasFlag(args, "--all");
    const diff = hasFlag(args, "--diff");
    const fix = hasFlag(args, "--fix");
    const format = getOptValue(args, "--format") orelse "text";
    const profile = getOptValue(args, "--profile");

    if (profile) |prof| {
        if (std.mem.eql(u8, prof, "ci")) {
            for (&[_][]const u8{ "security", "code-health", "testing" }) |cat| {
                var found = false;
                for (cats.items) |existing| {
                    if (std.mem.eql(u8, existing, cat)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try cats.append(cat);
            }
        } else if (std.mem.eql(u8, prof, "nightly")) {
            for (&maint_categories) |cat| {
                var found = false;
                for (cats.items) |existing| {
                    if (std.mem.eql(u8, existing, cat)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try cats.append(cat);
            }
        } else {
            std.debug.print("unknown profile: {s}\n", .{prof});
            std.process.exit(2);
        }
    }

    if (cats.items.len == 0 and rule_ids.items.len == 0 and !all) {
        std.debug.print("error: --category, --rule, --all, or --profile required for scanning.\nhint: mt maintain list  (to browse rules first)\n", .{});
        std.process.exit(2);
    }

    var scan_cats = cats;
    if (all) {
        scan_cats.clearRetainingCapacity();
        for (&maint_categories) |cat| try scan_cats.append(cat);
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const rules = try filterMaintenanceRules(allocator, scan_cats.items, rule_ids.items);
    defer allocator.free(rules);
    if (rules.len == 0) {
        std.debug.print("no rules match the given filters.\n", .{});
        std.process.exit(1);
    }

    const config = try loadMaintainConfig(allocator, repo);
    defer allocator.free(config);

    var results = std.array_list.Managed(ScanResult).init(allocator);
    defer results.deinit();
    for (rules) |rule| {
        try results.append(try scanRuleWithConfig(allocator, rule, config, repo));
    }

    // --diff (simplified: just show all results, diff logic requires JSON persistence)
    _ = diff;

    // --fix
    if (fix) {
        const ext_tools = try getEnabledExternalTools(allocator, config);
        defer allocator.free(ext_tools);
        for (ext_tools) |tool| {
            // Check if any failed rules match this tool
            for (results.items) |r| {
                if (std.mem.eql(u8, r.status, "fail")) {
                    for (tool.rule_ids) |trid| {
                        if (trid == r.rule_id) {
                            // Would run fix command here
                            std.debug.print("[FIX]  would run fix for tool: {s}\n", .{tool.name});
                            break;
                        }
                    }
                }
            }
        }
    }

    // Output
    if (std.mem.eql(u8, format, "json")) {
        try printStdout(allocator, "[", .{});
        for (results.items, 0..) |r, ri| {
            if (ri > 0) try printStdout(allocator, ",", .{});
            try printStdout(allocator, "\n  {{\"rule_id\": {d}, \"status\": \"{s}\", \"title\": \"{s}\", \"category\": \"{s}\"", .{ r.rule_id, r.status, r.title, r.category });
            if (r.findings.len > 0) {
                try printStdout(allocator, ", \"findings\": [", .{});
                for (r.findings, 0..) |f, fi| {
                    if (fi > 0) try printStdout(allocator, ", ", .{});
                    try printStdout(allocator, "{{\"file\": \"{s}\", \"line\": {d}, \"detail\": \"{s}\"}}", .{ f.file, f.line, f.detail });
                }
                try printStdout(allocator, "]", .{});
            }
            if (r.reason) |reason| {
                try printStdout(allocator, ", \"reason\": \"{s}\"", .{reason});
            }
            try printStdout(allocator, "}}", .{});
        }
        try printStdout(allocator, "\n]\n", .{});
    } else {
        for (results.items) |r| {
            if (std.mem.eql(u8, r.status, "fail")) {
                try printStdout(allocator, "[FAIL]  rule {d:>3}: {s} -- {d} finding(s)\n", .{ r.rule_id, r.title, r.findings.len });
                for (r.findings) |f| {
                    if (f.line > 0) {
                        try printStdout(allocator, "        {s}:{d}: {s}\n", .{ f.file, f.line, f.detail });
                    } else {
                        try printStdout(allocator, "        {s}: {s}\n", .{ f.file, f.detail });
                    }
                }
            } else if (std.mem.eql(u8, r.status, "pass")) {
                try printStdout(allocator, "[PASS]  rule {d:>3}: {s} -- ok\n", .{ r.rule_id, r.title });
            } else {
                try printStdout(allocator, "[SKIP]  rule {d:>3}: {s} -- {s}\n", .{ r.rule_id, r.title, r.reason orelse "no built-in scanner" });
            }
        }
    }

    var fail_count: usize = 0;
    var pass_count: usize = 0;
    var skip_count: usize = 0;
    for (results.items) |r| {
        if (std.mem.eql(u8, r.status, "fail")) fail_count += 1;
        if (std.mem.eql(u8, r.status, "pass")) pass_count += 1;
        if (std.mem.eql(u8, r.status, "skip")) skip_count += 1;
    }
    std.debug.print("\n{d} rule(s) scanned: {d} failed, {d} passed, {d} skipped\n", .{ results.items.len, fail_count, pass_count, skip_count });
    if (fail_count > 0) std.process.exit(1);
}

fn cmdMaintainCreate(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var cats = std.array_list.Managed([]const u8).init(allocator);
    defer cats.deinit();
    var rule_ids = std.array_list.Managed(i32).init(allocator);
    defer rule_ids.deinit();
    try parseMaintainFilterArgs(args, &cats, &rule_ids);

    const all = hasFlag(args, "--all");
    const dry_run = hasFlag(args, "--dry-run");
    const skip_scan = hasFlag(args, "--skip-scan");
    const priority_override = getOptValue(args, "--priority");
    const owner = getOptValue(args, "--owner");

    if (cats.items.len == 0 and rule_ids.items.len == 0 and !all) {
        std.debug.print("error: --category, --rule, or --all required.\nhint: mt maintain scan --category <cat>  (to scan first)\n", .{});
        std.process.exit(2);
    }

    var scan_cats = cats;
    if (all) {
        scan_cats.clearRetainingCapacity();
        for (&maint_categories) |cat| try scan_cats.append(cat);
    }

    const repo = try findRepoRoot(allocator);
    defer allocator.free(repo);
    const tdir = try std.fs.path.join(allocator, &[_][]const u8{ repo, "tickets" });
    defer allocator.free(tdir);
    std.fs.cwd().makePath(tdir) catch {};

    const rules = try filterMaintenanceRules(allocator, scan_cats.items, rule_ids.items);
    defer allocator.free(rules);
    if (rules.len == 0) {
        std.debug.print("no rules match the given filters.\n", .{});
        std.process.exit(1);
    }

    const config = try loadMaintainConfig(allocator, repo);
    defer allocator.free(config);

    // Scan (unless --skip-scan)
    var scan_results = std.AutoHashMap(i32, ScanResult).init(allocator);
    defer scan_results.deinit();
    if (!skip_scan) {
        for (rules) |rule| {
            try scan_results.put(rule.id, try scanRuleWithConfig(allocator, rule, config, repo));
        }
    }

    // Collect existing maint tags
    const existing_tags = try collectExistingMaintTags(allocator, repo);
    defer {
        for (existing_tags) |t| allocator.free(t);
        allocator.free(existing_tags);
    }

    var created: usize = 0;
    var skipped_dedup: usize = 0;
    var skipped_pass: usize = 0;

    for (rules) |rule| {
        const tag = try std.fmt.allocPrint(allocator, "maint-rule-{d}", .{rule.id});
        defer allocator.free(tag);
        if (hasMaintTag(existing_tags, tag)) {
            skipped_dedup += 1;
            continue;
        }

        const scan = scan_results.get(rule.id);
        if (scan) |s| {
            if (std.mem.eql(u8, s.status, "pass")) {
                skipped_pass += 1;
                continue;
            }
        }

        const body = if (scan) |s| blk: {
            if (std.mem.eql(u8, s.status, "fail") and s.findings.len > 0) {
                break :blk try formatFindingBody(allocator, rule, s.findings);
            }
            break :blk try formatSuggestionBody(allocator, rule);
        } else try formatSuggestionBody(allocator, rule);
        defer allocator.free(body);

        if (dry_run) {
            const label: []const u8 = if (scan != null and std.mem.eql(u8, scan.?.status, "fail")) "findings" else "suggestion";
            try printStdout(allocator, "[dry-run] [{s}] [MAINT-{d:0>3}] {s}\n", .{ label, @as(u32, @intCast(rule.id)), rule.title });
            created += 1;
            continue;
        }

        const tid = try nextTicketIdForRepo(allocator, repo);
        defer allocator.free(tid);
        const pri = priority_override orelse rule.default_priority;

        // Build labels string
        var labels_buf = std.array_list.Managed(u8).init(allocator);
        defer labels_buf.deinit();
        try labels_buf.append('[');
        for (rule.labels, 0..) |l, li| {
            if (li > 0) try labels_buf.appendSlice(", ");
            try labels_buf.appendSlice(l);
        }
        if (rule.labels.len > 0) try labels_buf.appendSlice(", ");
        try labels_buf.appendSlice("auto-maintenance]");

        // Build tags string
        const tags_str = try std.fmt.allocPrint(allocator, "[maint-rule-{d}, maint-cat-{s}]", .{ rule.id, rule.category });
        defer allocator.free(tags_str);

        const title = try std.fmt.allocPrint(allocator, "[MAINT-{d:0>3}] {s}", .{ @as(u32, @intCast(rule.id)), rule.title });
        defer allocator.free(title);

        const today = try todayIsoDate(allocator);
        defer allocator.free(today);

        const owner_str: []const u8 = owner orelse "null";

        const text = try std.fmt.allocPrint(allocator,
            \\---
            \\id: {s}
            \\title: {s}
            \\status: ready
            \\priority: {s}
            \\type: {s}
            \\effort: {s}
            \\labels: {s}
            \\tags: {s}
            \\owner: {s}
            \\created: {s}
            \\updated: {s}
            \\depends_on: []
            \\branch: null
            \\retry_count: 0
            \\retry_limit: 3
            \\allocated_to: null
            \\allocated_at: null
            \\lease_expires_at: null
            \\last_error: null
            \\last_attempted_at: null
            \\---
            \\
            \\{s}
        , .{ tid, title, pri, rule.default_type, rule.default_effort, labels_buf.items, tags_str, owner_str, today, today, body });
        defer allocator.free(text);

        const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{tid});
        defer allocator.free(file_name);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ tdir, file_name });
        defer allocator.free(path);
        try writeFileText(path, text);
        try printStdout(allocator, "{s}\n", .{path});
        created += 1;
    }

    const would_be: []const u8 = if (dry_run) "would be " else "";
    std.debug.print("{d} ticket(s) {s}created, {d} skipped (duplicates), {d} skipped (scan passed)\n", .{ created, would_be, skipped_dedup, skipped_pass });
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
        .maintain => try cmdMaintain(allocator, args[2..]),
    }
}
