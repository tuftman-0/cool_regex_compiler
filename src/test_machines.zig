const std = @import("std");
const dfa = @import("dfa.zig");

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
