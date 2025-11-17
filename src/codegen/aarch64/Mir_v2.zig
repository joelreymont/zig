//! Machine Intermediate Representation for ARM64 (AArch64)
//! This data is produced by aarch64 CodeGen and consumed by aarch64 Lower.
//! These instructions represent abstract ARM64 operations before encoding.
//! MIR postpones instruction encoding and offset assignment until Lower,
//! allowing for optimizations and proper branch offset calculation.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bits = @import("bits.zig");
const Condition = bits.Condition;
const Register = bits.Register;
const Memory = bits.Memory;
const FrameIndex = bits.FrameIndex;
const Immediate = bits.Immediate;

instructions: std.MultiArrayList(Inst).Slice,
extra: []const u32,
string_bytes: []const u8,
locals: []const Local,
table: []const Inst.Index,
frame_locs: std.MultiArrayList(FrameLoc).Slice,

pub const Inst = struct {
    tag: Tag,
    ops: Ops,
    data: Data,

    pub const Index = u32;

    /// ARM64 instruction tags (abstract operations)
    pub const Tag = enum(u16) {
        // ============================================================================
        // Data Processing - Arithmetic
        // ============================================================================

        /// ADD - Add
        add,
        /// ADDS - Add and set flags
        adds,
        /// SUB - Subtract
        sub,
        /// SUBS - Subtract and set flags (also CMP when Rd=ZR)
        subs,
        /// ADC - Add with carry
        adc,
        /// ADCS - Add with carry and set flags
        adcs,
        /// SBC - Subtract with carry
        sbc,
        /// SBCS - Subtract with carry and set flags
        sbcs,
        /// NEG - Negate
        neg,
        /// NEGS - Negate and set flags
        negs,
        /// NGC - Negate with carry
        ngc,

        /// MUL - Multiply
        mul,
        /// MNEG - Multiply-negate
        mneg,
        /// MADD - Multiply-add
        madd,
        /// MSUB - Multiply-subtract
        msub,
        /// SMULL - Signed multiply long
        smull,
        /// SMULH - Signed multiply high
        smulh,
        /// UMULL - Unsigned multiply long
        umull,
        /// UMULH - Unsigned multiply high
        umulh,

        /// SDIV - Signed divide
        sdiv,
        /// UDIV - Unsigned divide
        udiv,

        // ============================================================================
        // Data Processing - Logical
        // ============================================================================

        /// AND - Bitwise AND
        and_,
        /// ANDS - Bitwise AND and set flags (also TST when Rd=ZR)
        ands,
        /// ORR - Bitwise OR
        orr,
        /// ORN - Bitwise OR NOT
        orn,
        /// EOR - Bitwise XOR
        eor,
        /// EON - Bitwise XOR NOT
        eon,
        /// BIC - Bit clear (AND NOT)
        bic,
        /// BICS - Bit clear and set flags
        bics,
        /// MVN - Bitwise NOT
        mvn,

        // ============================================================================
        // Data Processing - Shift and Rotate
        // ============================================================================

        /// LSL - Logical shift left
        lsl,
        /// LSR - Logical shift right
        lsr,
        /// ASR - Arithmetic shift right
        asr,
        /// ROR - Rotate right
        ror,

        // ============================================================================
        // Data Processing - Bit Operations
        // ============================================================================

        /// CLZ - Count leading zeros
        clz,
        /// CLS - Count leading sign bits
        cls,
        /// REV - Byte reverse
        rev,
        /// REV16 - Reverse bytes in 16-bit halfwords
        rev16,
        /// REV32 - Reverse bytes in 32-bit words
        rev32,
        /// RBIT - Reverse bit order
        rbit,

        // ============================================================================
        // Data Processing - Move
        // ============================================================================

        /// MOV - Move (register)
        mov,
        /// MOVZ - Move wide with zero
        movz,
        /// MOVN - Move wide with NOT
        movn,
        /// MOVK - Move wide with keep
        movk,

        // ============================================================================
        // Load/Store
        // ============================================================================

        /// LDR - Load register
        ldr,
        /// LDRB - Load register byte
        ldrb,
        /// LDRH - Load register halfword
        ldrh,
        /// LDRSB - Load register signed byte
        ldrsb,
        /// LDRSH - Load register signed halfword
        ldrsh,
        /// LDRSW - Load register signed word
        ldrsw,

        /// STR - Store register
        str,
        /// STRB - Store register byte
        strb,
        /// STRH - Store register halfword
        strh,

        /// LDP - Load pair of registers
        ldp,
        /// STP - Store pair of registers
        stp,

        /// LDUR - Load register (unscaled offset)
        ldur,
        /// STUR - Store register (unscaled offset)
        stur,

        // ============================================================================
        // Branches
        // ============================================================================

        /// B - Branch
        b,
        /// BL - Branch with link
        bl,
        /// BR - Branch to register
        br,
        /// BLR - Branch with link to register
        blr,
        /// RET - Return from subroutine
        ret,

        /// B.cond - Conditional branch
        b_cond,
        /// CBZ - Compare and branch if zero
        cbz,
        /// CBNZ - Compare and branch if nonzero
        cbnz,
        /// TBZ - Test bit and branch if zero
        tbz,
        /// TBNZ - Test bit and branch if nonzero
        tbnz,

        // ============================================================================
        // Compare
        // ============================================================================

        /// CMP - Compare (alias for SUBS with XZR/WZR destination)
        cmp,
        /// CMN - Compare negative (alias for ADDS with XZR/WZR destination)
        cmn,
        /// TST - Test (alias for ANDS with XZR/WZR destination)
        tst,

        // ============================================================================
        // Conditional Operations
        // ============================================================================

        /// CSEL - Conditional select
        csel,
        /// CSINC - Conditional select increment
        csinc,
        /// CSINV - Conditional select invert
        csinv,
        /// CSNEG - Conditional select negate
        csneg,
        /// CSET - Conditional set (alias for CSINC)
        cset,
        /// CSETM - Conditional set mask (alias for CSINV)
        csetm,
        /// CINC - Conditional increment (alias for CSINC)
        cinc,
        /// CINV - Conditional invert (alias for CSINV)
        cinv,
        /// CNEG - Conditional negate (alias for CSNEG)
        cneg,
        /// CCMP - Conditional compare
        ccmp,
        /// CCMN - Conditional compare negative
        ccmn,

        // ============================================================================
        // Bit Field Operations
        // ============================================================================

        /// UBFM - Unsigned bitfield move
        ubfm,
        /// SBFM - Signed bitfield move
        sbfm,
        /// BFM - Bitfield move
        bfm,
        /// UBFX - Unsigned bitfield extract
        ubfx,
        /// SBFX - Signed bitfield extract
        sbfx,
        /// BFI - Bitfield insert
        bfi,
        /// BFXIL - Bitfield extract and insert low
        bfxil,

        /// SXTB - Sign extend byte
        sxtb,
        /// SXTH - Sign extend halfword
        sxth,
        /// SXTW - Sign extend word
        sxtw,
        /// UXTB - Zero extend byte
        uxtb,
        /// UXTH - Zero extend halfword
        uxth,

        // ============================================================================
        // System/Special
        // ============================================================================

        /// NOP - No operation
        nop,
        /// BRK - Breakpoint
        brk,
        /// HLT - Halt
        hlt,
        /// DMB - Data memory barrier
        dmb,
        /// DSB - Data synchronization barrier
        dsb,
        /// ISB - Instruction synchronization barrier
        isb,
        /// SVC - Supervisor call
        svc,

        // ============================================================================
        // Atomic Operations
        // ============================================================================

        /// LDADD - Atomic add
        ldadd,
        /// LDCLR - Atomic clear
        ldclr,
        /// LDEOR - Atomic XOR
        ldeor,
        /// LDSET - Atomic set
        ldset,
        /// LDSMAX - Atomic signed maximum
        ldsmax,
        /// LDSMIN - Atomic signed minimum
        ldsmin,
        /// LDUMAX - Atomic unsigned maximum
        ldumax,
        /// LDUMIN - Atomic unsigned minimum
        ldumin,
        /// SWP - Swap
        swp,
        /// CAS - Compare and swap
        cas,

        // ============================================================================
        // Floating Point
        // ============================================================================

        /// FADD - Floating-point add
        fadd,
        /// FSUB - Floating-point subtract
        fsub,
        /// FMUL - Floating-point multiply
        fmul,
        /// FDIV - Floating-point divide
        fdiv,
        /// FMADD - Floating-point multiply-add
        fmadd,
        /// FMSUB - Floating-point multiply-subtract
        fmsub,
        /// FNEG - Floating-point negate
        fneg,
        /// FABS - Floating-point absolute
        fabs,
        /// FSQRT - Floating-point square root
        fsqrt,
        /// FCMP - Floating-point compare
        fcmp,
        /// FCSEL - Floating-point conditional select
        fcsel,
        /// FMOV - Floating-point move
        fmov,
        /// FCVT - Floating-point convert
        fcvt,
        /// FCVTZS - Floating-point convert to signed integer
        fcvtzs,
        /// FCVTZU - Floating-point convert to unsigned integer
        fcvtzu,
        /// SCVTF - Signed integer convert to floating-point
        scvtf,
        /// UCVTF - Unsigned integer convert to floating-point
        ucvtf,

        // ============================================================================
        // SIMD/NEON
        // ============================================================================

        /// DUP - Duplicate vector element
        dup,
        /// INS - Insert vector element
        ins,
        /// UMOV - Unsigned move vector element
        umov,
        /// SMOV - Signed move vector element
        smov,

        // ============================================================================
        // Address Calculation
        // ============================================================================

        /// ADR - Form PC-relative address
        adr,
        /// ADRP - Form PC-relative address to 4KB page
        adrp,

        // ============================================================================
        // Pseudo Instructions (for debugging, prologue/epilogue, etc.)
        // ============================================================================

        /// Pseudo: Debug prologue end
        pseudo_dbg_prologue_end,
        /// Pseudo: Debug epilogue begin
        pseudo_dbg_epilogue_begin,
        /// Pseudo: Debug line info
        pseudo_dbg_line,
        /// Pseudo: Debug enter block
        pseudo_dbg_enter_block,
        /// Pseudo: Debug leave block
        pseudo_dbg_leave_block,
        /// Pseudo: Enter function frame
        pseudo_enter_frame,
        /// Pseudo: Exit function frame
        pseudo_exit_frame,
        /// Pseudo: Dead value (for tracking)
        pseudo_dead,
        /// Pseudo: Spill to stack
        pseudo_spill,
        /// Pseudo: Reload from stack
        pseudo_reload,
    };

    /// Operand patterns
    pub const Ops = enum(u16) {
        // No operands
        none,

        // Register operands
        /// Rd
        r,
        /// Rd, Rn
        rr,
        /// Rd, Rn, Rm
        rrr,
        /// Rd, Rn, Rm, Ra (4-register)
        rrrr,

        // Immediate operands
        /// Rd, #imm
        ri,
        /// Rd, Rn, #imm
        rri,
        /// Rd, Rn, #imm, #shift
        rri_shift,

        // Memory operands
        /// Rd, [Xn]
        rm,
        /// [Xn], Rd
        mr,
        /// Rd, Rt, [Xn] (pair)
        rrm,
        /// [Xn], Rd, Rt (pair)
        mrr,

        // Conditional operands
        /// Rd, Rn, Rm, cond
        rrrc,
        /// Rd, Rn, cond
        rrc,
        /// Rn, cond
        rc,

        // Branch operands
        /// target (immediate offset)
        rel,
        /// Rn, target
        r_rel,

        // Bit field operands
        /// Rd, Rn, #lsb, #width
        rr_bitmask,

        // System operands
        /// #imm (for SVC, BRK, etc.)
        imm,

        // Pseudo instruction operands
        pseudo_dbg_prologue_end_none,
        pseudo_dbg_epilogue_begin_none,
        pseudo_dbg_line_line_column,
        pseudo_dbg_enter_block_none,
        pseudo_dbg_leave_block_none,
        pseudo_enter_frame_none,
        pseudo_exit_frame_none,
        pseudo_dead_r,
        pseudo_spill_rm,
        pseudo_reload_mr,
    };

    /// Instruction data (operands)
    pub const Data = union {
        /// No data
        none: void,

        /// Single register
        r: Register,

        /// Two registers
        rr: struct {
            rd: Register,
            rn: Register,
        },

        /// Three registers
        rrr: struct {
            rd: Register,
            rn: Register,
            rm: Register,
        },

        /// Four registers
        rrrr: struct {
            rd: Register,
            rn: Register,
            rm: Register,
            ra: Register,
        },

        /// Register + immediate
        ri: struct {
            rd: Register,
            imm: u64,
        },

        /// Two registers + immediate
        rri: struct {
            rd: Register,
            rn: Register,
            imm: u64,
        },

        /// Two registers + immediate + shift
        rri_shift: struct {
            rd: Register,
            rn: Register,
            imm: u64,
            shift: u6,
        },

        /// Register + memory
        rm: struct {
            rd: Register,
            mem: Memory,
        },

        /// Memory + register
        mr: struct {
            mem: Memory,
            rs: Register,
        },

        /// Two registers + memory (for STP - store pair)
        rrm: struct {
            mem: Memory,
            r1: Register,
            r2: Register,
        },

        /// Memory + two registers (for LDP - load pair)
        mrr: struct {
            mem: Memory,
            r1: Register,
            r2: Register,
        },

        /// Three registers + condition
        rrrc: struct {
            rd: Register,
            rn: Register,
            rm: Register,
            cond: Condition,
        },

        /// Two registers + condition
        rrc: struct {
            rd: Register,
            rn: Register,
            cond: Condition,
        },

        /// Register + condition + branch target (for conditional branches like CBZ, CBNZ)
        rc: struct {
            rn: Register,
            cond: Condition,
            target: ?Inst.Index = null,
        },

        /// Branch target (offset)
        rel: struct {
            target: Inst.Index,
        },

        /// Register + branch target
        r_rel: struct {
            rn: Register,
            target: Inst.Index,
        },

        /// Bitfield operation
        rr_bitmask: struct {
            rd: Register,
            rn: Register,
            lsb: u6,
            width: u6,
        },

        /// Immediate value
        imm: u64,

        /// Debug line/column
        line_column: struct {
            line: u32,
            column: u32,
        },

        /// Frame index
        frame_index: FrameIndex,

        /// Extra data offset
        payload: u32,
    };
};

/// Local variable descriptor
pub const Local = struct {
    /// Index into string_bytes for name
    name: u32,
    /// Type index
    ty: u32,
};

/// Frame location descriptor
pub const FrameLoc = struct {
    /// Frame index
    index: FrameIndex,
    /// Offset from frame base
    offset: i32,
    /// Size in bytes
    size: u32,
    /// Alignment
    alignment: u32,
};

/// Deinitialize and free MIR resources
pub fn deinit(mir: *@This(), gpa: Allocator) void {
    gpa.free(mir.instructions.items(.tag));
    gpa.free(mir.extra);
    gpa.free(mir.string_bytes);
    gpa.free(mir.locals);
    gpa.free(mir.table);
    gpa.free(mir.frame_locs.items(.index));
    mir.* = undefined;
}

/// Emit MIR to machine code
/// This is the entry point called by codegen.zig
pub fn emit(
    mir: @This(),
    lf: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    atom_index: u32,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) error{ CodegenFail, OutOfMemory, Overflow, RelocationNotByteAligned, WriteFailed }!void {
    const Emit = @import("Emit.zig");
    return Emit.emitMir(mir, lf, pt, src_loc, func_index, atom_index, w, debug_output);
}

const Mir = @This();
const link = @import("../../link.zig");
const Zcu = @import("../../Zcu.zig");
const InternPool = @import("../../InternPool.zig");

test "Mir basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var insts: std.MultiArrayList(Inst) = .{};
    defer insts.deinit(gpa);

    // Test adding some instructions
    try insts.append(gpa, .{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = .x0,
            .rn = .x1,
            .rm = .x2,
        } },
    });

    try insts.append(gpa, .{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = .x3,
            .rn = .x4,
        } },
    });

    try std.testing.expectEqual(@as(usize, 2), insts.len);
    try std.testing.expectEqual(Inst.Tag.add, insts.items(.tag)[0]);
    try std.testing.expectEqual(Inst.Tag.mov, insts.items(.tag)[1]);
}
