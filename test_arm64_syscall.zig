const std = @import("std");

pub fn main() !void {
    const msg = "Hello from ARM64 inline assembly!\n";

    // Direct syscall to write to stdout (fd=1)
    // syscall number for write on macOS ARM64 is 4
    const result = asm volatile (
        \\mov x16, #4
        \\svc #0x80
        : [ret] "={x0}" (-> usize),
        : [fd] "{x0}" (@as(usize, 1)),
          [buf] "{x1}" (@intFromPtr(msg.ptr)),
          [len] "{x2}" (@as(usize, msg.len)),
        : .{ .memory = true }
    );

    std.debug.print("Syscall returned: {}\n", .{result});
    std.debug.print("Test completed successfully!\n", .{});
}
