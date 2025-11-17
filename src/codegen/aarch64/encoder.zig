//! ARM64 Instruction Encoder
//! Converts abstract MIR instructions to encoded ARM64 Instruction types

const std = @import("std");
const assert = std.debug.assert;

const Mir = @import("Mir_v2.zig");
const bits = @import("bits.zig");
const encoding = @import("encoding.zig");

const Condition = bits.Condition;
const Register = bits.Register;
const Memory = bits.Memory;
const Instruction = encoding.Instruction;

/// Convert a Condition to encoding ConditionCode
fn conditionToCode(cond: Condition) encoding.ConditionCode {
    return @enumFromInt(@intFromEnum(cond));
}

/// Encode a MIR instruction to an ARM64 machine instruction
pub fn encode(inst: Mir.Inst) Error!Instruction {
    return switch (inst.tag) {
        // Arithmetic
        .add => encodeAdd(inst),
        .adds => encodeAdds(inst),
        .sub => encodeSub(inst),
        .subs => encodeSubs(inst),
        .mul => encodeMul(inst),
        .sdiv => encodeSdiv(inst),
        .udiv => encodeUdiv(inst),

        // Logical
        .and_ => encodeAnd(inst),
        .orr => encodeOrr(inst),
        .eor => encodeEor(inst),
        .mvn => encodeMvn(inst),

        // Shifts
        .lsl => encodeLsl(inst),
        .lsr => encodeLsr(inst),
        .asr => encodeAsr(inst),

        // Move
        .mov => encodeMov(inst),
        .movz => encodeMovz(inst),
        .movk => encodeMovk(inst),

        // Floating point arithmetic
        .fadd => encodeFadd(inst),
        .fsub => encodeFsub(inst),
        .fmul => encodeFmul(inst),
        .fdiv => encodeFdiv(inst),

        // Load/Store
        .ldr => encodeLdr(inst),
        .str => encodeStr(inst),
        .ldrb => encodeLdrb(inst),
        .strb => encodeStrb(inst),
        .ldrh => encodeLdrh(inst),
        .strh => encodeStrh(inst),
        .ldp => encodeLdp(inst),
        .stp => encodeStp(inst),

        // Branches
        .b => encodeB(inst),
        .bl => encodeBl(inst),
        .br => encodeBr(inst),
        .blr => encodeBlr(inst),
        .ret => encodeRet(inst),
        .b_cond => encodeBCond(inst),
        .cbz => encodeCbz(inst),
        .cbnz => encodeCbnz(inst),

        // Compare
        .cmp => encodeCmp(inst),
        .cmn => encodeCmn(inst),

        // Conditional
        .csel => encodeCsel(inst),
        .csinc => encodeCsinc(inst),
        .cset => encodeCset(inst),

        // System
        .nop => encodeNop(),
        .brk => encodeBrk(inst),
        .dmb => encodeDmb(),
        .dsb => encodeDsb(),
        .isb => encodeIsb(),

        // Pseudo instructions don't encode to real instructions
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
        => return error.PseudoInstruction,

        else => return error.UnimplementedInstruction,
    };
}

pub const Error = error{
    UnimplementedInstruction,
    PseudoInstruction,
    InvalidOperands,
    InvalidImmediate,
    InvalidRegister,
};

// ============================================================================
// Arithmetic Instructions
// ============================================================================

fn encodeAdd(inst: Mir.Inst) Error!Instruction {
    return switch (inst.ops) {
        .rrr => blk: {
            const data = inst.data.rrr;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            break :blk Instruction.addSubtractShiftedRegister(
                "add",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                data.rm.id(),
                .lsl,
                0,
                false,
            );
        },
        .rri => blk: {
            const data = inst.data.rri;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            if (data.imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.addSubtractImmediate(
                "add",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                @intCast(data.imm),
                0, // unshifted
                false,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeAdds(inst: Mir.Inst) Error!Instruction {
    return switch (inst.ops) {
        .rrr => blk: {
            const data = inst.data.rrr;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            break :blk Instruction.addSubtractShiftedRegister(
                "add",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                data.rm.id(),
                .lsl,
                0,
                true, // Set flags
            );
        },
        .rri => blk: {
            const data = inst.data.rri;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            if (data.imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.addSubtractImmediate(
                "add",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                @intCast(data.imm),
                0, // unshifted
                true, // Set flags
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeSub(inst: Mir.Inst) Error!Instruction {
    return switch (inst.ops) {
        .rrr => blk: {
            const data = inst.data.rrr;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            break :blk Instruction.addSubtractShiftedRegister(
                "sub",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                data.rm.id(),
                .lsl,
                0,
                false,
            );
        },
        .rri => blk: {
            const data = inst.data.rri;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            if (data.imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.addSubtractImmediate(
                "sub",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                @intCast(data.imm),
                0, // unshifted
                false,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeSubs(inst: Mir.Inst) Error!Instruction {
    return switch (inst.ops) {
        .rrr => blk: {
            const data = inst.data.rrr;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            break :blk Instruction.addSubtractShiftedRegister(
                "sub",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                data.rm.id(),
                .lsl,
                0,
                true, // Set flags
            );
        },
        .rri => blk: {
            const data = inst.data.rri;
            const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
            if (data.imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.addSubtractImmediate(
                "sub",
                @enumFromInt(sf),
                data.rd.id(),
                data.rn.id(),
                @intCast(data.imm),
                0, // unshifted
                true, // Set flags
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeMul(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.dataProcessingThreeSource(
        @enumFromInt(sf),
        0b000, // MADD/MSUB
        data.rm.id(),
        31, // Ra = XZR (multiply, not multiply-add)
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeSdiv(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.dataProcessingTwoSource(
        @enumFromInt(sf),
        0b000011, // SDIV
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeUdiv(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.dataProcessingTwoSource(
        @enumFromInt(sf),
        0b000010, // UDIV
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

// ============================================================================
// Logical Instructions
// ============================================================================

fn encodeAnd(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.logicalShiftedRegister(
        .@"and",
        @enumFromInt(sf),
        .lsl,
        0,
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
        false,
    );
}

fn encodeOrr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.logicalShiftedRegister(
        .orr,
        @enumFromInt(sf),
        .lsl,
        0,
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
        false,
    );
}

fn encodeEor(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.logicalShiftedRegister(
        .eor,
        @enumFromInt(sf),
        .lsl,
        0,
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
        false,
    );
}

fn encodeMvn(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // MVN is ORN with XZR/WZR as Rn
    return Instruction.logicalShiftedRegister(
        .orn,
        @enumFromInt(sf),
        .lsl,
        0,
        data.rn.id(),
        31, // XZR/WZR
        data.rd.id(),
        false,
    );
}

// ============================================================================
// Shift Instructions
// ============================================================================

fn encodeLsl(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // LSL (register) is an alias for LSLV
    return Instruction.dataProcessingTwoSource(
        @enumFromInt(sf),
        0b001000, // LSLV
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeLsr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // LSR (register) is an alias for LSRV
    return Instruction.dataProcessingTwoSource(
        @enumFromInt(sf),
        0b001001, // LSRV
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeAsr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // ASR (register) is an alias for ASRV
    return Instruction.dataProcessingTwoSource(
        @enumFromInt(sf),
        0b001010, // ASRV
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

// ============================================================================
// Move Instructions
// ============================================================================

fn encodeMov(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // MOV (register) is an alias for ORR with XZR/WZR as Rn
    return Instruction.logicalShiftedRegister(
        .orr,
        @enumFromInt(sf),
        .lsl,
        0,
        data.rn.id(),
        31, // XZR/WZR
        data.rd.id(),
        false,
    );
}

fn encodeMovz(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rri_shift;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    if (data.imm > 0xFFFF) return error.InvalidImmediate;
    if (data.shift > 48) return error.InvalidImmediate;
    return Instruction.moveWideImmediate(
        "movz",
        @enumFromInt(sf),
        @intCast(data.shift / 16),
        @intCast(data.imm),
        data.rd.id(),
    );
}

fn encodeMovk(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rri_shift;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    if (data.imm > 0xFFFF) return error.InvalidImmediate;
    if (data.shift > 48) return error.InvalidImmediate;
    return Instruction.moveWideImmediate(
        "movk",
        @enumFromInt(sf),
        @intCast(data.shift / 16),
        @intCast(data.imm),
        data.rd.id(),
    );
}

// ============================================================================
// Load/Store Instructions
// ============================================================================

fn encodeLdr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rm;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;

    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0x7FF8) return error.InvalidImmediate;
            const imm12: i12 = @intCast(@divExact(imm, 8));
            break :blk Instruction.loadStoreRegisterImmediate(
                "ldr",
                sf,
                data.rd.id(),
                data.mem.base.id(),
                imm12,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeStr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.mr;
    const sf: u1 = if (data.rs.isGeneralPurpose() and @intFromEnum(data.rs) < 31) 1 else 0;

    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0x7FF8) return error.InvalidImmediate;
            const imm12: i12 = @intCast(@divExact(imm, 8));
            break :blk Instruction.loadStoreRegisterImmediate(
                "str",
                sf,
                data.rs.id(),
                data.mem.base.id(),
                imm12,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeLdrb(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rm;
    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.loadStoreRegisterImmediate(
                "ldrb",
                0, // byte size
                data.rd.id(),
                data.mem.base.id(),
                @as(i12, @intCast(imm)),
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeStrb(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.mr;
    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0xFFF) return error.InvalidImmediate;
            break :blk Instruction.loadStoreRegisterImmediate(
                "strb",
                0, // byte size
                data.rs.id(),
                data.mem.base.id(),
                @as(i12, @intCast(imm)),
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeLdrh(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rm;
    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0x1FFE) return error.InvalidImmediate;
            const imm12: i12 = @intCast(@divExact(imm, 2));
            break :blk Instruction.loadStoreRegisterImmediate(
                "ldrh",
                1, // halfword size
                data.rd.id(),
                data.mem.base.id(),
                imm12,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeStrh(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.mr;
    return switch (data.mem.offset) {
        .immediate => |imm| blk: {
            if (imm < 0 or imm > 0x1FFE) return error.InvalidImmediate;
            const imm12: i12 = @intCast(@divExact(imm, 2));
            break :blk Instruction.loadStoreRegisterImmediate(
                "strh",
                1, // halfword size
                data.rs.id(),
                data.mem.base.id(),
                imm12,
            );
        },
        else => error.InvalidOperands,
    };
}

fn encodeLdp(_: Mir.Inst) Error!Instruction {
    // Simplified - would need proper implementation
    return error.UnimplementedInstruction;
}

fn encodeStp(_: Mir.Inst) Error!Instruction {
    // Simplified - would need proper implementation
    return error.UnimplementedInstruction;
}

// ============================================================================
// Branch Instructions
// ============================================================================

fn encodeB(_: Mir.Inst) Error!Instruction {
    // Offset will be filled in by Lower.zig
    return Instruction.unconditionalBranchImmediate(.b, 0);
}

fn encodeBl(_: Mir.Inst) Error!Instruction {
    // Offset will be filled in by Lower.zig
    return Instruction.unconditionalBranchImmediate(.bl, 0);
}

fn encodeBr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.r;
    return Instruction.unconditionalBranchRegister(
        "br",
        false,
        false,
        data.id(),
        0,
    );
}

fn encodeBlr(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.r;
    return Instruction.unconditionalBranchRegister(
        "blr",
        false,
        false,
        data.id(),
        0,
    );
}

fn encodeRet(_: Mir.Inst) Error!Instruction {
    // RET defaults to X30 (LR)
    return Instruction.unconditionalBranchRegister(
        "ret",
        false,
        false,
        30, // X30/LR
        0,
    );
}

fn encodeBCond(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rc;
    // Offset will be filled in by Lower.zig
    return Instruction.conditionalBranchImmediate(0, conditionToCode(data.cond));
}

fn encodeCbz(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.r_rel;
    const sf: u1 = if (data.rn.isGeneralPurpose() and @intFromEnum(data.rn) < 31) 1 else 0;
    // Offset will be filled in by Lower.zig
    return Instruction.compareAndBranchImmediate(
        "cbz",
        @enumFromInt(sf),
        0,
        data.rn.id(),
    );
}

fn encodeCbnz(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.r_rel;
    const sf: u1 = if (data.rn.isGeneralPurpose() and @intFromEnum(data.rn) < 31) 1 else 0;
    // Offset will be filled in by Lower.zig
    return Instruction.compareAndBranchImmediate(
        "cbnz",
        @enumFromInt(sf),
        0,
        data.rn.id(),
    );
}

// ============================================================================
// Compare Instructions
// ============================================================================

fn encodeCmp(inst: Mir.Inst) Error!Instruction {
    // CMP is an alias for SUBS with XZR/WZR as destination
    return switch (inst.ops) {
        .rr => blk: {
            const data = inst.data.rr;
            const sf: u1 = if (data.rn.isGeneralPurpose() and @intFromEnum(data.rn) < 31) 1 else 0;
            break :blk Instruction.addSubtractShiftedRegister(
                "subs",
                @enumFromInt(sf),
                31, // XZR/WZR
                data.rn.id(),
                data.rd.id(), // Using rd for Rm
                .lsl,
                0,
                true, // Set flags
            );
        },
        .ri => {
            // TODO: addSubtractImmediate not yet implemented
            return error.UnimplementedInstruction;
        },
        else => error.InvalidOperands,
    };
}

fn encodeCmn(inst: Mir.Inst) Error!Instruction {
    // CMN is an alias for ADDS with XZR/WZR as destination
    const data = inst.data.rr;
    const sf: u1 = if (data.rn.isGeneralPurpose() and @intFromEnum(data.rn) < 31) 1 else 0;
    return Instruction.addSubtractShiftedRegister(
        "adds",
        @enumFromInt(sf),
        31, // XZR/WZR
        data.rn.id(),
        data.rd.id(), // Using rd for Rm
        .lsl,
        0,
        true, // Set flags
    );
}

// ============================================================================
// Conditional Instructions
// ============================================================================

fn encodeCsel(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrrc;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.conditionalSelect(
        "csel",
        @enumFromInt(sf),
        data.rd.id(),
        data.rn.id(),
        data.rm.id(),
        conditionToCode(data.cond),
    );
}

fn encodeCsinc(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrrc;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.conditionalSelect(
        "csinc",
        @enumFromInt(sf),
        data.rd.id(),
        data.rn.id(),
        data.rm.id(),
        conditionToCode(data.cond),
    );
}

fn encodeCset(inst: Mir.Inst) Error!Instruction {
    // CSET is an alias for CSINC with Rn=Rm=XZR/WZR and inverted condition
    const data = inst.data.rrc;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    return Instruction.conditionalSelect(
        "csinc",
        @enumFromInt(sf),
        data.rd.id(),
        31, // XZR/WZR
        31, // XZR/WZR
        conditionToCode(data.cond.negate()),
    );
}

// ============================================================================
// System Instructions
// ============================================================================

fn encodeNop() Instruction {
    return Instruction.nop();
}

fn encodeBrk(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.imm;
    if (data > 0xFFFF) return error.InvalidImmediate;
    return Instruction.exceptionGeneration("brk", @intCast(data), 0b001);
}

fn encodeDmb() Instruction {
    return Instruction.barriers("dmb", .sy);
}

fn encodeDsb() Instruction {
    return Instruction.barriers("dsb", .sy);
}

fn encodeIsb() Instruction {
    return Instruction.barriers("isb", .sy);
}

// ============================================================================
// Floating Point Arithmetic
// ============================================================================

fn encodeFadd(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FADD Dd, Dn, Dm (scalar floating point add, double precision)
    // TODO: Handle different float sizes (f16, f32, f64)
    // For now, assume f64 (double precision)
    return Instruction.floatingPointDataProcessingTwoSource(
        .fadd,
        .@"64",
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeFsub(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FSUB Dd, Dn, Dm (scalar floating point subtract, double precision)
    return Instruction.floatingPointDataProcessingTwoSource(
        .fsub,
        .@"64",
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeFmul(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FMUL Dd, Dn, Dm (scalar floating point multiply, double precision)
    return Instruction.floatingPointDataProcessingTwoSource(
        .fmul,
        .@"64",
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

fn encodeFdiv(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FDIV Dd, Dn, Dm (scalar floating point divide, double precision)
    return Instruction.floatingPointDataProcessingTwoSource(
        .fdiv,
        .@"64",
        data.rm.id(),
        data.rn.id(),
        data.rd.id(),
    );
}

const std = @import("std");
const expect = std.testing.expect;

test "encode ADD instruction" {
    // Test encoding ADD X0, X1, X2 (rrr variant)
    const inst = Mir.Inst{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = Register.x0,
            .rn = Register.x1,
            .rm = Register.x2,
        } },
    };
    const encoded = try encode(inst);
    const expected = Instruction.addSubtractShiftedRegister(.add, Register.x0, Register.x1, Register.x2, .lsl, 0);
    try expect(encoded.toU32() == expected.toU32());
}

test "encode MOV instruction" {
    // Test encoding MOV X0, X1 (register to register)
    const inst = Mir.Inst{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = Register.x0,
            .rn = Register.x1,
        } },
    };
    const encoded = try encode(inst);
    const expected = Instruction.logicalShiftedRegister(.orr, Register.x0, Register.xzr, Register.x1, .lsl, 0);
    try expect(encoded.toU32() == expected.toU32());
}

test "encode LDR instruction" {
    // Test encoding LDR X0, [X1]
    const inst = Mir.Inst{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rt = Register.x0,
            .rn = Register.x1,
            .offset = .{ .immediate = 0 },
        } },
    };
    const encoded = try encode(inst);
    const expected = Instruction.loadStoreRegisterImmediate(.ldr, Register.x0, Register.x1, Instruction.LoadStoreOffset.imm(0));
    try expect(encoded.toU32() == expected.toU32());
}

test "encode STR instruction" {
    // Test encoding STR X0, [X1]
    const inst = Mir.Inst{
        .tag = .str,
        .ops = .mr,
        .data = .{ .mr = .{
            .rt = Register.x0,
            .rn = Register.x1,
            .offset = .{ .immediate = 0 },
        } },
    };
    const encoded = try encode(inst);
    const expected = Instruction.loadStoreRegisterImmediate(.str, Register.x0, Register.x1, Instruction.LoadStoreOffset.imm(0));
    try expect(encoded.toU32() == expected.toU32());
}

test "encode B instruction" {
    // Test encoding B (unconditional branch)
    const inst = Mir.Inst{
        .tag = .b,
        .ops = .none,
        .data = .{ .inst = @enumFromInt(0) },
    };
    const encoded = try encode(inst);
    const expected = Instruction.unconditionalBranchImmediate(true, 0);
    try expect(encoded.toU32() == expected.toU32());
}

test "encode RET instruction" {
    // Test encoding RET (return from subroutine)
    const inst = Mir.Inst{
        .tag = .ret,
        .ops = .none,
        .data = .{ .reg = Register.x30 },
    };
    const encoded = try encode(inst);
    const expected = Instruction.unconditionalBranchRegister(.ret, Register.x30);
    try expect(encoded.toU32() == expected.toU32());
}

test "encode CMP instruction" {
    // Test encoding CMP X0, X1 (compare registers)
    const inst = Mir.Inst{
        .tag = .cmp,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = Register.xzr,
            .rn = Register.x0,
        } },
    };
    const encoded = try encode(inst);
    const expected = Instruction.addSubtractShiftedRegister(.subs, Register.xzr, Register.x0, Register.xzr, .lsl, 0);
    try expect(encoded.toU32() == expected.toU32());
}
