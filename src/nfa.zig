const std = @import("std");
const ast = @import("regex_ast.zig");

pub const StateId = u32; // indices for states in NFA and DFA (determines max number of states)

pub const Transition = union(enum) {
    ch: struct { ch: u8, to: StateId },
    any: struct { to: StateId }, // means any char except '\n'
};

pub const State = struct {
    eps: std.ArrayList(StateId) = .{},
    trans: std.ArrayList(Transition) = .{},
    is_accept: bool = false,
};

pub const NFA = struct {
    states: std.ArrayList(State) = .{},

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
        try self.states.items[from].trans.append(a, .{ .ch = .{ .ch = ch, .to = to } });
    }

    pub fn addAny(self: *NFA, a: std.mem.Allocator, from: StateId, to: StateId) !void {
        try self.states.items[from].trans.append(a, .{ .any = .{ .to = to } });
    }

    fn wireStar(self: *NFA, allocator: std.mem.Allocator, child_frag: Frag) !Frag {
        const start = try self.newState(allocator);
        const accept = try self.newState(allocator);

        try self.addEps(allocator, start, accept);
        try self.addEps(allocator, start, child_frag.start);
        try self.addEps(allocator, child_frag.accept, child_frag.start);
        try self.addEps(allocator, child_frag.accept, accept);

        return .{ .start = start, .accept = accept };
    }

    pub fn compileRegexNode(self: *NFA, allocator: std.mem.Allocator, node: *const ast.RegexNode) !Frag {
        return switch (node.*) {
            .epsilon => {
                const start = try self.newState(allocator);
                const accept = try self.newState(allocator);
                try self.addEps(allocator, start, accept);
                return .{ .start = start, .accept = accept };
            },
            .char => |c| {
                const start = try self.newState(allocator);
                const accept = try self.newState(allocator);
                try self.addChar(allocator, start, c, accept);
                return .{ .start = start, .accept = accept };
            },
            .any => {
                const start = try self.newState(allocator);
                const accept = try self.newState(allocator);
                try self.addAny(allocator, start, accept);
                return .{ .start = start, .accept = accept };
            },
            .concat => |pair| {
                const left_frag = try self.compileRegexNode(allocator, pair.left);
                const right_frag = try self.compileRegexNode(allocator, pair.right);
                try self.addEps(allocator, left_frag.accept, right_frag.start);
                return .{ .start = left_frag.start, .accept = right_frag.accept };
            },
            .choice => |pair| {
                const start = try self.newState(allocator);
                const accept = try self.newState(allocator);
                const left_frag = try self.compileRegexNode(allocator, pair.left);
                const right_frag = try self.compileRegexNode(allocator, pair.right);
                try self.addEps(allocator, start, left_frag.start);
                try self.addEps(allocator, start, right_frag.start);
                try self.addEps(allocator, right_frag.accept, accept);
                try self.addEps(allocator, left_frag.accept, accept);
                return .{ .start = start, .accept = accept };
            },
            .star => |child| {
                const child_frag = try self.compileRegexNode(allocator, child);
                return try self.wireStar(allocator, child_frag);
            },
            .plus => |child| {
                const first_frag = try self.compileRegexNode(allocator, child); 
                const star_child_frag = try self.compileRegexNode(allocator, child);
                const star_frag = try self.wireStar(allocator, star_child_frag);

                try self.addEps(allocator, first_frag.accept, star_frag.start);

                return .{ .start = first_frag.start, .accept = star_frag.accept };
            },
        };
    }
};

pub fn dumpNFA(stdout: *std.Io.Writer, nfa: *NFA) !void {
    for (nfa.states.items, 0..) |state, i| {
        try stdout.print("State {d}", .{i});
        if (state.is_accept) try stdout.print(" [accept]", .{});
        try stdout.print("\n", .{});

        for (state.eps.items) |to| {
            try stdout.print("  ε -> {d}\n", .{to});
        }

        for (state.trans.items) |t| switch (t) {
            .ch => |x| try stdout.print("  '{c}' -> {d}\n", .{ x.ch, x.to }),
            .any => |x| try stdout.print("  ANY -> {d}\n", .{ x.to }),
        };
    }
}

pub const Frag = struct {
    start: StateId,
    accept: StateId,
};

// **TODO** make this an NFA method
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
        .any => {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            try nfa.addAny(allocator, start, accept);
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
        .star => |child| {
            const start = try nfa.newState(allocator);
            const accept = try nfa.newState(allocator);
            const child_nfa = try compileNode(allocator, child, nfa);
            try nfa.addEps(allocator, start, accept);
            try nfa.addEps(allocator, start, child_nfa.start);
            try nfa.addEps(allocator, child_nfa.accept, child_nfa.start);
            try nfa.addEps(allocator, child_nfa.accept, accept);
            return .{ .start = start, .accept = accept };
        },
        .plus => |child| {
            const first = try compileNode(allocator, child, nfa);

            const loop_start = try nfa.newState(allocator);
            const loop_accept = try nfa.newState(allocator);

            const repeated = try compileNode(allocator, child, nfa);

            try nfa.addEps(allocator, first.accept, loop_start);
            try nfa.addEps(allocator, loop_start, repeated.start);
            try nfa.addEps(allocator, repeated.accept, repeated.start);
            try nfa.addEps(allocator, repeated.accept, loop_accept);
            try nfa.addEps(allocator, loop_start, loop_accept);

            return .{ .start = first.start, .accept = loop_accept };
        },
    };
}
