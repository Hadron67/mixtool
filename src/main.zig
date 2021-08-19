const std = @import("std");
const mix = @import("mix.zig");
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;

const USAGE = .{
    "Usages: ",
    "    mixtool unpack <mix file name>",
    "    mixtool pack <output mix file name> [<input file>]*",
    "    mixtool list <mix file name>",
    "    mixtool replace <input mix file> <replaced file id> <replacement file> <output file>",
    "    mixtool extract <input file> <file id> <output file>",
};

fn runMain(gpa: *Allocator, arena: *Allocator) !void {
    var args_iter = std.process.args();
    defer args_iter.deinit();
    _ = args_iter.next(arena);
    const ue = error.UsageError;
    const cmd_name = try (args_iter.next(arena) orelse return ue);

    if (mem.eql(u8, cmd_name, "unpack")) {
        const input_file_name = try (args_iter.next(arena) orelse return ue);
        const output_dir_name = try mem.concat(arena, u8, &.{ fs.path.basename(input_file_name), ".extracted" });
        try fs.cwd().makeDir(output_dir_name);
        var output_dir = try fs.cwd().openDir(output_dir_name, .{});
        defer output_dir.close();

        var mix_file_info = mix.MixFileInfo{};
        defer mix_file_info.deinit(gpa);
        const input_file = try fs.openFileAbsolute(try fs.path.resolve(arena, &.{input_file_name}), .{});
        defer input_file.close();
        try mix_file_info.readFromFile(gpa, input_file);
        try mix_file_info.extractAll(input_file, output_dir);
    } else if (mem.eql(u8, cmd_name, "pack")) {
        const InputFileEntry = struct {
            name: []const u8,
            file: fs.File,
        };

        const output_file_name = try fs.path.resolve(arena, &.{try (args_iter.next(arena) orelse return ue)});
        var output_info = mix.MixFileInfo{};
        defer output_info.deinit(gpa);
        var input_files = ArrayList(InputFileEntry){};
        defer {
            for (input_files.items) |*entry| entry.file.close();
            input_files.deinit(gpa);
        }
        while (args_iter.next(arena)) |nnn| {
            const name = try nnn;
            const resolved_name = try fs.path.resolve(arena, &.{name});
            const file = try fs.openFileAbsolute(resolved_name, .{});
            const base_name = fs.path.basename(name);
            try input_files.append(gpa, .{
                .name = base_name,
                .file = file,
            });
            try output_info.addFileEntry(gpa, mix.util.getFileIdFromName(base_name), @intCast(u32, try file.getEndPos()));
        }
        const output_file = try fs.createFileAbsolute(output_file_name, .{});
        defer output_file.close();
        const writer = output_file.writer();
        try output_info.writeTo(writer);
        for (input_files.items) |*entry| {
            log.info("adding file {s}", .{entry.name});
            try mix.util.copyToEnd(entry.file.reader(), writer);
        }
    } else if (mem.eql(u8, cmd_name, "replace")) {
        const input_file_name = try (args_iter.next(arena) orelse return ue);
        const replaced_id = try std.fmt.parseInt(u32, try (args_iter.next(arena) orelse return ue), 16);
        const replace_file_name = try (args_iter.next(arena) orelse ue);
        const output_file_name = try (args_iter.next(arena) orelse ue);

        const input_file = try fs.openFileAbsolute(try fs.path.resolve(arena, &.{input_file_name}), .{});
        defer input_file.close();
        const replace_file = try fs.openFileAbsolute(try fs.path.resolve(arena, &.{replace_file_name}), .{});
        defer replace_file.close();
        const output_file = try fs.createFileAbsolute(try fs.path.resolve(arena, &.{output_file_name}), .{});
        defer output_file.close();
        const replace_file_size = try replace_file.getEndPos();

        var input_info = mix.MixFileInfo{};
        defer input_info.deinit(gpa);
        var output_info = mix.MixFileInfo{};
        defer output_info.deinit(gpa);
        try input_info.readFromFile(gpa, input_file);
        if (!input_info.header.files.contains(replaced_id)) return error.NoSuchEntry;

        {
            var iter = input_info.header.files.iterator();
            while (iter.next()) |entry| {
                const size = if (entry.key_ptr.* == replaced_id) replace_file_size else entry.value_ptr.size;
                try output_info.addFileEntry(gpa, entry.key_ptr.*, @intCast(u32, size));
            }
        }
        {
            const input_reader = input_file.reader();
            const output_writer = output_file.writer();
            try output_info.writeTo(output_writer);
            var iter = input_info.header.files.iterator();
            while (iter.next()) |entry| {
                if (entry.key_ptr.* == replaced_id) {
                    try mix.util.copy(replace_file.reader(), output_writer, replace_file_size);
                } else if (entry.value_ptr.size != std.math.maxInt(u32)) {
                    try input_file.seekTo(input_info.body_offset + entry.value_ptr.offset);
                    try mix.util.copy(input_reader, output_writer, entry.value_ptr.size);
                }
            }
        }
    } else if (mem.eql(u8, cmd_name, "list")) {
        const input_file_name = try (args_iter.next(arena) orelse return ue);
        const input_file = try fs.openFileAbsolute(try fs.path.resolve(arena, &.{input_file_name}), .{});
        defer input_file.close();

        var info = mix.MixFileInfo{};
        defer info.deinit(gpa);
        try info.readFromFile(gpa, input_file);

        var iter = info.header.files.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.size != std.math.maxInt(u32)) {
                log.info("file id: {X}, size: {}", .{entry.key_ptr.*, entry.value_ptr.size});
            } else {
                log.info("file id: {X}, size: (empty)", .{entry.key_ptr.*});
            }
        }
    } else if (mem.eql(u8, cmd_name, "extract")) {
        const input_file_name = try (args_iter.next(arena) orelse return ue);
        const replaced_id = try std.fmt.parseInt(u32, try (args_iter.next(arena) orelse return ue), 16);
        const output_file_name = try (args_iter.next(arena) orelse return ue);

        const input_file = try fs.openFileAbsolute(try fs.path.resolve(arena, &.{input_file_name}), .{});
        defer input_file.close();

        var info = mix.MixFileInfo{};
        defer info.deinit(gpa);
        try info.readFromFile(gpa, input_file);
        if (info.header.files.get(replaced_id)) |entry| {
            const output_file = try fs.createFileAbsolute(try fs.path.resolve(arena, &.{output_file_name}), .{});
            defer output_file.close();

            try input_file.seekTo(entry.offset + info.body_offset);
            try mix.util.copy(input_file.reader(), output_file.writer(), entry.size);
        } else return error.NoSuchEntry;
    } else {
        return ue;
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();

    runMain(&gpa.allocator, &arena.allocator) catch |e| switch (e) {
        error.UsageError => {
            inline for (USAGE) |line| {
                log.info("{s}", .{line});
            }
        },
        error.NoSuchEntry => log.err("No such file entry", .{}),
        else => return e,
    };
}
