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
pub fn opStop(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm, scope };
    return error.StopToken;
}

// ── Arithmetic ────────────────────────────────────────────────────────────────

/// ADD (0x01): pop x, peek y, y = x + y (wrapping 2^256).
pub fn opAdd(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* +%= x;
    return null;
}

/// SUB (0x03): pop x, peek y, y = x - y (wrapping 2^256).
pub fn opSub(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = x -% y.*;
    return null;
}

/// MUL (0x02): pop x, peek y, y = x * y (wrapping 2^256).
pub fn opMul(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* *%= x;
    return null;
}

/// DIV (0x04): pop x, peek y, y = x / y unsigned. Returns 0 if y == 0.
pub fn opDiv(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = if (y.* == 0) 0 else x / y.*;
    return null;
}

/// SDIV (0x05): pop x, peek y, y = x / y signed (two's complement, truncate toward zero).
/// Returns 0 if y == 0. Returns INT256_MIN if x == INT256_MIN and y == -1 (overflow).
pub fn opSdiv(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    if (y.* == 0) return null;
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y.*);
    if (sx == std.math.minInt(i256) and sy == -1) {
        y.* = @bitCast(@as(i256, std.math.minInt(i256)));
        return null;
    }
    y.* = @bitCast(@divTrunc(sx, sy));
    return null;
}

/// MOD (0x06): pop x, peek y, y = x % y unsigned. Returns 0 if y == 0.
pub fn opMod(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = if (y.* == 0) 0 else x % y.*;
    return null;
}

/// SMOD (0x07): pop x, peek y, y = x % y signed. Result has same sign as x. Returns 0 if y == 0.
pub fn opSmod(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    if (y.* == 0) return null;
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y.*);
    y.* = @bitCast(@rem(sx, sy));
    return null;
}

/// ADDMOD (0x08): pop x, pop y, peek z, z = (x + y) % z. Returns 0 if z == 0.
/// Addition is performed in u512 to avoid overflow before the modulo.
pub fn opAddmod(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.pop();
    const z = scope.stack.peek();
    if (z.* == 0) return null;
    const sum: u512 = @as(u512, x) + @as(u512, y);
    z.* = @intCast(sum % @as(u512, z.*));
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "opAdd: 2 + 3 = 5" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 2);
    try stack.push(allocator, 3);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAdd(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 5), scope.stack.peek().*);
}

test "opAdd: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, std.math.maxInt(u256));
    try stack.push(allocator, 1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAdd(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSub: 10 - 3 = 7" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 3);
    try stack.push(allocator, 10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSub(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 7), scope.stack.peek().*);
}

test "opSub: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 1);
    try stack.push(allocator, 0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSub(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opMul: 6 * 7 = 42" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 7);
    try stack.push(allocator, 6);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMul(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 42), scope.stack.peek().*);
}

test "opMul: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 2);
    try stack.push(allocator, std.math.maxInt(u256));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMul(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    // maxInt(u256) * 2 = 2^257 - 2 ≡ 2^256 - 2 (mod 2^256)
    try std.testing.expectEqual(std.math.maxInt(u256) - 1, scope.stack.peek().*);
}

test "opDiv: 10 / 3 = 3" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 3);
    try stack.push(allocator, 10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opDiv(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 3), scope.stack.peek().*);
}

test "opDiv: divide by zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opDiv(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSdiv: -10 / 3 = -3" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg10: u256 = @bitCast(@as(i256, -10));
    try stack.push(allocator, 3);
    try stack.push(allocator, neg10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSdiv(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -3), result);
}

test "opSdiv: divide by zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSdiv(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSdiv: INT256_MIN / -1 returns INT256_MIN" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const int256_min: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, neg1);
    try stack.push(allocator, int256_min);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSdiv(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(int256_min, scope.stack.peek().*);
}

test "opMod: 10 % 3 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 3);
    try stack.push(allocator, 10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMod: modulo by zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSmod: -10 % 3 = -1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg10: u256 = @bitCast(@as(i256, -10));
    try stack.push(allocator, 3);
    try stack.push(allocator, neg10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -1), result);
}

test "opSmod: modulo by zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAddmod: (2 + 3) % 4 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 4); // z (modulus) — pushed first, deepest
    try stack.push(allocator, 3); // y
    try stack.push(allocator, 2); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAddmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opAddmod: overflow sum (maxInt + 1) % 2 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 2);                    // z
    try stack.push(allocator, 1);                    // y
    try stack.push(allocator, std.math.maxInt(u256)); // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAddmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAddmod: modulus zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);  // z
    try stack.push(allocator, 3);  // y
    try stack.push(allocator, 2);  // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAddmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

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
