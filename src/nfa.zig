const std = @import("std");
const ast = @import("regex_ast.zig");

pub const StateId = u16; // or u32

pub const Transition = struct {
    ch: u8,
    to: StateId,
};

pub const State = struct {
    eps: std.ArrayListUnmanaged(StateId) = .{},
    trans: std.ArrayListUnmanaged(Transition) = .{},
    is_accept: bool = false,
};

pub const NFA = struct {
    states: std.ArrayListUnmanaged(State) = .{},

    pub fn deinit(self: *NFA, a: std.mem.Allocator) void {
        for (self.states.items) |*s| {
            s.eps.deinit(a);
            s.trans.deinit(a);
        }
        self.states.deinit(a);
    }

    pub fn newState(self: *NFA, a: std.mem.Allocator) !StateId {
        try self.states.append(a, .{});
        return @intCast(self.states.items.len - 1);
    }

    pub fn addEps(self: *NFA, a: std.mem.Allocator, from: StateId, to: StateId) !void {
        try self.states.items[from].eps.append(a, to);
    }

    pub fn addChar(self: *NFA, a: std.mem.Allocator, from: StateId, ch: u8, to: StateId) !void {
        try self.states.items[from].trans.append(a, .{ .ch = ch, .to = to });
    }


};

pub fn dumpNFA(nfa: *NFA) void {
    for (nfa.states.items, 0..) |state, i| {
        std.debug.print("State {d}", .{i});
        if (state.is_accept) std.debug.print(" [accept]", .{});
        std.debug.print("\n", .{});

        for (state.eps.items) |to| {
            std.debug.print("  ε -> {d}\n", .{to});
        }

        for (state.trans.items) |t| {
            std.debug.print("  '{c}' -> {d}\n", .{t.ch, t.to});
        }
    }
}

pub const Frag = struct {
    start: StateId,
    accept: StateId,
};

pub fn compileNode(allocator: std.mem.Allocator, node: *const ast.RegexNode, nfa: *NFA) !Frag {
    return switch (node.*) {
        .epsilon => {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            try nfa.addEps(allocator, start, accept);
            return .{ .start = start, .accept = accept };
        },
        .char => |c| {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            try nfa.addChar(allocator, start, c, accept);
            return .{ .start = start, .accept = accept };
        },
        .concat => |pair| {
            const left_frag = try compileNode(allocator, pair.left, nfa);
            const right_frag = try compileNode(allocator, pair.right, nfa);
            try nfa.addEps(allocator, left_frag.accept, right_frag.start);
            return .{ .start = left_frag.start, .accept = right_frag.accept };
        },
        .choice => |pair| {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            const left_frag = try compileNode(allocator, pair.left, nfa);
            const right_frag = try compileNode(allocator, pair.right, nfa);
            try nfa.addEps(allocator, start, left_frag.start);
            try nfa.addEps(allocator, start, right_frag.start);
            try nfa.addEps(allocator, right_frag.accept, accept);
            try nfa.addEps(allocator, left_frag.accept, accept);
            return .{ .start = start, .accept = accept };
        },
        .star => |child_node| {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            const child_ast = try compileNode(allocator, child_node, nfa);
            try nfa.addEps(allocator, start, accept);
            try nfa.addEps(allocator, start, child_ast.start);
            try nfa.addEps(allocator, child_ast.accept, child_ast.start);
            try nfa.addEps(allocator, child_ast.accept, accept);
            return .{ .start = start, .accept = accept };
        },
    };
}
