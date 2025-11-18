//! ARM64 Machine Code Emission
//! Emits lowered instructions to machine code with relocations and debug info

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Mir = @import("Mir_v2.zig");
const Lower = @import("Lower.zig");
const encoding = @import("encoding.zig");
const link = @import("../../link.zig");
const Zcu = @import("../../Zcu.zig");
const InternPool = @import("../../InternPool.zig");

const Instruction = encoding.Instruction;

const log = std.log.scoped(.codegen);

/// Emit MIR to machine code
pub fn emitMir(
    mir: Mir,
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    atom_index: u32,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) error{ CodegenFail, OutOfMemory, Overflow, RelocationNotByteAligned, WriteFailed }!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const func = zcu.funcInfo(func_index);
    const mod = zcu.navFileScope(func.owner_nav).mod.?;
    const target = &mod.resolved_target.result;

    log.debug("=== ARM64 Emit: Starting emission for function atom {d} ===", .{atom_index});

    // Create lower
    var lower: Lower = .{
        .allocator = gpa,
        .mir = mir,
        .cc = .auto,
        .src_loc = src_loc,
        .target = target,
    };
    defer {
        log.debug("ARM64 Emit: Deinitializing lower", .{});
        lower.deinit();
    }

    log.debug("ARM64 Emit: Calling lowerMir()", .{});
    // Lower MIR to machine instructions
    // Convert encoder-specific errors to CodegenFail
    lower.lowerMir() catch |err| switch (err) {
        error.InvalidImmediate,
        error.InvalidOperands,
        error.InvalidRegister,
        error.PseudoInstruction,
        error.UnimplementedInstruction,
        => return error.CodegenFail,
        else => |e| return e,
    };

    log.debug("ARM64 Emit: lowerMir complete, writing {d} instructions", .{lower.instructions.items.len});

    // Write instructions to output
    const start_offset = w.end;

    for (lower.instructions.items, 0..) |inst, i| {
        const inst_bits: u32 = @bitCast(inst);
        log.debug("ARM64 Emit: Writing instruction {d}: 0x{x:0>8}", .{ i, inst_bits });
        try w.writeInt(u32, inst_bits, .little);
    }

    const end_offset = w.end;
    log.debug("ARM64 Emit: Wrote {d} bytes (offset {d} -> {d})", .{ end_offset - start_offset, start_offset, end_offset });

    // Generate debug info if requested
    if (debug_output != .none) {
        log.debug("ARM64 Emit: Generating debug info", .{});
        try emitDebugInfo(
            mir,
            bin_file,
            pt,
            func_index,
            atom_index,
            start_offset,
            end_offset,
            debug_output,
        );
    }

    log.debug("=== ARM64 Emit: Emission complete ===", .{});
}

/// Emit DWARF debug information
fn emitDebugInfo(
    mir: Mir,
    bin_file: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    atom_index: u32,
    start_offset: u64,
    end_offset: u64,
    debug_output: link.File.DebugInfoOutput,
) !void {
    _ = mir;
    _ = bin_file;
    _ = pt;
    _ = func_index;
    _ = atom_index;
    _ = start_offset;
    _ = end_offset;
    _ = debug_output;

    // TODO: Implement DWARF debug info generation
    // This would include:
    // - .debug_line entries for source line mapping
    // - .debug_frame entries for stack unwinding (CFI)
    // - FP/LR save locations
    // - Stack pointer adjustments
    // - CFA (Canonical Frame Address) tracking
}

/// Generate CFI (Call Frame Information) directives
fn emitCFI(
    mir: Mir,
    bin_file: *link.File,
    func_index: InternPool.Index,
) !void {
    _ = mir;
    _ = bin_file;
    _ = func_index;

    // TODO: Implement CFI generation
    // ARM64-specific CFI directives:
    // - DW_CFA_advance_loc: advance PC
    // - DW_CFA_def_cfa: define CFA register and offset
    // - DW_CFA_offset: register is saved at offset from CFA
    // - FP (X29) save location
    // - LR (X30) save location
}

test "Emit basic function" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Create simple MIR with RET instruction
    var insts: std.MultiArrayList(Mir.Inst) = .{};
    defer insts.deinit(gpa);

    try insts.append(gpa, .{
        .tag = .ret,
        .ops = .none,
        .data = .{ .none = {} },
    });

    const mir: Mir = .{
        .instructions = insts.slice(),
        .extra = &.{},
        .string_bytes = &.{},
        .locals = &.{},
        .table = &.{},
        .frame_locs = .empty,
    };

    var lower: Lower = .{
        .allocator = gpa,
        .mir = mir,
        .cc = .auto,
        .src_loc = undefined,
        .target = undefined,
    };
    defer lower.deinit();

    try lower.lowerMir();

    try testing.expectEqual(@as(usize, 1), lower.instructions.items.len);

    // RET instruction encoding: 0xD65F03C0
    const expected_ret: u32 = 0xD65F03C0;
    const actual: u32 = @bitCast(lower.instructions.items[0]);
    try testing.expectEqual(expected_ret, actual);
}
