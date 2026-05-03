// Compression stub for v0.16.0 sync release.
// LZ4/ZSTD implementations live in experimental/compression/ pending
// Zig 0.16 port and proper dependency packaging.

const std = @import("std");

pub const CompressionMethod = enum(u8) {
    None = 0x02,
    LZ4 = 0x82,
    ZSTD = 0x90,
};

pub const CompressedData = struct {
    data: []u8,

    pub fn compress(
        allocator: std.mem.Allocator,
        input: []const u8,
        method: CompressionMethod,
    ) !CompressedData {
        _ = method;
        const copy = try allocator.alloc(u8, input.len);
        @memcpy(copy, input);
        return .{ .data = copy };
    }

    pub fn deinit(self: CompressedData, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};
