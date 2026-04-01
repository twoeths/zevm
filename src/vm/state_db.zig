const std = @import("std");
const common = @import("common");
const Word = @import("stack.zig").Word;

/// Minimal in-memory StateDB backing needed by the current EVM implementation.
/// Start with balances and grow this surface as more opcodes land.
pub const StateDB = struct {
    balances: std.AutoHashMapUnmanaged(common.Address, Word) = .{},
    codes: std.AutoHashMapUnmanaged(common.Address, []u8) = .{},

    pub fn init() StateDB {
        return .{};
    }

    pub fn deinit(self: *StateDB, allocator: std.mem.Allocator) void {
        var iterator = self.codes.valueIterator();
        while (iterator.next()) |code| {
            allocator.free(code.*);
        }
        self.codes.deinit(allocator);
        self.balances.deinit(allocator);
        self.* = undefined;
    }

    pub fn getBalance(self: *const StateDB, address: common.Address) Word {
        return self.balances.get(address) orelse 0;
    }

    pub fn setBalance(self: *StateDB, allocator: std.mem.Allocator, address: common.Address, balance: Word) !void {
        try self.balances.put(allocator, address, balance);
    }

    pub fn getCodeSize(self: *const StateDB, address: common.Address) usize {
        const code = self.codes.get(address) orelse return 0;
        return code.len;
    }

    pub fn setCode(self: *StateDB, allocator: std.mem.Allocator, address: common.Address, code: []const u8) !void {
        const owned_code = try allocator.dupe(u8, code);
        errdefer allocator.free(owned_code);

        const gop = try self.codes.getOrPut(allocator, address);
        if (gop.found_existing) {
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_code;
    }
};

test "state db stores and loads balances by address" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try std.testing.expectEqual(@as(Word, 0), state_db.getBalance(address));

    try state_db.setBalance(allocator, address, 42);
    try std.testing.expectEqual(@as(Word, 42), state_db.getBalance(address));
}

test "state db stores and reports code size by address" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try std.testing.expectEqual(@as(usize, 0), state_db.getCodeSize(address));

    try state_db.setCode(allocator, address, &[_]u8{ 0x60, 0xaa, 0x5b });
    try std.testing.expectEqual(@as(usize, 3), state_db.getCodeSize(address));
}
