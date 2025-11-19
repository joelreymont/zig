const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("Usage: {s} <binary>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const file = try std.fs.cwd().openFile(args[1], .{
        .mode = .read_write,
    });
    defer file.close();

    // Write a minimal Mach-O header
    const macho = @import("std").macho;
    var header: macho.mach_header_64 = .{};
    header.magic = macho.MH_MAGIC_64;
    header.cputype = macho.CPU_TYPE_ARM64;
    header.cpusubtype = macho.CPU_SUBTYPE_ARM_ALL;
    header.filetype = macho.MH_EXECUTE;
    header.flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_TWOLEVEL | macho.MH_PIE;
    header.ncmds = 0;  // We'll need to calculate this
    header.sizeofcmds = 0;

    // Write the header
    try file.pwriteAll(std.mem.asBytes(&header), 0);

    std.debug.print("Wrote Mach-O header to {s}\n", .{args[1]});
    std.debug.print("Magic: 0x{x}\n", .{header.magic});
}
