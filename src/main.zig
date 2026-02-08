const std = @import("std");
const regexcomp = @import("regexcomp");
const ast = @import("regex_ast.zig");

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
}



// M = (Q, Sigma, delta, q0, F)



// const State = struct {
//     // The character to match (if any)
//     // You could use 0 or a special value for 'no character'
//     char: ?u8 = null,

//     // Pointers to the next states reachable via epsilon transitions
//     out1: ?*State = null,
//     out2: ?*State = null,

//     // A way to identify the state (helpful for debugging)
//     id: usize,
// };

// const Frag = struct {
//     start: *State,
//     // The 'dangling' pointers that need to be connected to the next state
//     end: std.ArrayList(*?*State),
// };

// fn toNFA(allocator: std.mem.Allocator, AST: *const RegexNode, id: *u32) !Frag {
//     switch (AST) {
//         .epsilon => {
//             var s = try allocator.create(State);
            
//         },
//         .char => |c| {
//             var s = try allocator.create(State);
//             s.* = .{ .char = c, .id = id.* };
//             id.* += 1;

//             var out_ptrs = std.ArrayList(*?*State).init(allocator);
//             // We store the address of s.out1 because that's what we'll fill later
//             try out_ptrs.append(&s.out1);

//             return Frag{ .start = s, .out_ptrs = out_ptrs };
//         },
//         .star => |child_ast| {
//             const child_frag = try toNFA(allocator, child_ast, id);
            
//             var s = try allocator.create(State);
//             s.* = .{ .id = id.*, .out1 = child_frag.start };
//             id.* += 1;

//             // Point all the child's ends back to our new junction 's'
//             for (child_frag.out_ptrs.items) |ptr| {
//                 ptr.* = s;
//             }

//             var out_ptrs = std.ArrayList(*?*State).init(allocator);
//             // The only way 'out' of the star now is through the second choice of our junction
//             try out_ptrs.append(&s.out2);

//             return Frag{ .start = s, .out_ptrs = out_ptrs };
//         },
//     }
// }
