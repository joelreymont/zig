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

fn gen(self: *CodeGen) error{ CodegenFail, OutOfMemory, Overflow, RelocationNotByteAligned }!void {
    self.genImpl() catch |err| switch (err) {
        error.OutOfRegisters => return error.CodegenFail,
        else => |e| return e,
    };
}

fn genImpl(self: *CodeGen) error{ CodegenFail, OutOfMemory, OutOfRegisters, Overflow, RelocationNotByteAligned }!void {
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

fn genInst(self: *CodeGen, inst: Air.Inst.Index, tag: Air.Inst.Tag) error{ CodegenFail, OutOfMemory, OutOfRegisters }!void {
    return switch (tag) {
        // Arithmetic
        .add => self.airAdd(inst),
        .sub => self.airSub(inst),
        .mul => self.airMul(inst),
        .div_trunc, .div_exact => self.airDiv(inst),
        .rem => self.airRem(inst),
        .mod => self.airMod(inst),
        .neg => self.airNeg(inst),
        .min => self.airMinMax(inst, true),
        .max => self.airMinMax(inst, false),

        // Bitwise
        .bit_and => self.airAnd(inst),
        .bit_or => self.airOr(inst),
        .xor => self.airXor(inst),
        .not => self.airNot(inst),
        .clz => self.airClz(inst),
        .ctz => self.airCtz(inst),
        .popcount => self.airPopcount(inst),

        // Boolean operations
        .bool_and => self.airBoolAnd(inst),
        .bool_or => self.airBoolOr(inst),

        // Shifts
        .shl, .shl_exact => self.airShl(inst),
        .shr, .shr_exact => self.airShr(inst),

        // Load/Store
        .load => self.airLoad(inst),
        .store => self.airStore(inst),

        // Compare
        .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte => self.airCmp(inst),

        // Select (ternary)
        .select => self.airSelect(inst),

        // Float operations
        .sqrt, .abs => self.airUnaryFloatOp(inst),

        // Branches
        .br => self.airBr(inst),
        .cond_br => self.airCondBr(inst),

        // Return
        .ret => self.airRet(inst),
        .ret_load => self.airRetLoad(inst),

        // Function calls
        .call, .call_always_tail, .call_never_tail, .call_never_inline => self.airCall(inst),

        // Type conversions
        .intcast => self.airIntCast(inst),
        .trunc => self.airTrunc(inst),
        .fptrunc, .fpext => self.airFloatCast(inst),
        .int_from_float => self.airIntFromFloat(inst),
        .float_from_int => self.airFloatFromInt(inst),

        // Pointer operations
        .ptr_add => self.airPtrAdd(inst),
        .ptr_sub => self.airPtrSub(inst),

        // Memory allocation
        .alloc => self.airAlloc(inst),

        // Struct and array access
        .struct_field_ptr => self.airStructFieldPtr(inst),
        .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
        => self.airStructFieldPtrIndex(inst),
        .struct_field_val => self.airStructFieldVal(inst),
        .ptr_elem_ptr => self.airPtrElemPtr(inst),
        .ptr_elem_val => self.airPtrElemVal(inst),
        .array_elem_val => self.airArrayElemVal(inst),

        // Slice operations
        .slice => self.airSlice(inst),
        .slice_ptr => self.airSlicePtr(inst),
        .slice_len => self.airSliceLen(inst),

        // Optional handling
        .is_null => self.airIsNull(inst, true),
        .is_non_null => self.airIsNull(inst, false),
        .is_null_ptr => self.airIsNullPtr(inst, true),
        .is_non_null_ptr => self.airIsNullPtr(inst, false),
        .optional_payload => self.airOptionalPayload(inst),
        .optional_payload_ptr => self.airOptionalPayloadPtr(inst),
        .wrap_optional => self.airWrapOptional(inst),

        // Error union handling
        .is_err => self.airIsErr(inst, true),
        .is_non_err => self.airIsErr(inst, false),
        .unwrap_errunion_payload => self.airUnwrapErrUnionPayload(inst),
        .unwrap_errunion_err => self.airUnwrapErrUnionErr(inst),
        .wrap_errunion_payload => self.airWrapErrUnionPayload(inst),

        // Union operations
        .get_union_tag => self.airGetUnionTag(inst),

        // Blocks
        .block => self.airBlock(inst),

        // Function arguments
        .arg => self.airArg(inst),

        // Unreachable/trap
        .unreach, .breakpoint => self.airUnreachable(inst),

        // Bitcast
        .bitcast => self.airBitcast(inst),

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

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    // Allocate destination register
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    if (is_float) {
        // FADD Dd, Dn, Dm (floating point add)
        try self.addInst(.{
            .tag = .fadd,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
            } },
        });
    } else {
        // Integer ADD instruction
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
    }

    // Track result
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airSub(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    if (is_float) {
        // FSUB Dd, Dn, Dm (floating point subtract)
        try self.addInst(.{
            .tag = .fsub,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
            } },
        });
    } else {
        // Integer SUB instruction
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
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airMul(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    const tag: Mir.Inst.Tag = if (is_float) .fmul else .mul;
    try self.addInst(.{
        .tag = tag,
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

fn airStructFieldPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;

    const ptr_field_ty = ty_pl.ty.toType();
    const ptr_agg_ty = self.typeOf(struct_field.struct_operand);
    const field_offset = codegen.fieldOffset(ptr_agg_ty, ptr_field_ty, struct_field.field_index, self.pt.zcu);

    const base_ptr = try self.resolveInst(struct_field.struct_operand.toIndex().?);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (field_offset == 0) {
        // Field is at offset 0, just copy the pointer
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = base_ptr.register,
            } },
        });
    } else {
        // ADD dst, base, #offset
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = base_ptr.register,
                .imm = field_offset,
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airStructFieldPtrIndex(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const tag = self.air.instructions.items(.tag)[@intFromEnum(inst)];

    const field_index: u32 = switch (tag) {
        .struct_field_ptr_index_0 => 0,
        .struct_field_ptr_index_1 => 1,
        .struct_field_ptr_index_2 => 2,
        .struct_field_ptr_index_3 => 3,
        else => unreachable,
    };

    const ptr_field_ty = ty_op.ty.toType();
    const ptr_agg_ty = self.typeOf(ty_op.operand);
    const field_offset = codegen.fieldOffset(ptr_agg_ty, ptr_field_ty, field_index, self.pt.zcu);

    const base_ptr = try self.resolveInst(ty_op.operand.toIndex().?);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (field_offset == 0) {
        // Field is at offset 0, just copy the pointer
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = base_ptr.register,
            } },
        });
    } else {
        // ADD dst, base, #offset
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = base_ptr.register,
                .imm = field_offset,
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airStructFieldVal(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;

    const field_ty = ty_pl.ty.toType();
    const agg_ty = self.typeOf(struct_field.struct_operand);
    const zcu = self.pt.zcu;

    // Calculate field offset
    const field_offset: i32 = switch (agg_ty.containerLayout(zcu)) {
        .auto, .@"extern" => @intCast(agg_ty.structFieldOffset(struct_field.field_index, zcu)),
        .@"packed" => return self.fail("TODO: packed struct field access not yet implemented", .{}),
    };

    // Check if field has runtime bits
    if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
        // Zero-sized field, return undefined/zero
        const dst_reg = try self.register_manager.allocReg(inst, .gp);
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = dst_reg,
                .imm = 0,
            } },
        });
        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
        return;
    }

    const struct_val = try self.resolveInst(struct_field.struct_operand.toIndex().?);

    // Determine register class based on field type
    const is_float = field_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // Load field value from struct at offset
    // LDR dst, [struct_ptr, #offset]
    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = dst_reg,
            .mem = Memory.simple(struct_val.register, field_offset),
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airPtrElemPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;

    const ptr_ty = self.typeOf(bin_op.lhs);
    const elem_ty = ptr_ty.childType(self.pt.zcu);
    const elem_size = elem_ty.abiSize(self.pt.zcu);

    const base_ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const index = try self.resolveInst(bin_op.rhs.toIndex().?);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Calculate offset: index * elem_size
    // For power-of-2 sizes, we can use LSL (left shift)
    if (std.math.isPowerOfTwo(elem_size)) {
        const shift = std.math.log2_int(u64, elem_size);

        if (shift == 0) {
            // Element size is 1, just add index to base
            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = dst_reg,
                    .rn = base_ptr.register,
                    .rm = index.register,
                } },
            });
        } else {
            // ADD dst, base, index, LSL #shift
            // For now, do it in two steps: shift then add
            const temp_reg = try self.register_manager.allocReg(null, .gp);

            // LSL temp, index, #shift
            try self.addInst(.{
                .tag = .lsl,
                .ops = .rri,
                .data = .{ .rri = .{
                    .rd = temp_reg,
                    .rn = index.register,
                    .imm = shift,
                } },
            });

            // ADD dst, base, temp
            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = dst_reg,
                    .rn = base_ptr.register,
                    .rm = temp_reg,
                } },
            });

            self.register_manager.freeReg(temp_reg);
        }
    } else {
        // Non-power-of-2 size, need to multiply
        const temp_reg = try self.register_manager.allocReg(null, .gp);

        // Load elem_size into temp
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = temp_reg,
                .imm = @intCast(elem_size & 0xFFFF),
            } },
        });

        const offset_reg = try self.register_manager.allocReg(null, .gp);

        // MUL offset, index, elem_size
        try self.addInst(.{
            .tag = .mul,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = offset_reg,
                .rn = index.register,
                .rm = temp_reg,
            } },
        });

        // ADD dst, base, offset
        try self.addInst(.{
            .tag = .add,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = dst_reg,
                .rn = base_ptr.register,
                .rm = offset_reg,
            } },
        });

        self.register_manager.freeReg(temp_reg);
        self.register_manager.freeReg(offset_reg);
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airPtrElemVal(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const ptr_ty = self.typeOf(bin_op.lhs);
    const elem_ty = ptr_ty.childType(self.pt.zcu);
    const elem_size = elem_ty.abiSize(self.pt.zcu);

    const base_ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const index = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Determine register class based on element type
    const is_float = elem_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // For simple cases with small constant index, we can use immediate offset
    if (index == .immediate and index.immediate * elem_size < 32768) {
        const offset: i32 = @intCast(index.immediate * elem_size);
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(base_ptr.register, offset),
            } },
        });
    } else {
        // Calculate address first, then load
        const addr_reg = try self.register_manager.allocReg(null, .gp);

        // Calculate offset
        if (std.math.isPowerOfTwo(elem_size)) {
            const shift = std.math.log2_int(u64, elem_size);

            if (shift == 0) {
                // ADD addr, base, index
                try self.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = addr_reg,
                        .rn = base_ptr.register,
                        .rm = index.register,
                    } },
                });
            } else {
                // Shift and add
                const temp_reg = try self.register_manager.allocReg(null, .gp);

                try self.addInst(.{
                    .tag = .lsl,
                    .ops = .rri,
                    .data = .{ .rri = .{
                        .rd = temp_reg,
                        .rn = index.register,
                        .imm = shift,
                    } },
                });

                try self.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = addr_reg,
                        .rn = base_ptr.register,
                        .rm = temp_reg,
                    } },
                });

                self.register_manager.freeReg(temp_reg);
            }
        } else {
            // Non-power-of-2 size
            const size_reg = try self.register_manager.allocReg(null, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = size_reg,
                    .imm = @intCast(elem_size & 0xFFFF),
                } },
            });

            const offset_reg = try self.register_manager.allocReg(null, .gp);
            try self.addInst(.{
                .tag = .mul,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = offset_reg,
                    .rn = index.register,
                    .rm = size_reg,
                } },
            });

            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = addr_reg,
                    .rn = base_ptr.register,
                    .rm = offset_reg,
                } },
            });

            self.register_manager.freeReg(size_reg);
            self.register_manager.freeReg(offset_reg);
        }

        // Load from calculated address
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(addr_reg, 0),
            } },
        });

        self.register_manager.freeReg(addr_reg);
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airArrayElemVal(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const array_ty = self.typeOf(bin_op.lhs);
    const elem_ty = array_ty.childType(self.pt.zcu);
    const elem_size = elem_ty.abiSize(self.pt.zcu);

    const array_val = try self.resolveInst(bin_op.lhs.toIndex().?);
    const index = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Determine register class based on element type
    const is_float = elem_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // For array by-value, the array is typically on the stack
    // array_val should be a pointer to the array
    // Calculate offset and load
    if (index == .immediate and index.immediate * elem_size < 32768) {
        const offset: i32 = @intCast(index.immediate * elem_size);
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(array_val.register, offset),
            } },
        });
    } else {
        // Calculate address dynamically
        const addr_reg = try self.register_manager.allocReg(null, .gp);

        if (std.math.isPowerOfTwo(elem_size)) {
            const shift = std.math.log2_int(u64, elem_size);

            if (shift == 0) {
                try self.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = addr_reg,
                        .rn = array_val.register,
                        .rm = index.register,
                    } },
                });
            } else {
                const temp_reg = try self.register_manager.allocReg(null, .gp);

                try self.addInst(.{
                    .tag = .lsl,
                    .ops = .rri,
                    .data = .{ .rri = .{
                        .rd = temp_reg,
                        .rn = index.register,
                        .imm = shift,
                    } },
                });

                try self.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = addr_reg,
                        .rn = array_val.register,
                        .rm = temp_reg,
                    } },
                });

                self.register_manager.freeReg(temp_reg);
            }
        } else {
            const size_reg = try self.register_manager.allocReg(null, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = size_reg,
                    .imm = @intCast(elem_size & 0xFFFF),
                } },
            });

            const offset_reg = try self.register_manager.allocReg(null, .gp);
            try self.addInst(.{
                .tag = .mul,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = offset_reg,
                    .rn = index.register,
                    .rm = size_reg,
                } },
            });

            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = addr_reg,
                    .rn = array_val.register,
                    .rm = offset_reg,
                } },
            });

            self.register_manager.freeReg(size_reg);
            self.register_manager.freeReg(offset_reg);
        }

        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(addr_reg, 0),
            } },
        });

        self.register_manager.freeReg(addr_reg);
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airIsNull(self: *CodeGen, inst: Air.Inst.Index, comptime is_null: bool) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const opt_ty = self.typeOf(un_op);
    const zcu = self.pt.zcu;

    const opt_repr_is_pl = opt_ty.optionalReprIsPayload(zcu);
    const opt_child_ty = opt_ty.optionalChild(zcu);
    const opt_child_abi_size: i32 = @intCast(opt_child_ty.abiSize(zcu));

    const operand = try self.resolveInst(un_op.toIndex().?);

    // Compare null tag (or payload for pointer-based optionals) with 0
    if (opt_repr_is_pl) {
        // Pointer-based optional: null is represented as 0
        // CMP operand, #0
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = operand.register,
                .rn = .xzr, // Compare with zero register
            } },
        });
    } else {
        // Tag-based optional: load null tag from offset and compare with 0
        const tag_reg = try self.register_manager.allocReg(null, .gp);

        // Load null tag: LDRB tag, [operand, #opt_child_abi_size]
        try self.addInst(.{
            .tag = .ldrb,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = tag_reg,
                .mem = Memory.simple(operand.register, opt_child_abi_size),
            } },
        });

        // CMP tag, #0
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = tag_reg,
                .rn = .xzr,
            } },
        });

        self.register_manager.freeReg(tag_reg);
    }

    // Materialize result to register using CSET
    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    const cond: Condition = if (is_null) .eq else .ne;

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

fn airIsNullPtr(self: *CodeGen, inst: Air.Inst.Index, comptime is_null: bool) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const ptr_ty = self.typeOf(un_op);
    const opt_ty = ptr_ty.childType(self.pt.zcu);
    const zcu = self.pt.zcu;

    const opt_repr_is_pl = opt_ty.optionalReprIsPayload(zcu);
    const opt_child_ty = opt_ty.optionalChild(zcu);
    const opt_child_abi_size: i32 = @intCast(opt_child_ty.abiSize(zcu));

    const ptr = try self.resolveInst(un_op.toIndex().?);

    // Load from pointer and compare
    if (opt_repr_is_pl) {
        // Load pointer value and compare with 0
        const val_reg = try self.register_manager.allocReg(null, .gp);

        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = val_reg,
                .mem = Memory.simple(ptr.register, 0),
            } },
        });

        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = val_reg,
                .rn = .xzr,
            } },
        });

        self.register_manager.freeReg(val_reg);
    } else {
        // Load null tag from [ptr + opt_child_abi_size]
        const tag_reg = try self.register_manager.allocReg(null, .gp);

        try self.addInst(.{
            .tag = .ldrb,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = tag_reg,
                .mem = Memory.simple(ptr.register, opt_child_abi_size),
            } },
        });

        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = tag_reg,
                .rn = .xzr,
            } },
        });

        self.register_manager.freeReg(tag_reg);
    }

    // Materialize result
    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    const cond: Condition = if (is_null) .eq else .ne;

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

fn airOptionalPayload(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const opt_ty = self.typeOf(ty_op.operand);
    const payload_ty = ty_op.ty.toType();

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // For payload-based optionals (pointers), the payload is the value itself
    // For tag-based optionals, the payload is at offset 0
    // In both cases, just return the operand (or load from it)
    const is_float = payload_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    const zcu = self.pt.zcu;
    const opt_repr_is_pl = opt_ty.optionalReprIsPayload(zcu);

    if (opt_repr_is_pl) {
        // Payload is the value itself, just move it
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else {
        // Payload is at offset 0, load it
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(operand.register, 0),
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airOptionalPayloadPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // For pointer to optional, payload pointer is the same as the optional pointer
    // (since payload is at offset 0)
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airWrapOptional(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const opt_ty = ty_op.ty.toType();
    const payload = try self.resolveInst(ty_op.operand.toIndex().?);
    const zcu = self.pt.zcu;

    const opt_repr_is_pl = opt_ty.optionalReprIsPayload(zcu);

    if (opt_repr_is_pl) {
        // For pointer-based optionals, the payload is the optional value
        const dst_reg = try self.register_manager.allocReg(inst, .gp);
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = payload.register,
            } },
        });
        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    } else {
        // For tag-based optionals, need to store payload + set tag to 1
        // This typically requires stack allocation
        // For now, simplified: just return payload and mark as TODO
        return self.fail("TODO: wrap_optional for tag-based optionals requires stack allocation", .{});
    }
}

fn airIsErr(self: *CodeGen, inst: Air.Inst.Index, comptime is_err: bool) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const err_union_ty = self.typeOf(un_op);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    const operand = try self.resolveInst(un_op.toIndex().?);

    // Load error value from union
    const err_reg = try self.register_manager.allocReg(null, .gp);

    // Error is u16, use LDRH
    try self.addInst(.{
        .tag = .ldrh,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = err_reg,
            .mem = Memory.simple(operand.register, err_off),
        } },
    });

    // Compare with 0
    try self.addInst(.{
        .tag = .cmp,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = err_reg,
            .rn = .xzr,
        } },
    });

    self.register_manager.freeReg(err_reg);

    // Materialize result
    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    const cond: Condition = if (is_err) .ne else .eq;

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

fn airUnwrapErrUnionPayload(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const payload_ty = ty_op.ty.toType();
    const zcu = self.pt.zcu;

    const payload_off: i32 = @intCast(codegen.errUnionPayloadOffset(payload_ty, zcu));

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    const is_float = payload_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // Load payload from union
    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = dst_reg,
            .mem = Memory.simple(operand.register, payload_off),
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airUnwrapErrUnionErr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const err_union_ty = self.typeOf(ty_op.operand);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Load error value (u16)
    try self.addInst(.{
        .tag = .ldrh,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = dst_reg,
            .mem = Memory.simple(operand.register, err_off),
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airWrapErrUnionPayload(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;
    // Wrapping a payload in an error union requires creating the struct
    // with error = 0 and payload = value
    // This typically requires stack allocation
    return self.fail("TODO: wrap_errunion_payload requires stack allocation and struct creation", .{});
}

fn airUnaryFloatOp(self: *CodeGen, inst: Air.Inst.Index) !void {
    const tag = self.air.instructions.items(.tag)[@intFromEnum(inst)];
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;

    const result_ty = self.typeOfIndex(inst);
    const operand = try self.resolveInst(un_op.toIndex().?);

    // Determine if this is actually a float operation
    const is_float = result_ty.isRuntimeFloat();

    if (!is_float) {
        // Integer operations
        if (tag == .neg) {
            return self.airNeg(inst);
        } else {
            return self.fail("TODO: integer {} not implemented", .{tag});
        }
    }

    // Allocate destination register
    const dst_reg = try self.register_manager.allocReg(inst, .vector);

    const mir_tag: Mir.Inst.Tag = switch (tag) {
        .sqrt => .fsqrt,
        .neg => .fneg,
        .abs => .fabs,
        else => unreachable,
    };

    try self.addInst(.{
        .tag = mir_tag,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airCmp(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Check if this is a float comparison
    const lhs_ty = self.typeOf(bin_op.lhs);
    const is_float = lhs_ty.isRuntimeFloat();

    if (is_float) {
        // Floating point comparison
        // FCMP sets NZCV flags
        try self.addInst(.{
            .tag = .fcmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = lhs.register,
                .rn = rhs.register,
            } },
        });
    } else {
        // Integer comparison
        // CMP sets condition flags
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = lhs.register,
                .rn = rhs.register,
            } },
        });
    }

    // Result is in condition flags - materialize to register using CSET
    const tag = self.air.instructions.items(.tag)[@intFromEnum(inst)];
    const cond: Condition = switch (tag) {
        .cmp_eq => .eq,
        .cmp_neq => .ne,
        .cmp_lt => if (is_float) .mi else .lt, // Float uses MI (minus/negative) for less than
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

fn airCall(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = self.air.extraData(Air.Call, pl_op.payload);
    const args: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.args_len]);

    const callee = pl_op.operand;

    // ARM64 calling convention: first 8 integer args in X0-X7
    // TODO: Handle more than 8 args (stack), float args (D0-D7), and return values

    // Marshal arguments to argument registers
    for (args, 0..) |arg, i| {
        if (i >= 8) {
            // TODO: Stack arguments
            return self.fail("TODO: ARM64 function calls with >8 arguments not yet supported", .{});
        }

        const arg_mcv = try self.resolveInst(arg.toIndex().?);
        const arg_reg = Register.x0.offset(@intCast(i)); // X0, X1, X2, ..., X7

        // Move argument to the appropriate register
        switch (arg_mcv) {
            .register => |reg| {
                if (reg.id() != arg_reg.id()) {
                    try self.addInst(.{
                        .tag = .mov,
                        .ops = .rr,
                        .data = .{ .rr = .{
                            .rd = arg_reg,
                            .rn = reg,
                        } },
                    });
                }
            },
            .immediate => |imm| {
                // Load immediate to argument register
                try self.addInst(.{
                    .tag = .movz,
                    .ops = .ri,
                    .data = .{ .ri = .{
                        .rd = arg_reg,
                        .imm = @intCast(imm & 0xFFFF),
                    } },
                });
                // TODO: Handle larger immediates with MOVK
            },
            else => return self.fail("TODO: ARM64 airCall with arg type {}", .{arg_mcv}),
        }
    }

    // Generate call instruction
    switch (try self.resolveInst(callee.toIndex().?)) {
        .register => |reg| {
            // BLR - Branch with link to register
            try self.addInst(.{
                .tag = .blr,
                .ops = .r,
                .data = .{ .r = .{ .rn = reg } },
            });
        },
        .memory => {
            // TODO: Load function pointer and call via BLR
            return self.fail("TODO: ARM64 indirect calls via memory", .{});
        },
        else => {
            // Direct call - assume it's a symbol
            // BL - Branch with link (direct call)
            // TODO: For now, we'll use BLR with the callee in a register
            // This needs proper symbol resolution
            return self.fail("TODO: ARM64 direct function calls need symbol resolution", .{});
        },
    }

    // Track return value in X0
    const result_ty = self.typeOfIndex(inst);
    if (!result_ty.hasRuntimeBitsIgnoreComptime(self.pt.zcu)) {
        // Void return - no value to track
        return;
    }

    // Store return value from X0
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = .x0 }));
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

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    if (is_float) {
        // FDIV Dd, Dn, Dm (floating point divide)
        try self.addInst(.{
            .tag = .fdiv,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
            } },
        });
    } else {
        // Determine if signed or unsigned division
        const lhs_ty = self.typeOf(bin_op.lhs);
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
    }

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

    const lhs_ty = self.typeOf(bin_op.lhs);
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

fn airMinMax(self: *CodeGen, inst: Air.Inst.Index, comptime is_min: bool) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    if (is_float) {
        // Floating point min/max using FCMP + CSEL
        // FCMP lhs, rhs
        // CSEL dst, lhs, rhs, <condition>

        try self.addInst(.{
            .tag = .fcmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = lhs.register,
                .rn = rhs.register,
            } },
        });

        const dst_reg = try self.register_manager.allocReg(inst, .vector);

        // For min: select lhs if lhs < rhs (LT/MI), else rhs
        // For max: select lhs if lhs > rhs (GT), else rhs
        const cond: Condition = if (is_min) .mi else .gt; // MI = less than for floats, GT = greater than

        try self.addInst(.{
            .tag = .csel,
            .ops = .rrrc,
            .data = .{ .rrrc = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
                .cond = cond,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    } else {
        // Integer min/max using conditional select
        // CMP lhs, rhs
        // CSEL dst, lhs, rhs, <condition>

        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = lhs.register,
                .rn = rhs.register,
            } },
        });

        const dst_reg = try self.register_manager.allocReg(inst, .gp);

        // For min: select lhs if lhs < rhs (LT), else rhs
        // For max: select lhs if lhs > rhs (GT), else rhs
        const zcu = self.pt.zcu;
        const is_signed = result_ty.isSignedInt(zcu);
        const cond: Condition = if (is_min)
            (if (is_signed) .lt else .lo) // less than (signed) or lower (unsigned)
        else
            (if (is_signed) .gt else .hi); // greater than (signed) or higher (unsigned)

        try self.addInst(.{
            .tag = .csel,
            .ops = .rrrc,
            .data = .{ .rrrc = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
                .cond = cond,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    }
}

fn airClz(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(un_op.operand.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // CLZ Xd, Xn - Count leading zeros
    try self.addInst(.{
        .tag = .clz,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airCtz(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(un_op.operand.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ARM64 doesn't have a CTZ instruction, but we can implement it as:
    // RBIT (reverse bits), then CLZ
    // We can reuse dst_reg to avoid needing a temporary

    // RBIT dst, operand - Reverse bit order
    try self.addInst(.{
        .tag = .rbit,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    // CLZ dst, dst - Count leading zeros (which are trailing zeros in original)
    try self.addInst(.{
        .tag = .clz,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = dst_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airPopcount(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;
    // ARM64 has NEON instruction CNT (count bits), but it works on vector registers
    // For scalar, we need to:
    // 1. Move to vector register (FMOV Dd, Xn)
    // 2. Use CNT Vd.8B, Vn.8B (count bits in each byte)
    // 3. Use ADDV to sum all bytes
    // 4. Move back to general purpose register
    // This requires full NEON vector arrangement encoding which is not yet implemented
    return self.fail("TODO: popcount requires NEON vector operations not yet fully implemented", .{});
}

fn airSelect(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = self.air.extraData(Air.Bin, pl_op.payload).data;

    // Select has 3 operands: condition, true_value, false_value
    // pl_op.operand is the condition (boolean)
    // extra contains true and false values

    const cond = try self.resolveInst(pl_op.operand.toIndex().?);
    const true_val = try self.resolveInst(extra.lhs.toIndex().?);
    const false_val = try self.resolveInst(extra.rhs.toIndex().?);

    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // Compare condition with zero (false)
    // CMP cond, #0
    try self.addInst(.{
        .tag = .cmp,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = cond.register,
            .rn = .xzr, // Compare with zero
        } },
    });

    // CSEL dst, true_val, false_val, NE
    // Select true_val if condition != 0 (NE), else false_val
    try self.addInst(.{
        .tag = .csel,
        .ops = .rrrc,
        .data = .{ .rrrc = .{
            .rd = dst_reg,
            .rn = true_val.register,
            .rm = false_val.register,
            .cond = .ne, // not equal (condition is true/nonzero)
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airIntCast(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);
    const src_ty = self.typeOf(ty_op.operand);

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
                .rn = narrow_reg,
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
                        .rn = operand.register.to32(),
                    } },
                });
            } else {
                // TODO: Handle other sign extension cases
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg,
                        .rn = operand.register,
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
                        .rn = operand.register.to32(),
                    } },
                });
            } else {
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg,
                        .rn = operand.register,
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

fn airFloatCast(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);
    const src_ty = self.typeOf(ty_op.operand);

    const dst_reg = try self.register_manager.allocReg(inst, .vector);

    // FCVT converts between different float precisions
    // The instruction automatically handles f16/f32/f64/f128 based on register size
    // For now, simplified version - use FMOV if same size, FCVT if different
    const zcu = self.pt.zcu;
    const dest_bits = dest_ty.bitSize(zcu);
    const src_bits = src_ty.bitSize(zcu);

    if (dest_bits == src_bits) {
        // Same size, just move
        try self.addInst(.{
            .tag = .fmov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else {
        // Different size, use FCVT
        try self.addInst(.{
            .tag = .fcvt,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airIntFromFloat(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);

    const zcu = self.pt.zcu;
    const is_signed = dest_ty.isSignedInt(zcu);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // FCVTZS (signed) or FCVTZU (unsigned) converts float to int, rounding toward zero
    const tag: Mir.Inst.Tag = if (is_signed) .fcvtzs else .fcvtzu;

    try self.addInst(.{
        .tag = tag,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airFloatFromInt(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const src_ty = self.typeOf(ty_op.operand);

    const zcu = self.pt.zcu;
    const is_signed = src_ty.isSignedInt(zcu);

    const dst_reg = try self.register_manager.allocReg(inst, .vector);

    // SCVTF (signed) or UCVTF (unsigned) converts int to float
    const tag: Mir.Inst.Tag = if (is_signed) .scvtf else .ucvtf;

    try self.addInst(.{
        .tag = tag,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
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

fn airArg(self: *CodeGen, inst: Air.Inst.Index) !void {
    // Function arguments are passed in registers or on the stack according to the calling convention
    // For ARM64 C calling convention:
    // - First 8 integer args in X0-X7
    // - First 8 float args in D0-D7 (V0-V7 lower 64 bits)
    // - Additional args on stack

    const arg_data = self.air.instructions.items(.data)[@intFromEnum(inst)].arg;
    const arg_index = arg_data.zir_param_index;
    const arg_ty = arg_data.ty.toType();

    // Determine if this is a float or integer argument
    const is_float = arg_ty.isRuntimeFloat();

    // For now, simplified: assume all args fit in registers
    // TODO: Handle stack arguments when >8 args
    if (arg_index >= 8) {
        return self.fail("TODO: ARM64 stack arguments not yet implemented", .{});
    }

    // Determine which register the argument is in
    const src_reg = if (is_float)
        // Float args in V0-V7 (D0-D7)
        Register.v0.offset(@intCast(arg_index))
    else
        // Integer args in X0-X7
        Register.x0.offset(@intCast(arg_index));

    // Mark the register as occupied by this instruction
    self.register_manager.getRegAssumeFree(src_reg, inst);

    // Track the argument value
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = src_reg }));
}

fn airUnreachable(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;
    // Generate a trap instruction (BRK or UDF)
    // BRK #0 will cause a breakpoint exception
    // Note: BRK uses immediate encoding, but we just emit a simple instruction
    // The actual immediate value is not critical for a trap
    try self.addInst(.{
        .tag = .brk,
        .ops = .none,
        .data = .{ .none = {} },
    });
}

fn airBitcast(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const dest_ty = self.typeOfIndex(inst);
    const src_ty = self.typeOf(ty_op.operand);

    const dest_is_float = dest_ty.isRuntimeFloat();
    const src_is_float = src_ty.isRuntimeFloat();

    // If bitcasting between int and float, need to move between register classes
    if (dest_is_float != src_is_float) {
        const dst_reg_class: abi.RegisterClass = if (dest_is_float) .vector else .gp;
        const dst_reg = try self.register_manager.allocReg(inst, dst_reg_class);

        if (dest_is_float) {
            // Integer to float register: FMOV Dd, Xn
            try self.addInst(.{
                .tag = .fmov,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rd = dst_reg,
                    .rn = operand.register,
                } },
            });
        } else {
            // Float to integer register: FMOV Xd, Dn
            try self.addInst(.{
                .tag = .fmov,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rd = dst_reg,
                    .rn = operand.register,
                } },
            });
        }

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    } else {
        // Same register class, just track the same value
        try self.inst_tracking.put(self.gpa, inst, .init(operand));
    }
}

fn airBoolAnd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // AND Xd, Xn, Xm (boolean AND - same as bitwise AND for bools)
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

fn airBoolOr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ORR Xd, Xn, Xm (boolean OR - same as bitwise OR for bools)
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

fn airGetUnionTag(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const union_ty = self.typeOf(ty_op.operand);

    const zcu = self.pt.zcu;

    // For tagged unions, the tag is typically stored at the beginning of the struct
    // Get the layout to determine tag offset
    const layout = union_ty.unionGetLayout(zcu);
    const tag_size = layout.tag_size;

    if (tag_size == 0) {
        // Untagged union - no tag to get
        return self.fail("Cannot get tag of untagged union", .{});
    }

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Load the tag from memory
    // The tag is at the union pointer + tag offset
    const tag_off: i32 = @intCast(layout.tag_align.forward(layout.payload_size));

    if (tag_off == 0) {
        // Tag is at offset 0, just load it
        try self.addInst(.{
            .tag = if (tag_size <= 1) .ldrb else if (tag_size <= 2) .ldrh else .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = .{
                    .base = .{ .reg = operand.register },
                    .mod = .{ .immediate = 0 },
                },
            } },
        });
    } else {
        // Tag is at non-zero offset
        try self.addInst(.{
            .tag = if (tag_size <= 1) .ldrb else if (tag_size <= 2) .ldrh else .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = .{
                    .base = .{ .reg = operand.register },
                    .mod = .{ .immediate = tag_off },
                },
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airSlice(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const bin = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const ptr = try self.resolveInst(bin.lhs.toIndex().?);
    const len = try self.resolveInst(bin.rhs.toIndex().?);

    // A slice is a struct with two fields: ptr and len
    // We need to create this on the stack and return a pointer to it

    const slice_ty = self.typeOfIndex(inst);
    const zcu = self.pt.zcu;
    const slice_size = slice_ty.abiSize(zcu);
    const slice_align = slice_ty.abiAlignment(zcu);

    // Allocate stack space for the slice
    const stack_offset = try self.allocStackSpace(@intCast(slice_size), slice_align);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Get stack pointer into dst_reg
    // SUB Xd, X29, #offset
    try self.addInst(.{
        .tag = .sub,
        .ops = .rri,
        .data = .{ .rri = .{
            .rd = dst_reg,
            .rn = .x29, // Frame pointer
            .imm = @intCast(stack_offset),
        } },
    });

    // Store ptr field (first 8 bytes)
    try self.addInst(.{
        .tag = .str,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = .{
                .base = .{ .reg = dst_reg },
                .mod = .{ .immediate = 0 },
            },
            .rs = ptr.register,
        } },
    });

    // Store len field (second 8 bytes)
    try self.addInst(.{
        .tag = .str,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = .{
                .base = .{ .reg = dst_reg },
                .mod = .{ .immediate = 8 },
            },
            .rs = len.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
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

fn airAlloc(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ptr_ty = self.typeOfIndex(inst);
    const pointee_ty = ptr_ty.childType(self.pt.zcu);

    // Check if type has runtime bits
    if (!pointee_ty.isFnOrHasRuntimeBitsIgnoreComptime(self.pt.zcu)) {
        // Zero-sized type - return a dummy pointer (stack pointer is fine)
        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = .sp }));
        return;
    }

    const zcu = self.pt.zcu;
    const size = pointee_ty.abiSize(zcu);
    const alignment = ptr_ty.ptrAlignment(zcu);

    // TODO: Track stack allocations properly and adjust SP in prologue
    // For now, we'll use a simplified approach

    // Allocate a register to hold the stack address
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Simple approach: just use SP as the pointer
    // TODO: Properly track stack frame layout and offsets
    // TODO: Adjust SP in prologue based on total stack usage

    // MOV Xd, SP
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = .sp,
        } },
    });

    // TODO: Subtract space from SP for the allocation
    // For now, we'll pretend the space is already allocated
    _ = size;
    _ = alignment;

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

fn typeOf(self: *CodeGen, inst: Air.Inst.Ref) Type {
    return self.air.typeOf(inst, &self.pt.zcu.intern_pool);
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
