//! UltraCDC: A Fast and Stable Content-Defined Chunking Algorithm
//! Based on the 2022 IEEE paper by Zhou, Wang, Xia, and Zhang

const std = @import("std");

const hamming_distance_to_0xAA = [256]u8{
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
    5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 7, 8, 6, 7, 5, 6, 4, 5, 6, 7, 5, 6,
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
    2, 3, 1, 2, 3, 4, 2, 3, 1, 2, 0, 1, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3,
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
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
        var mask = mask_s;

        if (n <= min_size) {
            return n;
        }

        const n_capped = @min(n, max_size);
        if (n_capped < normal_size) {
            normal_size = n_capped;
        }

        var out_buf_win = data[min_size .. min_size + 8];

        var dist: u8 = 0;
        for (out_buf_win) |byte| {
            dist += hamming_distance_to_0xAA[byte];
        }

        var i: usize = min_size + 8;

        while (i <= n_capped - 8) : (i += 8) {
            mask = if (i >= normal_size) mask_l else mask_s;

            const in_buf_win = data[i..][0..8];

            if (std.mem.eql(u8, in_buf_win, out_buf_win)) {
                low_entropy_count += 1;
                if (low_entropy_count >= low_entropy_string_threshold) {
                    return i + 8;
                }
                continue;
            }

            low_entropy_count = 0;

            for (0..8) |j| {
                if ((dist & mask) == 0) {
                    return i + j;
                }

                dist +%= hamming_distance_to_0xAA[data[i + j]] -% hamming_distance_to_0xAA[data[i + j - 8]];
            }

            out_buf_win = in_buf_win;
        }

        return n_capped;
    }
};

// Tests
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
    try std.testing.expectEqual(0, hamming_distance_to_0xAA[0xAA]);

    // 0xAA XOR 0x55 = 0xFF (8 bits set) -> distance = 8
    try std.testing.expectEqual(8, hamming_distance_to_0xAA[0x55]);

    // 0xAA XOR 0x00 = 0xAA (4 bits set) -> distance = 4
    try std.testing.expectEqual(4, hamming_distance_to_0xAA[0x00]);

    // 0xAA XOR 0xFF = 0x55 (4 bits set) -> distance = 4
    try std.testing.expectEqual(4, hamming_distance_to_0xAA[0xFF]);
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
