const std = @import("std");
const ultracdc = @import("ultracdc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = ultracdc.ChunkerOptions{
        .min_size = 8 * 1024,
        .normal_size = 64 * 1024,
        .max_size = 128 * 1024,
    };

    // Create test data - mix of random and patterns
    const data_size = 10 * 1024 * 1024; // 10MB
    const data = try allocator.alloc(u8, data_size);
    defer allocator.free(data);

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    random.bytes(data);

    std.debug.print("Benchmarking UltraCDC.find() on {d} MB of data\n", .{data_size / (1024 * 1024)});
    std.debug.print("Options: min={d} KB, normal={d} KB, max={d} KB\n\n", .{
        opts.min_size / 1024,
        opts.normal_size / 1024,
        opts.max_size / 1024,
    });

    // Warmup
    var offset: usize = 0;
    var chunks: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);
        offset += cutpoint;
        chunks += 1;
    }

    // Actual benchmark
    const iterations = 10;
    var total_time: u64 = 0;

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        offset = 0;
        chunks = 0;

        const start = std.time.nanoTimestamp();

        while (offset < data.len) {
            const remaining = data.len - offset;
            const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);
            offset += cutpoint;
            chunks += 1;
        }

        const end = std.time.nanoTimestamp();
        const elapsed = @as(u64, @intCast(end - start));
        total_time += elapsed;

        const throughput_mbps = (@as(f64, @floatFromInt(data_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        std.debug.print("Iteration {d}: {d:.2} ms, {d:.2} MB/s, {d} chunks\n", .{
            iter + 1,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            throughput_mbps,
            chunks,
        });
    }

    const avg_time = total_time / iterations;
    const avg_throughput = (@as(f64, @floatFromInt(data_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(avg_time)) / 1_000_000_000.0);

    std.debug.print("\nAverage: {d:.2} ms, {d:.2} MB/s\n", .{
        @as(f64, @floatFromInt(avg_time)) / 1_000_000.0,
        avg_throughput,
    });
}
