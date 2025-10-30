//! UltraCDC: A Fast and Stable Content-Defined Chunking Algorithm
//! Based on the 2022 IEEE paper by Zhou, Wang, Xia, and Zhang

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const lut = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        entry.* = @popCount(i ^ 0xAA);
    }
    break :blk table;
};

pub const ChunkerOptions = struct {
    min_size: usize = 8 * 1024,
    normal_size: usize = 64 * 1024,
    max_size: usize = 128 * 1024,
};

pub const UltraCDC = struct {
    pub fn find(options: ChunkerOptions, data: []const u8, n: usize) usize {
        std.debug.assert(n <= data.len);

        const mask_s: u64 = 0x2F;
        const mask_l: u64 = 0x2C;
        const low_entropy_string_threshold: usize = 64;

        const min_size = options.min_size;
        const max_size = options.max_size;
        var normal_size = options.normal_size;

        var low_entropy_count: usize = 0;

        if (n <= min_size) {
            return n;
        }

        const n_capped = @min(n, max_size);
        if (n_capped < normal_size) {
            normal_size = n_capped;
        }

        // Initialize hamming distance on first 8-byte window
        var dist: u8 = 0;
        for (0..8) |j| {
            dist += lut[data[min_size + j]];
        }

        var out_win = std.mem.readInt(u64, data[min_size..][0..8], native_endian);

        var i = min_size + 8;
        while (i <= n_capped - 8) : (i += 8) {
            const mask = if (i >= normal_size) mask_l else mask_s;

            const in_win = std.mem.readInt(u64, data[i..][0..8], native_endian);
            if (in_win == out_win) {
                low_entropy_count += 1;
                if (low_entropy_count >= low_entropy_string_threshold) {
                    return i + 8;
                }
                continue;
            }
            low_entropy_count = 0;

            const in0 = lut[data[i]];
            const in1 = lut[data[i + 1]];
            const in2 = lut[data[i + 2]];
            const in3 = lut[data[i + 3]];
            const in4 = lut[data[i + 4]];
            const in5 = lut[data[i + 5]];
            const in6 = lut[data[i + 6]];
            const in7 = lut[data[i + 7]];

            const out0 = lut[data[i - 8]];
            const out1 = lut[data[i - 7]];
            const out2 = lut[data[i - 6]];
            const out3 = lut[data[i - 5]];
            const out4 = lut[data[i - 4]];
            const out5 = lut[data[i - 3]];
            const out6 = lut[data[i - 2]];
            const out7 = lut[data[i - 1]];

            const d0 = in0 -% out0;
            const d1 = in1 -% out1;
            const d2 = in2 -% out2;
            const d3 = in3 -% out3;
            const d4 = in4 -% out4;
            const d5 = in5 -% out5;
            const d6 = in6 -% out6;
            const d7 = in7 -% out7;

            if ((dist & mask) == 0) return i;
            dist +%= d0;

            if ((dist & mask) == 0) return i + 1;
            dist +%= d1;

            if ((dist & mask) == 0) return i + 2;
            dist +%= d2;

            if ((dist & mask) == 0) return i + 3;
            dist +%= d3;

            if ((dist & mask) == 0) return i + 4;
            dist +%= d4;

            if ((dist & mask) == 0) return i + 5;
            dist +%= d5;

            if ((dist & mask) == 0) return i + 6;
            dist +%= d6;

            if ((dist & mask) == 0) return i + 7;
            dist +%= d7;

            out_win = in_win;
        }
        return n_capped;
    }
};

test "default options" {
    const opts = ChunkerOptions{};
    try std.testing.expectEqual(@as(usize, 8 * 1024), opts.min_size);
    try std.testing.expectEqual(@as(usize, 64 * 1024), opts.normal_size);
    try std.testing.expectEqual(@as(usize, 128 * 1024), opts.max_size);
}

test "algorithm - data smaller than min_size" {
    const opts = ChunkerOptions{};
    const data = [_]u8{0x00} ** 1024;
    const cutpoint = UltraCDC.find(opts, &data, data.len);
    try std.testing.expectEqual(data.len, cutpoint);
}

test "algorithm - data at min_size" {
    const opts = ChunkerOptions{};
    const data = [_]u8{0x00} ** (8 * 1024);
    const cutpoint = UltraCDC.find(opts, &data, data.len);
    try std.testing.expectEqual(data.len, cutpoint);
}

test "algorithm - low entropy detection" {
    const opts = ChunkerOptions{
        .min_size = 1024,
        .normal_size = 10 * 1024,
        .max_size = 64 * 1024,
    };

    // Create data with repeating 8-byte pattern to trigger low entropy detection
    // Need at least 64 identical windows (512 bytes of repetition) after min_size
    var data: [8192]u8 = undefined;
    @memset(&data, 0xAA);

    const cutpoint = UltraCDC.find(opts, &data, data.len);

    // Should cut due to low entropy after 64 identical windows
    // cutpoint should be min_size + 8 + (64 * 8) = 1024 + 8 + 512 = 1544
    try std.testing.expectEqual(@as(usize, 1544), cutpoint);
}

test "algorithm - max_size cap" {
    const opts = ChunkerOptions{
        .min_size = 1024,
        .normal_size = 10 * 1024,
        .max_size = 8 * 1024,
    };

    // Use varying data to avoid low entropy detection
    // but with a pattern that won't trigger cutpoints easily
    var data: [16384]u8 = undefined;
    for (&data, 0..) |*byte, i| {
        byte.* = @truncate(i * 7);
    }

    const cutpoint = UltraCDC.find(opts, &data, data.len);

    // Should be capped at max_size
    try std.testing.expectEqual(opts.max_size, cutpoint);
}

test "hamming distance lookup table verification" {
    // Verify a few entries in the lookup table
    // 0xAA XOR 0xAA = 0x00 (0 bits set) -> distance = 0
    try std.testing.expectEqual(0, lut[0xAA]);

    // 0xAA XOR 0x55 = 0xFF (8 bits set) -> distance = 8
    try std.testing.expectEqual(8, lut[0x55]);

    // 0xAA XOR 0x00 = 0xAA (4 bits set) -> distance = 4
    try std.testing.expectEqual(4, lut[0x00]);

    // 0xAA XOR 0xFF = 0x55 (4 bits set) -> distance = 4
    try std.testing.expectEqual(4, lut[0xFF]);
}

test "algorithm - random data produces reasonable chunks" {
    const opts = ChunkerOptions{};

    // Use a simple PRNG for reproducible test
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var data: [128 * 1024]u8 = undefined;
    random.bytes(&data);

    const cutpoint = UltraCDC.find(opts, &data, data.len);

    // Cutpoint should be within valid range
    try std.testing.expect(cutpoint >= opts.min_size);
    try std.testing.expect(cutpoint <= data.len);
}
