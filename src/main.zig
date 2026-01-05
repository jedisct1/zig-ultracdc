const std = @import("std");
const ultracdc = @import("ultracdc");
const Io = std.Io;

const Hash = u128;

const FileStats = struct {
    path: []const u8,
    chunks: usize,
    bytes: usize,
};

const ChunkingStats = struct {
    total_chunks: usize = 0,
    unique_chunks: usize = 0,
    total_bytes: usize = 0,
    min_chunk_size: usize = std.math.maxInt(usize),
    max_chunk_size: usize = 0,
    file_stats: std.ArrayList(FileStats) = .empty,

    fn deinit(self: *ChunkingStats, allocator: std.mem.Allocator) void {
        for (self.file_stats.items) |stat| {
            allocator.free(stat.path);
        }
        self.file_stats.deinit(allocator);
    }
};

fn printHelp(program_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\Usage: {s} [options] <file1> [file2] [file3] ...
        \\
        \\Options:
        \\  --min-size <bytes>     Minimum chunk size (default: 8192)
        \\  --normal-size <bytes>  Normal chunk size (default: 65536)
        \\  --max-size <bytes>     Maximum chunk size (default: 131072)
        \\  --help, -h             Show this help message
        \\
        \\Description:
        \\  Chunks files using UltraCDC and computes hashes to measure
        \\  deduplication potential. Displays total chunks and unique chunks to estimate
        \\  compression ratio.
        \\
        \\Example:
        \\  {s} file1.bin file2.bin
        \\  {s} --min-size 4096 --max-size 131072 large_file.dat
        \\
    , .{ program_name, program_name, program_name });
}

fn parseSize(arg: []const u8) !usize {
    return std.fmt.parseInt(usize, arg, 10);
}

fn computeHash(key: *const [16]u8, data: []const u8) Hash {
    const Polyval = std.crypto.onetimeauth.Polyval;
    var state = Polyval.init(key);
    state.update(data);
    var out: [16]u8 = undefined;
    state.final(&out);
    return std.mem.readInt(u128, &out, .little);
}

fn processFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    opts: ultracdc.ChunkerOptions,
    key: *const [16]u8,
    hash_set: *std.AutoHashMap(Hash, void),
    stats: *ChunkingStats,
    writer: anytype,
) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024 * 1024));
    defer allocator.free(data);

    if (data.len == 0) {
        try writer.print("Warning: Skipping empty file: {s}\n", .{file_path});
        return;
    }

    var file_chunks: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) {
        const remaining = data.len - offset;
        const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);

        const chunk_data = data[offset .. offset + cutpoint];
        const hash = computeHash(key, chunk_data);

        const gop = try hash_set.getOrPut(hash);
        if (!gop.found_existing) {
            stats.unique_chunks += 1;
        }

        stats.total_chunks += 1;
        file_chunks += 1;
        stats.min_chunk_size = @min(stats.min_chunk_size, cutpoint);
        stats.max_chunk_size = @max(stats.max_chunk_size, cutpoint);

        offset += cutpoint;
    }

    stats.total_bytes += data.len;

    const path_copy = try allocator.dupe(u8, file_path);
    try stats.file_stats.append(allocator, FileStats{
        .path = path_copy,
        .chunks = file_chunks,
        .bytes = data.len,
    });
}

fn formatBytes(bytes: usize, buf: []u8) ![]u8 {
    const f_bytes: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.2} KB", .{f_bytes / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.2} MB", .{f_bytes / (1024.0 * 1024.0)});
    return std.fmt.bufPrint(buf, "{d:.2} GB", .{f_bytes / (1024.0 * 1024.0 * 1024.0)});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    const program_name = args.next() orelse "ultracdc";

    var opts = ultracdc.ChunkerOptions{};
    var file_paths = std.ArrayList([]const u8){};
    defer file_paths.deinit(allocator);

    var expecting_value: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (expecting_value) |option_name| {
            const value = try parseSize(arg);
            if (std.mem.eql(u8, option_name, "min-size")) {
                opts.min_size = value;
            } else if (std.mem.eql(u8, option_name, "normal-size")) {
                opts.normal_size = value;
            } else if (std.mem.eql(u8, option_name, "max-size")) {
                opts.max_size = value;
            }
            expecting_value = null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(program_name, stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            expecting_value = "min-size";
        } else if (std.mem.eql(u8, arg, "--normal-size")) {
            expecting_value = "normal-size";
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            expecting_value = "max-size";
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try stderr.print("Error: Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            try file_paths.append(allocator, arg);
        }
    }

    if (expecting_value != null) {
        try stderr.print("Error: Option --{s} requires a value\n", .{expecting_value.?});
        return error.MissingValue;
    }

    if (file_paths.items.len == 0) {
        try stderr.print("Error: No input files specified\n\n", .{});
        try printHelp(program_name, stderr);
        return error.NoInputFiles;
    }

    try stdout.print("UltraCDC Deduplication Analyzer\n", .{});
    try stdout.print("===============================\n\n", .{});
    try stdout.print("Chunker options:\n", .{});
    try stdout.print("  Min size:    {d} bytes\n", .{opts.min_size});
    try stdout.print("  Normal size: {d} bytes\n", .{opts.normal_size});
    try stdout.print("  Max size:    {d} bytes\n\n", .{opts.max_size});

    // Generate a random key for Polyval
    var key: [16]u8 = undefined;
    std.crypto.random.bytes(&key);

    var hash_set = std.AutoHashMap(Hash, void).init(allocator);
    defer hash_set.deinit();

    var stats = ChunkingStats{};
    defer stats.deinit(allocator);

    try stdout.print("Processing {d} file(s)...\n\n", .{file_paths.items.len});

    for (file_paths.items) |file_path| {
        try stdout.print("  Processing: {s}\n", .{file_path});
        processFile(allocator, io, file_path, opts, &key, &hash_set, &stats, stderr) catch |err| {
            try stderr.print("  Error processing {s}: {}\n", .{ file_path, err });
            continue;
        };
    }

    try stdout.print("\n", .{});
    try stdout.print("Results:\n", .{});
    try stdout.print("========\n\n", .{});

    try stdout.print("  Total chunks:        {d}\n", .{stats.total_chunks});
    try stdout.print("  Unique chunks:       {d}\n", .{stats.unique_chunks});

    const duplicate_chunks = stats.total_chunks - stats.unique_chunks;
    try stdout.print("  Duplicate chunks:    {d}", .{duplicate_chunks});

    if (stats.total_chunks > 0) {
        const dup_pct = @as(f64, @floatFromInt(duplicate_chunks)) / @as(f64, @floatFromInt(stats.total_chunks)) * 100.0;
        try stdout.print(" ({d:.1}%)\n", .{dup_pct});
    } else {
        try stdout.print("\n", .{});
    }

    if (stats.unique_chunks > 0) {
        const ratio = @as(f64, @floatFromInt(stats.total_chunks)) / @as(f64, @floatFromInt(stats.unique_chunks));
        try stdout.print("  Deduplication ratio: {d:.2}x\n", .{ratio});
    }

    var buf: [64]u8 = undefined;
    try stdout.print("  Total data:          {s}\n", .{try formatBytes(stats.total_bytes, &buf)});

    if (stats.total_chunks > 0) {
        const avg_chunk = stats.total_bytes / stats.total_chunks;
        try stdout.print("  Average chunk:       {s}\n", .{try formatBytes(avg_chunk, &buf)});

        if (stats.min_chunk_size != std.math.maxInt(usize)) {
            try stdout.print("  Min chunk:           {s}\n", .{try formatBytes(stats.min_chunk_size, &buf)});
        }

        try stdout.print("  Max chunk:           {s}\n", .{try formatBytes(stats.max_chunk_size, &buf)});
    }

    if (stats.file_stats.items.len > 1) {
        try stdout.print("\n", .{});
        try stdout.print("Per-file breakdown:\n", .{});
        for (stats.file_stats.items) |file_stat| {
            try stdout.print("  {s}: {d} chunks, {s}\n", .{
                file_stat.path,
                file_stat.chunks,
                try formatBytes(file_stat.bytes, &buf),
            });
        }
    }

    try stdout.print("\n", .{});
}
