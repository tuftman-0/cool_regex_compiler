const std = @import("std");
const dfa = @import("dfa.zig");

const Match = struct {
    line: []const u8,
    line_no: usize
};

const MatchIterator = struct {
    reader: *std.Io.Reader,
    machine: *const dfa.DenseDFA,
    line_buf: std.Io.Writer.Allocating,
    done: bool = false,
    line_no: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        machine: *const dfa.DenseDFA,
    ) MatchIterator {
        return .{
            .reader = reader,
            .machine = machine,
            .line_buf = std.Io.Writer.Allocating.init(allocator),
        };
    }

    pub fn deinit(self: *MatchIterator) void { self.line_buf.deinit(); }

    pub fn next(self: *MatchIterator) !?Match {
        if (self.done) return null;
        while (true) {
            self.line_buf.clearRetainingCapacity();
            self.line_no += 1;
            // stream into line_buf until '\n' or EOF
            const streamed = self.reader.streamDelimiter(&self.line_buf.writer, '\n') catch |err| {
                if (err != error.EndOfStream) return err;

                // EOF: use tail once, then stop forever
                const tail = self.line_buf.written();
                self.done = true;
                if (tail.len != 0 and self.machine.matches(tail)) return .{ .line = tail, .line_no = self.line_no};
                return null;
            };

            _ = streamed;
            const line = self.line_buf.written();
            self.reader.toss(1); // consume '\n'

            if (self.machine.matches(line)) return .{ .line = line, .line_no = self.line_no};
        }
        return null;
    }
};


pub const PrintOpts = struct {
    label: ?[]const u8 = null,
    show_line_numbers: bool = false,
};

fn printMatch(out: *std.Io.Writer, opts: PrintOpts, m: Match) !void {
    if (opts.label) |lab| try out.print("{s}:", .{lab});
    if (opts.show_line_numbers) try out.print("{d}:", .{m.line_no});
    try out.print("{s}\n", .{m.line});
}

pub fn searchFile(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    reader: *std.Io.Reader,
    machine: *const dfa.DenseDFA,
    opts: PrintOpts,
) !void {
    var it = MatchIterator.init(allocator, reader, machine);
    defer it.deinit();

    while (try it.next()) |m| {
        try printMatch(out, opts, m);
    }
}

// pub fn searchFile(
//     allocator: std.mem.Allocator,
//     stdout: *std.Io.Writer,
//     reader: *std.Io.Reader,
//     machine: *const dfa.DenseDFA
// ) !void {
//     var iterator = MatchIterator.init(allocator, reader, machine);
//     defer iterator.deinit();
//     while (try iterator.next()) |match| {
//         try stdout.print("{s}\n", .{match.line});
//         // try stdout.print("{d}:{s}\n", .{match.line_no, match.line});
//     }
// }
