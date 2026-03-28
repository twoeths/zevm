const std       = @import("std");
const OpCode    = @import("opcodes.zig").OpCode;
const stack_mod = @import("stack.zig");
const Stack     = stack_mod.Stack;
const Memory    = @import("memory.zig").Memory;
const Contract  = @import("contract.zig").Contract;
const ScopeContext = @import("interpreter.zig").ScopeContext;
const instructions = @import("instructions.zig");

/// Forward-declared opaque for the EVM context; replaced with a concrete type once evm.zig exists.
pub const Evm = anyopaque;

const ExecError = instructions.ExecError;

pub const ExecuteFn = *const fn (pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8;
pub const GasFn     = *const fn (evm: *Evm, contract: *Contract, stack: *Stack, mem: *Memory, mem_size: u64) anyerror!u64;

pub const MemorySize = struct { size: u64, overflow: bool };
pub const MemorySizeFn = *const fn (stack: *const Stack) MemorySize;

// ── Gas constants ─────────────────────────────────────────────────────────────

pub const gas_quick_step:   u64 = 2;
pub const gas_fastest_step: u64 = 3;
pub const gas_fastish_step: u64 = 4;
pub const gas_fast_step:    u64 = 5;
pub const gas_mid_step:     u64 = 8;
pub const gas_slow_step:    u64 = 10;
pub const gas_ext_step:     u64 = 20;
pub const gas_jumpdest:     u64 = 1;
pub const gas_sha3_base:    u64 = 30;
pub const gas_log_base:     u64 = 375;

// ── Stack helpers ─────────────────────────────────────────────────────────────

pub fn minStack(pops: u16, push: u16) u16 {
    _ = push;
    return pops;
}

pub fn maxStack(pop: u16, push: u16) u16 {
    return @as(u16, @intCast(stack_mod.max_size)) + pop - push;
}

pub fn minDupStack(n: u16) u16  { return minStack(n, n + 1); }
pub fn maxDupStack(n: u16) u16  { return maxStack(n, n + 1); }
pub fn minSwapStack(n: u16) u16 { return minStack(n + 1, n + 1); }
pub fn maxSwapStack(n: u16) u16 { return maxStack(n + 1, n + 1); }

// ── Sentinel functions ────────────────────────────────────────────────────────

/// Sentinel execute for inactive slots (byte not assigned to any opcode in this fork).
/// Discriminant: op.execute_fn == opUndefined → not a real opcode.
pub fn opUndefined(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm, scope };
    return error.InvalidOpcode;
}

/// Execute stub for defined opcodes whose logic is not yet written.
pub fn opNotImplemented(pc: *u64, evm: *Evm, scope: *ScopeContext) ExecError!?[]u8 {
    _ = .{ pc, evm, scope };
    @panic("opcode not yet implemented");
}

/// Sentinel GasFn for DynamicOp entries that have gas but no implementation yet.
fn gasNotImplemented(evm: *Evm, contract: *Contract, stack: *Stack, mem: *Memory, mem_size: u64) anyerror!u64 {
    _ = .{ evm, contract, stack, mem, mem_size };
    @panic("dynamic gas not yet implemented");
}

/// Sentinel MemorySizeFn for DynamicOp entries that have no memory expansion.
/// gas_fn receives mem_size = 0, matching go-ethereum's behaviour (memorySize == nil → memorySize = 0).
pub fn memorySizeZero(stack: *const Stack) MemorySize {
    _ = stack;
    return .{ .size = 0, .overflow = false };
}

/// Sentinel MemorySizeFn for DynamicOp entries that have memory expansion but no implementation yet.
fn memorySizeNotImplemented(stack: *const Stack) MemorySize {
    _ = stack;
    @panic("memory size not yet implemented");
}

// ── DynamicOp ─────────────────────────────────────────────────────────────────
//
// go-ethereum's interpreter computes memorySize inside the `dynamicGas != nil` block
// and passes it as the last argument to dynamicGas. The two functions are always used
// together; merging them into DynamicOp enforces that invariant at the type level.
//
// gas-only ops (EXP, SSTORE, …) set memory_size_fn = memorySizeZero (sentinel).
// gas + memory ops (MLOAD, CALL, …) provide a real memory_size_fn.

pub const DynamicOp = struct {
    gas_fn:         GasFn,
    memory_size_fn: MemorySizeFn = memorySizeZero,
};

// Module-level DynamicOp instances live in .rodata; referenced by pointer from comptime fork tables.
const dynamic_gas_only       = DynamicOp{ .gas_fn = gasNotImplemented };
const dynamic_gas_and_memory = DynamicOp{ .gas_fn = gasNotImplemented, .memory_size_fn = memorySizeNotImplemented };

// ── Operation ─────────────────────────────────────────────────────────────────
//
// Layout (32 bytes, @alignOf = 8):
//   offset  0: execute_fn   (8 bytes, *const fn)
//   offset  8: constant_gas (8 bytes, u64)
//   offset 16: dynamic_op   (8 bytes, ?*const DynamicOp — null pointer = no dynamic gas)
//   offset 24: min_stack    (2 bytes, u16)
//   offset 26: max_stack    (2 bytes, u16)
//   offset 28: [4 bytes tail padding]

pub const Operation = struct {
    execute_fn:   ExecuteFn,
    constant_gas: u64               = 0,
    dynamic_op:   ?*const DynamicOp = null,
    min_stack:    u16,
    max_stack:    u16,

    /// Returns true if this byte is an assigned opcode in the current fork.
    pub fn isActive(self: *const Operation) bool {
        return self.execute_fn != opUndefined;
    }
};

// ── JumpTable ─────────────────────────────────────────────────────────────────

pub const JumpTable = struct {
    table: [256]Operation,

    pub fn get(self: *const JumpTable, opcode: u8) *const Operation {
        return &self.table[opcode];
    }
};

// ── Inactive slot default ─────────────────────────────────────────────────────

const inactive = Operation{
    .execute_fn   = opUndefined,
    .constant_gas = 0,
    .dynamic_op   = null,
    .min_stack    = 0,
    .max_stack    = maxStack(0, 0),
};

// ── Comptime fork constants ───────────────────────────────────────────────────

pub const frontier: JumpTable = blk: {
    var t = [_]Operation{inactive} ** 256;

    t[@intFromEnum(OpCode.STOP)]       = .{ .execute_fn = instructions.opStop, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 0), .max_stack = maxStack(0, 0) };
    t[@intFromEnum(OpCode.ADD)]        = .{ .execute_fn = instructions.opAdd, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.MUL)]        = .{ .execute_fn = instructions.opMul, .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SUB)]        = .{ .execute_fn = instructions.opSub, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.DIV)]        = .{ .execute_fn = instructions.opDiv,  .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SDIV)]       = .{ .execute_fn = instructions.opSdiv, .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.MOD)]        = .{ .execute_fn = instructions.opMod,  .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SMOD)]       = .{ .execute_fn = instructions.opSmod, .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.ADDMOD)]     = .{ .execute_fn = instructions.opAddmod, .constant_gas = gas_mid_step,     .min_stack = minStack(3, 1), .max_stack = maxStack(3, 1) };
    t[@intFromEnum(OpCode.MULMOD)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_mid_step,     .min_stack = minStack(3, 1), .max_stack = maxStack(3, 1) };
    t[@intFromEnum(OpCode.EXP)]        = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .dynamic_op = &dynamic_gas_only,       .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SIGNEXTEND)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };

    t[@intFromEnum(OpCode.LT)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.GT)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SLT)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.SGT)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.EQ)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.ISZERO)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.AND)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.OR)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.XOR)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t[@intFromEnum(OpCode.NOT)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.BYTE)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };

    t[@intFromEnum(OpCode.KECCAK256)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_sha3_base, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };

    t[@intFromEnum(OpCode.ADDRESS)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.BALANCE)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step,    .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.ORIGIN)]       = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.CALLER)]       = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.CALLVALUE)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.CALLDATALOAD)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.CALLDATASIZE)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.CALLDATACOPY)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(3, 0), .max_stack = maxStack(3, 0) };
    t[@intFromEnum(OpCode.CODESIZE)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.CODECOPY)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(3, 0), .max_stack = maxStack(3, 0) };
    t[@intFromEnum(OpCode.GASPRICE)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.EXTCODESIZE)]  = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step,    .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.EXTCODECOPY)]  = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(4, 0), .max_stack = maxStack(4, 0) };

    t[@intFromEnum(OpCode.BLOCKHASH)]  = .{ .execute_fn = opNotImplemented, .constant_gas = gas_ext_step,   .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.COINBASE)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.TIMESTAMP)]  = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.NUMBER)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.DIFFICULTY)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.GASLIMIT)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };

    t[@intFromEnum(OpCode.POP)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(1, 0), .max_stack = maxStack(1, 0) };
    t[@intFromEnum(OpCode.MLOAD)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.MSTORE)]  = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t[@intFromEnum(OpCode.MSTORE8)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t[@intFromEnum(OpCode.SLOAD)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step,    .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t[@intFromEnum(OpCode.SSTORE)]  = .{ .execute_fn = opNotImplemented, .constant_gas = 0,                .dynamic_op = &dynamic_gas_only,       .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t[@intFromEnum(OpCode.JUMP)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_mid_step,     .min_stack = minStack(1, 0), .max_stack = maxStack(1, 0) };
    t[@intFromEnum(OpCode.JUMPI)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step,    .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t[@intFromEnum(OpCode.PC)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.MSIZE)]   = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.GAS)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t[@intFromEnum(OpCode.JUMPDEST)]= .{ .execute_fn = opNotImplemented, .constant_gas = gas_jumpdest,     .min_stack = minStack(0, 0), .max_stack = maxStack(0, 0) };

    // PUSH1..PUSH32
    for (0..32) |n| {
        t[0x60 + n] = .{
            .execute_fn   = opNotImplemented,
            .constant_gas = gas_fastest_step,
            .min_stack    = minStack(0, 1),
            .max_stack    = maxStack(0, 1),
        };
    }

    // DUP1..DUP16
    for (0..16) |n| {
        t[0x80 + n] = .{
            .execute_fn   = opNotImplemented,
            .constant_gas = gas_fastest_step,
            .min_stack    = minDupStack(@intCast(n + 1)),
            .max_stack    = maxDupStack(@intCast(n + 1)),
        };
    }

    // SWAP1..SWAP16
    for (0..16) |n| {
        t[0x90 + n] = .{
            .execute_fn   = opNotImplemented,
            .constant_gas = gas_fastest_step,
            .min_stack    = minSwapStack(@intCast(n + 1)),
            .max_stack    = maxSwapStack(@intCast(n + 1)),
        };
    }

    // LOG0..LOG4: 2+n pops, 0 push
    for (0..5) |n| {
        t[0xa0 + n] = .{
            .execute_fn   = opNotImplemented,
            .constant_gas = gas_log_base,
            .dynamic_op   = &dynamic_gas_and_memory,
            .min_stack    = minStack(@intCast(2 + n), 0),
            .max_stack    = maxStack(@intCast(2 + n), 0),
        };
    }

    t[@intFromEnum(OpCode.CREATE)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(3, 1), .max_stack = maxStack(3, 1) };
    t[@intFromEnum(OpCode.CALL)]        = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(7, 1), .max_stack = maxStack(7, 1) };
    t[@intFromEnum(OpCode.CALLCODE)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(7, 1), .max_stack = maxStack(7, 1) };
    t[@intFromEnum(OpCode.RETURN)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,.dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t[@intFromEnum(OpCode.INVALID)]     = .{ .execute_fn = opNotImplemented, .constant_gas = 0,             .min_stack = minStack(0, 0), .max_stack = maxStack(0, 0) };
    t[@intFromEnum(OpCode.SELFDESTRUCT)]= .{ .execute_fn = opNotImplemented, .constant_gas = gas_slow_step, .dynamic_op = &dynamic_gas_only,       .min_stack = minStack(1, 0), .max_stack = maxStack(1, 0) };

    break :blk JumpTable{ .table = t };
};

pub const homestead: JumpTable = blk: {
    var t = frontier;
    t.table[@intFromEnum(OpCode.DELEGATECALL)] = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = gas_fast_step,
        .dynamic_op   = &dynamic_gas_and_memory,
        .min_stack    = minStack(6, 1),
        .max_stack    = maxStack(6, 1),
    };
    break :blk t;
};

pub const tangerine_whistle: JumpTable = blk: {
    // EIP-150: gas repricing only, no new opcodes
    break :blk homestead;
};

pub const spurious_dragon: JumpTable = blk: {
    // EIP-158/160: no new opcodes
    break :blk tangerine_whistle;
};

pub const byzantium: JumpTable = blk: {
    var t = spurious_dragon;
    t.table[@intFromEnum(OpCode.RETURNDATASIZE)] = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = gas_quick_step,
        .min_stack    = minStack(0, 1),
        .max_stack    = maxStack(0, 1),
    };
    t.table[@intFromEnum(OpCode.RETURNDATACOPY)] = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = gas_fast_step,
        .dynamic_op   = &dynamic_gas_and_memory,
        .min_stack    = minStack(3, 0),
        .max_stack    = maxStack(3, 0),
    };
    t.table[@intFromEnum(OpCode.STATICCALL)] = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = gas_slow_step,
        .dynamic_op   = &dynamic_gas_and_memory,
        .min_stack    = minStack(6, 1),
        .max_stack    = maxStack(6, 1),
    };
    t.table[@intFromEnum(OpCode.REVERT)] = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = 0,
        .dynamic_op   = &dynamic_gas_and_memory,
        .min_stack    = minStack(2, 0),
        .max_stack    = maxStack(2, 0),
    };
    break :blk t;
};

pub const constantinople: JumpTable = blk: {
    var t = byzantium;
    t.table[@intFromEnum(OpCode.SHL)]         = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t.table[@intFromEnum(OpCode.SHR)]         = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t.table[@intFromEnum(OpCode.SAR)]         = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(2, 1), .max_stack = maxStack(2, 1) };
    t.table[@intFromEnum(OpCode.EXTCODEHASH)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_ext_step,     .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t.table[@intFromEnum(OpCode.CREATE2)]     = .{
        .execute_fn   = opNotImplemented,
        .constant_gas = gas_slow_step,
        .dynamic_op   = &dynamic_gas_and_memory,
        .min_stack    = minStack(4, 1),
        .max_stack    = maxStack(4, 1),
    };
    break :blk t;
};

pub const istanbul: JumpTable = blk: {
    var t = constantinople;
    t.table[@intFromEnum(OpCode.CHAINID)]     = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t.table[@intFromEnum(OpCode.SELFBALANCE)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,  .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    // EIP-1884: reprice BALANCE
    t.table[@intFromEnum(OpCode.BALANCE)].constant_gas = gas_slow_step;
    break :blk t;
};

pub const berlin: JumpTable = blk: {
    // EIP-2929: access list gas repricing, no new opcodes
    break :blk istanbul;
};

pub const london: JumpTable = blk: {
    var t = berlin;
    t.table[@intFromEnum(OpCode.BASEFEE)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    break :blk t;
};

pub const merge: JumpTable = blk: {
    // DIFFICULTY renamed to PREVRANDAO (EIP-4399): same byte 0x44, execute_fn changes when implemented
    break :blk london;
};

pub const shanghai: JumpTable = blk: {
    var t = merge;
    t.table[@intFromEnum(OpCode.PUSH0)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step, .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    break :blk t;
};

pub const cancun: JumpTable = blk: {
    var t = shanghai;
    t.table[@intFromEnum(OpCode.TLOAD)]       = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t.table[@intFromEnum(OpCode.TSTORE)]      = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fast_step,    .min_stack = minStack(2, 0), .max_stack = maxStack(2, 0) };
    t.table[@intFromEnum(OpCode.BLOBHASH)]    = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    t.table[@intFromEnum(OpCode.BLOBBASEFEE)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_quick_step,   .min_stack = minStack(0, 1), .max_stack = maxStack(0, 1) };
    t.table[@intFromEnum(OpCode.MCOPY)]       = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .dynamic_op = &dynamic_gas_and_memory, .min_stack = minStack(3, 0), .max_stack = maxStack(3, 0) };
    break :blk t;
};

pub const prague: JumpTable = blk: {
    // EIP-7702: no new opcodes in jump table
    break :blk cancun;
};

pub const osaka: JumpTable = blk: {
    var t = prague;
    t.table[@intFromEnum(OpCode.CLZ)] = .{ .execute_fn = opNotImplemented, .constant_gas = gas_fastest_step, .min_stack = minStack(1, 1), .max_stack = maxStack(1, 1) };
    break :blk t;
};

// ── Fork enum and runtime lookup ──────────────────────────────────────────────

pub const Fork = enum {
    Frontier,
    Homestead,
    TangerineWhistle,
    SpuriousDragon,
    Byzantium,
    Constantinople,
    Istanbul,
    Berlin,
    London,
    Merge,
    Shanghai,
    Cancun,
    Prague,
    Osaka,
};

/// Returns a pointer to the comptime-constant JumpTable for the given fork.
/// The table lives in .rodata — not heap, not stack — and is valid for the entire program lifetime.
pub fn instructionSetForFork(fork: Fork) *const JumpTable {
    return switch (fork) {
        .Frontier         => &frontier,
        .Homestead        => &homestead,
        .TangerineWhistle => &tangerine_whistle,
        .SpuriousDragon   => &spurious_dragon,
        .Byzantium        => &byzantium,
        .Constantinople   => &constantinople,
        .Istanbul         => &istanbul,
        .Berlin           => &berlin,
        .London           => &london,
        .Merge            => &merge,
        .Shanghai         => &shanghai,
        .Cancun           => &cancun,
        .Prague           => &prague,
        .Osaka            => &osaka,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Operation size is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Operation));
    try std.testing.expectEqual(@as(usize, 8),  @alignOf(Operation));
}

test "stack helpers return u16" {
    try std.testing.expectEqual(@as(u16, 2),    minStack(2, 1));
    try std.testing.expectEqual(@as(u16, 1025), maxStack(2, 1));    // 1024 + 2 - 1
    try std.testing.expectEqual(@as(u16, 1),    minDupStack(1));
    try std.testing.expectEqual(@as(u16, 1023), maxDupStack(1));    // 1024 + 1 - 2
    try std.testing.expectEqual(@as(u16, 2),    minSwapStack(1));
    try std.testing.expectEqual(@as(u16, 1024), maxSwapStack(1));   // 1024 + 2 - 2
}

test "inactive slots use opUndefined sentinel" {
    try std.testing.expect(!frontier.table[0x0c].isActive());
    try std.testing.expect(!frontier.table[0x21].isActive());
    try std.testing.expect(!frontier.table[0xee].isActive());
}

test "defined opcodes are active in frontier" {
    try std.testing.expect(frontier.table[@intFromEnum(OpCode.ADD)].isActive());
    try std.testing.expect(frontier.table[@intFromEnum(OpCode.JUMPDEST)].isActive());
    try std.testing.expect(frontier.table[@intFromEnum(OpCode.SELFDESTRUCT)].isActive());
}

test "ADD: constant gas, no dynamic_op" {
    const op = frontier.get(@intFromEnum(OpCode.ADD));
    try std.testing.expectEqual(gas_fastest_step, op.constant_gas);
    try std.testing.expectEqual(@as(u16, 2),    op.min_stack);
    try std.testing.expectEqual(@as(u16, 1025), op.max_stack);
    try std.testing.expect(op.dynamic_op == null);
}

test "EXP: has dynamic_op (gas only, no memory)" {
    const op = frontier.get(@intFromEnum(OpCode.EXP));
    try std.testing.expect(op.dynamic_op != null);
    try std.testing.expect(op.dynamic_op.?.memory_size_fn == memorySizeZero);
}

test "MLOAD: has dynamic_op with both gas and memory size" {
    const op = frontier.get(@intFromEnum(OpCode.MLOAD));
    try std.testing.expect(op.dynamic_op != null);
    try std.testing.expect(op.dynamic_op.?.memory_size_fn != memorySizeZero);
}

test "fork progression: PUSH0 inactive in frontier, active in shanghai" {
    try std.testing.expect(!frontier.table[@intFromEnum(OpCode.PUSH0)].isActive());
    try std.testing.expect(shanghai.table[@intFromEnum(OpCode.PUSH0)].isActive());
}

test "fork progression: TLOAD inactive in london, active in cancun" {
    try std.testing.expect(!london.table[@intFromEnum(OpCode.TLOAD)].isActive());
    try std.testing.expect(cancun.table[@intFromEnum(OpCode.TLOAD)].isActive());
}

test "fork progression: SHL inactive in frontier, active in constantinople" {
    try std.testing.expect(!frontier.table[@intFromEnum(OpCode.SHL)].isActive());
    try std.testing.expect(constantinople.table[@intFromEnum(OpCode.SHL)].isActive());
}

test "fork progression: DELEGATECALL inactive in frontier, active in homestead" {
    try std.testing.expect(!frontier.table[@intFromEnum(OpCode.DELEGATECALL)].isActive());
    try std.testing.expect(homestead.table[@intFromEnum(OpCode.DELEGATECALL)].isActive());
}

test "osaka has CLZ, prague does not" {
    try std.testing.expect(!prague.table[@intFromEnum(OpCode.CLZ)].isActive());
    try std.testing.expect(osaka.table[@intFromEnum(OpCode.CLZ)].isActive());
}

test "instructionSetForFork runtime lookup" {
    const jt = instructionSetForFork(.Cancun);
    try std.testing.expect(jt.table[@intFromEnum(OpCode.TLOAD)].isActive());
    try std.testing.expect(!jt.table[@intFromEnum(OpCode.CLZ)].isActive());
}
