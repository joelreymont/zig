# ARM64 Backend Testing Guide

## Overview

This document describes how to test the ARM64 backend implementation.

## Unit Tests

The ARM64 backend includes unit tests in the following files:

### Core Infrastructure Tests

1. **src/codegen/aarch64/bits.zig**
   - Test condition code negation
   - Test condition code from compare operators
   - Test register ID extraction
   - Test register conversions (to64, to32)
   - Test register class detection

2. **src/codegen/aarch64/Mir_v2.zig**
   - Test basic MIR instruction construction

3. **src/codegen/aarch64/encoder.zig**
   - Test ADD instruction encoding
   - Test MOV instruction encoding
   - Test LDR instruction encoding
   - Test STR instruction encoding
   - Test B (branch) instruction encoding
   - Test RET instruction encoding
   - Test CMP instruction encoding

4. **src/codegen/aarch64/Lower.zig**
   - Test basic arithmetic lowering

5. **src/codegen/aarch64/Emit.zig**
   - Test basic function emission

### Running Unit Tests

To run all unit tests for the ARM64 backend:

```bash
# Run all tests in a specific file
zig test src/codegen/aarch64/bits.zig
zig test src/codegen/aarch64/Mir_v2.zig
zig test src/codegen/aarch64/encoder.zig
zig test src/codegen/aarch64/Lower.zig
zig test src/codegen/aarch64/Emit.zig

# Or run all backend tests together
zig test src/codegen/aarch64/*.zig
```

## Integration Tests

Integration tests verify that the backend works correctly when compiling actual Zig code.

### Cross-Compilation Tests

Since the backend generates ARM64 code, you can test it via cross-compilation:

```bash
# Compile a simple program for ARM64 target
zig build-exe -target aarch64-linux hello.zig

# Compile with debug info
zig build-exe -target aarch64-linux -O Debug hello.zig

# Compile with optimizations
zig build-exe -target aarch64-linux -O ReleaseFast hello.zig
```

### Running on ARM64 Hardware

To test the generated code on actual ARM64 hardware (Raspberry Pi, AWS Graviton, Apple M1/M2):

1. Cross-compile for ARM64:
   ```bash
   zig build-exe -target aarch64-linux program.zig
   ```

2. Transfer to ARM64 machine:
   ```bash
   scp program user@arm64-machine:~/
   ```

3. Run on ARM64 machine:
   ```bash
   ssh user@arm64-machine
   ./program
   ```

### Using QEMU for Testing

If you don't have ARM64 hardware, use QEMU user-mode emulation:

```bash
# Install QEMU user-mode
sudo apt-get install qemu-user

# Compile for ARM64
zig build-exe -target aarch64-linux hello.zig

# Run with QEMU
qemu-aarch64 ./hello
```

## Behavior Test Suite

The existing Zig behavior test suite in `test/behavior/` automatically tests the ARM64 backend when compiled for aarch64 targets.

### Running Behavior Tests for ARM64

```bash
# Run all behavior tests with ARM64 target
zig build test -Dtarget=aarch64-linux

# Run specific behavior test
zig test test/behavior/basic.zig -target aarch64-linux
zig test test/behavior/math.zig -target aarch64-linux
zig test test/behavior/call.zig -target aarch64-linux
```

## Disassembly and Verification

To verify the generated assembly:

```bash
# Generate assembly output
zig build-obj -target aarch64-linux -femit-asm=output.s program.zig

# Disassemble object file
aarch64-linux-gnu-objdump -d output.o

# Use LLVM tools
llvm-objdump -d output.o
```

## Testing Specific Features

### Arithmetic Operations

```zig
// test_arithmetic.zig
const std = @import("std");

test "basic arithmetic" {
    const a: i32 = 10;
    const b: i32 = 5;
    try std.testing.expect(a + b == 15);
    try std.testing.expect(a - b == 5);
    try std.testing.expect(a * b == 50);
    try std.testing.expect(a / b == 2);
}
```

### Function Calls

```zig
// test_calls.zig
const std = @import("std");

fn add(x: i32, y: i32) i32 {
    return x + y;
}

test "function calls" {
    const result = add(3, 4);
    try std.testing.expect(result == 7);
}
```

### Floating Point

```zig
// test_float.zig
const std = @import("std");

test "floating point operations" {
    const a: f64 = 10.5;
    const b: f64 = 2.5;
    try std.testing.expect(a + b == 13.0);
    try std.testing.expect(a - b == 8.0);
    try std.testing.expect(a * b == 26.25);
    try std.testing.expect(a / b == 4.2);
}
```

### Structures and Arrays

```zig
// test_structs.zig
const std = @import("std");

const Point = struct {
    x: i32,
    y: i32,
};

test "struct operations" {
    const p = Point{ .x = 10, .y = 20 };
    try std.testing.expect(p.x == 10);
    try std.testing.expect(p.y == 20);
}

test "array operations" {
    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    try std.testing.expect(arr[0] == 1);
    try std.testing.expect(arr[4] == 5);
}
```

## Known Limitations

The following features are not yet fully implemented:

1. **Switch Statements**: `switch_br` instruction not implemented
2. **Atomic Operations**: No atomic instruction support
3. **SIMD/NEON**: Vector operations not implemented
4. **Inline Assembly**: Assembly instruction not supported
5. **Debug Information**: DWARF generation stubbed out
6. **Large Constants**: Literal pool management not complete
7. **Position-Independent Code**: Not fully implemented

Tests that rely on these features may fail or be skipped.

## Debugging Failed Tests

When a test fails:

1. **Check the generated assembly**:
   ```bash
   zig build-obj -target aarch64-linux -femit-asm=fail.s fail.zig
   cat fail.s
   ```

2. **Enable verbose output**:
   ```bash
   zig test -target aarch64-linux --verbose fail.zig
   ```

3. **Check for backend errors**:
   ```bash
   zig test -target aarch64-linux fail.zig 2>&1 | grep "codegen/aarch64"
   ```

4. **Use debug builds**:
   ```bash
   zig test -target aarch64-linux -O Debug fail.zig
   ```

## Performance Testing

To benchmark the ARM64 backend:

```bash
# Build with optimizations
zig build-exe -target aarch64-linux -O ReleaseFast benchmark.zig

# Run on ARM64 hardware with timing
time ./benchmark

# Profile with perf (on Linux ARM64)
perf record ./benchmark
perf report
```

## Continuous Integration

For CI/CD pipelines:

```bash
# Cross-compilation test (can run on any architecture)
zig build-exe -target aarch64-linux *.zig

# Unit tests
zig test src/codegen/aarch64/*.zig

# QEMU-based integration test
zig build-exe -target aarch64-linux hello.zig
qemu-aarch64 ./hello
```

## Reporting Issues

When reporting bugs in the ARM64 backend:

1. Provide the full Zig version: `zig version`
2. Include the target triple: `aarch64-linux`
3. Provide a minimal reproduction case
4. Include the generated assembly if possible
5. Specify which AIR instruction is failing (check CodeGen_v2.zig)

## References

- ARM Architecture Reference Manual (ARM ARM)
- AAPCS64 Procedure Call Standard
- Zig x86_64 backend (reference implementation)
- Zig ARM64 backend documentation in this repository
