const std = @import("std");
const ast = @import("regex_ast.zig");

const RegexNode = ast.RegexNode;


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
            var terms = std.ArrayList(*RegexNode){};
            defer terms.deinit(a);
            try collectChoice(a, left, &terms);
            try collectChoice(a, right, &terms);
            for (terms.items) |*item| {
                item.* = try simplify(a, item.*);
            }
            var unique = std.ArrayList(*RegexNode){};
            defer unique.deinit(a);
            try dedupeNodes(a, terms.items, &unique);
            break :blk try combineChoice(a, unique.items);
        },
    };
}

fn combineChoice(a: std.mem.Allocator, nodes: [] *RegexNode) !*RegexNode {
    if (nodes.len == 0) unreachable;
    if (nodes.len == 1) return nodes[0];
    var left: *RegexNode = nodes[0];
    for (nodes[1..]) |node| {
        const right = node;
        const parent = try a.create(RegexNode);
        parent.* = .{ .choice = .{ .left = left, .right = right } };
        left = parent;
    }
    return left;
}

pub fn collectChoice(a: std.mem.Allocator, node: *RegexNode, out: *std.ArrayList(*RegexNode)) !void {
    switch (node.*) {
        .choice => |pair| {
            try collectChoice(a, pair.left, out);
            try collectChoice(a, pair.right, out);
        },
        else => try out.append(a, node),
    }
}

pub fn dedupeNodes(
    a: std.mem.Allocator,
    items: []const *RegexNode,
    out: *std.ArrayList(*RegexNode),
) !void {
    var equality = try a.alloc(usize, items.len);
    defer a.free(equality);
    for (equality, 0..) |*x, i| x.* = i;

    for (items, 0..) |node, i| {
        if (equality[i] < i) continue;

        try out.append(a, node);

        for ((i + 1)..items.len) |j| {
            if (equality[j] < j) continue;
            if (node.equals(items[j])) equality[j] = i;
        }
    }
}

