const std = @import("std");

const RegexTag = enum {
    char,
    epsilon,
    concat,
    choice,
    star,
};

const RegexNode = union(RegexTag) {
    char: u8,
    epsilon: void,
    concat: struct { left: *RegexNode, right: *RegexNode },
    choice: struct { left: *RegexNode, right: *RegexNode },
    star: *RegexNode,

    pub fn print(self: RegexNode, indent: usize) void {
        // Create a simple indentation string
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            std.debug.print("  ", .{});
        }

        switch (self) {
            .char => |c| std.debug.print("Char: {c}\n", .{c}),
            .epsilon => std.debug.print("Epsilon\n", .{}),
            .star => |child| {
                std.debug.print("Star:\n", .{});
                child.print(indent + 1);
            },
            .concat => |pair| {
                std.debug.print("Concat:\n", .{});
                pair.left.print(indent + 1);
                pair.right.print(indent + 1);
            },
            .choice => |pair| {
                std.debug.print("Choice:\n", .{});
                pair.left.print(indent + 1);
                pair.right.print(indent + 1);
            },
        }
    }
};

fn isEnder(char: u8) bool {
    return switch (char) {
        '|' => false,
        '.' => false,
        '(' => false,
        else => true,
    };
}

fn isStarter(char: u8) bool {
    return switch (char) {
        '*' => false,
        '|' => false,
        '.' => false,
        ')' => false,
        else => true,
    };
}

fn isOperator(char: u8) bool {
    return switch (char) {
        '*' => true,
        '.' => true,
        '|' => true,
        '(' => true,
        ')' => true,
        else => false,
    };
}

fn opPrecedence(op: u8) u8 {
    return switch (op) {
        '*' => 3,
        '.' => 2,
        '|' => 1,
        else => 0, // for '('
    };
}

pub fn addConcat(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var outbuf: []u8 = try allocator.alloc(u8, 2 * input.len);
    var outlen: usize = 0;
    for (input, 1..) |char, i| {
        outbuf[outlen] = char;
        outlen += 1;
        if (i >= input.len) {
            break;
        }
        const next = input[i];
        if (!isEnder(char) or !isStarter(next)) {
            continue;
        }
        outbuf[outlen] = '.';
        outlen += 1;
    }
    return outbuf[0..outlen];
}

fn popAndBuildBinaryNode(
    allocator: std.mem.Allocator,
    op: u8,
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
    const parent = try allocator.create(RegexNode);
    parent.* = switch (op) {
        '.' => .{ .concat = .{ .left = left, .right = right } },
        '|' => .{ .choice = .{ .left = left, .right = right } },
        else => return error.InvalidOperator,
    };

    // 4. Push the result back
    node_stack.*[node_height.*] = parent;
    node_height.* += 1;
}

pub fn shuntingYard(allocator: std.mem.Allocator, tokens: []const u8) !*RegexNode {
    var op_stack: []u8 = try allocator.alloc(u8, tokens.len);
    var op_height: usize = 0;
    var node_stack: []*RegexNode = try allocator.alloc(*RegexNode, tokens.len);
    var node_height: usize = 0;

    for (tokens) |token| {
        switch (token) {
            '(' => {
                op_stack[op_height] = token;
                op_height += 1;
            },
            '*' => {
                const node: *RegexNode = try allocator.create(RegexNode);
                if (node_height <= 0) {
                    //*TODO* add regex syntax error
                }
                node.* = .{ .star = node_stack[node_height - 1] };
                node_stack[node_height-1] = node;
            },
            '.', '|', ')' => {
                while (op_height > 0 and opPrecedence(op_stack[op_height - 1]) >= opPrecedence(token)) {
                    if (node_height <= 1) {
                        //*TODO* add regex syntax error
                    }
                    op_height -= 1;
                    // build node from operator on stack
                    const op = op_stack[op_height];
                    if (op == '(') {
                        break;
                    }
                    try popAndBuildBinaryNode(allocator, op, &node_stack, &node_height);
                } else {
                    op_stack[op_height] = token;
                    op_height += 1;
                }
            },
            else => {
                const node: *RegexNode = try allocator.create(RegexNode);
                node.* = .{ .char = token };
                node_stack[node_height] = node;
                node_height += 1;
            },
        }
    }

    while (op_height > 0) {
        op_height -= 1;
        const op = op_stack[op_height];
        if (op == '(') {
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
