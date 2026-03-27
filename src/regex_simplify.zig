const std = @import("std");
const ast = @import("regex_ast.zig");

const RegexNode = ast.RegexNode


pub fn simplify(a: std.mem.Allocator, node: *RegexNode) !*RegexNode {
    return switch (node.*) {
        .char, .epsilon, .any => node,

        .star => |child| blk: {
            const s = try simplify(a, child);
            break :blk try ast.mkStar(a, s);
        },

        .plus => |child| blk: {
            const s = try simplify(a, child);
            break :blk try ast.mkPlus(a, s);
        },

        .concat => |pair| blk: {
            const left = try simplify(a, pair.left);
            const right = try simplify(a, pair.right);
            break :blk try ast.mkConcat(a, left, right);
        },

        .choice => |pair| blk: {
            const left = try simplify(a, pair.left);
            const right = try simplify(a, pair.right);
            break :blk try ast.mkChoice(a, left, right);
        },
    };
}

pub fn collectChoice(node: *const RegexNode, out: *std.ArrayList(*RegexNode)) !void {
    switch (node.*) {
        .choice => |pair| {
            try collectChoice(pair.left, out);
            try collectChoice(pair.right, out);
        },
        else => try out.append(node),
    }
}

pub fn testCollect()

