//! ARM64 Code Generator (Modernized Architecture)
//! Converts AIR (Abstract Intermediate Representation) to MIR (Machine IR)
//! Following the x86_64 backend architecture with liveness-based register allocation

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../../codegen.zig");
const link = @import("../../link.zig");
const log = std.log.scoped(.codegen);

const Air = @import("../../Air.zig");
const Allocator = std.mem.Allocator;
const Mir = @import("Mir_v2.zig");
const Zcu = @import("../../Zcu.zig");
const Module = @import("../../Package/Module.zig");
const InternPool = @import("../../InternPool.zig");
const Type = @import("../../Type.zig");
const Value = @import("../../Value.zig");

const abi = @import("abi.zig");
const bits = @import("bits.zig");

const Condition = bits.Condition;
const Memory = bits.Memory;
const Register = bits.Register;
const RegisterManager = abi.RegisterManager;
const RegisterLock = RegisterManager.RegisterLock;
const FrameIndex = bits.FrameIndex;

const InnerError = codegen.CodeGenError || error{OutOfRegisters};

/// Legalize AIR instructions for ARM64
pub fn legalizeFeatures(_: *const std.Target) *const Air.Legalize.Features {
    return comptime &.initMany(&.{
        .scalarize_mul_sat,
        .scalarize_div_floor,
        .scalarize_mod,
        .scalarize_add_with_overflow,
        .scalarize_sub_with_overflow,
        .scalarize_mul_with_overflow,
        .scalarize_shl_with_overflow,
        .scalarize_shr,
        .scalarize_shr_exact,
        .scalarize_shl,
        .scalarize_shl_exact,
        .scalarize_shl_sat,
        .scalarize_bitcast,
        .scalarize_ctz,
        .scalarize_popcount,
        .scalarize_byte_swap,
        .scalarize_bit_reverse,
        .scalarize_cmp_vector,
        .scalarize_cmp_vector_optimized,
        .scalarize_shuffle_one,
        .scalarize_shuffle_two,
        .scalarize_select,

        .reduce_one_elem_to_bitcast,
        .splat_one_elem_to_bitcast,

        .expand_intcast_safe,
        .expand_int_from_float_safe,
        .expand_int_from_float_optimized_safe,
        .expand_add_safe,
        .expand_sub_safe,
        .expand_mul_safe,

        .expand_packed_load,
        .expand_packed_store,
        .expand_packed_struct_field_val,
        .expand_packed_aggregate_init,
    });
}

const CodeGen = @This();

// ============================================================================
// CodeGen State
// ============================================================================

gpa: Allocator,
pt: Zcu.PerThread,
air: Air,
liveness: Air.Liveness,
target: *const std.Target,
owner: union(enum) {
    nav_index: InternPool.Nav.Index,
    lazy_sym: link.File.LazySymbol,
},
inline_func: InternPool.Index,
mod: *Module,
args: []MCValue,
ret_mcv: InstTracking,
fn_type: Type,
src_loc: Zcu.LazySrcLoc,

/// MIR Instructions
mir_instructions: std.MultiArrayList(Mir.Inst) = .empty,
mir_extra: std.ArrayListUnmanaged(u32) = .empty,
mir_string_bytes: std.ArrayListUnmanaged(u8) = .empty,
mir_locals: std.ArrayListUnmanaged(Mir.Local) = .empty,
mir_table: std.ArrayListUnmanaged(Mir.Inst.Index) = .empty,

/// Instruction tracking (maps Air.Inst.Index to MCValue)
inst_tracking: InstTrackingMap = .empty,

/// Basic blocks
blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .empty,

/// Register allocation
register_manager: RegisterManager = .{},

/// Scope generation counter
scope_generation: u32 = 0,

/// Frame allocations
frame_allocs: std.MultiArrayList(FrameAlloc) = .empty,
free_frame_indices: std.AutoArrayHashMapUnmanaged(FrameIndex, void) = .empty,
frame_locs: std.MultiArrayList(Mir.FrameLoc) = .empty,

// ============================================================================
// Machine Code Value - where a value lives
// ============================================================================

pub const MCValue = union(enum) {
    /// No runtime bits (void, empty structs, u0, etc.)
    none,
    /// Control flow will not allow this value to be observed
    unreach,
    /// No more references to this value remain
    dead: u32,
    /// The value is undefined
    undef,
    /// Immediate value that fits in a register
    immediate: u64,
    /// The value is in a register
    register: Register,
    /// The value is split across two registers (for 128-bit values)
    register_pair: [2]Register,
    /// The value is in memory
    memory: Memory,
    /// Load from frame location
    load_frame: bits.FrameAddr,
    /// Address of frame location
    frame_addr: bits.FrameAddr,
    /// Register + constant offset
    register_offset: bits.RegisterOffset,
};

pub const InstTracking = struct {
    live: bool,
    short: u16,
    long: MCValue,

    fn init(mcv: MCValue) InstTracking {
        return .{
            .live = true,
            .short = 0,
            .long = mcv,
        };
    }

    fn resurrection(self: *InstTracking, mcv: MCValue) void {
        self.* = .{
            .live = true,
            .short = self.short,
            .long = mcv,
        };
    }

    fn reuse(self: *InstTracking, new_tracking: InstTracking) void {
        self.* = new_tracking;
    }

    fn die(self: *InstTracking, scope_generation: u32) void {
        self.live = false;
        self.long = .{ .dead = scope_generation };
    }

    fn isConditionFlags(self: InstTracking) bool {
        return false; // ARM64 uses condition code results differently
    }
};

const InstTrackingMap = std.AutoArrayHashMapUnmanaged(Air.Inst.Index, InstTracking);

const BlockData = struct {
    /// Relocations for branches to this block
    relocs: std.ArrayListUnmanaged(Mir.Inst.Index) = .empty,
    /// State at block entry
    state: State,

    fn deinit(self: *BlockData, gpa: Allocator) void {
        self.relocs.deinit(gpa);
        self.* = undefined;
    }
};

const State = struct {
    // TODO: Track register state across blocks
};

const FrameAlloc = struct {
    size: u64,
    alignment: InternPool.Alignment,

    fn init(spec: struct {
        size: u64,
        alignment: InternPool.Alignment,
    }) FrameAlloc {
        return .{
            .size = spec.size,
            .alignment = spec.alignment,
        };
    }
};

// ============================================================================
// Main Entry Point - Generate MIR from AIR
// ============================================================================

pub fn generate(
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) codegen.CodeGenError!Mir {
    _ = bin_file;
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const fn_type: Type = .fromInterned(func.ty);
    const mod = zcu.navFileScope(func.owner_nav).mod.?;

    var function: CodeGen = .{
        .gpa = gpa,
        .pt = pt,
        .air = air.*,
        .liveness = liveness.*.?,
        .target = &mod.resolved_target.result,
        .mod = mod,
        .owner = .{ .nav_index = func.owner_nav },
        .inline_func = func_index,
        .args = undefined,
        .ret_mcv = undefined,
        .fn_type = fn_type,
        .src_loc = src_loc,
    };

    defer function.deinit(gpa);

    // Initialize frame allocations
    try function.frame_allocs.resize(gpa, FrameIndex.named_count);
    function.frame_allocs.set(@intFromEnum(FrameIndex.stack_frame), .init(.{ .size = 0, .alignment = .@"1" }));
    function.frame_allocs.set(@intFromEnum(FrameIndex.call_frame), .init(.{ .size = 0, .alignment = .@"1" }));

    // TODO: Resolve calling convention values
    function.args = &.{};
    function.ret_mcv = .init(.none);

    // Generate MIR from AIR
    try function.gen();

    // Build and return MIR
    var mir: Mir = .{
        .instructions = .empty,
        .extra = &.{},
        .string_bytes = &.{},
        .locals = &.{},
        .table = &.{},
        .frame_locs = .empty,
    };
    errdefer mir.deinit(gpa);

    mir.instructions = function.mir_instructions.toOwnedSlice();
    mir.extra = try function.mir_extra.toOwnedSlice(gpa);
    mir.string_bytes = try function.mir_string_bytes.toOwnedSlice(gpa);
    mir.locals = try function.mir_locals.toOwnedSlice(gpa);
    mir.table = try function.mir_table.toOwnedSlice(gpa);
    mir.frame_locs = function.frame_locs.toOwnedSlice();

    return mir;
}

fn deinit(self: *CodeGen, gpa: Allocator) void {
    self.frame_allocs.deinit(gpa);
    self.free_frame_indices.deinit(gpa);
    self.frame_locs.deinit(gpa);

    var block_it = self.blocks.valueIterator();
    while (block_it.next()) |block| block.deinit(gpa);
    self.blocks.deinit(gpa);

    self.inst_tracking.deinit(gpa);
    self.mir_instructions.deinit(gpa);
    self.mir_string_bytes.deinit(gpa);
    self.mir_locals.deinit(gpa);
    self.mir_extra.deinit(gpa);
    self.mir_table.deinit(gpa);
}

// ============================================================================
// MIR Generation
// ============================================================================

fn gen(self: *CodeGen) !void {
    const gpa = self.gpa;
    const air_tags = self.air.instructions.items(.tag);

    // Process main body
    const main_body = self.air.getMainBody();

    for (main_body) |inst| {
        const tag = air_tags[@intFromEnum(inst)];

        // Generate instruction
        try self.genInst(inst, tag);
    }

    // Add return if needed
    try self.addInst(.{
        .tag = .ret,
        .ops = .none,
        .data = .{ .none = {} },
    });
}

fn genInst(self: *CodeGen, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    return switch (tag) {
        // Arithmetic
        .add => self.airAdd(inst),
        .sub => self.airSub(inst),
        .mul => self.airMul(inst),

        // Bitwise
        .bit_and => self.airAnd(inst),
        .bit_or => self.airOr(inst),
        .xor => self.airXor(inst),

        // Shifts
        .shl, .shl_exact => self.airShl(inst),
        .shr, .shr_exact => self.airShr(inst),

        // Load/Store
        .load => self.airLoad(inst),
        .store => self.airStore(inst),

        // Compare
        .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte => self.airCmp(inst),

        // Branches
        .br => self.airBr(inst),
        .cond_br => self.airCondBr(inst),

        // Return
        .ret => self.airRet(inst),
        .ret_load => self.airRetLoad(inst),

        // Constants
        .constant => self.airConstant(inst),

        // Blocks
        .block => self.airBlock(inst),

        // No-ops
        .dbg_stmt => .{},
        .dbg_inline_block => .{},
        .dbg_var_ptr, .dbg_var_val => .{},

        else => {
            log.err("TODO: ARM64 CodeGen {s}", .{@tagName(tag)});
            return error.CodegenFail;
        },
    };
}

// ============================================================================
// AIR Instruction Handlers
// ============================================================================

fn airAdd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    // Allocate destination register
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Generate ADD instruction
    switch (rhs) {
        .immediate => |imm| {
            // ADD Xd, Xn, #imm
            try self.addInst(.{
                .tag = .add,
                .ops = .rri,
                .data = .{ .rri = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .imm = imm,
                } },
            });
        },
        .register => |rhs_reg| {
            // ADD Xd, Xn, Xm
            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .rm = rhs_reg,
                } },
            });
        },
        else => return error.CodegenFail,
    }

    // Track result
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airSub(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    switch (rhs) {
        .immediate => |imm| {
            try self.addInst(.{
                .tag = .sub,
                .ops = .rri,
                .data = .{ .rri = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .imm = imm,
                } },
            });
        },
        .register => |rhs_reg| {
            try self.addInst(.{
                .tag = .sub,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .rm = rhs_reg,
                } },
            });
        },
        else => return error.CodegenFail,
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airMul(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .mul,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airAnd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .and_,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airOr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .orr,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airXor(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .eor,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airShl(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .lsl,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airShr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // TODO: Check if signed or unsigned
    try self.addInst(.{
        .tag = .lsr,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airLoad(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const ptr = try self.resolveInst(ty_op.operand);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = dst_reg,
            .mem = Memory.simple(ptr.register, 0),
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airStore(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs);
    const val = try self.resolveInst(bin_op.rhs);

    try self.addInst(.{
        .tag = .str,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = Memory.simple(ptr.register, 0),
            .rs = val.register,
        } },
    });
}

fn airCmp(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    // CMP sets condition flags
    try self.addInst(.{
        .tag = .cmp,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = lhs.register,
            .rn = rhs.register,
        } },
    });

    // Result is in condition flags - will be used by conditional instructions
    // For now, materialize to register using CSET
    const tag = self.air.instructions.items(.tag)[@intFromEnum(inst)];
    const cond: Condition = switch (tag) {
        .cmp_eq => .eq,
        .cmp_neq => .ne,
        .cmp_lt => .lt,
        .cmp_lte => .le,
        .cmp_gt => .gt,
        .cmp_gte => .ge,
        else => unreachable,
    };

    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    try self.addInst(.{
        .tag = .cset,
        .ops = .rrc,
        .data = .{ .rrc = .{
            .rd = dst_reg,
            .rn = .xzr,
            .cond = cond,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const br = self.air.instructions.items(.data)[@intFromEnum(inst)].br;

    // Get target block
    const target_block = self.blocks.get(br.block_inst) orelse return error.CodegenFail;
    _ = target_block;

    // Emit branch (offset will be filled by Lower)
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Will be fixed up
    });
}

fn airCondBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    _ = pl_op;

    // TODO: Implement conditional branch
    return error.CodegenFail;
}

fn airRet(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;

    // Simple RET instruction
    try self.addInst(.{
        .tag = .ret,
        .ops = .none,
        .data = .{ .none = {} },
    });
}

fn airRetLoad(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;

    // TODO: Load return value then RET
    try self.addInst(.{
        .tag = .ret,
        .ops = .none,
        .data = .{ .none = {} },
    });
}

fn airConstant(self: *CodeGen, inst: Air.Inst.Index) !void {
    // Constants are typically inlined or loaded as immediates
    // Track as immediate for now
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .immediate = 0 }));
}

fn airBlock(self: *CodeGen, inst: Air.Inst.Index) !void {
    // Register block
    try self.blocks.put(self.gpa, inst, .{
        .state = .{},
    });
}

// ============================================================================
// Helper Functions
// ============================================================================

fn resolveInst(self: *CodeGen, inst: Air.Inst.Index) !MCValue {
    const tracking = self.inst_tracking.get(inst) orelse {
        log.err("Instruction {d} not tracked", .{@intFromEnum(inst)});
        return error.CodegenFail;
    };

    return tracking.long;
}

fn addInst(self: *CodeGen, inst: Mir.Inst) !void {
    try self.mir_instructions.append(self.gpa, inst);
}

fn fail(self: *CodeGen, comptime format: []const u8, args: anytype) error{CodegenFail} {
    @setCold(true);
    log.err(format, args);
    _ = self;
    return error.CodegenFail;
}
