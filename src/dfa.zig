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

/// out = ε-closure(input)
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
    const N = nfa.states.items.len;

    // start_set = ε-closure({nfa_start})
    var singleton = try BitSet.initEmpty(allocator, N);
    // defer singleton.deinit(allocator);
    singleton.set(nfa_start);

    var start_set = try BitSet.initEmpty(allocator, N);
    // defer start_set.deinit(allocator);
    try epsilonClosure(allocator, nfa, &singleton, &start_set);

    var tmp_closure = try BitSet.initEmpty(allocator, N);
    // defer tmp_closure.deinit(allocator);

    var buckets: Buckets = .{ .sets = undefined };
    try bucketsInit(allocator, &buckets, N);
    // defer bucketsDeinit(allocator, &buckets);

    // DFA storage
    var dfa_sets = std.ArrayListUnmanaged(BitSet){};
    // defer {
    //     // if we error mid-build, clean up bitsets we own
    //     for (dfa_sets.items) |*s| s.deinit(allocator);
    //     dfa_sets.deinit(allocator);
    // }

    var edges = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Edge)){};
    // defer {
    //     for (edges.items) |*lst| lst.deinit(allocator);
    //     edges.deinit(allocator);
    // }

    var accept = std.ArrayListUnmanaged(bool){};
    // defer accept.deinit(allocator);

    // seen map: encoded set -> dfa_state_id
    var seen = std.StringHashMap(StateId).init(allocator);
    // defer {
    //     // keys were allocated by us; free them
    //     var it = seen.keyIterator();
    //     while (it.next()) |kptr| allocator.free(kptr.*);
    //     seen.deinit();
    // }

    var queue = std.ArrayListUnmanaged(StateId){};
    // defer queue.deinit(allocator);

    // add start DFA state (id 0)
    const start_id: StateId = 0;
    {
        const owned_set = try cloneBitSet(allocator, N, &start_set);
        try dfa_sets.append(allocator, owned_set);

        try edges.append(allocator, .{});
        try accept.append(allocator, isAccepting(nfa, &owned_set));

        const key = try encodeSetKey(allocator, &owned_set);
        try seen.put(key, start_id);

        try queue.append(allocator, start_id);
    }

    // while (queue.items.len > 0) {
    while (queue.pop()) |S_id| {
        // const S_id = queue.pop();
        const S_set = &dfa_sets.items[S_id];

        try groupByteMoves(allocator, nfa, S_set, &buckets);

        for (buckets.used.items) |ch| {
            const move_set = &buckets.sets[ch];
            if (move_set.count() == 0) continue;

            try epsilonClosure(allocator, nfa, move_set, &tmp_closure);

            const key = try encodeSetKey(allocator, &tmp_closure);
            const gop = try seen.getOrPut(key);
            var T_id: StateId = undefined;

            if (!gop.found_existing) {
                // new DFA state
                T_id = @intCast(dfa_sets.items.len);

                const owned = try cloneBitSet(allocator, N, &tmp_closure);
                try dfa_sets.append(allocator, owned);

                try edges.append(allocator, .{});
                try accept.append(allocator, isAccepting(nfa, &owned));

                gop.value_ptr.* = T_id;
                try queue.append(allocator, T_id);
            } else {
                // already seen; free the key we just allocated (since map kept old key)
                allocator.free(key);
                T_id = gop.value_ptr.*;
            }

            try edges.items[S_id].append(allocator, .{ .ch = ch, .to = T_id });
        }
    }

    // finalize into DFA struct (owned slices)
    const accept_slice = try allocator.alloc(bool, accept.items.len);
    @memcpy(accept_slice, accept.items);

    const edges_slice = try allocator.alloc(std.ArrayListUnmanaged(Edge), edges.items.len);
    @memcpy(edges_slice, edges.items);

    // prevent deferred cleanup from double-freeing moved buffers
    edges.items.len = 0;
    accept.items.len = 0;

    // dfa_sets bitsets are no longer needed after transitions built; free them
    // for (dfa_sets.items) |*s| s.deinit(allocator);
    // dfa_sets.deinit(allocator);

    return .{
        .start = start_id,
        .accept = accept_slice,
        .edges = edges_slice,
    };
}


pub fn dumpDFA(dfa_aut: *const DFA) void {
    for (dfa_aut.edges, 0..) |edges, i| {
        std.debug.print("DFA State {d}", .{i});
        if (dfa_aut.accept[i]) std.debug.print(" [accept]", .{});
        std.debug.print("\n", .{});

        for (edges.items) |e| {
            std.debug.print("  '{c}' -> {d}\n", .{ e.ch, e.to });
        }
    }
}



