// PDA
pub const  = struct {
    start: StateId,
    accept: []bool,
    edges: []std.ArrayList(Edge), // per DFA state

    pub fn deinit(self: *DFA, a: std.mem.Allocator) void {
        for (self.edges) |*lst| lst.deinit(a);
        a.free(self.edges);
        a.free(self.accept);
    }
