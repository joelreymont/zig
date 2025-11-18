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
        .neg => encodeNeg(inst),

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
        .ldxr => encodeLdxr(inst),
        .stxr => encodeStxr(inst),

        // Atomic LSE instructions
        .ldadd => encodeAtomicLSE(inst),
        .ldclr => encodeAtomicLSE(inst),
        .ldeor => encodeAtomicLSE(inst),
        .ldset => encodeAtomicLSE(inst),
        .ldsmax => encodeAtomicLSE(inst),
        .ldsmin => encodeAtomicLSE(inst),
        .ldumax => encodeAtomicLSE(inst),
        .ldumin => encodeAtomicLSE(inst),
        .swp => encodeAtomicLSE(inst),
        .cas => encodeAtomicLSE(inst),

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
// Atomic Instruction Packed Structs (ARMv8.1-A LSE + Exclusive Load/Store)
// ============================================================================

/// Load Exclusive Register - LDXR Xt, [Xn]
/// ARM64 Reference Manual C6.2.146
const LoadExclusive = packed struct(u32) {
    Rt: u5,          // [4:0] Destination register
    Rn: u5,          // [9:5] Base address register
    Rt2: u5 = 0b11111, // [14:10] Reserved (must be 11111)
    o0: u1 = 0,      // [15] Ordered flag
    Rs: u5 = 0b11111,  // [20:16] Reserved (must be 11111 for load)
    o1: u1 = 0,      // [21] Ordered flag
    L: u1 = 1,       // [22] Load (1) vs Store (0)
    o2: u1 = 0,      // [23] Ordered flag
    fixed: u6 = 0b001000, // [29:24] Fixed bits
    size: u2 = 0b11, // [31:30] Size (11=64-bit)
};

/// Store Exclusive Register - STXR Ws, Xt, [Xn]
/// ARM64 Reference Manual C6.2.303
const StoreExclusive = packed struct(u32) {
    Rt: u5,          // [4:0] Value register
    Rn: u5,          // [9:5] Base address register
    Rt2: u5 = 0b11111, // [14:10] Reserved (must be 11111)
    o0: u1 = 0,      // [15] Ordered flag
    Rs: u5,          // [20:16] Status register (Ws)
    o1: u1 = 0,      // [21] Ordered flag
    L: u1 = 0,       // [22] Load (1) vs Store (0)
    o2: u1 = 0,      // [23] Ordered flag
    fixed: u6 = 0b001000, // [29:24] Fixed bits
    size: u2 = 0b11, // [31:30] Size (11=64-bit)
};

/// LSE Atomic Memory Operation - LDADD, LDCLR, LDEOR, LDSET, etc.
/// ARM64 Reference Manual C6.2.131-138
const AtomicLSE = packed struct(u32) {
    Rt: u5,          // [4:0] Destination register (receives old value)
    Rn: u5,          // [9:5] Base address register
    o3: u2 = 0,      // [11:10] Reserved
    opc2: u3,        // [14:12] Secondary opcode (0b000 for most, 0b100 for SWP)
    o4: u1 = 0,      // [15] Reserved
    Rs: u5,          // [20:16] Source operand register
    opc: u3,         // [23:21] Primary opcode (selects operation)
    fixed: u4 = 0b1000, // [27:24] Fixed bits
    R: u1 = 1,       // [28] Release semantics
    A: u1 = 1,       // [29] Acquire semantics
    size: u2 = 0b11, // [31:30] Size (11=64-bit)
};

/// Compare and Swap - CAS Rs, Rt, [Xn]
/// ARM64 Reference Manual C6.2.42
const CompareAndSwap = packed struct(u32) {
    Rt: u5,          // [4:0] Destination/comparison register
    Rn: u5,          // [9:5] Base address register
    o3: u5 = 0b11111, // [14:10] Reserved (must be 11111)
    L: u1 = 1,       // [15] Load-Acquire
    Rs: u5,          // [20:16] Source value register
    o2: u1 = 1,      // [21] Fixed bit
    o1: u1 = 0,      // [22] Fixed bit
    o0: u1 = 0,      // [23] Fixed bit
    fixed: u5 = 0b01000, // [28:24] Fixed bits (001000)
    R: u1 = 1,       // [29] Release
    size: u2 = 0b11, // [31:30] Size (11=64-bit)
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

fn encodeNeg(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rr;
    const sf: u1 = if (data.rd.isGeneralPurpose() and @intFromEnum(data.rd) < 31) 1 else 0;
    // NEG is SUB Rd, XZR, Rn (subtract from zero)
    return Instruction.addSubtractShiftedRegister(
        "sub",
        @enumFromInt(sf),
        data.rd.id(),
        31, // XZR/WZR
        data.rn.id(),
        .lsl,
        0,
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

fn encodeLdp(inst: Mir.Inst) Error!Instruction {
    // LDP - Load Pair of Registers
    // Supports pre-indexed, post-indexed, and signed offset addressing modes
    const data = inst.data.mrr;

    // Determine register size (64-bit X registers or 32-bit W registers)
    const sf: encoding.Register.GeneralSize = if (@intFromEnum(data.r1) < 31)
        .doubleword
    else
        .word;

    // The immediate is scaled by register size (8 for 64-bit, 4 for 32-bit)
    const scale: i32 = if (sf == .doubleword) 8 else 4;

    return switch (data.mem.offset) {
        .pre_index => |offset| blk: {
            // Pre-indexed: LDP Xt1, Xt2, [Xn, #imm]!
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const ldp_insn = encoding.Instruction.LoadStore.RegisterPairPreIndexed.Integer.Ldp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_pre_indexed = .{
                        .integer = .{ .ldp = ldp_insn },
                    },
                },
            });
        },
        .post_index => |offset| blk: {
            // Post-indexed: LDP Xt1, Xt2, [Xn], #imm
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const ldp_insn = encoding.Instruction.LoadStore.RegisterPairPostIndexed.Integer.Ldp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_post_indexed = .{
                        .integer = .{ .ldp = ldp_insn },
                    },
                },
            });
        },
        .immediate => |offset| blk: {
            // Signed offset: LDP Xt1, Xt2, [Xn, #imm]
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const ldp_insn = encoding.Instruction.LoadStore.RegisterPairOffset.Integer.Ldp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_offset = .{
                        .integer = .{ .ldp = ldp_insn },
                    },
                },
            });
        },
        else => error.InvalidOperands,
    };
}

fn encodeStp(inst: Mir.Inst) Error!Instruction {
    // STP - Store Pair of Registers
    // Supports pre-indexed, post-indexed, and signed offset addressing modes
    const data = inst.data.rrm;

    // Determine register size (64-bit X registers or 32-bit W registers)
    // X registers (0-30) have sf=1, W registers have sf=0
    const sf: encoding.Register.GeneralSize = if (@intFromEnum(data.r1) < 31)
        .doubleword
    else
        .word;

    // The immediate is scaled by register size (8 for 64-bit, 4 for 32-bit)
    const scale: i32 = if (sf == .doubleword) 8 else 4;

    return switch (data.mem.offset) {
        .pre_index => |offset| blk: {
            // Pre-indexed: STP Xt1, Xt2, [Xn, #imm]!
            // Writes back the updated address to the base register
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const stp_insn = encoding.Instruction.LoadStore.RegisterPairPreIndexed.Integer.Stp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_pre_indexed = .{
                        .integer = .{ .stp = stp_insn },
                    },
                },
            });
        },
        .post_index => |offset| blk: {
            // Post-indexed: STP Xt1, Xt2, [Xn], #imm
            // Stores at Xn, then adds imm to Xn
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const stp_insn = encoding.Instruction.LoadStore.RegisterPairPostIndexed.Integer.Stp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_post_indexed = .{
                        .integer = .{ .stp = stp_insn },
                    },
                },
            });
        },
        .immediate => |offset| blk: {
            // Signed offset: STP Xt1, Xt2, [Xn, #imm]
            // No writeback
            const imm7: i7 = @intCast(@divExact(offset, scale));
            const stp_insn = encoding.Instruction.LoadStore.RegisterPairOffset.Integer.Stp{
                .Rt = @enumFromInt(data.r1.id()),
                .Rn = @enumFromInt(data.mem.base.id()),
                .Rt2 = @enumFromInt(data.r2.id()),
                .imm7 = imm7,
                .sf = sf,
            };
            break :blk @bitCast(encoding.Instruction{
                .load_store = .{
                    .register_pair_offset = .{
                        .integer = .{ .stp = stp_insn },
                    },
                },
            });
        },
        else => error.InvalidOperands,
    };
}

fn encodeLdxr(inst: Mir.Inst) Error!Instruction {
    // LDXR - Load Exclusive Register
    // Format: LDXR Xt, [Xn{, #0}]
    // Uses packed struct with proper field layout
    const data = inst.data.rm;

    const ldxr_insn = LoadExclusive{
        .Rt = data.rd.id(),
        .Rn = data.mem.base.id(),
        // All other fields use default values from struct definition
    };

    // Bitcast packed struct to Instruction
    return @bitCast(ldxr_insn);
}

fn encodeStxr(inst: Mir.Inst) Error!Instruction {
    // STXR - Store Exclusive Register
    // Format: STXR Ws, Xt, [Xn{, #0}]
    // Uses packed struct with proper field layout
    const data = inst.data.rrm;

    const stxr_insn = StoreExclusive{
        .Rt = data.r2.id(),  // Value register
        .Rn = data.mem.base.id(),  // Address register
        .Rs = data.r1.id(),  // Status register (Ws)
        // All other fields use default values from struct definition
    };

    // Bitcast packed struct to Instruction
    return @bitCast(stxr_insn);
}

fn encodeAtomicLSE(inst: Mir.Inst) Error!Instruction {
    // Atomic LSE (Large System Extensions) instructions
    // Uses packed structs with proper field layout
    const data = inst.data.rrm;

    // CAS has a different encoding pattern - use separate struct
    if (inst.tag == .cas) {
        const cas_insn = CompareAndSwap{
            .Rt = data.r2.id(),  // Destination/comparison register
            .Rn = data.mem.base.id(),  // Base address
            .Rs = data.r1.id(),  // Source value register
            // All other fields use default values from struct definition
        };
        return @bitCast(cas_insn);
    }

    // Determine primary opcode based on instruction tag
    const opc: u3 = switch (inst.tag) {
        .ldadd => 0b000,
        .ldclr => 0b001,
        .ldeor => 0b010,
        .ldset => 0b011,
        .ldsmax => 0b100,
        .ldsmin => 0b101,
        .ldumax => 0b110,
        .ldumin => 0b111,
        .swp => 0b000, // SWP uses different opc2
        else => return error.InvalidOperands,
    };

    // opc2 field distinguishes SWP from LDADD (both have opc=000)
    const opc2: u3 = if (inst.tag == .swp) 0b100 else 0b000;

    const lse_insn = AtomicLSE{
        .Rt = data.r2.id(),  // Destination (receives old value)
        .Rn = data.mem.base.id(),  // Memory address
        .Rs = data.r1.id(),  // Source operand
        .opc = opc,  // Primary opcode
        .opc2 = opc2,  // Secondary opcode
        // A=1, R=1, size=11, fixed=1000 from struct defaults
    };

    // Bitcast packed struct to Instruction
    return @bitCast(lse_insn);
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
    return .{ .data_processing_vector = .{ .float_data_processing_two_source = .{
        .fadd = .{
            .Rd = @enumFromInt(data.rd.id()),
            .Rn = @enumFromInt(data.rn.id()),
            .Rm = @enumFromInt(data.rm.id()),
            .ftype = .double,
        },
    } } };
}

fn encodeFsub(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FSUB Dd, Dn, Dm (scalar floating point subtract, double precision)
    return .{ .data_processing_vector = .{ .float_data_processing_two_source = .{
        .fsub = .{
            .Rd = @enumFromInt(data.rd.id()),
            .Rn = @enumFromInt(data.rn.id()),
            .Rm = @enumFromInt(data.rm.id()),
            .ftype = .double,
        },
    } } };
}

fn encodeFmul(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FMUL Dd, Dn, Dm (scalar floating point multiply, double precision)
    return .{ .data_processing_vector = .{ .float_data_processing_two_source = .{
        .fmul = .{
            .Rd = @enumFromInt(data.rd.id()),
            .Rn = @enumFromInt(data.rn.id()),
            .Rm = @enumFromInt(data.rm.id()),
            .ftype = .double,
        },
    } } };
}

fn encodeFdiv(inst: Mir.Inst) Error!Instruction {
    const data = inst.data.rrr;
    // FDIV Dd, Dn, Dm (scalar floating point divide, double precision)
    return .{ .data_processing_vector = .{ .float_data_processing_two_source = .{
        .fdiv = .{
            .Rd = @enumFromInt(data.rd.id()),
            .Rn = @enumFromInt(data.rn.id()),
            .Rm = @enumFromInt(data.rm.id()),
            .ftype = .double,
        },
    } } };
}
