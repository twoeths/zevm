const std = @import("std");
const bytes = @import("bytes.zig");

pub const address_length: usize = 20;

pub const Address = struct {
    bytes: [address_length]u8 = [_]u8{0} ** address_length,

    pub fn init(input: []const u8) Address {
        var address = Address{};
        address.setBytes(input);
        return address;
    }

    pub fn fromHex(input: []const u8) !Address {
        const decoded = try bytes.fromHex(std.heap.page_allocator, input);
        defer std.heap.page_allocator.free(decoded);
        return init(decoded);
    }

    pub fn cmp(self: Address, other: Address) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn asBytes(self: *const Address) []const u8 {
        return &self.bytes;
    }

    pub fn setBytes(self: *Address, input: []const u8) void {
        @memset(&self.bytes, 0);
        const truncated = if (input.len > address_length) input[input.len - address_length ..] else input;
        @memcpy(self.bytes[address_length - truncated.len ..], truncated);
    }

    pub fn hex(self: Address, allocator: std.mem.Allocator) ![]u8 {
        return try checksumHex(self, allocator);
    }

    pub fn checksumHex(self: Address, allocator: std.mem.Allocator) ![]u8 {
        var buf: [address_length * 2 + 2]u8 = undefined;
        toLowerHex(&buf, self);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(buf[2..], &digest, .{});

        var out = try allocator.dupe(u8, &buf);
        var i: usize = 2;
        while (i < out.len) : (i += 1) {
            var nibble = digest[(i - 2) / 2];
            if (i % 2 == 0) {
                nibble >>= 4;
            } else {
                nibble &= 0x0f;
            }

            if (out[i] > '9' and nibble > 7) {
                out[i] -= 32;
            }
        }
        return out;
    }
};

pub fn bytesToAddress(input: []const u8) Address {
    return Address.init(input);
}

pub fn hexToAddress(input: []const u8) !Address {
    return try Address.fromHex(input);
}

pub fn isHexAddress(input: []const u8) bool {
    const normalized = if (bytes.has0xPrefix(input)) input[2..] else input;
    return normalized.len == address_length * 2 and bytes.isHex(normalized);
}

fn toLowerHex(out: *[address_length * 2 + 2]u8, address: Address) void {
    out[0] = '0';
    out[1] = 'x';
    _ = std.fmt.bufPrint(out[2..], "{x}", .{std.fmt.fmtSliceHexLower(&address.bytes)}) catch unreachable;
}

test "bytesToAddress crops from the left" {
    const input = [_]u8{0xaa} ** 21;
    const address = bytesToAddress(&input);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 20, address.asBytes());
}

test "hexToAddress decodes prefixed input" {
    const address = try hexToAddress("0x00112233445566778899aabbccddeeff00112233");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33 },
        address.asBytes(),
    );
}

test "address hex returns EIP55 checksum" {
    const allocator = std.testing.allocator;
    const address = try hexToAddress("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    const hex = try address.hex(allocator);
    defer allocator.free(hex);

    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", hex);
}

test "isHexAddress validates shape" {
    try std.testing.expect(isHexAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"));
    try std.testing.expect(isHexAddress("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"));
    try std.testing.expect(!isHexAddress("0xabc"));
    try std.testing.expect(!isHexAddress("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}
