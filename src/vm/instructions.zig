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

/// MULMOD (0x09): pop x, pop y, peek z, z = (x * y) % z. Returns 0 if z == 0.
/// Multiplication is performed in u512 to avoid overflow before the modulo.
pub fn opMulmod(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.pop();
    const z = scope.stack.peek();
    if (z.* == 0) return null;
    const product: u512 = @as(u512, x) * @as(u512, y);
    z.* = @intCast(product % @as(u512, z.*));
    return null;
}

/// EXP (0x0a): pop base, peek exponent, exponent = base ** exponent (mod 2^256).
/// Uses binary exponentiation with wrapping multiplies.
pub fn opExp(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    var base = scope.stack.pop();
    const exp = scope.stack.peek();
    var e = exp.*;
    var result: u256 = 1;
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) result *%= base;
        base *%= base;
    }
    exp.* = result;
    return null;
}

// ── Comparison & bitwise ──────────────────────────────────────────────────────

/// LT (0x10): pop x, peek y, y = (x < y) ? 1 : 0 (unsigned).
pub fn opLt(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = if (x < y.*) 1 else 0;
    return null;
}

/// GT (0x11): pop x, peek y, y = (x > y) ? 1 : 0 (unsigned).
pub fn opGt(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = if (x > y.*) 1 else 0;
    return null;
}

/// SLT (0x12): pop x, peek y, y = (x < y) ? 1 : 0 (signed two's complement).
pub fn opSlt(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y.*);
    y.* = if (sx < sy) 1 else 0;
    return null;
}

/// SGT (0x13): pop x, peek y, y = (x > y) ? 1 : 0 (signed two's complement).
pub fn opSgt(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y.*);
    y.* = if (sx > sy) 1 else 0;
    return null;
}

/// EQ (0x14): pop x, peek y, y = (x == y) ? 1 : 0.
pub fn opEq(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* = if (x == y.*) 1 else 0;
    return null;
}

/// ISZERO (0x15): peek x, x = (x == 0) ? 1 : 0.
pub fn opIszero(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.peek();
    x.* = if (x.* == 0) 1 else 0;
    return null;
}

/// AND (0x16): pop x, peek y, y = x & y.
pub fn opAnd(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* &= x;
    return null;
}

/// OR (0x17): pop x, peek y, y = x | y.
pub fn opOr(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* |= x;
    return null;
}

/// XOR (0x18): pop x, peek y, y = x ^ y.
pub fn opXor(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.pop();
    const y = scope.stack.peek();
    y.* ^= x;
    return null;
}

/// NOT (0x19): peek x, x = ~x (bitwise complement).
pub fn opNot(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.peek();
    x.* = ~x.*;
    return null;
}

/// BYTE (0x1a): pop th, peek val, val = byte at index th (0 = MSB). Returns 0 if th >= 32.
pub fn opByte(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const th  = scope.stack.pop();
    const val = scope.stack.peek();
    if (th >= 32) {
        val.* = 0;
        return null;
    }
    const shift: u8 = @intCast((31 - th) * 8);
    val.* = (val.* >> shift) & 0xFF;
    return null;
}

/// CLZ (0x1e): peek x, x = number of leading zero bits in x (0..256).
pub fn opClz(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.peek();
    x.* = @clz(x.*);
    return null;
}

/// SHL (0x1b): pop shift, peek val, val = val << shift (logical). Returns 0 if shift >= 256.
pub fn opShl(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const shift = scope.stack.pop();
    const val   = scope.stack.peek();
    if (shift >= 256) {
        val.* = 0;
        return null;
    }
    val.* <<= @intCast(shift);
    return null;
}

/// SHR (0x1c): pop shift, peek val, val = val >> shift (logical). Returns 0 if shift >= 256.
pub fn opShr(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const shift = scope.stack.pop();
    const val   = scope.stack.peek();
    if (shift >= 256) {
        val.* = 0;
        return null;
    }
    val.* >>= @intCast(shift);
    return null;
}

/// SAR (0x1d): pop shift, peek val, val = val >>> shift (arithmetic, sign-extending).
/// If shift >= 256: returns 0 for non-negative values, all-ones for negative.
pub fn opSar(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const shift = scope.stack.pop();
    const val   = scope.stack.peek();
    const sv: i256 = @bitCast(val.*);
    if (shift >= 256) {
        val.* = if (sv < 0) std.math.maxInt(u256) else 0;
        return null;
    }
    val.* = @bitCast(sv >> @as(u8, @intCast(shift)));
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

test "opMulmod: (3 * 5) % 7 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 7); // z (modulus)
    try stack.push(allocator, 5); // y
    try stack.push(allocator, 3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMulmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMulmod: overflow product (2^128 * 2^128) % 3 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    // 2^128 * 2^128 = 2^256, which overflows u256.
    // 2^256 mod 3: 2^256 = (2^2)^128 = 4^128 ≡ 1^128 = 1 (mod 3)
    const two_pow_128: u256 = 1 << 128;
    try stack.push(allocator, 3);
    try stack.push(allocator, two_pow_128);
    try stack.push(allocator, two_pow_128);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMulmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMulmod: modulus zero returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0); // z
    try stack.push(allocator, 5); // y
    try stack.push(allocator, 3); // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opMulmod(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opExp: 2 ** 10 = 1024" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 10); // exponent
    try stack.push(allocator, 2);  // base — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opExp(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1024), scope.stack.peek().*);
}

test "opExp: x ** 0 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0);  // exponent
    try stack.push(allocator, 42); // base
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opExp(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opExp: 2 ** 256 wraps to 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 256); // exponent
    try stack.push(allocator, 2);   // base
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opExp(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
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

test "opLt: 3 < 5 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 5); // y
    try stack.push(allocator, 3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opLt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opLt: 5 < 3 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 3); // y
    try stack.push(allocator, 5); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opLt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opGt: 5 > 3 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 3); // y
    try stack.push(allocator, 5); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opGt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opGt: 3 > 5 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 5); // y
    try stack.push(allocator, 3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opGt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSlt: -1 < 1 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, 1);    // y
    try stack.push(allocator, neg1); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSlt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opSlt: 1 < -1 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, neg1); // y
    try stack.push(allocator, 1);    // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSlt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSgt: 1 > -1 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, neg1); // y
    try stack.push(allocator, 1);    // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSgt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opSgt: -1 > 1 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, 1);    // y
    try stack.push(allocator, neg1); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSgt(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opEq: 42 == 42 = 1" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 42);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opEq(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opEq: 1 == 2 = 0" {
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
    try stack.push(allocator, 1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opEq(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opIszero: 0 = 1" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opIszero(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opIszero: 42 = 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opIszero(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAnd: 0xF0 & 0xFF = 0xF0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0xFF);
    try stack.push(allocator, 0xF0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opAnd(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0xF0), scope.stack.peek().*);
}

test "opOr: 0xF0 | 0x0F = 0xFF" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0x0F);
    try stack.push(allocator, 0xF0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opOr(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0xFF), scope.stack.peek().*);
}

test "opXor: 0xFF ^ 0xF0 = 0x0F" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0xF0);
    try stack.push(allocator, 0xFF);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opXor(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0x0F), scope.stack.peek().*);
}

test "opNot: ~0 = maxInt(u256)" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opNot(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opNot: ~maxInt(u256) = 0" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opNot(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opByte: byte 31 of 0x42 = 0x42" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0x42); // val
    try stack.push(allocator, 31);   // th — top (LSB is byte 31)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opByte(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0x42), scope.stack.peek().*);
}

test "opByte: th >= 32 returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0xFF); // val
    try stack.push(allocator, 32);   // th — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opByte(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opShl: 1 << 1 = 2" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 1); // val
    try stack.push(allocator, 1); // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opShl(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 2), scope.stack.peek().*);
}

test "opShl: shift >= 256 returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 1);   // val
    try stack.push(allocator, 256); // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opShl(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opShr: 4 >> 1 = 2" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 4); // val
    try stack.push(allocator, 1); // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opShr(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 2), scope.stack.peek().*);
}

test "opShr: shift >= 256 returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 0xFF); // val
    try stack.push(allocator, 256);  // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opShr(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSar: -4 >> 1 = -2 (sign extending)" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg4: u256 = @bitCast(@as(i256, -4));
    try stack.push(allocator, neg4); // val
    try stack.push(allocator, 1);    // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSar(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -2), result);
}

test "opSar: shift >= 256 with negative value returns all-ones" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    const neg1: u256 = @bitCast(@as(i256, -1));
    try stack.push(allocator, neg1); // val (negative)
    try stack.push(allocator, 256);  // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSar(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opSar: shift >= 256 with positive value returns 0" {
    const allocator = std.testing.allocator;
    var jump_dests = @import("jump_dest_cache.zig").JumpDestCache.init();
    defer jump_dests.deinit(allocator);
    var contract = @import("contract.zig").Contract.init(allocator, &jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack = @import("stack.zig").Stack{};
    defer stack.deinit(allocator);
    try stack.push(allocator, 42);  // val (positive)
    try stack.push(allocator, 256); // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opSar(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opClz: 0 has 256 leading zeros" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opClz(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 256), scope.stack.peek().*);
}

test "opClz: 1 has 255 leading zeros" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opClz(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 255), scope.stack.peek().*);
}

test "opClz: maxInt(u256) has 0 leading zeros" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    const evm_placeholder: u8 = 0;
    _ = try opClz(&pc, @constCast(@ptrCast(&evm_placeholder)), &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}
