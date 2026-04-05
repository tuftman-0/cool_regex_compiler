const std = @import("std");
const nfa_mod = @import("nfa.zig");

const NFA = nfa_mod.NFA;
const StateId = nfa_mod.StateId;
const BitSet = std.bit_set.DynamicBitSetUnmanaged;

pub const Edge = struct { ch: u8, to: StateId };

pub const DFA = struct {
    start: StateId,
    accept: []bool,
    edges: []std.ArrayList(Edge), // per DFA state

    pub fn deinit(self: *DFA, a: std.mem.Allocator) void {
        for (self.edges) |*lst| lst.deinit(a);
        a.free(self.edges);
        a.free(self.accept);
    }

 pub fn init(a: std.mem.Allocator, n_states: usize, start: StateId) !DFA {
        const accept = try a.alloc(bool, n_states);
        errdefer a.free(accept);

        const edges = try a.alloc(std.ArrayList(Edge), n_states);
        errdefer a.free(edges);

        for (accept) |*b| b.* = false;
        for (edges) |*lst| lst.* = .{};

        return .{
            .start = start,
            .accept = accept,
            .edges = edges,
        };
    }

    pub fn addEdge(self: *DFA, a: std.mem.Allocator, from: StateId, ch: u8, to: StateId) !void {
        try self.edges[from].append(a, .{ .ch = ch, .to = to });
    }

    pub fn dumpAsZigBuilder(
        machine: *const DFA,
        writer: *std.Io.Writer,
        fn_name: []const u8,
    ) !void {
        try writer.print("pub fn {s}(a: std.mem.Allocator) !DFA {{\n", .{fn_name});
        try writer.print("    var dfa = try DFA.init(a, {d}, {d});\n", .{
            machine.accept.len,
            machine.start,
        });

        for (machine.accept, 0..) |is_accept, i| {
            if (is_accept) {
                try writer.print("    dfa.accept[{d}] = true;\n", .{i});
            }
        }

        for (machine.edges, 0..) |edges, from| {
            for (edges.items) |edge| {
                try writer.print(
                    "    try dfa.addEdge(a, {d}, {d}, {d});\n",
                    .{ from, edge.ch, edge.to },
                );
            }
        }

        try writer.print("    return dfa;\n", .{});
        try writer.print("}}\n", .{});
    }
};


fn dumpByteLiteral(writer: *std.Io.Writer, ch: u8) !void {
    switch (ch) {
        '\n' => try writer.print("'\\n'", .{}),
        '\r' => try writer.print("'\\r'", .{}),
        '\t' => try writer.print("'\\t'", .{}),
        '\\' => try writer.print("'\\\\'", .{}),
        '\'' => try writer.print("'\\''", .{}),
        32...126 => try writer.print("'{c}'", .{ch}),
        else => try writer.print("{d}", .{ch}),
    }
}

pub fn dumpAsZigBuilderPretty(
    machine: *const DFA,
    writer: *std.Io.Writer,
    fn_name: []const u8,
) !void {
    try writer.print("pub fn {s}(a: std.mem.Allocator) !DFA {{\n", .{fn_name});
    try writer.print("    var dfa = try DFA.init(a, {d}, {d});\n", .{
        machine.accept.len,
        machine.start,
    });

    for (machine.accept, 0..) |is_accept, i| {
        if (is_accept) {
            try writer.print("    dfa.accept[{d}] = true;\n", .{i});
        }
    }

    for (machine.edges, 0..) |edges, from| {
        for (edges.items) |edge| {
            try writer.print("    try dfa.addEdge(a, {d}, ", .{from});
            try dumpByteLiteral(writer, edge.ch);
            try writer.print(", {d});\n", .{edge.to});
        }
    }

    try writer.print("    return dfa;\n", .{});
    try writer.print("}}\n", .{});
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

    // seed out with input (no shallow copies)
    var it0 = input.iterator(.{});
    while (it0.next()) |s_usize| out.set(s_usize);

    var stack: std.ArrayList(StateId) = .empty;
    defer stack.deinit(allocator);

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
    used: std.ArrayList(u8) = .{},
    sets: [256]BitSet, // sets[ch] = NFA states reachable by 'ch' from input-set

    fn init(self: *Buckets, allocator: std.mem.Allocator, n_bits: usize) !void {
        for (0..256) |i| {
            self.sets[i] = try BitSet.initEmpty(allocator, n_bits);
        }
    }

    fn deinit(self: *Buckets, allocator: std.mem.Allocator) void {
        self.used.deinit(allocator);
        for (0..256) |i| self.sets[i].deinit(allocator);
    }
};

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

        for (st.trans.items) |tr| switch (tr) {
            .ch => |x| {
                if (buckets.sets[x.ch].count() == 0) try buckets.used.append(allocator, x.ch);
                buckets.sets[x.ch].set(x.to);
            },
            .any => |x| {
                for (0..256) |cu| {
                    const c: u8 = @intCast(cu);
                    // might limit characters
                    // if (c != '\n') continue;
                    // switch (c) { // remove control characters (good for dumping reasonably) (might add flag to control)
                    //     0x00...0x1F, 0x7F...0xFF => continue,
                    //     else => {},
                    // }

                    if (buckets.sets[c].count() == 0) try buckets.used.append(allocator, c);
                    buckets.sets[c].set(x.to);
                }
            },
        };
    }
}

/// Encode a set as bytes: [u16 idx0][u16 idx1]...[u16 idxk] (little-endian)
/// Key memory must outlive the hashmap, so we allocate it and store it as the key
fn encodeSetKey(allocator: std.mem.Allocator, set: *const BitSet) ![]u8 {
    // Count bits first so we can allocate exactly
    const k = set.count();
    const bytes = try allocator.alloc(u8, k * 2);

    var i: usize = 0;
    var it = set.iterator(.{});
    while (it.next()) |idx_usize| {
        const idx: StateId = @intCast(idx_usize);
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

pub fn makeDFAWithScratch(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    nfa: *const NFA,
    nfa_start: StateId,
) !DFA {
    const N = nfa.states.items.len;

    // start_set = epsilon-closure({nfa_start})
    var singleton = try BitSet.initEmpty(scratch_allocator, N);
    defer singleton.deinit(scratch_allocator);
    singleton.set(nfa_start);

    var start_set = try BitSet.initEmpty(scratch_allocator, N);
    defer start_set.deinit(scratch_allocator);
    try epsilonClosure(scratch_allocator, nfa, &singleton, &start_set);

    var tmp_closure = try BitSet.initEmpty(scratch_allocator, N);
    defer tmp_closure.deinit(scratch_allocator);

    var buckets: Buckets = .{ .sets = undefined };
    try buckets.init(scratch_allocator, N);
    defer buckets.deinit(scratch_allocator);

    // DFA storage
    var dfa_sets = std.ArrayList(BitSet){};
    defer {
        for (dfa_sets.items) |*set| set.deinit(scratch_allocator);
        dfa_sets.deinit(scratch_allocator);
    }

    var edges = std.ArrayList(std.ArrayList(Edge)){};
    defer edges.deinit(scratch_allocator);

    var accept = std.ArrayList(bool){};
    defer accept.deinit(scratch_allocator);

    // seen map: encoded set -> dfa_state_id
    var seen = std.StringHashMap(StateId).init(scratch_allocator);
    defer seen.deinit();

    var queue = std.ArrayList(StateId){};
    defer queue.deinit(scratch_allocator);

    // add start DFA state (id 0)
    const start_id: StateId = 0;
    {
        const owned_set = try cloneBitSet(scratch_allocator, N, &start_set);
        try dfa_sets.append(scratch_allocator, owned_set);

        try edges.append(scratch_allocator, .{});
        try accept.append(scratch_allocator, isAccepting(nfa, &owned_set));

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
                T_id = @intCast(dfa_sets.items.len);

                const owned = try cloneBitSet(scratch_allocator, N, &tmp_closure);
                try dfa_sets.append(scratch_allocator, owned);

                try edges.append(scratch_allocator, .{});
                try accept.append(scratch_allocator, isAccepting(nfa, &owned));

                gop.value_ptr.* = T_id;
                try queue.append(scratch_allocator, T_id);
            } else {
                T_id = gop.value_ptr.*;
            }

            try edges.items[S_id].append(allocator, .{ .ch = ch, .to = T_id });
        }
    }

    const accept_slice = try allocator.alloc(bool, accept.items.len);
    @memcpy(accept_slice, accept.items);

    const edges_slice = try allocator.alloc(std.ArrayList(Edge), edges.items.len);
    @memcpy(edges_slice, edges.items);

    return .{
        .start = start_id,
        .accept = accept_slice,
        .edges = edges_slice,
    };
}

pub fn makeDFA(
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    nfa_start: StateId,
) !DFA {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    return try makeDFAWithScratch(allocator, scratch_arena.allocator(), nfa, nfa_start);
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
    accept: []bool, // len = num_states (including dead)
    next: []StateId, // len = num_states * 256
    dead: StateId,

    pub fn deinit(self: *const DenseDFA, a: std.mem.Allocator) void {
        a.free(self.next);
        a.free(self.accept);
    }

    pub fn nextState(self: *const DenseDFA, state: StateId, transition: usize) StateId {
        return self.next[@as(usize, state) * 256 + transition];

    }


    pub fn matches(self: *const DenseDFA, input: []const u8) bool {
        var state: StateId = self.start;
        for (input) |ch| {
            state = self.next[@as(usize, state) * 256 + ch];
            // short circuit on dead (might need to change this if arbitrary machine input is allowed or enforce a dead state that goes nowhere)
            if (state == self.dead) return false;
        }
        return self.accept[@as(usize, state)];
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
        .dead = dead,
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

fn computeReachable(allocator: std.mem.Allocator, d: *const DenseDFA) ![]bool {
    const n = d.accept.len;
    const reachable = try allocator.alloc(bool, n);
    @memset(reachable, false);

    var q = std.ArrayList(StateId){};
    defer q.deinit(allocator);

    reachable[@as(usize, d.start)] = true;
    try q.append(allocator, d.start);

    while (q.pop()) |s| {
        const base = @as(usize, s) * 256;
        for (0..256) |ch| {
            const t = d.next[base + ch];
            const tu = @as(usize, t);
            if (!reachable[tu]) {
                reachable[tu] = true;
                try q.append(allocator, t);
            }
        }
    }

    return reachable;
}

fn computeReachableWithUsed(
    allocator: std.mem.Allocator,
    d: *const DenseDFA,
    used: *const [256]bool,
) ![]bool {
    const n = d.accept.len;
    const reachable = try allocator.alloc(bool, n);
    @memset(reachable, false);

    var q = std.ArrayList(StateId){};
    defer q.deinit(allocator);

    reachable[@as(usize, d.start)] = true;
    try q.append(allocator, d.start);

    while (q.pop()) |s| {
        const base = @as(usize, s) * 256;
        for (0..256) |ch| {
            if (!used[ch]) continue;
            const t = d.next[base + ch];
            const tu = @as(usize, t);
            if (!reachable[tu]) {
                reachable[tu] = true;
                try q.append(allocator, t);
            }
        }
    }
    return reachable;
}

fn printState(stdout: anytype, s: usize, dead: usize, show_dead: bool) !void {
    if (show_dead and s == dead) {
        try stdout.print("dead", .{});
    } else {
        try stdout.print("q{d}", .{s});
    }
}

fn printByte(stdout: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        0x00...0x1F, 0x7F...0xFF => try stdout.print("0x{X}", .{byte}),
        else => try stdout.print("{c}", .{byte}),
    }
}

pub fn dumpParker(stdout: *std.Io.Writer, dfa: *const DenseDFA, show_dead: bool) !void {
    const n = dfa.accept.len;
    const dead: usize = @as(usize, dfa.dead);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var used: [256]bool = [_]bool{false} ** 256;
    for (0..n) |s| {
        if (s == dead) continue;
        for (0..256) |ch| {
            const to = dfa.next[s * 256 + ch];
            if (to != dead) used[ch] = true;
        }
    }
    const reachable = try computeReachableWithUsed(a, dfa, &used);
    const dead_reachable = reachable[dead];

    try stdout.print("type = DFA\n", .{});

    try stdout.print("Q = {{", .{});
    for (0..n) |s| {
        if (!reachable[s]) continue;
        if (!show_dead and dead_reachable and s == dead) continue;
        try printState(stdout, s, dead, show_dead and dead_reachable);
        try stdout.print(", ", .{});
    }
    try stdout.print("}}\n", .{});

    try stdout.print("E = {{", .{});
    for (0..256) |ch_usize| {
        if (used[ch_usize]) {
            try printByte(stdout, @intCast(ch_usize));
            try stdout.print(", ", .{});
        }
    }
    try stdout.print("}}\n", .{});

    try stdout.print("F = {{", .{});
    for (0..n) |s| {
        if (!reachable[s]) continue;
        if (dfa.accept[s]) {
            // if accept+dead ever happens, that's bad, but print name anyway lol
            try printState(stdout, s, dead, show_dead and dead_reachable);
            try stdout.print(", ", .{});
        }
    }
    try stdout.print("}}\n", .{});

    // Initial
    try stdout.print("q0 = ", .{});
    try printState(stdout, @as(usize, dfa.start), dead, show_dead and dead_reachable);
    try stdout.print("\n", .{});

    // Transitions (reachable only)
    for (0..n) |s| {
        if (!reachable[s]) continue;
        if (!show_dead and dead_reachable and s == dead) continue;

        try stdout.print("\n// State ", .{});
        try printState(stdout, s, dead, show_dead and dead_reachable);
        if (dfa.accept[s]) try stdout.print(" [accept]", .{});
        if (dfa.start == s) try stdout.print(" [start]", .{});
        try stdout.print("\n", .{});

        for (0..256) |ch_usize| {
            if (!used[ch_usize]) continue;
            const to = dfa.next[s * 256 + ch_usize];
            const tu = @as(usize, to);

            if (dead_reachable and tu == dead) {
                if (show_dead) {
                    try stdout.print("d(", .{});
                    try printState(stdout, s, dead, true);
                    // try stdout.print(", {c}) = dead\n", .{@as(u8, @intCast(ch_usize))});
                    try stdout.print(", ", .{});
                    try printByte(stdout, @intCast(ch_usize));
                    try stdout.print(") = dead\n", .{});
                }
            } else {
                try stdout.print("d(", .{});
                try printState(stdout, s, dead, show_dead and dead_reachable);
                // try stdout.print(", {c}) = ", .{@as(u8, @intCast(ch_usize))});
                try stdout.print(", ", .{});
                try printByte(stdout, @intCast(ch_usize));
                try stdout.print(") = ", .{});
                try printState(stdout, tu, dead, show_dead and dead_reachable);
                try stdout.print("\n", .{});
            }
        }
    }

    try stdout.flush();
}

pub fn matches(dfa: *const DenseDFA, input: []const u8) bool {
    var state: StateId = dfa.start;
    for (input) |ch| {
        state = dfa.next[@as(usize, state) * 256 + ch];
        // short circuit on dead (might need to change this if arbitrary machine input is allowed or enforce a dead state that goes nowhere)
        if (state == dfa.dead) return false;
    }
    return dfa.accept[@as(usize, state)];
}

fn pairIndex(i: usize, j: usize) usize {
    std.debug.assert(i < j);
    return (j * (j - 1)) / 2 + i;
}

const Range = struct {
    start: usize,
    end: usize,
}; // end exclusive

const Epoch = u32; // number of splits must be less than max number in Epoch

fn partition(
    block_states: []StateId,
    pos: []usize,
    r: Range,
    mark_state: []const Epoch,
    epoch: Epoch,
) usize {
    var mid: usize = r.start;
    var i: usize = r.start;
    while (i < r.end) : (i += 1) {
        const s = block_states[i];
        if (mark_state[@as(usize, s)] == epoch) {
            if (i != mid) {
                const a = block_states[i];
                const b = block_states[mid];

                block_states[i] = b;
                block_states[mid] = a;

                pos[@as(usize, a)] = mid;
                pos[@as(usize, b)] = i;
            }
            mid += 1;
        }
    }
    return mid;
}

fn pushWork(
    allocator: std.mem.Allocator,
    work: *std.ArrayList(usize),
    in_work: []bool,
    b: usize,
) !void {
    if (!in_work[b]) {
        try work.append(allocator, b);
        in_work[b] = true;
    }
}

/// Split block Y into two blocks using mid (where [start..mid) are marked)
/// Returns the new block id Z if a split happened, otherwise returns null
///
/// Requires these per-block parallel arrays (all length == block_ranges.items.len):
/// - in_work
/// - hit_count (can be reused per-iteration)
fn splitBlockFromMid(
    allocator: std.mem.Allocator,
    Y: usize,
    mid: usize,
    block_ranges: *std.ArrayList(Range),
    block_states: []const StateId,
    block_of: []usize,
    work: *std.ArrayList(usize),
    in_work: []bool,
    hit_count: []usize,
    mark_block: ?[]u32,
) !?usize {
    const r = block_ranges.items[Y];
    const l = r.start;
    const r_end = r.end;

    // sizes
    const left_len = mid - l;
    const right_len = r_end - mid;

    // no split
    if (left_len == 0 or right_len == 0) {
        hit_count[Y] = 0; // cleanup for this round
        return null;
    }

    // Create new block id
    const Z: usize = block_ranges.items.len;
    try block_ranges.append(allocator, .{ .start = 0, .end = 0 });

    // Decide which side stays as Y:
    // keep the larger part as Y, move smaller to new Z
    const keep_left = left_len >= right_len;

    var kept: Range = undefined;
    var moved: Range = undefined;

    if (keep_left) {
        kept = .{ .start = l, .end = mid };
        moved = .{ .start = mid, .end = r_end };
    } else {
        kept = .{ .start = mid, .end = r_end };
        moved = .{ .start = l, .end = mid };
    }

    // Update ranges
    block_ranges.items[Y] = kept;
    block_ranges.items[Z] = moved;

    // Update block_of for moved states
    for (moved.start..moved.end) |idx| {
        const s = block_states[idx];
        block_of[@as(usize, s)] = Z;
    }
    // kept states remain in Y, so no need to rewrite them if block_of already Y

    // Worklist update (Hopcroft rule)
    // If Y was in work, push Z as well. Otherwise push the smaller block
    // NOTE: in_work tracks membership in the worklist
    if (in_work[Y]) {
        try pushWork(allocator, work, in_work, Z);
    } else {
        // push the smaller part
        const smaller = if ((kept.end - kept.start) < (moved.end - moved.start)) Y else Z;
        try pushWork(allocator, work, in_work, smaller);
    }

    // per-round cleanup/init
    hit_count[Y] = 0;
    // hit_count[Z] should start at 0 too
    if (mark_block) |mb| {
        mb[Z] = 0;
    }
    // in_work[Z] initialized false unless pushed above

    return Z;
}

// *TODO* switch to using a scratch arena for stuff used during construction
// *TODO* make bookkeeping struct to manage all the stuff going on here
pub fn minimizeWithScratch(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    dfa: *const DenseDFA,
) !DenseDFA {
    const n: usize = dfa.accept.len;
    std.debug.assert(n > 0);
    const dead = dfa.dead;

    var used: [256]bool = [_]bool{false} ** 256;
    var count: usize = 0;
    var char_buffer: [256]u8 = undefined;

    for (0..@as(usize, dead)) |s| {
        const row = s * 256;
        for (0..256) |ch_usize| {
            const to: StateId = dfa.next[row + ch_usize];
            if (to != dead and !used[ch_usize]) {
                used[ch_usize] = true;
                char_buffer[count] = @intCast(ch_usize);
                count += 1;
            }
        }
    }
    const chars: []const u8 = char_buffer[0..count];

    var pred: []std.ArrayList(StateId) = try scratch.alloc(std.ArrayList(StateId), chars.len * n);
    defer scratch.free(pred);
    for (pred) |*lst| lst.* = .{};
    defer for (pred) |*lst| lst.deinit(scratch);

    for (chars, 0..) |ch, ci| {
        const ch_usize: usize = @as(usize, ch);
        for (0..n) |s_usize| {
            const t: StateId = dfa.next[s_usize * 256 + ch_usize];
            try pred[ci * n + @as(usize, t)].append(scratch, @intCast(s_usize));
        }
    }

    var block_states = try scratch.alloc(StateId, n);
    defer scratch.free(block_states);
    var pos = try scratch.alloc(usize, n);
    defer scratch.free(pos);
    var block_of = try scratch.alloc(usize, n);
    defer scratch.free(block_of);

    for (0..n) |i| block_states[i] = @intCast(i);

    var k: usize = 0;
    for (0..n) |idx| {
        const s = block_states[idx];
        if (dfa.accept[@as(usize, s)]) {
            const t = block_states[k];
            block_states[k] = s;
            block_states[idx] = t;
            k += 1;
        }
    }

    for (0..n) |i| {
        const s = block_states[i];
        pos[@as(usize, s)] = i;
    }

    var block_ranges = std.ArrayList(Range){};
    defer block_ranges.deinit(scratch);
    var in_work = std.ArrayList(bool){};
    defer in_work.deinit(scratch);
    var hit_count = std.ArrayList(usize){};
    defer hit_count.deinit(scratch);
    var mark_block = std.ArrayList(Epoch){};
    defer mark_block.deinit(scratch);

    const AppendBlock = struct {
        fn add(
            a: std.mem.Allocator,
            br: *std.ArrayList(Range),
            iw: *std.ArrayList(bool),
            hc: *std.ArrayList(usize),
            mb: *std.ArrayList(Epoch),
            r: Range,
        ) !usize {
            const id: usize = br.items.len;
            try br.append(a, r);
            try iw.append(a, false);
            try hc.append(a, 0);
            try mb.append(a, 0);
            return id;
        }
    };

    if (k > 0) _ = try AppendBlock.add(scratch, &block_ranges, &in_work, &hit_count, &mark_block, .{ .start = 0, .end = k });
    if (k < n) _ = try AppendBlock.add(scratch, &block_ranges, &in_work, &hit_count, &mark_block, .{ .start = k, .end = n });

    for (block_ranges.items, 0..) |r, bid| {
        for (r.start..r.end) |idx| {
            const s = block_states[idx];
            block_of[@as(usize, s)] = bid;
        }
    }

    var work = std.ArrayList(usize){};
    defer work.deinit(scratch);
    if (block_ranges.items.len == 1) {
        try pushWork(scratch, &work, in_work.items, 0);
    } else {
        const s0 = block_ranges.items[0].end - block_ranges.items[0].start;
        const s1 = block_ranges.items[1].end - block_ranges.items[1].start;
        const first: usize = if (s0 <= s1) 0 else 1;
        try pushWork(scratch, &work, in_work.items, first);
    }

    var mark_state = try scratch.alloc(Epoch, n);
    defer scratch.free(mark_state);
    @memset(mark_state, 0);
    var epoch_state: Epoch = 1;
    var epoch_block: Epoch = 1;

    var touched_blocks = std.ArrayList(usize){};
    defer touched_blocks.deinit(scratch);

    while (work.pop()) |A| {
        in_work.items[A] = false;

        const rA = block_ranges.items[A];

        for (chars, 0..) |_, ci| {
            epoch_state += 1;
            epoch_block += 1;
            touched_blocks.clearRetainingCapacity();

            for (rA.start..rA.end) |idx| {
                const t: StateId = block_states[idx];
                const lst = &pred[ci * n + @as(usize, t)];

                for (lst.items) |s| {
                    const su: usize = @as(usize, s);
                    if (mark_state[su] == epoch_state) continue;
                    mark_state[su] = epoch_state;

                    const b: usize = block_of[su];
                    if (mark_block.items[b] != epoch_block) {
                        mark_block.items[b] = epoch_block;
                        hit_count.items[b] = 0;
                        try touched_blocks.append(scratch, b);
                    }
                    hit_count.items[b] += 1;
                }
            }

            for (touched_blocks.items) |Y| {
                const rY = block_ranges.items[Y];
                const y_len = rY.end - rY.start;
                const hy = hit_count.items[Y];

                if (hy == 0 or hy == y_len) {
                    hit_count.items[Y] = 0;
                    continue;
                }

                const mid = partition(block_states, pos, rY, mark_state, epoch_state);

                const left_len = mid - rY.start;
                const right_len = rY.end - mid;
                if (left_len == 0 or right_len == 0) {
                    hit_count.items[Y] = 0;
                    continue;
                }

                const keep_left = left_len >= right_len;
                const kept: Range = if (keep_left) .{ .start = rY.start, .end = mid } else .{ .start = mid, .end = rY.end };
                const moved: Range = if (keep_left) .{ .start = mid, .end = rY.end } else .{ .start = rY.start, .end = mid };

                const Z = try AppendBlock.add(scratch, &block_ranges, &in_work, &hit_count, &mark_block, moved);

                block_ranges.items[Y] = kept;

                for (moved.start..moved.end) |idx| {
                    const s = block_states[idx];
                    block_of[@as(usize, s)] = Z;
                }

                if (in_work.items[Y]) {
                    try pushWork(scratch, &work, in_work.items, Z);
                } else {
                    const smaller = if ((kept.end - kept.start) < (moved.end - moved.start)) Y else Z;
                    try pushWork(scratch, &work, in_work.items, smaller);
                }

                hit_count.items[Y] = 0;
            }
        }
    }

    const m: usize = block_ranges.items.len;
    std.debug.assert(m > 0);

    const new_start: StateId = @intCast(block_of[@as(usize, dfa.start)]);
    const new_dead: usize = block_of[@as(usize, dead)];

    var out_accept = try allocator.alloc(bool, m);
    var out_next = try allocator.alloc(StateId, m * 256);

    for (0..m) |b| {
        const r = block_ranges.items[b];
        const rep: StateId = block_states[r.start];
        out_accept[b] = dfa.accept[@as(usize, rep)];
    }

    for (0..m) |b| {
        const r = block_ranges.items[b];
        const rep: StateId = block_states[r.start];
        const rep_u: usize = @as(usize, rep);

        for (0..256) |ch| {
            const t: StateId = dfa.next[rep_u * 256 + ch];
            const tb: usize = block_of[@as(usize, t)];
            out_next[b * 256 + ch] = @intCast(tb);
        }
    }

    return .{
        .start = new_start,
        .accept = out_accept,
        .next = out_next,
        .dead = @intCast(new_dead),
    };
}

pub fn minimize(
    allocator: std.mem.Allocator,
    dfa: *const DenseDFA,
) !DenseDFA {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    return try minimizeWithScratch(allocator, scratch_arena.allocator(), dfa);
}



// *TODO* write canonicalize

/// takes two minimized DFAs and checks if they're isomorphic/equivalent
pub fn equals(allocator: std.mem.Allocator, a: *const DenseDFA, b: *const DenseDFA) bool {
    if (a.accept.len != b.accept.len) return false;

    var seen = BitSet.initEmpty(allocator, a.accept.len * b.accept.len) catch unreachable;
    defer seen.deinit(allocator);

    return eq_helper(a, b, a.start, b.start, &seen);
}

fn eq_helper(
    a: *const DenseDFA,
    b: *const DenseDFA,
    a_st: StateId,
    b_st: StateId,
    seen: *BitSet,
) bool {
    const idx = a_st * b.accept.len + b_st;
    if (seen.isSet(idx)) return true;
    seen.set(idx);

    if (a.accept[a_st] != b.accept[b_st]) return false;

    for (0..256) |ch| {
        const a_succ = a.nextState(a_st, ch);
        const b_succ = b.nextState(b_st, ch);
        if (!eq_helper(a, b, a_succ, b_succ, seen)) return false;
    }
    return true;
}


