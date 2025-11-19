const std = @import("std");

pub fn main() !void {
    const file = try std.fs.cwd().createFile("test_output.bin", .{
        .truncate = true,
        .read = true,
    });
    defer file.close();

    // Write some data at offset 0x4000 first (like sections do)
    const section_data = [_]u8{0xAA} ** 32;
    try file.pwriteAll(&section_data, 0x4000);

    // Now write header at offset 0
    const header = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE } ++ [_]u8{0xBB} ** 28;
    try file.pwriteAll(&header, 0);

    std.debug.print("Wrote header and section data\n", .{});
}
