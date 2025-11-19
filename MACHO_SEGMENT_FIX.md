# Mach-O Segment Ordering Fix for macOS ARM64

## Problem Statement

Self-hosted ARM64 binaries on macOS fail to execute with the error:
```
dyld[xxxxx]: segment '__CONST_ZIG' vm address out of order
```

This occurs because macOS's dynamic linker (dyld) requires that segments appear in the Mach-O binary in **ascending VM address order**.

## Root Cause Analysis

### The Bug

In `src/link/MachO.zig`, function `initSegments()` (line 2076-2195), segments are created with specific VM addresses:

```zig
// Line 3304
self.zig_text_seg_index = try self.addSegment("__TEXT_ZIG", .{
    .vmaddr = base_vmaddr + 0x4000000,  // 0x104000000
    ...
});

// Line 3316
self.zig_const_seg_index = try self.addSegment("__CONST_ZIG", .{
    .vmaddr = base_vmaddr + 0xc000000,  // 0x10c000000
    ...
});

// Line 3328
self.zig_data_seg_index = try self.addSegment("__DATA_ZIG", .{
    .vmaddr = base_vmaddr + 0x10000000, // 0x110000000
    ...
});

// Line 3338
self.zig_bss_seg_index = try self.addSegment("__BSS_ZIG", .{
    .vmaddr = base_vmaddr + 0x14000000, // 0x114000000
    ...
});
```

**Expected VM address order** (ascending):
1. `__TEXT_ZIG`  @ 0x104000000
2. `__CONST_ZIG` @ 0x10c000000
3. `__DATA_ZIG`  @ 0x110000000
4. `__BSS_ZIG`   @ 0x114000000

However, segments are then sorted at line 2117-2154 using this logic:

```zig
pub fn lessThan(macho_file: *MachO, lhs: @This(), rhs: @This()) bool {
    return segmentLessThan(
        {},
        macho_file.segments.items[lhs.index].segName(),
        macho_file.segments.items[rhs.index].segName(),
    );
}
```

The `segmentLessThan()` function (line 1757-1765) uses `getSegmentRank()`:

```zig
fn getSegmentRank(segname: []const u8) u8 {
    if (mem.eql(u8, segname, "__PAGEZERO")) return 0x0;
    if (mem.eql(u8, segname, "__LINKEDIT")) return 0xf;
    if (mem.indexOf(u8, segname, "ZIG")) |_| return 0xe;  // ALL ZIG segments get same rank!
    if (mem.startsWith(u8, segname, "__TEXT")) return 0x1;
    ...
}
```

**Problem**: All ZIG segments get the same rank (0xe). When ranks are equal, `segmentLessThan()` sorts **alphabetically by name**:

```zig
if (lhs_rank == rhs_rank) {
    return mem.order(u8, lhs, rhs) == .lt;  // Alphabetical order!
}
```

**Alphabetical order of ZIG segments**:
1. `__BSS_ZIG`   @ 0x114000000 ❌ (highest address, but first alphabetically)
2. `__CONST_ZIG` @ 0x10c000000
3. `__DATA_ZIG`  @ 0x110000000
4. `__TEXT_ZIG`  @ 0x104000000 ❌ (lowest address, but last alphabetically)

This creates an **out-of-order VM address sequence**, violating dyld's requirement.

## The Fix

**File**: `src/link/MachO.zig`
**Location**: Lines 2121-2131
**Commit**: 1399fb41ff

Changed the sorting logic to use VM address when ranks are equal:

```zig
pub fn lessThan(macho_file: *MachO, lhs: @This(), rhs: @This()) bool {
    const lhs_seg = &macho_file.segments.items[lhs.index];
    const rhs_seg = &macho_file.segments.items[rhs.index];
    const lhs_rank = getSegmentRank(lhs_seg.segName());
    const rhs_rank = getSegmentRank(rhs_seg.segName());
    if (lhs_rank == rhs_rank) {
        // For segments with same rank, sort by VM address instead of name
        return lhs_seg.vmaddr < rhs_seg.vmaddr;  // ✅ VM address order!
    }
    return lhs_rank < rhs_rank;
}
```

## Verification

### Before the fix:
```bash
$ otool -l test_simple | grep -E "(segname|vmaddr)" | grep ZIG -A 1
segname __BSS_ZIG
   vmaddr 0x0000000114000000
segname __CONST_ZIG
   vmaddr 0x000000010c000000  # ❌ Lower than BSS_ZIG!
segname __DATA_ZIG
   vmaddr 0x0000000110000000
segname __TEXT_ZIG
   vmaddr 0x0000000104000000
```

**Result**: `dyld: segment '__CONST_ZIG' vm address out of order`

### After the fix:
```bash
$ otool -l test_simple | grep -E "(segname|vmaddr)" | grep ZIG -A 1
segname __TEXT_ZIG
   vmaddr 0x0000000104000000  # ✅ Lowest address first
segname __CONST_ZIG
   vmaddr 0x000000010c000000  # ✅ Ascending order
segname __DATA_ZIG
   vmaddr 0x0000000110000000  # ✅ Ascending order
segname __BSS_ZIG
   vmaddr 0x0000000114000000  # ✅ Highest address last
```

**Result**: Binary loads and executes successfully! ✅

## Testing

### Manual Test
```bash
# Build zig from source with the fix
zig build -Doptimize=ReleaseFast

# Test with self-hosted backend
./zig-out/bin/zig build-exe -fno-llvm -fno-lld test_simple.zig

# Verify segment order
otool -l test_simple | grep -E "(segname|vmaddr)" | grep ZIG

# Run the binary
./test_simple  # Should print: Result: 55
```

### Automated Test
```bash
chmod +x test_macho_fix.sh
./test_macho_fix.sh ./zig-out/bin/zig
```

## Impact

- **Platforms Affected**: macOS ARM64 (aarch64-macos)
- **Backends Affected**: Self-hosted backend only (LLVM backend unaffected)
- **Severity**: Critical - blocks all self-hosted ARM64 binary execution on macOS
- **Fix Scope**: One function, 11 lines changed
- **Risk**: Low - only affects segment sorting logic for equal-rank segments

## Related Issues

This fix complements the inline assembly register type conversion fix (commit 110e7212). Together, these fixes enable:
1. ✅ Inline assembly compilation (register type fix)
2. ✅ Binary generation (segment ordering fix)
3. ✅ Binary execution on macOS ARM64

## References

- Commit: 1399fb41ff "Fix Mach-O segment VM address ordering on macOS ARM64"
- Related: 110e7212 "Fix register type conversions in inline assembly for ARM64"
- File: `src/link/MachO.zig:2121-2131`
- Apple Documentation: [Mach-O File Format](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/CodeFootprint/Articles/MachOOverview.html)
