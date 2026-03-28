const std = @import("std");
const common = @import("common");
const Contract = @import("contract.zig").Contract;
const Memory = @import("memory.zig").Memory;
const Stack = @import("stack.zig").Stack;
const Word = @import("stack.zig").Word;

/// ScopeContext carries per-call execution state without transient interpreter fields.
pub const ScopeContext = struct {
    memory: *Memory,
    stack: *Stack,
    contract: *Contract,

    pub fn memoryData(self: *const ScopeContext) []const u8 {
        return self.memory.data();
    }

    pub fn stackData(self: *const ScopeContext) []const Word {
        return self.stack.items();
    }

    pub fn caller(self: *const ScopeContext) common.Address {
        return self.contract.caller;
    }

    pub fn address(self: *const ScopeContext) common.Address {
        return self.contract.address;
    }

    pub fn callValue(self: *const ScopeContext) Word {
        return self.contract.value;
    }

    pub fn callInput(self: *const ScopeContext) []const u8 {
        return self.contract.input;
    }

    pub fn contractCode(self: *const ScopeContext) []const u8 {
        return self.contract.code;
    }
};

test "scope context exposes memory, stack, and contract-backed accessors" {
    const allocator = std.testing.allocator;

    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);

    var contract = Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    contract.caller = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    contract.address = try common.hexToAddress("0xaabbccddeeff0011223344556677889900112233");
    contract.value = 7;
    contract.input = "call-data";
    contract.code = "code";

    var memory = Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(4);
    memory.set(0, 4, "mem!");

    var stack = Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 11);
    try stack.push(allocator, 22);

    const scope = ScopeContext{
        .memory = &memory,
        .stack = &stack,
        .contract = &contract,
    };

    try std.testing.expectEqualSlices(u8, "mem!", scope.memoryData());
    try std.testing.expectEqualSlices(Word, &[_]Word{ 11, 22 }, scope.stackData());
    try std.testing.expectEqual(contract.caller, scope.caller());
    try std.testing.expectEqual(contract.address, scope.address());
    try std.testing.expectEqual(@as(Word, 7), scope.callValue());
    try std.testing.expectEqualStrings("call-data", scope.callInput());
    try std.testing.expectEqualStrings("code", scope.contractCode());
}
