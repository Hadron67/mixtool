const std = @import("std");
const crc32 = @import("crc32.zig");
const log = std.log;
const Allocator = std.mem.Allocator;
const AutoArrayHashMap = std.AutoArrayHashMapUnmanaged;
const fs = std.fs;
const File = std.fs.File;
const min = std.math.min;

pub const MixFlags = struct {
    has_checksum: bool = false,
    is_encrypted: bool = false,

    pub const FLAG_CHECKSUM = 0x00010000;
    pub const FLAG_ENCRYPTED = 0x00020000;
    const Self = @This();

    pub fn readFrom(reader: anytype) !Self {
        const flags = try reader.readIntLittle(u32);
        return Self{
            .has_checksum = (flags & FLAG_CHECKSUM) != 0,
            .is_encrypted = (flags & FLAG_ENCRYPTED) != 0,
        };
    }
    pub fn writeTo(self: Self, writer: anytype) !void {
        var flags: u32 = 0;
        if (self.has_checksum) flags |= FLAG_CHECKSUM;
        if (self.is_encrypted) flags |= FLAG_ENCRYPTED;
        try writer.writeIntLittle(@TypeOf(flags), flags);
    }
};

pub const MixHeader = struct {
    body_size: u32 = 0,
    files: AutoArrayHashMap(u32, MixFileEntry) = .{}, // file id to entry

    const Self = @This();
    pub fn readFrom(self: *Self, allocator: *Allocator, reader: anytype) !void {
        const file_count = try reader.readIntLittle(u16);
        self.body_size = try reader.readIntLittle(@TypeOf(self.body_size));
        log.info("file count: {}, body size: {}", .{ file_count, self.body_size });
        try self.files.ensureTotalCapacity(allocator, file_count);

        var i: usize = 0;
        while (i < file_count) : (i += 1) {
            const file_id = try reader.readIntLittle(u32);
            const offset = try reader.readIntLittle(u32);
            const size = try reader.readIntLittle(u32);
            const gpt = self.files.getOrPut(allocator, file_id) catch unreachable;
            if (gpt.found_existing) {
                log.warn("duplicated file id {}, ignoring", .{file_id});
            } else {
                gpt.value_ptr.* = .{
                    .offset = offset,
                    .size = size,
                };
            }
        }
    }
    pub fn writeTo(self: Self, writer: anytype) !void {
        try writer.writeIntLittle(u16, @intCast(u16, self.files.count()));
        try writer.writeIntLittle(@TypeOf(self.body_size), self.body_size);

        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            try writer.writeIntLittle(u32, entry.key_ptr.*);
            try writer.writeIntLittle(u32, entry.value_ptr.offset);
            try writer.writeIntLittle(u32, entry.value_ptr.size);
        }
    }
    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.files.deinit(allocator);
    }
};

pub const MixFileEntry = struct {
    offset: u32,
    size: u32,
};

pub const MixFileInfo = struct {
    flags: MixFlags = .{},
    header: MixHeader = .{},
    body_offset: u64 = 0,

    const Self = @This();
    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.header.deinit(allocator);
    }
    pub fn readFromFile(self: *Self, allocator: *Allocator, file: File) !void {
        const reader = file.reader();
        self.flags = try MixFlags.readFrom(reader);
        if (self.flags.is_encrypted) {
            return error.EncryptionUnimplemented;
        }
        try self.header.readFrom(allocator, reader);
        self.body_offset = try file.getPos();
        log.info("body start: {}", .{self.body_offset});
    }
    pub fn extractAll(self: Self, file: File, out_dir: fs.Dir) !void {
        var iter = self.header.files.iterator();
        try file.seekTo(self.body_offset);
        const reader = file.reader();
        while (iter.next()) |entry| {
            const file_id = entry.key_ptr.*;
            const offset = entry.value_ptr.offset;
            const size = entry.value_ptr.size;
            const file_name = &idToStr(file_id);
            if (offset != 0xffffffff and size != 0xffffffff) {
                try file.seekTo(self.body_offset + offset);
                const out_file = try out_dir.createFile(file_name, .{});
                defer out_file.close();
                log.info("extracting file {s}, offset: {}, size: {}", .{ file_name, offset, size });
                try copy(reader, out_file.writer(), size);
            } else {
                const out_file = try out_dir.createFile(file_name, .{});
                defer out_file.close();
                log.info("extracting file {s}, offset: (empty), size: (empty)", .{ file_name });
            }
        }
    }
    pub fn addFileEntry(self: *Self, allocator: *Allocator, file_id: u32, size: u32) !void {
        if (size == 0) {
            try self.header.files.putNoClobber(allocator, file_id, .{ .size = std.math.maxInt(u32), .offset = std.math.maxInt(u32) });
        } else {
            try self.header.files.putNoClobber(allocator, file_id, .{ .size = size, .offset = self.header.body_size });
            self.header.body_size += size;
        }
    }
    pub fn writeTo(self: Self, writer: anytype) !void {
        try self.flags.writeTo(writer);
        try self.header.writeTo(writer);
    }
};

const NAME_PLACEHOLDER = ("x" ** 8) ++ ".raw_id";

fn idToStr(id: u32) [NAME_PLACEHOLDER.len]u8 {
    const hex = "0123456789ABCDEF";
    var ret = NAME_PLACEHOLDER.*;
    var i: u5 = 0;
    while (i < 4) : (i += 1) {
        const c = @truncate(u8, id >> (3 - i) * 8);
        ret[2 * @as(u8, i)] = hex[c >> 4];
        ret[2 * @as(u8, i) + 1] = hex[c & 0xF];
    }
    return ret;
}

fn copy(from: anytype, to: anytype, size: usize) !void {
    var buffer: [8192]u8 = undefined;
    var rest = size;
    while (rest > 0) {
        const to_read = min(rest, buffer.len);
        try from.readNoEof(buffer[0..to_read]);
        rest -= to_read;
        try to.writeAll(buffer[0..to_read]);
    }
}

pub fn copyToEnd(from: anytype, to: anytype) !void {
    var buffer: [8192]u8 = undefined;
    var len = try from.read(&buffer);
    while (len > 0) {
        try to.writeAll(buffer[0..len]);
        len = try from.read(&buffer);
    }
}

fn fileIdFromName(name: []const u8) u32 {
    var i: usize = 0;
    var ret: u32 = 0;
    while (i < name.len) {
        var a: u32 = 0;
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            a >>= 8;
            if (i < name.len) a +%= @as(u32, name[i]) << 24;
            i += 1;
        }
        ret = ((ret >> 31) | (ret << 1)) +% a;
    }
    return ret;
}

pub fn getFileIdFromName(name: []const u8) u32 {
    if (std.mem.endsWith(u8, name, ".raw_id") and name.len == NAME_PLACEHOLDER.len) {
        return std.fmt.parseInt(u32, name[0..8], 16) catch crc32.doBlock(name);
    } else return crc32.doBlock(name);
}

// comptime {
//     @compileLog(fileIdFromName("RULESMO.INI"));
//     @compileLog(crc32.doBlock("RULESMO.INI"));
// }