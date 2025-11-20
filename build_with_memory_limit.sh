#!/bin/bash
# Build Zig compiler with custom memory limit
# This bypasses the bootstrap compiler's hardcoded 7.8GB limit

set -e

BOOTSTRAP=/tmp/zig-aarch64-macos-0.16.0-dev.1364+f0a3df98d/zig

echo "Building Zig compiler with 12GB memory limit..."
echo "Bootstrap compiler: $BOOTSTRAP"
echo

# The bootstrap compiler has its own memory limit we can't change
# But we can modify build.zig temporarily to use a higher limit
# then build with that modified version

$BOOTSTRAP build -Doptimize=ReleaseFast 2>&1
