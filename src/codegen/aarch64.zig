pub const abi = @import("aarch64/abi.zig");
pub const Assemble = @import("aarch64/Assemble.zig");
pub const Disassemble = @import("aarch64/Disassemble.zig");
pub const encoding = @import("aarch64/encoding.zig");
pub const Mir = @import("aarch64/Mir.zig");
pub const Select = @import("aarch64/Select.zig");

// New modernized backend
const CodeGen_v2 = @import("aarch64/CodeGen_v2.zig");
const Mir_v2 = @import("aarch64/Mir_v2.zig");

const std = @import("std");
const builtin = @import("builtin");
const Air = @import("../Air.zig");
const Zcu = @import("../Zcu.zig");
const InternPool = @import("../InternPool.zig");
const link = @import("../link.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.aarch64);

pub fn legalizeFeatures(target: *const std.Target) ?*const Air.Legalize.Features {
    // For now, always use new backend's legalizeFeatures
    // TODO: Add runtime switching when stable
    return CodeGen_v2.legalizeFeatures(target);
}

pub fn generate(
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) !Mir_v2 {
    // Feature flag: Use new backend (enabled by default for testing)
    // TODO: Add environment variable or build option to switch
    const use_new_backend = true;

    // Dispatch to new backend if enabled
    if (use_new_backend) {
        log.debug("Using new ARM64 backend for function {d}", .{@intFromEnum(func_index)});
        return try CodeGen_v2.generate(bin_file, pt, src_loc, func_index, air, liveness);
    }

    // Old backend below (deprecated)
    // If use_new_backend is false, fail at compile time
    @compileError("Old aarch64 backend is deprecated. Use new backend (Mir_v2) instead.");
}
test {
    _ = Assemble;
}
