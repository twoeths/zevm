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

pub const Evm = struct {
    allocator: std.mem.Allocator,
    state_db: *StateDB,
    jump_table: *const jump_table.JumpTable,
    jump_dests: JumpDestCache,
    tx_context: TxContext = .{},

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

    pub fn setTxContext(self: *Evm, tx_context: TxContext) void {
        self.tx_context = tx_context;
    }
};
