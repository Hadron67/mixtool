const std = @import("std");
const mix = @import("mix.zig");
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;

const Args = struct {};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();

    var args_iter = std.process.args();
    defer args_iter.deinit();
    _ = args_iter.next(&arena.allocator);
    const cmd_name = try (args_iter.next(&arena.allocator) orelse return error.MissingCommandName);

    if (mem.eql(u8, cmd_name, "unpack")) {
        const input_file_name = try (args_iter.next(&arena.allocator) orelse return error.MissingFileName);
        const output_dir_name = try mem.concat(&arena.allocator, u8, &.{ fs.path.basename(input_file_name), ".extracted" });
        try fs.cwd().makeDir(output_dir_name);
        var output_dir = try fs.cwd().openDir(output_dir_name, .{});
        defer output_dir.close();

        var mix_file_info = mix.MixFileInfo{};
        defer mix_file_info.deinit(&gpa.allocator);
        const input_file = try fs.openFileAbsolute(try fs.path.resolve(&arena.allocator, &.{input_file_name}), .{});
        defer input_file.close();
        try mix_file_info.readFromFile(&gpa.allocator, input_file);
        try mix_file_info.extractAll(input_file, output_dir);
    } else if (mem.eql(u8, cmd_name, "pack")) {
        const InputFileEntry = struct {
            name: []const u8,
            file: fs.File,
        };

        const output_file_name = try fs.path.resolve(&arena.allocator, &.{try (args_iter.next(&arena.allocator) orelse return error.MissingOutputFile)});
        var output_info = mix.MixFileInfo{};
        defer output_info.deinit(&gpa.allocator);
        var input_files = ArrayList(InputFileEntry){};
        defer {
            for (input_files.items) |*entry| entry.file.close();
            input_files.deinit(&gpa.allocator);
        }
        while (args_iter.next(&arena.allocator)) |nnn| {
            const name = try nnn;
            const resolved_name = try fs.path.resolve(&arena.allocator, &.{name});
            const file = try fs.openFileAbsolute(resolved_name, .{});
            const base_name = fs.path.basename(name);
            try input_files.append(&gpa.allocator, .{
                .name = base_name,
                .file = file,
            });
            try output_info.addFileEntry(&gpa.allocator, mix.getFileIdFromName(base_name), @intCast(u32, try file.getEndPos()));
        }
        const output_file = try fs.createFileAbsolute(output_file_name, .{});
        defer output_file.close();
        const writer = output_file.writer();
        try output_info.writeTo(writer);
        for (input_files.items) |*entry| {
            log.info("adding file {s}", .{entry.name});
            try mix.copyToEnd(entry.file.reader(), writer);
        }
    } else {
        return error.UnknownCommandName;
    }
}
