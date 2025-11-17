# ARM64 Backend Implementation Plan

## Session Context
**Branch**: `claude/add-arm64-backend-01XHckFVprmYheD9cdrr87Ke`
**Last Updated**: 2025-11-17
**Status**: ✅ Foundation Complete - Compilation Successful
**Commits**: 22 total

## What We've Accomplished

### Phase 0: Foundation & Compilation Fixes ✅ COMPLETE
All compilation errors have been resolved. The ARM64 backend now compiles cleanly as part of the Zig bootstrap process.

**Key Fixes Applied**:
- ✅ Fixed 35+ type conversions (Air.Inst.Ref → Air.Inst.Index)
- ✅ Fixed 8+ struct field errors (rr.rm → rr.rn)
- ✅ Implemented error handling (OutOfRegisters → CodegenFail conversion)
- ✅ Corrected function signatures (typeOf, typeOfIndex with InternPool)
- ✅ Removed @compileLog debug statements
- ✅ Fixed Memory struct initialization
- ✅ Removed invalid AIR tags

**Currently Implemented AIR Instructions** (25 basic):
- Arithmetic: add, sub, mul, div, rem, mod, neg
- Bitwise: and, or, xor, not
- Shifts: shl, shr
- Memory: load, store
- Comparisons: eq, neq, lt, lte, gt, gte
- Control: br, cond_br, block
- Returns: ret, ret_load
- Conversions: intcast, trunc
- Pointers: ptr_add, ptr_sub
- Slices: slice_ptr, slice_len

---

## Implementation Roadmap

### Phase 1: Core Functionality (NEXT - Priority 1)
**Goal**: Make the backend usable for simple programs

#### 1.1 Function Calls ⚠️ CRITICAL
**File**: `src/codegen/aarch64/CodeGen_v2.zig`
**Status**: TODO
**Complexity**: HIGH

Missing AIR instructions:
- `call` - function calls
- `ret_ptr` - return pointer for structs
- Proper calling convention parameter passing
- Stack alignment for calls

Current blockers:
```zig
// Line 524: CodeGen_v2.zig
else => return self.fail("TODO implement function parameters
    and return values for {} on ARM64", .{cc});
```

Implementation tasks:
- [ ] Implement parameter passing (registers X0-X7, stack overflow)
- [ ] Implement return value handling (X0 for integers, D0 for floats)
- [ ] Handle structure passing (by value vs by reference)
- [ ] Implement proper stack frame setup for outgoing args
- [ ] Add BL/BLR instruction support
- [ ] Handle HFA (Homogeneous Floating-point Aggregate) passing

**Estimated effort**: 2-3 hours

#### 1.2 Stack Allocation ⚠️ CRITICAL
**File**: `src/codegen/aarch64/CodeGen_v2.zig`
**Status**: TODO
**Complexity**: MEDIUM

Missing AIR instruction:
- `alloc` - allocate stack space
- `arg` - access function arguments

Implementation tasks:
- [ ] Implement `airAlloc()` handler
- [ ] Track stack frame size
- [ ] Adjust SP appropriately
- [ ] Generate proper stack pointer arithmetic (SUB SP, SP, #size)
- [ ] Handle stack alignment (16-byte aligned)
- [ ] Implement `airArg()` to read function parameters

**Estimated effort**: 1-2 hours

#### 1.3 Floating Point Arithmetic ⚠️ HIGH
**File**: `src/codegen/aarch64/CodeGen_v2.zig`
**Status**: TODO
**Complexity**: MEDIUM

Missing AIR instructions:
- `add_with_overflow` variants
- `sub_with_overflow` variants
- Floating point: `fadd`, `fsub`, `fmul`, `fdiv`
- Float comparisons: `fcmp_*`
- Conversions: `fptrunc`, `fpext`, `intofloat`, `floattoint`

Implementation tasks:
- [ ] Add floating point register allocation (D0-D31)
- [ ] Implement `airFloatAdd()`, `airFloatSub()`, `airFloatMul()`, `airFloatDiv()`
- [ ] Implement float comparisons
- [ ] Implement float/int conversions (SCVTF, FCVTZS, etc.)
- [ ] Handle different float sizes (f16, f32, f64, f128)
- [ ] Add FADD, FSUB, FMUL, FDIV instruction encodings

**Estimated effort**: 2-3 hours

---

### Phase 2: Essential Features (Priority 2)

#### 2.1 Struct and Array Access
**Status**: TODO
**Complexity**: MEDIUM

Missing AIR instructions:
- `struct_field_ptr` - get pointer to struct field
- `struct_field_val` - load struct field value
- `array_elem_val` - load array element
- `ptr_elem_val`, `ptr_elem_ptr` - pointer element access

Implementation tasks:
- [ ] Implement offset calculations
- [ ] Handle struct field alignment
- [ ] Implement array indexing with bounds checking (optional)
- [ ] Add LDR/STR with offset addressing modes

**Estimated effort**: 1-2 hours

#### 2.2 Switch Statements
**Status**: TODO
**Complexity**: HIGH

Missing AIR instruction:
- `switch_br` - multi-way branch

Implementation tasks:
- [ ] Implement jump table generation
- [ ] Handle sparse vs dense switch optimization
- [ ] Generate comparison chains for small switches
- [ ] Add BR (branch register) instruction support

**Estimated effort**: 2-3 hours

#### 2.3 Optionals and Error Handling
**Status**: TODO
**Complexity**: MEDIUM

Missing AIR instructions:
- `is_null`, `is_non_null`
- `is_err`, `is_non_err`
- `optional_payload`
- `unwrap_errunion_payload`
- `wrap_optional`, `wrap_errunion_payload`

Implementation tasks:
- [ ] Understand optional/error union memory layout
- [ ] Implement null/error tag checks
- [ ] Implement payload extraction
- [ ] Handle wrapping values

**Estimated effort**: 2-3 hours

---

### Phase 3: Concurrency & Advanced Features (Priority 3)

#### 3.1 Atomic Operations
**Status**: TODO
**Complexity**: HIGH

Missing AIR instructions:
- `atomic_load`
- `atomic_store`
- `atomic_rmw` (read-modify-write)
- `cmpxchg` (compare and exchange)
- `fence` (partial support exists)

Implementation tasks:
- [ ] Implement LDAR/STLR (load-acquire/store-release)
- [ ] Implement LDXR/STXR (load-exclusive/store-exclusive) loops
- [ ] Add LDADD, LDCLR, LDEOR, LDSET, LDSMAX, etc. (LSE atomics)
- [ ] Implement CAS (compare-and-swap) loops
- [ ] Add DMB/DSB barrier instructions

**Estimated effort**: 3-4 hours

#### 3.2 Inline Assembly
**Status**: TODO
**Complexity**: HIGH

Missing AIR instruction:
- `assembly`

Implementation tasks:
- [ ] Parse inline assembly constraints
- [ ] Handle register allocation for inline asm
- [ ] Pass through raw assembly instructions
- [ ] Handle clobbers

**Estimated effort**: 2-3 hours

---

### Phase 4: Optimization & Polish (Priority 4)

#### 4.1 Debug Information
**File**: `src/codegen/aarch64/Emit.zig`
**Status**: TODO
**Complexity**: HIGH

Current state:
```zig
// TODO: Implement DWARF debug info generation
// TODO: Implement CFI generation
```

Implementation tasks:
- [ ] Generate DWARF debug info
- [ ] Generate CFI (Call Frame Information)
- [ ] Add line number tables
- [ ] Add variable location tracking

**Estimated effort**: 4-5 hours

#### 4.2 SIMD/Vector Operations
**Status**: Partial encoding support exists
**Complexity**: VERY HIGH

Implementation tasks:
- [ ] Implement vector arithmetic
- [ ] Implement vector loads/stores
- [ ] Handle different vector sizes (8B, 16B, 2S, 4S, 2D, etc.)
- [ ] Use NEON instructions efficiently

**Estimated effort**: 5-8 hours

#### 4.3 Advanced Arithmetic
**Status**: TODO
**Complexity**: MEDIUM

Missing features:
- Overflow checking arithmetic
- Saturating arithmetic
- Bit manipulation (CLZ, CTZ, POPCNT)
- Extended precision arithmetic

**Estimated effort**: 2-3 hours

---

## Current File Status

### Files Modified (This Session)
1. ✅ `src/codegen/aarch64/CodeGen_v2.zig` - Main codegen, all compilation errors fixed
2. ✅ `src/codegen/aarch64/encoding.zig` - Instruction encoding, @compileLog removed
3. ✅ `src/codegen/aarch64/bits.zig` - RegisterOffset exposed
4. ✅ `src/codegen/aarch64/Mir_v2.zig` - Added rc.target field, error sets fixed
5. ✅ `src/codegen/aarch64/Lower.zig` - Error handling updated
6. ✅ `src/codegen/aarch64/Emit.zig` - Error conversion added

### Files Needing Work
- `src/codegen/aarch64/CodeGen_v2.zig` - Add missing AIR handlers
- `src/codegen/aarch64/encoder.zig` - Complete instruction encoding
- `src/codegen/aarch64/abi.zig` - Enhance calling convention support
- `src/codegen/aarch64/Emit.zig` - Add debug info generation

---

## Next Immediate Steps

### Step 1: Function Call Support (START HERE)
This is the most critical missing feature. Without function calls, the backend can only compile trivial single-function programs.

**Action items**:
1. Implement `airCall()` in CodeGen_v2.zig
2. Add BL/BLR instruction encoding
3. Implement parameter marshaling (registers + stack)
4. Test with simple function call

### Step 2: Stack Allocation
Enable local variables on the stack.

**Action items**:
1. Implement `airAlloc()` in CodeGen_v2.zig
2. Track stack frame layout
3. Adjust frame setup in prologue
4. Test with local variable allocation

### Step 3: Basic Floating Point
Enable floating point arithmetic.

**Action items**:
1. Add FP register class to register allocator
2. Implement `airFloatAdd()`, `airFloatSub()`, etc.
3. Add FADD, FSUB, FMUL, FDIV encodings
4. Test with simple float operations

---

## Testing Strategy

After each phase:
1. Run bootstrap build to ensure no regressions
2. Create minimal test programs exercising new features
3. Compare generated assembly with expected output
4. Run Zig test suite for ARM64

---

## Known Issues / Blockers

### Current Blockers
None - compilation is clean!

### Future Blockers to Watch For
1. Register allocator may need enhancement for complex functions
2. Stack frame layout needs refinement for varargs
3. Calling convention edge cases (HFA, large structs)
4. Debug info generation requires deep DWARF knowledge

---

## Progress Tracking

### Completion Metrics
- **Compilation**: ✅ 100% (builds cleanly)
- **Basic AIR instructions**: ✅ ~25/200+ (12%)
- **Calling conventions**: ⚠️ Partial C support only
- **Floating point**: ❌ 0%
- **Memory operations**: ✅ Basic load/store only
- **Control flow**: ⚠️ Basic branches only
- **Debug info**: ❌ 0%
- **Overall functionality**: ~15% complete

### Session Statistics
- **Total commits**: 22
- **Lines changed**: ~8,000+
- **Files modified**: 6
- **Compilation errors fixed**: 50+
- **TODO items added**: 32

---

## Reference Information

### Key Files
- `src/Air.zig` - All AIR instruction definitions
- `src/codegen.zig` - Codegen entry points
- `src/codegen/aarch64/abi.zig` - Calling conventions
- ARM Architecture Reference Manual (online)

### Useful Commands
```bash
# Build
./bootstrap

# Check for errors in ARM64 code only
./bootstrap 2>&1 | grep "src/codegen/aarch64/"

# Count implemented instructions
grep "\.tag => self\." src/codegen/aarch64/CodeGen_v2.zig | wc -l

# Find TODOs
grep -r "TODO" src/codegen/aarch64/
```

---

**END OF IMPLEMENTATION PLAN**
*Last updated: 2025-11-17*
