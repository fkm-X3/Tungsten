//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const ir = @import("ir.zig");
pub const codegen = @import("codegen.zig");
