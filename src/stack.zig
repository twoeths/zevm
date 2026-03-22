const std = @import("std");

pub const Word = u256;
pub const max_size: usize = 1024;

pub const Stack = struct {
    data: std.ArrayListUnmanaged(Word) = .{},

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *Stack) void {
        self.data.clearRetainingCapacity();
    }

    pub fn items(self: *const Stack) []const Word {
        return self.data.items;
    }

    pub fn len(self: *const Stack) usize {
        return self.data.items.len;
    }

    pub fn push(self: *Stack, allocator: std.mem.Allocator, value: Word) !void {
        std.debug.assert(self.len() < max_size);
        try self.data.append(allocator, value);
    }

    pub fn pop(self: *Stack) Word {
        std.debug.assert(self.len() > 0);
        return self.data.pop().?;
    }

    pub fn dup(self: *Stack, allocator: std.mem.Allocator, n: usize) !void {
        std.debug.assert(n >= 1 and n <= self.len());
        try self.push(allocator, self.data.items[self.len() - n]);
    }

    pub fn peek(self: *Stack) *Word {
        std.debug.assert(self.len() > 0);
        return &self.data.items[self.len() - 1];
    }

    pub fn back(self: *Stack, n: usize) *Word {
        std.debug.assert(n < self.len());
        return &self.data.items[self.len() - n - 1];
    }

    pub fn swap(self: *Stack, n: usize) void {
        std.debug.assert(n >= 1 and n < self.len());
        const top = self.len() - 1;
        const other = self.len() - n - 1;
        std.mem.swap(Word, &self.data.items[top], &self.data.items[other]);
    }

    pub fn swap1(self: *Stack) void {
        self.swap(1);
    }

    pub fn swap2(self: *Stack) void {
        self.swap(2);
    }

    pub fn swap3(self: *Stack) void {
        self.swap(3);
    }

    pub fn swap4(self: *Stack) void {
        self.swap(4);
    }

    pub fn swap5(self: *Stack) void {
        self.swap(5);
    }

    pub fn swap6(self: *Stack) void {
        self.swap(6);
    }

    pub fn swap7(self: *Stack) void {
        self.swap(7);
    }

    pub fn swap8(self: *Stack) void {
        self.swap(8);
    }

    pub fn swap9(self: *Stack) void {
        self.swap(9);
    }

    pub fn swap10(self: *Stack) void {
        self.swap(10);
    }

    pub fn swap11(self: *Stack) void {
        self.swap(11);
    }

    pub fn swap12(self: *Stack) void {
        self.swap(12);
    }

    pub fn swap13(self: *Stack) void {
        self.swap(13);
    }

    pub fn swap14(self: *Stack) void {
        self.swap(14);
    }

    pub fn swap15(self: *Stack) void {
        self.swap(15);
    }

    pub fn swap16(self: *Stack) void {
        self.swap(16);
    }
};

test "push, pop, peek, and back" {
    const allocator = std.testing.allocator;
    var stack = Stack{};
    defer stack.deinit(allocator);

    try stack.push(allocator, 1);
    try stack.push(allocator, 2);
    try stack.push(allocator, 3);

    try std.testing.expectEqual(@as(usize, 3), stack.len());
    try std.testing.expectEqual(@as(Word, 3), stack.peek().*);
    try std.testing.expectEqual(@as(Word, 2), stack.back(1).*);
    try std.testing.expectEqual(@as(Word, 3), stack.pop());
    try std.testing.expectEqual(@as(usize, 2), stack.len());
}

test "dup copies nth item from the top" {
    const allocator = std.testing.allocator;
    var stack = Stack{};
    defer stack.deinit(allocator);

    try stack.push(allocator, 10);
    try stack.push(allocator, 20);
    try stack.push(allocator, 30);

    try stack.dup(allocator, 2);

    try std.testing.expectEqual(@as(usize, 4), stack.len());
    try std.testing.expectEqual(@as(Word, 20), stack.peek().*);
}

test "swap exchanges top with nth item below it" {
    const allocator = std.testing.allocator;
    var stack = Stack{};
    defer stack.deinit(allocator);

    try stack.push(allocator, 1);
    try stack.push(allocator, 2);
    try stack.push(allocator, 3);
    try stack.push(allocator, 4);

    stack.swap2();

    try std.testing.expectEqualSlices(Word, &[_]Word{ 1, 4, 3, 2 }, stack.items());
}
