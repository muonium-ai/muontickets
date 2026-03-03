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
        \\Note: command handlers are scaffolded and will be implemented incrementally.
        \\ 
    , .{});
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
        .init => std.debug.print("TODO: init (zig port)\n", .{}),
        .new => std.debug.print("TODO: new (zig port)\n", .{}),
        .ls => std.debug.print("TODO: ls (zig port)\n", .{}),
        .show => std.debug.print("TODO: show (zig port)\n", .{}),
        .pick => std.debug.print("TODO: pick (zig port)\n", .{}),
        .claim => std.debug.print("TODO: claim (zig port)\n", .{}),
        .comment => std.debug.print("TODO: comment (zig port)\n", .{}),
        .set_status => std.debug.print("TODO: set-status (zig port)\n", .{}),
        .done => std.debug.print("TODO: done (zig port)\n", .{}),
        .archive => std.debug.print("TODO: archive (zig port)\n", .{}),
        .graph => std.debug.print("TODO: graph (zig port)\n", .{}),
        .@"export" => std.debug.print("TODO: export (zig port)\n", .{}),
        .stats => std.debug.print("TODO: stats (zig port)\n", .{}),
        .validate => std.debug.print("TODO: validate (zig port)\n", .{}),
        .report => std.debug.print("TODO: report (zig port)\n", .{}),
    }
}
