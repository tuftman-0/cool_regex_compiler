const std = @import("std");
const ast = @import("regex_ast.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");

const StateId = nfa.StateId;
const RegexNode = ast.RegexNode;

// pub const Edge = struct {
//     from: StateId,
//     to: StateId,
//     pattern: *RegexNode,
// };

// pub const State = struct {
//     trans: std.ArrayList(Transition) = .{},
//     is_accept: bool = false,
// };

pub const GNFA = struct {
    start: StateId,
    accept: StateId,
    n_states: usize,
    labels: []?*RegexNode, // flattened matrix (n*n); null = empty language
    alive: []bool,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        n_states: usize,
    ) !GNFA {
        const labels = try allocator.alloc(?*RegexNode, n_states * n_states);
        for (labels) |*l| l.* = null;
        const alive = try allocator.alloc(bool, n_states);
        for (alive) |*b| b.* = true;

        return GNFA{
            .start = @intCast(n_states - 2),
            .accept = @intCast(n_states - 1),
            .n_states = n_states,
            .labels = labels,
            .alive = alive,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GNFA) void {
        // we're gonna just use an arena I think, possible doublefrees here
        // for (self.labels) |label| {
        //     if (label) |val| val.deinit(self.allocator);
        // }
        self.allocator.free(self.labels);
    }

    pub fn idx(self: *const GNFA, from: StateId, to: StateId) usize {
        return @as(usize, from) * self.n_states + to;
    }

    pub fn get(self: *const GNFA, from: StateId, to: StateId) ?*RegexNode {
        return self.labels[self.idx(from, to)];
    }

    pub fn put(self: *GNFA, from: StateId, to: StateId, r: ?*RegexNode) void {
        self.labels[self.idx(from, to)] = r;
    }

    pub fn addLabel(
        self: *GNFA,
        from: StateId,
        to: StateId,
        label: *RegexNode,
    ) !void {
        const old = self.get(from, to);
        self.put(from, to, try mkUnionOpt(self.allocator, old, label));
    }

    pub fn addChar(self: *GNFA, from: StateId, to: StateId, ch: u8) !void {
        const node = try self.allocator.create(RegexNode);
        node.* = .{ .char = ch };
        try self.addLabel(from, to, node);
    }

    pub fn addEps(self: *GNFA, from: StateId, to: StateId) !void {
        const node = try self.allocator.create(RegexNode);
        node.* = .{ .epsilon = {} };
        try self.addLabel(from, to, node);
    }

    pub fn eliminateState(self: *GNFA, q: StateId) !void {
        const max = self.n_states;
        const rqq = self.get(q,q);
        var star: *RegexNode = undefined;
        if (rqq) |v| {
            star = try ast.mkStar(self.allocator, v);
        } else {
            star = try self.allocator.create(RegexNode);
            star.* = .{ .epsilon = {}};
        }

        for (0..max) |i| {
            const riq = self.get(@intCast(i), q);
            if (i == q or riq == null) continue;
            for (0..max) |j| {
                const rqj = self.get(q,@intCast(j));
                if (j == q or rqj == null) continue;
                const concat1 = try ast.mkConcat(self.allocator, riq.?, star);
                const concat2 = try ast.mkConcat(self.allocator, concat1, rqj.?);
                try self.addLabel(@intCast(i), @intCast(j), concat2);
            }
        }
    }

    pub fn toRegex(self: *GNFA) !*RegexNode {
        const max = self.n_states - 2;
        for (0..max) |q| {
            if (self.alive[q]) {
                try self.eliminateState(@intCast(q));
                self.alive[q] = false;
            }
        }
        return self.get(self.start, self.accept).?;
    }
};

fn mkUnionOpt(allocator: std.mem.Allocator, a: ?*RegexNode, b: ?*RegexNode) !?*RegexNode {
    if (a == null) return b;
    if (b == null) return a;
    return try ast.mkChoice(allocator, a.?, b.?);
}

pub fn DFA_to_GNFA(allocator: std.mem.Allocator, machine: *const dfa.DFA) !GNFA {
    const n_states = machine.accept.len + 2; // extra nodes for start and accept
    var gnfa = try GNFA.init(allocator, n_states);
    try gnfa.addEps(gnfa.start, machine.start);
    for (machine.edges, 0..) |edges, i| {
        if (machine.accept[i]) try gnfa.addEps(@intCast(i), gnfa.accept);
        for (edges.items) |edge| try gnfa.addChar(@intCast(i), edge.to, edge.ch);
    }
    return gnfa;
}

pub fn make9div(a: std.mem.Allocator) !dfa.DFA {
    var machine = try dfa.DFA.init(a, 9, 0);
    machine.accept[0] = true;

    try machine.addEdge(a, 0, '0', 0);
    try machine.addEdge(a, 0, '1', 1);
    try machine.addEdge(a, 0, '2', 2);
    try machine.addEdge(a, 0, '3', 3);
    try machine.addEdge(a, 0, '4', 4);
    try machine.addEdge(a, 0, '5', 5);
    try machine.addEdge(a, 0, '6', 6);
    try machine.addEdge(a, 0, '7', 7);
    try machine.addEdge(a, 0, '8', 8);
    try machine.addEdge(a, 0, '9', 0);

    try machine.addEdge(a, 1, '0', 1);
    try machine.addEdge(a, 1, '1', 2);
    try machine.addEdge(a, 1, '2', 3);
    try machine.addEdge(a, 1, '3', 4);
    try machine.addEdge(a, 1, '4', 5);
    try machine.addEdge(a, 1, '5', 6);
    try machine.addEdge(a, 1, '6', 7);
    try machine.addEdge(a, 1, '7', 8);
    try machine.addEdge(a, 1, '8', 0);
    try machine.addEdge(a, 1, '9', 1);

    try machine.addEdge(a, 2, '0', 2);
    try machine.addEdge(a, 2, '1', 3);
    try machine.addEdge(a, 2, '2', 4);
    try machine.addEdge(a, 2, '3', 5);
    try machine.addEdge(a, 2, '4', 6);
    try machine.addEdge(a, 2, '5', 7);
    try machine.addEdge(a, 2, '6', 8);
    try machine.addEdge(a, 2, '7', 0);
    try machine.addEdge(a, 2, '8', 1);
    try machine.addEdge(a, 2, '9', 2);

    try machine.addEdge(a, 3, '0', 3);
    try machine.addEdge(a, 3, '1', 4);
    try machine.addEdge(a, 3, '2', 5);
    try machine.addEdge(a, 3, '3', 6);
    try machine.addEdge(a, 3, '4', 7);
    try machine.addEdge(a, 3, '5', 8);
    try machine.addEdge(a, 3, '6', 0);
    try machine.addEdge(a, 3, '7', 1);
    try machine.addEdge(a, 3, '8', 2);
    try machine.addEdge(a, 3, '9', 3);

    try machine.addEdge(a, 4, '0', 4);
    try machine.addEdge(a, 4, '1', 5);
    try machine.addEdge(a, 4, '2', 6);
    try machine.addEdge(a, 4, '3', 7);
    try machine.addEdge(a, 4, '4', 8);
    try machine.addEdge(a, 4, '5', 0);
    try machine.addEdge(a, 4, '6', 1);
    try machine.addEdge(a, 4, '7', 2);
    try machine.addEdge(a, 4, '8', 3);
    try machine.addEdge(a, 4, '9', 4);

    try machine.addEdge(a, 5, '0', 5);
    try machine.addEdge(a, 5, '1', 6);
    try machine.addEdge(a, 5, '2', 7);
    try machine.addEdge(a, 5, '3', 8);
    try machine.addEdge(a, 5, '4', 0);
    try machine.addEdge(a, 5, '5', 1);
    try machine.addEdge(a, 5, '6', 2);
    try machine.addEdge(a, 5, '7', 3);
    try machine.addEdge(a, 5, '8', 4);
    try machine.addEdge(a, 5, '9', 5);

    try machine.addEdge(a, 6, '0', 6);
    try machine.addEdge(a, 6, '1', 7);
    try machine.addEdge(a, 6, '2', 8);
    try machine.addEdge(a, 6, '3', 0);
    try machine.addEdge(a, 6, '4', 1);
    try machine.addEdge(a, 6, '5', 2);
    try machine.addEdge(a, 6, '6', 3);
    try machine.addEdge(a, 6, '7', 4);
    try machine.addEdge(a, 6, '8', 5);
    try machine.addEdge(a, 6, '9', 6);

    try machine.addEdge(a, 7, '0', 7);
    try machine.addEdge(a, 7, '1', 8);
    try machine.addEdge(a, 7, '2', 0);
    try machine.addEdge(a, 7, '3', 1);
    try machine.addEdge(a, 7, '4', 2);
    try machine.addEdge(a, 7, '5', 3);
    try machine.addEdge(a, 7, '6', 4);
    try machine.addEdge(a, 7, '7', 5);
    try machine.addEdge(a, 7, '8', 6);
    try machine.addEdge(a, 7, '9', 7);

    try machine.addEdge(a, 8, '0', 8);
    try machine.addEdge(a, 8, '1', 0);
    try machine.addEdge(a, 8, '2', 1);
    try machine.addEdge(a, 8, '3', 2);
    try machine.addEdge(a, 8, '4', 3);
    try machine.addEdge(a, 8, '5', 4);
    try machine.addEdge(a, 8, '6', 5);
    try machine.addEdge(a, 8, '7', 6);
    try machine.addEdge(a, 8, '8', 7);
    try machine.addEdge(a, 8, '9', 8);

    return machine;
}
