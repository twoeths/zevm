const std = @import("std");
const common = @import("common");
const JumpDestCache = @import("jump_dest_cache.zig").JumpDestCache;
const StateDB = @import("state_db.zig").StateDB;
const jump_table = @import("jump_table.zig");

pub const TxContext = struct {
    // The externally-owned account that originated the transaction.
    origin: common.Address = .{},
    // The per-unit gas price paid by the transaction.
    gas_price: u256 = 0,
};

pub const ChainConfig = struct {
    // The chain ID used by the CHAINID opcode and replay protection.
    chain_id: u256 = 0,
};

pub const GetHashFn = *const fn (ctx: *anyopaque, block_number: u64) common.Hash;

pub const BlockContext = struct {
    // The current block beneficiary address.
    coinbase: common.Address = .{},
    // The current block timestamp.
    timestamp: u64 = 0,
    // The current block number for this execution.
    block_number: u64 = 0,
    // The current block gas limit.
    gas_limit: u64 = 0,
    // The current block base fee per gas unit.
    base_fee: u256 = 0,
    // The current block difficulty (or opcode 0x44 source before Merge semantics change).
    difficulty: u256 = 0,
    // The randomness value exposed by PREVRANDAO/RANDOM after Merge.
    random: ?common.Hash = null,
    // Optional host callback for resolving recent block hashes.
    get_hash_ctx: ?*anyopaque = null,
    get_hash_fn: ?GetHashFn = null,

    pub fn getHash(self: *const BlockContext, block_number: u64) common.Hash {
        const get_hash_fn = self.get_hash_fn orelse return .{};
        const get_hash_ctx = self.get_hash_ctx orelse return .{};
        return get_hash_fn(get_hash_ctx, block_number);
    }
};

pub const Evm = struct {
    allocator: std.mem.Allocator,
    state_db: *StateDB,
    jump_table: *const jump_table.JumpTable,
    jump_dests: JumpDestCache,
    chain_config: ChainConfig = .{},
    block_context: BlockContext = .{},
    tx_context: TxContext = .{},
    return_data: []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, state_db: *StateDB, fork: jump_table.Fork) Evm {
        return .{
            .allocator = allocator,
            .state_db = state_db,
            .jump_table = jump_table.instructionSetForFork(fork),
            .jump_dests = JumpDestCache.init(),
        };
    }

    pub fn deinit(self: *Evm) void {
        self.jump_dests.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getBalance(self: *const Evm, address: common.Address) @import("stack.zig").Word {
        return self.state_db.getBalance(address);
    }

    pub fn getCodeSize(self: *const Evm, address: common.Address) usize {
        return self.state_db.getCodeSize(address);
    }

    pub fn getCode(self: *const Evm, address: common.Address) []const u8 {
        return self.state_db.getCode(address);
    }

    pub fn getCodeHash(self: *const Evm, address: common.Address) common.Hash {
        return self.state_db.getCodeHash(address);
    }

    pub fn empty(self: *const Evm, address: common.Address) bool {
        return self.state_db.empty(address);
    }

    pub fn setTxContext(self: *Evm, tx_context: TxContext) void {
        self.tx_context = tx_context;
    }

    pub fn setBlockContext(self: *Evm, block_context: BlockContext) void {
        self.block_context = block_context;
    }

    pub fn setChainConfig(self: *Evm, chain_config: ChainConfig) void {
        self.chain_config = chain_config;
    }
};
