const std = @import("std");
const common = @import("common");
const Evm = @import("evm.zig").Evm;
const Fork = @import("jump_table.zig").Fork;
const ScopeContext = @import("interpreter.zig").ScopeContext;
const StateDB = @import("state_db.zig").StateDB;
const Word = @import("stack.zig").Word;

/// Typed error set for opcode execution functions.
/// Extended as new opcodes are implemented.
pub const ExecError = error{
    StopToken, // STOP, RETURN, SELFDESTRUCT — normal halt
    InvalidOpcode,
    InvalidJump,
    ReturnDataOutOfBounds,
    WriteProtection,
    OutOfMemory,
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
    const th = scope.stack.pop();
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
    const val = scope.stack.peek();
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
    const val = scope.stack.peek();
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
    const val = scope.stack.peek();
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
    const top = scope.stack.peek();
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &buf, top.*, .big);
    const address = common.bytesToAddress(buf[12..]);
    top.* = evm.getBalance(address);
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

/// CALLDATACOPY (0x37): copy calldata bytes into memory, zero-filling any missing tail.
pub fn opCallDataCopy(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const mem_offset = scope.stack.pop();
    const data_offset = scope.stack.pop();
    const length = scope.stack.pop();

    const mem_offset_usize: usize = @intCast(mem_offset);
    const length_usize: usize = @intCast(length);
    const dst = scope.memory.getPtr(mem_offset_usize, length_usize);
    @memset(dst, 0);

    if (data_offset > std.math.maxInt(usize) or length_usize == 0) {
        return null;
    }

    const data_offset_usize: usize = @intCast(data_offset);
    const input = scope.contract.input;
    if (data_offset_usize >= input.len) {
        return null;
    }

    const available = @min(length_usize, input.len - data_offset_usize);
    @memcpy(dst[0..available], input[data_offset_usize .. data_offset_usize + available]);
    return null;
}

/// CODESIZE (0x38): push the length of the currently executing contract bytecode.
/// Unlike EXTCODESIZE, this does not read an address from the stack or query state.
pub fn opCodeSize(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    scope.stack.push(scope.contract.code.len);
    return null;
}

/// CODECOPY (0x39): copy current contract bytecode into memory, zero-filling any missing tail.
pub fn opCodeCopy(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const mem_offset = scope.stack.pop();
    const code_offset = scope.stack.pop();
    const length = scope.stack.pop();

    const mem_offset_usize: usize = @intCast(mem_offset);
    const length_usize: usize = @intCast(length);
    const dst = scope.memory.getPtr(mem_offset_usize, length_usize);
    @memset(dst, 0);

    if (code_offset > std.math.maxInt(usize) or length_usize == 0) {
        return null;
    }

    const code_offset_usize: usize = @intCast(code_offset);
    const code = scope.contract.code;
    if (code_offset_usize >= code.len) {
        return null;
    }

    const available = @min(length_usize, code.len - code_offset_usize);
    @memcpy(dst[0..available], code[code_offset_usize .. code_offset_usize + available]);
    return null;
}

/// GASPRICE (0x3a): push the transaction gas price.
pub fn opGasprice(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    scope.stack.push(evm.tx_context.gas_price);
    return null;
}

/// EXTCODESIZE (0x3b): replace the top stack item address with that account's code length.
/// Unlike CODESIZE, this queries state for an arbitrary external address from the stack.
pub fn opExtCodeSize(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &buf, top.*, .big);
    const address = common.bytesToAddress(buf[12..]);
    top.* = evm.getCodeSize(address);
    return null;
}

/// EXTCODECOPY (0x3c): copy code from an address in state into memory, zero-filling any missing tail.
/// Unlike CODECOPY, this reads code for an arbitrary external address from the stack via state.
pub fn opExtCodeCopy(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const address_word = scope.stack.pop();
    const mem_offset = scope.stack.pop();
    const code_offset = scope.stack.pop();
    const length = scope.stack.pop();

    var address_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &address_buf, address_word, .big);
    const address = common.bytesToAddress(address_buf[12..]);

    const mem_offset_usize: usize = @intCast(mem_offset);
    const length_usize: usize = @intCast(length);
    const dst = scope.memory.getPtr(mem_offset_usize, length_usize);
    @memset(dst, 0);

    if (code_offset > std.math.maxInt(usize) or length_usize == 0) {
        return null;
    }

    const code_offset_usize: usize = @intCast(code_offset);
    const code = evm.getCode(address);
    if (code_offset_usize >= code.len) {
        return null;
    }

    const available = @min(length_usize, code.len - code_offset_usize);
    @memcpy(dst[0..available], code[code_offset_usize .. code_offset_usize + available]);
    return null;
}

/// RETURNDATASIZE (0x3d): push the byte length of the last call's return data buffer.
pub fn opReturnDataSize(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.return_data.len);
    return null;
}

/// RETURNDATACOPY (0x3e): copy bytes from the last call's return data into memory.
/// Returns ReturnDataOutOfBounds when the requested slice exceeds the available buffer.
pub fn opReturnDataCopy(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const mem_offset = scope.stack.pop();
    const data_offset = scope.stack.pop();
    const length = scope.stack.pop();

    if (data_offset > std.math.maxInt(usize)) {
        return error.ReturnDataOutOfBounds;
    }

    const data_offset_usize: usize = @intCast(data_offset);
    const length_usize: usize = @intCast(length);
    const end = std.math.add(usize, data_offset_usize, length_usize) catch {
        return error.ReturnDataOutOfBounds;
    };
    if (end > evm.return_data.len) {
        return error.ReturnDataOutOfBounds;
    }

    if (length_usize == 0) {
        return null;
    }

    scope.memory.set(@intCast(mem_offset), length_usize, evm.return_data[data_offset_usize..end]);
    return null;
}

/// EXTCODEHASH (0x3f): replace the top stack item address with that account's code hash.
/// Empty or non-existent accounts return zero; existing no-code accounts return the empty-code hash.
pub fn opExtCodeHash(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    var address_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &address_buf, top.*, .big);
    const address = common.bytesToAddress(address_buf[12..]);

    if (evm.empty(address)) {
        top.* = 0;
        return null;
    }

    const code_hash = evm.getCodeHash(address);
    top.* = std.mem.readInt(u256, &code_hash.bytes, .big);
    return null;
}

/// BLOCKHASH (0x40): replace the top stack item with the hash of a recent block.
/// Only the previous 256 blocks are queryable; current/future or older blocks return zero.
/// this is the "getBlockHashByNumber()" api
pub fn opBlockhash(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    if (top.* > std.math.maxInt(u64)) {
        top.* = 0;
        return null;
    }

    const requested = @as(u64, @intCast(top.*));
    const upper = evm.block_context.block_number;
    const lower: u64 = if (upper < 257) 0 else upper - 256;
    if (requested >= lower and requested < upper) {
        const hash = evm.block_context.getHash(requested);
        top.* = std.mem.readInt(u256, &hash.bytes, .big);
    } else {
        top.* = 0;
    }
    return null;
}

/// COINBASE (0x41): push the current block beneficiary address as a 32-byte word.
pub fn opCoinbase(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    var buf = [_]u8{0} ** 32;
    @memcpy(buf[12..], &evm.block_context.coinbase.bytes);
    scope.stack.push(std.mem.readInt(u256, &buf, .big));
    return null;
}

/// TIMESTAMP (0x42): push the current block timestamp.
pub fn opTimestamp(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.timestamp);
    return null;
}

/// NUMBER (0x43): push the current block number.
pub fn opNumber(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.block_number);
    return null;
}

/// DIFFICULTY (0x44): push the current block difficulty context value.
pub fn opDifficulty(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.difficulty);
    return null;
}

/// RANDOM/PREVRANDAO (0x44 after Merge): push the current randomness value.
pub fn opRandom(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    const random = evm.block_context.random orelse common.Hash{};
    scope.stack.push(std.mem.readInt(u256, &random.bytes, .big));
    return null;
}

/// GASLIMIT (0x45): push the current block gas limit.
pub fn opGasLimit(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.gas_limit);
    return null;
}

/// CHAINID (0x46): push the configured chain ID for this EVM.
pub fn opChainID(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.chain_config.chain_id);
    return null;
}

/// SELFBALANCE (0x47): push the balance of the currently executing contract.
pub fn opSelfBalance(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.getBalance(scope.contract.address));
    return null;
}

/// BASEFEE (0x48): push the current block base fee.
pub fn opBaseFee(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.base_fee);
    return null;
}

/// BLOBHASH (0x49): replace the top stack index with the corresponding versioned blob hash.
/// Out-of-range indices return zero.
pub fn opBlobHash(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    if (top.* > std.math.maxInt(usize)) {
        top.* = 0;
        return null;
    }

    const index: usize = @intCast(top.*);
    if (index >= evm.tx_context.blob_hashes.len) {
        top.* = 0;
        return null;
    }

    const blob_hash = evm.tx_context.blob_hashes[index];
    top.* = std.mem.readInt(u256, &blob_hash.bytes, .big);
    return null;
}

/// BLOBBASEFEE (0x4a): push the current blob base fee.
pub fn opBlobBaseFee(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, scope };
    scope.stack.push(evm.block_context.blob_base_fee);
    return null;
}

/// POP (0x50): discard the top stack item.
pub fn opPop(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    _ = scope.stack.pop();
    return null;
}

/// MLOAD (0x51): replace the top stack offset with the 32-byte word at that memory position.
pub fn opMload(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const top = scope.stack.peek();
    const offset: usize = @intCast(top.*);
    var word_buf: [32]u8 = undefined;
    @memcpy(&word_buf, scope.memory.getPtr(offset, 32));
    top.* = std.mem.readInt(u256, &word_buf, .big);
    return null;
}

/// MSTORE (0x52): pop memory offset and word value, then write the full 32-byte word to memory.
pub fn opMstore(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const m_start = scope.stack.pop();
    const val = scope.stack.pop();
    scope.memory.set32(@intCast(m_start), val);
    return null;
}

/// MSTORE8 (0x53): pop memory offset and value, then write only the low byte to memory.
pub fn opMstore8(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const offset = scope.stack.pop();
    const val = scope.stack.pop();
    scope.memory.getPtr(@intCast(offset), 1)[0] = @truncate(val);
    return null;
}

/// SLOAD (0x54): replace the top stack slot index with the stored 32-byte value for this contract.
pub fn opSload(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    var storage_key_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &storage_key_buf, top.*, .big);
    const storage_key = common.Hash{ .bytes = storage_key_buf };
    const value = evm.getStorageValue(scope.contract.address, storage_key);
    top.* = std.mem.readInt(u256, &value.bytes, .big);
    return null;
}

/// SSTORE (0x55): pop storage key and value, then write the 32-byte value for this contract.
/// Returns WriteProtection when the EVM is executing in read-only mode.
pub fn opSstore(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    if (evm.read_only) {
        return error.WriteProtection;
    }

    const storage_key_word = scope.stack.pop();
    const value_word = scope.stack.pop();

    var storage_key_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &storage_key_buf, storage_key_word, .big);
    const storage_key = common.Hash{ .bytes = storage_key_buf };

    var value_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &value_buf, value_word, .big);
    const value = common.Hash{ .bytes = value_buf };

    try evm.setStorageValue(scope.contract.address, storage_key, value);
    return null;
}

/// JUMP (0x56): pop a destination and set pc to that opcode if it is a valid JUMPDEST.
/// Returns StopToken when execution has been aborted and InvalidJump for bad destinations.
pub fn opJump(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    if (evm.abort) {
        return error.StopToken;
    }

    const pos = scope.stack.pop();
    if (!(try scope.contract.validJumpdest(pos))) {
        return error.InvalidJump;
    }

    pc.* = @as(u64, @intCast(pos)) - 1;
    return null;
}

/// JUMPI (0x57): pop a destination and condition, then jump only when the condition is non-zero.
/// Returns StopToken when execution has been aborted and InvalidJump for bad taken destinations.
pub fn opJumpi(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    if (evm.abort) {
        return error.StopToken;
    }

    const pos = scope.stack.pop();
    const cond = scope.stack.pop();
    if (cond != 0) {
        if (!(try scope.contract.validJumpdest(pos))) {
            return error.InvalidJump;
        }
        pc.* = @as(u64, @intCast(pos)) - 1;
    }

    return null;
}

/// TLOAD (0x5c): replace the top stack storage key with the transient storage value for this contract.
pub fn opTload(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    const top = scope.stack.peek();
    var storage_key_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &storage_key_buf, top.*, .big);
    const storage_key = common.Hash{ .bytes = storage_key_buf };
    const value = evm.getTransientStorageValue(scope.contract.address, storage_key);
    top.* = std.mem.readInt(u256, &value.bytes, .big);
    return null;
}

/// TSTORE (0x5d): pop storage key and value, then write the 32-byte transient value for this contract.
/// Returns WriteProtection when the EVM is executing in read-only mode.
pub fn opTstore(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = pc;
    if (evm.read_only) {
        return error.WriteProtection;
    }

    const storage_key_word = scope.stack.pop();
    const value_word = scope.stack.pop();

    var storage_key_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &storage_key_buf, storage_key_word, .big);
    const storage_key = common.Hash{ .bytes = storage_key_buf };

    var value_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &value_buf, value_word, .big);
    const value = common.Hash{ .bytes = value_buf };

    try evm.setTransientStorageValue(scope.contract.address, storage_key, value);
    return null;
}

/// MCOPY (0x5e): pop destination, source, and length, then copy bytes within memory.
pub fn opMcopy(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const dst = scope.stack.pop();
    const src = scope.stack.pop();
    const length = scope.stack.pop();
    scope.memory.copy(@intCast(dst), @intCast(src), @intCast(length));
    return null;
}

/// PUSH0 (0x5f): push a zero word onto the stack.
pub fn opPush0(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    scope.stack.push(0);
    return null;
}

/// Build a PUSH1..PUSH32 opcode implementation for the requested immediate byte size.
pub fn makePush(comptime push_byte_size: usize) fn (*u64, *Evm, *ScopeContext) ExecError!?[]u8 {
    return struct {
        fn op(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
            _ = evm;
            const code = scope.contract.code;
            const code_len = code.len;
            const start: usize = @min(code_len, @as(usize, @intCast(pc.* + 1)));
            const end: usize = @min(code_len, start + push_byte_size);

            var value: u256 = 0;
            for (code[start..end]) |byte| {
                value = (value << 8) | byte;
            }

            const missing = push_byte_size - (end - start);
            if (missing > 0) {
                value <<= @as(std.math.Log2Int(u256), @intCast(8 * missing));
            }

            scope.stack.push(value);
            pc.* += push_byte_size;
            return null;
        }
    }.op;
}

/// Build a DUP1..DUP16 opcode implementation for the requested stack depth.
pub fn makeDup(comptime size: usize) fn (*u64, *Evm, *ScopeContext) ExecError!?[]u8 {
    return struct {
        fn op(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
            _ = .{ pc, evm };
            scope.stack.dup(size);
            return null;
        }
    }.op;
}

/// Build a SWAP1..SWAP16 opcode implementation for the requested stack depth.
pub fn makeSwap(comptime size: usize) fn (*u64, *Evm, *ScopeContext) ExecError!?[]u8 {
    return struct {
        fn op(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
            _ = .{ pc, evm };
            scope.stack.swap(size);
            return null;
        }
    }.op;
}

/// Build a LOG0..LOG4 opcode implementation for the requested topic count.
pub fn makeLog(comptime size: usize) fn (*u64, *Evm, *ScopeContext) ExecError!?[]u8 {
    return struct {
        fn op(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
            _ = pc;
            if (evm.read_only) {
                return error.WriteProtection;
            }

            const memory_start = scope.stack.pop();
            const memory_size = scope.stack.pop();
            var topics = try evm.allocator.alloc(common.Hash, size);
            errdefer evm.allocator.free(topics);

            for (0..size) |i| {
                const topic_word = scope.stack.pop();
                var topic_buf = [_]u8{0} ** 32;
                std.mem.writeInt(u256, &topic_buf, topic_word, .big);
                topics[i] = .{ .bytes = topic_buf };
            }

            const data = try scope.memory.getCopy(evm.allocator, @intCast(memory_start), @intCast(memory_size));
            errdefer evm.allocator.free(data);

            try evm.addLog(.{
                .address = scope.contract.address,
                .topics = topics,
                .data = data,
                .block_number = evm.block_context.block_number,
            });
            return null;
        }
    }.op;
}

/// PC (0x58): push the current program counter.
pub fn opPc(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = evm;
    scope.stack.push(pc.*);
    return null;
}

/// MSIZE (0x59): push the current memory size in bytes.
pub fn opMsize(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    scope.stack.push(scope.memory.len());
    return null;
}

/// GAS (0x5a): push the remaining gas in the current contract frame.
pub fn opGas(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    scope.stack.push(scope.contract.gas);
    return null;
}

/// JUMPDEST (0x5b): no-op marker for valid jump destinations.
pub fn opJumpdest(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm, scope };
    return null;
}

// ── Hash ──────────────────────────────────────────────────────────────────────

/// KECCAK256 (0x20): pop offset, peek size, size = keccak256(memory[offset..offset+size]).
pub fn opKeccak256(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm };
    const offset = scope.stack.pop();
    const size = scope.stack.peek();
    const data = scope.memory.getPtr(@intCast(offset), @intCast(size.*));
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

test "opCallDataCopy: copies calldata into memory and zero-fills the tail" {
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
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(6); // length
    stack.push(1); // data offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCallDataCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00 }, memory.getPtr(0, 6));
}

test "opCallDataCopy: out-of-range data offset writes zero bytes" {
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
    try memory.resize(4);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4); // length
    stack.push(99); // data offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCallDataCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 4));
}

test "opCodeSize: pushes current contract code length" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCodeSize(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 4), scope.stack.peek().*);
}

test "opCodeCopy: copies contract code into memory and zero-fills the tail" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(6); // length
    stack.push(1); // code offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCodeCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0x5b, 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 6));
}

test "opCodeCopy: out-of-range code offset writes zero bytes" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(4);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4); // length
    stack.push(99); // code offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCodeCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 4));
}

test "opGasprice: pushes transaction gas price" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setTxContext(.{
        .origin = .{},
        .gas_price = 12345,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opGasprice(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 12345), scope.stack.peek().*);
}

test "opExtCodeSize: replaces address with account code size" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setCode(allocator, address, &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 });
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(std.mem.readInt(u256, &address_buf, .big));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeSize(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 4), scope.stack.peek().*);
}

test "opExtCodeCopy: copies external code into memory and zero-fills the tail" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setCode(allocator, address, &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 });
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(6); // length
    stack.push(1); // code offset
    stack.push(0); // mem offset
    stack.push(std.mem.readInt(u256, &address_buf, .big)); // address (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0x5b, 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 6));
}

test "opExtCodeCopy: out-of-range offset writes zero bytes" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setCode(allocator, address, &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 });
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(4);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(4); // length
    stack.push(99); // code offset
    stack.push(0); // mem offset
    stack.push(std.mem.readInt(u256, &address_buf, .big)); // address (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 4));
}

test "opReturnDataSize: pushes last return data length" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Byzantium);
    defer evm.deinit();
    evm.return_data = "hello";
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opReturnDataSize(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 5), scope.stack.peek().*);
}

test "opReturnDataCopy: copies return data into memory" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Byzantium);
    defer evm.deinit();
    evm.return_data = "hello";
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3); // length
    stack.push(1); // data offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opReturnDataCopy(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(u8, "ell", memory.getPtr(0, 3));
}

test "opReturnDataCopy: returns error on out-of-bounds slice" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Byzantium);
    defer evm.deinit();
    evm.return_data = "hello";
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(3); // length
    stack.push(4); // data offset
    stack.push(0); // mem offset (top)
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.ReturnDataOutOfBounds, opReturnDataCopy(&pc, &evm, &scope));
}

test "opExtCodeHash: replaces address with external account code hash" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const code = [_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    try state_db.setCode(allocator, address, &code);
    var evm = initTestEvm(allocator, &state_db, .Constantinople);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(std.mem.readInt(u256, &address_buf, .big));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeHash(&pc, &evm, &scope);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &expected_hash, .{});
    try std.testing.expectEqual(std.mem.readInt(u256, &expected_hash, .big), scope.stack.peek().*);
}

test "opExtCodeHash: empty account returns zero" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var evm = initTestEvm(allocator, &state_db, .Constantinople);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(std.mem.readInt(u256, &address_buf, .big));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeHash(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
}

test "opExtCodeHash: funded no-code account returns empty code hash" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setBalance(allocator, address, 1);
    var evm = initTestEvm(allocator, &state_db, .Constantinople);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var address_buf = [_]u8{0} ** 32;
    @memcpy(address_buf[12..], &address.bytes);
    stack.push(std.mem.readInt(u256, &address_buf, .big));
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opExtCodeHash(&pc, &evm, &scope);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&.{}, &expected_hash, .{});
    try std.testing.expectEqual(std.mem.readInt(u256, &expected_hash, .big), scope.stack.peek().*);
}

test "opBlockhash: returns hash for recent block" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    const HashCtx = struct {
        expected_block: u64,
        hash: common.Hash,

        fn getHash(ctx: *anyopaque, block_number: u64) common.Hash {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.testing.expectEqual(self.expected_block, block_number) catch unreachable;
            return self.hash;
        }
    };

    var hash_ctx = HashCtx{
        .expected_block = 99,
        .hash = try common.hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
    };
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .block_number = 100,
        .get_hash_ctx = &hash_ctx,
        .get_hash_fn = HashCtx.getHash,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(99);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlockhash(&pc, &evm, &scope);
    try std.testing.expectEqual(std.mem.readInt(u256, &hash_ctx.hash.bytes, .big), scope.stack.peek().*);
}

test "opBlockhash: current block returns zero" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{ .block_number = 100 });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(100);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlockhash(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
}

test "opBlockhash: older than 256 blocks returns zero" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{ .block_number = 300 });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(43);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlockhash(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
}

test "opCoinbase: pushes current block beneficiary as u256" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .coinbase = try common.hexToAddress("0xaabbccddeeff0011223344556677889900112233"),
        .block_number = 100,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opCoinbase(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0xaabbccddeeff0011223344556677889900112233), scope.stack.peek().*);
}

test "opTimestamp: pushes current block timestamp" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .timestamp = 1_710_000_000,
        .block_number = 100,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opTimestamp(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 1_710_000_000), scope.stack.peek().*);
}

test "opNumber: pushes current block number" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .timestamp = 1_710_000_000,
        .block_number = 12345678,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opNumber(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 12345678), scope.stack.peek().*);
}

test "opDifficulty: pushes current block difficulty" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .timestamp = 1_710_000_000,
        .block_number = 12345678,
        .difficulty = 0x123456789abcdef0,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opDifficulty(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x123456789abcdef0), scope.stack.peek().*);
}

test "opRandom: pushes merge randomness value" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Merge);
    defer evm.deinit();
    evm.setBlockContext(.{
        .timestamp = 1_710_000_000,
        .block_number = 12345678,
        .random = try common.hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opRandom(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff), scope.stack.peek().*);
}

test "opGasLimit: pushes current block gas limit" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{
        .block_number = 12345678,
        .gas_limit = 30_000_000,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opGasLimit(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 30_000_000), scope.stack.peek().*);
}

test "opChainID: pushes configured chain ID" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Istanbul);
    defer evm.deinit();
    evm.setChainConfig(.{
        .chain_id = 11155111,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opChainID(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 11155111), scope.stack.peek().*);
}

test "opSelfBalance: pushes current contract balance" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Istanbul);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try state_db.setBalance(allocator, contract.address, 0x123456789abcdef0);
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opSelfBalance(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x123456789abcdef0), scope.stack.peek().*);
}

test "opBaseFee: pushes current block base fee" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .London);
    defer evm.deinit();
    evm.setBlockContext(.{
        .base_fee = 0x123456789abcdef0123456789abcdef0,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBaseFee(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x123456789abcdef0123456789abcdef0), scope.stack.peek().*);
}

test "opBlobHash: replaces index with matching blob hash" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    evm.setTxContext(.{
        .blob_hashes = &[_]common.Hash{
            try common.hexToHash("0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"),
            try common.hexToHash("0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff"),
        },
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlobHash(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff), scope.stack.peek().*);
}

test "opBlobHash: clears top for out-of-range index" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    evm.setTxContext(.{
        .blob_hashes = &[_]common.Hash{
            try common.hexToHash("0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"),
        },
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlobHash(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
}

test "opBlobBaseFee: pushes current blob base fee" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    evm.setBlockContext(.{
        .blob_base_fee = 0xabcdef0123456789abcdef0123456789,
    });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opBlobBaseFee(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0xabcdef0123456789abcdef0123456789), scope.stack.peek().*);
}

test "opPop: removes the top stack item" {
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
    stack.push(0x11);
    stack.push(0x22);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opPop(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 0x11), scope.stack.peek().*);
}

test "opMload: loads 32 bytes from memory into the top stack item" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(64);
    memory.set(4, 32, &[_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    });
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opMload(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20), scope.stack.peek().*);
}

test "opMstore: writes a 32-byte word to memory" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(64);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20);
    stack.push(4);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opMstore(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    }, memory.getPtr(4, 32));
}

test "opMstore8: writes only the low byte to memory" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x1234);
    stack.push(3);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opMstore8(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00, 0x00 }, memory.getPtr(0, 8));
}

test "opSload: replaces slot index with stored contract value" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000042");
    const value = try common.hexToHash("0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff");
    try state_db.setState(allocator, contract.address, storage_key, value);
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opSload(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff), scope.stack.peek().*);
}

test "opSstore: writes storage for the current contract" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff);
    stack.push(0x42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opSstore(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());

    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000042");
    const expected = try common.hexToHash("0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff");
    try std.testing.expectEqualSlices(u8, expected.asBytes(), state_db.getStorageValue(contract.address, storage_key).asBytes());
}

test "opSstore: rejects writes in read-only mode" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setReadOnly(true);
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x99);
    stack.push(0x01);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.WriteProtection, opSstore(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 2), scope.stack.len());

    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000001");
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), state_db.getStorageValue(contract.address, storage_key).asBytes());
}

test "opJump: updates pc for a valid jumpdest" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(2);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opJump(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqual(@as(u64, 1), pc);
}

test "opJump: rejects an invalid jump destination" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.InvalidJump, opJump(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
}

test "opJump: returns StopToken when the evm is aborted" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setAbort(true);
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x5b };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 7;

    try std.testing.expectError(error.StopToken, opJump(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(u64, 7), pc);
}

test "opJumpi: updates pc when condition is non-zero and jumpdest is valid" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    stack.push(2);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opJumpi(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqual(@as(u64, 1), pc);
}

test "opJumpi: leaves pc unchanged when condition is zero" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 9;

    _ = try opJumpi(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqual(@as(u64, 9), pc);
}

test "opJumpi: rejects an invalid taken jump destination" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, 0x5b, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    stack.push(1);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.InvalidJump, opJumpi(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
}

test "opJumpi: returns StopToken when the evm is aborted" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setAbort(true);
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x5b };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(1);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 5;

    try std.testing.expectError(error.StopToken, opJumpi(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 2), scope.stack.len());
    try std.testing.expectEqual(@as(u64, 5), pc);
}

test "opTload: replaces storage key with transient storage value" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000042");
    const value = try common.hexToHash("0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff");
    try state_db.setTransientState(allocator, contract.address, storage_key, value);
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opTload(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(Word, 0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff), scope.stack.peek().*);
}

test "opTstore: writes transient storage for the current contract" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff);
    stack.push(0x42);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opTstore(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());

    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000042");
    const expected = try common.hexToHash("0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff");
    try std.testing.expectEqualSlices(u8, expected.asBytes(), state_db.getTransientStorageValue(contract.address, storage_key).asBytes());
}

test "opTstore: rejects writes in read-only mode" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    evm.setReadOnly(true);
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x99);
    stack.push(0x01);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.WriteProtection, opTstore(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 2), scope.stack.len());

    const storage_key = try common.hexToHash("0x0000000000000000000000000000000000000000000000000000000000000001");
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), state_db.getTransientStorageValue(contract.address, storage_key).asBytes());
}

test "opMcopy: copies bytes within memory" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Cancun);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(10);
    memory.set(0, 10, "abcdefghij");
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(4); // length
    stack.push(2); // src
    stack.push(5); // dst
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opMcopy(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqualSlices(u8, "abcdecdecj", memory.getPtr(0, 10));
}

test "opPush0: pushes zero onto the stack" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Shanghai);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xaa);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opPush0(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 2), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 0), scope.stack.peek().*);
    try std.testing.expectEqual(@as(Word, 0xaa), scope.stack.back(1).*);
}

test "makePush(1): pushes the next byte and advances pc" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xab, 0x00 };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makePush(1)(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 0xab), scope.stack.peek().*);
    try std.testing.expectEqual(@as(u64, 1), pc);
}

test "makePush(2): zero-pads missing immediate bytes at end of code" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x61, 0xab };
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makePush(2)(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 0xab00), scope.stack.peek().*);
    try std.testing.expectEqual(@as(u64, 2), pc);
}

test "makeDup(1): duplicates the top stack item" {
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
    stack.push(0x11);
    stack.push(0x22);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makeDup(1)(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 3), scope.stack.len());
    try std.testing.expectEqualSlices(Word, &[_]Word{ 0x11, 0x22, 0x22 }, scope.stack.items());
}

test "makeDup(3): duplicates the third item from the top" {
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
    stack.push(0xaa);
    stack.push(0xbb);
    stack.push(0xcc);
    stack.push(0xdd);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makeDup(3)(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 5), scope.stack.len());
    try std.testing.expectEqualSlices(Word, &[_]Word{ 0xaa, 0xbb, 0xcc, 0xdd, 0xbb }, scope.stack.items());
}

test "makeSwap(1): swaps the top item with the next item down" {
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
    stack.push(0x11);
    stack.push(0x22);
    stack.push(0x33);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makeSwap(1)(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(Word, &[_]Word{ 0x11, 0x33, 0x22 }, scope.stack.items());
}

test "makeSwap(3): swaps the top item with the fourth item from the top" {
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
    stack.push(0xaa);
    stack.push(0xbb);
    stack.push(0xcc);
    stack.push(0xdd);
    stack.push(0xee);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makeSwap(3)(&pc, &evm, &scope);
    try std.testing.expectEqualSlices(Word, &[_]Word{ 0xaa, 0xee, 0xcc, 0xdd, 0xbb }, scope.stack.items());
}

test "makeLog(2): emits a log with topics, data, and block number" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setBlockContext(.{ .block_number = 99 });
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.address = try common.hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(8);
    memory.set(0, 8, "eventful");
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa);
    stack.push(0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);
    stack.push(8);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try makeLog(2)(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 0), scope.stack.len());
    try std.testing.expectEqual(@as(usize, 1), state_db.getLogs().len);
    const log = state_db.getLogs()[0];
    try std.testing.expectEqual(contract.address, log.address);
    try std.testing.expectEqual(@as(u64, 99), log.block_number);
    try std.testing.expectEqual(@as(usize, 2), log.topics.len);
    try std.testing.expectEqualSlices(u8, "eventful", log.data);
    try std.testing.expectEqual(@as(common.Hash, try common.hexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")), log.topics[0]);
    try std.testing.expectEqual(@as(common.Hash, try common.hexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")), log.topics[1]);
}

test "makeLog(1): rejects logs in read-only mode" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    evm.setReadOnly(true);
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(1);
    memory.set(0, 1, "x");
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0x11);
    stack.push(1);
    stack.push(0);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    try std.testing.expectError(error.WriteProtection, makeLog(1)(&pc, &evm, &scope));
    try std.testing.expectEqual(@as(usize, 3), scope.stack.len());
    try std.testing.expectEqual(@as(usize, 0), state_db.getLogs().len);
}

test "opPc: pushes the current program counter" {
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
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 123;

    _ = try opPc(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 123), scope.stack.peek().*);
    try std.testing.expectEqual(@as(u64, 123), pc);
}

test "opMsize: pushes the current memory size in bytes" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    try memory.resize(96);
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opMsize(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 96), scope.stack.peek().*);
}

test "opGas: pushes the current contract gas" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.gas = 50_000;
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;

    _ = try opGas(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 50_000), scope.stack.peek().*);
}

test "opJumpdest: is a no-op" {
    const allocator = std.testing.allocator;
    var state_db = StateDB.init();
    defer state_db.deinit(allocator);
    var evm = initTestEvm(allocator, &state_db, .Frontier);
    defer evm.deinit();
    var contract = @import("contract.zig").Contract.init(allocator, &evm.jump_dests);
    defer contract.deinit();
    contract.gas = 1234;
    var memory = @import("memory.zig").Memory.init(allocator);
    defer memory.deinit();
    var stack_buf: [@import("stack.zig").max_size]@import("stack.zig").Word = undefined;
    var stack = @import("stack.zig").Stack.init(&stack_buf);
    stack.push(0xaa);
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 17;

    _ = try opJumpdest(&pc, &evm, &scope);
    try std.testing.expectEqual(@as(u64, 17), pc);
    try std.testing.expectEqual(@as(usize, 1), scope.stack.len());
    try std.testing.expectEqual(@as(Word, 0xaa), scope.stack.peek().*);
    try std.testing.expectEqual(@as(usize, 0), scope.memory.len());
    try std.testing.expectEqual(@as(u64, 1234), contract.gas);
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
    stack.push(2); // z
    stack.push(1); // y
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
    stack.push(0); // z
    stack.push(3); // y
    stack.push(2); // x
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
    stack.push(2); // base — top
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
    stack.push(0); // exponent
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
    stack.push(2); // base
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
        .memory = &memory,
        .stack = &stack,
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
    stack.push(1); // y
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
    stack.push(1); // x — top
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
    stack.push(1); // x — top
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
    stack.push(1); // y
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
    stack.push(31); // th — top (LSB is byte 31)
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
    stack.push(32); // th — out of range
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
    stack.push(1); // val
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
    stack.push(256); // shift — out of range
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
    stack.push(1); // shift — top
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
    stack.push(256); // shift — out of range
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
    stack.push(42); // val (positive)
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
    stack.push(0); // offset — top
    var scope = ScopeContext{ .memory = &memory, .stack = &stack, .contract = &contract };
    var pc: u64 = 0;
    _ = try opKeccak256(&pc, &evm, &scope);
    // compute expected hash independently
    var expected_buf: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&input, &expected_buf, .{});
    const expected = std.mem.readInt(u256, &expected_buf, .big);
    try std.testing.expectEqual(expected, scope.stack.peek().*);
}
