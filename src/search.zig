const std = @import("std");
const dfa = @import("dfa.zig");

// a|b is like a or b
// a* is 0 or more a's
// a+ is 1 or more a's


const MatchIterator = struct {
    reader: *std.Io.Reader,
    machine: *const dfa.DenseDFA,
    buf: [4096]u8 = undefined,

    pub fn next(self: *MatchIterator) !?[]const u8 {
        while (try self.reader.takeDelimiter('\n')) |line| {
            if (self.machine.matches(line)) return line;
        }
        return null;
    }
};


pub fn searchFile(stdout: *std.Io.Writer, reader: *std.Io.Reader, machine: *const dfa.DenseDFA) !void {
    var iterator = MatchIterator {
        .reader = reader,
        .machine = machine,
    };
    while (try iterator.next()) |line| {
        try stdout.print("{s}", .{line});
    }
}



// pub const MatchIterator = struct {
//     reader: std.Io.Reader, 
//     machine: *dfa.DenseDFA,
//     line_buf: std.ArrayList(u8),
//     allocator: std.mem.Allocator,

//     pub fn init(allocator: std.mem.Allocator, reader: std.Io.Reader, machine: *dfa.DenseDFA) MatchIterator {
//         return .{
//             .reader = reader,
//             .machine = machine,
//             .line_buf = std.ArrayList(u8).init(allocator),
//             .allocator = allocator,
//         };
//     }

//     pub fn deinit(self: *MatchIterator) void {
//         self.line_buf.deinit();
//     }

//     pub fn next(self: *MatchIterator) !?[]const u8 {
//         while (true) {
//             self.line_buf.clearRetainingCapacity();
//             // streamUntilDelimiter writes directly into our ArrayList's writer
//             self.reader.streamUntilDelimiter(self.line_buf.writer, '\n', null) catch |err| switch (err) {
//                 error.EndOfStream => if (self.line_buf.items.len == 0) return null,
//                 else => return err,
//             };

//             if (self.machine.matches(self.line_buf.items)) {
//                 // Return a slice of the internal buffer
//                 return self.line_buf.items;
//             }
//         }
//     }
// };
