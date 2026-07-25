//! Tungsten Frontend API
//!
//! High-level, ergonomic API for frontend compilers written in Zig to construct
//! Tungsten IR and generate native code.
//!
//! This is the recommended interface for driving Tungsten from a frontend.
//! It wraps the low-level IR builder with a single `Context` object that owns
//! all module state and provides methods for type creation, function definition,
//! instruction building, and code emission.
//!
//! Example — building a simple `add` function:
//!
//! ```zig
//! const tungsten = @import("Tungsten");
//! const api = tungsten.api;
//!
//! fn buildAdd(ctx: *api.Context) !void {
//!     const i32 = try ctx.intType(true, 32);
//!
//!     const func = try ctx.addFunction("add", i32, 2);
//!     ctx.setCurrentFunction(func);
//!
//!     const entry = try ctx.appendBlock();
//!     ctx.setCurrentBlock(entry);
//!
//!     const a = ctx.getParam(0);
//!     const b = ctx.getParam(1);
//!     const sum = try ctx.buildAdd(i32, a, b);
//!     _ = try ctx.buildRet(sum);
//! }
//! ```

const std = @import("std");
const ir = @import("ir.zig");
const codegen = @import("codegen.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// Re-exports — handle types for use by frontends without importing ir.zig
// ============================================================================

pub const Value = ir.Value;
pub const TypeIdx = ir.TypeIdx;
pub const FunctionIdx = ir.FunctionIdx;
pub const BasicBlockIdx = ir.BasicBlockIdx;
pub const Opcode = ir.Opcode;
pub const FloatType = ir.FloatType;
pub const IrType = ir.IrType;
pub const IntType = ir.IntType;
pub const PointerType = ir.PointerType;
pub const FunctionType = ir.FunctionType;
pub const PhiIncoming = ir.PhiIncoming;

// ============================================================================
// Context
// ============================================================================

/// The top-level entry point for constructing Tungsten IR.
///
/// A `Context` owns the IR module and instruction builder. All types, functions,
/// basic blocks, and instructions are created through this object.
///
/// The context is heap-allocated via `init` and freed via `deinit`.
pub const Context = struct {
    gpa: Allocator,
    module: ir.Module,
    builder: ir.Builder,

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Create a new Tungsten context.
    ///
    /// Allocates the context on the heap so that internal pointers (e.g. the
    /// builder's reference to the module) remain stable.
    /// The caller must free via `deinit`.
    pub fn init(gpa: Allocator) !*Context {
        const ctx = try gpa.create(Context);
        ctx.* = .{
            .gpa = gpa,
            .module = .empty,
            .builder = undefined,
        };
        ctx.builder = ir.Builder.init(gpa, &ctx.module);
        return ctx;
    }

    /// Destroy the context and release all associated memory.
    pub fn deinit(self: *Context) void {
        self.module.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // ========================================================================
    // Type System
    // ========================================================================

    /// Create a void type.
    pub fn voidType(self: *Context) !TypeIdx {
        return self.builder.addVoidType();
    }

    /// Create a boolean type.
    pub fn boolType(self: *Context) !TypeIdx {
        return self.builder.addBoolType();
    }

    /// Create an integer type with the given signedness and bit width.
    pub fn intType(self: *Context, signed: bool, bits: u16) !TypeIdx {
        return self.builder.addIntType(signed, bits);
    }

    /// Create a floating-point type (f16, f32, or f64).
    pub fn floatType(self: *Context, ft: FloatType) !TypeIdx {
        return self.builder.addFloatType(ft);
    }

    /// Create a pointer type pointing to `elem`.
    pub fn ptrType(self: *Context, elem: TypeIdx) !TypeIdx {
        return self.builder.addPointerType(elem);
    }

    /// Create a function type with the given return type and parameter types.
    pub fn funcType(self: *Context, ret: TypeIdx, param_types: []const TypeIdx) !TypeIdx {
        return self.builder.addFunctionType(ret, param_types);
    }

    /// Look up a type by its index.
    pub fn getType(self: *Context, idx: TypeIdx) IrType {
        return self.module.getIrType(idx);
    }

    /// Return the number of types registered in the module.
    pub fn getTypeCount(self: *Context) usize {
        return self.module.types.items.len;
    }

    // ========================================================================
    // Functions
    // ========================================================================

    /// Add a new function to the module.
    ///
    /// After creation call `setCurrentFunction` to begin building its body.
    pub fn addFunction(self: *Context, name: []const u8, return_type: TypeIdx, param_count: u32) !FunctionIdx {
        return self.builder.addFunction(name, return_type, param_count);
    }

    /// Set the current function for subsequent block / instruction insertion.
    pub fn setCurrentFunction(self: *Context, func: FunctionIdx) void {
        self.builder.setCurrentFunction(func);
    }

    /// Get a reference to a function by index.
    pub fn getFunction(self: *Context, idx: FunctionIdx) *ir.Function {
        return &self.module.functions.items[@intFromEnum(idx)];
    }

    /// Return the number of functions in the module.
    pub fn getFunctionCount(self: *Context) usize {
        return self.module.functions.items.len;
    }

    /// Get the name of a function.
    pub fn getFunctionName(self: *Context, idx: FunctionIdx) []const u8 {
        const func = self.module.functions.items[@intFromEnum(idx)];
        return self.module.strings.get(func.name);
    }

    /// Return the number of basic blocks in the given function.
    pub fn getBlockCountIn(self: *Context, idx: FunctionIdx) usize {
        return self.module.functions.items[@intFromEnum(idx)].blocks.items.len;
    }

    /// Return the number of instructions in the given function.
    pub fn getInstructionCountIn(self: *Context, idx: FunctionIdx) usize {
        return self.module.functions.items[@intFromEnum(idx)].instructions.items.len;
    }

    // ========================================================================
    // Basic Blocks
    // ========================================================================

    /// Append a new basic block to the current function.
    ///
    /// Panics if no current function has been set via `setCurrentFunction`.
    pub fn appendBlock(self: *Context) !BasicBlockIdx {
        return self.builder.appendBlock();
    }

    /// Set the current insertion point to the end of the given basic block.
    pub fn setCurrentBlock(self: *Context, block: BasicBlockIdx) void {
        self.builder.setCurrentBlock(block);
    }

    // ========================================================================
    // Parameter Access
    // ========================================================================

    /// Get the SSA value handle for a function parameter.
    ///
    /// Parameters are numbered from 0. The Nth parameter of the current
    /// function is `getParam(N)`.
    pub fn getParam(_: *Context, index: u32) Value {
        return @enumFromInt(index);
    }

    // ========================================================================
    // Instruction Building — Arithmetic
    // ========================================================================

    pub fn buildAdd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildAdd(type_idx, lhs, rhs);
    }

    pub fn buildSub(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildSub(type_idx, lhs, rhs);
    }

    pub fn buildMul(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildMul(type_idx, lhs, rhs);
    }

    pub fn buildSDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildSDiv(type_idx, lhs, rhs);
    }

    pub fn buildUDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildUDiv(type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Bitwise
    // ========================================================================

    pub fn buildAnd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildAnd(type_idx, lhs, rhs);
    }

    pub fn buildOr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildOr(type_idx, lhs, rhs);
    }

    pub fn buildXor(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildXor(type_idx, lhs, rhs);
    }

    pub fn buildShl(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildShl(type_idx, lhs, rhs);
    }

    pub fn buildShr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildShr(type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Comparison
    // ========================================================================

    /// Build an integer comparison.
    ///
    /// `cond` must be one of the `icmp_*` opcodes (e.g. `.icmp_eq`, `.icmp_slt`).
    pub fn buildIcmp(self: *Context, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildIcmp(cond, type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Control Flow
    // ========================================================================

    /// Build an unconditional branch to `target`.
    pub fn buildBr(self: *Context, target: BasicBlockIdx) !Value {
        return self.builder.buildBr(target);
    }

    /// Build a conditional branch: branch to `true_block` if `cond` is nonzero,
    /// otherwise to `false_block`.
    pub fn buildCondBr(self: *Context, cond: Value, true_block: BasicBlockIdx, false_block: BasicBlockIdx) !Value {
        return self.builder.buildCondBr(cond, true_block, false_block);
    }

    /// Build a return instruction.
    pub fn buildRet(self: *Context, val: Value) !Value {
        return self.builder.buildRet(val);
    }

    // ========================================================================
    // Instruction Building — Function Calls
    // ========================================================================

    /// Build a call to `func` passing the given arguments.
    pub fn buildCall(self: *Context, func: FunctionIdx, type_idx: TypeIdx, args: []const Value) !Value {
        return self.builder.buildCall(func, type_idx, args);
    }

    // ========================================================================
    // Instruction Building — Memory
    // ========================================================================

    /// Allocate stack space for `type_idx`. Returns a pointer value.
    pub fn buildAlloca(self: *Context, type_idx: TypeIdx) !Value {
        return self.builder.buildAlloca(type_idx);
    }

    /// Load a value of `type_idx` from `ptr`.
    pub fn buildLoad(self: *Context, type_idx: TypeIdx, ptr: Value) !Value {
        return self.builder.buildLoad(type_idx, ptr);
    }

    /// Store `val` (of `type_idx`) through `ptr`.
    pub fn buildStore(self: *Context, type_idx: TypeIdx, ptr: Value, val: Value) !Value {
        return self.builder.buildStore(type_idx, ptr, val);
    }

    // ========================================================================
    // Instruction Building — SSA
    // ========================================================================

    /// Build a phi node with the given incoming (value, block) pairs.
    pub fn buildPhi(self: *Context, type_idx: TypeIdx, incoming: []const PhiIncoming) !Value {
        return self.builder.buildPhi(type_idx, incoming);
    }

    // ========================================================================
    // Output — Textual IR
    // ========================================================================

    /// Print the module's textual IR representation to `writer`.
    pub fn print(self: *Context, writer: anytype) !void {
        try ir.printModule(&self.module, writer);
    }

    // ========================================================================
    // Output — Native Code
    // ========================================================================

    /// Emit x86-64 NASM assembly for the entire module.
    ///
    /// Returns an allocated byte slice that the caller must free with
    /// `ctx.gpa.free(result)`.
    pub fn emitAssembly(self: *Context) ![]u8 {
        var cg = codegen.CodeGen.init(self.gpa, &self.module);
        defer cg.deinit();
        try cg.emitModule();
        return self.gpa.dupe(u8, cg.buf.items);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "context lifecycle" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.getFunctionCount());
}

test "type creation" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const void_ty = try ctx.voidType();
    const bool_ty = try ctx.boolType();
    const i32_ty = try ctx.intType(true, 32);
    const u8_ty = try ctx.intType(false, 8);
    const f32_ty = try ctx.floatType(.f32);
    const ptr_ty = try ctx.ptrType(i32_ty);

    try std.testing.expectEqual(@as(usize, 6), ctx.getTypeCount());

    // Verify round-trip
    try std.testing.expectEqual(IrType.void, ctx.getType(void_ty));
    try std.testing.expectEqual(IrType.bool_type, ctx.getType(bool_ty));
    try std.testing.expectEqual(IrType{ .int = .{ .signed = true, .bits = 32 } }, ctx.getType(i32_ty));
    try std.testing.expectEqual(IrType{ .int = .{ .signed = false, .bits = 8 } }, ctx.getType(u8_ty));
    try std.testing.expectEqual(IrType{ .float = .f32 }, ctx.getType(f32_ty));
    try std.testing.expectEqual(IrType{ .pointer = .{ .elem = i32_ty } }, ctx.getType(ptr_ty));
}

test "function and instruction building" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    _ = try ctx.voidType();

    // int add(int a, int b) { return a + b; }
    const func = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);

    try std.testing.expectEqual(@as(usize, 1), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), ctx.getBlockCountIn(func));
    try std.testing.expectEqual(@as(usize, 3), ctx.getInstructionCountIn(func));
    try std.testing.expectEqualStrings("add", ctx.getFunctionName(func));
}

test "fibonacci with control flow" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    // fn fib(i32 %n) -> i32
    const fib = try ctx.addFunction("fib", i32_ty, 1);
    ctx.setCurrentFunction(fib);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const n = ctx.getParam(0);
    const zero = @as(Value, @enumFromInt(0));
    const cond = try ctx.buildIcmp(.icmp_sle, i32_ty, n, zero);

    const base = try ctx.appendBlock();
    const recurse = try ctx.appendBlock();
    _ = try ctx.buildCondBr(cond, base, recurse);

    ctx.setCurrentBlock(base);
    _ = try ctx.buildRet(n);

    ctx.setCurrentBlock(recurse);
    _ = try ctx.buildRet(n);

    try std.testing.expectEqual(@as(usize, 1), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 3), ctx.getBlockCountIn(fib));
}

test "print textual IR" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("main", i32_ty, 0);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const zero = @as(Value, @enumFromInt(0));
    _ = try ctx.buildRet(zero);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try ctx.print(buf.writer(std.testing.allocator));

    const text = try buf.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "@main") != null);
}

test "all binary opcodes compile" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(false, 32);

    const func = try ctx.addFunction("test_ops", i32_ty, 2);
    ctx.setCurrentFunction(func);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    _ = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildSub(i32_ty, a, b);
    _ = try ctx.buildMul(i32_ty, a, b);
    _ = try ctx.buildSDiv(i32_ty, a, b);
    _ = try ctx.buildUDiv(i32_ty, a, b);
    _ = try ctx.buildAnd(i32_ty, a, b);
    _ = try ctx.buildOr(i32_ty, a, b);
    _ = try ctx.buildXor(i32_ty, a, b);
    _ = try ctx.buildShl(i32_ty, a, b);
    _ = try ctx.buildShr(i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_eq, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ne, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_slt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sle, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sgt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sge, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ult, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ule, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ugt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_uge, i32_ty, a, b);

    try std.testing.expectEqual(@as(usize, 21), ctx.getInstructionCountIn(func));
}

test "memory and call instructions" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    const ptr_ty = try ctx.ptrType(i32_ty);

    const callee = try ctx.addFunction("callee", i32_ty, 1);
    const caller = try ctx.addFunction("caller", i32_ty, 1);
    ctx.setCurrentFunction(caller);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const n = ctx.getParam(0);

    // alloca + store + load
    const alloca = try ctx.buildAlloca(ptr_ty);
    _ = try ctx.buildStore(i32_ty, alloca, n);
    const loaded = try ctx.buildLoad(i32_ty, alloca);

    // call
    _ = try ctx.buildCall(callee, i32_ty, &.{loaded});

    _ = try ctx.buildRet(loaded);

    try std.testing.expectEqual(@as(usize, 2), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 6), ctx.getInstructionCountIn(caller));
}

test "function type creation" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    const void_ty = try ctx.voidType();

    const fty = try ctx.funcType(i32_ty, &.{ i32_ty, i32_ty });
    _ = fty;
    const fty2 = try ctx.funcType(void_ty, &.{});
    _ = fty2;

    try std.testing.expectEqual(@as(usize, 4), ctx.getTypeCount());
}
