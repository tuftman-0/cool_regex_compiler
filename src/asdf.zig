const std = @import("std");
const nfa_mod = @import("nfa.zig");

const NFA = nfa_mod.NFA;
const StateId = nfa_mod.StateId;
const BitSet = std.bit_set.DynamicBitSetUnmanaged;

fn epsilonClosure(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    input: *const BitSet,
    out: *BitSet,
) !void {
    // start with input copied into out
    try out.resize(allocator, nfa.states.items.len);
    out.* = input.*;

    // simple stack for DFS
    var stack = std.ArrayList(StateId).init(allocator);
    defer stack.deinit();

    // seed stack with all states already in the set
    var it = input.iterator(.{});
    while (it.next()) |s| {
        try stack.append(@intCast(s));
    }

    // DFS over ε edges
    while (stack.popOrNull()) |s| {
        for (nfa.states.items[s].eps.items) |t| {
            if (!out.isSet(t)) {
                out.set(t);
                try stack.append(t);
            }
        }
    }
}

const Buckets = struct {
    used: std.ArrayListUnmanaged(u8),
    sets: [256]BitSet, // represents the set of states accessible from sets[u]
};

fn groupByteMoves(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    input: *const BitSet,
    buckets: *Buckets,
) !void {
    for (buckets.used.items) |ch| buckets.sets[ch].resetAll();
    buckets.used.clearRetainingCapacity();

    var it = input.iterator(.{});
    while (it.next()) |sid_usize| {
        const sid: StateId = @intCast(sid_usize);
        const st = &nfa.states.items[sid];

        for (st.trans.items) |tr| {
            if (buckets.sets[tr.ch].count() == 0) {
                try buckets.used.append(allocator, tr.ch);
            }
            buckets.sets[tr.ch].set(tr.to);
        }
    }
}

pub const Edge = struct { ch: u8, to: StateId };

pub const DFA = struct {
    start: StateId,
    accept: []bool,
    edges: []std.ArrayListUnmanaged(Edge), // per state
};

pub fn makeDFA(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    nfa_start: StateId,
) !DFA {
    const N = nfa.states.items.len;
    var input = try BitSet.initEmpty(allocator, N);
    input.set(nfa_start);

    var start_set = try BitSet.initEmpty(allocator, N);
    try epsilonClosure(allocator, nfa, &input, &start_set);

    var tmp_closure = try BitSet.initEmpty(allocator, N);
    var buckets: Buckets = .{
        .used = .{},
        .sets = undefined,
    };

    // pre-size each bucket bitset once
    for (0..256) |i| {
        buckets.sets[i] = try BitSet.initEmpty(allocator, N);
    }



    var work = std.ArrayListUnmanaged(StateId){};
    // var head: usize = 0;

    var dfa_sets = std.ArrayListUnmanaged(BitSet){};
    var start_id: StateId = 0;
    
    try work.append(allocator, start_id);
    var owned = try BitSet.initEmpty(allocator, N);
    owned.* = start_set.*;
    try dfa_sets.append(allocator, owned);

    var seen = std.AutoHashMap([]const u8, StateId).init(allocator);

    while (work.items.len > 0) {
        const S_id = work.pop();
        const S_set = dfa_sets[S_id];
        groupByteMoves(allocator, nfa, S_set, &buckets);
        for (buckets.used) |ch| {
            // const T = buckets[ch];
            tmp_closure.unsetAll();
            epsilonClosure(allocator, nfa, &buckets[ch], &tmp_closure);
            owned.* = &tmp_closure.*;

            if (seen.getOrPutValue(owned, dfa_sets.items.len)) {

            }
        }
    }
}


