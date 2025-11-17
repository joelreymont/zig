const assert = @import("std").debug.assert;
const std = @import("std");
const Type = @import("../../Type.zig");
const Zcu = @import("../../Zcu.zig");

pub const Class = union(enum) {
    memory,
    byval,
    integer,
    double_integer,
    float_array: u8,
};

/// For `float_array` the second element will be the amount of floats.
pub fn classifyType(ty: Type, zcu: *Zcu) Class {
    assert(ty.hasRuntimeBitsIgnoreComptime(zcu));

    var maybe_float_bits: ?u16 = null;
    switch (ty.zigTypeTag(zcu)) {
        .@"struct" => {
            if (ty.containerLayout(zcu) == .@"packed") return .byval;
            const float_count = countFloats(ty, zcu, &maybe_float_bits);
            if (float_count <= sret_float_count) return .{ .float_array = float_count };

            const bit_size = ty.bitSize(zcu);
            if (bit_size > 128) return .memory;
            if (bit_size > 64) return .double_integer;
            return .integer;
        },
        .@"union" => {
            if (ty.containerLayout(zcu) == .@"packed") return .byval;
            const float_count = countFloats(ty, zcu, &maybe_float_bits);
            if (float_count <= sret_float_count) return .{ .float_array = float_count };

            const bit_size = ty.bitSize(zcu);
            if (bit_size > 128) return .memory;
            if (bit_size > 64) return .double_integer;
            return .integer;
        },
        .int, .@"enum", .error_set, .float, .bool => return .byval,
        .vector => {
            const bit_size = ty.bitSize(zcu);
            // TODO is this controlled by a cpu feature?
            if (bit_size > 128) return .memory;
            return .byval;
        },
        .optional => {
            assert(ty.isPtrLikeOptional(zcu));
            return .byval;
        },
        .pointer => {
            assert(!ty.isSlice(zcu));
            return .byval;
        },
        .error_union,
        .frame,
        .@"anyframe",
        .noreturn,
        .void,
        .type,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        .@"opaque",
        .enum_literal,
        .array,
        => unreachable,
    }
}

const sret_float_count = 4;
fn countFloats(ty: Type, zcu: *Zcu, maybe_float_bits: *?u16) u8 {
    const ip = &zcu.intern_pool;
    const target = zcu.getTarget();
    const invalid = std.math.maxInt(u8);
    switch (ty.zigTypeTag(zcu)) {
        .@"union" => {
            const union_obj = zcu.typeToUnion(ty).?;
            var max_count: u8 = 0;
            for (union_obj.field_types.get(ip)) |field_ty| {
                const field_count = countFloats(Type.fromInterned(field_ty), zcu, maybe_float_bits);
                if (field_count == invalid) return invalid;
                if (field_count > max_count) max_count = field_count;
                if (max_count > sret_float_count) return invalid;
            }
            return max_count;
        },
        .@"struct" => {
            const fields_len = ty.structFieldCount(zcu);
            var count: u8 = 0;
            var i: u32 = 0;
            while (i < fields_len) : (i += 1) {
                const field_ty = ty.fieldType(i, zcu);
                const field_count = countFloats(field_ty, zcu, maybe_float_bits);
                if (field_count == invalid) return invalid;
                count += field_count;
                if (count > sret_float_count) return invalid;
            }
            return count;
        },
        .float => {
            const float_bits = maybe_float_bits.* orelse {
                maybe_float_bits.* = ty.floatBits(target);
                return 1;
            };
            if (ty.floatBits(target) == float_bits) return 1;
            return invalid;
        },
        .void => return 0,
        else => return invalid,
    }
}

pub fn getFloatArrayType(ty: Type, zcu: *Zcu) ?Type {
    const ip = &zcu.intern_pool;
    switch (ty.zigTypeTag(zcu)) {
        .@"union" => {
            const union_obj = zcu.typeToUnion(ty).?;
            for (union_obj.field_types.get(ip)) |field_ty| {
                if (getFloatArrayType(Type.fromInterned(field_ty), zcu)) |some| return some;
            }
            return null;
        },
        .@"struct" => {
            const fields_len = ty.structFieldCount(zcu);
            var i: u32 = 0;
            while (i < fields_len) : (i += 1) {
                const field_ty = ty.fieldType(i, zcu);
                if (getFloatArrayType(field_ty, zcu)) |some| return some;
            }
            return null;
        },
        .float => return ty,
        else => return null,
    }
}

// ============================================================================
// RegisterManager - ARM64 Register Allocation
// ============================================================================

const Air = @import("../../Air.zig");
const bits = @import("bits.zig");
const Register = bits.Register;

/// AAPCS64 calling convention register usage
/// Based on ARM Procedure Call Standard for the ARM64 Architecture

/// General purpose registers callee must preserve
pub const callee_preserved_gp_regs = [_]Register{
    .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28,
    // X29 (FP) and X30 (LR) are also callee-saved but handled specially
};

/// General purpose registers caller must preserve (available for callee to use)
pub const caller_preserved_gp_regs = [_]Register{
    .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
    .x8,  // Indirect result location register
    .x9, .x10, .x11, .x12, .x13, .x14, .x15,
    .x16, .x17, // IP0, IP1 (intra-procedure call)
    // X18 is platform-specific (TLS on Linux, reserved on Darwin)
};

/// Vector/FP registers callee must preserve (lower 64 bits of V8-V15)
pub const callee_preserved_fp_regs = [_]Register{
    .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15,
};

/// Vector/FP registers caller must preserve
pub const caller_preserved_fp_regs = [_]Register{
    .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7,
    .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23,
    .v24, .v25, .v26, .v27, .v28, .v29, .v30, .v31,
};

/// Argument registers (integer/pointer)
pub const arg_gp_regs = [_]Register{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7 };

/// Argument registers (floating-point/SIMD)
pub const arg_fp_regs = [_]Register{ .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7 };

/// Return value registers (integer)
pub const ret_gp_regs = [_]Register{ .x0, .x1 }; // x0 primary, x1 for 128-bit

/// Return value registers (floating-point/SIMD)
pub const ret_fp_regs = [_]Register{ .v0, .v1, .v2, .v3 }; // HFA/HVA returns

/// Register manager for tracking register allocation
pub const RegisterManager = struct {
    /// Maps register to the Air instruction it's currently allocated to (null if free)
    registers: [max_reg_index]?Air.Inst.Index,

    const max_reg_index = @typeInfo(Register).@"enum".fields.len;

    pub const Self = @This();

    /// Initialize with all registers free
    pub fn init() RegisterManager {
        return .{
            .registers = [_]?Air.Inst.Index{null} ** max_reg_index,
        };
    }

    /// Register allocation lock (RAII)
    pub const RegisterLock = struct {
        manager: *RegisterManager,
        reg: Register,

        pub fn release(lock: RegisterLock) void {
            lock.manager.freeReg(lock.reg);
        }
    };

    /// Check if a register is free
    pub fn isRegFree(self: *const RegisterManager, reg: Register) bool {
        if (reg == .none) return false;
        return self.registers[@intFromEnum(reg)] == null;
    }

    /// Allocate a register, returning error if none available
    pub fn allocReg(
        self: *RegisterManager,
        inst: Air.Inst.Index,
        reg_class: RegisterClass,
    ) error{OutOfRegisters}!Register {
        const regs = switch (reg_class) {
            .gp => &caller_preserved_gp_regs,
            .vector => &caller_preserved_fp_regs,
        };

        // Try to find a free register
        for (regs) |reg| {
            if (self.isRegFree(reg)) {
                self.registers[@intFromEnum(reg)] = inst;
                return reg;
            }
        }

        return error.OutOfRegisters;
    }

    /// Allocate a specific register, asserting it's free
    pub fn getRegAssumeFree(
        self: *RegisterManager,
        reg: Register,
        inst: Air.Inst.Index,
    ) void {
        assert(self.isRegFree(reg));
        self.registers[@intFromEnum(reg)] = inst;
    }

    /// Free a register
    pub fn freeReg(self: *RegisterManager, reg: Register) void {
        if (reg == .none) return;
        self.registers[@intFromEnum(reg)] = null;
    }

    /// Lock a register (RAII)
    pub fn lockReg(self: *RegisterManager, reg: Register) RegisterLock {
        return .{ .manager = self, .reg = reg };
    }

    /// Lock multiple registers
    pub fn lockRegs(
        self: *RegisterManager,
        comptime count: comptime_int,
        regs: [count]Register,
    ) [count]RegisterLock {
        var locks: [count]RegisterLock = undefined;
        for (regs, 0..) |reg, i| {
            locks[i] = self.lockReg(reg);
        }
        return locks;
    }

    /// Get the instruction currently using a register (or null if free)
    pub fn getRegOwner(self: *const RegisterManager, reg: Register) ?Air.Inst.Index {
        return self.registers[@intFromEnum(reg)];
    }
};

/// Register class for allocation
pub const RegisterClass = enum {
    /// General purpose (X/W registers)
    gp,
    /// Vector/FP (V/D/S/H/B registers)
    vector,
};
