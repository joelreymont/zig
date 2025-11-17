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
register_manager: RegisterManager = RegisterManager.init(),

/// Scope generation counter
scope_generation: u32 = 0,

/// Frame allocations
frame_allocs: std.MultiArrayList(FrameAlloc) = .empty,
free_frame_indices: std.AutoArrayHashMapUnmanaged(FrameIndex, void) = .empty,
frame_locs: std.MultiArrayList(Mir.FrameLoc) = .empty,

/// Stack offset for spills (grows downward from frame pointer)
stack_offset: u32 = 0,

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
    register_offset: bits.RegOffset,
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

    fn isConditionFlags(_: InstTracking) bool {
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

/// Calling convention values - parameter and return value locations
const CallMCValues = struct {
    /// Argument MCValues
    args: []MCValue,
    /// Number of AIR arguments (not counting zero-bit args)
    air_arg_count: u32,
    /// Return value location
    return_value: InstTracking,
    /// Stack space needed for arguments (in bytes)
    stack_byte_count: u31,
    /// Stack alignment required
    stack_align: InternPool.Alignment,
    /// Number of GP registers used
    gp_count: u32,
    /// Number of FP registers used
    fp_count: u32,

    fn deinit(self: *CallMCValues, gpa: Allocator) void {
        gpa.free(self.args);
        self.* = undefined;
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
    _ = &zcu.intern_pool;
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

    // Resolve calling convention values
    const fn_info = zcu.typeToFunc(fn_type).?;
    var call_info = try function.resolveCallingConventionValues(fn_info, .stack_frame);
    defer call_info.deinit(gpa);

    function.args = call_info.args;
    function.ret_mcv = call_info.return_value;

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
// Calling Convention
// ============================================================================

/// Resolve calling convention values for function parameters and return value
/// Implements AAPCS64 (ARM Procedure Call Standard for ARM64)
fn resolveCallingConventionValues(
    self: *CodeGen,
    fn_info: InternPool.Key.FuncType,
    stack_frame_base: FrameIndex,
) !CallMCValues {
    const pt = self.pt;
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const cc = fn_info.cc;

    const param_types = try self.gpa.alloc(Type, fn_info.param_types.len);
    defer self.gpa.free(param_types);

    for (param_types, fn_info.param_types.get(ip)) |*param_ty, arg_ty|
        param_ty.* = .fromInterned(arg_ty);

    var result: CallMCValues = .{
        .args = try self.gpa.alloc(MCValue, param_types.len),
        .air_arg_count = 0,
        .return_value = undefined,
        .stack_byte_count = 0,
        .stack_align = .@"16", // AAPCS64 requires 16-byte stack alignment
        .gp_count = 0,
        .fp_count = 0,
    };
    errdefer self.gpa.free(result.args);

    const ret_ty: Type = .fromInterned(fn_info.return_type);

    switch (cc) {
        .naked => {
            assert(result.args.len == 0);
            result.return_value = .init(.unreach);
            result.stack_align = .@"16";
        },
        .auto => {
            // AAPCS64 parameter passing rules
            const param_gp_regs = abi.arg_gp_regs;
            var param_gp_index: u32 = 0;
            const param_fp_regs = abi.arg_fp_regs;
            var param_fp_index: u32 = 0;

            // Return value handling
            if (ret_ty.isNoReturn(zcu)) {
                result.return_value = .init(.unreach);
            } else if (!ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                result.return_value = .init(.none);
            } else {
                const ret_size: u32 = @intCast(ret_ty.abiSize(zcu));

                // Classify return type
                const ret_class = abi.classifyType(ret_ty, zcu);
                result.return_value = switch (ret_class) {
                    .byval, .integer => blk: {
                        // Simple types: X0 for <= 64 bits, X0+X1 for <= 128 bits
                        if (ret_size <= 8) {
                            const reg = registerAlias(abi.ret_gp_regs[0], ret_size);
                            break :blk .init(.{ .register = reg });
                        } else if (ret_size <= 16) {
                            break :blk .init(.{ .register_pair = .{
                                abi.ret_gp_regs[0],
                                abi.ret_gp_regs[1],
                            } });
                        } else {
                            // Indirect return: caller passes pointer in X8
                            param_gp_index = 1; // Reserve X0 for return pointer
                            break :blk .init(.{ .register = .x8 });
                        }
                    },
                    .double_integer => .init(.{ .register_pair = .{
                        abi.ret_gp_regs[0],
                        abi.ret_gp_regs[1],
                    } }),
                    .float_array => |count| blk: {
                        // HFA (Homogeneous Float Aggregate): up to 4 FP regs
                        if (count == 1) {
                            const reg = registerAlias(abi.ret_fp_regs[0], ret_size);
                            break :blk .init(.{ .register = reg });
                        } else {
                            // For now, treat multi-FP returns as indirect
                            // TODO: Implement proper HFA support
                            param_gp_index = 1;
                            break :blk .init(.{ .register = .x8 });
                        }
                    },
                    .memory => blk: {
                        // Indirect return
                        param_gp_index = 1;
                        break :blk .init(.{ .register = .x8 });
                    },
                };
            }

            // Parameter passing
            for (param_types, result.args) |param_ty, *arg| {
                if (!param_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    arg.* = .none;
                    continue;
                }
                result.air_arg_count += 1;

                const param_size: u32 = @intCast(param_ty.abiSize(zcu));
                const param_class = abi.classifyType(param_ty, zcu);

                switch (param_class) {
                    .byval, .integer => {
                        // Integer/pointer parameters
                        if (param_gp_index < param_gp_regs.len and param_size <= 8) {
                            const reg = registerAlias(param_gp_regs[param_gp_index], param_size);
                            arg.* = .{ .register = reg };
                            param_gp_index += 1;
                        } else if (param_gp_index + 1 < param_gp_regs.len and param_size <= 16) {
                            arg.* = .{ .register_pair = .{
                                param_gp_regs[param_gp_index],
                                param_gp_regs[param_gp_index + 1],
                            } };
                            param_gp_index += 2;
                        } else {
                            // Spill to stack
                            const param_align = param_ty.abiAlignment(zcu).max(.@"8");
                            result.stack_byte_count = @intCast(param_align.forward(result.stack_byte_count));
                            result.stack_align = result.stack_align.max(param_align);
                            arg.* = .{ .load_frame = .{
                                .index = stack_frame_base,
                                .off = result.stack_byte_count,
                            } };
                            result.stack_byte_count = @intCast(result.stack_byte_count + param_size);
                        }
                    },
                    .double_integer => {
                        if (param_gp_index + 1 < param_gp_regs.len) {
                            arg.* = .{ .register_pair = .{
                                param_gp_regs[param_gp_index],
                                param_gp_regs[param_gp_index + 1],
                            } };
                            param_gp_index += 2;
                        } else {
                            // Spill to stack
                            const param_align = InternPool.Alignment.@"16";
                            result.stack_byte_count = @intCast(param_align.forward(result.stack_byte_count));
                            result.stack_align = result.stack_align.max(param_align);
                            arg.* = .{ .load_frame = .{
                                .index = stack_frame_base,
                                .off = result.stack_byte_count,
                            } };
                            result.stack_byte_count = @intCast(result.stack_byte_count + param_size);
                        }
                    },
                    .float_array => |count| {
                        // Floating point parameters
                        if (count == 1 and param_fp_index < param_fp_regs.len) {
                            const reg = registerAlias(param_fp_regs[param_fp_index], param_size);
                            arg.* = .{ .register = reg };
                            param_fp_index += 1;
                        } else {
                            // HFA or spill to stack
                            const param_align = param_ty.abiAlignment(zcu).max(.@"8");
                            result.stack_byte_count = @intCast(param_align.forward(result.stack_byte_count));
                            result.stack_align = result.stack_align.max(param_align);
                            arg.* = .{ .load_frame = .{
                                .index = stack_frame_base,
                                .off = result.stack_byte_count,
                            } };
                            result.stack_byte_count = @intCast(result.stack_byte_count + param_size);
                        }
                    },
                    .memory => {
                        // Large types passed on stack
                        const param_align = param_ty.abiAlignment(zcu).max(.@"8");
                        result.stack_byte_count = @intCast(param_align.forward(result.stack_byte_count));
                        result.stack_align = result.stack_align.max(param_align);
                        arg.* = .{ .load_frame = .{
                            .index = stack_frame_base,
                            .off = result.stack_byte_count,
                        } };
                        result.stack_byte_count = @intCast(result.stack_byte_count + param_size);
                    },
                }
            }

            result.gp_count = param_gp_index;
            result.fp_count = param_fp_index;
        },
        else => return self.fail("TODO implement function parameters and return values for {} on ARM64", .{cc}),
    }

    result.stack_byte_count = @intCast(result.stack_align.forward(result.stack_byte_count));
    return result;
}

/// Returns register wide enough to hold at least `size_bytes`
fn registerAlias(reg: Register, size_bytes: u32) Register {
    if (size_bytes == 0) unreachable;

    return switch (reg.class()) {
        .general_purpose => if (size_bytes <= 4)
            reg.to32()
        else
            reg.to64(),
        .vector => reg, // Keep SIMD registers as-is for now
        .special => reg, // SP, XZR, WZR
    };
}

fn fail(self: *CodeGen, comptime format: []const u8, args: anytype) error{ OutOfMemory, CodegenFail } {
    @branchHint(.cold);
    const zcu = self.pt.zcu;
    return switch (self.owner) {
        .nav_index => |i| zcu.codegenFail(i, format, args),
        .lazy_sym => |s| zcu.codegenFailType(s.ty, format, args),
    };
}

// ============================================================================
// MIR Generation
// ============================================================================

fn gen(self: *CodeGen) !void {
    _ = self.gpa;
    const air_tags = self.air.instructions.items(.tag);

    // Generate function prologue
    try self.genPrologue();

    // Process main body
    const main_body = self.air.getMainBody();

    for (main_body) |inst| {
        const tag = air_tags[@intFromEnum(inst)];

        // Generate instruction
        try self.genInst(inst, tag);
    }

    // Note: Epilogue is generated by airRet/airRetLoad handlers
    // If no explicit return, add one
    const last_inst_idx = self.mir_instructions.len -| 1;
    if (last_inst_idx == 0 or self.mir_instructions.items(.tag)[last_inst_idx] != .ret) {
        try self.genEpilogue();
    }
}

/// Generate function prologue
/// Saves FP (X29) and LR (X30), sets up stack frame
fn genPrologue(self: *CodeGen) !void {
    const fn_info = self.pt.zcu.typeToFunc(self.fn_type).?;
    const cc = fn_info.cc;

    // Debug marker
    if (!self.mod.strip) {
        try self.addInst(.{
            .tag = .pseudo_dbg_prologue_end,
            .ops = .none,
            .data = .{ .none = {} },
        });
    }

    // For naked functions, skip prologue
    if (cc == .naked) return;

    // Save FP (X29) and LR (X30) to stack, pre-decrement SP
    // STP X29, X30, [SP, #-16]!
    try self.addInst(.{
        .tag = .stp,
        .ops = .rrm,
        .data = .{ .rrm = .{
            .mem = .{
                .base = .sp,
                .offset = .{ .pre_index = -16 },
            },
            .r1 = .x29,
            .r2 = .x30,
        } },
    });

    // Set frame pointer to current stack pointer
    // MOV X29, SP
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = .x29,
            .rn = .sp,
        } },
    });

    // Reserve placeholder for stack space allocation
    // This will be patched after we know total stack_offset
    // SUB SP, SP, #stack_size (filled in epilogue)
    // For now, stack space for spills grows from frame pointer
}

/// Generate function epilogue
/// Restores FP and LR, returns to caller
fn genEpilogue(self: *CodeGen) !void {
    const fn_info = self.pt.zcu.typeToFunc(self.fn_type).?;
    const cc = fn_info.cc;

    // Debug marker
    if (!self.mod.strip) {
        try self.addInst(.{
            .tag = .pseudo_dbg_epilogue_begin,
            .ops = .none,
            .data = .{ .none = {} },
        });
    }

    // For naked functions, just return
    if (cc == .naked) {
        try self.addInst(.{
            .tag = .ret,
            .ops = .none,
            .data = .{ .none = {} },
        });
        return;
    }

    // TODO: Deallocate stack space if needed
    // ADD SP, SP, #size

    // Restore SP from FP (if we modified SP)
    // For now, skip this since we didn't allocate extra stack

    // Restore FP (X29) and LR (X30) from stack, post-increment SP
    // LDP X29, X30, [SP], #16
    try self.addInst(.{
        .tag = .ldp,
        .ops = .mrr,
        .data = .{ .mrr = .{
            .mem = .{
                .base = .sp,
                .offset = .{ .post_index = 16 },
            },
            .r1 = .x29,
            .r2 = .x30,
        } },
    });

    // Return to caller via LR
    // RET
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
        .div_trunc, .div_exact => self.airDiv(inst),
        .rem => self.airRem(inst),
        .mod => self.airMod(inst),
        .neg => self.airNeg(inst),

        // Bitwise
        .bit_and => self.airAnd(inst),
        .bit_or => self.airOr(inst),
        .xor => self.airXor(inst),
        .not => self.airNot(inst),

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

        // Type conversions
        .intcast => self.airIntCast(inst),
        .trunc => self.airTrunc(inst),

        // Pointer operations
        .ptr_add => self.airPtrAdd(inst),
        .ptr_sub => self.airPtrSub(inst),

        // Slice operations
        .slice_ptr => self.airSlicePtr(inst),
        .slice_len => self.airSliceLen(inst),

        // Blocks
        .block => self.airBlock(inst),

        // No-ops
        .dbg_stmt => {},
        .dbg_inline_block => {},
        .dbg_var_ptr, .dbg_var_val => {},

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

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

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

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

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

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);
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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);
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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);
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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);
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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);
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
    const ptr = try self.resolveInst(ty_op.operand.toIndex().?);
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
    const ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const val = try self.resolveInst(bin_op.rhs.toIndex().?);

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
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

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

    // Get target block data
    const block_data = self.blocks.getPtr(br.block_inst) orelse {
        return self.fail("Branch to unregistered block {d}", .{@intFromEnum(br.block_inst)});
    };

    // Emit unconditional branch
    const branch_inst: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Placeholder, will be patched
    });

    // Record this branch for later patching
    try block_data.relocs.append(self.gpa, branch_inst);

    // TODO: Handle block operand value if needed
    _ = br.operand;
}

fn airCondBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const cond = try self.resolveInst(pl_op.operand.toIndex().?);
    const extra = self.air.extraData(Air.CondBr, pl_op.payload);
    const then_body: []const Air.Inst.Index =
        @ptrCast(self.air.extra.items[extra.end..][0..extra.data.then_body_len]);
    const else_body: []const Air.Inst.Index =
        @ptrCast(self.air.extra.items[extra.end + then_body.len ..][0..extra.data.else_body_len]);

    // Emit conditional branch based on condition value
    // If cond is in a register, use CBZ/CBNZ (compare and branch zero/nonzero)
    const cond_reg = switch (cond) {
        .register => |reg| reg,
        else => blk: {
            // Materialize to register if needed
            const reg = try self.register_manager.allocReg(inst, .gp);
            // TODO: Load immediate/memory to register
            break :blk reg;
        },
    };

    // Branch to else if condition is zero
    const else_branch: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .cbz,
        .ops = .r_rel,
        .data = .{ .r_rel = .{
            .rn = cond_reg,
            .target = 0, // Placeholder
        } },
    });

    // Execute then body
    try self.genBody(then_body);

    // After then body, jump past else body
    const skip_else_branch: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Placeholder
    });

    // Patch else branch to point here
    const else_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    self.mir_instructions.items(.data)[else_branch].r_rel.target = else_start;

    // Execute else body
    try self.genBody(else_body);

    // Patch skip_else branch to point after else body
    const after_else: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    self.mir_instructions.items(.data)[skip_else_branch].rel.target = after_else;
}

fn airRet(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;

    // TODO: Move return value to appropriate register(s) if needed

    // Generate epilogue and return
    try self.genEpilogue();
}

fn airRetLoad(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;

    // TODO: Load return value from memory, move to return register

    // Generate epilogue and return
    try self.genEpilogue();
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

    // Process block body
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = self.air.extraData(Air.Block, ty_pl.payload);
    const body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.body_len]);

    try self.genBody(body);

    // Patch all branches to this block
    const block_data = self.blocks.getPtr(inst).?;
    const current_inst: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    for (block_data.relocs.items) |reloc_inst| {
        self.mir_instructions.items(.data)[reloc_inst].rel.target = current_inst;
    }
}

fn genBody(self: *CodeGen, body: []const Air.Inst.Index) !void {
    const air_tags = self.air.instructions.items(.tag);
    for (body) |body_inst| {
        const tag = air_tags[@intFromEnum(body_inst)];
        try self.genInst(body_inst, tag);
    }
}

fn airDiv(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Determine if signed or unsigned division
    const lhs_ty = self.typeOf(bin_op.lhs.toIndex().?);
    const is_signed = lhs_ty.isSignedInt(self.pt.zcu);

    // ARM64: SDIV Xd, Xn, Xm (signed) or UDIV Xd, Xn, Xm (unsigned)
    try self.addInst(.{
        .tag = if (is_signed) .sdiv else .udiv,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airRem(self: *CodeGen, inst: Air.Inst.Index) !void {
    // ARM64 doesn't have a remainder instruction
    // We need to compute: rem = lhs - (lhs / rhs) * rhs
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    const tmp_reg = try self.register_manager.allocReg(inst, .gp);
    defer self.register_manager.freeReg(tmp_reg);

    const lhs_ty = self.typeOf(bin_op.lhs.toIndex().?);
    const is_signed = lhs_ty.isSignedInt(self.pt.zcu);

    // tmp = lhs / rhs
    try self.addInst(.{
        .tag = if (is_signed) .sdiv else .udiv,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = tmp_reg,
            .rn = lhs.register,
            .rm = rhs.register,
        } },
    });

    // tmp = tmp * rhs
    try self.addInst(.{
        .tag = .mul,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = tmp_reg,
            .rn = tmp_reg,
            .rm = rhs.register,
        } },
    });

    // dst = lhs - tmp
    try self.addInst(.{
        .tag = .sub,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = lhs.register,
            .rm = tmp_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airMod(self: *CodeGen, inst: Air.Inst.Index) !void {
    // For now, treat mod same as rem
    // TODO: Implement proper modulo behavior (different from remainder for negative numbers)
    return self.airRem(inst);
}

fn airNeg(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try self.resolveInst(un_op.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ARM64: NEG Xd, Xm (equivalent to SUB Xd, XZR, Xm)
    try self.addInst(.{
        .tag = .neg,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airNot(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(un_op.operand.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ARM64: MVN Xd, Xm (bitwise NOT)
    try self.addInst(.{
        .tag = .mvn,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airIntCast(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);
    const src_ty = self.typeOf(ty_op.operand.toIndex().?);

    const zcu = self.pt.zcu;
    const dest_bits = dest_ty.bitSize(zcu);
    const src_bits = src_ty.bitSize(zcu);

    if (dest_bits == src_bits) {
        // No conversion needed, just track
        try self.inst_tracking.put(self.gpa, inst, .init(operand));
        return;
    }

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (dest_bits < src_bits) {
        // Truncation - just use the narrower register alias
        const narrow_reg = if (dest_bits <= 32) operand.register.to32() else operand.register.to64();
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rm = narrow_reg,
            } },
        });
    } else {
        // Extension
        const is_signed = src_ty.isSignedInt(zcu);
        if (is_signed) {
            // Sign extension - SXTW (32->64) or SXTB/SXTH for smaller
            if (src_bits <= 32 and dest_bits == 64) {
                try self.addInst(.{
                    .tag = .sxtw,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg.to64(),
                        .rm = operand.register.to32(),
                    } },
                });
            } else {
                // TODO: Handle other sign extension cases
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg,
                        .rm = operand.register,
                    } },
                });
            }
        } else {
            // Zero extension - MOV with 32-bit register zeros upper 32 bits automatically
            if (src_bits <= 32 and dest_bits == 64) {
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg.to32(), // Writing to W reg zeros upper 32 bits
                        .rm = operand.register.to32(),
                    } },
                });
            } else {
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg,
                        .rm = operand.register,
                    } },
                });
            }
        }
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airTrunc(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);

    const zcu = self.pt.zcu;
    const dest_bits = dest_ty.bitSize(zcu);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Truncate by using narrower register alias
    const narrow_reg = if (dest_bits <= 32) operand.register.to32() else operand.register.to64();
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = narrow_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airBoolToInt(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try self.resolveInst(un_op);

    // Boolean is already 0 or 1, just track it
    try self.inst_tracking.put(self.gpa, inst, .init(operand));
}

fn airPtrAdd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const offset = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ADD Xd, Xn, Xm (pointer + offset)
    try self.addInst(.{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = ptr.register,
            .rm = offset.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airPtrSub(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const offset = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // SUB Xd, Xn, Xm (pointer - offset)
    try self.addInst(.{
        .tag = .sub,
        .ops = .rrr,
        .data = .{ .rrr = .{
            .rd = dst_reg,
            .rn = ptr.register,
            .rm = offset.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airSlicePtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const slice = try self.resolveInst(ty_op.operand.toIndex().?);

    // Slice is represented as { ptr, len } pair
    // For register_pair, first register is the pointer
    const ptr_reg = switch (slice) {
        .register_pair => |regs| regs[0],
        else => return error.CodegenFail,
    };

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = ptr_reg }));
}

fn airSliceLen(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const slice = try self.resolveInst(ty_op.operand.toIndex().?);

    // Slice is represented as { ptr, len } pair
    // For register_pair, second register is the length
    const len_reg = switch (slice) {
        .register_pair => |regs| regs[1],
        else => return error.CodegenFail,
    };

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = len_reg }));
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

fn typeOf(self: *CodeGen, inst: Air.Inst.Index) Type {
    const air_tags = self.air.instructions.items(.tag);
    return self.air.typeOf(inst, air_tags[@intFromEnum(inst)]);
}

fn typeOfIndex(self: *CodeGen, inst: Air.Inst.Index) Type {
    return self.air.typeOfIndex(inst, &self.pt.zcu.intern_pool);
}

// ============================================================================
// Register Spilling
// ============================================================================

/// Allocate a register, spilling if necessary
fn allocRegOrSpill(self: *CodeGen, inst: Air.Inst.Index, reg_class: abi.RegisterClass) !Register {
    return self.register_manager.allocReg(inst, reg_class) catch {
        // Out of registers, need to spill one
        const spill_reg = try self.findSpillCandidate(reg_class);
        try self.spillReg(spill_reg);
        return self.register_manager.allocReg(inst, reg_class);
    };
}

/// Find a register to spill (heuristic: find oldest allocation)
fn findSpillCandidate(self: *CodeGen, reg_class: abi.RegisterClass) !Register {
    const regs = switch (reg_class) {
        .gp => &abi.caller_preserved_gp_regs,
        .vector => &abi.caller_preserved_fp_regs,
    };

    // Simple heuristic: spill the first allocated register
    // TODO: Use better heuristics (LRU, furthest next use, etc.)
    for (regs) |reg| {
        if (self.register_manager.getRegOwner(reg)) |_| {
            return reg;
        }
    }

    return error.OutOfRegisters;
}

/// Spill a register to stack
fn spillReg(self: *CodeGen, reg: Register) !void {
    const owner = self.register_manager.getRegOwner(reg) orelse return;
    const tracking = self.inst_tracking.getPtr(owner) orelse return;

    // Allocate stack space for the spill (8 bytes for GP, 16 for vector)
    const spill_size: u32 = switch (reg.class()) {
        .general_purpose => 8,
        .vector => 16,
        .special => return error.CannotSpillSpecialRegister,
    };

    // Align stack offset
    self.stack_offset = std.mem.alignForward(u32, self.stack_offset, spill_size);
    const spill_offset = self.stack_offset;
    self.stack_offset += spill_size;

    // Store register to stack: STR Xn, [X29, #-offset]
    // (Store relative to frame pointer)
    try self.addInst(.{
        .tag = .str,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = .{
                .base = .{ .reg = .x29 }, // Frame pointer
                .mod = .{ .immediate = -@as(i32, @intCast(spill_offset)) },
            },
            .rs = reg,
        } },
    });

    // Emit pseudo-instruction for debug info
    if (!self.mod.strip) {
        try self.addInst(.{
            .tag = .pseudo_spill,
            .ops = .none,
            .data = .{ .none = {} },
        });
    }

    // Update tracking to indicate value is on stack
    tracking.long = .{ .load_frame = .{
        .index = .stack_frame,
        .off = spill_offset,
    } };

    // Free the register
    self.register_manager.freeReg(reg);
}

/// Reload a value from stack to register
fn reloadReg(self: *CodeGen, inst: Air.Inst.Index, frame_addr: bits.FrameAddr) !Register {
    const reg_class: abi.RegisterClass = .gp; // TODO: Determine from type
    const reg = try self.allocRegOrSpill(inst, reg_class);

    // Load from stack: LDR Xn, [X29, #-offset]
    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = reg,
            .mem = .{
                .base = .{ .reg = .x29 }, // Frame pointer
                .mod = .{ .immediate = -@as(i32, @intCast(frame_addr.off)) },
            },
        } },
    });

    // Emit pseudo-instruction for debug info
    if (!self.mod.strip) {
        try self.addInst(.{
            .tag = .pseudo_reload,
            .ops = .none,
            .data = .{ .none = {} },
        });
    }

    return reg;
}
