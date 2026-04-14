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
    // The transaction's versioned blob hashes, indexed by BLOBHASH.
    blob_hashes: []const common.Hash = &.{},
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
    // The current blob base fee per blob gas unit.
    blob_base_fee: u256 = 0,
    // The current block difficulty (or opcode 0x44 source before Merge semantics change).
    difficulty: u256 = 0,
    // The randomness value exposed by PREVRANDAO/RANDOM after Merge.
    random: ?common.Hash = null,
    // Optional host callback for resolving recent block hashes.
    get_hash_ctx: ?*anyopaque = null,
    get_hash_fn: ?GetHashFn = null,

    /// Resolve a recent block hash through the configured host callback.
    pub fn getHash(self: *const BlockContext, block_number: u64) common.Hash {
        const get_hash_fn = self.get_hash_fn orelse return .{};
        const get_hash_ctx = self.get_hash_ctx orelse return .{};
        return get_hash_fn(get_hash_ctx, block_number);
    }
};

/// Concrete execution environment shared by opcode implementations.
pub const Evm = struct {
    // Allocator used for VM-owned helper state such as jump destination caches.
    allocator: std.mem.Allocator,
    // Borrowed mutable world state used for account and storage access.
    state_db: *StateDB,
    // Selected fork-specific instruction metadata; shared and immutable.
    jump_table: *const jump_table.JumpTable,
    // VM-owned cache for analyzed jump destinations shared with contracts.
    jump_dests: JumpDestCache,
    // Chain-wide constants such as CHAINID.
    chain_config: ChainConfig = .{},
    // Per-block execution context such as number, fees, and randomness.
    block_context: BlockContext = .{},
    // Per-transaction execution context such as origin and gas price.
    tx_context: TxContext = .{},
    // Return buffer from the most recent external call-like opcode.
    return_data: []const u8 = &.{},
    // Whether state-modifying opcodes must reject writes for this execution.
    read_only: bool = false,
    // Whether execution should stop as soon as the interpreter observes it.
    abort: bool = false,

    /// Initialize an EVM for the selected fork while borrowing external state.
    pub fn init(allocator: std.mem.Allocator, state_db: *StateDB, fork: jump_table.Fork) Evm {
        return .{
            .allocator = allocator,
            .state_db = state_db,
            .jump_table = jump_table.instructionSetForFork(fork),
            .jump_dests = JumpDestCache.init(),
        };
    }

    /// Release VM-owned helper state. Borrowed state_db and jump_table are untouched.
    pub fn deinit(self: *Evm) void {
        self.jump_dests.deinit(self.allocator);
        self.* = undefined;
    }

    /// Load an account balance from StateDB.
    pub fn getBalance(self: *const Evm, address: common.Address) @import("stack.zig").Word {
        return self.state_db.getBalance(address);
    }

    /// Load the byte length of an account's code from StateDB.
    pub fn getCodeSize(self: *const Evm, address: common.Address) usize {
        return self.state_db.getCodeSize(address);
    }

    /// Load an account's code bytes from StateDB.
    pub fn getCode(self: *const Evm, address: common.Address) []const u8 {
        return self.state_db.getCode(address);
    }

    /// Load the code hash for an account from StateDB.
    pub fn getCodeHash(self: *const Evm, address: common.Address) common.Hash {
        return self.state_db.getCodeHash(address);
    }

    /// Load a storage value for an account and storage key from StateDB.
    /// Equivalent to `GetState` in go-ethereum (geth).
    pub fn getStorageValue(self: *const Evm, address: common.Address, storage_key: common.Hash) common.Hash {
        return self.state_db.getStorageValue(address, storage_key);
    }

    /// Load a transient storage value for an account and storage key from StateDB.
    /// Equivalent to `GetTransientState` in go-ethereum (geth).
    pub fn getTransientStorageValue(self: *const Evm, address: common.Address, storage_key: common.Hash) common.Hash {
        return self.state_db.getTransientStorageValue(address, storage_key);
    }

    /// Store a transient storage value for an account and storage key in StateDB.
    /// Equivalent to `SetTransientState` in go-ethereum (geth).
    pub fn setTransientStorageValue(self: *Evm, address: common.Address, storage_key: common.Hash, value: common.Hash) !void {
        try self.state_db.setTransientState(self.allocator, address, storage_key, value);
    }

    /// Store a storage value for an account and storage key in StateDB.
    /// Equivalent to `SetState` in go-ethereum (geth).
    pub fn setStorageValue(self: *Evm, address: common.Address, storage_key: common.Hash, value: common.Hash) !void {
        try self.state_db.setState(self.allocator, address, storage_key, value);
    }

    /// Report whether an account is empty under the current StateDB model.
    pub fn empty(self: *const Evm, address: common.Address) bool {
        return self.state_db.empty(address);
    }

    /// Replace the active transaction context.
    pub fn setTxContext(self: *Evm, tx_context: TxContext) void {
        self.tx_context = tx_context;
    }

    /// Replace the active block context.
    pub fn setBlockContext(self: *Evm, block_context: BlockContext) void {
        self.block_context = block_context;
    }

    /// Replace the active chain configuration.
    pub fn setChainConfig(self: *Evm, chain_config: ChainConfig) void {
        self.chain_config = chain_config;
    }

    /// Enable or disable read-only execution for state-modifying opcodes.
    pub fn setReadOnly(self: *Evm, read_only: bool) void {
        self.read_only = read_only;
    }

    /// Request that opcode execution stop at the next abort check.
    pub fn setAbort(self: *Evm, abort: bool) void {
        self.abort = abort;
    }
};
