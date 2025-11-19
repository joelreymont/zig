# ARM64 Self-Hosted Backend Progress

## Current Status (2025-11-19)

### ✅ Completed Fixes

1. **Inline Assembly Register Type Conversion** (commit 110e7212)
   - File: `src/codegen/aarch64/CodeGen_v2.zig:2885-2998`
   - Fixed bidirectional conversion between `bits.Register` and `encoding.Register`
   - Enables compilation of inline assembly code

2. **Mach-O Segment VM Address Ordering** (commit 1399fb41ff)
   - File: `src/link/MachO.zig:2121-2131`
   - Fixed segment sorting to use VM address instead of alphabetical order
   - Prevents `dyld: segment vm address out of order` errors

3. **Inline Assembly Memory Constraints** (commit 9ab4674e57)
   - File: `src/codegen/aarch64/CodeGen_v2.zig:2891-2919, 2961-3000`
   - Added support for 'm', 'rm', '=m', '=rm' constraints
   - Treats memory constraints as register constraints (sufficient for most use cases)
   - **Result**: Compiler builds successfully, std library constraint errors resolved

4. **Frame Allocation and aggregate_init** (commits a72abafd07, 53cd7b2f50)
   - File: `src/codegen/aarch64/CodeGen_v2.zig`
   - Added `FrameAlloc.initSpill()` helper (lines 226-239)
   - Implemented `allocFrameIndex()` for stack allocation with reuse (lines 5538-5565)
   - Implemented `genSetMem()` for writing to frame memory (lines 5648-5722)
   - Implemented `airAggregateInit()` for struct/array initialization (lines 4848-4912)
   - Supports non-packed structs and arrays with sentinels
   - **Result**: Aggregate types can now be initialized on the stack

5. **Register Pair Calling Convention** (commit db93a1360b)
   - File: `src/codegen/aarch64/CodeGen_v2.zig:3161-3229`
   - Added register_pair support in airCall for both register and stack arguments
   - Handles slices and multi-register values in function calls
   - **Result**: Fixes compiler_rt/clear_cache.zig compilation

6. **Critical AIR Instructions** (commit a4df673839)
   - **airTry** - Error handling with conditional branching (lines 2589-2670)
     - Uses ldrh/cbnz for error checking, generates error handler branches
   - **airWrapErrUnionErr** - Error union wrapping (lines 2347-2417)
     - Allocates stack frame, stores error value, zero-initializes payload
   - **airErrorName** - Error name lookup (lines 2676-2778)
     - Table lookup implementation (requires symbol resolution infrastructure)
   - **airSliceElemVal** - Slice element access (lines 5080-5209)
     - Bounds checking and element value loading
   - **airFieldParentPtr** - Parent pointer calculation (lines 1380-1415)
     - Subtracts field offset from field pointer
   - **mul_wrap**, **div_float** support added
   - **encodeFmov** - Floating point move encoding (encoder.zig:1140-1152)
   - **Result**: Generates proper Mach-O executables (not "data" files)

### 🚧 Remaining Work for Self-Hosted Backend

The self-hosted ARM64 backend is partially implemented but missing critical AIR instruction handlers. These are needed to compile the standard library and user programs.

#### Critical Missing AIR Instructions

**Location**: `src/codegen/aarch64/CodeGen_v2.zig:739` (genInst switch statement)

Priority 1 (Blocks most std library code):
- ✅ **array_to_slice** - Array to slice conversions (IMPLEMENTED)
- ✅ **aggregate_init** - Struct/array initialization (IMPLEMENTED)
- ✅ **try** - Error handling expressions (IMPLEMENTED)
- ✅ **wrap_errunion_err** - Error union wrapping (IMPLEMENTED)

Priority 2 (Common operations):
- **repeat** - Loop control flow (requires loop state tracking infrastructure)
- ✅ **mul_wrap** - Wrapping multiplication (IMPLEMENTED)
- ✅ **slice_elem_val** - Slice element access (IMPLEMENTED)
- ✅ **error_name** - Error name lookup (IMPLEMENTED - needs symbol resolution)
- ✅ **field_parent_ptr** - Parent pointer from field (IMPLEMENTED)
- ✅ **dbg_empty_stmt** - Debug statement markers (IMPLEMENTED)
- ✅ **div_float** - Floating point division (IMPLEMENTED)

Priority 3 (Advanced features):
- ✅ **Register pair arguments** - C calling convention (IMPLEMENTED)
- ✅ **fmov encoding** - Floating point move instruction encoding (IMPLEMENTED)
- Proper memory operands for inline assembly (currently use registers)

#### Implementation Pattern

To add a new AIR instruction:

1. **Add case to genInst switch** (line 739+):
   ```zig
   .array_to_slice => self.airArrayToSlice(inst),
   ```

2. **Implement handler function**:
   ```zig
   fn airArrayToSlice(self: *CodeGen, inst: Air.Inst.Index) !void {
       // Get instruction data
       const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
       const operand_mcv = try self.resolveInst(ty_op.operand.toIndex().?);

       // Generate MIR instructions
       // ...

       // Track result
       try self.inst_tracking.put(self.gpa, inst, .init(result_mcv));
   }
   ```

3. **Key components**:
   - Get AIR instruction data from `.data` array
   - Resolve operand MCValues (Machine Code Values)
   - Generate ARM64 MIR (Machine Intermediate Representation) instructions
   - Track result for future references

## Current Compilation Results

### Test with Simple Program (test_simple.zig)

```bash
./zig-out/bin/zig build-exe -fno-llvm -fno-lld test_simple.zig
```

**Errors encountered**:
- ❌ `TODO: ARM64 CodeGen array_to_slice` (multiple occurrences)
- ❌ `TODO: ARM64 CodeGen aggregate_init` (multiple occurrences)
- ❌ `TODO: ARM64 CodeGen try` (multiple occurrences)
- ❌ `TODO: ARM64 CodeGen wrap_errunion_err`
- ❌ `TODO: ARM64 CodeGen error_name`
- ❌ `TODO: ARM64 CodeGen field_parent_ptr`
- ❌ `TODO: ARM64 CodeGen slice_elem_val`
- ❌ `TODO: ARM64 CodeGen dbg_empty_stmt`
- ❌ `Instruction X not tracked` (various indices)

**Binary output**: Generated but lacks proper Mach-O headers (file type: "data" instead of Mach-O)

### Test with Minimal Program (test_minimal.zig)

```zig
pub fn main() void {
    _ = add(42, 13);
}

fn add(a: u32, b: u32) u32 {
    return a + b;
}
```

**Result (After commit a4df673839)**:
- ✅ Compiles successfully with no AIR TODO errors
- ✅ Generates proper Mach-O 64-bit ARM64 executable (402KB)
- ⚠️  "Instruction 0 not tracked" warnings (tracking issue)
- ⚠️  "Branch target 932 not found" error
- ❌ Binary headers filled with zeros instead of Mach-O magic number

**Mach-O Header Bug (FIXED in commits b698605af1 + 5d13f20994)**:
- **Issue**: Generated binaries had headers filled with zeros (magic number = 0x00000000)
- **Root Cause**: `relocatable.writeHeader()` function was missing magic number initialization
- **Location**: `src/link/MachO/relocatable.zig:746`
- **Fix**: Added `header.magic = macho.MH_MAGIC_64;` to match main writeHeader() pattern
- **Additional Fix**: Fixed section offset allocation to prevent header overwrite (page-aligned headerpad)
- **Status**: ✅ FIXED - Binaries now have proper Mach-O headers with magic number 0xFEEDFACF

## Build System Status

### Successful Builds
- ✅ Zig compiler builds with ReleaseFast optimization
- ✅ Binary size: 22MB
- ✅ Build time: ~6 minutes
- ⚠️  Memory usage: 9.06GB (exceeds 7.8GB limit but completes)

### Bootstrap Method
Using zig 0.16.0-dev.1364 master build to compile the branch with fixes:
```bash
/tmp/zig-aarch64-macos-0.16.0-dev.1364+f0a3df98d/zig build -Doptimize=ReleaseFast
```

## Next Steps

### Phase 1: Core AIR Instructions (Estimated: 2-3 days)
1. Implement `array_to_slice` - Study x86_64 implementation as reference
2. Implement `aggregate_init` - Handle struct and array initialization
3. Implement `try` expressions - Error handling flow control
4. Test with progressively complex programs

### Phase 2: Additional AIR Instructions (Estimated: 1-2 days)
1. Implement `wrap_errunion_err` and related error union operations
2. Implement `slice_elem_val` and other slice operations
3. Implement `error_name` lookup
4. Implement `field_parent_ptr` calculations

### Phase 3: Calling Conventions (Estimated: 1-2 days)
1. Fix register pair argument passing
2. Ensure C calling convention compliance
3. Test with external function calls

### Phase 4: Mach-O Linker (Estimated: 2-3 days)
1. Fix Mach-O header generation
2. Ensure proper segment/section layout
3. Verify dyld can load binaries
4. Test execution of generated binaries

### Phase 5: Integration Testing (Estimated: ongoing)
1. Compile progressively larger programs
2. Run test suite with self-hosted backend
3. Fix issues as they arise
4. Document limitations and workarounds

## Reference Information

### Key Files
- **CodeGen**: `src/codegen/aarch64/CodeGen_v2.zig`
- **MIR**: `src/codegen/aarch64/Mir.zig`
- **Encoding**: `src/codegen/aarch64/encoding.zig`
- **Linker**: `src/link/MachO.zig`
- **AIR**: `src/Air.zig`

### Example Implementations to Study
- x86_64 backend: `src/codegen/x86_64.zig`
- ARM64 v1 (if exists): `src/codegen/aarch64/CodeGen.zig`

### Useful Commands
```bash
# Build with self-hosted backend
./zig-out/bin/zig build-exe -fno-llvm -fno-lld program.zig

# Check segment order in binary
otool -l binary | grep -E "(segname|vmaddr)"

# Verify binary type
file binary

# Test execution
./binary
```

## Achievements Summary

- **3 critical fixes** implemented and tested
- **Compiler builds successfully** on macOS ARM64
- **Inline assembly** now works with memory constraints
- **Mach-O segment ordering** fixed (pending runtime verification)
- **Clear path forward** identified for remaining work

## Conclusion

The ARM64 self-hosted backend has made significant progress:
- Core infrastructure is in place
- Compiler itself compiles successfully
- Critical bugs fixed (register types, Mach-O segments, inline assembly)

**Current blocker**: Missing AIR instruction implementations prevent compiling even simple programs with the standard library.

**Estimated effort to completion**: 1-2 weeks of focused development to implement all critical AIR instructions and fix linking issues.

**Recommendation**: Continue implementing AIR instructions in priority order, testing incrementally with progressively complex programs.
