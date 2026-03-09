const regexcomp = @import("regexcomp");
const std = @import("std");
const ast = @import("regex_ast.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");
const search = @import("search.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // basic usage check
    if (args.len < 2 or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        return printHelp();
    }

    const pattern = args[1];

    // if no command is provided, default to dump
    const command = if (args.len > 2) args[2] else "dump";

    const slice_args = try allocator.alloc([]u8, args.len);
    defer allocator.free(slice_args);
    for (args, 0..) |arg, i| {
        slice_args[i] = arg;
    }

    if (std.mem.eql(u8, command, "dump")) {
        try handleDump(allocator, pattern, slice_args[3..]);
    } else if (std.mem.eql(u8, command, "match")) {
        try handleMatch(allocator, pattern, slice_args[3..]);
    } else if (std.mem.eql(u8, command, "search") or std.mem.eql(u8, command, "grep")) {
        // try handleSearch();
        try handleSearch(allocator, pattern, slice_args[3..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        return printHelp();
    }
}

fn printHelp() void {
    const help_text =
        \\Usage: lexis <expression> [command] [options]
        \\
        \\Commands:
        \\  match <string>       Check if string matches the regex (default)
        \\  dump [options]       Output internal structures (AST, NFA, DFA)
        \\  search/grep <files>  [Not Implemented] Search files for pattern
        \\
        \\Dump Options:
        \\  -t, --ast            Dump the Abstract Syntax Tree
        \\  -n, --nfa            Dump the NFA
        \\  -d, --dfa            Dump the non-minimal DFA
        \\  -m, --min            Dump the minimal DFA (default)
        \\  -a, --all            Dump everything
        \\  --no-dead           Exclude the dead/sink state from DFA output
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn handleDump(allocator: std.mem.Allocator, pattern: []const u8, options: [][]u8) !void {
    var out_buf: [1 << 16]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;
    var dump_ast = false;
    var dump_nfa = false;
    var dump_dfa = false;
    var dump_min = false;
    var include_dead = true;

    for (options) |opt| {
        if (std.mem.eql(u8, opt, "--ast") or std.mem.eql(u8, opt, "-t")) dump_ast = true;
        if (std.mem.eql(u8, opt, "--nfa") or std.mem.eql(u8, opt, "-n")) dump_nfa = true;
        if (std.mem.eql(u8, opt, "--dfa") or std.mem.eql(u8, opt, "-d")) dump_dfa = true;
        if (std.mem.eql(u8, opt, "--min") or std.mem.eql(u8, opt, "-m")) dump_min = true;
        if (std.mem.eql(u8, opt, "--all") or std.mem.eql(u8, opt, "-a")) {
            dump_ast = true;
            dump_nfa = true;
            dump_dfa = true;
            dump_min = true;
        }
        if (std.mem.eql(u8, opt, "--no-dead")) include_dead = false;
    }
    if (!dump_ast and !dump_nfa and !dump_dfa) dump_min = true;

    const pipeline: usize = if (dump_min) 4 else if (dump_dfa) 3 else if (dump_nfa) 2 else 1;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const tokens = try ast.tokenize(allocator, pattern);
    errdefer allocator.free(tokens);
    const ir = try ast.addConcat(allocator, tokens);
    errdefer allocator.free(ir);
    const tree = try ast.shuntingYard(aa, ir);
    allocator.free(ir);
    allocator.free(tokens);

    // *TODO* maybe pass stdout to printing functions
    if (dump_ast) try tree.print(stdout, 0);

    if (pipeline < 2) {
        try stdout.flush();
        return;
    }
    var autobot = nfa.NFA{};
    const frag = try nfa.compileNode(aa, tree, &autobot);
    autobot.states.items[frag.accept].is_accept = true;
    if (dump_nfa) try nfa.dumpNFA(stdout, &autobot);

    if (pipeline < 3) {
        try stdout.flush();
        return;
    }
    const sparse_dfa = try dfa.makeDFA(aa, &autobot, frag.start);
    const dense_dfa = try dfa.toDense(aa, &sparse_dfa);
    if (dump_dfa) try dfa.dumpParker(stdout, &dense_dfa, include_dead);

    if (pipeline < 4) {
        try stdout.flush();
        return;
    }
    const min_dfa = try dfa.minimize(aa, &dense_dfa);
    if (dump_min) try dfa.dumpParker(stdout, &min_dfa, include_dead);
    try stdout.flush();
}

fn handleMatch(allocator: std.mem.Allocator, pattern: []const u8, remaining: [][]u8) !void {
    if (remaining.len == 0) {
        std.debug.print("Error: 'match' requires a string to test.\nUsage: lexis \"{s}\" match \"target_string\"\n", .{pattern});
        return;
    }
    const target = remaining[0];
    // std.debug.print("Matching \"{s}\" against /{s}/\n", .{target, pattern});

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const tokens = try ast.tokenize(allocator, pattern);
    errdefer allocator.free(tokens);
    const ir = try ast.addConcat(allocator, tokens);
    errdefer allocator.free(ir);
    const tree = try ast.shuntingYard(aa, ir);
    allocator.free(ir);
    allocator.free(tokens);

    // *TODO* maybe pass stdout to printing functions

    var autobot = nfa.NFA{};
    const frag = try nfa.compileNode(aa, tree, &autobot);
    autobot.states.items[frag.accept].is_accept = true;

    const sparse_dfa = try dfa.makeDFA(aa, &autobot, frag.start);
    const dense_dfa = try dfa.toDense(aa, &sparse_dfa);

    const min_dfa = try dfa.minimize(aa, &dense_dfa);

    if (dfa.matches(&min_dfa, target)) {
        std.debug.print("Matches\n", .{});
        std.process.exit(0);
    } else {
        std.debug.print("No Match\n", .{});
        std.process.exit(1);
    }
}

fn handleSearch(allocator: std.mem.Allocator, pattern: []const u8, remaining: [][]u8) !void {
    var out_buf: [1 << 16]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;

    var scratch_build_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer scratch_build_arena.deinit();
    var scratch_minimize_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer scratch_minimize_arena.deinit();
    var final_arena: std.heap.ArenaAllocator = .init(allocator);
    defer final_arena.deinit();
    const scratch_build = scratch_build_arena.allocator();
    const scratch_min = scratch_minimize_arena.allocator();
    const final = final_arena.allocator();

    // detect and trim anchors from pattern
    var anchored_start = false;
    var anchored_end = false;
    var pat = pattern;
    if (pat.len > 0 and pat[0] == '^') {
        anchored_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        anchored_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    // wrap pattern in wildcards depending on anchors
    const key: u2 = (@as(u2, @intFromBool(anchored_start)) << 1) | @as(u2, @intFromBool(anchored_end));
    const wrapped_pattern = switch (key) {
        0b00 => try std.mem.concat(scratch_build, u8, &.{ ".*", pat, ".*" }),
        0b01 => try std.mem.concat(scratch_build, u8, &.{ ".*", pat }),
        0b10 => try std.mem.concat(scratch_build, u8, &.{ pat, ".*" }),
        0b11 => pat,
    };

    const tokens = try ast.tokenize(scratch_build, wrapped_pattern);
    const ir = try ast.addConcat(scratch_build, tokens);
    const tree = try ast.shuntingYard(scratch_build, ir);

    var autobot = nfa.NFA{};
    const frag = try nfa.compileNode(scratch_build, tree, &autobot);
    autobot.states.items[frag.accept].is_accept = true;

    const sparse_dfa = try dfa.makeDFA(scratch_build, &autobot, frag.start);
    const dense_dfa = try dfa.toDense(scratch_min, &sparse_dfa);
    scratch_build_arena.deinit();

    const min_dfa = try dfa.minimize(final, &dense_dfa);
    scratch_minimize_arena.deinit();

    var file: std.fs.File = undefined;
    var reader_buf: [4096]u8 = undefined;
    var file_reader: std.fs.File.Reader = undefined;

    var opts: search.PrintOpts = .{ .label = null, .show_line_numbers = false };

    var rem = remaining;
    var dash_buf: [1]u8 = .{'-'};
    var rem_buf: [1][]u8 = .{dash_buf[0..]};
    if (rem.len == 0) rem = &rem_buf;

    for (rem) |arg| {
        if (arg.len == 1 and arg[0] == '-') {
            file = std.fs.File.stdin();
            file_reader = file.readerStreaming(&reader_buf);
            if (rem.len > 1) opts.label = "(standard input)";
        } else {
            file = try std.fs.cwd().openFile(arg, .{});
            file_reader = file.reader(&reader_buf);
            if (rem.len > 1) opts.label = arg;
        }
        const reader = &file_reader.interface;
        try search.searchFile(allocator, stdout, reader, &min_dfa, opts);
    }

    try stdout.flush();
}
