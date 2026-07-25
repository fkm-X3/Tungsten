const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Handles - compact, typed, 32-bit integer indices into flat arrays
// ============================================================================

/// An SSA value. By convention, the result of the instruction at index `N`
/// in a function's instruction list is `Value(N)`.
pub const Value = enum(u32) {
    none = 0,
    _,
};

pub const TypeIdx = enum(u32) { _ };
pub const InstructionIdx = enum(u32) { _ };
pub const BasicBlockIdx = enum(u32) { _ };
pub const FunctionIdx = enum(u32) { _ };

// ============================================================================
// Opcode
// ============================================================================

pub const Opcode = enum(u8) {
    // Arithmetic
    add,
    sub,
    mul,
    sdiv,
    udiv,
    // Bitwise
    and_op,
    or_op,
    xor_op,
    shl,
    shr,
    // Comparison
    icmp_eq,
    icmp_ne,
    icmp_slt,
    icmp_sle,
    icmp_sgt,
    icmp_sge,
    icmp_ult,
    icmp_ule,
    icmp_ugt,
    icmp_uge,
    // Control flow
    br,
    cond_br,
    ret,
    call,
    // Memory
    alloca,
    load,
    store,
    // SSA
    phi,
};

// ============================================================================
// Instruction
// ============================================================================

pub const OperandSlice = struct {
    start: u32,
    len: u16,
};

pub const Instruction = struct {
    opcode: Opcode,
    type_idx: TypeIdx,
    operands: OperandSlice,

    /// Returns whether this opcode produces an SSA value.
    pub fn producesValue(self: Instruction) bool {
        return switch (self.opcode) {
            .br, .cond_br, .ret, .store => false,
            else => true,
        };
    }
};

// ============================================================================
// BasicBlock
// ============================================================================

pub const BasicBlock = struct {
    first_inst: InstructionIdx,
    inst_count: u32,
};

// ============================================================================
// Types
// ============================================================================

pub const IrType = union(enum) {
    void,
    bool_type,
    int: IntType,
    float: FloatType,
    pointer: PointerType,
    function: FunctionType,
};

pub const IntType = struct {
    signed: bool,
    bits: u16,
};

pub const FloatType = enum(u16) {
    f16 = 16,
    f32 = 32,
    f64 = 64,
};

pub const PointerType = struct {
    elem: TypeIdx,
};

pub const FunctionType = struct {
    return_type: TypeIdx,
    param_types: []const TypeIdx,
};

// ============================================================================
// String Pool
// ============================================================================

pub const StringRef = struct {
    start: u32,
    len: u32,
};

pub const StringPool = struct {
    buffer: std.ArrayList(u8),

    pub const empty: StringPool = .{ .buffer = .empty };

    pub fn deinit(self: *StringPool, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }

    pub fn intern(self: *StringPool, gpa: Allocator, s: []const u8) !StringRef {
        const start: u32 = @intCast(self.buffer.items.len);
        try self.buffer.appendSlice(gpa, s);
        return .{ .start = start, .len = @intCast(s.len) };
    }

    pub fn get(self: StringPool, ref: StringRef) []const u8 {
        return self.buffer.items[ref.start..][0..ref.len];
    }
};

// ============================================================================
// Function
// ============================================================================

pub const Function = struct {
    name: StringRef,
    return_type: TypeIdx,
    param_count: u32,
    blocks: std.ArrayList(BasicBlock),
    instructions: std.ArrayList(Instruction),
    /// Operand pool: flat u32 array referenced by Instruction.operands
    extra_data: std.ArrayList(u32),

    pub const empty: Function = .{
        .name = .{ .start = 0, .len = 0 },
        .return_type = @enumFromInt(0),
        .param_count = 0,
        .blocks = .empty,
        .instructions = .empty,
        .extra_data = .empty,
    };

    pub fn deinit(self: *Function, gpa: Allocator) void {
        self.blocks.deinit(gpa);
        self.instructions.deinit(gpa);
        self.extra_data.deinit(gpa);
    }

    pub fn getOperand(self: Function, val: Value) u32 {
        return self.extra_data.items[@intFromEnum(val)];
    }

    pub fn getOperands(self: Function, slice: OperandSlice) []const u32 {
        return self.extra_data.items[slice.start..][0..slice.len];
    }
};

// ============================================================================
// Module
// ============================================================================

pub const Module = struct {
    functions: std.ArrayList(Function),
    types: std.ArrayList(IrType),
    strings: StringPool,

    pub const empty: Module = .{
        .functions = .empty,
        .types = .empty,
        .strings = StringPool.empty,
    };

    pub fn deinit(self: *Module, gpa: Allocator) void {
        for (self.functions.items) |*f| f.deinit(gpa);
        self.functions.deinit(gpa);
        self.types.deinit(gpa);
        self.strings.deinit(gpa);
    }

    pub fn addType(self: *Module, gpa: Allocator, ir_type: IrType) !TypeIdx {
        const idx: u32 = @intCast(self.types.items.len);
        try self.types.append(gpa, ir_type);
        return @enumFromInt(idx);
    }

    pub fn getIrType(self: Module, idx: TypeIdx) IrType {
        return self.types.items[@intFromEnum(idx)];
    }
};

// ============================================================================
// Builder - convenience API for constructing IR
// ============================================================================

pub const Builder = struct {
    gpa: Allocator,
    module: *Module,
    current_func: ?FunctionIdx,
    current_block: ?BasicBlockIdx,

    pub fn init(gpa: Allocator, module: *Module) Builder {
        return .{
            .gpa = gpa,
            .module = module,
            .current_func = null,
            .current_block = null,
        };
    }

    pub fn setCurrentFunction(self: *Builder, func: FunctionIdx) void {
        self.current_func = func;
        self.current_block = null;
    }

    pub fn setCurrentBlock(self: *Builder, block: BasicBlockIdx) void {
        self.current_block = block;
        // Pin the block's first_inst to the current end of the instruction
        // list so that all subsequent appends land in this block.
        const func = self.getCurrentFunction();
        func.blocks.items[@intFromEnum(block)].first_inst =
            @enumFromInt(@as(u32, @intCast(func.instructions.items.len)));
    }

    // -- Type helpers --

    pub fn addVoidType(self: *Builder) !TypeIdx {
        return self.module.addType(self.gpa, .void);
    }

    pub fn addBoolType(self: *Builder) !TypeIdx {
        return self.module.addType(self.gpa, .bool_type);
    }

    pub fn addIntType(self: *Builder, signed: bool, bits: u16) !TypeIdx {
        return self.module.addType(self.gpa, .{ .int = .{ .signed = signed, .bits = bits } });
    }

    pub fn addFloatType(self: *Builder, float: FloatType) !TypeIdx {
        return self.module.addType(self.gpa, .{ .float = float });
    }

    pub fn addPointerType(self: *Builder, elem: TypeIdx) !TypeIdx {
        return self.module.addType(self.gpa, .{ .pointer = .{ .elem = elem } });
    }

    pub fn addFunctionType(self: *Builder, ret: TypeIdx, param_types: []const TypeIdx) !TypeIdx {
        const owned = try self.gpa.dupe(TypeIdx, param_types);
        return self.module.addType(self.gpa, .{ .function = .{
            .return_type = ret,
            .param_types = owned,
        } });
    }

    // -- Function --

    pub fn addFunction(self: *Builder, name: []const u8, return_type: TypeIdx, param_count: u32) !FunctionIdx {
        const name_ref = try self.module.strings.intern(self.gpa, name);
        const idx: u32 = @intCast(self.module.functions.items.len);
        var func = Function.empty;
        func.name = name_ref;
        func.return_type = return_type;
        func.param_count = param_count;
        try self.module.functions.append(self.gpa, func);
        return @enumFromInt(idx);
    }

    pub fn getCurrentFunction(self: *Builder) *Function {
        return &self.module.functions.items[@intFromEnum(self.current_func.?)];
    }

    // -- Basic Blocks --

    pub fn appendBlock(self: *Builder) !BasicBlockIdx {
        const func = self.getCurrentFunction();
        const idx: u32 = @intCast(func.blocks.items.len);
        try func.blocks.append(self.gpa, .{
            .first_inst = @enumFromInt(@as(u32, @intCast(func.instructions.items.len))),
            .inst_count = 0,
        });
        return @enumFromInt(idx);
    }

    pub fn getCurrentBlock(self: *Builder) *BasicBlock {
        return &self.getCurrentFunction().blocks.items[@intFromEnum(self.current_block.?)];
    }

    // -- Operand helpers --

    fn appendOperands(self: *Builder, operands: []const u32) !OperandSlice {
        const func = self.getCurrentFunction();
        const start: u32 = @intCast(func.extra_data.items.len);
        try func.extra_data.appendSlice(self.gpa, operands);
        return .{ .start = start, .len = @intCast(operands.len) };
    }

    fn appendInstruction(self: *Builder, inst: Instruction) !Value {
        const func = self.getCurrentFunction();
        const block = self.getCurrentBlock();
        const idx: u32 = @intCast(func.instructions.items.len);
        try func.instructions.append(self.gpa, inst);
        block.inst_count += 1;
        if (inst.producesValue()) {
            return @enumFromInt(idx);
        }
        return .none;
    }

    // -- Instruction builders --

    fn buildBinOp(self: *Builder, opcode: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.appendInstruction(.{
            .opcode = opcode,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @intFromEnum(lhs), @intFromEnum(rhs) }),
        });
    }

    pub fn buildAdd(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.add, type_idx, lhs, rhs);
    }

    pub fn buildSub(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.sub, type_idx, lhs, rhs);
    }

    pub fn buildMul(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.mul, type_idx, lhs, rhs);
    }

    pub fn buildSDiv(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.sdiv, type_idx, lhs, rhs);
    }

    pub fn buildUDiv(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.udiv, type_idx, lhs, rhs);
    }

    pub fn buildAnd(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.and_op, type_idx, lhs, rhs);
    }

    pub fn buildOr(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.or_op, type_idx, lhs, rhs);
    }

    pub fn buildXor(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.xor_op, type_idx, lhs, rhs);
    }

    pub fn buildShl(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.shl, type_idx, lhs, rhs);
    }

    pub fn buildShr(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.shr, type_idx, lhs, rhs);
    }

    pub fn buildIcmp(self: *Builder, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(cond, type_idx, lhs, rhs);
    }

    pub fn buildBr(self: *Builder, target: BasicBlockIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .br,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{@intFromEnum(target)}),
        });
    }

    pub fn buildCondBr(self: *Builder, cond: Value, true_block: BasicBlockIdx, false_block: BasicBlockIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .cond_br,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{ @intFromEnum(cond), @intFromEnum(true_block), @intFromEnum(false_block) }),
        });
    }

    pub fn buildRet(self: *Builder, val: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .ret,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{@intFromEnum(val)}),
        });
    }

    pub fn buildCall(self: *Builder, func_idx: FunctionIdx, type_idx: TypeIdx, args: []const Value) !Value {
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        try ops.append(self.gpa, @intFromEnum(func_idx));
        for (args) |arg| {
            try ops.append(self.gpa, @intFromEnum(arg));
        }
        return self.appendInstruction(.{
            .opcode = .call,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }

    pub fn buildAlloca(self: *Builder, type_idx: TypeIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .alloca,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{}),
        });
    }

    pub fn buildLoad(self: *Builder, type_idx: TypeIdx, ptr: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .load,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{@intFromEnum(ptr)}),
        });
    }

    pub fn buildStore(self: *Builder, type_idx: TypeIdx, ptr: Value, val: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .store,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @intFromEnum(ptr), @intFromEnum(val) }),
        });
    }

    pub fn buildPhi(self: *Builder, type_idx: TypeIdx, incoming: []const PhiIncoming) !Value {
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        for (incoming) |inc| {
            try ops.append(self.gpa, @intFromEnum(inc.value));
            try ops.append(self.gpa, @intFromEnum(inc.block));
        }
        return self.appendInstruction(.{
            .opcode = .phi,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }
};

pub const PhiIncoming = struct {
    value: Value,
    block: BasicBlockIdx,
};

// ============================================================================
// Textual IR Printer
// ============================================================================

pub fn printModule(module: *Module, writer: anytype) !void {
    for (module.functions.items) |func| {
        const name = module.strings.get(func.name);
        try writer.print("fn @{s}() {{\n", .{name});

        for (func.blocks.items, 0..) |block, block_idx| {
            try writer.print("  bb{}:\n", .{block_idx});

            const start = @intFromEnum(block.first_inst);
            const end = start + block.inst_count;
            for (func.instructions.items[start..end], 0..) |inst, i| {
                const inst_idx = start + i;
                try writer.print("    ", .{});
                if (inst.producesValue()) {
                    try writer.print("%{d} = ", .{inst_idx});
                }
                try printInstruction(func, inst, writer);
                try writer.print("\n", .{});
            }
        }

        try writer.print("}}\n\n", .{});
    }
}

fn printInstruction(func: Function, inst: Instruction, writer: anytype) !void {
    const ops = func.getOperands(inst.operands);
    switch (inst.opcode) {
        .add => try writer.print("add %{d}, %{d}", .{ ops[0], ops[1] }),
        .sub => try writer.print("sub %{d}, %{d}", .{ ops[0], ops[1] }),
        .mul => try writer.print("mul %{d}, %{d}", .{ ops[0], ops[1] }),
        .sdiv => try writer.print("sdiv %{d}, %{d}", .{ ops[0], ops[1] }),
        .udiv => try writer.print("udiv %{d}, %{d}", .{ ops[0], ops[1] }),
        .and_op => try writer.print("and %{d}, %{d}", .{ ops[0], ops[1] }),
        .or_op => try writer.print("or %{d}, %{d}", .{ ops[0], ops[1] }),
        .xor_op => try writer.print("xor %{d}, %{d}", .{ ops[0], ops[1] }),
        .shl => try writer.print("shl %{d}, %{d}", .{ ops[0], ops[1] }),
        .shr => try writer.print("shr %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_eq => try writer.print("icmp eq %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ne => try writer.print("icmp ne %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_slt => try writer.print("icmp slt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sle => try writer.print("icmp sle %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sgt => try writer.print("icmp sgt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sge => try writer.print("icmp sge %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ult => try writer.print("icmp ult %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ule => try writer.print("icmp ule %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ugt => try writer.print("icmp ugt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_uge => try writer.print("icmp uge %{d}, %{d}", .{ ops[0], ops[1] }),
        .br => try writer.print("br bb{d}", .{ops[0]}),
        .cond_br => try writer.print("cond_br %{d}, bb{d}, bb{d}", .{ ops[0], ops[1], ops[2] }),
        .ret => try writer.print("ret %{d}", .{ops[0]}),
        .call => {
            try writer.print("call @fn{d}(", .{ops[0]});
            for (ops[1..], 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("%{d}", .{arg});
            }
            try writer.print(")", .{});
        },
        .alloca => try writer.print("alloca", .{}),
        .load => try writer.print("load %{d}", .{ops[0]}),
        .store => try writer.print("store %{d}, %{d}", .{ ops[0], ops[1] }),
        .phi => {
            try writer.print("phi ", .{});
            var i: usize = 0;
            while (i + 1 < ops.len) : (i += 2) {
                try writer.print("[ %{d}, bb{d} ] ", .{ ops[i], ops[i + 1] });
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "basic module construction" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    _ = try builder.addVoidType();
    const i32_type = try builder.addIntType(false, 32);

    const func = try builder.addFunction("main", i32_type, 0);
    builder.setCurrentFunction(func);

    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    _ = try builder.buildRet(@enumFromInt(0));

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items[0].blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items[0].instructions.items.len);
}

test "fibonacci construction" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    const i32_type = try builder.addIntType(true, 32);

    const fib = try builder.addFunction("fib", i32_type, 1);
    builder.setCurrentFunction(fib);

    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    // %cond = icmp sle %n, 1
    const n_param = @as(Value, @enumFromInt(0));
    const one = @as(Value, @enumFromInt(1));
    _ = one;
    const cond = try builder.buildIcmp(.icmp_sle, i32_type, n_param, @enumFromInt(0));

    const base = try builder.appendBlock();
    const recurse = try builder.appendBlock();
    _ = try builder.buildCondBr(cond, base, recurse);

    builder.setCurrentBlock(base);
    _ = try builder.buildRet(n_param);

    builder.setCurrentBlock(recurse);
    _ = try builder.buildRet(n_param);

    try std.testing.expectEqual(@as(usize, 3), module.functions.items[0].blocks.items.len);
}
