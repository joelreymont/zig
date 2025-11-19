const std = @import("std");

pub fn main() !void {
    const a: u32 = 42;
    const b: u32 = 13;
    const result = a + b;

    std.debug.print("Result: {}\n", .{result});
}
