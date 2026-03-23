const std = @import("std");
const common = @import("common");
const CodeBitmap = @import("code_bitmap.zig").CodeBitmap;
const JumpDestCache = @import("jump_dest_cache.zig").JumpDestCache;
const Word = @import("stack.zig").Word;
const GasChangeReason = @import("tracing/gas_change_reason.zig").GasChangeReason;
// TODO zevm: move opcode constants into vm/opcodes.zig.
const JUMPDEST_OPCODE: u8 = 0x5b;

/// Contract represents an Ethereum contract in the state database. It contains
/// the contract code and calling arguments.
pub const Contract = struct {
    // TODO zevm: this allocator may not belong on Contract if instances are always consumer-owned.
    allocator: std.mem.Allocator,
    // `caller` is the account that initialized this contract. For delegated
    // calls this needs to remain the original caller rather than the immediate
    // parent frame.
    caller: common.Address = .{},
    address: common.Address = .{},

    // Aggregated result of JUMPDEST analysis.
    jump_dests: JumpDestCache = .{},
    // Locally cached result of JUMPDEST analysis.
    // In Zig this may either borrow storage owned by `jump_dests` or point at
    // contract-local allocated storage for initcode analysis, so ownership must
    // be tracked explicitly.
    analysis: ?CodeBitmap = null,
    // Go does not need this because the GC owns the lifetime of both cases.
    // Zig needs an explicit bit so `deinit` knows whether `analysis` should be
    // freed here or left to `jump_dests`.
    owns_analysis: bool = false,

    code: []const u8 = &.{},
    code_hash: common.Hash = .{},
    input: []const u8 = &.{},

    // Whether the execution frame represented by this object is a contract deployment.
    is_deployment: bool = false,
    is_system_call: bool = false,

    gas: u64 = 0,
    value: Word = 0,

    pub fn init(allocator: std.mem.Allocator) Contract {
        return .{
            .allocator = allocator,
            .jump_dests = JumpDestCache.init(),
        };
    }

    pub fn deinit(self: *Contract) void {
        if (self.owns_analysis) {
            self.analysis.?.deinit(self.allocator);
        }
        self.jump_dests.deinit(self.allocator);
        self.analysis = null;
        self.owns_analysis = false;
    }

    pub fn validJumpdest(self: *Contract, dest: Word) !bool {
        if (dest > std.math.maxInt(usize)) {
            return false;
        }
        const udest: usize = @intCast(dest);
        // PC cannot go beyond the code length.
        if (udest >= self.code.len) {
            return false;
        }
        // Only JUMPDEST opcodes are valid destinations.
        if (self.code[udest] != JUMPDEST_OPCODE) {
            return false;
        }
        return try self.isCode(udest);
    }

    /// useGas attempts to consume gas and returns true on success.
    pub fn useGas(self: *Contract, gas: u64, logger: anytype, reason: GasChangeReason) bool {
        _ = logger;
        _ = reason;

        if (self.gas < gas) {
            return false;
        }
        self.gas -= gas;
        return true;
    }

    /// refundGas refunds gas to the contract.
    pub fn refundGas(self: *Contract, gas: u64, logger: anytype, reason: GasChangeReason) void {
        _ = logger;
        _ = reason;

        if (gas == 0) {
            return;
        }
        self.gas += gas;
    }

    /// isCode returns true if the provided PC location is an actual opcode
    /// rather than PUSH-data.
    fn isCode(self: *Contract, udest: usize) !bool {
        // Do we already have an analysis laying around?
        if (self.analysis) |analysis| {
            return analysis.codeSegment(udest);
        }

        // If this is regular deployed code, store the analysis in the shared cache.
        if (self.code_hash.cmp(.{}) != .eq) {
            const analysis = if (self.jump_dests.load(self.code_hash)) |cached|
                cached
            else
                try self.jump_dests.parseAndStore(self.allocator, self.code_hash, self.code);
            self.analysis = analysis;
            return analysis.codeSegment(udest);
        }

        // Temporary initcode gets a contract-local analysis instead.
        const analysis = try CodeBitmap.fromCode(self.allocator, self.code);
        self.analysis = analysis;
        self.owns_analysis = true;
        return analysis.codeSegment(udest);
    }
};

test "useGas subtracts gas when enough balance exists" {
    var contract = Contract.init(std.testing.allocator);
    defer contract.deinit();
    contract.gas = 10;

    try std.testing.expect(contract.useGas(4, null, .CallOpCode));
    try std.testing.expectEqual(@as(u64, 6), contract.gas);
}

test "useGas leaves gas unchanged on insufficient balance" {
    var contract = Contract.init(std.testing.allocator);
    defer contract.deinit();
    contract.gas = 3;

    try std.testing.expect(!contract.useGas(4, null, .CallOpCode));
    try std.testing.expectEqual(@as(u64, 3), contract.gas);
}

test "refundGas adds gas and ignores zero refunds" {
    var contract = Contract.init(std.testing.allocator);
    defer contract.deinit();
    contract.gas = 5;

    contract.refundGas(0, null, .CallLeftOverRefunded);
    try std.testing.expectEqual(@as(u64, 5), contract.gas);

    contract.refundGas(7, null, .CallLeftOverRefunded);
    try std.testing.expectEqual(@as(u64, 12), contract.gas);
}

test "validJumpdest accepts opcode-space jumpdest from cached code hash analysis" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0xaa, JUMPDEST_OPCODE };
    const hash = try common.hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var contract = Contract.init(allocator);
    defer contract.deinit();
    contract.code = &code;
    contract.code_hash = hash;

    try std.testing.expect(try contract.validJumpdest(2));
    try std.testing.expect(contract.analysis != null);
}

test "validJumpdest rejects push-data jumpdest bytes" {
    const allocator = std.testing.allocator;
    var contract = Contract.init(allocator);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x61, JUMPDEST_OPCODE, 0x00 };

    try std.testing.expect(!(try contract.validJumpdest(1)));
    try std.testing.expect(contract.analysis != null);
}

test "validJumpdest computes local analysis for initcode" {
    const allocator = std.testing.allocator;
    var contract = Contract.init(allocator);
    defer contract.deinit();
    contract.code = &[_]u8{ 0x60, 0xaa, JUMPDEST_OPCODE };

    try std.testing.expect(try contract.validJumpdest(2));
    try std.testing.expect(contract.owns_analysis);
}
