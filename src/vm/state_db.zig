const std = @import("std");
const common = @import("common");
const Word = @import("stack.zig").Word;

pub const Log = struct {
    address: common.Address,
    topics: []common.Hash,
    data: []u8,
    block_number: u64,
};

/// Minimal in-memory StateDB backing needed by the current EVM implementation.
/// Start with balances and grow this surface as more opcodes land.
pub const StateDB = struct {
    const StorageKey = struct {
        address: common.Address,
        storage_key: common.Hash,
    };

    balances: std.AutoHashMapUnmanaged(common.Address, Word) = .{},
    codes: std.AutoHashMapUnmanaged(common.Address, []u8) = .{},
    storage: std.AutoHashMapUnmanaged(StorageKey, common.Hash) = .{},
    transient_storage: std.AutoHashMapUnmanaged(StorageKey, common.Hash) = .{},
    logs: std.ArrayListUnmanaged(Log) = .{},

    pub fn init() StateDB {
        return .{};
    }

    pub fn deinit(self: *StateDB, allocator: std.mem.Allocator) void {
        var iterator = self.codes.valueIterator();
        while (iterator.next()) |code| {
            allocator.free(code.*);
        }
        for (self.logs.items) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        self.codes.deinit(allocator);
        self.storage.deinit(allocator);
        self.transient_storage.deinit(allocator);
        self.logs.deinit(allocator);
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

    pub fn getCode(self: *const StateDB, address: common.Address) []const u8 {
        return self.codes.get(address) orelse &.{};
    }

    pub fn getCodeHash(self: *const StateDB, address: common.Address) common.Hash {
        if (self.empty(address)) {
            return .{};
        }

        var out: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(self.getCode(address), &out, .{});
        return .{ .bytes = out };
    }

    pub fn empty(self: *const StateDB, address: common.Address) bool {
        return self.getBalance(address) == 0 and self.getCodeSize(address) == 0;
    }

    /// Load a storage value for an account and storage key.
    /// Equivalent to `GetState` in go-ethereum (geth).
    pub fn getStorageValue(self: *const StateDB, address: common.Address, storage_key: common.Hash) common.Hash {
        return self.storage.get(.{ .address = address, .storage_key = storage_key }) orelse .{};
    }

    pub fn setState(self: *StateDB, allocator: std.mem.Allocator, address: common.Address, storage_key: common.Hash, value: common.Hash) !void {
        try self.storage.put(allocator, .{ .address = address, .storage_key = storage_key }, value);
    }

    /// Load a transient storage value for an account and storage key.
    /// Equivalent to `GetTransientState` in go-ethereum (geth).
    pub fn getTransientStorageValue(self: *const StateDB, address: common.Address, storage_key: common.Hash) common.Hash {
        return self.transient_storage.get(.{ .address = address, .storage_key = storage_key }) orelse .{};
    }

    pub fn setTransientState(self: *StateDB, allocator: std.mem.Allocator, address: common.Address, storage_key: common.Hash, value: common.Hash) !void {
        try self.transient_storage.put(allocator, .{ .address = address, .storage_key = storage_key }, value);
    }

    pub fn addLog(self: *StateDB, allocator: std.mem.Allocator, log: Log) !void {
        try self.logs.append(allocator, log);
    }

    pub fn getLogs(self: *const StateDB) []const Log {
        return self.logs.items;
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
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0xaa, 0x5b }, state_db.getCode(address));
    try std.testing.expect(!state_db.empty(address));

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&[_]u8{ 0x60, 0xaa, 0x5b }, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, state_db.getCodeHash(address).asBytes());
}

test "state db returns zero hash for empty accounts and empty code hash for funded no-code accounts" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try std.testing.expect(state_db.empty(address));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), state_db.getCodeHash(address).asBytes());

    try state_db.setBalance(allocator, address, 1);
    var expected_empty_code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&.{}, &expected_empty_code_hash, .{});
    try std.testing.expect(!state_db.empty(address));
    try std.testing.expectEqualSlices(u8, &expected_empty_code_hash, state_db.getCodeHash(address).asBytes());
}

test "state db stores and loads storage slots by address and slot hash" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const storage_key = try common.hexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const value = try common.hexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), state_db.getStorageValue(address, storage_key).asBytes());

    try state_db.setState(allocator, address, storage_key, value);
    try std.testing.expectEqualSlices(u8, value.asBytes(), state_db.getStorageValue(address, storage_key).asBytes());
}

test "state db stores and loads transient storage slots by address and slot hash" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const storage_key = try common.hexToHash("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    const value = try common.hexToHash("0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");

    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), state_db.getTransientStorageValue(address, storage_key).asBytes());

    try state_db.setTransientState(allocator, address, storage_key, value);
    try std.testing.expectEqualSlices(u8, value.asBytes(), state_db.getTransientStorageValue(address, storage_key).asBytes());
}

test "state db stores emitted logs" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const topics = try allocator.dupe(common.Hash, &[_]common.Hash{
        try common.hexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    });
    const data = try allocator.dupe(u8, "hello");

    try state_db.addLog(allocator, .{
        .address = address,
        .topics = topics,
        .data = data,
        .block_number = 7,
    });

    try std.testing.expectEqual(@as(usize, 1), state_db.getLogs().len);
    try std.testing.expectEqual(address, state_db.getLogs()[0].address);
    try std.testing.expectEqual(@as(u64, 7), state_db.getLogs()[0].block_number);
    try std.testing.expectEqualSlices(u8, "hello", state_db.getLogs()[0].data);
    try std.testing.expectEqualSlices(u8, topics[0].asBytes(), state_db.getLogs()[0].topics[0].asBytes());
}
