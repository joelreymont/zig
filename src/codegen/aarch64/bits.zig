//! ARM64 (AArch64) architecture-specific types and constants
//! This module defines registers, condition codes, memory addressing modes,
//! and other ARM64-specific primitives used by the CodeGen backend.

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const Allocator = std.mem.Allocator;
const InternPool = @import("../../InternPool.zig");
const link = @import("../../link.zig");

/// ARM64 condition codes (NZCV flags)
/// These map to the condition field in conditional instructions (bits [15:12])
pub const Condition = enum(u4) {
    /// Equal (Z == 1)
    eq = 0b0000,
    /// Not equal (Z == 0)
    ne = 0b0001,
    /// Carry set / unsigned higher or same (C == 1)
    cs = 0b0010,
    /// Carry clear / unsigned lower (C == 0)
    cc = 0b0011,
    /// Minus, negative (N == 1)
    mi = 0b0100,
    /// Plus, positive or zero (N == 0)
    pl = 0b0101,
    /// Overflow set (V == 1)
    vs = 0b0110,
    /// Overflow clear (V == 0)
    vc = 0b0111,
    /// Unsigned higher (C == 1 && Z == 0)
    hi = 0b1000,
    /// Unsigned lower or same (C == 0 || Z == 1)
    ls = 0b1001,
    /// Signed greater than or equal (N == V)
    ge = 0b1010,
    /// Signed less than (N != V)
    lt = 0b1011,
    /// Signed greater than (Z == 0 && N == V)
    gt = 0b1100,
    /// Signed less than or equal (Z == 1 || N != V)
    le = 0b1101,
    /// Always (unconditional)
    al = 0b1110,
    /// Always (unconditional, reserved encoding)
    nv = 0b1111,

    /// Alias: hs (higher or same) == cs
    pub const hs: Condition = .cs;
    /// Alias: lo (lower) == cc
    pub const lo: Condition = .cc;

    /// Convert from signed comparison operator
    pub fn fromCompareOperatorSigned(op: std.math.CompareOperator) Condition {
        return switch (op) {
            .gte => .ge,
            .gt => .gt,
            .neq => .ne,
            .lt => .lt,
            .lte => .le,
            .eq => .eq,
        };
    }

    /// Convert from unsigned comparison operator
    pub fn fromCompareOperatorUnsigned(op: std.math.CompareOperator) Condition {
        return switch (op) {
            .gte => .cs, // or .hs
            .gt => .hi,
            .neq => .ne,
            .lt => .cc, // or .lo
            .lte => .ls,
            .eq => .eq,
        };
    }

    /// Convert from comparison operator with signedness
    pub fn fromCompareOperator(
        signedness: std.builtin.Signedness,
        op: std.math.CompareOperator,
    ) Condition {
        return switch (signedness) {
            .signed => fromCompareOperatorSigned(op),
            .unsigned => fromCompareOperatorUnsigned(op),
        };
    }

    /// Returns the negation of this condition (inverts the test)
    pub fn negate(cond: Condition) Condition {
        // ARM64 condition codes are designed so that bit 0 inverts the condition
        return @enumFromInt(@intFromEnum(cond) ^ 1);
    }

    /// Returns the equivalent condition when operands are swapped
    pub fn commute(cond: Condition) Condition {
        return switch (cond) {
            .eq, .ne, .al, .nv => cond, // Symmetric
            .cs => .cc,
            .cc => .cs,
            .mi => .pl,
            .pl => .mi,
            .vs => .vc,
            .vc => .vs,
            .hi => .lo,
            .ls => .hi,
            .ge => .le,
            .lt => .gt,
            .gt => .lt,
            .le => .ge,
        };
    }
};

/// ARM64 registers
/// Encoding compatible with the existing encoding.zig Register.Alias
pub const Register = enum(u8) {
    // 64-bit general purpose registers (X0-X30)
    x0, x1, x2, x3, x4, x5, x6, x7,
    x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23,
    x24, x25, x26, x27, x28, x29, x30,

    // Special 64-bit registers
    xzr, // Zero register
    sp,  // Stack pointer

    // 32-bit general purpose registers (W0-W30)
    w0, w1, w2, w3, w4, w5, w6, w7,
    w8, w9, w10, w11, w12, w13, w14, w15,
    w16, w17, w18, w19, w20, w21, w22, w23,
    w24, w25, w26, w27, w28, w29, w30,

    // Special 32-bit register
    wzr, // Zero register (32-bit)

    // 128-bit SIMD/FP registers (V0-V31)
    v0, v1, v2, v3, v4, v5, v6, v7,
    v8, v9, v10, v11, v12, v13, v14, v15,
    v16, v17, v18, v19, v20, v21, v22, v23,
    v24, v25, v26, v27, v28, v29, v30, v31,

    // 64-bit FP registers (D0-D31, lower half of V regs)
    d0, d1, d2, d3, d4, d5, d6, d7,
    d8, d9, d10, d11, d12, d13, d14, d15,
    d16, d17, d18, d19, d20, d21, d22, d23,
    d24, d25, d26, d27, d28, d29, d30, d31,

    // 32-bit FP registers (S0-S31)
    s0, s1, s2, s3, s4, s5, s6, s7,
    s8, s9, s10, s11, s12, s13, s14, s15,
    s16, s17, s18, s19, s20, s21, s22, s23,
    s24, s25, s26, s27, s28, s29, s30, s31,

    // 16-bit FP registers (H0-H31)
    h0, h1, h2, h3, h4, h5, h6, h7,
    h8, h9, h10, h11, h12, h13, h14, h15,
    h16, h17, h18, h19, h20, h21, h22, h23,
    h24, h25, h26, h27, h28, h29, h30, h31,

    // 8-bit FP registers (B0-B31)
    b0, b1, b2, b3, b4, b5, b6, b7,
    b8, b9, b10, b11, b12, b13, b14, b15,
    b16, b17, b18, b19, b20, b21, b22, b23,
    b24, b25, b26, b27, b28, b29, b30, b31,

    // Special marker
    none,

    /// Register class for allocation
    pub const Class = enum {
        general_purpose, // X/W registers
        vector,          // V/D/S/H/B registers
        special,         // SP, XZR, WZR
    };

    /// Get the register number (0-31) for encoding
    pub fn id(reg: Register) u5 {
        return switch (reg) {
            .x0, .w0, .v0, .d0, .s0, .h0, .b0 => 0,
            .x1, .w1, .v1, .d1, .s1, .h1, .b1 => 1,
            .x2, .w2, .v2, .d2, .s2, .h2, .b2 => 2,
            .x3, .w3, .v3, .d3, .s3, .h3, .b3 => 3,
            .x4, .w4, .v4, .d4, .s4, .h4, .b4 => 4,
            .x5, .w5, .v5, .d5, .s5, .h5, .b5 => 5,
            .x6, .w6, .v6, .d6, .s6, .h6, .b6 => 6,
            .x7, .w7, .v7, .d7, .s7, .h7, .b7 => 7,
            .x8, .w8, .v8, .d8, .s8, .h8, .b8 => 8,
            .x9, .w9, .v9, .d9, .s9, .h9, .b9 => 9,
            .x10, .w10, .v10, .d10, .s10, .h10, .b10 => 10,
            .x11, .w11, .v11, .d11, .s11, .h11, .b11 => 11,
            .x12, .w12, .v12, .d12, .s12, .h12, .b12 => 12,
            .x13, .w13, .v13, .d13, .s13, .h13, .b13 => 13,
            .x14, .w14, .v14, .d14, .s14, .h14, .b14 => 14,
            .x15, .w15, .v15, .d15, .s15, .h15, .b15 => 15,
            .x16, .w16, .v16, .d16, .s16, .h16, .b16 => 16,
            .x17, .w17, .v17, .d17, .s17, .h17, .b17 => 17,
            .x18, .w18, .v18, .d18, .s18, .h18, .b18 => 18,
            .x19, .w19, .v19, .d19, .s19, .h19, .b19 => 19,
            .x20, .w20, .v20, .d20, .s20, .h20, .b20 => 20,
            .x21, .w21, .v21, .d21, .s21, .h21, .b21 => 21,
            .x22, .w22, .v22, .d22, .s22, .h22, .b22 => 22,
            .x23, .w23, .v23, .d23, .s23, .h23, .b23 => 23,
            .x24, .w24, .v24, .d24, .s24, .h24, .b24 => 24,
            .x25, .w25, .v25, .d25, .s25, .h25, .b25 => 25,
            .x26, .w26, .v26, .d26, .s26, .h26, .b26 => 26,
            .x27, .w27, .v27, .d27, .s27, .h27, .b27 => 27,
            .x28, .w28, .v28, .d28, .s28, .h28, .b28 => 28,
            .x29, .w29, .v29, .d29, .s29, .h29, .b29 => 29,
            .x30, .w30, .v30, .d30, .s30, .h30, .b30 => 30,
            .v31, .d31, .s31, .h31, .b31 => 31,
            .xzr, .wzr, .sp => 31, // SP and ZR share encoding 31
            .none => unreachable,
        };
    }

    /// Get register class
    pub fn class(reg: Register) Class {
        return switch (reg) {
            .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
            .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15,
            .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
            .x24, .x25, .x26, .x27, .x28, .x29, .x30,
            .w0, .w1, .w2, .w3, .w4, .w5, .w6, .w7,
            .w8, .w9, .w10, .w11, .w12, .w13, .w14, .w15,
            .w16, .w17, .w18, .w19, .w20, .w21, .w22, .w23,
            .w24, .w25, .w26, .w27, .w28, .w29, .w30 => .general_purpose,

            .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7,
            .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15,
            .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23,
            .v24, .v25, .v26, .v27, .v28, .v29, .v30, .v31,
            .d0, .d1, .d2, .d3, .d4, .d5, .d6, .d7,
            .d8, .d9, .d10, .d11, .d12, .d13, .d14, .d15,
            .d16, .d17, .d18, .d19, .d20, .d21, .d22, .d23,
            .d24, .d25, .d26, .d27, .d28, .d29, .d30, .d31,
            .s0, .s1, .s2, .s3, .s4, .s5, .s6, .s7,
            .s8, .s9, .s10, .s11, .s12, .s13, .s14, .s15,
            .s16, .s17, .s18, .s19, .s20, .s21, .s22, .s23,
            .s24, .s25, .s26, .s27, .s28, .s29, .s30, .s31,
            .h0, .h1, .h2, .h3, .h4, .h5, .h6, .h7,
            .h8, .h9, .h10, .h11, .h12, .h13, .h14, .h15,
            .h16, .h17, .h18, .h19, .h20, .h21, .h22, .h23,
            .h24, .h25, .h26, .h27, .h28, .h29, .h30, .h31,
            .b0, .b1, .b2, .b3, .b4, .b5, .b6, .b7,
            .b8, .b9, .b10, .b11, .b12, .b13, .b14, .b15,
            .b16, .b17, .b18, .b19, .b20, .b21, .b22, .b23,
            .b24, .b25, .b26, .b27, .b28, .b29, .b30, .b31 => .vector,

            .xzr, .wzr, .sp => .special,
            .none => unreachable,
        };
    }

    /// Convert to 64-bit version
    pub fn to64(reg: Register) Register {
        return switch (reg) {
            .w0 => .x0, .w1 => .x1, .w2 => .x2, .w3 => .x3,
            .w4 => .x4, .w5 => .x5, .w6 => .x6, .w7 => .x7,
            .w8 => .x8, .w9 => .x9, .w10 => .x10, .w11 => .x11,
            .w12 => .x12, .w13 => .x13, .w14 => .x14, .w15 => .x15,
            .w16 => .x16, .w17 => .x17, .w18 => .x18, .w19 => .x19,
            .w20 => .x20, .w21 => .x21, .w22 => .x22, .w23 => .x23,
            .w24 => .x24, .w25 => .x25, .w26 => .x26, .w27 => .x27,
            .w28 => .x28, .w29 => .x29, .w30 => .x30,
            .wzr => .xzr,
            .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
            .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15,
            .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
            .x24, .x25, .x26, .x27, .x28, .x29, .x30,
            .xzr, .sp => reg,
            else => unreachable,
        };
    }

    /// Convert to 32-bit version
    pub fn to32(reg: Register) Register {
        return switch (reg) {
            .x0 => .w0, .x1 => .w1, .x2 => .w2, .x3 => .w3,
            .x4 => .w4, .x5 => .w5, .x6 => .w6, .x7 => .w7,
            .x8 => .w8, .x9 => .w9, .x10 => .w10, .x11 => .w11,
            .x12 => .w12, .x13 => .w13, .x14 => .w14, .x15 => .w15,
            .x16 => .w16, .x17 => .w17, .x18 => .w18, .x19 => .w19,
            .x20 => .w20, .x21 => .w21, .x22 => .w22, .x23 => .w23,
            .x24 => .w24, .x25 => .w25, .x26 => .w26, .x27 => .w27,
            .x28 => .w28, .x29 => .w29, .x30 => .w30,
            .xzr => .wzr,
            .w0, .w1, .w2, .w3, .w4, .w5, .w6, .w7,
            .w8, .w9, .w10, .w11, .w12, .w13, .w14, .w15,
            .w16, .w17, .w18, .w19, .w20, .w21, .w22, .w23,
            .w24, .w25, .w26, .w27, .w28, .w29, .w30,
            .wzr => reg,
            else => unreachable,
        };
    }

    /// Check if this is a general purpose register
    pub fn isGeneralPurpose(reg: Register) bool {
        return reg.class() == .general_purpose;
    }

    /// Check if this is a vector register
    pub fn isVector(reg: Register) bool {
        return reg.class() == .vector;
    }

    /// Frame pointer (X29)
    pub const fp: Register = .x29;
    /// Link register (X30)
    pub const lr: Register = .x30;
};

/// Memory operand for load/store instructions
pub const Memory = struct {
    base: Register,
    offset: Offset,

    pub const Offset = union(enum) {
        /// Immediate offset: [Xn, #imm]
        immediate: i32,
        /// Register offset: [Xn, Xm{, LSL #shift}]
        register: RegisterOffset,
        /// Pre-index: [Xn, #imm]!
        pre_index: i32,
        /// Post-index: [Xn], #imm
        post_index: i32,
        /// PC-relative (for literals)
        pc_relative: i32,
    };

    pub const RegisterOffset = struct {
        reg: Register,
        shift: u3, // 0-3 for LSL amount
        extend: Extend = .none,

        pub const Extend = enum {
            none,
            uxtw, // Zero-extend W register to 64 bits
            sxtw, // Sign-extend W register to 64 bits
            sxtx, // Sign-extend X register (identity)
        };
    };

    /// Create simple immediate offset memory operand
    pub fn simple(base: Register, offset: i32) Memory {
        return .{
            .base = base,
            .offset = .{ .immediate = offset },
        };
    }

    /// Create register offset memory operand
    pub fn registerOffset(base: Register, offset_reg: Register, shift: u3) Memory {
        return .{
            .base = base,
            .offset = .{ .register = .{
                .reg = offset_reg,
                .shift = shift,
            } },
        };
    }
};

/// Register + offset (used for tracking values in CodeGen)
/// Note: Different from Memory.RegisterOffset which is for addressing modes
pub const RegOffset = struct {
    reg: Register,
    off: i32,
};

/// Frame index for stack frame management
pub const FrameIndex = enum(u32) {
    /// Return address (saved by BL instruction)
    ret_addr,
    /// Saved frame pointer (X29)
    base_ptr,
    /// Arguments passed on stack
    args_frame,
    /// Local variables and spills
    stack_frame,
    /// Call frame for outgoing arguments
    call_frame,
    _,

    pub const named_count = 5;
};

/// Frame address (frame index + offset)
pub const FrameAddr = struct {
    index: FrameIndex,
    off: i32,

    pub fn withOffset(fa: FrameAddr, extra: i32) FrameAddr {
        return .{
            .index = fa.index,
            .off = fa.off + extra,
        };
    }
};

/// Immediate values
pub const Immediate = union(enum) {
    signed: i64,
    unsigned: u64,

    pub fn s(val: i64) Immediate {
        return .{ .signed = val };
    }

    pub fn u(val: u64) Immediate {
        return .{ .unsigned = val };
    }

    pub fn asUnsigned(imm: Immediate, bits: u16) u64 {
        return switch (imm) {
            .signed => |val| @bitCast(@as(i64, val) & (@as(i64, 1) << @as(u6, @intCast(bits)) - 1)),
            .unsigned => |val| val & (@as(u64, 1) << @as(u6, @intCast(bits)) - 1),
        };
    }
};

test "Condition negate" {
    try expect(Condition.eq.negate() == .ne);
    try expect(Condition.ne.negate() == .eq);
    try expect(Condition.gt.negate() == .le);
    try expect(Condition.le.negate() == .gt);
    try expect(Condition.hi.negate() == .ls);
}

test "Condition from compare operator" {
    try expect(Condition.fromCompareOperatorSigned(.gt) == .gt);
    try expect(Condition.fromCompareOperatorSigned(.gte) == .ge);
    try expect(Condition.fromCompareOperatorSigned(.lt) == .lt);
    try expect(Condition.fromCompareOperatorSigned(.lte) == .le);
    try expect(Condition.fromCompareOperatorSigned(.eq) == .eq);
    try expect(Condition.fromCompareOperatorSigned(.neq) == .ne);

    try expect(Condition.fromCompareOperatorUnsigned(.gt) == .hi);
    try expect(Condition.fromCompareOperatorUnsigned(.gte) == .cs);
    try expect(Condition.fromCompareOperatorUnsigned(.lt) == .cc);
    try expect(Condition.fromCompareOperatorUnsigned(.lte) == .ls);
}

test "Register ID" {
    try expect(Register.x0.id() == 0);
    try expect(Register.x15.id() == 15);
    try expect(Register.x30.id() == 30);
    try expect(Register.xzr.id() == 31);
    try expect(Register.sp.id() == 31);
    try expect(Register.w0.id() == 0);
    try expect(Register.v0.id() == 0);
    try expect(Register.v31.id() == 31);
}

test "Register conversions" {
    try expect(Register.w0.to64() == .x0);
    try expect(Register.w15.to64() == .x15);
    try expect(Register.x0.to32() == .w0);
    try expect(Register.x30.to32() == .w30);
}

test "Register class" {
    try expect(Register.x0.class() == .general_purpose);
    try expect(Register.w15.class() == .general_purpose);
    try expect(Register.v0.class() == .vector);
    try expect(Register.d15.class() == .vector);
    try expect(Register.sp.class() == .special);
    try expect(Register.xzr.class() == .special);
}
