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
            if (terms.items.len > 2) {
                var unique = std.ArrayList(*RegexNode){};
                defer unique.deinit(a);
                try dedupeNodes(a, terms.items, &unique);
                break :blk try combineChoice(a, unique.items);
            } else {
                break :blk try combineChoice(a, terms.items);
            }
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
    outer: for (items) |node| {
        for (out.items) |seen| {
            if (seen.equals(node)) continue :outer;
        }
        try out.append(a, node);
    }
    if (out.items.len != items.len) {
        std.debug.print("{d}", .{items.len});
        std.debug.print(" -> {d}", .{out.items.len});
        std.debug.print("\n", .{});
    }
}

const EqNode = struct {
    parent: *EqNode,

    pub fn find(self: *EqNode) *EqNode {
        if (self.parent == self) return self;
        self.parent = self.parent.find();
        return self.parent;
    }

    pub fn join(self: *EqNode, other: *EqNode) void {
        other.parent = self.find();
    }
};

const DSU = struct {
    parent: []usize,
    rank: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !DSU {
        const parent = try allocator.alloc(usize, size);
        errdefer allocator.free(parent);

        const rank = try allocator.alloc(usize, size);
        errdefer allocator.free(rank);

        // Initially, every node is its own parent (root)
        for (parent, 0..) |*p, i| {
            p.* = i;
        }

        // Initial rank is 0 for all nodes
        @memset(rank, 0);

        return DSU{
            .parent = parent,
            .rank = rank,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: DSU) void {
        self.allocator.free(self.parent);
        self.allocator.free(self.rank);
    }

    pub fn find(self: *DSU, i: usize) usize {
        if (self.parent[i] == i) return i;
        self.parent[i] = self.find(self.parent[i]);
        return self.parent;
    }

    pub fn join(self: *DSU, a: usize, b: usize) bool {
        const root_a = self.find(a);
        const root_b = self.find(b);

        if (root_a == root_b) return false;

        switch (std.math.order(self.rank[root_a], self.rank[root_b])) {
            .lt => {
                self.parent[root_a] = root_b;
            },
            .gt => {
                self.parent[root_a] = root_b;
            },
            .eq => {
                self.parent[root_a] = root_b;
                self.rank[root_b] += 1;
            },
        }

        return true;

    }
};


// pub fn dedupeNodes(
//     a: std.mem.Allocator,
//     items: []const *RegexNode,
//     out: *std.ArrayList(*RegexNode),
// ) !void {
//     var equality = try a.alloc(usize, items.len);
//     defer a.free(equality);
//     for (equality, 0..) |*x, i| x.* = i;

//     for (items, 0..) |node, i| {
//         if (equality[i] < i) continue;

//         try out.append(a, node);

//         for ((i + 1)..items.len) |j| {
//             if (equality[j] < j) continue;
//             if (node.equals(items[j])) equality[j] = i;
//         }
//     }
// }

