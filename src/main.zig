const std = @import("std");
const gup = @import("gup");
const Blake3 = std.crypto.hash.Blake3;

const Hash = [32]u8; // 256-bit hash output

const FileStats = struct {
    path: []const u8,
    chunks: usize,
    bytes: usize,
};

const ChunkingStats = struct {
    total_chunks: usize,
    unique_chunks: usize,
    total_bytes: usize,
    min_chunk_size: usize,
    max_chunk_size: usize,
    file_stats: std.ArrayList(FileStats),

    fn init() ChunkingStats {
        return ChunkingStats{
            .total_chunks = 0,
            .unique_chunks = 0,
            .total_bytes = 0,
            .min_chunk_size = std.math.maxInt(usize),
            .max_chunk_size = 0,
            .file_stats = .empty,
        };
    }

    fn deinit(self: *ChunkingStats, allocator: std.mem.Allocator) void {
        for (self.file_stats.items) |stat| {
            allocator.free(stat.path);
        }
        self.file_stats.deinit(allocator);
    }
};

fn printHelp(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [options] <file1> [file2] [file3] ...
        \\
        \\Options:
        \\  --min-size <bytes>     Minimum chunk size (default: 2048)
        \\  --normal-size <bytes>  Normal chunk size (default: 10240)
        \\  --max-size <bytes>     Maximum chunk size (default: 65536)
        \\  --help, -h             Show this help message
        \\
        \\Description:
        \\  Chunks files using UltraCDC and computes BLAKE3 hashes to measure
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

fn computeHash(data: []const u8) Hash {
    var hash: Hash = undefined;
    Blake3.hash(data, &hash, .{});
    return hash;
}

fn processFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    opts: gup.ChunkerOptions,
    hash_set: *std.AutoHashMap(Hash, void),
    stats: *ChunkingStats,
) !void {
    // Read the file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size == 0) {
        std.debug.print("Warning: Skipping empty file: {s}\n", .{file_path});
        return;
    }

    const data = try std.fs.cwd().readFileAlloc(file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024 * 1024)); // 10GB max
    defer allocator.free(data);

    var file_chunks: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) {
        const remaining = data.len - offset;
        const cutpoint = gup.UltraCDC.algorithm(opts, data[offset..], remaining);

        // Compute hash for this chunk
        const chunk_data = data[offset .. offset + cutpoint];
        const hash = computeHash(chunk_data);

        // Add to set (will only increase unique count if new)
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

    // Store file stats
    const path_copy = try allocator.dupe(u8, file_path);
    try stats.file_stats.append(allocator, FileStats{
        .path = path_copy,
        .chunks = file_chunks,
        .bytes = data.len,
    });
}

fn formatBytes(bytes: usize, buf: []u8) ![]u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
    }
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    const program_name = args.next() orelse "gup";

    // Parse options and collect file paths
    var opts = gup.ChunkerOptions.default();
    var file_paths: std.ArrayList([]const u8) = .empty;
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
            printHelp(program_name);
            return;
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            expecting_value = "min-size";
        } else if (std.mem.eql(u8, arg, "--normal-size")) {
            expecting_value = "normal-size";
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            expecting_value = "max-size";
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            try file_paths.append(allocator, arg);
        }
    }

    if (expecting_value != null) {
        std.debug.print("Error: Option --{s} requires a value\n", .{expecting_value.?});
        return error.MissingValue;
    }

    if (file_paths.items.len == 0) {
        std.debug.print("Error: No input files specified\n\n", .{});
        printHelp(program_name);
        return error.NoInputFiles;
    }

    // Validate options
    opts.validate() catch |err| {
        std.debug.print("Error: Invalid chunker options: {}\n", .{err});
        return err;
    };

    std.debug.print("UltraCDC Deduplication Analyzer\n", .{});
    std.debug.print("================================\n\n", .{});
    std.debug.print("Chunker options:\n", .{});
    std.debug.print("  Min size:    {d} bytes\n", .{opts.min_size});
    std.debug.print("  Normal size: {d} bytes\n", .{opts.normal_size});
    std.debug.print("  Max size:    {d} bytes\n\n", .{opts.max_size});

    // Initialize hash set and stats
    var hash_set = std.AutoHashMap(Hash, void).init(allocator);
    defer hash_set.deinit();

    var stats = ChunkingStats.init();
    defer stats.deinit(allocator);

    // Process each file
    std.debug.print("Processing {d} file(s)...\n\n", .{file_paths.items.len});

    for (file_paths.items) |file_path| {
        std.debug.print("  Processing: {s}\n", .{file_path});
        processFile(allocator, file_path, opts, &hash_set, &stats) catch |err| {
            std.debug.print("  Error processing {s}: {}\n", .{ file_path, err });
            continue;
        };
    }

    // Display results
    std.debug.print("\n", .{});
    std.debug.print("Results:\n", .{});
    std.debug.print("========\n\n", .{});

    var buf: [64]u8 = undefined;
    const total_str = try std.fmt.bufPrint(&buf, "{d}", .{stats.total_chunks});
    std.debug.print("  Total chunks:      {s}\n", .{total_str});

    const unique_str = try std.fmt.bufPrint(buf[total_str.len..], "{d}", .{stats.unique_chunks});
    std.debug.print("  Unique chunks:     {s}\n", .{unique_str});

    const duplicate_chunks = stats.total_chunks - stats.unique_chunks;
    const duplicate_str = try std.fmt.bufPrint(&buf, "{d}", .{duplicate_chunks});
    std.debug.print("  Duplicate chunks:  {s}", .{duplicate_str});

    if (stats.total_chunks > 0) {
        const dup_pct = @as(f64, @floatFromInt(duplicate_chunks)) / @as(f64, @floatFromInt(stats.total_chunks)) * 100.0;
        std.debug.print(" ({d:.1}%)\n", .{dup_pct});
    } else {
        std.debug.print("\n", .{});
    }

    if (stats.unique_chunks > 0) {
        const ratio = @as(f64, @floatFromInt(stats.total_chunks)) / @as(f64, @floatFromInt(stats.unique_chunks));
        std.debug.print("  Deduplication ratio: {d:.2}x\n", .{ratio});
    }

    const total_bytes_str = try formatBytes(stats.total_bytes, &buf);
    std.debug.print("  Total data:        {s}\n", .{total_bytes_str});

    if (stats.total_chunks > 0) {
        const avg_chunk = stats.total_bytes / stats.total_chunks;
        const avg_str = try formatBytes(avg_chunk, &buf);
        std.debug.print("  Average chunk:     {s}\n", .{avg_str});

        if (stats.min_chunk_size != std.math.maxInt(usize)) {
            const min_str = try formatBytes(stats.min_chunk_size, &buf);
            std.debug.print("  Min chunk:         {s}\n", .{min_str});
        }

        const max_str = try formatBytes(stats.max_chunk_size, &buf);
        std.debug.print("  Max chunk:         {s}\n", .{max_str});
    }

    // Per-file stats
    if (stats.file_stats.items.len > 1) {
        std.debug.print("\n", .{});
        std.debug.print("Per-file breakdown:\n", .{});
        for (stats.file_stats.items) |file_stat| {
            const chunks_str = try std.fmt.bufPrint(&buf, "{d}", .{file_stat.chunks});
            const bytes_str = try formatBytes(file_stat.bytes, buf[chunks_str.len..]);
            std.debug.print("  {s}: {s} chunks, {s}\n", .{ file_stat.path, chunks_str, bytes_str });
        }
    }

    std.debug.print("\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
