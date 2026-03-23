const std = @import("std");

pub const Token = union(enum) {
    literal: u8,
    epsilon: void,  // empty string
    any: void,      // The '.' wildcard (any character in alphabet)
    star: void,     // '*'
    plus: void,     // '+'
    choice: void,   // '|'
    concat: void,   // '.'
    lparen: void,   // '('
    rparen: void,   // ')'
    // eof: void,

    pub fn isEnder(self: Token) bool {
        return switch (self) {
            .choice => false,
            .concat => false,
            .lparen => false,
            else => true,
        };
    }

    pub fn isStarter(self: Token) bool {
        return switch (self) {
            .star => false,
            .plus => false,
            .choice => false,
            .concat => false,
            .rparen => false,
            else => true,
        };
    }

    pub fn isOperator(self: Token) bool {
        return switch (self) {
            .literal => false,
            .any => false,
            .epsilon => false,
            else => true,
        };
    }

    pub fn precedence(self: Token) u8 {
        return switch (self) {
            .star, .plus => 3,
            .concat  => 2,
            .choice => 1,
            else  => 0, // for '('
        };
    }
};

pub fn tokenize(allocator: std.mem.Allocator, pattern: []const u8) ![]Token {
    var tokens = try std.ArrayList(Token).initCapacity(allocator, pattern.len);
    errdefer tokens.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        const tok: Token = switch (ch) {
            '*' => .{ .star = {} },
            '+' => .{ .plus = {} },
            '|' => .{ .choice = {} },
            '(' => .{ .lparen = {} },
            ')' => .{ .rparen = {} },
            '.' => .{ .any = {} }, // wildcard token
            '~' => .{ .epsilon = {} }, // empty string
            '\\' => blk: {
                if (i + 1 >= pattern.len) return error.TrailingEscape;
                i += 1; // consume escaped char
                break :blk .{ .literal = pattern[i] };
            },
            else => .{ .literal = ch },
        };
        try tokens.append(allocator, tok);
    }
    return try tokens.toOwnedSlice(allocator);
}



pub fn addConcat(allocator: std.mem.Allocator, input: []Token) ![]Token {
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 2*input.len);
    errdefer tokens.deinit(allocator);
    for (input, 1..) |token, i| {
        try tokens.append(allocator, token);
        if (i >= input.len) break;
        const next_token = input[i];
        if (!token.isEnder() or !next_token.isStarter()) continue;
        try tokens.append(allocator, .{.concat={}});
    }
    return try tokens.toOwnedSlice(allocator);
}



pub const RegexTag = enum {
    epsilon,
    char,
    any,
    concat,
    choice,
    star,
    plus,
};

pub const RegexNode = union(RegexTag) {
    epsilon: void,
    char: u8,
    any: void,
    concat: struct { left: *RegexNode, right: *RegexNode },
    choice: struct { left: *RegexNode, right: *RegexNode },
    star: *RegexNode,
    plus: *RegexNode,

    pub fn print(self: RegexNode, stdout: *std.Io.Writer, indent: usize) !void {
        // var out_buf: [1 << 16]u8 = undefined;
        // var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        // const stdout = &stdout_writer.interface;
        // Create a simple indentation string
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try stdout.print("  ", .{});
        }

        switch (self) {
            .char => |c| try stdout.print("Char: {c}\n", .{c}),
            .epsilon => try stdout.print("Epsilon\n", .{}),
            .star => |child| {
                try stdout.print("Star:\n", .{});
                try child.print(stdout, indent + 1);
            },
            .plus => |child| {
                try stdout.print("Plus:\n", .{});
                try child.print(stdout, indent + 1);
            },
            .concat => |pair| {
                try stdout.print("Concat:\n", .{});
                try pair.left.print(stdout, indent + 1);
                try pair.right.print(stdout, indent + 1);
            },
            .choice => |pair| {
                try stdout.print("Choice:\n", .{});
                try pair.left.print(stdout, indent + 1);
                try pair.right.print(stdout, indent + 1);
            },
            .any => try stdout.print("Any\n", .{}),
        }
    }

    pub fn clone(self: *const RegexNode, allocator: std.mem.Allocator) !*RegexNode {
        const out = try allocator.create(RegexNode);
        out.* = switch (self.*) {
            .char    => |c| .{ .char = c },
            .epsilon => .{ .epsilon = {} },
            .any     => .{ .any = {} },
            .star    => |child| .{ .star = try child.clone(allocator) },
            .plus    => |child| .{ .plus = try child.clone(allocator) },
            .concat  => |p| .{ .concat = .{
                .left = try p.left.clone(allocator),
                .right = try p.right.clone(allocator),
            }},
            .choice  => |p| .{ .choice = .{
                .left = try p.left.clone(allocator),
                .right = try p.right.clone(allocator),
            }},
        };
        return out;
    }

    pub fn equals(self: *const RegexNode, other: *const RegexNode) bool {
        return switch (self.*) {
            .epsilon => switch (other.*) {
                .epsilon => true,
                else => false,
            },
            .any => switch (other.*) {
                .any => true,
                else => false,
            },
            .char => |char1| switch (other.*) {
                .char => |char2| char1 == char2,
                else => false,
            },
            .star => |child1| switch (other.*) {
                .star => |child2| child1.equals(child2),
                else => false,
            },
            .plus => |child1| switch (other.*) {
                .star => |child2| child1.equals(child2),
                else => false,
            },
            .concat => |p1| switch (other.*) {
                .concat => |p2| p1.left.equals(p2.left) and p1.right.equals(p2.right),
                else => false,
            },
            .choice => |p1| switch (other.*) {
                .concat => |p2| (p1.left.equals(p2.left) and p1.right.equals(p2.right)) or
                                (p1.left.equals(p2.right) and p1.right.equals(p2.left)),
                else => false,
            },
        };
    }

    pub fn deinit(self: *RegexNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .char, .epsilon, .any => {},
            .star => |child| {
                child.deinit(allocator);
            },
            .concat => |pair| {
                pair.left.deinit(allocator);
                pair.right.deinit(allocator);
            },
            .choice => |pair| {
                pair.left.deinit(allocator);
                pair.right.deinit(allocator);
            },
        }
        allocator.destroy(self);
    }
};



fn mkConcat(allocator: std.mem.Allocator, left: *RegexNode, right: *RegexNode) !*RegexNode {
    // simplify concatenations with epsilon
    if (left.* == .epsilon) return right;
    if (right.* == .epsilon) return left;
    const parent = try allocator.create(RegexNode);
    parent.* = .{ .concat = .{ .left = left, .right = right } };
    return parent;
}

fn mkChoice(allocator: std.mem.Allocator, left: *RegexNode, right: *RegexNode) !*RegexNode {
    // if (left.*. == right.*) return left; // shallow equality to detect simple stuff
    if (left.equals(right)) return left; // can do full equality but it's expensive
    const parent = try allocator.create(RegexNode);
    parent.* = .{ .choice = .{ .left = left, .right = right } };
    return parent;
}

fn mkStar(allocator: std.mem.Allocator, child: *RegexNode) !*RegexNode {
    return switch (child.*) {
        // if child is a* a+ or epsilon adding a star won't change anything
        .star, .plus, .epsilon => child,
        else => blk: {
            const node = try allocator.create(RegexNode);
            node.* = .{ .star = child };
            break :blk node;
        },
    };
}

fn mkPlus(allocator: std.mem.Allocator, child: *RegexNode) !*RegexNode {
    return switch (child.*) {
        // if child is a* a+ or epsilon adding a plus won't change anything
        .star, .plus, .epsilon => child,
        else => blk: {
            const node = try allocator.create(RegexNode);
            node.* = .{ .plus = child };
            break :blk node;
        },
    };
}

fn popAndBuildBinaryNode(
    allocator: std.mem.Allocator,
    op: Token,
    node_stack: *[]*RegexNode,
    node_height: *usize,
) !void {
    // 1. Ensure we have enough operands
    if (node_height.* < 2) return error.SyntaxError;

    // 2. Pop in correct LIFO order
    const right = node_stack.*[node_height.* - 1];
    const left = node_stack.*[node_height.* - 2];
    node_height.* -= 2;

    // 3. Allocate and link
    const parent: *RegexNode = switch (op) {
        .concat => try mkConcat(allocator, left, right),
        .choice => try mkChoice(allocator, left, right),
        else => return error.InvalidOperator,
    };

    // 4. Push the result back
    node_stack.*[node_height.*] = parent;
    node_height.* += 1;
}


pub fn shuntingYard(allocator: std.mem.Allocator, tokens: []Token) !*RegexNode {
    if (tokens.len == 0) {
        const node = try allocator.create(RegexNode);
        node.* = .{ .epsilon = {} };
        return node;
    }
    var op_stack: []Token = try allocator.alloc(Token, tokens.len);
    defer allocator.free(op_stack);
    var op_height: usize = 0;
    var node_stack: []*RegexNode = try allocator.alloc(*RegexNode, tokens.len);
    defer allocator.free(node_stack);
    var node_height: usize = 0;

    for (tokens) |token| {
        switch (token) {
            .lparen => {
                op_stack[op_height] = token;
                op_height += 1;
            },
            .star => {
                if (node_height <= 0) { return error.SyntaxError; }
                node_stack[node_height - 1] = try mkStar(allocator, node_stack[node_height - 1]);
            },
            .plus => {
                if (node_height <= 0) { return error.SyntaxError; }
                node_stack[node_height - 1] = try mkPlus(allocator, node_stack[node_height - 1]);
            },
            .concat, .choice, .rparen => {
                while (op_height > 0 and op_stack[op_height - 1].precedence() >= token.precedence()) {
                    op_height -= 1;
                    // build node from operator on stack
                    const op = op_stack[op_height];
                    if (op == .lparen) break;
                    try popAndBuildBinaryNode(allocator, op, &node_stack, &node_height);
                } else {
                    op_stack[op_height] = token;
                    op_height += 1;
                }
            },
            .epsilon => {
                const node: *RegexNode = try allocator.create(RegexNode);
                node.* = .{ .epsilon = {} };
                node_stack[node_height] = node;
                node_height += 1;
            },
            .any => {
                const node: *RegexNode = try allocator.create(RegexNode);
                node.* = .{ .any = {} };
                node_stack[node_height] = node;
                node_height += 1;
            },
            .literal => |c| {
                const node: *RegexNode = try allocator.create(RegexNode);
                node.* = .{ .char = c };
                node_stack[node_height] = node;
                node_height += 1;
            },
        }
    }

    while (op_height > 0) {
        op_height -= 1;
        const op = op_stack[op_height];
        if (op == .lparen) {
            @panic("unmatched parenthesis");
        }

        try popAndBuildBinaryNode(allocator, op, &node_stack, &node_height);
    }
    return node_stack[0];
}


pub fn buildAST(allocator: std.mem.Allocator, input: []const u8) !*RegexNode {
    const ir = try addConcat(allocator, input);
    defer allocator.free(ir);
    return try shuntingYard(allocator, ir);
}
