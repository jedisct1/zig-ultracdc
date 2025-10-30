const std = @import("std");

/// UltraCDC: A Fast and Stable Content-Defined Chunking Algorithm
/// Based on the 2022 IEEE paper by Zhou, Wang, Xia, and Zhang
/// Original Go implementation: https://github.com/PlakarKorp/go-cdc-chunkers
/// Precomputed Hamming distance table from each byte value to 0xAA (binary 10101010)
/// This lookup table is faster than computing bits.OnesCount8(byte ^ 0xAA) for each byte
const hamming_distance_to_0xAA = [256]i32{
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
    5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 7, 8, 6, 7, 5, 6, 4, 5, 6, 7, 5, 6,
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
    2, 3, 1, 2, 3, 4, 2, 3, 1, 2, 0, 1, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3,
    4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 6, 7, 5, 6, 4, 5, 3, 4, 5, 6, 4, 5,
    3, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 5, 6, 4, 5, 3, 4, 2, 3, 4, 5, 3, 4,
};

/// Configuration options for the UltraCDC chunker
pub const ChunkerOptions = struct {
    /// Minimum chunk size in bytes (must be >= 64 and < normal_size)
    min_size: usize,
    /// Normal size threshold where mask switches from maskS to maskL (must be > min_size and < max_size)
    normal_size: usize,
    /// Maximum chunk size in bytes (must be > normal_size and <= 1GB)
    max_size: usize,

    /// Default chunker options (2KB min, 10KB normal, 64KB max)
    pub fn default() ChunkerOptions {
        return ChunkerOptions{
            .min_size = 2 * 1024,
            .normal_size = 10 * 1024,
            .max_size = 64 * 1024,
        };
    }

    /// Validate that options are within acceptable ranges
    pub fn validate(self: ChunkerOptions) !void {
        const min_allowed = 64;
        const max_allowed = 1024 * 1024 * 1024; // 1GB

        if (self.normal_size < min_allowed or self.normal_size > max_allowed) {
            return error.InvalidNormalSize;
        }
        if (self.min_size < min_allowed or self.min_size > max_allowed or self.min_size >= self.normal_size) {
            return error.InvalidMinSize;
        }
        if (self.max_size < min_allowed or self.max_size > max_allowed or self.max_size <= self.normal_size) {
            return error.InvalidMaxSize;
        }
    }
};

/// UltraCDC chunker (stateless design)
pub const UltraCDC = struct {
    /// Find the cutpoint in the given data buffer
    ///
    /// PRE condition: n must be <= data.len
    /// POST INVARIANT: returned cutpoint <= n
    ///
    /// Parameters:
    ///   - options: chunker configuration
    ///   - data: input data buffer
    ///   - n: number of bytes to process (typically data.len)
    ///
    /// Returns: cutpoint index where the chunk should be split
    pub fn algorithm(options: ChunkerOptions, data: []const u8, n: usize) usize {
        // Verify precondition
        std.debug.assert(n <= data.len);

        // Algorithm constants from the UltraCDC paper
        const mask_s: u64 = 0x2F; // binary 101111 - used before normal_size
        const mask_l: u64 = 0x2C; // binary 101100 - used after normal_size (easier to match)
        const low_entropy_string_threshold: usize = 64; // LEST in the paper

        const min_size = options.min_size;
        const max_size = options.max_size;
        var normal_size = options.normal_size;

        var low_entropy_count: usize = 0;
        var mask = mask_s;

        // Handle edge cases
        if (n <= min_size) {
            return n;
        }

        // Cap n at max_size and adjust normal_size if needed
        const n_capped = @min(n, max_size);
        if (n_capped < normal_size) {
            normal_size = n_capped;
        }

        // Initialize the outgoing 8-byte window starting at min_size
        var out_buf_win = data[min_size .. min_size + 8];

        // Initialize hamming distance on the initial window
        // The pattern 0xAA (binary 10101010) is used as referenced in the paper
        var dist: i32 = 0;
        for (out_buf_win) |byte| {
            dist += hamming_distance_to_0xAA[byte];
        }

        // Main loop: process 8 bytes at a time
        var i: usize = min_size + 8;

        while (i <= n_capped - 8) : (i += 8) {
            // Switch to maskL after reaching normal_size (evaluated once per iteration)
            mask = if (i >= normal_size) mask_l else mask_s;

            // Get the incoming 8-byte window
            const in_buf_win = data[i .. i + 8];

            // Check for low entropy (repeated data)
            if (std.mem.eql(u8, in_buf_win, out_buf_win)) {
                low_entropy_count += 1;
                if (low_entropy_count >= low_entropy_string_threshold) {
                    // Force a cut after too many identical windows
                    return i + 8;
                }
                continue;
            }

            // Reset low entropy counter
            low_entropy_count = 0;

            // Check each byte in the window for cutpoint
            for (0..8) |j| {
                if ((@as(u64, @intCast(dist)) & mask) == 0) {
                    return i + j;
                }

                // Update hamming distance by sliding the window
                dist += hamming_distance_to_0xAA[data[i + j]] - hamming_distance_to_0xAA[data[i + j - 8]];
            }

            // Update the outgoing window reference
            out_buf_win = in_buf_win;
        }

        // No cutpoint found
        return n_capped;
    }
};

// Tests
test "UltraCDC: default options" {
    const opts = ChunkerOptions.default();
    try std.testing.expectEqual(@as(usize, 2 * 1024), opts.min_size);
    try std.testing.expectEqual(@as(usize, 10 * 1024), opts.normal_size);
    try std.testing.expectEqual(@as(usize, 64 * 1024), opts.max_size);
}

test "UltraCDC: validate options - valid" {
    const opts = ChunkerOptions.default();
    try opts.validate();
}

test "UltraCDC: validate options - invalid normal_size" {
    const opts = ChunkerOptions{
        .min_size = 2 * 1024,
        .normal_size = 32, // Too small
        .max_size = 64 * 1024,
    };
    try std.testing.expectError(error.InvalidNormalSize, opts.validate());
}

test "UltraCDC: validate options - invalid min_size" {
    const opts = ChunkerOptions{
        .min_size = 32, // Too small
        .normal_size = 10 * 1024,
        .max_size = 64 * 1024,
    };
    try std.testing.expectError(error.InvalidMinSize, opts.validate());
}

test "UltraCDC: validate options - min_size >= normal_size" {
    const opts = ChunkerOptions{
        .min_size = 10 * 1024,
        .normal_size = 10 * 1024,
        .max_size = 64 * 1024,
    };
    try std.testing.expectError(error.InvalidMinSize, opts.validate());
}

test "UltraCDC: validate options - invalid max_size" {
    const opts = ChunkerOptions{
        .min_size = 2 * 1024,
        .normal_size = 10 * 1024,
        .max_size = 10 * 1024, // Not greater than normal_size
    };
    try std.testing.expectError(error.InvalidMaxSize, opts.validate());
}

test "UltraCDC: algorithm - data smaller than min_size" {
    const opts = ChunkerOptions.default();
    const data = [_]u8{0x00} ** 1024; // 1KB < 2KB min_size
    const cutpoint = UltraCDC.algorithm(opts, &data, data.len);
    try std.testing.expectEqual(data.len, cutpoint);
}

test "UltraCDC: algorithm - data at min_size" {
    const opts = ChunkerOptions.default();
    const data = [_]u8{0x00} ** 2048; // Exactly 2KB
    const cutpoint = UltraCDC.algorithm(opts, &data, data.len);
    try std.testing.expectEqual(data.len, cutpoint);
}

test "UltraCDC: algorithm - low entropy detection" {
    const opts = ChunkerOptions{
        .min_size = 1024,
        .normal_size = 10 * 1024,
        .max_size = 64 * 1024,
    };

    // Create data with repeating 8-byte pattern to trigger low entropy detection
    // Need at least 64 identical windows (512 bytes of repetition) after min_size
    var data: [8192]u8 = undefined;
    @memset(&data, 0xAA);

    const cutpoint = UltraCDC.algorithm(opts, &data, data.len);

    // Should cut due to low entropy after 64 identical windows
    // cutpoint should be min_size + 8 + (64 * 8) = 1024 + 8 + 512 = 1544
    try std.testing.expectEqual(@as(usize, 1544), cutpoint);
}

test "UltraCDC: algorithm - max_size cap" {
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

    const cutpoint = UltraCDC.algorithm(opts, &data, data.len);

    // Should be capped at max_size
    try std.testing.expectEqual(opts.max_size, cutpoint);
}

test "UltraCDC: hamming distance lookup table verification" {
    // Verify a few entries in the lookup table
    // 0xAA XOR 0xAA = 0x00 (0 bits set) -> distance = 0
    try std.testing.expectEqual(@as(i32, 0), hamming_distance_to_0xAA[0xAA]);

    // 0xAA XOR 0x55 = 0xFF (8 bits set) -> distance = 8
    try std.testing.expectEqual(@as(i32, 8), hamming_distance_to_0xAA[0x55]);

    // 0xAA XOR 0x00 = 0xAA (4 bits set) -> distance = 4
    try std.testing.expectEqual(@as(i32, 4), hamming_distance_to_0xAA[0x00]);

    // 0xAA XOR 0xFF = 0x55 (4 bits set) -> distance = 4
    try std.testing.expectEqual(@as(i32, 4), hamming_distance_to_0xAA[0xFF]);
}

test "UltraCDC: algorithm - random data produces reasonable chunks" {
    const opts = ChunkerOptions.default();

    // Use a simple PRNG for reproducible test
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var data: [128 * 1024]u8 = undefined;
    random.bytes(&data);

    const cutpoint = UltraCDC.algorithm(opts, &data, data.len);

    // Cutpoint should be within valid range
    try std.testing.expect(cutpoint >= opts.min_size);
    try std.testing.expect(cutpoint <= data.len);
}
