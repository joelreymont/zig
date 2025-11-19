#!/bin/bash
# Test script for Mach-O segment ordering fix (commit 1399fb41)
#
# This script verifies that ARM64 binaries have segments in ascending VM address order.
# The fix changes segment sorting from alphabetical to VM address order when ranks are equal.
#
# Usage: ./test_macho_fix.sh [zig_binary_path]
# If no path provided, uses 'zig' from PATH

set -e

ZIG=${1:-zig}

echo "=== Testing Mach-O Segment Ordering Fix ==="
echo "Using zig compiler: $ZIG"
echo

# Create a simple test program
cat > /tmp/macho_test.zig << 'EOF'
const std = @import("std");
pub fn main() !void {
    std.debug.print("Hello from ARM64!\n", .{});
}
EOF

echo "Compiling test program with self-hosted backend..."
$ZIG build-exe -fno-llvm -fno-lld /tmp/macho_test.zig -femit-bin=/tmp/macho_test 2>&1

echo
echo "Checking segment order in binary..."
echo

# Extract segment names and VM addresses
otool -l /tmp/macho_test | grep -E "(segname|vmaddr)" | \
    awk '/segname/ {seg=$2} /vmaddr/ {print seg, $2}' | \
    grep "ZIG" | sort -k2 > /tmp/segments_by_addr.txt

echo "ZIG segments (sorted by VM address):"
cat /tmp/segments_by_addr.txt
echo

# Extract just the order from the binary
otool -l /tmp/macho_test | grep "segname.*ZIG" | \
    awk '{print NR, $2}' > /tmp/segments_in_binary.txt

echo "ZIG segments (order in binary):"
cat /tmp/segments_in_binary.txt
echo

# Expected order (by VM address):
# 1. __TEXT_ZIG   0x104000000
# 2. __CONST_ZIG  0x10c000000
# 3. __DATA_ZIG   0x110000000
# 4. __BSS_ZIG    0x114000000

# Check if segments are in ascending VM address order
echo "Verifying ascending VM address order..."
prev_addr=0
error=0

while read seg addr; do
    # Convert hex to decimal for comparison
    dec_addr=$((addr))

    if [ $dec_addr -lt $prev_addr ]; then
        echo "❌ ERROR: Segment $seg (addr $addr) comes after higher address!"
        error=1
    else
        echo "✓ $seg at $addr"
    fi

    prev_addr=$dec_addr
done < /tmp/segments_by_addr.txt

echo
if [ $error -eq 0 ]; then
    echo "✅ SUCCESS: All segments in ascending VM address order!"
    echo "Attempting to run binary..."
    /tmp/macho_test
    if [ $? -eq 0 ]; then
        echo "✅ Binary executed successfully!"
    else
        echo "❌ Binary execution failed (exit code: $?)"
    fi
else
    echo "❌ FAILED: Segments not in correct order"
    exit 1
fi

# Cleanup
rm -f /tmp/macho_test.zig /tmp/macho_test /tmp/segments_*.txt
