pub const bytes = @import("bytes.zig");
pub const types = @import("types.zig");
pub const Address = types.Address;
pub const bytesToAddress = types.bytesToAddress;
pub const hexToAddress = types.hexToAddress;
pub const isHexAddress = types.isHexAddress;

test {
    _ = @import("bytes.zig");
    _ = @import("types.zig");
}
