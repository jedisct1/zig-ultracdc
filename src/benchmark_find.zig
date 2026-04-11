const std = @import("std");
const ultracdc = @import("ultracdc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_writer.interface;

    const opts = ultracdc.ChunkerOptions{
        .min_size = 8 * 1024,
        .normal_size = 64 * 1024,
        .max_size = 128 * 1024,
    };

    const data_size = 10 * 1024 * 1024;
    const data = try allocator.alloc(u8, data_size);
    defer allocator.free(data);

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    random.bytes(data);

    try stderr.print("Benchmarking UltraCDC.find() on {d} MB of data\n", .{data_size / (1024 * 1024)});
    try stderr.print("Options: min={d} KB, normal={d} KB, max={d} KB\n\n", .{
        opts.min_size / 1024,
        opts.normal_size / 1024,
        opts.max_size / 1024,
    });

    var offset: usize = 0;
    var chunks: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);
        offset += cutpoint;
        chunks += 1;
    }

    const iterations = 10;
    var total_ns: u64 = 0;

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        offset = 0;
        chunks = 0;

        const start = std.Io.Clock.awake.now(io);

        while (offset < data.len) {
            const remaining = data.len - offset;
            const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);
            offset += cutpoint;
            chunks += 1;
        }

        const end = std.Io.Clock.awake.now(io);
        const elapsed: u64 = @intCast(start.durationTo(end).nanoseconds);
        total_ns += elapsed;

        const throughput_mbps = (@as(f64, @floatFromInt(data_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stderr.print("Iteration {d}: {d:.2} ms, {d:.2} MB/s, {d} chunks\n", .{
            iter + 1,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            throughput_mbps,
            chunks,
        });
    }

    const avg_ns = total_ns / iterations;
    const avg_throughput = (@as(f64, @floatFromInt(data_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(avg_ns)) / 1_000_000_000.0);

    try stderr.print("\nAverage: {d:.2} ms, {d:.2} MB/s\n", .{
        @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0,
        avg_throughput,
    });
}
