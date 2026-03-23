const std = @import("std");
const common = @import("common");
const code_bitmap = @import("code_bitmap.zig");

/// JumpDestCache stores code-analysis bitmaps keyed by code hash so jump
/// destination validation can reuse previously computed opcode/data layouts.
/// `parseAndStore` is the main consumer entrypoint: it analyzes bytecode once,
/// stores the owned bitmap, and returns it. `load` returns a borrowed wrapper
/// over cache-owned storage, while `store` allows injecting precomputed data.
pub const JumpDestCache = struct {
    // TODO zevm: consider if we should keep the allocator here or let callers manage it.
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(common.Hash, []u8),

    pub fn init(allocator: std.mem.Allocator) JumpDestCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(common.Hash, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *JumpDestCache) void {
        var iterator = self.map.valueIterator();
        while (iterator.next()) |bits| {
            self.allocator.free(bits.*);
        }
        self.map.deinit();
        self.* = undefined;
    }

    pub fn load(self: *const JumpDestCache, code_hash: common.Hash) ?code_bitmap.CodeBitmap {
        const bits = self.map.get(code_hash) orelse return null;
        return .{ .bits = bits };
    }

    pub fn store(self: *JumpDestCache, code_hash: common.Hash, bitmap: code_bitmap.CodeBitmap) !void {
        const owned_bits = try self.allocator.dupe(u8, bitmap.bits);
        errdefer self.allocator.free(owned_bits);

        try putOwned(self, code_hash, owned_bits);
    }

    pub fn parseAndStore(self: *JumpDestCache, code_hash: common.Hash, code: []const u8) !code_bitmap.CodeBitmap {
        const owned_bits = try self.allocator.alloc(u8, code_bitmap.bitmapLen(code.len));
        errdefer self.allocator.free(owned_bits);
        _ = code_bitmap.codeIntoBitmap(code, owned_bits);

        try putOwned(self, code_hash, owned_bits);
        return .{ .bits = self.map.get(code_hash).? };
    }

    fn putOwned(self: *JumpDestCache, code_hash: common.Hash, owned_bits: []u8) !void {
        const gop = try self.map.getOrPut(code_hash);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_bits;
    }
};

test "jump dest cache stores and loads analysis by hash" {
    const allocator = std.testing.allocator;
    var cache = JumpDestCache.init(allocator);
    defer cache.deinit();

    const code = [_]u8{ 0x61, 0xaa, 0xbb, 0x5b };
    const hash = try common.hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    _ = try cache.parseAndStore(hash, &code);

    const cached = cache.load(hash) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cached.codeSegment(0));
    try std.testing.expect(!cached.codeSegment(1));
    try std.testing.expect(!cached.codeSegment(2));
    try std.testing.expect(cached.codeSegment(3));
}

test "jump dest cache overwrites existing entries" {
    const allocator = std.testing.allocator;
    var cache = JumpDestCache.init(allocator);
    defer cache.deinit();

    const hash = try common.hexToHash("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

    const code_a = [_]u8{ 0x60, 0xaa, 0x5b };
    _ = try cache.parseAndStore(hash, &code_a);

    const code_b = [_]u8{ 0x5b, 0x00 };
    _ = try cache.parseAndStore(hash, &code_b);

    const cached = cache.load(hash) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cached.codeSegment(0));
    try std.testing.expect(cached.codeSegment(1));
}

test "jump dest cache can store precomputed bitmaps" {
    const allocator = std.testing.allocator;
    var cache = JumpDestCache.init(allocator);
    defer cache.deinit();

    const code = [_]u8{ 0x60, 0xaa, 0x5b };
    var bitmap = try code_bitmap.codeBitmap(allocator, &code);
    defer bitmap.deinit(allocator);

    const hash = try common.hexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try cache.store(hash, bitmap);

    const cached = cache.load(hash) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cached.codeSegment(0));
    try std.testing.expect(!cached.codeSegment(1));
    try std.testing.expect(cached.codeSegment(2));
}
