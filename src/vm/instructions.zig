const std          = @import("std");
const common       = @import("common");
const Evm          = @import("evm.zig").Evm;
const Fork         = @import("jump_table.zig").Fork;
const ScopeContext = @import("interpreter.zig").ScopeContext;
const StateDB      = @import("state_db.zig").StateDB;
const Word         = @import("stack.zig").Word;

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

// ── Block info ────────────────────────────────────────────────────────────────

/// ADDRESS (0x30): push the address of the currently executing contract.
pub fn opAddress(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    var buf = [_]u8{0} ** 32;
    const addr = scope.contract.address.bytes;
    @memcpy(buf[12..], &addr);
    scope.stack.push(std.mem.readInt(u256, &buf, .big));
    return null;
}

/// BALANCE (0x31): replace the top stack item address with that account's balance.
pub fn opBalance(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const slot = scope.stack.peek();
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &buf, slot.*, .big);
    const address = common.bytesToAddress(buf[12..]);
    slot.* = evm.getBalance(address);
    return null;
}

/// ORIGIN (0x32): push the transaction origin address as a u256 word.
pub fn opOrigin(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    var buf = [_]u8{0} ** 32;
    @memcpy(buf[12..], &evm.tx_context.origin.bytes);
    scope.stack.push(std.mem.readInt(u256, &buf, .big));
    return null;
}

/// CALLER (0x33): push the immediate caller address as a u256 word.
pub fn opCaller(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    var buf = [_]u8{0} ** 32;
    @memcpy(buf[12..], &scope.contract.caller.bytes);
    scope.stack.push(std.mem.readInt(u256, &buf, .big));
    return null;
}

/// CALLDATALOAD (0x35): replace the top stack item offset with 32 bytes from calldata.
pub fn opCallDataLoad(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const x = scope.stack.peek();
    if (x.* > std.math.maxInt(usize)) {
        x.* = 0;
        return null;
    }

    const offset: usize = @intCast(x.*);
    const input = scope.contract.input;
    if (offset >= input.len) {
        x.* = 0;
        return null;
    }

    var word_buf = [_]u8{0} ** 32;
    const available = @min(@as(usize, 32), input.len - offset);
    @memcpy(word_buf[0..available], input[offset .. offset + available]);
    x.* = std.mem.readInt(u256, &word_buf, .big);
    return null;
}

/// CALLDATASIZE (0x36): push the size of the current call input in bytes.
pub fn opCallDataSize(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    scope.stack.push(scope.contract.input.len);
    return null;
}

// ── Hash ──────────────────────────────────────────────────────────────────────

/// KECCAK256 (0x20): pop offset, peek size, size = keccak256(memory[offset..offset+size]).
pub fn opKeccak256(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const offset = scope.stack.pop();
    const size   = scope.stack.peek();
    const data   = scope.memory.getPtr(@intCast(offset), @intCast(size.*));
    var buf: [32]u8 = undefined;
    // TODO zevm: may want to make this generic by calling an Evm function like in go-ethereum
    std.crypto.hash.sha3.Keccak256.hash(data, &buf, .{});
    size.* = std.mem.readInt(u256, &buf, .big);
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn initTestEvm(allocator: std.mem.Allocator, state_db: *StateDB, fork: Fork) Evm {
    return Evm.init(allocator, state_db, fork);
}

test "opAddress: pushes contract address as u256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = .{ .bytes = [_]u8{0} ** 12 ++ [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe } };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAddress(&pc, &evm, &scope);
    const expected: u256 = 0xdeadbeefcafebabe;
    try std.testing.expectEqual(expected, scope.stack.peek().*);
}

test "opBalance: replaces address with account balance" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);

    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setBalance(allocator, address, 0x123456789abcdef0);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(std.mem.readInt(u256, &address_buf, .big));

    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opBalance(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x123456789abcdef0), scope.stack.peek().*);
}

test "opOrigin: pushes transaction origin as u256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setTxContext(.{
        .origin = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233"),
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opOrigin(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x00112233445566778899aabbccddeeff00112233), scope.stack.peek().*);
}

test "opCaller: pushes immediate caller as u256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.caller = try common.hexToAddress("0xaabbccddeeff0011223344556677889900112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCaller(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0xaabbccddeeff0011223344556677889900112233), scope.stack.peek().*);
}

test "opCallDataLoad: loads 32 bytes from calldata with zero padding" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.input = &[_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCallDataLoad(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0xdeadbeef00000000000000000000000000000000000000000000000000000000), scope.stack.peek().*);
}

test "opCallDataLoad: returns zero for out-of-range offset" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.input = &[_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(99);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCallDataLoad(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
}

test "opCallDataSize: pushes calldata length" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.input = "hello";
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCallDataSize(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 5), scope.stack.peek().*);
}

test "opAdd: 2 + 3 = 5" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);
    stack.push(3);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAdd(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 5), scope.stack.peek().*);
}

test "opAdd: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(std.math.maxInt(u256));
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAdd(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSub: 10 - 3 = 7" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3);
    stack.push(10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSub(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 7), scope.stack.peek().*);
}

test "opSub: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSub(&pc, &evm, &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opMul: 6 * 7 = 42" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(7);
    stack.push(6);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMul(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 42), scope.stack.peek().*);
}

test "opMul: wraps at 2^256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);
    stack.push(std.math.maxInt(u256));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMul(&pc, &evm, &scope);
    // maxInt(u256) * 2 = 2^257 - 2 ≡ 2^256 - 2 (mod 2^256)
    try std.testing.expectEqual(std.math.maxInt(u256) - 1, scope.stack.peek().*);
}

test "opDiv: 10 / 3 = 3" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3);
    stack.push(10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opDiv(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 3), scope.stack.peek().*);
}

test "opDiv: divide by zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opDiv(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSdiv: -10 / 3 = -3" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg10: u256 = @bitCast(@as(i256, -10));
    stack.push(3);
    stack.push(neg10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSdiv(&pc, &evm, &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -3), result);
}

test "opSdiv: divide by zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSdiv(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSdiv: INT256_MIN / -1 returns INT256_MIN" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const int256_min: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(neg1);
    stack.push(int256_min);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSdiv(&pc, &evm, &scope);
    try std.testing.expectEqual(int256_min, scope.stack.peek().*);
}

test "opMod: 10 % 3 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3);
    stack.push(10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMod: modulo by zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSmod: -10 % 3 = -1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg10: u256 = @bitCast(@as(i256, -10));
    stack.push(3);
    stack.push(neg10);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSmod(&pc, &evm, &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -1), result);
}

test "opSmod: modulo by zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAddmod: (2 + 3) % 4 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4); // z (modulus) — pushed first, deepest
    stack.push(3); // y
    stack.push(2); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAddmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opAddmod: overflow sum (maxInt + 1) % 2 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);                    // z
    stack.push(1);                    // y
    stack.push(std.math.maxInt(u256)); // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAddmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAddmod: modulus zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);  // z
    stack.push(3);  // y
    stack.push(2);  // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAddmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opMulmod: (3 * 5) % 7 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(7); // z (modulus)
    stack.push(5); // y
    stack.push(3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMulmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMulmod: overflow product (2^128 * 2^128) % 3 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    // 2^128 * 2^128 = 2^256, which overflows u256.
    // 2^256 mod 3: 2^256 = (2^2)^128 = 4^128 ≡ 1^128 = 1 (mod 3)
    const two_pow_128: u256 = 1 << 128;
    stack.push(3);
    stack.push(two_pow_128);
    stack.push(two_pow_128);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMulmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opMulmod: modulus zero returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0); // z
    stack.push(5); // y
    stack.push(3); // x
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opMulmod(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opExp: 2 ** 10 = 1024" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(10); // exponent
    stack.push(2);  // base — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opExp(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1024), scope.stack.peek().*);
}

test "opExp: x ** 0 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);  // exponent
    stack.push(42); // base
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opExp(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opExp: 2 ** 256 wraps to 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(256); // exponent
    stack.push(2);   // base
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opExp(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opStop returns StopToken" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();

    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();

    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);

    var scope = ScopeContext{
        .memory   = &memory,
        .stack    = &stack,
        .contract = &contract,
    };

    var pc: u64 = 0;
    // opStop ignores all arguments; any non-null evm pointer satisfies the type
    const result = opStop(&pc, &evm, &scope);
    try std.testing.expectError(error.StopToken, result);
}

test "opLt: 3 < 5 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(5); // y
    stack.push(3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opLt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opLt: 5 < 3 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3); // y
    stack.push(5); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opLt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opGt: 5 > 3 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3); // y
    stack.push(5); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opGt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opGt: 3 > 5 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(5); // y
    stack.push(3); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opGt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSlt: -1 < 1 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(1);    // y
    stack.push(neg1); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSlt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opSlt: 1 < -1 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(neg1); // y
    stack.push(1);    // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSlt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSgt: 1 > -1 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(neg1); // y
    stack.push(1);    // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSgt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opSgt: -1 > 1 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(1);    // y
    stack.push(neg1); // x — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSgt(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opEq: 42 == 42 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(42);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opEq(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opEq: 1 == 2 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opEq(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opIszero: 0 = 1" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opIszero(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 1), scope.stack.peek().*);
}

test "opIszero: 42 = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opIszero(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opAnd: 0xF0 & 0xFF = 0xF0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xFF);
    stack.push(0xF0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opAnd(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0xF0), scope.stack.peek().*);
}

test "opOr: 0xF0 | 0x0F = 0xFF" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x0F);
    stack.push(0xF0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opOr(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0xFF), scope.stack.peek().*);
}

test "opXor: 0xFF ^ 0xF0 = 0x0F" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xF0);
    stack.push(0xFF);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opXor(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0x0F), scope.stack.peek().*);
}

test "opNot: ~0 = maxInt(u256)" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opNot(&pc, &evm, &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opNot: ~maxInt(u256) = 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(std.math.maxInt(u256));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opNot(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opByte: byte 31 of 0x42 = 0x42" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x42); // val
    stack.push(31);   // th — top (LSB is byte 31)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opByte(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0x42), scope.stack.peek().*);
}

test "opByte: th >= 32 returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xFF); // val
    stack.push(32);   // th — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opByte(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opShl: 1 << 1 = 2" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1); // val
    stack.push(1); // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opShl(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 2), scope.stack.peek().*);
}

test "opShl: shift >= 256 returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);   // val
    stack.push(256); // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opShl(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opShr: 4 >> 1 = 2" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4); // val
    stack.push(1); // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opShr(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 2), scope.stack.peek().*);
}

test "opShr: shift >= 256 returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xFF); // val
    stack.push(256);  // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opShr(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opSar: -4 >> 1 = -2 (sign extending)" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg4: u256 = @bitCast(@as(i256, -4));
    stack.push(neg4); // val
    stack.push(1);    // shift — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSar(&pc, &evm, &scope);
    const result: i256 = @bitCast(scope.stack.peek().*);
    try std.testing.expectEqual(@as(i256, -2), result);
}

test "opSar: shift >= 256 with negative value returns all-ones" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const neg1: u256 = @bitCast(@as(i256, -1));
    stack.push(neg1); // val (negative)
    stack.push(256);  // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSar(&pc, &evm, &scope);
    try std.testing.expectEqual(std.math.maxInt(u256), scope.stack.peek().*);
}

test "opSar: shift >= 256 with positive value returns 0" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(42);  // val (positive)
    stack.push(256); // shift — out of range
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opSar(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opClz: 0 has 256 leading zeros" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opClz(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 256), scope.stack.peek().*);
}

test "opClz: 1 has 255 leading zeros" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opClz(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 255), scope.stack.peek().*);
}

test "opClz: maxInt(u256) has 0 leading zeros" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(std.math.maxInt(u256));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opClz(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u256, 0), scope.stack.peek().*);
}

test "opKeccak256: hash of empty data" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    // size=0, offset=0 — no memory expansion needed
    stack.push(0); // size
    stack.push(0); // offset — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opKeccak256(&pc, &evm, &scope);
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try std.testing.expectEqual(expected, scope.stack.peek().*);
}

test "opKeccak256: hash of known data" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try memory.resize(input.len);
    memory.set(0, input.len, &input);
    stack.push(input.len); // size
    stack.push(0);         // offset — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opKeccak256(&pc, &evm, &scope);
    // compute expected hash independently
    var expected_buf: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&input, &expected_buf, .{});
    const expected = std.mem.readInt(u256, &expected_buf, .big);
    try std.testing.expectEqual(expected, scope.stack.peek().*);
}
