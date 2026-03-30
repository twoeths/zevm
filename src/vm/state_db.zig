const std = @import("std");
const common = @import("common");
const Word = @import("stack.zig").Word;

/// Minimal in-memory StateDB backing needed by the current EVM implementation.
/// Start with balances and grow this surface as more opcodes land.
pub const StateDB = struct {
    balances: std.AutoHashMapUnmanaged(common.Address, Word) = .{},

    pub fn init() StateDB {
        return .{};
    }

    pub fn deinit(self: *StateDB, allocator: std.mem.Allocator) void {
        self.balances.deinit(allocator);
        self.* = undefined;
    }

    pub fn getBalance(self: *const StateDB, address: common.Address) Word {
        return self.balances.get(address) orelse 0;
    }

    pub fn setBalance(self: *StateDB, allocator: std.mem.Allocator, address: common.Address, balance: Word) !void {
        try self.balances.put(allocator, address, balance);
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
