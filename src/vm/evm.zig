const std = @import("std");
const common = @import("common");
const Word = @import("stack.zig").Word;
const JumpDestCache = @import("jump_dest_cache.zig").JumpDestCache;
const StateDB = @import("state_db.zig").StateDB;
const jump_table = @import("jump_table.zig");

pub const Evm = struct {
    allocator: std.mem.Allocator,
    state_db: *StateDB,
    jump_table: *const jump_table.JumpTable,
    jump_dests: JumpDestCache,

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

    pub fn getBalance(self: *const Evm, address: common.Address) Word {
        return self.state_db.getBalance(address);
    }
};
