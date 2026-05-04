//! LZ4 block-format codec — pure Zig.
//!
//! Implements the LZ4 BLOCK format (raw, no LZ4 framing). This is what
//! ClickHouse wraps inside its compression frame: the "compressed
//! payload" bytes after the 9-byte header are an LZ4 block, decoded
//! to exactly `decompressed_size` bytes (carried in the frame header).
//!
//! Decoder is full LZ4 (handles literal + match sequences). Encoder
//! takes a deliberate shortcut: emits a single "all-literal" block
//! with no back-references. The output is byte-identical to the input
//! plus a 1-2 byte token prefix, so we get NO compression — but the
//! resulting bytes ARE valid LZ4 that any decoder accepts. This keeps
//! INSERT bandwidth honest while letting us read compressed server
//! responses (the high-volume direction).
//!
//! Block format reference:
//!   sequences end-to-end. Each sequence:
//!     1 token byte = (literal_len_nibble << 4) | match_len_nibble
//!     if literal_len_nibble == 15: extra bytes 0x00..0xFF, sum to add
//!     literal_len bytes of literal data
//!     2 bytes LE: match offset (1..65535)        — omitted if last seq
//!     if match_len_nibble == 15: extra bytes      — omitted if last seq
//!     match copies match_len_nibble + 4 bytes from output[pos - offset]
//!   Last sequence: literal-only, no offset, no match. Match nibble
//!   in token MUST be 0 for the last sequence (per LZ4 spec a final
//!   match cannot terminate before 5 bytes from the end of input).

const std = @import("std");

pub const Error = error{
    MalformedInput,
    OutputTooSmall,
};

/// Decompress an LZ4 block. `out` must be exactly `decompressed_size`
/// bytes (caller knows this from the compression frame header). Returns
/// the number of bytes written, which always equals out.len on success.
pub fn decompressBlock(input: []const u8, out: []u8) Error!usize {
    var ip: usize = 0;
    var op: usize = 0;
    while (ip < input.len) {
        const token = input[ip];
        ip += 1;
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (ip < input.len) {
                const b = input[ip];
                ip += 1;
                lit_len += b;
                if (b != 0xFF) break;
            }
        }
        if (lit_len > 0) {
            if (ip + lit_len > input.len) return error.MalformedInput;
            if (op + lit_len > out.len) return error.OutputTooSmall;
            @memcpy(out[op .. op + lit_len], input[ip .. ip + lit_len]);
            op += lit_len;
            ip += lit_len;
        }
        // End-of-block: last sequence has only literals. ip == input.len
        // means no offset/match follows.
        if (ip == input.len) break;

        if (ip + 2 > input.len) return error.MalformedInput;
        const offset = std.mem.readInt(u16, input[ip..][0..2], .little);
        ip += 2;
        if (offset == 0) return error.MalformedInput;

        var match_len: usize = (token & 0x0F) + 4;
        if ((token & 0x0F) == 15) {
            while (ip < input.len) {
                const b = input[ip];
                ip += 1;
                match_len += b;
                if (b != 0xFF) break;
            }
        }
        if (offset > op) return error.MalformedInput;
        if (op + match_len > out.len) return error.OutputTooSmall;
        // Match may overlap when offset < match_len — that's valid LZ4
        // (run-length encoding shortcut). Byte-by-byte copy handles it.
        const match_start = op - offset;
        var i: usize = 0;
        while (i < match_len) : (i += 1) {
            out[op + i] = out[match_start + i];
        }
        op += match_len;
    }
    if (op != out.len) return error.MalformedInput;
    return op;
}

/// Encode `input` as a single-literal LZ4 block. The output is valid
/// LZ4 that any decoder accepts; it carries no compression benefit.
/// Caller must allocate `out` ≥ `worstCaseLiteralEncodedSize(input.len)`.
pub fn encodeLiteralBlock(input: []const u8, out: []u8) Error!usize {
    const needed = worstCaseLiteralEncodedSize(input.len);
    if (out.len < needed) return error.OutputTooSmall;

    var op: usize = 0;
    if (input.len < 15) {
        out[op] = @as(u8, @intCast(input.len)) << 4;
        op += 1;
    } else {
        out[op] = 0xF0; // 15 << 4
        op += 1;
        var rem = input.len - 15;
        while (rem >= 255) : (rem -= 255) {
            out[op] = 0xFF;
            op += 1;
        }
        out[op] = @intCast(rem);
        op += 1;
    }
    @memcpy(out[op .. op + input.len], input);
    op += input.len;
    return op;
}

pub fn worstCaseLiteralEncodedSize(input_len: usize) usize {
    // 1 token byte + ceil((input_len - 15) / 255) extension bytes + 1 final byte + payload.
    // For input_len < 15: 1 + input_len.
    if (input_len < 15) return 1 + input_len;
    const ext = ((input_len - 15) / 255) + 1;
    return 1 + ext + input_len;
}

const testing = std.testing;

test "encode literal then decode round-trips" {
    const ally = testing.allocator;
    const payload = "Hello, ClickHouse! This is an LZ4 round-trip test.";
    const enc_size = worstCaseLiteralEncodedSize(payload.len);
    const enc = try ally.alloc(u8, enc_size);
    defer ally.free(enc);
    const enc_len = try encodeLiteralBlock(payload, enc);

    const dec = try ally.alloc(u8, payload.len);
    defer ally.free(dec);
    const dec_len = try decompressBlock(enc[0..enc_len], dec);
    try testing.expectEqual(payload.len, dec_len);
    try testing.expectEqualStrings(payload, dec);
}

test "encode literal handles >15-byte payload with extension byte" {
    const ally = testing.allocator;
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const enc_size = worstCaseLiteralEncodedSize(payload.len);
    const enc = try ally.alloc(u8, enc_size);
    defer ally.free(enc);
    const enc_len = try encodeLiteralBlock(&payload, enc);
    // First byte = 0xF0 (15 << 4)
    try testing.expectEqual(@as(u8, 0xF0), enc[0]);

    const dec = try ally.alloc(u8, payload.len);
    defer ally.free(dec);
    _ = try decompressBlock(enc[0..enc_len], dec);
    try testing.expectEqualSlices(u8, &payload, dec);
}

test "decompress real LZ4 with back-reference" {
    // "abcabcabc" can be encoded as: literals "abc" + match offset=3 length=6
    // Token: lit_len=3, match_len_nibble = 6 - 4 = 2 → 0x32
    // Then literal "abc" = 0x61 0x62 0x63
    // Then offset 3 LE = 0x03 0x00
    // Match nibble 2 = 6 bytes (4 + 2)
    // Wait — match needs to terminate the block, but the LAST sequence
    // can't have a match. So we add a final empty-literal terminator.
    //
    // Better: construct via "abcabc" = 6 bytes total = literal "abc" (3
    // bytes) + match offset 3 length 3 = (4 + match_nibble). To get
    // match_len = 3 we'd need match_nibble = -1 — impossible. The min
    // match length in LZ4 is 4. So we use "abcabcab" (8 bytes): literal
    // "abc" + match offset 3 length 5 (nibble = 1).
    // Token: lit_len 3, match_nibble 1 → 0x31. literal "abc". offset 3 LE.
    // Then a closing literal-only sequence with 0 literals to terminate.
    //
    // Actually LZ4 requires the last 5 bytes to be literals (the
    // "lastLiterals" rule). So a back-reference can only end ≥5 bytes
    // before the end. "abcabcabcabcabc" (15 bytes) = lit "abcab" (5)
    // + match offset 5 length 5 + lit "abcab" (5 final). But that's 5+5+5=15.
    // Token1: lit_nibble 5, match_nibble 1 → 0x51.
    // Then "abcab", offset 5 LE = 05 00, then closing sequence:
    // Token2: lit_nibble 5, match_nibble 0 → 0x50, "abcab".
    const enc = [_]u8{
        0x51, 'a', 'b', 'c', 'a', 'b', 0x05, 0x00,
        0x50, 'a', 'b', 'c', 'a', 'b',
    };
    var dec_buf: [15]u8 = undefined;
    const dec_len = try decompressBlock(&enc, &dec_buf);
    try testing.expectEqual(@as(usize, 15), dec_len);
    try testing.expectEqualStrings("abcababcababcab", &dec_buf);
}
