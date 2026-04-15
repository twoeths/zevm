const std = @import("std");

pub const Word = u256;
pub const max_size: usize = 1024;

/// EVM word stack, capacity fixed at the protocol maximum of 1024 entries.
///
/// Design: the backing buffer is caller-provided. Stack itself holds only an
/// ArrayListUnmanaged header (slice pointer + capacity usize) — it owns no
/// memory and needs no allocator anywhere.
///
/// The caller decides the buffer lifetime strategy:
///   - Stack-allocate `[max_size]Word` for simple single-frame use.
///   - Heap-allocate and reuse via a pool across call frames (preferred for an
///     interpreter) — buffers grow to the high-water mark of observed call
///     depth and are never freed, eliminating per-frame allocation entirely.
///
/// Why ArrayListUnmanaged + initBuffer instead of a bare array + usize index:
///   Reuses std slice/length machinery (items, len, pop) and lets us call
///   appendAssumeCapacity without an allocator, since capacity is pre-set.
pub const Stack = struct {
    data: std.ArrayListUnmanaged(Word) = .{},

    /// Caller stack-allocates `buf` (length >= max_size) and passes it in.
    /// Returns a Stack wired to that buffer — no heap involved.
    pub fn init(buf: []Word) Stack {
        return .{ .data = std.ArrayListUnmanaged(Word).initBuffer(buf) };
    }

    /// no need deinit() since we own no memory
    pub fn reset(self: *Stack) void {
        self.data.clearRetainingCapacity();
    }

    pub fn items(self: *const Stack) []const Word {
        return self.data.items;
    }

    pub fn len(self: *const Stack) usize {
        return self.data.items.len;
    }

    /// Push one word. Infallible: capacity was reserved upfront by init.
    pub fn push(self: *Stack, value: Word) void {
        std.debug.assert(self.len() < max_size);
        self.data.appendAssumeCapacity(value);
    }

    pub fn pop(self: *Stack) Word {
        std.debug.assert(self.len() > 0);
        return self.data.pop().?;
    }

    /// Duplicate the nth word from the top (1-indexed). Infallible.
    pub fn dup(self: *Stack, n: usize) void {
        std.debug.assert(n >= 1 and n <= self.len());
        self.push(self.data.items[self.len() - n]);
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
};

test "push, pop, peek, and back" {
    var buf: [max_size]Word = undefined;
    var stack = Stack.init(&buf);

    stack.push(1);
    stack.push(2);
    stack.push(3);

    try std.testing.expectEqual(@as(usize, 3), stack.len());
    try std.testing.expectEqual(@as(Word, 3), stack.peek().*);
    try std.testing.expectEqual(@as(Word, 2), stack.back(1).*);
    try std.testing.expectEqual(@as(Word, 3), stack.pop());
    try std.testing.expectEqual(@as(usize, 2), stack.len());
}

test "dup copies nth item from the top" {
    var buf: [max_size]Word = undefined;
    var stack = Stack.init(&buf);

    stack.push(10);
    stack.push(20);
    stack.push(30);

    stack.dup(2);

    try std.testing.expectEqual(@as(usize, 4), stack.len());
    try std.testing.expectEqual(@as(Word, 20), stack.peek().*);
}

test "swap exchanges top with nth item below it" {
    var buf: [max_size]Word = undefined;
    var stack = Stack.init(&buf);

    stack.push(1);
    stack.push(2);
    stack.push(3);
    stack.push(4);

    stack.swap(2);

    try std.testing.expectEqualSlices(Word, &[_]Word{ 1, 4, 3, 2 }, stack.items());
}
