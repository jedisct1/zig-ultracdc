//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Re-export UltraCDC module
pub const ultracdc = @import("ultracdc.zig");

// Convenience exports
pub const UltraCDC = ultracdc.UltraCDC;
pub const ChunkerOptions = ultracdc.ChunkerOptions;
