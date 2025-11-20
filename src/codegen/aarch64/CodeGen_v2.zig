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

/// Total stack space needed (calculated during codegen, applied in prologue)
max_stack_size: u32 = 0,

/// Index in MIR where stack allocation should be inserted (after FP setup)
stack_alloc_inst_index: ?Mir.Inst.Index = null,

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
    /// Result value from break instructions
    result: MCValue = .none,

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

    fn initSpill(ty: Type, zcu: *Zcu) FrameAlloc {
        const abi_size = ty.abiSize(zcu);
        const abi_align = ty.abiAlignment(zcu);
        const spill_size = if (abi_size < 8)
            std.math.ceilPowerOfTwoAssert(u64, abi_size)
        else
            std.mem.alignForward(u64, abi_size, 8);
        return init(.{
            .size = spill_size,
            .alignment = abi_align.maxStrict(
                InternPool.Alignment.fromNonzeroByteUnits(@min(spill_size, 8)),
            ),
        });
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

    std.debug.print("ARM64 CodeGen: Starting new function generation, mir_instructions.len={d}\n", .{function.mir_instructions.len});

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
        // ARM64 uses AAPCS64 for .auto and the various AAPCS variants
        .auto,
        .aarch64_aapcs,
        .aarch64_aapcs_darwin,
        .aarch64_aapcs_win,
        => {
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

    log.debug("=== ARM64 CodeGen: Starting function generation ===", .{});

    // Generate function prologue
    log.debug("ARM64 CodeGen: Generating prologue", .{});
    try self.genPrologue();
    log.debug("ARM64 CodeGen: Prologue complete, MIR instructions: {d}", .{self.mir_instructions.len});

    // Process main body
    const main_body = self.air.getMainBody();
    log.debug("ARM64 CodeGen: Processing main body with {d} instructions", .{main_body.len});

    for (main_body, 0..) |inst, i| {
        const tag = air_tags[@intFromEnum(inst)];
        log.debug("ARM64 CodeGen: Processing AIR inst {d}/{d}: {s}", .{ i + 1, main_body.len, @tagName(tag) });

        // Generate instruction
        try self.genInst(inst, tag);
    }

    // Note: Epilogue is generated by airRet/airRetLoad handlers
    // If no explicit return, add one
    const last_inst_idx = self.mir_instructions.len -| 1;
    log.debug("ARM64 CodeGen: Checking for epilogue (last_inst_idx={d})", .{last_inst_idx});
    if (last_inst_idx == 0 or self.mir_instructions.items(.tag)[last_inst_idx] != .ret) {
        log.debug("ARM64 CodeGen: Generating epilogue", .{});
        try self.genEpilogue();
    }

    log.debug("=== ARM64 CodeGen: Function generation complete, total MIR: {d} ===", .{self.mir_instructions.len});

    // Insert stack allocation in prologue now that we know max_stack_size
    if (self.max_stack_size > 0 and self.stack_alloc_inst_index != null) {
        const stack_size_aligned = std.mem.alignForward(u32, self.max_stack_size, 16);
        const insert_idx: usize = self.stack_alloc_inst_index.?;

        // Insert SUB SP, SP, #stack_size at the saved index
        try self.mir_instructions.insert(self.gpa, insert_idx, .{
            .tag = .sub,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = .sp,
                .rn = .sp,
                .imm = stack_size_aligned,
            } },
        });
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

    // Remember where to insert stack allocation
    // We'll insert "SUB SP, SP, #stack_size" here after codegen completes
    self.stack_alloc_inst_index = @intCast(self.mir_instructions.len);
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

    // Restore SP from FP if we allocated stack space
    // MOV SP, FP  (restores SP to where it was after saving FP/LR)
    if (self.max_stack_size > 0) {
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = .sp,
                .rn = .x29, // FP
            } },
        });
    }

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
    log.debug("genInst: processing instruction {d} with tag {s}", .{ @intFromEnum(inst), @tagName(tag) });
    return switch (tag) {
        // Arithmetic
        .add => self.airAdd(inst),
        .sub => self.airSub(inst),
        .add_wrap => self.airAdd(inst),  // Wrapping is default behavior
        .sub_wrap => self.airSub(inst),  // Wrapping is default behavior
        .mul => self.airMul(inst),
        .mul_wrap => self.airMulWrap(inst),
        .div_trunc, .div_exact, .div_float => self.airDiv(inst),
        .rem => self.airRem(inst),
        .mod => self.airMod(inst),
        .neg => self.airNeg(inst),
        .min => self.airMinMax(inst, true),
        .max => self.airMinMax(inst, false),
        .abs => self.airAbs(inst),
        .mul_add => self.airMulAdd(inst),

        // Overflow arithmetic
        .add_with_overflow => self.airOverflowOp(inst, .add),
        .sub_with_overflow => self.airOverflowOp(inst, .sub),
        .mul_with_overflow => self.airOverflowOp(inst, .mul),
        .shl_with_overflow => self.airOverflowOp(inst, .shl),

        // Bitwise
        .bit_and => self.airAnd(inst),
        .bit_or => self.airOr(inst),
        .xor => self.airXor(inst),
        .not => self.airNot(inst),
        .clz => self.airClz(inst),
        .ctz => self.airCtz(inst),
        .popcount => self.airPopcount(inst),
        .byte_swap => self.airByteSwap(inst),
        .bit_reverse => self.airBitReverse(inst),

        // Boolean operations
        .bool_and => self.airBoolAnd(inst),
        .bool_or => self.airBoolOr(inst),

        // Shifts
        .shl, .shl_exact => self.airShl(inst),
        .shr, .shr_exact => self.airShr(inst),

        // Load/Store
        .load => self.airLoad(inst),
        .store => self.airStore(inst, false),
        .store_safe => self.airStore(inst, true),

        // Memory operations
        .memset => self.airMemset(inst),
        .memcpy => self.airMemcpy(inst),

        // Compare
        .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte => self.airCmp(inst),

        // Select (ternary)
        .select => self.airSelect(inst),

        // Vector operations
        .splat => self.airSplat(inst),

        // Float operations
        .sqrt => self.airUnaryFloatOp(inst),

        // Branches
        .br => self.airBr(inst),
        .cond_br => self.airCondBr(inst),
        .switch_br => self.airSwitchBr(inst),
        .loop_switch_br => self.airLoopSwitchBr(inst),

        // Return
        .ret => self.airRet(inst, false),
        .ret_safe => self.airRet(inst, true),
        .ret_load => self.airRetLoad(inst),
        .ret_ptr => self.airRetPtr(inst),
        .ret_addr => self.airRetAddr(inst),

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
        .field_parent_ptr => self.airFieldParentPtr(inst),
        .ptr_elem_ptr => self.airPtrElemPtr(inst),
        .ptr_elem_val => self.airPtrElemVal(inst),
        .array_elem_val => self.airArrayElemVal(inst),
        .aggregate_init => self.airAggregateInit(inst),

        // Slice operations
        .slice_elem_val => self.airSliceElemVal(inst),
        .slice => self.airSlice(inst),
        .slice_ptr => self.airSlicePtr(inst),
        .slice_len => self.airSliceLen(inst),
        .ptr_slice_ptr_ptr => self.airPtrSlicePtrPtr(inst),
        .ptr_slice_len_ptr => self.airPtrSliceLenPtr(inst),
        .array_to_slice => self.airArrayToSlice(inst),

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
        .is_err_ptr => self.airIsErrPtr(inst, true),
        .is_non_err_ptr => self.airIsErrPtr(inst, false),
        .unwrap_errunion_payload => self.airUnwrapErrUnionPayload(inst),
        .unwrap_errunion_err => self.airUnwrapErrUnionErr(inst),
        .unwrap_errunion_payload_ptr => self.airUnwrapErrUnionPayloadPtr(inst),
        .unwrap_errunion_err_ptr => self.airUnwrapErrUnionErrPtr(inst),
        .wrap_errunion_payload => self.airWrapErrUnionPayload(inst),
        .wrap_errunion_err => self.airWrapErrUnionErr(inst),
        .@"try" => self.airTry(inst),
        .error_name => self.airErrorName(inst),

        // Union operations
        .union_init => self.airUnionInit(inst),
        .get_union_tag => self.airGetUnionTag(inst),

        // Blocks
        .block => self.airBlock(inst),
        .loop => self.airLoop(inst),
        .repeat => self.airRepeat(inst),

        // Function arguments
        .arg => self.airArg(inst),

        // Unreachable/trap
        .unreach, .breakpoint => self.airUnreachable(inst),
        .trap => self.airTrap(inst),

        // Bitcast
        .bitcast => self.airBitcast(inst),

        // Inline assembly
        .assembly => self.airAsm(inst),

        // Atomic operations
        .atomic_load => self.airAtomicLoad(inst),
        .atomic_store_unordered => self.airAtomicStore(inst, .unordered),
        .atomic_store_monotonic => self.airAtomicStore(inst, .monotonic),
        .atomic_store_release => self.airAtomicStore(inst, .release),
        .atomic_store_seq_cst => self.airAtomicStore(inst, .seq_cst),
        .atomic_rmw => self.airAtomicRmw(inst),
        .cmpxchg_weak => self.airCmpxchg(inst, true),
        .cmpxchg_strong => self.airCmpxchg(inst, false),

        // No-ops - Track with .none so they can be resolved
        .dbg_stmt => try self.inst_tracking.put(self.gpa, inst, .init(.none)),
        .dbg_inline_block => try self.inst_tracking.put(self.gpa, inst, .init(.none)),
        .dbg_var_ptr, .dbg_var_val => try self.inst_tracking.put(self.gpa, inst, .init(.none)),
        .dbg_empty_stmt => try self.inst_tracking.put(self.gpa, inst, .init(.none)),

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

fn airMulWrap(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const lhs = try self.resolveInst(bin_op.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Check if this is a float operation
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // Wrapping multiplication is the default behavior on ARM64
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

fn airStore(self: *CodeGen, inst: Air.Inst.Index, safety: bool) !void {
    if (safety) {
        // TODO if the value is undef, write 0xaa bytes to dest
    } else {
        // TODO if the value is undef, don't lower this instruction
    }

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

fn airFieldParentPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const field_parent_ptr = self.air.extraData(Air.FieldParentPtr, ty_pl.payload).data;

    const ptr_parent_ty = ty_pl.ty.toType();
    const ptr_field_ty = self.typeOf(field_parent_ptr.field_ptr);
    const field_offset = codegen.fieldOffset(ptr_parent_ty, ptr_field_ty, field_parent_ptr.field_index, self.pt.zcu);

    const field_ptr = try self.resolveInst(field_parent_ptr.field_ptr.toIndex().?);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (field_offset == 0) {
        // Field is at offset 0, parent pointer equals field pointer
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = field_ptr.register,
            } },
        });
    } else {
        // SUB dst, field_ptr, #offset
        try self.addInst(.{
            .tag = .sub,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = field_ptr.register,
                .imm = field_offset,
            } },
        });
    }

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
            const temp_reg = try self.register_manager.allocReg(inst, .gp);

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
        const temp_reg = try self.register_manager.allocReg(inst, .gp);

        // Load elem_size into temp
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = temp_reg,
                .imm = @intCast(elem_size & 0xFFFF),
            } },
        });

        const offset_reg = try self.register_manager.allocReg(inst, .gp);

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
        const addr_reg = try self.register_manager.allocReg(inst, .gp);

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
                const temp_reg = try self.register_manager.allocReg(inst, .gp);

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
            const size_reg = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = size_reg,
                    .imm = @intCast(elem_size & 0xFFFF),
                } },
            });

            const offset_reg = try self.register_manager.allocReg(inst, .gp);
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
        const addr_reg = try self.register_manager.allocReg(inst, .gp);

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
                const temp_reg = try self.register_manager.allocReg(inst, .gp);

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
            const size_reg = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = size_reg,
                    .imm = @intCast(elem_size & 0xFFFF),
                } },
            });

            const offset_reg = try self.register_manager.allocReg(inst, .gp);
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
        const tag_reg = try self.register_manager.allocReg(inst, .gp);

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
        const val_reg = try self.register_manager.allocReg(inst, .gp);

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
        const tag_reg = try self.register_manager.allocReg(inst, .gp);

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
        const payload_ty = opt_ty.optionalChild(zcu);
        const payload_abi_size: u32 = @intCast(payload_ty.abiSize(zcu));
        const payload_abi_align: u32 = @intCast(payload_ty.abiAlignment(zcu).toByteUnits().?);

        // Allocate stack space for optional (payload + tag byte)
        // Align the stack allocation
        const stack_offset = std.mem.alignForward(u32, self.max_stack_size, payload_abi_align);
        const opt_abi_size: u32 = @intCast(opt_ty.abiSize(zcu));
        self.max_stack_size = stack_offset + opt_abi_size;

        // Get stack pointer for this allocation
        const stack_reg = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(stack_reg);

        // Calculate address: SP + offset
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = stack_reg,
                .rn = .sp,
                .imm = @intCast(stack_offset),
            } },
        });

        // Store payload at offset 0
        const payload_reg = switch (payload) {
            .register => |reg| reg,
            .immediate => |imm| blk: {
                const temp = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(temp);

                try self.addInst(.{
                    .tag = .movz,
                    .ops = .ri,
                    .data = .{ .ri = .{
                        .rd = temp,
                        .imm = @intCast(imm & 0xFFFF),
                    } },
                });
                break :blk temp;
            },
            else => return self.fail("TODO: wrap_optional with payload type {}", .{payload}),
        };

        // Store payload based on size
        if (payload_abi_size == 8) {
            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(stack_reg, 0),
                    .rs = payload_reg,
                } },
            });
        } else if (payload_abi_size == 4) {
            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(stack_reg, 0),
                    .rs = payload_reg,
                } },
            });
        } else if (payload_abi_size == 2) {
            try self.addInst(.{
                .tag = .strh,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(stack_reg, 0),
                    .rs = payload_reg,
                } },
            });
        } else if (payload_abi_size == 1) {
            try self.addInst(.{
                .tag = .strb,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(stack_reg, 0),
                    .rs = payload_reg,
                } },
            });
        } else {
            return self.fail("TODO: wrap_optional with payload size {}", .{payload_abi_size});
        }

        // Store tag = 1 at offset payload_abi_size
        const tag_reg = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(tag_reg);

        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = tag_reg,
                .imm = 1,
            } },
        });

        try self.addInst(.{
            .tag = .strb,
            .ops = .mr,
            .data = .{ .mr = .{
                .mem = Memory.simple(stack_reg, @intCast(payload_abi_size)),
                .rs = tag_reg,
            } },
        });

        // Return stack pointer as the result
        const dst_reg = try self.register_manager.allocReg(inst, .gp);
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = stack_reg,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
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
    const err_reg = try self.register_manager.allocReg(inst, .gp);

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
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const err_union_ty = ty_op.ty.toType();
    const payload = try self.resolveInst(ty_op.operand.toIndex().?);
    const zcu = self.pt.zcu;

    const payload_ty = err_union_ty.errorUnionPayload(zcu);
    const payload_abi_size: u32 = @intCast(payload_ty.abiSize(zcu));
    const payload_abi_align: u32 = @intCast(payload_ty.abiAlignment(zcu).toByteUnits().?);

    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    // Allocate stack space for error union (payload + error u16)
    const stack_offset = std.mem.alignForward(u32, self.max_stack_size, payload_abi_align);
    const err_union_abi_size: u32 = @intCast(err_union_ty.abiSize(zcu));
    self.max_stack_size = stack_offset + err_union_abi_size;

    // Get stack pointer for this allocation
    const stack_reg = try self.register_manager.allocReg(inst, .gp);
    defer self.register_manager.freeReg(stack_reg);

    // Calculate address: SP + offset
    try self.addInst(.{
        .tag = .add,
        .ops = .rri,
        .data = .{ .rri = .{
            .rd = stack_reg,
            .rn = .sp,
            .imm = @intCast(stack_offset),
        } },
    });

    // Store payload based on MCValue type
    switch (payload) {
        .none => {
            // Void-typed payload, no storage needed - just set error = 0 and return
            // Skip to error storage section
        },
        .register, .immediate, .load_frame => {
            const payload_reg = switch (payload) {
                .register => |reg| reg,
                .immediate => |imm| blk: {
                    const temp = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(temp);

                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{
                            .rd = temp,
                            .imm = @intCast(imm & 0xFFFF),
                        } },
                    });
                    break :blk temp;
                },
                .load_frame => |frame_addr| blk: {
                    const temp = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(temp);

                    // Load from frame into temp register
                    try self.addInst(.{
                        .tag = .ldr,
                        .ops = .rm,
                        .data = .{ .rm = .{
                            .rd = temp,
                            .mem = Memory.soff(frame_addr.index.toReg().?, frame_addr.off),
                        } },
                    });
                    break :blk temp;
                },
                else => unreachable,
            };

            // Store payload based on size
            if (payload_abi_size == 16) {
                // 16-byte payload: store as two 8-byte values
                // First 8 bytes
                try self.addInst(.{
                    .tag = .str,
                    .ops = .mr,
                    .data = .{ .mr = .{
                        .mem = Memory.simple(stack_reg, 0),
                        .rs = payload_reg,
                    } },
                });
                // Second 8 bytes - need to load high part for load_frame case
                if (payload == .load_frame) {
                    const temp2 = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(temp2);

                    const frame_addr = payload.load_frame;
                    try self.addInst(.{
                        .tag = .ldr,
                        .ops = .rm,
                        .data = .{ .rm = .{
                            .rd = temp2,
                            .mem = Memory.soff(frame_addr.index.toReg().?, frame_addr.off + 8),
                        } },
                    });
                    try self.addInst(.{
                        .tag = .str,
                        .ops = .mr,
                        .data = .{ .mr = .{
                            .mem = Memory.simple(stack_reg, 8),
                            .rs = temp2,
                        } },
                    });
                }
                // For register/immediate: just store low part, high part is zeros
            } else if (payload_abi_size == 8) {
                try self.addInst(.{
                    .tag = .str,
                    .ops = .mr,
                    .data = .{ .mr = .{
                        .mem = Memory.simple(stack_reg, 0),
                        .rs = payload_reg,
                    } },
                });
            } else if (payload_abi_size == 4) {
                try self.addInst(.{
                    .tag = .str,
                    .ops = .mr,
                    .data = .{ .mr = .{
                        .mem = Memory.simple(stack_reg, 0),
                        .rs = payload_reg,
                    } },
                });
            } else if (payload_abi_size == 2) {
                try self.addInst(.{
                    .tag = .strh,
                    .ops = .mr,
                    .data = .{ .mr = .{
                        .mem = Memory.simple(stack_reg, 0),
                        .rs = payload_reg,
                    } },
                });
            } else if (payload_abi_size == 1) {
                try self.addInst(.{
                    .tag = .strb,
                    .ops = .mr,
                    .data = .{ .mr = .{
                        .mem = Memory.simple(stack_reg, 0),
                        .rs = payload_reg,
                    } },
                });
            } else {
                return self.fail("TODO: wrap_errunion_payload with payload size {}", .{payload_abi_size});
            }
        },
        else => return self.fail("TODO: wrap_errunion_payload with payload type {}", .{payload}),
    }

    // Store error = 0 at error offset (error is u16)
    const err_reg = try self.register_manager.allocReg(inst, .gp);
    defer self.register_manager.freeReg(err_reg);

    try self.addInst(.{
        .tag = .movz,
        .ops = .ri,
        .data = .{ .ri = .{
            .rd = err_reg,
            .imm = 0,
        } },
    });

    try self.addInst(.{
        .tag = .strh,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = Memory.simple(stack_reg, err_off),
            .rs = err_reg,
        } },
    });

    // Return stack pointer as the result
    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = stack_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airWrapErrUnionErr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const err_union_ty = ty_op.ty.toType();
    const err_operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const zcu = self.pt.zcu;

    const payload_ty = err_union_ty.errorUnionPayload(zcu);

    // If payload has no runtime bits, the error union is just the error value
    if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
        const dst_reg = try self.register_manager.allocReg(inst, .gp);

        // Copy the error value to the destination register
        switch (err_operand) {
            .register => |reg| {
                try self.addInst(.{
                    .tag = .mov,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rd = dst_reg,
                        .rn = reg,
                    } },
                });
            },
            .immediate => |imm| {
                try self.addInst(.{
                    .tag = .movz,
                    .ops = .ri,
                    .data = .{ .ri = .{
                        .rd = dst_reg,
                        .imm = @intCast(imm & 0xFFFF),
                    } },
                });
            },
            else => return self.fail("TODO: wrap_errunion_err with error type {}", .{err_operand}),
        }

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
        return;
    }

    // Payload has runtime bits, need to allocate stack space
    const payload_abi_align: u32 = @intCast(payload_ty.abiAlignment(zcu).toByteUnits().?);
    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    // Allocate stack space for error union
    const stack_offset = std.mem.alignForward(u32, self.max_stack_size, payload_abi_align);
    const err_union_abi_size: u32 = @intCast(err_union_ty.abiSize(zcu));
    self.max_stack_size = stack_offset + err_union_abi_size;

    // Get stack pointer for this allocation
    const stack_reg = try self.register_manager.allocReg(inst, .gp);
    defer self.register_manager.freeReg(stack_reg);

    // Calculate address: SP + offset
    try self.addInst(.{
        .tag = .add,
        .ops = .rri,
        .data = .{ .rri = .{
            .rd = stack_reg,
            .rn = .sp,
            .imm = @intCast(stack_offset),
        } },
    });

    // Store error value at error offset (error is u16)
    const err_reg = switch (err_operand) {
        .register => |reg| reg,
        .immediate => |imm| blk: {
            const temp = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(temp);

            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = temp,
                    .imm = @intCast(imm & 0xFFFF),
                } },
            });
            break :blk temp;
        },
        else => return self.fail("TODO: wrap_errunion_err with error type {}", .{err_operand}),
    };

    try self.addInst(.{
        .tag = .strh,
        .ops = .mr,
        .data = .{ .mr = .{
            .mem = Memory.simple(stack_reg, err_off),
            .rs = err_reg,
        } },
    });

    // Payload is left undefined (we don't need to initialize it)
    // Return stack pointer as the result
    const dst_reg = try self.register_manager.allocReg(inst, .gp);
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = stack_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airIsErrPtr(self: *CodeGen, inst: Air.Inst.Index, comptime is_err: bool) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const ptr_ty = self.typeOf(ty_op.operand);
    const err_union_ty = ptr_ty.childType(self.pt.zcu);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Load error value from memory through pointer
    const err_reg = try self.register_manager.allocReg(inst, .gp);

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

fn airUnwrapErrUnionPayloadPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const ptr_ty = self.typeOf(ty_op.operand);
    const err_union_ty = ptr_ty.childType(self.pt.zcu);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    const payload_off: i32 = @intCast(codegen.errUnionPayloadOffset(payload_ty, zcu));

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Calculate pointer to payload
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (payload_off == 0) {
        // Payload is at offset 0, just return the pointer
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else {
        // Add offset to pointer
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = operand.register,
                .imm = @intCast(payload_off),
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airUnwrapErrUnionErrPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const ptr_ty = self.typeOf(ty_op.operand);
    const err_union_ty = ptr_ty.childType(self.pt.zcu);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));

    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Calculate pointer to error
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    if (err_off == 0) {
        // Error is at offset 0, just return the pointer
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else {
        // Add offset to pointer
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = operand.register,
                .imm = @intCast(err_off),
            } },
        });
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airTry(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = self.air.extraData(Air.Try, pl_op.payload);
    const body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.body_len]);
    const err_union_ty = self.typeOf(pl_op.operand);
    const payload_ty = err_union_ty.errorUnionPayload(self.pt.zcu);
    const zcu = self.pt.zcu;

    // Get error union operand
    const operand = try self.resolveInst(pl_op.operand.toIndex().?);

    // Get error offset and load error value
    const err_off: i32 = @intCast(codegen.errUnionErrorOffset(payload_ty, zcu));
    const err_reg = try self.register_manager.allocReg(inst, .gp);

    // Load error value (u16)
    try self.addInst(.{
        .tag = .ldrh,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = err_reg,
            .mem = Memory.simple(operand.register, err_off),
        } },
    });

    // Compare error with 0 - if zero, no error, fall through to unwrap payload
    try self.addInst(.{
        .tag = .cmp,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = err_reg,
            .rn = .xzr,
        } },
    });

    // Branch to error handler (body) if error is not zero (ne = not equal)
    const error_branch: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .cbnz,
        .ops = .r_rel,
        .data = .{ .r_rel = .{
            .rn = err_reg, // Branch if error != 0
            .target = 0, // Placeholder
        } },
    });

    self.register_manager.freeReg(err_reg);

    // No error case: unwrap payload
    const payload_off: i32 = @intCast(codegen.errUnionPayloadOffset(payload_ty, zcu));
    const is_float = payload_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const payload_reg = try self.register_manager.allocReg(inst, reg_class);

    // Load payload from union
    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = payload_reg,
            .mem = Memory.simple(operand.register, payload_off),
        } },
    });

    // Jump past error handling body
    const skip_error_body: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Placeholder
    });

    // Patch error branch to point here
    const error_body_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    self.mir_instructions.items(.data)[error_branch].r_rel.target = error_body_start;

    // Execute error handling body (typically returns the error)
    try self.genBody(body);

    // Patch skip branch to point after error body
    const after_error_body: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    self.mir_instructions.items(.data)[skip_error_body].rel.target = after_error_body;

    // Track the payload result
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = payload_reg }));
}

fn airErrorName(self: *CodeGen, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try self.resolveInst(un_op.toIndex().?);

    // Each entry in the error name table is a slice (ptr + len).
    // The operand represents the error value (u16), which is the index into the table.
    // We need to:
    // 1. Load the base address of the error name table
    // 2. Calculate: base_addr + (error_value * sizeof(slice))
    // 3. Load the slice (ptr + len) from that location
    //
    // On ARM64, a slice is 16 bytes (8-byte pointer + 8-byte length)

    const zcu = self.pt.zcu;
    const slice_ty = Type.slice_const_u8_sentinel_0;
    const slice_abi_size: u32 = @intCast(slice_ty.abiSize(zcu));

    // Get error value into a register and extend to 64-bit
    // (error values are u16, but we need 64-bit for pointer arithmetic)
    const error_val_reg = switch (operand) {
        .register => |reg| reg,
        .immediate => |imm| blk: {
            const temp = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = temp,
                    .imm = @intCast(imm & 0xFFFF),
                } },
            });
            break :blk temp;
        },
        else => return self.fail("TODO: airErrorName with operand type {}", .{operand}),
    };

    // TODO: Load the error name table base address
    // This requires symbol resolution infrastructure that may not be fully
    // implemented yet in the ARM64 backend. The table is a global symbol
    // that needs to be loaded via ADRP + ADD or GOT access.
    //
    // For now, we'll fail with an informative message.
    _ = error_val_reg;
    _ = slice_abi_size;

    return self.fail("TODO: ARM64 CodeGen error_name - requires error name table symbol resolution", .{});

    // The complete implementation would look like:
    //
    // 1. Load error name table base address (requires symbol resolution):
    //    const table_reg = try self.register_manager.allocReg(null, .gp);
    //    // ADRP table_reg, error_name_table
    //    // ADD table_reg, table_reg, :lo12:error_name_table
    //
    // 2. Calculate offset: error_value * slice_size
    //    const offset_reg = try self.register_manager.allocReg(null, .gp);
    //    try self.addInst(.{
    //        .tag = .mov,
    //        .ops = .ri,
    //        .data = .{ .ri = .{
    //            .rd = offset_reg,
    //            .imm = slice_abi_size,
    //        } },
    //    });
    //    const scaled_offset_reg = try self.register_manager.allocReg(null, .gp);
    //    try self.addInst(.{
    //        .tag = .mul,
    //        .ops = .rrr,
    //        .data = .{ .rrr = .{
    //            .rd = scaled_offset_reg,
    //            .rn = error_val_reg,
    //            .rm = offset_reg,
    //        } },
    //    });
    //
    // 3. Add offset to table base
    //    const entry_addr_reg = try self.register_manager.allocReg(null, .gp);
    //    try self.addInst(.{
    //        .tag = .add,
    //        .ops = .rrr,
    //        .data = .{ .rrr = .{
    //            .rd = entry_addr_reg,
    //            .rn = table_reg,
    //            .rm = scaled_offset_reg,
    //        } },
    //    });
    //
    // 4. Load the slice (ptr + len) using LDP (load pair)
    //    const ptr_reg = try self.register_manager.allocReg(inst, .gp);
    //    const len_reg = try self.register_manager.allocReg(inst, .gp);
    //    try self.addInst(.{
    //        .tag = .ldp,
    //        .ops = .mrr,
    //        .data = .{ .mrr = .{
    //            .mem = Memory.simple(entry_addr_reg, 0),
    //            .r1 = ptr_reg,
    //            .r2 = len_reg,
    //        } },
    //    });
    //
    // 5. Return slice as register pair
    //    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register_pair = .{ ptr_reg, len_reg } }));
}

fn airPtrSlicePtrPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Get pointer to the ptr field (first field at offset 0)
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Slice ptr is at offset 0, so just return the pointer
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

fn airPtrSliceLenPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Get pointer to the len field (second field at offset 8)
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Add 8 to get to len field
    try self.addInst(.{
        .tag = .add,
        .ops = .rri,
        .data = .{ .rri = .{
            .rd = dst_reg,
            .rn = operand.register,
            .imm = 8,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airRetPtr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Load value from pointer and return it
    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const val_reg = try self.register_manager.allocReg(inst, reg_class);

    // Load the value
    try self.addInst(.{
        .tag = .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = val_reg,
            .mem = Memory.simple(operand.register, 0),
        } },
    });

    // Move to return register (X0 or V0)
    const ret_reg: Register = if (is_float) .v0 else .x0;
    if (val_reg.id() != ret_reg.id()) {
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = ret_reg,
                .rn = val_reg,
            } },
        });
    }

    // Return
    try self.addInst(.{
        .tag = .ret,
        .ops = .none,
        .data = .{ .none = {} },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = ret_reg }));
}

fn airTrap(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;
    // Generate a trap/abort instruction - use UDF (undefined instruction)
    // which will cause an exception
    try self.addInst(.{
        .tag = .brk,
        .ops = .none,
        .data = .{ .none = {} },
    });
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

    // Handle block result value
    if (br.operand != .none) {
        if (br.operand.toIndex()) |operand_inst| {
            block_data.result = try self.resolveInst(operand_inst);
        } else {
            // It's a constant or type, not an instruction
            // For now, we'll leave it as .none, but this may need more handling
            _ = br.operand;
        }
    }

    // Emit unconditional branch
    const branch_inst: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Placeholder, will be patched
    });

    // Record this branch for later patching
    try block_data.relocs.append(self.gpa, branch_inst);
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

fn airRet(self: *CodeGen, inst: Air.Inst.Index, safety: bool) !void {
    _ = inst;
    if (safety) {
        // TODO: runtime safety check for return value
    }

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

fn airRetAddr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Return address is stored in X30 (LR register)
    // Copy it to destination register
    try self.addInst(.{
        .tag = .mov,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = .x30, // Link register
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airLoop(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const loop = self.air.extraData(Air.Block, ty_pl.payload);
    const body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[loop.end..][0..loop.data.body_len]);

    // Mark the loop start position for backward jumps
    const loop_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);

    std.debug.print("ARM64 CodeGen: airLoop inst={d}, loop_start={d}\n", .{ @intFromEnum(inst), loop_start });

    // Process loop body
    try self.genBody(body);

    // The repeat instruction in the body will jump back to loop_start
    // Store loop_start for use by repeat instructions
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .immediate = loop_start }));
}

fn airRepeat(self: *CodeGen, inst: Air.Inst.Index) !void {
    const repeat_data = self.air.instructions.items(.data)[@intFromEnum(inst)].repeat;

    std.debug.print("ARM64 CodeGen: airRepeat inst={d}, loop_inst={d}, mir_instructions.len={d}\n", .{ @intFromEnum(inst), @intFromEnum(repeat_data.loop_inst), self.mir_instructions.len });

    // Get the loop start position from the loop instruction
    const loop_mcv = try self.resolveInst(repeat_data.loop_inst);
    const loop_start: Mir.Inst.Index = switch (loop_mcv) {
        .immediate => |imm| @intCast(imm),
        else => return self.fail("Loop start not an immediate: {s}", .{@tagName(loop_mcv)}),
    };

    std.debug.print("ARM64 CodeGen: airRepeat resolved loop_start={d}\n", .{loop_start});

    // Emit unconditional branch back to loop start
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = loop_start } },
    });
}

fn airSwitchBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const switch_br = self.air.unwrapSwitch(inst);
    const condition = try self.resolveInst(switch_br.operand.toIndex().?);

    const cond_reg = switch (condition) {
        .register => |reg| reg,
        .immediate => |imm| blk: {
            const reg = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{ .rd = reg, .imm = imm } },
            });
            break :blk reg;
        },
        else => return self.fail("TODO: switch_br condition type {s}", .{@tagName(condition)}),
    };

    // Collect branch fixup locations
    var case_branches: std.ArrayListUnmanaged(Mir.Inst.Index) = .empty;
    defer case_branches.deinit(self.gpa);

    // Process each case
    var it = switch_br.iterateCases();
    while (it.next()) |case| {
        // For each item in the case, compare and branch if equal
        for (case.items) |item| {
            const item_mcv = try self.resolveInst(item.toIndex().?);

            // Allocate temp register for comparison
            const cmp_reg = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(cmp_reg);

            // Compare condition with item
            switch (item_mcv) {
                .immediate => |imm| {
                    // CMP cond_reg, #imm
                    try self.addInst(.{
                        .tag = .cmp,
                        .ops = .rri,
                        .data = .{ .rri = .{
                            .rd = .xzr,
                            .rn = cond_reg,
                            .imm = imm,
                        } },
                    });
                },
                .register => |item_reg| {
                    // CMP cond_reg, item_reg
                    try self.addInst(.{
                        .tag = .cmp,
                        .ops = .rrr,
                        .data = .{ .rrr = .{
                            .rd = .xzr,
                            .rn = cond_reg,
                            .rm = item_reg,
                        } },
                    });
                },
                else => return self.fail("TODO: switch_br item type {s}", .{@tagName(item_mcv)}),
            }

            // Branch to case body if equal
            const branch_idx: Mir.Inst.Index = @intCast(self.mir_instructions.len);
            try self.addInst(.{
                .tag = .b_cond,
                .ops = .rc,
                .data = .{ .rc = .{
                    .rn = .xzr,
                    .cond = .eq,
                    .target = 0, // Placeholder
                } },
            });
            try case_branches.append(self.gpa, branch_idx);
        }

        // Skip case body - will be filled in when we process case bodies
    }

    // Generate else/default body
    if (switch_br.else_body_len > 0) {
        var else_it = switch_br.iterateCases();
        while (else_it.next()) |_| {}
        const else_body = else_it.elseBody();
        try self.genBody(else_body);
    }

    // Jump past all case bodies
    const end_branch_idx: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{ .target = 0 } }, // Will be patched
    });

    // Now generate case bodies and patch branches
    var case_idx: usize = 0;
    var cases_it = switch_br.iterateCases();
    while (cases_it.next()) |case| {
        const case_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);

        // Patch all branches for this case's items
        for (0..case.items.len) |_| {
            if (case_idx < case_branches.items.len) {
                self.mir_instructions.items(.data)[case_branches.items[case_idx]].rc.target = case_start;
                case_idx += 1;
            }
        }

        // Generate case body
        try self.genBody(case.body);

        // Jump to end
        try self.addInst(.{
            .tag = .b,
            .ops = .rel,
            .data = .{ .rel = .{ .target = end_branch_idx } },
        });
    }

    // Patch end branch to point here
    const after_switch: Mir.Inst.Index = @intCast(self.mir_instructions.len);
    self.mir_instructions.items(.data)[end_branch_idx].rel.target = after_switch;
}

fn airLoopSwitchBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO: ARM64 CodeGen loop_switch_br", .{});
}

fn airAsm(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = self.air.extraData(Air.Asm, ty_pl.payload);
    var extra_index = extra.end;
    const outputs: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra_index..][0..extra.data.flags.outputs_len]);
    extra_index += outputs.len;
    const inputs: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra_index..][0..extra.data.inputs_len]);
    extra_index += inputs.len;

    const zcu = self.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = self.gpa;

    var as: codegen.aarch64.Assemble = .{
        .source = undefined,
        .operands = .empty,
    };
    defer as.operands.deinit(gpa);

    // Process outputs
    var result_reg: ?Register = null;
    for (outputs) |output| {
        const extra_bytes = std.mem.sliceAsBytes(self.air.extra.items[extra_index..]);
        const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra.items[extra_index..]), 0);
        const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
        extra_index += (constraint.len + name.len + (2 + 3)) / 4;

        switch (output) {
            else => return self.fail("invalid constraint: '{s}'", .{constraint}),
            .none => if (std.mem.startsWith(u8, constraint, "={") and std.mem.endsWith(u8, constraint, "}")) {
                const reg_name = constraint["={".len .. constraint.len - "}".len];
                const output_enc_reg = parseRegName(reg_name) orelse
                    return self.fail("invalid constraint: '{s}'", .{constraint});

                if (!std.mem.eql(u8, name, "_")) {
                    const operand_gop = try as.operands.getOrPut(gpa, name);
                    if (operand_gop.found_existing) return self.fail("duplicate output name: '{s}'", .{name});
                    operand_gop.value_ptr.* = .{ .register = output_enc_reg };
                }
                // Convert encoding.Register.Alias to bits.Register for result tracking
                if (result_reg == null) {
                    result_reg = @enumFromInt(@intFromEnum(output_enc_reg.alias));
                }
            } else if (std.mem.eql(u8, constraint, "=r") or std.mem.eql(u8, constraint, "=rm") or std.mem.eql(u8, constraint, "=m")) {
                // For '=r', '=rm', and '=m' constraints, we use a register
                // Note: '=m' and '=rm' should technically support memory operands, but for now
                // we treat them as register constraints which is sufficient for most use cases
                const output_reg = try self.register_manager.allocReg(inst, .gp);

                if (!std.mem.eql(u8, name, "_")) {
                    const operand_gop = try as.operands.getOrPut(gpa, name);
                    if (operand_gop.found_existing) return self.fail("duplicate output name: '{s}'", .{name});
                    // Convert bits.Register to encoding.Register for Assemble
                    const enc_reg = switch (output_reg) {
                        .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9,
                        .x10, .x11, .x12, .x13, .x14, .x15, .x16, .x17, .x18, .x19,
                        .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28, .x29, .x30 => blk: {
                            const alias: codegen.aarch64.encoding.Register.Alias = @enumFromInt(@intFromEnum(output_reg));
                            break :blk alias.x();
                        },
                        .w0, .w1, .w2, .w3, .w4, .w5, .w6, .w7, .w8, .w9,
                        .w10, .w11, .w12, .w13, .w14, .w15, .w16, .w17, .w18, .w19,
                        .w20, .w21, .w22, .w23, .w24, .w25, .w26, .w27, .w28, .w29, .w30 => blk: {
                            const alias: codegen.aarch64.encoding.Register.Alias = @enumFromInt(@intFromEnum(output_reg) - @intFromEnum(Register.w0) + @intFromEnum(Register.x0));
                            break :blk alias.w();
                        },
                        else => return self.fail("unsupported register type for inline assembly: {s}", .{@tagName(output_reg)}),
                    };
                    operand_gop.value_ptr.* = .{ .register = enc_reg };
                }
                if (result_reg == null) result_reg = output_reg;
            } else return self.fail("invalid constraint: '{s}'", .{constraint}),
        }
    }

    // Process inputs
    for (inputs) |input| {
        const extra_bytes = std.mem.sliceAsBytes(self.air.extra.items[extra_index..]);
        const constraint = std.mem.sliceTo(extra_bytes, 0);
        const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
        extra_index += (constraint.len + name.len + (2 + 3)) / 4;

        const input_mcv = try self.resolveInst(input.toIndex().?);

        if (std.mem.startsWith(u8, constraint, "{") and std.mem.endsWith(u8, constraint, "}")) {
            const reg_name = constraint["{".len .. constraint.len - "}".len];
            const input_enc_reg = parseRegName(reg_name) orelse
                return self.fail("invalid constraint: '{s}'", .{constraint});

            // Convert encoding.Register.Alias to bits.Register for Mir instructions
            const input_bits_reg: Register = @enumFromInt(@intFromEnum(input_enc_reg.alias));

            // Move input to specified register
            switch (input_mcv) {
                .register => |reg| if (reg.id() != input_bits_reg.id()) {
                    try self.addInst(.{
                        .tag = .mov,
                        .ops = .rr,
                        .data = .{ .rr = .{ .rd = input_bits_reg, .rn = reg } },
                    });
                },
                .immediate => |imm| {
                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{ .rd = input_bits_reg, .imm = @intCast(imm & 0xFFFF) } },
                    });
                },
                else => return self.fail("TODO: input MCValue type {s}", .{@tagName(input_mcv)}),
            }

            if (!std.mem.eql(u8, name, "_")) {
                const operand_gop = try as.operands.getOrPut(gpa, name);
                if (operand_gop.found_existing) return self.fail("duplicate input name: '{s}'", .{name});
                operand_gop.value_ptr.* = .{ .register = input_enc_reg };
            }
        } else if (std.mem.eql(u8, constraint, "r") or std.mem.eql(u8, constraint, "rm") or std.mem.eql(u8, constraint, "m")) {
            // For 'r', 'rm', and 'm' constraints, we use a register
            // Note: 'm' and 'rm' should technically support memory operands, but for now
            // we treat them as register constraints which is sufficient for most use cases
            const input_bits_reg = switch (input_mcv) {
                .register => |reg| reg,
                .immediate => |imm| blk: {
                    const reg = try self.register_manager.allocReg(inst, .gp);
                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{ .rd = reg, .imm = @intCast(imm & 0xFFFF) } },
                    });
                    break :blk reg;
                },
                else => return self.fail("TODO: input MCValue type {s}", .{@tagName(input_mcv)}),
            };

            if (!std.mem.eql(u8, name, "_")) {
                const operand_gop = try as.operands.getOrPut(gpa, name);
                if (operand_gop.found_existing) return self.fail("duplicate input name: '{s}'", .{name});
                // Convert bits.Register to encoding.Register for Assemble
                const input_enc_reg = switch (input_bits_reg) {
                    .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9,
                    .x10, .x11, .x12, .x13, .x14, .x15, .x16, .x17, .x18, .x19,
                    .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28, .x29, .x30 => blk: {
                        const alias: codegen.aarch64.encoding.Register.Alias = @enumFromInt(@intFromEnum(input_bits_reg));
                        break :blk alias.x();
                    },
                    .w0, .w1, .w2, .w3, .w4, .w5, .w6, .w7, .w8, .w9,
                    .w10, .w11, .w12, .w13, .w14, .w15, .w16, .w17, .w18, .w19,
                    .w20, .w21, .w22, .w23, .w24, .w25, .w26, .w27, .w28, .w29, .w30 => blk: {
                        const alias: codegen.aarch64.encoding.Register.Alias = @enumFromInt(@intFromEnum(input_bits_reg) - @intFromEnum(Register.w0) + @intFromEnum(Register.x0));
                        break :blk alias.w();
                    },
                    else => return self.fail("unsupported register type for inline assembly: {s}", .{@tagName(input_bits_reg)}),
                };
                operand_gop.value_ptr.* = .{ .register = input_enc_reg };
            }
        } else return self.fail("invalid constraint: '{s}'", .{constraint});
    }

    // Process clobbers
    const aggregate = ip.indexToKey(extra.data.clobbers).aggregate;
    const struct_type: Type = .fromInterned(aggregate.ty);
    for (0..struct_type.structFieldCount(zcu)) |field_index| {
        switch (switch (aggregate.storage) {
            .bytes => unreachable,
            .elems => |elems| elems[field_index],
            .repeated_elem => |repeated_elem| repeated_elem,
        }) {
            else => unreachable,
            .bool_false => continue,
            .bool_true => {},
        }
        const clobber_name = struct_type.structFieldName(field_index, zcu).toSlice(ip).?;
        if (std.mem.eql(u8, clobber_name, "memory")) continue;
        if (std.mem.eql(u8, clobber_name, "nzcv")) continue;
        if (std.mem.eql(u8, clobber_name, "cc")) continue;
        // For now, we don't explicitly handle other clobbers
    }

    // Assemble the inline assembly
    as.source = std.mem.sliceAsBytes(self.air.extra.items[extra_index..])[0..extra.data.source_len :0];

    // Parse and emit each instruction
    while (as.nextInstruction() catch |err| switch (err) {
        error.InvalidSyntax => {
            const remaining_source = std.mem.span(as.source);
            return self.fail("unable to assemble: '{s}'", .{std.mem.trim(
                u8,
                as.source[0 .. std.mem.indexOfScalar(u8, remaining_source, '\n') orelse remaining_source.len],
                &std.ascii.whitespace,
            )});
        },
    }) |instruction| {
        // Convert encoding.Instruction to raw u32 and emit as data
        const inst_bits: u32 = @bitCast(instruction);

        // Emit as raw instruction
        try self.addInst(.{
            .tag = .raw,
            .ops = .none,
            .data = .{ .raw = inst_bits },
        });
    }

    // Track result if there is one
    if (result_reg) |reg| {
        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = reg }));
    } else {
        try self.inst_tracking.put(self.gpa, inst, .init(.none));
    }
}

fn airCall(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = self.air.extraData(Air.Call, pl_op.payload);
    const args: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.args_len]);

    const callee = pl_op.operand;

    // ARM64 calling convention (AAPCS64):
    // - First 8 integer/pointer args in X0-X7
    // - First 8 FP/SIMD args in V0-V7
    // - Additional args on stack (8-byte aligned, 16-byte stack alignment)

    // Calculate stack space needed for overflow arguments
    const stack_arg_count = if (args.len > 8) args.len - 8 else 0;
    const stack_arg_bytes = stack_arg_count * 8; // Each arg is 8 bytes
    // Round up to 16-byte alignment
    const stack_space = std.mem.alignForward(u32, @intCast(stack_arg_bytes), 16);

    // Adjust SP for stack arguments if needed
    if (stack_space > 0) {
        try self.addInst(.{
            .tag = .sub,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = .sp,
                .rn = .sp,
                .imm = stack_space,
            } },
        });
    }

    // Marshal arguments to registers and stack
    for (args, 0..) |arg, i| {
        const arg_mcv = try self.resolveInst(arg.toIndex().?);
        const arg_ty = self.typeOf(arg);
        const is_float = arg_ty.isRuntimeFloat();

        if (i < 8) {
            // Register arguments
            const arg_reg = if (is_float)
                Register.v0.offset(@intCast(i))
            else
                Register.x0.offset(@intCast(i));

            // Move argument to the appropriate register
            switch (arg_mcv) {
                .none => {
                    // Void-typed argument, no runtime representation needed
                    // Skip marshaling for this argument
                },
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
                    if (imm > 0xFFFF) {
                        try self.addInst(.{
                            .tag = .movk,
                            .ops = .ri,
                            .data = .{ .ri = .{
                                .rd = arg_reg,
                                .imm = @intCast((imm >> 16) & 0xFFFF),
                            } },
                        });
                    }
                },
                .register_pair => |regs| {
                    // For register_pair, we need to check if this is a multi-register argument
                    // or if we just need to extract one register from the pair
                    // For now, assume we need the first register (common for slices/pairs)
                    const src_reg = regs[0];
                    if (src_reg.id() != arg_reg.id()) {
                        try self.addInst(.{
                            .tag = .mov,
                            .ops = .rr,
                            .data = .{ .rr = .{
                                .rd = arg_reg,
                                .rn = src_reg,
                            } },
                        });
                    }
                },
                .load_frame => |frame_addr| {
                    // Load from frame into argument register
                    try self.addInst(.{
                        .tag = .ldr,
                        .ops = .rm,
                        .data = .{ .rm = .{
                            .rd = arg_reg,
                            .mem = Memory.soff(frame_addr.index.toReg().?, frame_addr.off),
                        } },
                    });
                },
                else => return self.fail("TODO: ARM64 airCall with arg type {}", .{arg_mcv}),
            }
        } else {
            // Stack arguments (args 8+)
            const stack_offset = @as(i32, @intCast((i - 8) * 8));

            switch (arg_mcv) {
                .none => {
                    // Void-typed argument, no runtime representation needed
                    // Skip marshaling for this argument
                },
                .register => |reg| {
                    // STR Xt, [SP, #offset]
                    try self.addInst(.{
                        .tag = .str,
                        .ops = .mr,
                        .data = .{ .mr = .{
                            .mem = Memory.simple(.sp, stack_offset),
                            .rs = reg,
                        } },
                    });
                },
                .immediate => |imm| {
                    // Need temp register to hold immediate
                    const temp = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(temp);

                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{
                            .rd = temp,
                            .imm = @intCast(imm & 0xFFFF),
                        } },
                    });

                    try self.addInst(.{
                        .tag = .str,
                        .ops = .mr,
                        .data = .{ .mr = .{
                            .mem = Memory.simple(.sp, stack_offset),
                            .rs = temp,
                        } },
                    });
                },
                .register_pair => |regs| {
                    // For register_pair on stack, store the first register
                    // (This handles cases like slices where we pass the pointer)
                    try self.addInst(.{
                        .tag = .str,
                        .ops = .mr,
                        .data = .{ .mr = .{
                            .mem = Memory.simple(.sp, stack_offset),
                            .rs = regs[0],
                        } },
                    });
                },
                .load_frame => |frame_addr| {
                    // Load from frame into temp register, then store to stack
                    const temp = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(temp);

                    try self.addInst(.{
                        .tag = .ldr,
                        .ops = .rm,
                        .data = .{ .rm = .{
                            .rd = temp,
                            .mem = Memory.soff(frame_addr.index.toReg().?, frame_addr.off),
                        } },
                    });

                    try self.addInst(.{
                        .tag = .str,
                        .ops = .mr,
                        .data = .{ .mr = .{
                            .mem = Memory.simple(.sp, stack_offset),
                            .rs = temp,
                        } },
                    });
                },
                else => return self.fail("TODO: ARM64 airCall stack arg type {}", .{arg_mcv}),
            }
        }
    }

    // Generate call instruction
    if (callee.toIndex()) |callee_index| {
        // Callee is an AIR instruction (computed at runtime)
        switch (try self.resolveInst(callee_index)) {
            .register => |reg| {
                // BLR - Branch with link to register
                try self.addInst(.{
                    .tag = .blr,
                    .ops = .r,
                    .data = .{ .r = reg },
                });
            },
            .memory => |mem| {
                // Load function pointer from memory and call via BLR
                const temp_reg = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(temp_reg);

                try self.addInst(.{
                    .tag = .ldr,
                    .ops = .rm,
                    .data = .{ .rm = .{
                        .rd = temp_reg,
                        .mem = mem,
                    } },
                });

                try self.addInst(.{
                    .tag = .blr,
                    .ops = .r,
                    .data = .{ .r = temp_reg },
                });
            },
            else => |mcv| return self.fail("TODO: ARM64 airCall with callee type {}", .{mcv}),
        }
    } else if (callee.toInterned()) |callee_interned| {
        // Callee is an interned constant (direct function call)
        const ip = &self.pt.zcu.intern_pool;
        const func_key = ip.indexToKey(callee_interned);

        // Extract the navigation index for the function
        const nav_index = switch (func_key) {
            .func => |func| func.owner_nav,
            .@"extern" => |@"extern"| @"extern".owner_nav,
            .ptr => |ptr| blk: {
                if (ptr.byte_offset != 0) return self.fail("TODO: function pointer with offset", .{});
                switch (ptr.base_addr) {
                    .nav => |nav| {
                        const nav_val = self.pt.zcu.navValue(nav);
                        const nav_key = ip.indexToKey(nav_val.toIntern());
                        break :blk switch (nav_key) {
                            .func => |func| func.owner_nav,
                            .@"extern" => |@"extern"| @"extern".owner_nav,
                            else => return self.fail("TODO: function pointer to non-function: {}", .{nav_key}),
                        };
                    },
                    else => return self.fail("TODO: function pointer base {}", .{ptr.base_addr}),
                }
            },
            else => return self.fail("TODO: direct call to non-function type {}", .{func_key}),
        };

        // Emit BL instruction - will be relocated by linker
        // Navigation index stored for linker to resolve
        try self.addInst(.{
            .tag = .bl,
            .ops = .nav,
            .data = .{ .nav = @intFromEnum(nav_index) },
        });
    } else {
        return self.fail("Invalid callee reference", .{});
    }

    // Restore stack pointer if we adjusted it for stack arguments
    if (stack_space > 0) {
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = .sp,
                .rn = .sp,
                .imm = stack_space,
            } },
        });
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

    // Track the block's result value (set by br instructions)
    try self.inst_tracking.put(self.gpa, inst, .init(block_data.result));
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

fn airByteSwap(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const ty = self.typeOf(ty_op.operand);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    const zcu = self.pt.zcu;
    const bit_size = ty.bitSize(zcu);

    // ARM64 has REV instruction for byte swap
    // REV reverses bytes in 32-bit or 64-bit register
    if (bit_size == 16) {
        // REV16 - reverse bytes in each halfword
        try self.addInst(.{
            .tag = .rev16,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else if (bit_size == 32) {
        // REV32 for 32-bit (or REV Wd on 32-bit register)
        try self.addInst(.{
            .tag = .rev32,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg.to32(),
                .rn = operand.register.to32(),
            } },
        });
    } else if (bit_size == 64) {
        // REV for 64-bit
        try self.addInst(.{
            .tag = .rev,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });
    } else {
        return self.fail("TODO: byte_swap for {}-bit integers not yet implemented", .{bit_size});
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airBitReverse(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ARM64 has RBIT instruction to reverse all bits
    try self.addInst(.{
        .tag = .rbit,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airAbs(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);
    const ty = self.typeOfIndex(inst);

    const is_float = ty.isRuntimeFloat();

    if (is_float) {
        // Float absolute value - FABS
        const dst_reg = try self.register_manager.allocReg(inst, .vector);

        try self.addInst(.{
            .tag = .fabs,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = operand.register,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    } else {
        // Integer absolute value
        // ARM64 doesn't have a single ABS instruction for integers
        // Use: CMP operand, #0; CNEG dst, operand, MI
        // CNEG conditionally negates if condition is true
        const dst_reg = try self.register_manager.allocReg(inst, .gp);

        // Compare with zero
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = operand.register,
                .rn = .xzr,
            } },
        });

        // Conditionally negate if negative (MI = minus/negative)
        try self.addInst(.{
            .tag = .cneg,
            .ops = .rrc,
            .data = .{ .rrc = .{
                .rd = dst_reg,
                .rn = operand.register,
                .cond = .mi, // if negative
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    }
}

fn airSplat(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand = try self.resolveInst(ty_op.operand.toIndex().?);

    // Splat broadcasts a scalar to all elements of a vector
    // This requires NEON/SIMD support
    // For now, use DUP instruction to duplicate scalar into vector
    const dst_reg = try self.register_manager.allocReg(inst, .vector);

    // DUP Vd.<T>, Rn - duplicate general-purpose register to vector
    try self.addInst(.{
        .tag = .dup,
        .ops = .rr,
        .data = .{ .rr = .{
            .rd = dst_reg,
            .rn = operand.register,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airOverflowOp(self: *CodeGen, inst: Air.Inst.Index, comptime op: enum { add, sub, mul, shl }) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const bin = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const lhs = try self.resolveInst(bin.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin.rhs.toIndex().?);

    // Result is a tuple: { result, overflow_bit }
    // We need to allocate two registers for the result
    const result_reg = try self.register_manager.allocReg(inst, .gp);
    const overflow_reg = try self.register_manager.allocReg(inst, .gp);

    switch (op) {
        .add => {
            // ADDS - Add and set flags
            try self.addInst(.{
                .tag = .adds,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = result_reg,
                    .rn = lhs.register,
                    .rm = rhs.register,
                } },
            });

            // CSET overflow_reg, VS - Set to 1 if overflow
            try self.addInst(.{
                .tag = .cset,
                .ops = .rrc,
                .data = .{ .rrc = .{
                    .rd = overflow_reg,
                    .rn = .xzr,
                    .cond = .vs, // overflow set
                } },
            });
        },
        .sub => {
            // SUBS - Subtract and set flags
            try self.addInst(.{
                .tag = .subs,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = result_reg,
                    .rn = lhs.register,
                    .rm = rhs.register,
                } },
            });

            // CSET overflow_reg, VS - Set to 1 if overflow
            try self.addInst(.{
                .tag = .cset,
                .ops = .rrc,
                .data = .{ .rrc = .{
                    .rd = overflow_reg,
                    .rn = .xzr,
                    .cond = .vs, // overflow set
                } },
            });
        },
        .mul => {
            // For multiplication overflow detection on ARM64:
            // - For signed: use MUL + SMULH, check if high == sign_extend(low)
            // - For unsigned: use MUL + UMULH, check if high == 0

            const result_ty = self.typeOf(bin.lhs);
            const int_info = result_ty.intInfo(self.pt.zcu);
            const is_signed = int_info.signedness == .signed;

            // Compute low part: result_reg = lhs * rhs
            try self.addInst(.{
                .tag = .mul,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = result_reg,
                    .rn = lhs.register,
                    .rm = rhs.register,
                } },
            });

            if (is_signed) {
                // For signed: compute high part with SMULH
                const high_reg = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(high_reg);

                try self.addInst(.{
                    .tag = .smulh,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = high_reg,
                        .rn = lhs.register,
                        .rm = rhs.register,
                    } },
                });

                // Check overflow: high != arithmetic_shift_right(low, 63)
                // ASR temp, result_reg, #63 (sign extend)
                const sign_ext_reg = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(sign_ext_reg);

                try self.addInst(.{
                    .tag = .asr,
                    .ops = .rri,
                    .data = .{ .rri = .{
                        .rd = sign_ext_reg,
                        .rn = result_reg,
                        .imm = 63,
                    } },
                });

                // CMP high, sign_ext
                try self.addInst(.{
                    .tag = .cmp,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rn = high_reg,
                        .rd = sign_ext_reg,
                    } },
                });

                // CSET overflow_reg, NE - Set to 1 if not equal (overflow)
                try self.addInst(.{
                    .tag = .cset,
                    .ops = .rrc,
                    .data = .{ .rrc = .{
                        .rd = overflow_reg,
                        .rn = .xzr,
                        .cond = .ne,
                    } },
                });
            } else {
                // For unsigned: compute high part with UMULH
                const high_reg = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(high_reg);

                try self.addInst(.{
                    .tag = .umulh,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = high_reg,
                        .rn = lhs.register,
                        .rm = rhs.register,
                    } },
                });

                // Check overflow: high != 0
                // CMP high, XZR (compare with zero)
                try self.addInst(.{
                    .tag = .cmp,
                    .ops = .rr,
                    .data = .{ .rr = .{
                        .rn = high_reg,
                        .rd = .xzr,
                    } },
                });

                // CSET overflow_reg, NE - Set to 1 if not equal to 0 (overflow)
                try self.addInst(.{
                    .tag = .cset,
                    .ops = .rrc,
                    .data = .{ .rrc = .{
                        .rd = overflow_reg,
                        .rn = .xzr,
                        .cond = .ne,
                    } },
                });
            }
        },
        .shl => {
            // For shift left overflow detection:
            // 1. Perform the shift: result = lhs << rhs
            // 2. Shift back: temp = result >> rhs (arithmetic for signed, logical for unsigned)
            // 3. Compare temp with original lhs
            // 4. If different, overflow occurred

            const result_ty = self.typeOf(bin.lhs);
            const int_info = result_ty.intInfo(self.pt.zcu);
            const is_signed = int_info.signedness == .signed;

            // LSL result_reg, lhs, rhs (shift left)
            try self.addInst(.{
                .tag = .lsl,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = result_reg,
                    .rn = lhs.register,
                    .rm = rhs.register,
                } },
            });

            // Shift back to check for overflow
            const shifted_back_reg = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(shifted_back_reg);

            if (is_signed) {
                // ASR shifted_back, result, rhs (arithmetic shift right)
                try self.addInst(.{
                    .tag = .asr,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = shifted_back_reg,
                        .rn = result_reg,
                        .rm = rhs.register,
                    } },
                });
            } else {
                // LSR shifted_back, result, rhs (logical shift right)
                try self.addInst(.{
                    .tag = .lsr,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = shifted_back_reg,
                        .rn = result_reg,
                        .rm = rhs.register,
                    } },
                });
            }

            // CMP shifted_back, lhs (compare with original)
            try self.addInst(.{
                .tag = .cmp,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rn = shifted_back_reg,
                    .rd = lhs.register,
                } },
            });

            // CSET overflow_reg, NE - Set to 1 if not equal (overflow)
            try self.addInst(.{
                .tag = .cset,
                .ops = .rrc,
                .data = .{ .rrc = .{
                    .rd = overflow_reg,
                    .rn = .xzr,
                    .cond = .ne,
                } },
            });
        },
    }

    // Store as register pair
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register_pair = .{ result_reg, overflow_reg } }));
}

fn airMulAdd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const bin = self.air.extraData(Air.Bin, pl_op.payload).data;
    const addend = try self.resolveInst(pl_op.operand.toIndex().?);
    const lhs = try self.resolveInst(bin.lhs.toIndex().?);
    const rhs = try self.resolveInst(bin.rhs.toIndex().?);

    const result_ty = self.typeOfIndex(inst);
    const is_float = result_ty.isRuntimeFloat();

    if (is_float) {
        // FMADD - Floating-point fused multiply-add: d = a + (n * m)
        const dst_reg = try self.register_manager.allocReg(inst, .vector);

        try self.addInst(.{
            .tag = .fmadd,
            .ops = .rrrr,
            .data = .{ .rrrr = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
                .ra = addend.register,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    } else {
        // MADD - Integer multiply-add: d = a + (n * m)
        const dst_reg = try self.register_manager.allocReg(inst, .gp);

        try self.addInst(.{
            .tag = .madd,
            .ops = .rrrr,
            .data = .{ .rrrr = .{
                .rd = dst_reg,
                .rn = lhs.register,
                .rm = rhs.register,
                .ra = addend.register,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    }
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

    if (arg_index < 8) {
        // Register arguments (0-7)
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
    } else {
        // Stack arguments (8+)
        // Arguments on stack are at [FP + 16 + (arg_index - 8) * 8]
        // The +16 accounts for saved FP and LR
        const stack_offset = @as(i32, @intCast(16 + (arg_index - 8) * 8));

        // Allocate a register to load the argument into
        const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
        const dst_reg = try self.register_manager.allocReg(inst, reg_class);

        // LDR Xt, [FP, #offset]
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(.x29, stack_offset), // FP
            } },
        });

        // Track the argument value
        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
    }
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

fn airUnionInit(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = self.air.extraData(Air.UnionInit, ty_pl.payload).data;
    const union_ty = ty_pl.ty.toType();
    const field_index = extra.field_index;
    const init_val = try self.resolveInst(extra.init.toIndex().?);

    const zcu = self.pt.zcu;
    const layout = union_ty.unionGetLayout(zcu);

    // Allocate stack space for the union
    const stack_offset = self.max_stack_size;
    const union_abi_size: u32 = @intCast(union_ty.abiSize(zcu));
    self.max_stack_size = stack_offset + union_abi_size;

    // Get the stack pointer for the union
    const sp_reg = try self.register_manager.allocReg(inst, .gp);

    // Calculate SP + stack_offset and store in sp_reg
    if (stack_offset <= 4095) {
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = sp_reg,
                .rn = .sp,
                .imm = stack_offset,
            } },
        });
    } else {
        // Load large offset into temp register
        const tmp_reg = try self.register_manager.allocReg(inst, .gp);
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = tmp_reg,
                .imm = @intCast(stack_offset & 0xFFFF),
            } },
        });
        if (stack_offset > 0xFFFF) {
            try self.addInst(.{
                .tag = .movk,
                .ops = .rri_shift,
                .data = .{ .rri_shift = .{
                    .rd = tmp_reg,
                    .rn = tmp_reg,  // MOVK modifies rd in-place
                    .imm = @intCast((stack_offset >> 16) & 0xFFFF),
                    .shift = 16,
                } },
            });
        }
        try self.addInst(.{
            .tag = .add,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = sp_reg,
                .rn = .sp,
                .rm = tmp_reg,
            } },
        });
    }

    // If tagged union, store the tag first
    if (layout.tag_size > 0) {
        const tag_off: i32 = @intCast(layout.tag_align.forward(layout.payload_size));
        const tag_reg = try self.register_manager.allocReg(inst, .gp);

        // Load field index as tag value
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = tag_reg,
                .imm = @intCast(field_index),
            } },
        });

        // Store tag at union + tag_offset
        try self.addInst(.{
            .tag = if (layout.tag_size <= 1) .strb else if (layout.tag_size <= 2) .strh else .str,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = tag_reg,
                .mem = Memory.simple(sp_reg, tag_off),
            } },
        });
    }

    // Store the payload value at the union base
    const payload_off: i32 = @intCast(layout.payloadOffset());
    switch (init_val) {
        .register => |reg| {
            try self.addInst(.{
                .tag = .str,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = reg,
                    .mem = Memory.simple(sp_reg, payload_off),
                } },
            });
        },
        .immediate => |imm| {
            const temp_reg = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = temp_reg,
                    .imm = @intCast(imm & 0xFFFF),
                } },
            });
            try self.addInst(.{
                .tag = .str,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = temp_reg,
                    .mem = Memory.simple(sp_reg, payload_off),
                } },
            });
        },
        else => return self.fail("TODO: ARM64 union_init for MCValue type {s}", .{@tagName(init_val)}),
    }

    // Track the result as the register containing the union address
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = sp_reg }));
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

    // Load the tag using appropriate instruction based on size
    try self.addInst(.{
        .tag = if (tag_size <= 1) .ldrb else if (tag_size <= 2) .ldrh else .ldr,
        .ops = .rm,
        .data = .{ .rm = .{
            .rd = dst_reg,
            .mem = Memory.simple(operand.register, tag_off),
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airSlice(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const len = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Slices are represented as register pairs: {ptr, len}
    // Allocate two registers for the slice
    const ptr_reg = switch (ptr) {
        .register => |reg| reg,
        else => blk: {
            const temp = try self.register_manager.allocReg(inst, .gp);
            // Move the value to a register
            switch (ptr) {
                .immediate => |imm| {
                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{
                            .rd = temp,
                            .imm = @intCast(imm & 0xFFFF),
                        } },
                    });
                },
                else => return self.fail("TODO: airSlice with ptr type {}", .{ptr}),
            }
            break :blk temp;
        },
    };

    const len_reg = switch (len) {
        .register => |reg| reg,
        .immediate => |imm| blk: {
            const temp = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = temp,
                    .imm = @intCast(imm & 0xFFFF),
                } },
            });
            break :blk temp;
        },
        else => return self.fail("TODO: airSlice with len type {}", .{len}),
    };

    // Track the slice as a register pair
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register_pair = .{ ptr_reg, len_reg } }));
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
    const size: u32 = @intCast(pointee_ty.abiSize(zcu));
    const alignment = ptr_ty.ptrAlignment(zcu);
    const alignment_bytes: u32 = @intCast(alignment.toByteUnits().?);

    // Align stack_offset to required alignment
    self.stack_offset = std.mem.alignForward(u32, self.stack_offset, alignment_bytes);

    // Allocate space on stack
    const offset = self.stack_offset;
    self.stack_offset += size;

    // Track maximum stack size
    self.max_stack_size = @max(self.max_stack_size, self.stack_offset);

    // Allocate a register to hold the address
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Calculate address: FP - offset
    // Since stack grows downward, allocations are at negative offsets from FP
    if (offset == 0) {
        // First allocation - just use FP
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = .x29, // FP
            } },
        });
    } else {
        // SUB Xd, FP, #offset
        try self.addInst(.{
            .tag = .sub,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = dst_reg,
                .rn = .x29, // FP
                .imm = offset,
            } },
        });
    }

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

fn airSliceElemVal(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const slice_ty = self.typeOf(bin_op.lhs);
    const elem_ty = slice_ty.childType(self.pt.zcu);
    const elem_size = elem_ty.abiSize(self.pt.zcu);

    // Get the slice (which is a { ptr, len } pair)
    const slice = try self.resolveInst(bin_op.lhs.toIndex().?);
    const index = try self.resolveInst(bin_op.rhs.toIndex().?);

    // Extract the pointer from the slice
    const slice_ptr_reg = switch (slice) {
        .register_pair => |regs| regs[0],
        else => return self.fail("TODO: slice_elem_val with slice MCValue {s}", .{@tagName(slice)}),
    };

    // Determine register class based on element type
    const is_float = elem_ty.isRuntimeFloat();
    const reg_class: abi.RegisterClass = if (is_float) .vector else .gp;
    const dst_reg = try self.register_manager.allocReg(inst, reg_class);

    // Calculate address and load value
    if (index == .immediate and index.immediate * elem_size < 32768) {
        // Direct load with immediate offset
        const offset: i32 = @intCast(index.immediate * elem_size);
        try self.addInst(.{
            .tag = .ldr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(slice_ptr_reg, offset),
            } },
        });
    } else {
        // Calculate address dynamically
        const addr_reg = try self.register_manager.allocReg(inst, .gp);

        if (std.math.isPowerOfTwo(elem_size)) {
            const shift = std.math.log2_int(u64, elem_size);

            if (shift == 0) {
                // Element size is 1, just add index to pointer
                try self.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .rrr = .{
                        .rd = addr_reg,
                        .rn = slice_ptr_reg,
                        .rm = index.register,
                    } },
                });
            } else {
                // Shift index by log2(elem_size), then add to pointer
                const temp_reg = try self.register_manager.allocReg(inst, .gp);

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
                        .rn = slice_ptr_reg,
                        .rm = temp_reg,
                    } },
                });

                self.register_manager.freeReg(temp_reg);
            }
        } else {
            // Non-power-of-2 size, use multiplication
            const size_reg = try self.register_manager.allocReg(inst, .gp);
            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = size_reg,
                    .imm = @intCast(elem_size & 0xFFFF),
                } },
            });

            const offset_reg = try self.register_manager.allocReg(inst, .gp);
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
                    .rn = slice_ptr_reg,
                    .rm = offset_reg,
                } },
            });

            self.register_manager.freeReg(size_reg);
            self.register_manager.freeReg(offset_reg);
        }

        // Load the value at the calculated address
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

fn airArrayToSlice(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const zcu = self.pt.zcu;

    // Get the pointer to the array
    const array_ptr_mcv = try self.resolveInst(ty_op.operand.toIndex().?);
    const ptr_ty = self.typeOf(ty_op.operand);
    const array_ty = ptr_ty.childType(zcu);
    const array_len = array_ty.arrayLen(zcu);

    // Get pointer in a register
    const ptr_reg = switch (array_ptr_mcv) {
        .register => |reg| reg,
        else => return self.fail("TODO: array_to_slice with ptr MCValue {s}", .{@tagName(array_ptr_mcv)}),
    };

    // Allocate a register for the length
    const len_reg = try self.register_manager.allocReg(inst, .gp);

    // Load the array length into the length register
    // MOV len_reg, #array_len (or use MOVZ for larger values)
    if (array_len <= 0xFFFF) {
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = len_reg,
                .imm = @intCast(array_len),
            } },
        });
    } else {
        // For larger lengths, we need to build the value in multiple steps
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = len_reg,
                .imm = @intCast(array_len & 0xFFFF),
            } },
        });
        if ((array_len >> 16) & 0xFFFF != 0) {
            try self.addInst(.{
                .tag = .movk,
                .ops = .rri_shift,
                .data = .{ .rri_shift = .{
                    .rd = len_reg,
                    .rn = len_reg,
                    .imm = @intCast((array_len >> 16) & 0xFFFF),
                    .shift = 16,
                } },
            });
        }
    }

    // Return slice as a register pair: {pointer, length}
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register_pair = .{ ptr_reg, len_reg } }));
}

fn airAggregateInit(self: *CodeGen, inst: Air.Inst.Index) !void {
    const zcu = self.pt.zcu;
    const result_ty = self.typeOfIndex(inst);
    const len: usize = @intCast(result_ty.arrayLen(zcu));
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const elements: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[ty_pl.payload..][0..len]);

    const result: MCValue = result: {
        switch (result_ty.zigTypeTag(zcu)) {
            .@"struct" => {
                const frame_index = try self.allocFrameIndex(FrameAlloc.initSpill(result_ty, zcu));

                // For now, only support non-packed structs
                if (result_ty.containerLayout(zcu) == .@"packed") {
                    return self.fail("TODO: ARM64 airAggregateInit packed structs", .{});
                }

                // Initialize each struct field
                for (elements, 0..) |elem, elem_i| {
                    if ((try result_ty.structFieldValueComptime(self.pt, elem_i)) != null) continue;

                    const elem_ty = result_ty.fieldType(elem_i, zcu);
                    const elem_off: i32 = @intCast(result_ty.structFieldOffset(elem_i, zcu));
                    const elem_mcv = try self.resolveInst(elem.toIndex().?);
                    try self.genSetMem(inst, .{ .frame_addr = .{ .index = frame_index, .off = 0 } }, elem_off, elem_ty, elem_mcv);
                }
                break :result .{ .load_frame = .{ .index = frame_index, .off = 0 } };
            },
            .array => {
                const elem_ty = result_ty.childType(zcu);
                const frame_index = try self.allocFrameIndex(FrameAlloc.initSpill(result_ty, zcu));
                const elem_size: u32 = @intCast(elem_ty.abiSize(zcu));

                // Initialize each array element
                for (elements, 0..) |elem, elem_i| {
                    const elem_mcv = try self.resolveInst(elem.toIndex().?);
                    const elem_off: i32 = @intCast(elem_size * elem_i);
                    try self.genSetMem(
                        inst,
                        .{ .frame_addr = .{ .index = frame_index, .off = 0 } },
                        elem_off,
                        elem_ty,
                        elem_mcv,
                    );
                }

                // Handle sentinel if present
                if (result_ty.sentinel(zcu)) |sentinel_val| {
                    const sentinel_off: i32 = @intCast(elem_size * elements.len);
                    // For now, assume sentinel is an immediate value
                    const sentinel_mcv: MCValue = .{ .immediate = sentinel_val.toUnsignedInt(zcu) };
                    try self.genSetMem(
                        inst,
                        .{ .frame_addr = .{ .index = frame_index, .off = 0 } },
                        sentinel_off,
                        elem_ty,
                        sentinel_mcv,
                    );
                }
                break :result .{ .load_frame = .{ .index = frame_index, .off = 0 } };
            },
            else => return self.fail("TODO: ARM64 airAggregateInit {s}", .{@tagName(result_ty.zigTypeTag(zcu))}),
        }
    };

    try self.inst_tracking.put(self.gpa, inst, .init(result));
}

fn airMemset(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pt = self.pt;
    const zcu = pt.zcu;
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const dest_ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const value = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dest_ty = self.typeOf(bin_op.lhs);
    _ = self.typeOf(bin_op.rhs);

    // Get the length - for slices it's in the second element
    const len_mcv = switch (dest_ty.ptrSize(zcu)) {
        .slice => blk: {
            // Slice is {ptr, len} - we need the length
            switch (dest_ptr) {
                .register_pair => |regs| break :blk MCValue{ .register = regs[1] },
                else => return self.fail("TODO: memset with slice not in register pair", .{}),
            }
        },
        .one => blk: {
            // Pointer to array - get compile-time length
            const array_ty = dest_ty.childType(zcu);
            const len = array_ty.arrayLen(zcu);
            break :blk MCValue{ .immediate = len };
        },
        else => return self.fail("TODO: memset with pointer size {}", .{dest_ty.ptrSize(zcu)}),
    };

    // Get destination pointer register
    const dest_reg = switch (dest_ptr) {
        .register => |reg| reg,
        .register_pair => |regs| regs[0], // First element is the pointer
        else => return self.fail("TODO: memset with dest type {}", .{dest_ptr}),
    };

    // Get value to set (should be u8)
    const value_reg = switch (value) {
        .register => |reg| reg,
        .immediate => |imm| blk: {
            const temp = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(temp);

            try self.addInst(.{
                .tag = .movz,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = temp,
                    .imm = @intCast(imm & 0xFF),
                } },
            });
            break :blk temp;
        },
        else => return self.fail("TODO: memset with value type {}", .{value}),
    };

    // For compile-time known small lengths, unroll
    if (len_mcv == .immediate and len_mcv.immediate <= 32) {
        const len: u64 = len_mcv.immediate;
        var offset: i32 = 0;

        while (offset < len) : (offset += 1) {
            try self.addInst(.{
                .tag = .strb,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(dest_reg, offset),
                    .rs = value_reg,
                } },
            });
        }
    } else {
        // Runtime length or large size - use loop with byte stores
        // Loop counter
        const counter = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(counter);

        const len_reg = switch (len_mcv) {
            .register => |reg| reg,
            .immediate => |imm| blk: {
                const temp = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(temp);

                try self.addInst(.{
                    .tag = .movz,
                    .ops = .ri,
                    .data = .{ .ri = .{
                        .rd = temp,
                        .imm = @intCast(imm & 0xFFFF),
                    } },
                });
                break :blk temp;
            },
            else => return self.fail("Invalid length MCValue", .{}),
        };

        // MOV counter, #0
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = counter,
                .imm = 0,
            } },
        });

        // Loop start
        const loop_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);

        // STR value, [dest, counter]
        try self.addInst(.{
            .tag = .strb,
            .ops = .mr,
            .data = .{ .mr = .{
                .mem = .{ .base = dest_reg, .offset = .{ .register = .{ .reg = counter, .shift = 0 } } },
                .rs = value_reg,
            } },
        });

        // ADD counter, counter, #1
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = counter,
                .rn = counter,
                .imm = 1,
            } },
        });

        // CMP counter, len
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rn = counter,
                .rd = len_reg,
            } },
        });

        // B.LT loop_start
        try self.addInst(.{
            .tag = .b_cond,
            .ops = .rel,
            .data = .{ .rc = .{
                .rn = .xzr,
                .cond = .lt,
                .target = loop_start,
            } },
        });
    }

    // memset doesn't produce a result value
}

fn airMemcpy(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pt = self.pt;
    const zcu = pt.zcu;
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const dest_ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const source_ptr = try self.resolveInst(bin_op.rhs.toIndex().?);

    const dest_ty = self.typeOf(bin_op.lhs);
    _ = self.typeOf(bin_op.rhs);

    // Get the length - for slices it's in the second element
    const len_mcv = switch (dest_ty.ptrSize(zcu)) {
        .slice => blk: {
            // Slice is {ptr, len} - we need the length
            switch (dest_ptr) {
                .register_pair => |regs| break :blk MCValue{ .register = regs[1] },
                else => return self.fail("TODO: memcpy with slice not in register pair", .{}),
            }
        },
        .one => blk: {
            // Pointer to array - get compile-time length
            const array_ty = dest_ty.childType(zcu);
            const len = array_ty.arrayLen(zcu);
            break :blk MCValue{ .immediate = len };
        },
        else => return self.fail("TODO: memcpy with pointer size {}", .{dest_ty.ptrSize(zcu)}),
    };

    // Get destination pointer register
    const dest_reg = switch (dest_ptr) {
        .register => |reg| reg,
        .register_pair => |regs| regs[0], // First element is the pointer
        else => return self.fail("TODO: memcpy with dest type {}", .{dest_ptr}),
    };

    // Get source pointer register
    const source_reg = switch (source_ptr) {
        .register => |reg| reg,
        .register_pair => |regs| regs[0], // First element is the pointer
        else => return self.fail("TODO: memcpy with source type {}", .{source_ptr}),
    };

    // For compile-time known small lengths, unroll
    if (len_mcv == .immediate and len_mcv.immediate <= 32) {
        const len: u64 = len_mcv.immediate;
        var offset: i32 = 0;

        // Use 8-byte copies where possible, then 4-byte, then 1-byte
        while (offset + 8 <= len) : (offset += 8) {
            const temp = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(temp);

            // LDR temp, [source, #offset]
            try self.addInst(.{
                .tag = .ldr,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = temp,
                    .mem = Memory.simple(source_reg, offset),
                } },
            });

            // STR temp, [dest, #offset]
            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(dest_reg, offset),
                    .rs = temp,
                } },
            });
        }

        // Handle remaining bytes
        while (offset < len) : (offset += 1) {
            const temp = try self.register_manager.allocReg(inst, .gp);
            defer self.register_manager.freeReg(temp);

            // LDRB temp, [source, #offset]
            try self.addInst(.{
                .tag = .ldrb,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = temp,
                    .mem = Memory.simple(source_reg, offset),
                } },
            });

            // STRB temp, [dest, #offset]
            try self.addInst(.{
                .tag = .strb,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(dest_reg, offset),
                    .rs = temp,
                } },
            });
        }
    } else {
        // Runtime length or large size - use loop
        const counter = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(counter);

        const temp = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(temp);

        const len_reg = switch (len_mcv) {
            .register => |reg| reg,
            .immediate => |imm| blk: {
                const t = try self.register_manager.allocReg(inst, .gp);
                defer self.register_manager.freeReg(t);

                try self.addInst(.{
                    .tag = .movz,
                    .ops = .ri,
                    .data = .{ .ri = .{
                        .rd = t,
                        .imm = @intCast(imm & 0xFFFF),
                    } },
                });
                break :blk t;
            },
            else => return self.fail("Invalid length MCValue", .{}),
        };

        // MOV counter, #0
        try self.addInst(.{
            .tag = .movz,
            .ops = .ri,
            .data = .{ .ri = .{
                .rd = counter,
                .imm = 0,
            } },
        });

        // Loop start
        const loop_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);

        // LDRB temp, [source, counter]
        try self.addInst(.{
            .tag = .ldrb,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = temp,
                .mem = .{ .base = source_reg, .offset = .{ .register = .{ .reg = counter, .shift = 0 } } },
            } },
        });

        // STRB temp, [dest, counter]
        try self.addInst(.{
            .tag = .strb,
            .ops = .mr,
            .data = .{ .mr = .{
                .mem = .{ .base = dest_reg, .offset = .{ .register = .{ .reg = counter, .shift = 0 } } },
                .rs = temp,
            } },
        });

        // ADD counter, counter, #1
        try self.addInst(.{
            .tag = .add,
            .ops = .rri,
            .data = .{ .rri = .{
                .rd = counter,
                .rn = counter,
                .imm = 1,
            } },
        });

        // CMP counter, len
        try self.addInst(.{
            .tag = .cmp,
            .ops = .rr,
            .data = .{ .rr = .{
                .rn = counter,
                .rd = len_reg,
            } },
        });

        // B.LT loop_start
        try self.addInst(.{
            .tag = .b_cond,
            .ops = .rel,
            .data = .{ .rc = .{
                .rn = .xzr,
                .cond = .lt,
                .target = loop_start,
            } },
        });
    }

    // memcpy doesn't produce a result value
}

fn airAtomicLoad(self: *CodeGen, inst: Air.Inst.Index) !void {
    const atomic_load = self.air.instructions.items(.data)[@intFromEnum(inst)].atomic_load;
    const ptr = try self.resolveInst(atomic_load.ptr.toIndex().?);

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // ARM64 atomic load ideally uses LDAR (Load-Acquire Register)
    // but MIR doesn't have LDAR/LDARB/LDARH yet, so we use LDR + DMB for acquire semantics
    const ordering = atomic_load.order;

    switch (ordering) {
        .unordered, .monotonic => {
            // Use regular load - no ordering guarantees needed
            try self.addInst(.{
                .tag = .ldr,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = dst_reg,
                    .mem = Memory.simple(ptr.register, 0),
                } },
            });
        },
        .acquire, .acq_rel, .seq_cst => {
            // Load followed by DMB (Data Memory Barrier) for acquire semantics
            // Note: acq_rel behaves like acquire for loads
            try self.addInst(.{
                .tag = .ldr,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = dst_reg,
                    .mem = Memory.simple(ptr.register, 0),
                } },
            });

            // DMB ISH - full memory barrier
            try self.addInst(.{
                .tag = .dmb,
                .ops = .none,
                .data = .{ .none = {} },
            });
        },
        else => return self.fail("TODO: atomic_load with ordering {} not yet supported", .{ordering}),
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airAtomicStore(self: *CodeGen, inst: Air.Inst.Index, comptime ordering: std.builtin.AtomicOrder) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs.toIndex().?);
    const value = try self.resolveInst(bin_op.rhs.toIndex().?);

    // ARM64 atomic store ideally uses STLR (Store-Release Register)
    // but MIR doesn't have STLR/STLRB/STLRH yet, so we use DMB + STR for release semantics

    switch (ordering) {
        .unordered, .monotonic => {
            // Use regular store - no ordering guarantees needed
            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(ptr.register, 0),
                    .rs = value.register,
                } },
            });
        },
        .release, .acq_rel, .seq_cst => {
            // DMB followed by store for release semantics
            // Note: acq_rel behaves like release for stores
            // DMB ISH - full memory barrier
            try self.addInst(.{
                .tag = .dmb,
                .ops = .none,
                .data = .{ .none = {} },
            });

            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .mem = Memory.simple(ptr.register, 0),
                    .rs = value.register,
                } },
            });
        },
        else => return self.fail("TODO: atomic_store with ordering {} not yet supported", .{ordering}),
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .none = {} }));
}

fn airAtomicRmw(self: *CodeGen, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = self.air.extraData(Air.AtomicRmw, pl_op.payload);

    const ptr = try self.resolveInst(pl_op.operand.toIndex().?);
    const operand = try self.resolveInst(extra.data.operand.toIndex().?);
    const op = extra.data.op();

    // ARM64 has atomic RMW operations using LSE (Load-Store Exclusive) instructions
    // These are ARMv8.1-A LSE (Large System Extensions) instructions:
    // LDADD, LDCLR, LDEOR, LDSET, LDSMAX, LDSMIN, LDUMAX, LDUMIN
    // For Nand operation, we use LDXR/STXR loop since there's no single LSE instruction

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Handle Nand as a special case with LDXR/STXR loop
    if (op == .Nand) {
        // NAND requires LDXR/STXR loop: ~(old & operand)
        // Algorithm:
        // loop:
        //   LDXR  old_value, [ptr]      ; Load exclusive, save old value
        //   AND   new_value, old_value, operand ; new_value = old_value & operand
        //   MVN   new_value, new_value  ; new_value = ~(old_value & operand) = NAND
        //   STXR  status, new_value, [ptr]  ; Store exclusive, status=0 on success
        //   CBNZ  status, loop          ; Retry if failed
        // Result: dst_reg contains the value before the operation

        // Allocate temp registers
        const new_value_reg = try self.register_manager.allocReg(inst, .gp);
        const status_reg = try self.register_manager.allocReg(inst, .gp);
        defer self.register_manager.freeReg(new_value_reg);
        defer self.register_manager.freeReg(status_reg);

        // Mark loop start
        const loop_start: Mir.Inst.Index = @intCast(self.mir_instructions.len);

        // LDXR dst_reg, [ptr]  ; Load exclusive into dst_reg (old value)
        try self.addInst(.{
            .tag = .ldxr,
            .ops = .rm,
            .data = .{ .rm = .{
                .rd = dst_reg,
                .mem = Memory.simple(ptr.register, 0),
            } },
        });

        // AND new_value_reg, dst_reg, operand
        try self.addInst(.{
            .tag = .and_,
            .ops = .rrr,
            .data = .{ .rrr = .{
                .rd = new_value_reg,
                .rn = dst_reg,
                .rm = operand.register,
            } },
        });

        // MVN new_value_reg, new_value_reg
        try self.addInst(.{
            .tag = .mvn,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = new_value_reg,
                .rn = new_value_reg,
            } },
        });

        // STXR status_reg, new_value_reg, [ptr]
        try self.addInst(.{
            .tag = .stxr,
            .ops = .rrm,
            .data = .{ .rrm = .{
                .mem = Memory.simple(ptr.register, 0),
                .r1 = status_reg,
                .r2 = new_value_reg,
            } },
        });

        // CBNZ status_reg, loop_start
        try self.addInst(.{
            .tag = .cbnz,
            .ops = .r_rel,
            .data = .{ .r_rel = .{
                .rn = status_reg,
                .target = loop_start,
            } },
        });

        try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
        return;
    }

    // Determine signedness for Max/Min operations
    const zcu = self.pt.zcu;
    const ptr_ty = self.typeOf(pl_op.operand);
    const elem_ty = ptr_ty.childType(zcu); // Get element type from pointer
    const is_signed = elem_ty.isSignedInt(zcu);

    // Select the appropriate LSE instruction based on operation
    const mir_tag: Mir.Inst.Tag = switch (op) {
        .Xchg => .swp,  // SWP = atomic exchange
        .Add => .ldadd,
        .Sub => .ldadd, // SUB is implemented as ADD with negated operand
        .And => .ldclr, // LDCLR with inverted operand = AND
        .Or => .ldset,  // LDSET = OR
        .Xor => .ldeor,
        .Max => if (is_signed) .ldsmax else .ldumax,  // Signed or unsigned max
        .Min => if (is_signed) .ldsmin else .ldumin,  // Signed or unsigned min
        .Nand => unreachable, // Handled above
    };

    // Prepare the actual operand (may need transformation for some operations)
    var actual_operand = operand.register;
    var temp_reg_allocated = false;

    if (op == .And or op == .Sub) {
        const temp_reg = try self.register_manager.allocReg(inst, .gp);
        temp_reg_allocated = true;
        defer if (temp_reg_allocated) self.register_manager.freeReg(temp_reg);

        if (op == .And) {
            // MVN temp, operand (bitwise NOT for LDCLR)
            try self.addInst(.{
                .tag = .mvn,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rd = temp_reg,
                    .rn = operand.register,
                } },
            });
        } else { // op == .Sub
            // NEG temp, operand (negate for SUB via LDADD)
            try self.addInst(.{
                .tag = .neg,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rd = temp_reg,
                    .rn = operand.register,
                } },
            });
        }
        actual_operand = temp_reg;
    }

    // LSE atomic operation: LD<op> Rs, Rt, [Rn]
    // Rs = source value (operand)
    // Rt = destination for old value
    // [Rn] = memory location
    try self.addInst(.{
        .tag = mir_tag,
        .ops = .rrm,
        .data = .{ .rrm = .{
            .mem = Memory.simple(ptr.register, 0),
            .r1 = actual_operand,
            .r2 = dst_reg,
        } },
    });

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airCmpxchg(self: *CodeGen, inst: Air.Inst.Index, comptime is_weak: bool) !void {
    const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = self.air.extraData(Air.Cmpxchg, ty_pl.payload);

    const ptr = try self.resolveInst(extra.data.ptr.toIndex().?);
    const expected_value = try self.resolveInst(extra.data.expected_value.toIndex().?);
    const new_value = try self.resolveInst(extra.data.new_value.toIndex().?);

    // ARM64 compare-and-exchange using CAS instruction (ARMv8.1 LSE)
    // CAS Rs, Rt, [Rn]
    // Compares value at [Rn] with Rs, if equal stores Rt to [Rn]
    // Returns old value in Rs
    // Weak CAS can spuriously fail, strong CAS only fails on mismatch

    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Move expected value to destination register (will be overwritten with old value)
    if (expected_value.register.id() != dst_reg.id()) {
        try self.addInst(.{
            .tag = .mov,
            .ops = .rr,
            .data = .{ .rr = .{
                .rd = dst_reg,
                .rn = expected_value.register,
            } },
        });
    }

    // CAS expected (in dst_reg), new_value, [ptr]
    // After execution, dst_reg contains the old value from memory
    try self.addInst(.{
        .tag = .cas,
        .ops = .rrm,
        .data = .{ .rrm = .{
            .mem = Memory.simple(ptr.register, 0),
            .r1 = dst_reg,      // Expected value (overwritten with old value)
            .r2 = new_value.register,  // New value to store
        } },
    });

    // Result is the old value that was in memory
    // User code will compare this with expected to see if exchange succeeded
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));

    // Note: The weak parameter is ignored because CAS hardware behavior
    // is essentially "strong" - it only fails on actual mismatch
    _ = is_weak;
}

fn airFence(self: *CodeGen, inst: Air.Inst.Index) !void {
    const atomic_order = self.air.instructions.items(.data)[@intFromEnum(inst)].fence;

    // ARM64 memory barriers:
    // DMB ISH - Data Memory Barrier, Inner Shareable domain
    // DSB ISH - Data Synchronization Barrier, Inner Shareable domain

    switch (atomic_order) {
        .unordered, .monotonic => {
            // No barrier needed
        },
        .acquire, .release, .acq_rel, .seq_cst => {
            // DMB ISH - full memory barrier
            try self.addInst(.{
                .tag = .dmb,
                .ops = .none,
                .data = .{ .none = {} },
            });
        },
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .none = {} }));
}

// ============================================================================
// Helper Functions
// ============================================================================

fn resolveInst(self: *CodeGen, inst: Air.Inst.Index) !MCValue {
    const air_tags = self.air.instructions.items(.tag);
    const tag = air_tags[@intFromEnum(inst)];
    const tracking = self.inst_tracking.get(inst) orelse {
        log.err("Instruction {d} (tag={s}) not tracked. inst_tracking has {d} entries", .{
            @intFromEnum(inst),
            @tagName(tag),
            self.inst_tracking.count(),
        });
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
// Frame Allocation
// ============================================================================

/// Allocate a frame index for stack-based values
fn allocFrameIndex(self: *CodeGen, alloc: FrameAlloc) !FrameIndex {
    const frame_allocs_slice = self.frame_allocs.slice();
    const frame_size = frame_allocs_slice.items(.size);
    const frame_align = frame_allocs_slice.items(.alignment);

    // Update stack_frame alignment
    const stack_frame_align = &frame_align[@intFromEnum(FrameIndex.stack_frame)];
    stack_frame_align.* = stack_frame_align.max(alloc.alignment);

    // Try to reuse a freed frame index with matching size
    for (self.free_frame_indices.keys(), 0..) |frame_index, free_i| {
        const size = frame_size[@intFromEnum(frame_index)];
        if (size != alloc.size) continue;
        const abi_align = &frame_align[@intFromEnum(frame_index)];
        abi_align.* = abi_align.max(alloc.alignment);

        _ = self.free_frame_indices.swapRemoveAt(free_i);
        log.debug("reused frame {}", .{frame_index});
        return frame_index;
    }

    // Allocate new frame index
    const frame_index: FrameIndex = @enumFromInt(self.frame_allocs.len);
    try self.frame_allocs.append(self.gpa, alloc);
    log.debug("allocated frame {}", .{frame_index});
    return frame_index;
}

/// Write a value to memory (frame or register-indirect)
fn genSetMem(self: *CodeGen, inst: Air.Inst.Index, ptr_mcv: MCValue, ptr_off: i32, src_ty: Type, src_mcv: MCValue) !void {
    const zcu = self.pt.zcu;
    const src_size = src_ty.abiSize(zcu);

    switch (ptr_mcv) {
        .frame_addr => |frame_addr| {
            // Calculate effective offset
            const eff_off = frame_addr.off + ptr_off;

            switch (src_mcv) {
                .none => {
                    // Void-typed value, no runtime representation
                    // Nothing to store
                },
                .immediate => |imm| {
                    // Load immediate into temporary register
                    const tmp_reg = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(tmp_reg);

                    // Load immediate
                    try self.addInst(.{
                        .tag = .movz,
                        .ops = .ri,
                        .data = .{ .ri = .{
                            .rd = tmp_reg,
                            .imm = @intCast(imm & 0xFFFF),
                        } },
                    });

                    // Store to frame
                    const str_tag: Mir.Inst.Tag = switch (src_size) {
                        1 => .strb,
                        2 => .strh,
                        4 => .str,
                        8 => .str,
                        16 => .str, // Will do two stores below
                        else => return self.fail("TODO: genSetMem frame with size {}", .{src_size}),
                    };

                    if (src_size == 16) {
                        // 16-byte store: do two 8-byte stores
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = tmp_reg,
                            } },
                        });
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off - 8),
                                .rs = tmp_reg,
                            } },
                        });
                    } else {
                        try self.addInst(.{
                            .tag = str_tag,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = tmp_reg,
                            } },
                        });
                    }
                },
                .register => |reg| {
                    // Store register to frame
                    const str_tag: Mir.Inst.Tag = switch (src_size) {
                        1 => .strb,
                        2 => .strh,
                        4 => .str,
                        8 => .str,
                        16 => .str, // Will do two stores below
                        else => return self.fail("TODO: genSetMem frame with size {}", .{src_size}),
                    };

                    if (src_size == 16) {
                        // 16-byte store: assuming register pair or doing two 8-byte stores
                        // For now, just store the same register twice (may need refinement)
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = reg,
                            } },
                        });
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off - 8),
                                .rs = reg,
                            } },
                        });
                    } else {
                        try self.addInst(.{
                            .tag = str_tag,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = reg,
                            } },
                        });
                    }
                },
                .load_frame => |src_frame| {
                    // Load from source frame location, then store to destination
                    const tmp_reg = try self.register_manager.allocReg(inst, .gp);
                    defer self.register_manager.freeReg(tmp_reg);

                    if (src_size == 16) {
                        // 16-byte copy: do two 8-byte loads and stores
                        // First 8 bytes
                        try self.addInst(.{
                            .tag = .ldr,
                            .ops = .rm,
                            .data = .{ .rm = .{
                                .rd = tmp_reg,
                                .mem = Memory.simple(.x29, -src_frame.off),
                            } },
                        });
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = tmp_reg,
                            } },
                        });

                        // Second 8 bytes
                        try self.addInst(.{
                            .tag = .ldr,
                            .ops = .rm,
                            .data = .{ .rm = .{
                                .rd = tmp_reg,
                                .mem = Memory.simple(.x29, -src_frame.off - 8),
                            } },
                        });
                        try self.addInst(.{
                            .tag = .str,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off - 8),
                                .rs = tmp_reg,
                            } },
                        });
                    } else {
                        // Load from source frame
                        const ldr_tag: Mir.Inst.Tag = switch (src_size) {
                            1 => .ldrb,
                            2 => .ldrh,
                            4 => .ldr,
                            8 => .ldr,
                            else => return self.fail("TODO: genSetMem frame load with size {}", .{src_size}),
                        };

                        try self.addInst(.{
                            .tag = ldr_tag,
                            .ops = .rm,
                            .data = .{ .rm = .{
                                .rd = tmp_reg,
                                .mem = Memory.simple(.x29, -src_frame.off),
                            } },
                        });

                        // Store to destination frame
                        const str_tag: Mir.Inst.Tag = switch (src_size) {
                            1 => .strb,
                            2 => .strh,
                            4 => .str,
                            8 => .str,
                            else => return self.fail("TODO: genSetMem frame store with size {}", .{src_size}),
                        };

                        try self.addInst(.{
                            .tag = str_tag,
                            .ops = .mr,
                            .data = .{ .mr = .{
                                .mem = Memory.simple(.x29, -eff_off),
                                .rs = tmp_reg,
                            } },
                        });
                    }
                },
                else => return self.fail("TODO: genSetMem frame with src {s}", .{@tagName(src_mcv)}),
            }
        },
        else => return self.fail("TODO: genSetMem with ptr {s}", .{@tagName(ptr_mcv)}),
    }
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

/// Parse register name from string (for inline assembly)
fn parseRegName(name: []const u8) ?codegen.aarch64.encoding.Register {
    return codegen.aarch64.encoding.Register.parse(name);
}
