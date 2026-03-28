const std = @import("std");

const OpCode = @import("opcodes.zig").OpCode;
const push1: u8  = @intFromEnum(OpCode.PUSH1);
const push32: u8 = @intFromEnum(OpCode.PUSH32);

const set_2_bits_mask: u16 = 0b11;
const set_3_bits_mask: u16 = 0b111;
const set_4_bits_mask: u16 = 0b1111;
const set_5_bits_mask: u16 = 0b1_1111;
const set_6_bits_mask: u16 = 0b11_1111;
const set_7_bits_mask: u16 = 0b111_1111;

/// CodeBitmap marks each byte position in EVM bytecode as either opcode-space
/// or PUSH-data. A set bit means PUSH-data, and an unset bit means a real
/// opcode byte. `JUMPDEST` validity is checked by combining this bitmap with an
/// opcode check for the `JUMPDEST` byte. The bitmap itself is just a thin
/// wrapper over storage; ownership depends on the producer that returned it.
pub const CodeBitmap = struct {
    bits: []u8,

    pub fn init(allocator: std.mem.Allocator, code_len: usize) !CodeBitmap {
        const bits = try allocator.alloc(u8, bitmapLen(code_len));
        @memset(bits, 0);
        return .{ .bits = bits };
    }

    pub fn deinit(self: CodeBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn asSlice(self: CodeBitmap) []u8 {
        return self.bits;
    }

    pub fn codeSegment(self: CodeBitmap, pos: usize) bool {
        return ((self.bits[pos / 8] >> @intCast(pos % 8)) & 1) == 0;
    }

    pub fn fromCode(allocator: std.mem.Allocator, code: []const u8) !CodeBitmap {
        const bitmap = try init(allocator, code.len);
        _ = codeIntoBitmap(code, bitmap.bits);
        return bitmap;
    }
};

pub fn bitmapLen(code_len: usize) usize {
    return code_len / 8 + 5;
}

pub fn codeBitmap(allocator: std.mem.Allocator, code: []const u8) !CodeBitmap {
    return CodeBitmap.fromCode(allocator, code);
}

/// Marks PUSH-data bytes in `code` as 1 into caller-provided bitmap storage.
/// Real opcode bytes, including `JUMPDEST`, remain 0.
/// A valid jump destination is therefore a byte that is both opcode-space
/// according to this bitmap and equal to the `JUMPDEST` opcode.
pub fn codeIntoBitmap(code: []const u8, bits: []u8) []u8 {
    std.debug.assert(bits.len >= bitmapLen(code.len));
    @memset(bits, 0);

    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        pc += 1;

        if (op < push1 or op > push32) continue;

        var numbits: usize = @as(usize, op - push1) + 1;
        if (numbits >= 8) {
            while (numbits >= 16) : (numbits -= 16) {
                set16(bits, pc);
                pc += 16;
            }
            while (numbits >= 8) : (numbits -= 8) {
                set8(bits, pc);
                pc += 8;
            }
        }

        switch (numbits) {
            0 => {},
            1 => {
                set1(bits, pc);
                pc += 1;
            },
            2 => {
                setN(bits, set_2_bits_mask, pc);
                pc += 2;
            },
            3 => {
                setN(bits, set_3_bits_mask, pc);
                pc += 3;
            },
            4 => {
                setN(bits, set_4_bits_mask, pc);
                pc += 4;
            },
            5 => {
                setN(bits, set_5_bits_mask, pc);
                pc += 5;
            },
            6 => {
                setN(bits, set_6_bits_mask, pc);
                pc += 6;
            },
            7 => {
                setN(bits, set_7_bits_mask, pc);
                pc += 7;
            },
            else => unreachable,
        }
    }

    return bits;
}

fn set1(bits: []u8, pos: usize) void {
    bits[pos / 8] |= @as(u8, 1) << @intCast(pos % 8);
}

fn setN(bits: []u8, flag: u16, pos: usize) void {
    const shifted = flag << @intCast(pos % 8);
    bits[pos / 8] |= @truncate(shifted);

    const upper: u8 = @truncate(shifted >> 8);
    if (upper != 0) {
        bits[pos / 8 + 1] = upper;
    }
}

fn set8(bits: []u8, pos: usize) void {
    const lower = @as(u8, 0xff) << @intCast(pos % 8);
    bits[pos / 8] |= lower;
    bits[pos / 8 + 1] = ~lower;
}

fn set16(bits: []u8, pos: usize) void {
    const lower = @as(u8, 0xff) << @intCast(pos % 8);
    bits[pos / 8] |= lower;
    bits[pos / 8 + 1] = 0xff;
    bits[pos / 8 + 2] = ~lower;
}

test "code bitmap marks push data bytes as data segments" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0xaa, 0x7f } ++ [_]u8{0xbb} ** 32;

    const bitmap = try codeBitmap(allocator, &code);
    defer bitmap.deinit(allocator);

    try std.testing.expect(bitmap.codeSegment(0));
    try std.testing.expect(!bitmap.codeSegment(1));
    try std.testing.expect(bitmap.codeSegment(2));

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expect(!bitmap.codeSegment(3 + i));
    }
}

test "codeIntoBitmap reuses caller-provided storage" {
    const code = [_]u8{ 0x61, 0xaa, 0xbb, 0x00 };
    var storage = [_]u8{0xaa} ** bitmapLen(code.len);
    const bits = codeIntoBitmap(&code, &storage);
    const bitmap = CodeBitmap{ .bits = bits };

    try std.testing.expect(bits[0] != 0xaa);
    try std.testing.expect(!bitmap.codeSegment(1));
    try std.testing.expect(!bitmap.codeSegment(2));
    try std.testing.expect(bitmap.codeSegment(3));
}
