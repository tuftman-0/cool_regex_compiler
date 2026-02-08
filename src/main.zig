const std = @import("std");
const regexcomp = @import("regexcomp");
const ast = @import("regex_ast.zig");
const nfa = @import("nfa.zig");

pub fn main() !void {
    // 1. Setup the allocator
    const allocator = std.heap.page_allocator;

    const input = "1(3|45)*";

    std.debug.print("Input: {s}\n", .{input});

    const ir = try ast.addConcat(allocator, input);
    defer allocator.free(ir);

    std.debug.print("Processed: {s}\n", .{ir});

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const tree = try ast.buildAST(arena.allocator(), ir);
    tree.print(0);

    var automaton = nfa.NFA{};
    const frag = try nfa.compileNode(arena.allocator(), tree, &automaton);
    automaton.states.items[frag.accept].is_accept = true;
    nfa.dumpNFA(&automaton);
}
