pub const bytes = @import("bytes.zig");
pub const types = @import("types.zig");
pub const Hash = types.Hash;
pub const Address = types.Address;
pub const bytesToHash = types.bytesToHash;
pub const bytesToAddress = types.bytesToAddress;
pub const hexToHash = types.hexToHash;
pub const hexToAddress = types.hexToAddress;
pub const isHexHash = types.isHexHash;
pub const isHexAddress = types.isHexAddress;

test {
    _ = @import("bytes.zig");
    _ = @import("types.zig");
}
