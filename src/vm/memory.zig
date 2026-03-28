const std = @import("std");
const Word = @import("stack.zig").Word;

/// Memory implements the EVM's linear byte-addressed memory.
pub const Memory = struct {
    allocator: std.mem.Allocator,
    store: std.ArrayListUnmanaged(u8) = .{},
    last_gas_cost: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        self.store.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn reset(self: *Memory) void {
        self.store.clearRetainingCapacity();
        self.last_gas_cost = 0;
    }

    pub fn set(self: *Memory, offset: usize, size: usize, value: []const u8) void {
        if (size == 0) return;

        std.debug.assert(offset + size <= self.store.items.len);
        std.debug.assert(value.len >= size);
        @memcpy(self.store.items[offset .. offset + size], value[0..size]);
    }

    /// set32 writes the word as a 32-byte big-endian value.
    pub fn set32(self: *Memory, offset: usize, value: Word) void {
        std.debug.assert(offset + 32 <= self.store.items.len);

        var out = self.store.items[offset .. offset + 32];
        var remaining = value;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            out[i] = @truncate(remaining);
            remaining >>= 8;
        }
    }

    pub fn resize(self: *Memory, size: usize) !void {
        if (self.store.items.len >= size) return;
        try self.store.appendNTimes(self.allocator, 0, size - self.store.items.len);
    }

    pub fn getCopy(self: *const Memory, allocator: std.mem.Allocator, offset: usize, size: usize) ![]u8 {
        if (size == 0) return allocator.alloc(u8, 0);

        std.debug.assert(offset + size <= self.store.items.len);
        const out = try allocator.alloc(u8, size);
        @memcpy(out, self.store.items[offset .. offset + size]);
        return out;
    }

    pub fn getPtr(self: *Memory, offset: usize, size: usize) []u8 {
        if (size == 0) return self.store.items[0..0];

        std.debug.assert(offset + size <= self.store.items.len);
        return self.store.items[offset .. offset + size];
    }

    pub fn len(self: *const Memory) usize {
        return self.store.items.len;
    }

    pub fn data(self: *const Memory) []const u8 {
        return self.store.items;
    }

    pub fn copy(self: *Memory, dst: usize, src: usize, size: usize) void {
        if (size == 0) return;

        std.debug.assert(dst + size <= self.store.items.len);
        std.debug.assert(src + size <= self.store.items.len);
        std.mem.copyForwards(u8, self.store.items[dst .. dst + size], self.store.items[src .. src + size]);
    }
};

test "memory resizes and supports set, set32, getCopy, getPtr, and copy" {
    const allocator = std.testing.allocator;
    var memory = Memory.init(allocator);
    defer memory.deinit();

    try memory.resize(64);
    try std.testing.expectEqual(@as(usize, 64), memory.len());

    memory.set(4, 4, "abcd");
    try std.testing.expectEqualStrings("abcd", memory.getPtr(4, 4));

    memory.set32(32, 0x010203);
    try std.testing.expectEqual(@as(u8, 0x00), memory.data()[60]);
    try std.testing.expectEqual(@as(u8, 0x01), memory.data()[61]);
    try std.testing.expectEqual(@as(u8, 0x02), memory.data()[62]);
    try std.testing.expectEqual(@as(u8, 0x03), memory.data()[63]);

    const copied = try memory.getCopy(allocator, 4, 4);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("abcd", copied);

    memory.copy(8, 4, 4);
    try std.testing.expectEqualStrings("abcd", memory.getPtr(8, 4));
}
