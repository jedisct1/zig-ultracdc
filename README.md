# UltraCDC

A Zig implementation of UltraCDC, a fast content-defined chunking algorithm for data deduplication.

## What is this?

Content-defined chunking (CDC) splits data into variable-sized pieces based on the data itself, not arbitrary boundaries. This makes it useful for deduplication: if you change one paragraph in a document, only that chunk changes, not everything after it.

UltraCDC is a CDC algorithm from a 2022 IEEE paper that's both fast and stable. This implementation can process data at around 2.7 GB/s, making it practical for real-world use.

## Building

You'll need Zig 0.16 or later.

```bash
zig build -Doptimize=ReleaseFast
```

## Using the CLI

The `ultracdc` tool analyzes how well your files would deduplicate:

```bash
# Basic usage
zig-out/bin/ultracdc file1.dat file2.dat

# With custom chunk sizes
zig-out/bin/ultracdc --min-size 4096 --max-size 262144 backup.tar
```

It will show you:

- How many chunks it found
- How many are unique
- The deduplication ratio (potential storage savings)

## Using as a library

```zig
const ultracdc = @import("ultracdc");

// Use default options (8KB min, 64KB normal, 128KB max)
const options = ultracdc.ChunkerOptions{};

// Find the first chunk boundary
const cutpoint = ultracdc.UltraCDC.find(options, data, data.len);

// Process the chunk
const chunk = data[0..cutpoint];
```

## How it works

UltraCDC uses a sliding window over your data and looks at the "fingerprint" of each window using hamming distance. When it finds a fingerprint that matches a pattern, it makes a cut. The algorithm is designed to:

- Cut at the same places even if you insert or delete data elsewhere
- Avoid creating tiny or huge chunks
- Handle low-entropy data (like runs of zeros) without slowing down

## Testing

```bash
zig build test
```

The tests cover edge cases like minimum-size data, low-entropy detection, and maximum chunk size enforcement.

## Performance

```bash
zig build bench-find
```

## Reference

The algorithm comes from:

- [Zhou, Wang, Xia, and Zhang. "UltraCDC: A Fast and Stable Content-Defined Chunking Algorithm." IEEE, 2022.](https://ieeexplore.ieee.org/document/9894295)
