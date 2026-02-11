const std = @import("std");
const nfa_mod = @import("nfa.zig");

const NFA = nfa_mod.NFA;
const StateId = nfa_mod.StateId;
const BitSet = std.bit_set.DynamicBitSetUnmanaged;

pub const Edge = struct { ch: u8, to: StateId };

pub const DFA = struct {
    start: StateId,
    accept: []bool,
    edges: []std.ArrayListUnmanaged(Edge), // per DFA state

    pub fn deinit(self: *DFA, a: std.mem.Allocator) void {
        for (self.edges) |*lst| lst.deinit(a);
        a.free(self.edges);
        a.free(self.accept);
    }
};

fn bitsetClearAndCopy(out: *BitSet, src: *const BitSet) void {
    out.unsetAll();
    var it = src.iterator(.{});
    while (it.next()) |idx| out.set(idx);
}

/// out = epsilon-closure(input)
fn epsilonClosure(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    input: *const BitSet,
    out: *BitSet,
) !void {
    try out.resize(allocator, nfa.states.items.len, false);
    out.unsetAll();

    // seed out with input (no shallow copies!)
    var it0 = input.iterator(.{});
    while (it0.next()) |s_usize| out.set(s_usize);

    var stack: std.ArrayList(StateId) = .empty;
    // defer stack.deinit(allocator);

    // push initial states
    var it1 = input.iterator(.{});
    while (it1.next()) |s_usize| {
        try stack.append(allocator, @intCast(s_usize));
    }

    while (stack.pop()) |s| {
        for (nfa.states.items[s].eps.items) |t| {
            if (!out.isSet(t)) {
                out.set(t);
                try stack.append(allocator, t);
            }
        }
    }
}

const Buckets = struct {
    used: std.ArrayListUnmanaged(u8) = .{},
    sets: [256]BitSet, // sets[ch] = NFA states reachable by 'ch' from input-set
};

fn bucketsInit(allocator: std.mem.Allocator, buckets: *Buckets, n_bits: usize) !void {
    for (0..256) |i| {
        buckets.sets[i] = try BitSet.initEmpty(allocator, n_bits);
    }
}

fn bucketsDeinit(allocator: std.mem.Allocator, buckets: *Buckets) void {
    buckets.used.deinit(allocator);
    for (0..256) |i| buckets.sets[i].deinit(allocator);
}

fn groupByteMoves(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    input: *const BitSet,
    buckets: *Buckets,
) !void {
    // clear previously used buckets
    for (buckets.used.items) |ch| buckets.sets[ch].unsetAll();
    buckets.used.clearRetainingCapacity();

    var it = input.iterator(.{});
    while (it.next()) |sid_usize| {
        const sid: StateId = @intCast(sid_usize);
        const st = &nfa.states.items[sid];

        for (st.trans.items) |tr| {
            // first time this ch appears for this input set?
            if (buckets.sets[tr.ch].count() == 0) {
                try buckets.used.append(allocator, tr.ch);
            }
            buckets.sets[tr.ch].set(tr.to);
        }
    }
}

/// Encode a set as bytes: [u16 idx0][u16 idx1]...[u16 idxk] (little-endian).
/// Key memory must outlive the hashmap, so we allocate it and store it as the key.
fn encodeSetKey(allocator: std.mem.Allocator, set: *const BitSet) ![]u8 {
    // Count bits first so we can allocate exactly.
    const k = set.count();
    const bytes = try allocator.alloc(u8, k * 2);

    var i: usize = 0;
    var it = set.iterator(.{});
    while (it.next()) |idx_usize| {
        const idx: u16 = @intCast(idx_usize);
        bytes[i + 0] = @truncate(idx);
        bytes[i + 1] = @truncate(idx >> 8);
        i += 2;
    }
    return bytes;
}

fn isAccepting(nfa: *const NFA, set: *const BitSet) bool {
    var it = set.iterator(.{});
    while (it.next()) |sid_usize| {
        const sid: StateId = @intCast(sid_usize);
        if (nfa.states.items[sid].is_accept) return true;
    }
    return false;
}

fn cloneBitSet(allocator: std.mem.Allocator, n_bits: usize, src: *const BitSet) !BitSet {
    var dst = try BitSet.initEmpty(allocator, n_bits);
    // copy via iterator so we don't rely on internal layout
    var it = src.iterator(.{});
    while (it.next()) |idx| dst.set(idx);
    return dst;
}


pub fn makeDFA(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    nfa_start: StateId,
) !DFA {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();
    const N = nfa.states.items.len;

    // start_set = epsilon-closure({nfa_start})
    var singleton = try BitSet.initEmpty(scratch_allocator, N);
    singleton.set(nfa_start);

    var start_set = try BitSet.initEmpty(scratch_allocator, N);
    try epsilonClosure(scratch_allocator, nfa, &singleton, &start_set);

    var tmp_closure = try BitSet.initEmpty(scratch_allocator, N);

    var buckets: Buckets = .{ .sets = undefined };
    try bucketsInit(scratch_allocator, &buckets, N);

    // DFA storage
    var dfa_sets = std.ArrayListUnmanaged(BitSet){};

    var edges = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Edge)){};

    var accept = std.ArrayListUnmanaged(bool){};

    // seen map: encoded set -> dfa_state_id
    var seen = std.StringHashMap(StateId).init(scratch_allocator);

    var queue = std.ArrayListUnmanaged(StateId){};

    // add start DFA state (id 0)
    const start_id: StateId = 0;
    {
        const owned_set = try cloneBitSet(scratch_allocator, N, &start_set);
        try dfa_sets.append(scratch_allocator, owned_set);

        try edges.append(scratch_allocator, .{});
        // try edges.append(allocator, .{});
        try accept.append(scratch_allocator, isAccepting(nfa, &owned_set));
        // try accept.append(allocator, isAccepting(nfa, &owned_set));

        const key = try encodeSetKey(scratch_allocator, &owned_set);
        try seen.put(key, start_id);
        try queue.append(scratch_allocator, start_id);
    }

    while (queue.pop()) |S_id| {
        const S_set = &dfa_sets.items[S_id];

        try groupByteMoves(scratch_allocator, nfa, S_set, &buckets);

        for (buckets.used.items) |ch| {
            const move_set = &buckets.sets[ch];
            if (move_set.count() == 0) continue;

            try epsilonClosure(scratch_allocator, nfa, move_set, &tmp_closure);

            const key = try encodeSetKey(scratch_allocator, &tmp_closure);
            const gop = try seen.getOrPut(key);
            var T_id: StateId = undefined;

            if (!gop.found_existing) {
                // new DFA state
                T_id = @intCast(dfa_sets.items.len);

                const owned = try cloneBitSet(scratch_allocator, N, &tmp_closure);
                try dfa_sets.append(scratch_allocator, owned);

                try edges.append(scratch_allocator, .{});
                // try edges.append(allocator, .{});
                try accept.append(scratch_allocator, isAccepting(nfa, &owned));
                // try accept.append(allocator, isAccepting(nfa, &owned));

                gop.value_ptr.* = T_id;
                try queue.append(scratch_allocator, T_id);
            } else {
                // already seen; free the key we just allocated (since map kept old key)
                T_id = gop.value_ptr.*;
            }

            // try edges.items[S_id].append(scratch_allocator, .{ .ch = ch, .to = T_id });
            try edges.items[S_id].append(allocator, .{ .ch = ch, .to = T_id });
        }
    }

    // finalize into DFA struct (owned slices)
    const accept_slice = try allocator.alloc(bool, accept.items.len);
    @memcpy(accept_slice, accept.items);

    const edges_slice = try allocator.alloc(std.ArrayListUnmanaged(Edge), edges.items.len);
    @memcpy(edges_slice, edges.items);

    return .{
        .start = start_id,
        .accept = accept_slice,
        .edges = edges_slice,
        // .accept = accept.items,
        // .edges = edges.items,
    };
}


pub fn dumpDFA(dfa: *const DFA) void {
    for (dfa.edges, 0..) |edges, i| {
        std.debug.print("DFA State {d}", .{i});
        if (dfa.accept[i]) std.debug.print(" [accept]", .{});
        std.debug.print("\n", .{});

        for (edges.items) |e| {
            std.debug.print("  '{c}' -> {d}\n", .{ e.ch, e.to });
        }
    }
}


pub const DenseDFA = struct {
    start: StateId,
    accept: []bool,  // len = num_states (including dead)
    next: []StateId, // len = num_states * 256

    // if you use an arena for this, you can skip deinit entirely
    pub fn deinit(self: *DenseDFA, a: std.mem.Allocator) void {
        a.free(self.next);
        a.free(self.accept);
    }
};

pub fn toDense(
    allocator: std.mem.Allocator,
    sparse: *const DFA,
) !DenseDFA {
    const n_states: usize = sparse.edges.len;
    const dead: StateId = @intCast(n_states);
    const total_states: usize = n_states + 1;
    std.debug.assert(total_states < std.math.maxInt(StateId));

    const accept = try allocator.alloc(bool, total_states);
    @memcpy(accept[0..n_states], sparse.accept);
    accept[dead] = false;

    const next = try allocator.alloc(StateId, total_states * 256);
    for (next) |*p| p.* = dead;

    for (sparse.edges, 0..) |lst, s_usize| {
        const state: StateId = @intCast(s_usize);
        for (lst.items) |edge| {
            next[@as(usize, state) * 256 + edge.ch] = edge.to;
        }
    }

    // dead state loops to itself on all bytes
    for (0..256) |ch| {
        next[@as(usize, dead) * 256 + ch] = dead;
    }

    return .{
        .start = sparse.start,
        .accept = accept,
        .next = next,
    };
}


pub fn dumpDense(dfa: *const DenseDFA) void {
    const n = dfa.accept.len;
    for (0..n) |s| {
        std.debug.print("State {d}", .{s});
        if (dfa.accept[s]) std.debug.print(" [accept]", .{});
        std.debug.print("\n", .{});

        for (0..256) |ch_usize| {
            const ch: u8 = @intCast(ch_usize);
            const to = dfa.next[s * 256 + ch_usize];
            if (to != n - 1) { // if not dead (optional filter)
                std.debug.print("  '{c}' -> {d}\n", .{ ch, to });
            }
        }
    }
}


pub fn dumpParker(dfa: *const DenseDFA) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    const n = dfa.accept.len;
    const dead = n - 1;


    try stdout.print("type = DFA\n", .{});
    // print states
    try stdout.print("Q = {{", .{});
    for (0..dead) |s| {
        try stdout.print("q{d}, ", .{s});
    }
    try stdout.print("dead}}\n", .{});

    // get used characters
    var used: [256]bool = [_]bool{false} ** 256;
    for (0..dead) |s| {
        for (0..256) |ch| {
            const to = dfa.next[s * 256 + ch];
            if (to != dead) {
                used[ch] = true;
            }
        }

    }

    // print alphabet
    try stdout.print("E = {{", .{});
    for (0..256) |ch_usize| {
    const ch: u8 = @intCast(ch_usize);
    if (used[ch_usize]) try stdout.print("{c}, ", .{ch});
    }
    try stdout.print("}}\n", .{});

    //print final states
    try stdout.print("F = {{", .{});
    for (0..dead) |s| {
        if (dfa.accept[s]) try stdout.print("q{d}, ", .{s});
    }
    try stdout.print("}}\n", .{});

    // print initial state
    try stdout.print("q0 = q0\n", .{});

    // print transition functions
    for (0..n) |s| {

        try stdout.print("\n// State {d}", .{s});
        if (dfa.accept[s]) try stdout.print(" [accept]", .{});
        try stdout.print("\n", .{});

        for (0..256) |ch_usize| {
            const ch: u8 = @intCast(ch_usize);
            const to = dfa.next[s * 256 + ch_usize];
            if (to != dead) {
                try stdout.print("d(q{d}, {c}) = q{d}\n", .{s, ch, to});
            } else if (used[ch] == true) {
                if (s != dead) {
                    try stdout.print("d(q{d}, {c}) = dead\n", .{s, ch});
                } else {
                    try stdout.print("d(dead, {c}) = dead\n", .{ch});
                }
            }
        }
    }
    try stdout.flush();
}

pub fn matches(dfa: *const DenseDFA, input: []const u8) bool {
    var state: StateId = dfa.start;
    for (input) |ch| {
        state = dfa.next[@as(usize, state) * 256 + ch];
    }
    return dfa.accept[@as(usize, state)];
}

