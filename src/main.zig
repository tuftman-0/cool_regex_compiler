const regexcomp = @import("regexcomp");
const std = @import("std");
const ast = @import("regex_ast.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");


pub fn main() !void {
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    // const stdout = &stdout_writer.interface;
    // _ = stdout;

    const allocator = std.heap.page_allocator;

    // const input = "(1|10)(1|10)*";
    // const input = "a*b*a*b*";
    // const input = "11(11)*|111(111)*";
    const input = "(10|01)*";
    // const input = "a+(bab)*(0|11)+|(1|010|~)*11(~|a)";
    // const input = "(a(ab)*b)*";
    // const input = "(ab|ba)*";
    // const input = "(h|e|l|o)*hello";

    std.debug.print("Input: {s}\n", .{input});

    const ir = try ast.addConcat(allocator, input);
    defer allocator.free(ir);

    std.debug.print("Processed: {s}\n", .{ir});

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const tree = try ast.buildAST(arena.allocator(), ir);

    std.debug.print("\nAST\n", .{});
    tree.print(0);


    var automaton = nfa.NFA{};
    const frag = try nfa.compileNode(arena.allocator(), tree, &automaton);
    automaton.states.items[frag.accept].is_accept = true;
    // std.debug.print("\nNFA\n", .{});
    // nfa.dumpNFA(&automaton);


    const sparse_dfa = try dfa.makeDFA(
        allocator,
        &automaton,
        frag.start,
    );
    // defer sparse_dfa.deinit(allocator); // not needed because we use arena

    // std.debug.print("\nsparse DFA\n", .{});
    // dfa.dumpDFA(&sparse_dfa);

    const dense_dfa = try dfa.toDense(arena.allocator(), &sparse_dfa);
    // std.debug.print("\ndense DFA\n", .{});
    // dfa.dumpDense(&dense_dfa);
    try dfa.dumpParker(&dense_dfa);
    const matched = dfa.matches(&dense_dfa, "01010");

    const output: []const u8 = if (matched) "accepted" else "rejected";
    std.debug.print("\n{s} blehg\n" , .{output});

}
