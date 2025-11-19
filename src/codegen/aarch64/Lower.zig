//! ARM64 MIR Lowering
//! Converts abstract MIR instructions to encoded machine instructions
//! Handles branch offset calculation and relocation generation

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Mir = @import("Mir_v2.zig");
const encoder = @import("encoder.zig");
const encoding = @import("encoding.zig");
const link = @import("../../link.zig");
const Zcu = @import("../../Zcu.zig");

const Instruction = encoding.Instruction;

const log = std.log.scoped(.codegen);

allocator: Allocator,
mir: Mir,
cc: std.builtin.CallingConvention,
src_loc: Zcu.LazySrcLoc,
target: *const std.Target,

/// Lowered instructions
instructions: std.ArrayListUnmanaged(Instruction) = .empty,
/// Relocations that need to be applied
relocations: std.ArrayListUnmanaged(Relocation) = .empty,

/// Branch targets (maps MIR index to instruction index)
branch_targets: std.AutoHashMapUnmanaged(Mir.Inst.Index, u32) = .empty,

const Lower = @This();

pub const Relocation = struct {
    /// Source instruction offset (in instruction count, not bytes)
    source: u32,
    /// Target MIR instruction index
    target: Mir.Inst.Index,
    /// Type of relocation
    type: Type,

    pub const Type = enum {
        /// Unconditional branch (B, BL) - 26-bit signed offset
        branch_26,
        /// Conditional branch (B.cond) - 19-bit signed offset
        branch_19,
        /// Compare and branch (CBZ, CBNZ) - 19-bit signed offset
        cbz_19,
        /// Test and branch (TBZ, TBNZ) - 14-bit signed offset
        tbz_14,
        /// ADRP page offset - 21-bit signed offset (for PIC)
        adrp_page,
        /// ADD page offset - 12-bit unsigned offset (for PIC)
        add_pageoff,
        /// Load literal - 19-bit signed offset
        literal_19,
    };
};

/// Lower all MIR instructions to machine code
pub fn lowerMir(self: *Lower) error{ CodegenFail, OutOfMemory, Overflow, InvalidImmediate, InvalidOperands, InvalidRegister, PseudoInstruction, UnimplementedInstruction }!void {
    const gpa = self.allocator;

    log.debug("=== ARM64 Lower: Starting MIR lowering with {d} instructions ===", .{self.mir.instructions.len});

    // First pass: count instructions and build branch target map
    try self.branch_targets.ensureTotalCapacity(gpa, @intCast(self.mir.instructions.len));

    var instruction_offset: u32 = 0;
    for (self.mir.instructions.items(.tag), 0..) |tag, i| {
        const mir_index: Mir.Inst.Index = @intCast(i);

        // Record this as a potential branch target (pseudo instructions map to current offset)
        self.branch_targets.putAssumeCapacity(mir_index, instruction_offset);

        // Pseudo instructions don't generate code, so don't increment offset
        if (isPseudoInstruction(tag)) {
            continue;
        }

        instruction_offset += 1;
    }

    log.debug("ARM64 Lower: Branch target map built, starting instruction lowering", .{});

    // Second pass: generate instructions
    for (self.mir.instructions.items(.tag), 0..) |tag, i| {
        const mir_index: Mir.Inst.Index = @intCast(i);
        const inst = self.mir.instructions.get(mir_index);

        log.debug("ARM64 Lower: Lowering MIR inst {d}: {s}", .{ i, @tagName(tag) });
        try self.lowerInst(inst, mir_index);
    }

    log.debug("ARM64 Lower: Instruction lowering complete, generated {d} instructions", .{self.instructions.items.len});

    // Third pass: apply relocations
    log.debug("ARM64 Lower: Applying relocations", .{});
    try self.applyRelocations();

    log.debug("=== ARM64 Lower: MIR lowering complete ===", .{});
}

fn isPseudoInstruction(tag: Mir.Inst.Tag) bool {
    return switch (tag) {
        .pseudo_dbg_prologue_end,
        .pseudo_dbg_epilogue_begin,
        .pseudo_dbg_line,
        .pseudo_dbg_enter_block,
        .pseudo_dbg_leave_block,
        .pseudo_enter_frame,
        .pseudo_exit_frame,
        .pseudo_dead,
        .pseudo_spill,
        .pseudo_reload,
        => true,
        else => false,
    };
}

fn lowerInst(self: *Lower, inst: Mir.Inst, _: Mir.Inst.Index) error{ CodegenFail, OutOfMemory, Overflow, InvalidImmediate, InvalidOperands, InvalidRegister, PseudoInstruction, UnimplementedInstruction }!void {
    const gpa = self.allocator;

    // Skip pseudo instructions
    if (isPseudoInstruction(inst.tag)) {
        return;
    }

    // Special handling for branches (need relocations)
    switch (inst.tag) {
        .b, .bl => {
            const source_offset: u32 = @intCast(self.instructions.items.len);

            // Emit placeholder instruction
            const placeholder = try encoder.encode(inst);
            try self.instructions.append(gpa, placeholder);

            // Record relocation
            try self.relocations.append(gpa, .{
                .source = source_offset,
                .target = inst.data.rel.target,
                .type = .branch_26,
            });
            return;
        },

        .b_cond => {
            const source_offset: u32 = @intCast(self.instructions.items.len);

            // Emit placeholder instruction
            const placeholder = try encoder.encode(inst);
            try self.instructions.append(gpa, placeholder);

            // Record relocation
            try self.relocations.append(gpa, .{
                .source = source_offset,
                .target = inst.data.rel.target,
                .type = .branch_19,
            });
            return;
        },

        .cbz, .cbnz => {
            const source_offset: u32 = @intCast(self.instructions.items.len);

            // Emit placeholder instruction
            const placeholder = try encoder.encode(inst);
            try self.instructions.append(gpa, placeholder);

            // Record relocation
            try self.relocations.append(gpa, .{
                .source = source_offset,
                .target = inst.data.r_rel.target,
                .type = .cbz_19,
            });
            return;
        },

        .raw => {
            // Raw encoded instruction (from inline assembly)
            const inst_bits: u32 = inst.data.raw;
            const raw_inst: encoding.Instruction = @bitCast(inst_bits);
            try self.instructions.append(gpa, raw_inst);
            return;
        },

        else => {},
    }

    // Regular instruction encoding
    const encoded = encoder.encode(inst) catch |err| {
        std.debug.print("Failed to encode {s}: {}\n", .{ @tagName(inst.tag), err });
        return err;
    };

    try self.instructions.append(gpa, encoded);
}

fn applyRelocations(self: *Lower) error{ CodegenFail, OutOfMemory, Overflow }!void {
    for (self.relocations.items) |reloc| {
        const target_offset = self.branch_targets.get(reloc.target) orelse {
            std.debug.print("Branch target {} not found (have {} targets, {} MIR instructions)\n", .{ reloc.target, self.branch_targets.count(), self.mir.instructions.len });
            return error.CodegenFail;
        };

        const source_offset = reloc.source;

        // Calculate offset in instructions
        const offset_instructions: i32 = @as(i32, @intCast(target_offset)) - @as(i32, @intCast(source_offset));

        switch (reloc.type) {
            .branch_26 => {
                // Unconditional branch: 26-bit signed offset
                if (offset_instructions < -33554432 or offset_instructions > 33554431) {
                    return error.CodegenFail;
                }

                const offset_26: i26 = @intCast(offset_instructions);
                const imm26: u26 = @bitCast(offset_26);

                // Patch the instruction
                var inst_bits: u32 = @bitCast(self.instructions.items[source_offset]);
                inst_bits &= 0xFC000000; // Clear imm26 field
                inst_bits |= imm26;
                self.instructions.items[source_offset] = @bitCast(inst_bits);
            },

            .branch_19 => {
                // Conditional branch: 19-bit signed offset
                if (offset_instructions < -262144 or offset_instructions > 262143) {
                    return error.CodegenFail;
                }

                const offset_19: i19 = @intCast(offset_instructions);
                const imm19: u19 = @bitCast(offset_19);

                // Patch the instruction
                var inst_bits: u32 = @bitCast(self.instructions.items[source_offset]);
                inst_bits &= 0xFF00001F; // Clear imm19 field
                inst_bits |= @as(u32, imm19) << 5;
                self.instructions.items[source_offset] = @bitCast(inst_bits);
            },

            .cbz_19 => {
                // Compare and branch: 19-bit signed offset
                if (offset_instructions < -262144 or offset_instructions > 262143) {
                    return error.CodegenFail;
                }

                const offset_19: i19 = @intCast(offset_instructions);
                const imm19: u19 = @bitCast(offset_19);

                // Patch the instruction
                var inst_bits: u32 = @bitCast(self.instructions.items[source_offset]);
                inst_bits &= 0xFF00001F; // Clear imm19 field
                inst_bits |= @as(u32, imm19) << 5;
                self.instructions.items[source_offset] = @bitCast(inst_bits);
            },

            .tbz_14 => {
                // Test and branch: 14-bit signed offset
                if (offset_instructions < -8192 or offset_instructions > 8191) {
                    return error.CodegenFail;
                }

                const offset_14: i14 = @intCast(offset_instructions);
                const imm14: u14 = @bitCast(offset_14);

                // Patch the instruction
                var inst_bits: u32 = @bitCast(self.instructions.items[source_offset]);
                inst_bits &= 0xFFF8001F; // Clear imm14 field
                inst_bits |= @as(u32, imm14) << 5;
                self.instructions.items[source_offset] = @bitCast(inst_bits);
            },

            .adrp_page, .add_pageoff, .literal_19 => {
                // These would be handled for position-independent code
                // Not implemented in this initial version
                return error.CodegenFail;
            },
        }
    }
}

pub fn deinit(self: *Lower) void {
    self.instructions.deinit(self.allocator);
    self.relocations.deinit(self.allocator);
    self.branch_targets.deinit(self.allocator);
}

test "Lower basic arithmetic" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Create simple MIR
    var insts: std.MultiArrayList(Mir.Inst) = .{};
    defer insts.deinit(gpa);

    // ADD X0, X1, X2
    try insts.append(gpa, .{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = .x0,
            .rn = .x1,
            .rm = .x2,
        } },
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
}
