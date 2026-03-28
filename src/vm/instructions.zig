const std          = @import("std");
const Evm          = @import("jump_table.zig").Evm;
const ScopeContext = @import("interpreter.zig").ScopeContext;

/// Typed error set for opcode execution functions.
/// Extended as new opcodes are implemented.
pub const ExecError = error{
    StopToken,     // STOP, RETURN, SELFDESTRUCT — normal halt
    InvalidOpcode,
};

// ── Control flow ──────────────────────────────────────────────────────────────

/// STOP (0x00): halt execution normally.
/// Mirrors go-ethereum: `return nil, errStopToken`.
pub fn opStop(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm, scope };
    return error.StopToken;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "opStop returns StopToken" {
    const allocator = std.testing.allocator;

    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);

    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();

    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();

    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);

    var scope = ScopeContext{
        .memory   = &memory,
        .stack    = &stack,
        .contract = &contract,
    };

    var pc: u64 = 0;
    // opStop ignores all arguments; any non-null evm pointer satisfies the type
    const evm_placeholder: u8 = 0;
    const result = opStop(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectError(error.StopToken, result);
}
