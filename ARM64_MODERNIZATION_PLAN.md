# ARM64 Backend Modernization Plan
## Porting x86_64 Architecture to aarch64

**Author:** Claude
**Date:** 2025-11-17
**Status:** Planning Phase

---

## Executive Summary

This document outlines a detailed plan to modernize Zig's aarch64 backend by adopting the sophisticated architecture used in the x86_64 backend. The goal is to improve code generation quality, maintainability, and performance while maintaining backward compatibility during the transition.

**Current State:**
- ✅ Working aarch64 backend (~35K lines)
- ✅ Working x86_64 backend (~200K lines, modern architecture)
- ⚠️ Architectures are completely different

**Goal State:**
- ✅ aarch64 backend using x86_64's architecture
- ✅ Liveness analysis enabled
- ✅ Sophisticated register allocation
- ✅ Better code generation
- ✅ Shared patterns and maintainability

---

## Table of Contents

1. [Architecture Comparison](#architecture-comparison)
2. [Migration Strategy](#migration-strategy)
3. [Detailed Implementation Plan](#detailed-implementation-plan)
4. [File Structure](#file-structure)
5. [Implementation Phases](#implementation-phases)
6. [Testing Strategy](#testing-strategy)
7. [Rollout Plan](#rollout-plan)
8. [Risk Mitigation](#risk-mitigation)

---

## Architecture Comparison

### Current aarch64 Backend

```
┌─────┐     ┌────────┐     ┌─────┐     ┌──────────┐     ┌──────────┐
│ AIR │ --> │ Select │ --> │ MIR │ --> │ Assemble │ --> │ Machine  │
│     │     │        │     │     │     │          │     │   Code   │
└─────┘     └────────┘     └─────┘     └──────────┘     └──────────┘
              │                │
              ├─ analyze()     └─ Already encoded instructions
              ├─ body()
              └─ CFG/dominance
```

**Key Characteristics:**
- No liveness analysis (`wantsLiveness() = false`)
- Direct CFG and dominance analysis
- Instructions encoded during selection
- ~35,000 lines of code
- Simpler, older architecture

### Target x86_64 Backend

```
┌─────┐     ┌─────────┐     ┌─────┐     ┌───────┐     ┌──────┐     ┌──────────┐
│ AIR │ --> │ CodeGen │ --> │ MIR │ --> │ Lower │ --> │ Emit │ --> │ Machine  │
│     │     │         │     │     │     │       │     │      │     │   Code   │
└─────┘     └─────────┘     └─────┘     └───────┘     └──────┘     └──────────┘
              │                │            │             │
              ├─ gen()         │            │             └─ DWARF, relocations
              ├─ Liveness      │            └─ Instruction encoding
              └─ RegisterMgr   └─ Abstract instructions
```

**Key Characteristics:**
- Full liveness analysis
- Sophisticated register allocation (RegisterManager)
- Multi-phase: Gen → MIR → Lower → Emit
- Abstract MIR, late instruction encoding
- ~200,000 lines of code
- Modern, maintainable architecture

---

## Migration Strategy

### Core Principle: Incremental Modernization

**DO NOT** remove the current aarch64 backend during development. Instead:

1. **Build alongside:** Create new files with `_v2` suffix initially
2. **Feature flag:** Add compiler flag to switch between old/new backend
3. **Gradual migration:** Test new backend on subsets of code
4. **Performance validation:** Ensure new backend meets or exceeds performance
5. **Clean cutover:** Only remove old backend when new is proven

### Development Branches

```
main
  └─ feature/aarch64-modernization
       ├─ phase-1-foundation
       ├─ phase-2-codegen
       ├─ phase-3-lowering
       └─ phase-4-integration
```

---

## Detailed Implementation Plan

## Phase 1: Foundation (Estimated: 8-10 weeks)

### 1.1 Create ARM64 bits.zig Module

**Goal:** Define all ARM64-specific types and constants

**File:** `src/codegen/aarch64/bits.zig`

**Components to implement:**

#### A. Condition Codes
```zig
pub const Condition = enum(u4) {
    /// Equal
    eq = 0b0000,
    /// Not equal
    ne = 0b0001,
    /// Carry set / unsigned higher or same
    cs = 0b0010, // Also: hs
    /// Carry clear / unsigned lower
    cc = 0b0011, // Also: lo
    /// Minus, negative
    mi = 0b0100,
    /// Plus, positive or zero
    pl = 0b0101,
    /// Overflow set
    vs = 0b0110,
    /// Overflow clear
    vc = 0b0111,
    /// Unsigned higher
    hi = 0b1000,
    /// Unsigned lower or same
    ls = 0b1001,
    /// Signed greater than or equal
    ge = 0b1010,
    /// Signed less than
    lt = 0b1011,
    /// Signed greater than
    gt = 0b1100,
    /// Signed less than or equal
    le = 0b1101,
    /// Always (unconditional)
    al = 0b1110,
    /// Always (unconditional, but reserved encoding)
    nv = 0b1111,

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

    pub fn negate(cond: Condition) Condition {
        return @enumFromInt(@intFromEnum(cond) ^ 1);
    }
};
```

#### B. Register Definitions
```zig
/// ARM64 General Purpose Registers (aligned with encoding.zig)
pub const Register = enum(u8) {
    // 64-bit registers (X0-X30, XZR, SP)
    x0, x1, x2, x3, x4, x5, x6, x7,
    x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23,
    x24, x25, x26, x27, x28, x29, x30,
    xzr, // Zero register
    sp,  // Stack pointer

    // 32-bit registers (W0-W30, WZR)
    w0, w1, w2, w3, w4, w5, w6, w7,
    w8, w9, w10, w11, w12, w13, w14, w15,
    w16, w17, w18, w19, w20, w21, w22, w23,
    w24, w25, w26, w27, w28, w29, w30,
    wzr,

    // SIMD/FP registers (128-bit view)
    v0, v1, v2, v3, v4, v5, v6, v7,
    v8, v9, v10, v11, v12, v13, v14, v15,
    v16, v17, v18, v19, v20, v21, v22, v23,
    v24, v25, v26, v27, v28, v29, v30, v31,

    // Aliases for different sizes
    // Note: encoding.zig already has size handling

    pub fn id(reg: Register) u5 {
        // Return 0-31 register number for encoding
        return @truncate(@intFromEnum(reg) % 32);
    }

    pub fn to64(reg: Register) Register {
        // Convert W register to X register
        // ...
    }

    pub fn to32(reg: Register) Register {
        // Convert X register to W register
        // ...
    }

    pub fn isGeneralPurpose(reg: Register) bool {
        return @intFromEnum(reg) < @intFromEnum(Register.v0);
    }

    pub fn isVector(reg: Register) bool {
        return @intFromEnum(reg) >= @intFromEnum(Register.v0);
    }
};
```

#### C. Memory Addressing
```zig
pub const Memory = struct {
    base: Register,
    offset: Offset,

    pub const Offset = union(enum) {
        /// Immediate offset: [Xn, #imm]
        immediate: i32,
        /// Register offset: [Xn, Xm{, LSL #shift}]
        register: struct {
            reg: Register,
            shift: u3, // 0-7, but typically 0, 1, 2, 3
        },
        /// Pre-index: [Xn, #imm]!
        pre_index: i32,
        /// Post-index: [Xn], #imm
        post_index: i32,
    };

    pub fn simple(base: Register, offset: i32) Memory {
        return .{
            .base = base,
            .offset = .{ .immediate = offset },
        };
    }
};
```

#### D. Frame Indices
```zig
pub const FrameIndex = enum(u32) {
    /// Return address (pushed by BL)
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

pub const FrameAddr = struct {
    index: FrameIndex,
    off: i32,
};
```

**Deliverables:**
- [ ] `bits.zig` with all ARM64 types
- [ ] Unit tests for condition code transformations
- [ ] Register conversion functions
- [ ] Memory addressing mode validation

**Estimated time:** 2 weeks

---

### 1.2 Enhance abi.zig with RegisterManager

**Goal:** Port x86_64's RegisterManager to ARM64

**File:** `src/codegen/aarch64/abi.zig` (enhance existing)

**Components to add:**

#### A. Register Classification
```zig
/// AAPCS64 calling convention register usage
pub const callee_preserved_regs = [_]Register{
    .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28,
    .x29, // Frame pointer (when used)
    .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15,
};

pub const caller_preserved_regs = [_]Register{
    .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
    .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15,
    .x16, .x17, // IP0, IP1 (intra-procedure call)
    .x18, // Platform register (varies by OS)
    .x30, // Link register
    .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7,
    .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23,
    .v24, .v25, .v26, .v27, .v28, .v29, .v30, .v31,
};

/// Argument registers (integer)
pub const arg_gp_regs = [_]Register{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7 };

/// Argument registers (floating-point/SIMD)
pub const arg_fp_regs = [_]Register{ .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7 };

/// Return value registers
pub const ret_gp_regs = [_]Register{ .x0, .x1 }; // x0 primary, x1 for 128-bit
pub const ret_fp_regs = [_]Register{ .v0, .v1, .v2, .v3 }; // HFA/HVA returns
```

#### B. RegisterManager (ported from x86_64)
```zig
pub const RegisterManager = struct {
    /// Registers currently in use
    registers: [@typeInfo(Register).@"enum".fields.len]?Air.Inst.Index =
        [_]?Air.Inst.Index{null} ** @typeInfo(Register).@"enum".fields.len,

    pub const RegisterLock = struct {
        manager: *RegisterManager,
        reg: Register,

        pub fn release(lock: RegisterLock) void {
            lock.manager.registers[@intFromEnum(lock.reg)] = null;
        }
    };

    pub fn allocReg(
        self: *RegisterManager,
        inst: Air.Inst.Index,
        reg_class: RegisterClass,
    ) !Register {
        // Try to find a free register in the appropriate class
        const regs = switch (reg_class) {
            .gp => &caller_preserved_regs,
            .vector => &arg_fp_regs, // simplified
        };

        for (regs) |reg| {
            if (self.registers[@intFromEnum(reg)] == null) {
                self.registers[@intFromEnum(reg)] = inst;
                return reg;
            }
        }

        return error.OutOfRegisters;
    }

    pub fn isRegFree(self: *const RegisterManager, reg: Register) bool {
        return self.registers[@intFromEnum(reg)] == null;
    }

    pub fn getRegAssumeFree(
        self: *RegisterManager,
        reg: Register,
        inst: Air.Inst.Index,
    ) void {
        assert(self.isRegFree(reg));
        self.registers[@intFromEnum(reg)] = inst;
    }

    pub fn freeReg(self: *RegisterManager, reg: Register) void {
        self.registers[@intFromEnum(reg)] = null;
    }

    pub fn lockReg(self: *RegisterManager, reg: Register) RegisterLock {
        return .{ .manager = self, .reg = reg };
    }
};

pub const RegisterClass = enum {
    gp,    // General purpose (X0-X30)
    vector, // SIMD/FP (V0-V31)
};
```

**Deliverables:**
- [ ] RegisterManager implementation
- [ ] Register allocation tests
- [ ] Calling convention validation
- [ ] Integration with existing abi.zig

**Estimated time:** 2 weeks

---

### 1.3 Create New MIR Definition (Mir_v2.zig)

**Goal:** Define abstract MIR representation (not pre-encoded)

**File:** `src/codegen/aarch64/Mir_v2.zig`

**Structure:**

```zig
//! Machine Intermediate Representation for ARM64
//! Abstract instruction representation before encoding

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

    /// Instruction tags (abstract operations)
    pub const Tag = enum(u16) {
        // Data processing
        add,
        sub,
        mul,
        div,
        and_,
        orr,
        eor,
        lsl,
        lsr,
        asr,

        // Load/store
        ldr,
        str,
        ldp,
        stp,

        // Branches
        b,
        bl,
        br,
        blr,
        ret,

        // Conditional branches
        b_cond,
        cbz,
        cbnz,
        tbz,
        tbnz,

        // Compare
        cmp,
        cmn,
        tst,

        // Conditional select
        csel,
        csinc,
        csinv,
        csneg,

        // Move
        mov,
        movz,
        movk,
        movn,

        // Pseudo instructions (like x86_64)
        pseudo_dbg_prologue_end,
        pseudo_dbg_epilogue_begin,
        pseudo_dbg_line,
        pseudo_enter_frame,
        pseudo_exit_frame,
        pseudo_dead,

        // ... many more
    };

    /// Operand patterns
    pub const Ops = enum(u16) {
        /// No operands
        none,

        /// Register-register: ADD Xd, Xn, Xm
        rrr,

        /// Register-register-immediate: ADD Xd, Xn, #imm
        rri,

        /// Register-register: MOV Xd, Xn
        rr,

        /// Register-immediate: MOV Xd, #imm
        ri,

        /// Register-memory: LDR Xd, [base, offset]
        rm,

        /// Memory-register: STR Xs, [base, offset]
        mr,

        /// Register-register-register-condition: CSEL Xd, Xn, Xm, cond
        rrrc,

        /// Branch target
        rel,

        /// Conditional branch
        rc,

        // ... many more operand patterns

        pseudo_dbg_prologue_end_none,
        pseudo_dbg_epilogue_begin_none,
        // ...
    };

    pub const Data = union {
        /// Three registers
        rrr: struct {
            rd: Register,
            rn: Register,
            rm: Register,
        },
        /// Two registers + immediate
        rri: struct {
            rd: Register,
            rn: Register,
            imm: u32,
        },
        /// Two registers
        rr: struct {
            rd: Register,
            rn: Register,
        },
        /// Register + immediate
        ri: struct {
            rd: Register,
            imm: u64,
        },
        /// Register + memory
        rm: struct {
            rd: Register,
            mem: Memory,
        },
        /// Register + condition
        rc: struct {
            rn: Register,
            cond: Condition,
        },
        /// Relocation target
        rel: struct {
            target: Inst.Index,
        },
        // ... more data types

        // Extra data indirection (like x86_64)
        payload: u32,
    };
};

pub const Local = struct {
    // Similar to x86_64 Mir.Local
};

pub const FrameLoc = struct {
    // Similar to x86_64 Mir.FrameLoc
};

pub fn deinit(mir: *Mir, gpa: Allocator) void {
    // Cleanup
}
```

**Deliverables:**
- [ ] Complete Mir_v2.zig with all ARM64 instructions
- [ ] Data structure definitions
- [ ] Helper functions for MIR construction
- [ ] Documentation of instruction encoding mapping

**Estimated time:** 3 weeks

---

### 1.4 Update Encoding System

**Goal:** Separate encoding from selection

**Current state:** `encoding.zig` has `Instruction` type that's already encoded
**New state:** `Encoding.zig` provides lookup for encoding MIR instructions

**Files:**
- Enhance: `src/codegen/aarch64/encoding.zig`
- Create: `src/codegen/aarch64/Encoding.zig` (lookup tables)
- Create: `src/codegen/aarch64/encoder.zig` (instruction builder)

**Implementation:**

#### encoder.zig (new file)
```zig
//! ARM64 instruction encoding engine

const std = @import("std");
const Mir = @import("Mir_v2.zig");
const bits = @import("bits.zig");
const encoding = @import("encoding.zig");

pub const Instruction = encoding.Instruction; // Keep existing type

/// Build an instruction from MIR
pub fn encode(mir_inst: Mir.Inst) !Instruction {
    return switch (mir_inst.tag) {
        .add => encodeAdd(mir_inst),
        .sub => encodeSub(mir_inst),
        .ldr => encodeLdr(mir_inst),
        .str => encodeStr(mir_inst),
        .b => encodeB(mir_inst),
        .bl => encodeBl(mir_inst),
        // ... all instructions
        else => error.UnhandledInstruction,
    };
}

fn encodeAdd(mir_inst: Mir.Inst) !Instruction {
    return switch (mir_inst.ops) {
        .rrr => {
            const data = mir_inst.data.rrr;
            return Instruction.addSubtractShiftedRegister(.add, .x,
                data.rd.id(), data.rn.id(), data.rm.id(),
                .lsl, 0, false);
        },
        .rri => {
            const data = mir_inst.data.rri;
            return Instruction.addSubtractImmediate(.add, .x,
                data.rd.id(), data.rn.id(),
                @intCast(data.imm), .unshifted, false);
        },
        else => error.InvalidOperands,
    };
}

// ... more encoding functions
```

**Deliverables:**
- [ ] encoder.zig with all instruction encoders
- [ ] Encoding validation
- [ ] Integration with existing encoding.zig
- [ ] Unit tests for each instruction type

**Estimated time:** 3 weeks

---

## Phase 2: CodeGen Rewrite (Estimated: 10-12 weeks)

### 2.1 Create CodeGen_v2.zig Structure

**Goal:** Port x86_64 CodeGen.zig to ARM64

**File:** `src/codegen/aarch64/CodeGen_v2.zig`

**Structure (based on x86_64/CodeGen.zig:867-1017):**

```zig
const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../../codegen.zig");
const link = @import("../../link.zig");
const Air = @import("../../Air.zig");
const Allocator = std.mem.Allocator;
const Mir = @import("Mir_v2.zig");
const Zcu = @import("../../Zcu.zig");
const InternPool = @import("../../InternPool.zig");
const Type = @import("../../Type.zig");
const Value = @import("../../Value.zig");

const abi = @import("abi.zig");
const bits = @import("bits.zig");
const encoder = @import("encoder.zig");

const Condition = bits.Condition;
const Memory = bits.Memory;
const Register = bits.Register;
const RegisterManager = abi.RegisterManager;
const RegisterLock = RegisterManager.RegisterLock;
const FrameIndex = bits.FrameIndex;

const InnerError = codegen.CodeGenError || error{OutOfRegisters};

pub fn legalizeFeatures(_: *const std.Target) *const Air.Legalize.Features {
    // Port from x86_64 - what needs to be scalarized/expanded
    return comptime &.initMany(&.{
        .scalarize_mul_sat,
        .scalarize_div_floor,
        // ... ARM64-specific legalizations
    });
}

const CodeGen = @This();

// Fields (similar to x86_64/CodeGen.zig:85-165)
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

// MIR building
mir_instructions: std.MultiArrayList(Mir.Inst) = .empty,
mir_extra: std.ArrayListUnmanaged(u32) = .empty,
mir_string_bytes: std.ArrayListUnmanaged(u8) = .empty,
mir_locals: std.ArrayListUnmanaged(Mir.Local) = .empty,
mir_table: std.ArrayListUnmanaged(Mir.Inst.Index) = .empty,

// State tracking
inst_tracking: InstTrackingMap = .empty,
blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .empty,
register_manager: RegisterManager = .{},
frame_allocs: std.MultiArrayList(FrameAlloc) = .empty,
frame_locs: std.MultiArrayList(Mir.FrameLoc) = .empty,

/// Machine code value - where a value lives
pub const MCValue = union(enum) {
    none,
    unreach,
    dead: u32,
    undef,
    immediate: u64,
    register: Register,
    register_pair: [2]Register,
    register_offset: bits.RegisterOffset,
    memory: Memory,
    load_frame: FrameAddr,
    // ... similar to x86_64
};

/// Main entry point - port from x86_64/CodeGen.zig:869-1017
pub fn generate(
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) codegen.CodeGenError!Mir {
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
    defer function.deinit();

    // Setup calling convention
    const fn_info = zcu.typeToFunc(fn_type).?;
    var call_info = try function.resolveCallingConventionValues(fn_info);
    defer call_info.deinit(&function);

    function.args = call_info.args;
    function.ret_mcv = call_info.return_value;

    // Generate MIR from AIR
    try function.gen();

    // Return MIR
    var mir: Mir = .{
        .instructions = function.mir_instructions.toOwnedSlice(),
        .extra = try function.mir_extra.toOwnedSlice(gpa),
        // ...
    };
    return mir;
}

/// Generate MIR from AIR
fn gen(self: *CodeGen) !void {
    const air_tags = self.air.instructions.items(.tag);
    const air_data = self.air.instructions.items(.data);

    for (self.air.getMainBody()) |inst| {
        // Track liveness
        const old_tracking = self.inst_tracking.get(inst);
        // ...

        // Generate instruction
        switch (air_tags[@intFromEnum(inst)]) {
            .add => try self.airAdd(inst),
            .sub => try self.airSub(inst),
            .mul => try self.airMul(inst),
            .load => try self.airLoad(inst),
            .store => try self.airStore(inst),
            .ret => try self.airRet(inst),
            // ... all AIR instructions
            else => return self.fail("TODO: ARM64 {s}", .{@tagName(air_tags[@intFromEnum(inst)])}),
        }
    }
}

// AIR instruction handlers
fn airAdd(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    // Allocate destination register
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    // Generate MIR add instruction
    switch (rhs) {
        .immediate => |imm| {
            try self.addInst(.{
                .tag = .add,
                .ops = .rri,
                .data = .{ .rri = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .imm = @intCast(imm),
                }},
            });
        },
        .register => |rhs_reg| {
            try self.addInst(.{
                .tag = .add,
                .ops = .rrr,
                .data = .{ .rrr = .{
                    .rd = dst_reg,
                    .rn = lhs.register,
                    .rm = rhs_reg,
                }},
            });
        },
        else => return self.fail("TODO: add with {s}", .{@tagName(rhs)}),
    }

    // Track result
    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

// ... many more airXxx functions (port from x86_64)
```

**Deliverables:**
- [ ] CodeGen_v2.zig structure
- [ ] generate() function
- [ ] gen() main loop
- [ ] Basic AIR handlers (add, sub, load, store, ret)
- [ ] Register allocation integration
- [ ] Calling convention setup

**Estimated time:** 4 weeks

---

### 2.2 Implement AIR Instruction Handlers

**Goal:** Implement all ~150+ AIR instruction handlers

**Approach:**
1. Start with arithmetic: add, sub, mul, div
2. Load/store operations
3. Comparisons and branches
4. Control flow
5. Advanced operations

**Example implementations:**

#### Load/Store
```zig
fn airLoad(self: *CodeGen, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const ptr = try self.resolveInst(ty_op.operand);
    const dst_reg = try self.register_manager.allocReg(inst, .gp);

    switch (ptr) {
        .register => |ptr_reg| {
            try self.addInst(.{
                .tag = .ldr,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = dst_reg,
                    .mem = Memory.simple(ptr_reg, 0),
                }},
            });
        },
        .memory => |mem| {
            // LDR Xd, [mem]
            try self.addInst(.{
                .tag = .ldr,
                .ops = .rm,
                .data = .{ .rm = .{
                    .rd = dst_reg,
                    .mem = mem,
                }},
            });
        },
        else => return self.fail("TODO: load from {s}", .{@tagName(ptr)}),
    }

    try self.inst_tracking.put(self.gpa, inst, .init(.{ .register = dst_reg }));
}

fn airStore(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs);
    const val = try self.resolveInst(bin_op.rhs);

    const val_reg = switch (val) {
        .register => |r| r,
        .immediate => |imm| blk: {
            const tmp = try self.register_manager.allocReg(inst, .gp);
            try self.genSetReg(tmp, imm);
            break :blk tmp;
        },
        else => return self.fail("TODO: store {s}", .{@tagName(val)}),
    };

    switch (ptr) {
        .register => |ptr_reg| {
            try self.addInst(.{
                .tag = .str,
                .ops = .mr,
                .data = .{ .mr = .{
                    .rs = val_reg,
                    .mem = Memory.simple(ptr_reg, 0),
                }},
            });
        },
        else => return self.fail("TODO: store to {s}", .{@tagName(ptr)}),
    }
}
```

#### Comparison and Branch
```zig
fn airCmp(self: *CodeGen, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);

    const lhs_reg = switch (lhs) {
        .register => |r| r,
        else => blk: {
            const tmp = try self.register_manager.allocReg(inst, .gp);
            try self.genCopy(tmp, lhs);
            break :blk tmp;
        },
    };

    switch (rhs) {
        .immediate => |imm| {
            try self.addInst(.{
                .tag = .cmp,
                .ops = .ri,
                .data = .{ .ri = .{
                    .rd = lhs_reg,
                    .imm = @intCast(imm),
                }},
            });
        },
        .register => |rhs_reg| {
            try self.addInst(.{
                .tag = .cmp,
                .ops = .rr,
                .data = .{ .rr = .{
                    .rd = lhs_reg,
                    .rn = rhs_reg,
                }},
            });
        },
        else => return self.fail("TODO: cmp with {s}", .{@tagName(rhs)}),
    }

    // Result is in condition flags (NZCV)
    try self.inst_tracking.put(self.gpa, inst, .init(.condition_flags));
}

fn airBr(self: *CodeGen, inst: Air.Inst.Index) !void {
    const br = self.air.instructions.items(.data)[@intFromEnum(inst)].br;
    const target_block = self.blocks.get(br.target).?;

    // Generate branch instruction
    try self.addInst(.{
        .tag = .b,
        .ops = .rel,
        .data = .{ .rel = .{
            .target = target_block.first_inst,
        }},
    });
}
```

**Deliverables (incremental):**
- [ ] Week 1: Arithmetic (add, sub, mul, div, bitwise)
- [ ] Week 2: Load/store, memory operations
- [ ] Week 3: Comparison, branches, control flow
- [ ] Week 4: Calls, returns, stack operations
- [ ] Week 5: Advanced (SIMD, atomics, etc.)
- [ ] Week 6: Testing and bug fixes

**Estimated time:** 6 weeks

---

## Phase 3: Lower & Emit (Estimated: 8-10 weeks)

### 3.1 Implement Lower.zig

**Goal:** Convert abstract MIR to encoded instructions

**File:** `src/codegen/aarch64/Lower.zig`

**Structure:**

```zig
const std = @import("std");
const Mir = @import("Mir_v2.zig");
const encoder = @import("encoder.zig");
const encoding = @import("encoding.zig");
const link = @import("../../link.zig");

allocator: std.mem.Allocator,
mir: Mir,
cc: std.builtin.CallingConvention,
src_loc: Zcu.LazySrcLoc,
target: *const std.Target,

instructions: std.ArrayListUnmanaged(encoding.Instruction) = .empty,
relocations: std.ArrayListUnmanaged(Relocation) = .empty,

pub const Relocation = struct {
    source: u32, // Instruction offset
    target: u32, // Target offset or symbol
    type: Type,

    pub const Type = enum {
        branch,
        adrp_page,
        add_pageoff,
        literal,
    };
};

pub fn lowerMir(self: *Lower) !void {
    for (self.mir.instructions.items(.tag), 0..) |tag, i| {
        const inst = self.mir.instructions.get(@intCast(i));
        try self.lowerInst(inst, @intCast(i));
    }
}

fn lowerInst(self: *Lower, inst: Mir.Inst, index: Mir.Inst.Index) !void {
    switch (inst.tag) {
        .add => try self.lowerAdd(inst),
        .sub => try self.lowerSub(inst),
        .ldr => try self.lowerLdr(inst),
        .str => try self.lowerStr(inst),
        .b => try self.lowerBranch(inst, index),
        .bl => try self.lowerBranchLink(inst, index),
        .b_cond => try self.lowerBranchCond(inst, index),
        // ... all MIR tags

        .pseudo_dbg_prologue_end,
        .pseudo_dbg_epilogue_begin,
        => {}, // No-op for non-debug builds

        else => std.debug.panic("TODO: lower {s}", .{@tagName(inst.tag)}),
    }
}

fn lowerAdd(self: *Lower, inst: Mir.Inst) !void {
    const encoded = try encoder.encode(inst);
    try self.instructions.append(self.allocator, encoded);
}

fn lowerBranch(self: *Lower, inst: Mir.Inst, index: Mir.Inst.Index) !void {
    const target = inst.data.rel.target;

    // Calculate offset (will be fixed up in emit)
    const source_offset: u32 = @intCast(self.instructions.items.len);

    // Placeholder instruction
    try self.instructions.append(self.allocator, encoding.Instruction.b(0));

    // Record relocation
    try self.relocations.append(self.allocator, .{
        .source = source_offset,
        .target = target,
        .type = .branch,
    });
}

fn lowerLdr(self: *Lower, inst: Mir.Inst) !void {
    const data = inst.data.rm;
    const mem = data.mem;

    // ARM64 has load literal for PC-relative loads
    switch (mem.offset) {
        .immediate => |imm| {
            // LDR Xd, [Xn, #imm]
            const encoded = encoding.Instruction.loadStoreRegisterImmediate(
                .ldr, .x, data.rd.id(), mem.base.id(), @intCast(imm));
            try self.instructions.append(self.allocator, encoded);
        },
        .register => |reg_off| {
            // LDR Xd, [Xn, Xm, LSL #shift]
            const encoded = encoding.Instruction.loadStoreRegisterRegisterOffset(
                .ldr, .x, data.rd.id(), mem.base.id(), reg_off.reg.id());
            try self.instructions.append(self.allocator, encoded);
        },
        else => return error.UnsupportedAddressingMode,
    }
}
```

**Key challenges:**

1. **Branch offset calculation:** ARM64 branches use PC-relative offsets
   - 26-bit signed offset for `B` (±128MB range)
   - 19-bit signed offset for `B.cond` (±1MB range)
   - Must be calculated after all instructions are known

2. **Literal pool management:** Large constants need literal pool
   ```zig
   // Large immediate that doesn't fit in MOVZ/MOVK
   const val: u64 = 0x123456789abcdef0;

   // Generate:
   // ldr x0, .Lliteral_0
   // ...
   // .Lliteral_0:
   //   .quad 0x123456789abcdef0
   ```

3. **ADRP + ADD pairs for position-independent code:**
   ```zig
   // Load address of symbol
   // ADRP x0, symbol@PAGE
   // ADD x0, x0, symbol@PAGEOFF
   ```

**Deliverables:**
- [ ] Lower.zig implementation
- [ ] All instruction lowering
- [ ] Branch offset calculation
- [ ] Literal pool generation
- [ ] Relocation tracking
- [ ] Unit tests

**Estimated time:** 4 weeks

---

### 3.2 Implement Emit.zig

**Goal:** Emit final machine code with relocations and debug info

**File:** `src/codegen/aarch64/Emit.zig`

**Structure:**

```zig
const std = @import("std");
const Mir = @import("Mir_v2.zig");
const Lower = @import("Lower.zig");
const encoding = @import("encoding.zig");
const link = @import("../../link.zig");
const Zcu = @import("../../Zcu.zig");

pub fn emitMir(
    mir: Mir,
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    atom_index: u32,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) !void {
    var lower: Lower = .{
        .allocator = pt.zcu.gpa,
        .mir = mir,
        .cc = .auto,
        .src_loc = src_loc,
        .target = &pt.zcu.comp.root_mod.resolved_target.result,
    };
    defer lower.deinit();

    // Lower MIR to instructions
    try lower.lowerMir();

    // Write instructions to output
    for (lower.instructions.items) |inst| {
        try w.writeInt(u32, @bitCast(inst), .little);
    }

    // Apply relocations
    try applyRelocations(lower.relocations.items, w);

    // Generate DWARF debug info
    if (debug_output != .none) {
        try emitDebugInfo(mir, bin_file, pt, func_index, debug_output);
    }
}

fn applyRelocations(relocs: []const Lower.Relocation, w: *std.Io.Writer) !void {
    for (relocs) |reloc| {
        switch (reloc.type) {
            .branch => {
                // Calculate branch offset
                const offset: i32 = @intCast(reloc.target - reloc.source);
                const offset_words = @divExact(offset, 4);

                // Read current instruction
                w.seekTo(reloc.source * 4);
                var inst: u32 = try w.readInt(u32, .little);

                // Patch in offset (26 bits for B, 19 bits for B.cond)
                inst |= @as(u32, @intCast(offset_words & 0x3FFFFFF));

                // Write back
                w.seekTo(reloc.source * 4);
                try w.writeInt(u32, inst, .little);
            },
            .adrp_page => {
                // ADRP relocation
                // ...
            },
            .literal => {
                // Literal pool relocation
                // ...
            },
            else => return error.UnhandledRelocation,
        }
    }
}

fn emitDebugInfo(
    mir: Mir,
    bin_file: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    debug_output: link.File.DebugInfoOutput,
) !void {
    // Generate DWARF .debug_line, .debug_frame, etc.
    // CFI directives for stack unwinding
    // Similar to x86_64/Emit.zig

    // ARM64-specific:
    // - FP/LR save locations
    // - Stack pointer adjustments
    // - CFA (Canonical Frame Address) tracking
}
```

**Deliverables:**
- [ ] Emit.zig implementation
- [ ] Machine code output
- [ ] Relocation application
- [ ] DWARF debug info generation
- [ ] CFI directives
- [ ] Integration tests

**Estimated time:** 4 weeks

---

## Phase 4: Integration & Testing (Estimated: 6-8 weeks)

### 4.1 Enable Liveness Analysis

**File:** `src/codegen.zig`

**Change:**
```zig
pub fn wantsLiveness(pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) bool {
    const zcu = pt.zcu;
    const target = &zcu.navFileScope(nav_index).mod.?.resolved_target.result;
    return switch (target_util.zigBackend(target, zcu.comp.config.use_llvm)) {
        else => true,
        // REMOVE THIS:
        // .stage2_aarch64 => false,
    };
}
```

### 4.2 Wire Up New Backend

**File:** `src/codegen/aarch64.zig`

**Add feature flag:**
```zig
const use_v2_backend = @import("builtin").zig_backend_v2_aarch64 orelse false;

pub fn generate(
    bin_file: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) !Mir {
    if (use_v2_backend) {
        return @import("aarch64/CodeGen_v2.zig").generate(
            bin_file, pt, src_loc, func_index, air, liveness);
    } else {
        // Keep old backend as fallback
        return @import("aarch64/Select.zig").generate(
            bin_file, pt, src_loc, func_index, air, liveness);
    }
}
```

### 4.3 Testing Strategy

#### Unit Tests
```zig
// In bits.zig
test "condition code negation" {
    try std.testing.expectEqual(Condition.ne, Condition.eq.negate());
    try std.testing.expectEqual(Condition.lt, Condition.ge.negate());
}

// In encoder.zig
test "encode ADD immediate" {
    const inst = Mir.Inst{
        .tag = .add,
        .ops = .rri,
        .data = .{ .rri = .{ .rd = .x0, .rn = .x1, .imm = 42 }},
    };
    const encoded = try encoder.encode(inst);
    // Verify encoding matches ARM spec
}
```

#### Integration Tests
```zig
// Test simple function compilation
test "codegen simple function" {
    const source =
        \\fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;

    // Compile with new backend
    // Verify generated code
}
```

#### Behavior Tests
- Run entire Zig test suite with new backend
- Compare output with old backend
- Verify on real ARM64 hardware (M1/M2 Mac, Linux ARM64)

**Deliverables:**
- [ ] Unit tests for all components
- [ ] Integration tests
- [ ] Behavior test suite passing
- [ ] Performance benchmarks
- [ ] Bug fixes from testing

**Estimated time:** 6 weeks

---

## File Structure

### New Files to Create

```
src/codegen/aarch64/
├── bits.zig              [NEW] ARM64 types (Condition, Register, Memory, etc.)
├── CodeGen_v2.zig        [NEW] Main code generator (AIR → MIR)
├── Mir_v2.zig            [NEW] Abstract MIR definition
├── Lower.zig             [NEW] MIR → Instruction lowering
├── Emit.zig              [NEW] Instruction → Machine code emission
├── encoder.zig           [NEW] Instruction encoding engine
├── Encoding.zig          [NEW] Encoding lookup tables
├── encodings.zon         [NEW] Instruction database (convert instructions.zon)
├── abi.zig               [ENHANCE] Add RegisterManager
├── encoding.zig          [KEEP] Existing instruction types
├── Select.zig            [KEEP] Old backend (fallback)
├── Mir.zig               [KEEP] Old MIR (fallback)
└── Assemble.zig          [KEEP] Old assembler (fallback)
```

### Modified Files

```
src/
├── codegen.zig           [MODIFY] Enable liveness for aarch64
└── codegen/
    └── aarch64.zig       [MODIFY] Wire up new backend with feature flag
```

---

## Timeline & Milestones

### Phase 1: Foundation (Weeks 1-10)
- **Week 1-2:** bits.zig implementation ✓
- **Week 3-4:** RegisterManager in abi.zig ✓
- **Week 5-7:** Mir_v2.zig definition ✓
- **Week 8-10:** encoder.zig + Encoding.zig ✓

**Milestone 1:** Can represent ARM64 instructions abstractly

### Phase 2: CodeGen (Weeks 11-22)
- **Week 11-14:** CodeGen_v2.zig structure + basic AIR handlers ✓
- **Week 15-16:** Arithmetic operations ✓
- **Week 17-18:** Load/store operations ✓
- **Week 19-20:** Control flow ✓
- **Week 21-22:** Advanced operations ✓

**Milestone 2:** Can generate MIR from AIR

### Phase 3: Lower & Emit (Weeks 23-32)
- **Week 23-26:** Lower.zig implementation ✓
- **Week 27-30:** Emit.zig implementation ✓
- **Week 31-32:** Debug info generation ✓

**Milestone 3:** Can generate machine code

### Phase 4: Integration (Weeks 33-40)
- **Week 33-34:** Wire up new backend ✓
- **Week 35-36:** Unit testing ✓
- **Week 37-38:** Integration testing ✓
- **Week 39-40:** Bug fixes and optimization ✓

**Milestone 4:** New backend passes tests

### Total: 40 weeks (~9-10 months) with 1-2 developers

---

## Testing Strategy

### Level 1: Unit Tests
- Test each component in isolation
- bits.zig: condition codes, registers, memory
- encoder.zig: instruction encoding correctness
- abi.zig: register allocation, calling conventions

### Level 2: Integration Tests
- CodeGen_v2 generates valid MIR
- Lower produces correct instructions
- Emit generates valid machine code

### Level 3: Behavior Tests
- Run Zig test suite
- Compare old vs new backend output
- Cross-compile and run on ARM64 hardware

### Level 4: Performance Tests
- Code size comparisons
- Execution speed benchmarks
- Compilation speed measurements

### Level 5: Real-World Testing
- Build Zig compiler itself with new backend
- Build large projects (std lib, real applications)
- Stress test on various ARM64 targets

---

## Rollout Plan

### Stage 1: Experimental (Weeks 33-36)
```bash
# Enable with flag
zig build -Dzig_backend_v2_aarch64=true
```
- Default: OFF
- Testing by core developers only
- Known issues expected

### Stage 2: Opt-in Beta (Weeks 37-40)
```bash
# Announce to community
# Encourage testing
zig build -Dzig_backend_v2_aarch64=true
```
- Default: OFF
- Open to adventurous users
- Bug reports tracked

### Stage 3: Opt-out Preview (Week 41+)
```bash
# New backend default, old available
zig build -Dzig_backend_v2_aarch64=false # to disable
```
- Default: ON (new backend)
- Old backend available for comparison
- Migration issues addressed

### Stage 4: Full Deployment (Week 45+)
- Default: ON (only option)
- Remove old backend code
- Celebrate! 🎉

---

## Risk Mitigation

### Risk 1: Performance Regression
**Mitigation:**
- Continuous benchmarking during development
- Keep old backend as fallback
- Performance must meet or exceed old backend before default switch

### Risk 2: Correctness Issues
**Mitigation:**
- Extensive testing at each phase
- Differential testing (compare old vs new)
- Fuzzing with random AIR inputs
- Real hardware testing

### Risk 3: Timeline Overrun
**Mitigation:**
- Conservative estimates (9-10 months)
- Modular phases allow partial delivery
- Feature flag allows incremental rollout
- Can pause and resume work

### Risk 4: Incompatibility with Old Backend
**Mitigation:**
- Keep old backend functional during transition
- Feature flag for easy switching
- Document migration issues
- Provide migration guide

---

## Success Criteria

### Must Have ✅
- [ ] All Zig test suite passes on ARM64
- [ ] Performance equal or better than old backend
- [ ] Code size equal or better than old backend
- [ ] Compilation speed acceptable (<20% slower)
- [ ] Works on all ARM64 targets (Darwin, Linux, Windows)

### Should Have 🎯
- [ ] Better register allocation than old backend
- [ ] Cleaner, more maintainable code
- [ ] Shared patterns with x86_64 backend
- [ ] Good documentation

### Nice to Have 💡
- [ ] Faster compilation than old backend
- [ ] Smaller code than old backend
- [ ] Better debug info
- [ ] Easier to extend

---

## Resources Required

### People
- **1-2 Senior Compiler Engineers**
  - Deep understanding of ARM64 ISA
  - Experience with Zig compiler internals
  - Familiar with x86_64 backend architecture

### Hardware
- **ARM64 test machines:**
  - Mac M1/M2/M3 (Darwin)
  - Raspberry Pi 4/5 (Linux)
  - AWS Graviton instances (Linux)
  - Windows ARM64 (Surface Pro X or VM)

### Tools
- ARM64 documentation (ARM ARM)
- Disassemblers (objdump, llvm-objdump)
- Debuggers (gdb, lldb)
- Profilers (perf, Instruments)

---

## Next Steps

### Immediate (Week 1)
1. Review this plan with Zig core team
2. Get approval and resourcing
3. Set up development branch
4. Create initial file stubs

### Short-term (Weeks 2-4)
1. Implement bits.zig
2. Start RegisterManager in abi.zig
3. Begin Mir_v2.zig design
4. Set up CI for new backend

### Medium-term (Weeks 5-12)
1. Complete Phase 1 (Foundation)
2. Begin Phase 2 (CodeGen)
3. Weekly progress reviews
4. Adjust timeline as needed

---

## Conclusion

This modernization will bring the aarch64 backend in line with the x86_64 backend's architecture, improving code quality, maintainability, and performance. The incremental approach with feature flags ensures we can develop and test safely while maintaining the working old backend as a fallback.

**Estimated effort:** 9-10 months with 1-2 experienced developers

**Risk level:** Medium (mitigated by incremental rollout)

**Value:** High (modernized ARM64 backend, shared architecture patterns)

---

## Appendix A: ARM64 Quick Reference

### Instruction Format
All ARM64 instructions are 32 bits:
```
31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16  15  14  13  12  11  10  9   8   7   6   5   4   3   2   1   0
[-- op0 --][--- op1 ---][-- op2 --][------------- instruction-specific fields -----------------------]
```

### Common Instruction Encodings

**Data Processing (register):**
```
ADD Xd, Xn, Xm
31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9  8  7  6  5  4  3  2  1  0
sf  0  0  0  1  0  1  1  0  0  0  [-- Rm --] [- imm6 -] [-- Rn --] [-- Rd --]
```

**Load/Store:**
```
LDR Xt, [Xn, #imm]
31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9  8  7  6  5  4  3  2  1  0
sz V  0  0  1  0  0  1  [- imm12 -] [-- Rn --] [-- Rt --]
```

**Branch:**
```
B label
31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9  8  7  6  5  4  3  2  1  0
0  0  0  1  0  1  [---------------------------- imm26 ----------------------------]
```

### Registers
- **X0-X30:** 64-bit general purpose
- **W0-W30:** 32-bit (lower half of X regs)
- **V0-V31:** 128-bit SIMD/FP
- **XZR/WZR:** Zero register
- **SP:** Stack pointer
- **X29:** Frame pointer (FP)
- **X30:** Link register (LR)

---

**End of Modernization Plan**
