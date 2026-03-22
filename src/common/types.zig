const std = @import("std");
const bytes = @import("bytes.zig");

pub const hash_length: usize = 32;
pub const address_length: usize = 20;
pub const hash_hex_length: usize = 2 + hash_length * 2;
pub const address_hex_length: usize = 2 + address_length * 2;

pub const Hash = struct {
    bytes: [hash_length]u8 = [_]u8{0} ** hash_length,

    pub fn init(input: []const u8) Hash {
        var hash = Hash{};
        hash.setBytes(input);
        return hash;
    }

    pub fn fromHex(input: []const u8) !Hash {
        var out: [hash_length]u8 = [_]u8{0} ** hash_length;
        try hexIntoHash(&out, input);
        return .{ .bytes = out };
    }

    pub fn cmp(self: Hash, other: Hash) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn asBytes(self: *const Hash) []const u8 {
        return &self.bytes;
    }

    pub fn setBytes(self: *Hash, input: []const u8) void {
        @memset(&self.bytes, 0);
        const truncated = if (input.len > hash_length) input[input.len - hash_length ..] else input;
        @memcpy(self.bytes[hash_length - truncated.len ..], truncated);
    }

    pub fn hex(self: Hash) [hash_hex_length]u8 {
        var out: [hash_hex_length]u8 = undefined;
        self.intoHex(&out);
        return out;
    }

    pub fn intoHex(self: Hash, out: *[hash_hex_length]u8) void {
        out[0] = '0';
        out[1] = 'x';
        _ = bytes.bytesIntoHex(out[2..], &self.bytes) catch unreachable;
    }
};

pub const Address = struct {
    bytes: [address_length]u8 = [_]u8{0} ** address_length,

    pub fn init(input: []const u8) Address {
        var address = Address{};
        address.setBytes(input);
        return address;
    }

    pub fn fromHex(input: []const u8) !Address {
        var out: [address_length]u8 = [_]u8{0} ** address_length;
        try hexIntoAddress(&out, input);
        return .{ .bytes = out };
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

    pub fn hex(self: Address) [address_hex_length]u8 {
        var out: [address_hex_length]u8 = undefined;
        self.intoHex(&out);
        return out;
    }

    pub fn intoHex(self: Address, out: *[address_hex_length]u8) void {
        out.* = checksumHex(self);
    }

    pub fn checksumHex(self: Address) [address_hex_length]u8 {
        var buf: [address_hex_length]u8 = undefined;
        toLowerHex(&buf, self);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(buf[2..], &digest, .{});

        var i: usize = 2;
        while (i < buf.len) : (i += 1) {
            var nibble = digest[(i - 2) / 2];
            if (i % 2 == 0) {
                nibble >>= 4;
            } else {
                nibble &= 0x0f;
            }

            if (buf[i] > '9' and nibble > 7) {
                buf[i] -= 32;
            }
        }
        return buf;
    }
};

pub fn bytesToAddress(input: []const u8) Address {
    return Address.init(input);
}

pub fn bytesToHash(input: []const u8) Hash {
    return Hash.init(input);
}

pub fn hexToHash(input: []const u8) !Hash {
    return try Hash.fromHex(input);
}

pub fn hexIntoHash(out: *[hash_length]u8, input: []const u8) !void {
    const normalized = if (bytes.has0xPrefix(input)) input[2..] else input;
    if (normalized.len > hash_length * 2) {
        _ = try bytes.hexIntoBytes(out, normalized[normalized.len - hash_length * 2 ..]);
        return;
    }

    @memset(out, 0);
    const start = hash_length - normalized.len / 2;
    _ = try bytes.hexIntoBytes(out[start..], normalized);
}

pub fn hexToAddress(input: []const u8) !Address {
    return try Address.fromHex(input);
}

pub fn hexIntoAddress(out: *[address_length]u8, input: []const u8) !void {
    const normalized = if (bytes.has0xPrefix(input)) input[2..] else input;
    if (normalized.len > address_length * 2) {
        _ = try bytes.hexIntoBytes(out, normalized[normalized.len - address_length * 2 ..]);
        return;
    }

    @memset(out, 0);
    const start = address_length - normalized.len / 2;
    _ = try bytes.hexIntoBytes(out[start..], normalized);
}

pub fn isHexHash(input: []const u8) bool {
    const normalized = if (bytes.has0xPrefix(input)) input[2..] else input;
    return normalized.len == hash_length * 2 and bytes.isHex(normalized);
}

pub fn isHexAddress(input: []const u8) bool {
    const normalized = if (bytes.has0xPrefix(input)) input[2..] else input;
    return normalized.len == address_length * 2 and bytes.isHex(normalized);
}

fn toLowerHex(out: *[address_hex_length]u8, address: Address) void {
    out[0] = '0';
    out[1] = 'x';
    _ = bytes.bytesIntoHex(out[2..], &address.bytes) catch unreachable;
}

test "bytesToHash crops from the left" {
    const input = [_]u8{0xbb} ** 33;
    const hash = bytesToHash(&input);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xbb} ** 32, hash.asBytes());
}

test "hexToHash decodes prefixed input" {
    const hash = try hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        },
        hash.asBytes(),
    );
}

test "hash hex returns lower-case 0x-prefixed string" {
    const hash = try hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    const hex = hash.hex();

    try std.testing.expectEqualStrings("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", &hex);
}

test "hash intoHex writes into caller buffer" {
    const hash = try hexToHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var out: [hash_hex_length]u8 = undefined;
    hash.intoHex(&out);
    try std.testing.expectEqualStrings("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", &out);
}

test "isHexHash validates shape" {
    try std.testing.expect(isHexHash("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    try std.testing.expect(isHexHash("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    try std.testing.expect(!isHexHash("0xabc"));
    try std.testing.expect(!isHexHash("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
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
    const address = try hexToAddress("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    const hex = address.hex();

    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &hex);
}

test "address intoHex writes into caller buffer" {
    const address = try hexToAddress("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    var out: [address_hex_length]u8 = undefined;
    address.intoHex(&out);
    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &out);
}

test "isHexAddress validates shape" {
    try std.testing.expect(isHexAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"));
    try std.testing.expect(isHexAddress("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"));
    try std.testing.expect(!isHexAddress("0xabc"));
    try std.testing.expect(!isHexAddress("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}
