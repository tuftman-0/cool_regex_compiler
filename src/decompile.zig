const std = @import("std");
const ast = @import("regex_ast.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");

const StateId = nfa.StateId;
const RegexNode = ast.RegexNode;

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

        if (n_states > std.math.maxInt(StateId)) return error.TooManyStates;

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
        self.allocator.free(self.alive);
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
