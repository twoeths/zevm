const std = @import("std");
const fmt = std.fmt;

pub fn fromHex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var hex = input;
    if (has0xPrefix(hex)) {
        hex = hex[2..];
    }

    if (hex.len % 2 == 1) {
        const prefixed = try allocator.alloc(u8, hex.len + 1);
        prefixed[0] = '0';
        @memcpy(prefixed[1..], hex);
        defer allocator.free(prefixed);
        return try hexToBytes(allocator, prefixed);
    }

    return try hexToBytes(allocator, hex);
}

pub fn copyBytes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return try allocator.dupe(u8, input);
}

pub fn has0xPrefix(input: []const u8) bool {
    return input.len >= 2 and input[0] == '0' and (input[1] == 'x' or input[1] == 'X');
}

pub fn isHexCharacter(c: u8) bool {
    return ('0' <= c and c <= '9') or ('a' <= c and c <= 'f') or ('A' <= c and c <= 'F');
}

pub fn isHex(input: []const u8) bool {
    if (input.len % 2 != 0) return false;
    for (input) |c| {
        if (!isHexCharacter(c)) return false;
    }
    return true;
}

pub fn bytesToHex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return try fmt.allocPrint(allocator, "{x}", .{fmt.fmtSliceHexLower(input)});
}

pub fn hexToBytes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len / 2);
    errdefer allocator.free(out);
    _ = try fmt.hexToBytes(out, input);
    return out;
}

pub fn hexToBytesFixed(allocator: std.mem.Allocator, input: []const u8, fixed_len: usize) ![]u8 {
    const decoded = try hexToBytes(allocator, input);
    defer allocator.free(decoded);

    const out = try allocator.alloc(u8, fixed_len);
    @memset(out, 0);

    if (decoded.len >= fixed_len) {
        @memcpy(out, decoded[decoded.len - fixed_len ..]);
    } else {
        @memcpy(out[fixed_len - decoded.len ..], decoded);
    }

    return out;
}

pub fn parseHexOrString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!has0xPrefix(input)) {
        return try copyBytes(allocator, input);
    }

    return try fromHex(allocator, input);
}

pub fn rightPadBytes(allocator: std.mem.Allocator, input: []const u8, len: usize) ![]u8 {
    if (len <= input.len) {
        return try copyBytes(allocator, input);
    }

    const out = try allocator.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..input.len], input);
    return out;
}

pub fn leftPadBytes(allocator: std.mem.Allocator, input: []const u8, len: usize) ![]u8 {
    if (len <= input.len) {
        return try copyBytes(allocator, input);
    }

    const out = try allocator.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[len - input.len ..], input);
    return out;
}

pub fn trimLeftZeroes(input: []const u8) []const u8 {
    var idx: usize = 0;
    while (idx < input.len and input[idx] == 0) : (idx += 1) {}
    return input[idx..];
}

pub fn trimRightZeroes(input: []const u8) []const u8 {
    var idx: usize = input.len;
    while (idx > 0 and input[idx - 1] == 0) : (idx -= 1) {}
    return input[0..idx];
}

test "fromHex supports prefix and odd length" {
    const allocator = std.testing.allocator;

    const a = try fromHex(allocator, "0xabc");
    defer allocator.free(a);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0a, 0xbc }, a);

    const b = try fromHex(allocator, "ff");
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, b);
}

test "bytesToHex and hexToBytes roundtrip" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    const hex = try bytesToHex(allocator, &input);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("deadbeef", hex);

    const decoded = try hexToBytes(allocator, hex);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "hexToBytesFixed truncates and left pads" {
    const allocator = std.testing.allocator;

    const truncated = try hexToBytesFixed(allocator, "aabbcc", 2);
    defer allocator.free(truncated);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xcc }, truncated);

    const padded = try hexToBytesFixed(allocator, "aa", 4);
    defer allocator.free(padded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0xaa }, padded);
}

test "parseHexOrString falls back to raw bytes without prefix" {
    const allocator = std.testing.allocator;

    const raw = try parseHexOrString(allocator, "hello");
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("hello", raw);

    const decoded = try parseHexOrString(allocator, "0x6869");
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'h', 'i' }, decoded);
}

test "padding and trimming helpers" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x01, 0x02 };

    const right = try rightPadBytes(allocator, &input, 4);
    defer allocator.free(right);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x00, 0x00 }, right);

    const left = try leftPadBytes(allocator, &input, 4);
    defer allocator.free(left);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01, 0x02 }, left);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x00 }, trimLeftZeroes(&[_]u8{ 0x00, 0x00, 0x01, 0x02, 0x00 }));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01, 0x02 }, trimRightZeroes(&[_]u8{ 0x00, 0x00, 0x01, 0x02, 0x00, 0x00 }));
}

test "hex predicates" {
    try std.testing.expect(has0xPrefix("0x01"));
    try std.testing.expect(has0xPrefix("0X01"));
    try std.testing.expect(!has0xPrefix("01"));
    try std.testing.expect(isHex("abcdEF12"));
    try std.testing.expect(!isHex("abc"));
    try std.testing.expect(!isHex("zz"));
}
