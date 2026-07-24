const std = @import("std");
const Io = std.Io;

const Tungsten = @import("Tungsten");
const ir = Tungsten.ir;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    var module = ir.Module.empty;
    defer module.deinit(arena);

    var builder = ir.Builder.init(arena, &module);
    const i32_type = try builder.addIntType(true, 32);
    _ = try builder.addVoidType();

    const fib = try builder.addFunction("fib", i32_type);
    builder.setCurrentFunction(fib);

    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    const n = @as(ir.Value, @enumFromInt(0));
    const one = @as(ir.Value, @enumFromInt(1));
    const cond = try builder.buildIcmp(.icmp_sle, i32_type, n, one);

    const base = try builder.appendBlock();
    const recurse = try builder.appendBlock();
    _ = try builder.buildCondBr(cond, base, recurse);

    builder.setCurrentBlock(base);
    _ = try builder.buildRet(n);

    builder.setCurrentBlock(recurse);
    _ = try builder.buildRet(n);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;

    try ir.printModule(&module, writer);
    try writer.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
