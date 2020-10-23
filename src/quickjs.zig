const std = @import("std");

const is64bit = @bitSizeOf(usize) == 64;

fn isStringLiteral(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        else => false,
        .Pointer => |ptr| {
            return switch (@typeInfo(ptr.child)) {
                else => false,
                .Array => |arr| arr.child == u8 and arr.sentinel == @as(u8, 0),
            };
        },
    };
}

pub const JsModuleLoader = struct {
    normalizefn: ?fn (self: *@This(), ctx: *JsContext, base: [*:0]const u8, name: [*:0]const u8) [*:0]const u8 = null,
    loaderfn: fn (self: *@This(), ctx: *JsContext, name: [*:0]const u8) ?*JsModuleDef,

    fn normalize(ctx: *JsContext, base: [*:0]const u8, name: [*:0]const u8, ptr: ?*c_void) callconv(.C) [*:0]const u8 {
        const self = @ptrCast(*@This(), @alignCast(@alignOf(*@This()), ptr.?));
        const f = self.*.normalizefn.?;
        return f(self, ctx, base, name);
    }

    fn trampoline(ctx: *JsContext, name: [*:0]const u8, ptr: ?*c_void) callconv(.C) ?*JsModuleDef {
        const self = @ptrCast(*@This(), @alignCast(@alignOf(*@This()), ptr.?));
        return self.*.loaderfn(self, ctx, name);
    }
};

pub const JsRuntime = opaque {
    extern fn JS_ExecutePendingJob(rt: *JsRuntime, pctx: *?*JsContext) c_int;

    pub fn init() *@This() {
        return JS_NewRuntime().?;
    }

    pub fn deinit(self: *@This()) void {
        JS_FreeRuntime(self);
    }

    pub fn gc(self: *@This()) void {
        JS_RunGC(self);
    }

    pub fn setModuleLoader(self: *@This(), loader: *JsModuleLoader) void {
        JS_SetModuleLoaderFunc(
            self,
            if (loader.normalizefn != null) JsModuleLoader.normalize else null,
            JsModuleLoader.trampoline,
            @ptrCast(?*c_void, loader),
        );
    }

    pub fn setOpaque(self: *@This(), ptr: ?*c_void) void {
        JS_SetRuntimeOpaque(self, ptr);
    }

    pub fn getOpaque(self: *@This()) ?*c_void {
        return JS_GetRuntimeOpaque(self);
    }

    pub fn getOpaqueT(self: *@This(), comptime T: type) ?*T {
        return @ptrCast(?*T, @alignCast(@alignOf(*T), self.getOpaque()));
    }

    pub fn pending(self: *@This()) bool {
        var ctx: ?*JsContext = null;
        const ret = JS_ExecutePendingJob(self, &ctx);
        return ret > 0;
    }
};

pub const JsContext = opaque {
    pub fn init(rt: *JsRuntime) !*@This() {
        return JS_NewContext(rt) orelse return error.FailedToCreateContext;
    }

    pub fn deinit(self: *@This()) void {
        JS_FreeContext(self);
    }

    pub fn clone(self: *@This()) !*@This() {
        return JS_DupContext(self) orelse return error.FailedToCreateContext;
    }

    pub fn getRuntime(self: *@This()) *JsRuntime {
        return JS_GetRuntime(self);
    }

    pub fn getException(self: *@This()) JsValue {
        return JS_GetException(self);
    }

    pub fn detect(self: *@This(), class: Detect, val: JsValue) bool {
        return switch (class) {
            .Error => JS_IsError(self, val),
            .Function => JS_IsFunction(self, val),
            .Constructor => JS_IsConstructor(self, val),
            .Array => JS_IsArray(self, val),
        };
    }

    pub fn resetUncatchableError(self: *@This()) void {
        JS_ResetUncatchableError(self);
    }

    pub fn throw(self: *@This(), err: JsError) JsValue {
        return switch (err) {
            .OutOfMemory => JS_ThrowOutOfMemory(self),
            .Syntax => |str| JS_ThrowSyntaxError(self, "%.*s", str.len, str.ptr),
            .Type => |str| JS_ThrowTypeError(self, "%.*s", str.len, str.ptr),
            .Reference => |str| JS_ThrowReferenceError(self, "%.*s", str.len, str.ptr),
            .Range => |str| JS_ThrowRangeError(self, "%.*s", str.len, str.ptr),
            .Internal => |str| JS_ThrowInternalError(self, "%.*s", str.len, str.ptr),
        };
    }

    pub fn setConstructorBit(self: *@This(), val: JsValue, bit: bool) !void {
        if (!JS_SetConstructorBit(self, val, bit)) return error.FailedToSetConstructorBit;
    }

    pub fn eval(self: *@This(), input: [:0]const u8, filename: [*:0]const u8, flags: packed struct {
        module: bool = false,
        unused: u2 = 0,
        strict: bool = false,
        strip: bool = false,
        compile: bool = false,
        backtrace: bool = false,
    }) JsValue {
        return JS_Eval(
            self,
            input.ptr,
            input.len,
            filename,
            @intCast(c_int, @bitCast(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(flags))), flags)),
        );
    }

    pub fn evalFunction(self: *@This(), func: JsValue) JsValue {
        return JS_EvalFunction(self, func);
    }

    pub fn getGlobal(self: *@This()) JsValue {
        return JS_GetGlobalObject(self);
    }

    fn dumpObject(self: *@This(), out: anytype, ex: JsValue) void {
        const str = ex.as(JsString, self) catch return;
        defer str.deinit(self);
        out.print("{}\n", .{str.data}) catch {};
    }

    fn dumpException(self: *@This(), ex: JsValue) void {
        const writer = std.io.getStdErr().writer();
        self.dumpObject(writer, ex);
        if (ex.getProperty(self, JsAtom.comptimeAtom(self, "stack"))) |stack| {
            defer stack.deinit(self);
            self.dumpObject(writer, stack);
        }
    }

    pub fn dumpError(self: *@This()) void {
        const ex = self.getException();
        defer ex.deinit(self);
        self.dumpException(ex);
    }

    pub fn setConstructor(self: *@This(), func: JsValue, proto: JsValue) void {
        JS_SetConstructor(self, func, proto);
    }
};
pub const JsClassID = extern enum(u32) {
    initial,
    _,

    pub fn init(self: *@This()) void {
        _ = JS_NewClassID(self);
    }

    pub fn define(self: @This(), rt: *JsRuntime, def: *const JsClassDef) void {
        if (!JS_IsRegisteredClass(rt, self))
            _ = JS_NewClass(rt, self, def);
    }

    pub fn setProto(self: @This(), ctx: *JsContext, proto: JsValue) void {
        JS_SetClassProto(ctx, self, proto);
    }

    pub fn getProto(self: @This(), ctx: *JsContext) JsValue {
        return JS_GetClassProto(ctx, self);
    }
};
pub const JsAtom = extern enum(u32) {
    invalid,
    _,

    extern fn JS_NewAtomLen(ctx: *JsContext, str: [*]const u8, len: usize) JsAtom;
    extern fn JS_NewAtom(ctx: *JsContext, str: [*:0]const u8) JsAtom;
    extern fn JS_NewAtomUInt32(ctx: *JsContext, n: u32) JsAtom;
    extern fn JS_DupAtom(ctx: *JsContext, v: JsAtom) JsAtom;
    extern fn JS_FreeAtom(ctx: *JsContext, v: JsAtom) void;
    extern fn JS_FreeAtomRT(rt: *JsRuntime, v: JsAtom) void;
    extern fn JS_AtomToValue(ctx: *JsContext, atom: JsAtom) JsValue;
    extern fn JS_AtomToString(ctx: *JsContext, atom: JsAtom) JsValue;
    extern fn JS_AtomToCString(ctx: *JsContext, atom: JsAtom) ?[*:0]const u8;
    extern fn JS_ValueToAtom(ctx: *JsContext, val: JsValue) JsAtom;

    pub fn comptimeAtom(ctx: *JsContext, comptime name: []const u8) @This() {
        const Storage = opaque {
            threadlocal var atom: JsAtom = .invalid;
        };
        if (Storage.atom == .invalid) Storage.atom = initAtom(ctx, name);
        return Storage.atom;
    }

    pub fn initAtom(ctx: *JsContext, val: anytype) @This() {
        return switch (@TypeOf(val)) {
            []const u8 => JS_NewAtomLen(ctx, val.ptr, val.len),
            [*:0]const u8 => JS_NewAtom(ctx, val),
            u32 => JS_NewAtomUInt32(ctx, val),
            i32, usize, i64, u64 => JS_ValueToAtom(ctx, JsValue.from(val)),
            JsValue => JS_ValueToAtom(ctx, val),
            else => if (comptime isStringLiteral(@TypeOf(val)))
                initAtom(ctx, @as([*:0]const u8, val))
            else
                @compileError("unsupported type: " ++ @typeName(@TypeOf(val))),
        };
    }

    pub fn clone(self: @This(), ctx: *JsContext) @This() {
        return JS_DupAtom(ctx, self);
    }

    pub fn deinit(self: @This(), ctx: *JsContext) void {
        JS_FreeAtom(ctx, self);
    }

    pub fn deinitRT(self: @This(), rt: *JsRuntime) void {
        JS_FreeAtomRT(rt, self);
    }

    pub fn toValue(self: @This(), ctx: *JsContext) JsValue {
        return Js_AtomToValue(ctx, self);
    }

    pub fn toString(self: @This(), ctx: *JsContext) JsValue {
        return JS_AtomToString(ctx, self);
    }

    pub fn toCString(self: @This(), ctx: *JsContext) ?JsString {
        const ret = JS_AtomToCString(ctx, self) orelse return null;
        return JsString{ .data = ret[0..std.mem.lenZ(ret) :0] };
    }
};
pub const JsPropertyEnum = extern struct {
    enumerable: bool,
    atom: JsAtom,
};
pub const JsPropertyDescriptor = extern struct {
    flags: c_int,
    value: JsValue,
    getter: JsValue,
    setter: JsValue,
};

const JsTag = extern enum(isize) {
    First = -11,
    BigDecimal = -11,
    BigInt = -10,
    BigFloat = -9,
    Symbol = -8,
    String = -7,
    Module = -3,
    FunctionByteCode = -2,
    Object = -1,

    Integer = 0,
    Boolean = 1,
    Null = 2,
    Undefined = 3,
    Uninitialized = 4,
    CatchOffset = 5,
    Exception = 6,
    Float64 = 7,

    _,
};

pub const RawValue = union(JsTag) {
    BigDecimal: usize,
    First: usize,
    BigInt: usize,
    BigFloat: usize,
    Symbol: usize,
    String: usize,
    Module: *JsModuleDef,
    FunctionByteCode: usize,
    Object: usize,
    Integer: i32,
    Boolean: bool,
    Null: void,
    Undefined: void,
    Uninitialized: void,
    CatchOffset: i32,
    Exception: i32,
    Float64: f64,
};

pub const ValueSource = union(enum) {
    Uninitialized: void,
    Undefined: void,
    Null: void,
    Boolean: bool,
    Integer: i32,
    Float64: f64,
    Error: void,
    Array: void,
    Object: struct {
        proto: ?JsValue = null,
        class: ?JsClassID = null,
        temp: ?[]const JsCFunctionListEntry = null,
    },
    String: []const u8,
    ArrayBuffer: []const u8,
    Function: struct {
        name: [*:0]const u8 = "",
        length: c_int,
        func: JsCFunctionTypeZ,
        magic: c_int = 0,
        data: ?[]const JsValue = null,
    },
};

const JSRefCountHeader = extern struct {
    rc: c_int,
};

fn safeIntCast(comptime T: type, val: anytype) ?T {
    if (val >= std.math.minInt(T) and val <= std.math.maxInt(T)) return @intCast(T, val);
    return null;
}

pub const JsString = struct {
    data: [:0]const u8,

    pub fn deinit(self: @This(), ctx: *JsContext) void {
        JS_FreeCString(ctx, self.data.ptr);
    }

    pub fn dupe(self: @This(), ctx: *JsContext, allocator: *std.mem.Allocator) ![:0]u8 {
        defer self.deinit(ctx);
        return allocator.dupeZ(u8, self.data);
    }
};

pub const PropertyDefinition = struct {
    configurable: bool,
    writable: bool,
    enumerable: bool,
    data: union(enum) {
        getset: struct {
            getter: ?JsValue = null,
            setter: ?JsValue = null,
        },
        value: JsValue,
        none: void,
    },

    fn toFlags(self: @This()) c_int {
        var ret: c_int = 0;
        ret |= 1 << 8;
        if (self.configurable) ret |= 1 << 0;
        ret |= 1 << 9;
        if (self.writable) ret |= 1 << 1;
        ret |= 1 << 10;
        if (self.enumerable) ret |= 1 << 2;
        switch (self.data) {
            .none => {},
            .getset => |data| {
                ret |= 1 << 4;
                if (data.getter != null) ret |= 1 << 11;
                if (data.setter != null) ret |= 1 << 12;
            },
            .value => ret |= 1 << 13,
        }
        return ret;
    }
};

pub const JsValue = extern struct {
    storage: if (is64bit)
        extern struct {
            a: u64,
            b: i64,
        }
    else
        extern struct {
            a: u32,
            b: i32,
        },

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{value.getValue()});
    }

    fn box(comptime T: type) type {
        const ret = if (is64bit)
            extern struct {
                val: T align(8),
                tag: i64,

                pub fn init(val: T, tag: i64) @This() {
                    return .{ .val = val, .tag = tag };
                }

                pub fn transmit(val: T, tag: i64) u128 {
                    return @bitCast(u128, init(val, tag));
                }

                pub fn from(e: JsValue) @This() {
                    return @bitCast(@This(), e);
                }
            }
        else switch (T) {
            bool, i32, usize => extern struct {
                val: T align(4),
                tag: i32,

                pub fn init(val: T, tag: i32) @This() {
                    return .{ .val = val, .tag = tag };
                }

                pub fn transmit(val: T, tag: i32) u64 {
                    return @bitCast(u64, init(val, tag));
                }

                pub fn from(e: JsValue) @This() {
                    return @bitCast(@This(), e);
                }
            },
            f64 => extern struct {
                val: T,

                pub fn init(val: T, tag: i32) @This() {
                    return .{ .val = val };
                }

                pub fn transmit(val: T, tag: i32) u64 {
                    return @bitCast(u64, init(val, tag)) + (JS_FLOAT64_TAG_ADDEND << 32);
                }

                pub fn from(e: JsValue) @This() {
                    return @bitCast(@This(), @bitCast(u64, e.storage) - (JS_FLOAT64_TAG_ADDEND << 32));
                }
            },
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };
        comptime {
            std.debug.assert(@sizeOf(ret) == @sizeOf(@This()));
        }
        return ret;
    }

    const JS_FLOAT64_TAG_ADDEND: comptime_int = 0x7ff80000 - @enumToInt(JsTag.First) + 1;
    const JS_NAN: comptime_int = 0x7ff8000000000000 - (JS_FLOAT64_TAG_ADDEND << 32);

    pub fn getTag(self: @This()) JsTag {
        const r = box(bool).from(self).tag;
        return @intToEnum(JsTag, r);
    }

    fn tagIsFloat64(tag: JsTag) bool {
        return if (is64bit)
            tag == JsTag.Float64
        else
            @bitCast(u32, @enumToInt(tag) - @enumToInt(JsTag.First)) >= @bitCast(u32, @enumToInt(JsTag.Float64) - @enumToInt(JsTag.First));
    }

    pub fn isFloat64(self: @This()) bool {
        const tag = self.getTag();
        return tagIsFloat64(tag);
    }

    pub fn isNumber(self: @This()) bool {
        const tag = self.getTag();
        return tag == JsTag.Integer or tagIsFloat64(tag);
    }

    pub fn getNormTag(self: @This()) JsTag {
        const tag = self.getTag();
        return if (is64bit or !self.isFloat64()) tag else JsTag.Float64;
    }

    pub fn isNan(self: @This()) bool {
        if (is64bit) {
            if (self.getTag() != JsTag.Float64) return false;
            return std.math.isNan(box(f64).from(self).val);
        } else {
            return self.getTag() == JS_NAN >> 32;
        }
    }

    pub fn getPointer(self: @This()) usize {
        return box(usize).from(self).val;
    }

    pub fn getPointerT(self: @This(), comptime T: type) ?*T {
        return @intToPtr(?*T, self.getPointer());
    }

    pub fn getValue(self: @This()) RawValue {
        const integer = box(i32).from(self).val;
        const boolean = box(bool).from(self).val;
        const pointer = self.getPointer();
        const float64 = box(f64).from(self).val;

        return switch (self.getNormTag()) {
            .BigDecimal => .{ .BigDecimal = pointer },
            .BigInt => .{ .BigInt = pointer },
            .BigFloat => .{ .BigFloat = pointer },
            .Symbol => .{ .Symbol = pointer },
            .String => .{ .String = pointer },
            .Module => .{ .Module = @intToPtr(*JsModuleDef, pointer) },
            .FunctionByteCode => .{ .FunctionByteCode = pointer },
            .Object => .{ .Object = pointer },
            .Integer => .{ .Integer = integer },
            .Boolean => .{ .Boolean = boolean },
            .Null => .Null,
            .Undefined => .Undefined,
            .Uninitialized => .Uninitialized,
            .CatchOffset => .{ .CatchOffset = integer },
            .Exception => .{ .Exception = integer },
            .Float64 => .{ .Float64 = float64 },
            else => @panic("invalid data"),
        };
    }

    pub fn make(val: anytype, tag: JsTag) @This() {
        const r = switch (@TypeOf(val)) {
            bool, usize, i32, f64 => box(@TypeOf(val)).transmit(val, @enumToInt(tag)),
            else => @compileError("unsupported type: " ++ @typeName(@TypeOf(val))),
        };
        return @bitCast(@This(), r);
    }

    pub fn fromRaw(val: RawValue) @This() {
        return switch (val) {
            .Integer => |int| make(int, .Integer),
            .Boolean => |b| make(b, .Boolean),
            .Null => make(false, .Null),
            .Undefined => make(false, .Undefined),
            .Uninitialized => make(false, .Uninitialized),
            .Float64 => |double| make(double, .Float64),
            else => @panic("unsupported value"),
        };
    }

    pub fn from(val: anytype) @This() {
        return switch (@TypeOf(val)) {
            i8, i16, u8, u16, c_int => fromRaw(.{ .Integer = @intCast(i32, val) }),
            i32 => fromRaw(.{ .Integer = val }),
            u32, i64, u64, usize => if (safeIntCast(i32, val)) |safe| fromRaw(.{ .Integer = safe }) else fromRaw(.{ .Float64 = @intToFloat(f64, val) }),
            f64 => blk: {
                if (val >= @intToFloat(f64, std.math.minInt(i32)) and val <= @intToFloat(f64, std.math.maxInt(i32))) {
                    const ru = @bitCast(u64, val);
                    const i = @floatToInt(i32, val);
                    const rdu = @bitCast(u64, @intToFloat(f64, i));
                    if (ru == rdu) {
                        break :blk fromRaw(.{ .Integer = i });
                    }
                }
                break :blk fromRaw(.{ .Float64 = val });
            },
            bool => fromRaw(.{ .Boolean = val }),
            else => @compileError("unsupported type: " ++ @typeName(@TypeOf(val))),
        };
    }

    pub fn init(ctx: *JsContext, src: ValueSource) @This() {
        return switch (src) {
            .Integer => |int| make(int, .Integer),
            .Boolean => |b| make(b, .Boolean),
            .Null => make(false, .Null),
            .Undefined => make(false, .Undefined),
            .Uninitialized => make(false, .Uninitialized),
            .Float64 => |double| make(double, .Float64),
            .Error => JS_NewError(ctx),
            .Array => JS_NewArray(ctx),
            .Object => |opts| blk: {
                const ret = inner: {
                    if (opts.proto) |proto| {
                        if (opts.class) |class| {
                            break :inner JS_NewObjectProtoClass(ctx, proto, class);
                        } else {
                            break :inner JS_NewObjectProto(ctx, proto);
                        }
                    } else {
                        if (opts.class) |class| {
                            break :inner JS_NewObjectClass(ctx, class);
                        } else {
                            break :inner JS_NewObject(ctx);
                        }
                    }
                };
                if (opts.temp) |temp|
                    JS_SetPropertyFunctionList(ctx, ret, temp.ptr, @intCast(c_int, temp.len));
                break :blk ret;
            },
            .String => |data| JS_NewStringLen(ctx, data.ptr, data.len),
            .ArrayBuffer => |data| JS_NewArrayBufferCopy(ctx, data.ptr, data.len),
            .Function => |def| if (def.data) |data|
                JS_NewCFunctionData(
                    ctx,
                    def.func.dump(),
                    def.name,
                    def.length,
                    std.meta.activeTag(def.func),
                    def.magic,
                    @intCast(c_int, data.len),
                    data.ptr,
                )
            else
                JS_NewCFunction2(
                    ctx,
                    def.func.dump(),
                    def.name,
                    def.length,
                    std.meta.activeTag(def.func),
                    def.magic,
                ),
        };
    }

    pub fn fromBig(ctx: *JsContext, val: anytype) @This() {
        return switch (@TypeOf(val)) {
            i64 => JS_NewBigInt64(ctx, val),
            u64 => JS_NewBigUint64(ctx, val),
            isize => JS_NewBigInt64(ctx, @intCast(i64, val)),
            usize => JS_NewBigUint64(ctx, @intCast(u64, val)),
            else => @compileError("unsupported type: " ++ @typeName(@TypeOf(val))),
        };
    }

    pub fn hasRefCount(self: @This()) bool {
        return @bitCast(usize, self.getTag()) >= @bitCast(usize, @enumToInt(JsTag.First));
    }

    fn canBeFreed(self: @This()) bool {
        return self.hasRefCount() and self.getTag() != .Module;
    }

    pub fn deinit(self: @This(), ctx: *JsContext) void {
        self.deinitRT(ctx.getRuntime());
    }

    pub fn deinitRT(self: @This(), rt: *JsRuntime) void {
        if (self.canBeFreed()) {
            const header = @intToPtr(*JSRefCountHeader, self.getPointer());
            header.rc -= 1;
            if (header.rc <= 0) __JS_FreeValueRT(rt, self);
        }
    }

    pub fn clone(self: @This()) @This() {
        if (self.hasRefCount()) {
            const header = @intToPtr(*JSRefCountHeader, self.getPointer());
            header.rc += 1;
        }
        return self;
    }

    pub fn as(self: @This(), comptime T: type, ctx: *JsContext) !T {
        switch (T) {
            bool => {
                const r = JS_ToBool(ctx, self);
                if (r == -1) return error.FailedError;
                return r != 0;
            },
            i32 => {
                var res: i32 = undefined;
                const r = JS_ToInt32(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return res;
            },
            u32 => {
                var res: i32 = undefined;
                const r = JS_ToInt64Ext(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return @intCast(u32, res);
            },
            i64 => {
                var res: i64 = undefined;
                const r = JS_ToInt64Ext(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return res;
            },
            u64 => {
                var res: u64 = undefined;
                const r = JS_ToIndex(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return res;
            },
            f64 => {
                var res: f64 = undefined;
                const r = JS_ToFloat64(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return res;
            },
            usize => {
                var res: u64 = undefined;
                const r = JS_ToIndex(ctx, &res, self);
                if (r == -1) return error.FailedToConvert;
                return @intCast(usize, res);
            },
            JsString => {
                var len: usize = undefined;
                const r = JS_ToCStringLen2(ctx, &len, self, 0) orelse return error.FailedToConvert;
                return T{ .data = r[0..len :0] };
            },
            []u8 => {
                var len: usize = undefined;
                const r = JS_GetArrayBuffer(ctx, &len, self) orelse return error.FailedToConvert;
                return r[0..len];
            },
            else => @compileError("unsupported type: " ++ @typeName(T)),
        }
    }

    pub fn toString(self: @This()) @This() {
        return JS_ToString(ctx, self);
    }

    pub fn toPropertyKey(self: @This()) @This() {
        return JS_ToPropertyKey(ctx, self);
    }

    pub fn getProperty(self: @This(), ctx: *JsContext, key: anytype) ?@This() {
        const atom = toAtom(ctx, key);
        defer killAtom(ctx, key, atom);
        const ret = JS_GetPropertyInternal(ctx, self, atom, self, 0);
        if (ret.getTag() == .Undefined) return null;
        return ret;
    }

    pub fn setProperty(self: @This(), ctx: *JsContext, key: anytype, value: JsValue) !void {
        const atom = toAtom(ctx, key);
        defer killAtom(ctx, key, atom);
        const ret = JS_SetPropertyInternal(ctx, self, atom, value, 1 << 14);
        if (ret == -1) return error.FailedToSetProperty;
    }

    pub fn hasProperty(self: @This(), ctx: *JsContext, key: JsAtom) !bool {
        const ret = JS_HasProperty(ctx, self, key);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn deleteProperty(self: @This(), ctx: *JsContext, key: JsAtom) !bool {
        const ret = JS_DeleteProperty(ctx, self, key, 1 << 15);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn isExtensible(self: @This(), ctx: *JsContext) !bool {
        const ret = JS_IsExtensible(ctx, self);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn preventExtensions(self: @This(), ctx: *JsContext) !bool {
        const ret = JS_PreventExtensions(ctx, self);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn setPrototype(self: @This(), ctx: *JsContext, target: @This()) !bool {
        const ret = JS_SetPrototype(ctx, self, target);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn getPrototype(self: @This(), ctx: *JsContext) ?@This() {
        const ret = JS_GetPrototype(ctx, self);
        if (ret.getTag() == .Undefined) return null;
        return ret;
    }

    pub fn getOwnPropertyNames(self: @This(), ctx: *JsContext, options: packed struct {
        string: bool = true,
        symbol: bool = false,
        private: bool = false,
        enumOnly: bool = false,
        setEnum: bool = false,
    }) ![]JsPropertyEnum {
        var arr: [*]JsPropertyEnum = undefined;
        var len: u32 = 0;
        const ret = JS_GetOwnPropertyNames(ctx, &arr, &len, self, @intCast(c_int, @bitCast(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(options))), options)));
        if (ret != 0) return error.NotAnObject;
        return arr[0..len];
    }

    pub fn getOwnProperty(self: @This(), ctx: *JsContext, key: JsAtom) !JsPropertyDescriptor {
        var desc: JsPropertyDescriptor = undefined;
        const ret = JS_GetOwnProperty(ctx, &desc, self, key);
        if (ret == -1) return error.NotAnObject;
        return desc;
    }

    pub fn call(self: @This(), ctx: *JsContext, this: @This(), args: []const @This()) @This() {
        return JS_Call(ctx, self, this, @intCast(c_int, args.len), args.ptr);
    }

    pub fn invoke(self: @This(), ctx: *JsContext, key: JsAtom, this: @This(), args: []const @This()) @This() {
        return JS_Call(ctx, self, key, this, @intCast(c_int, args.len), args.ptr);
    }

    pub fn construct(self: @This(), ctx: *JsContext, args: []const @This()) @This() {
        return JS_CallConstructor(ctx, self, @intCast(c_int, args.len), args.ptr);
    }

    pub fn instanceOf(self: @This(), ctx: *JsContext, constructor: @This()) !bool {
        const ret = JS_IsInstanceOf(ctx, self, constructor);
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    fn toAtom(ctx: *JsContext, key: anytype) JsAtom {
        return switch (@TypeOf(key)) {
            JsAtom => key,
            else => JsAtom.initAtom(ctx, key),
        };
    }

    fn killAtom(ctx: *JsContext, key: anytype, atom: JsAtom) void {
        if (@TypeOf(key) == JsAtom) return;
        atom.deinit(ctx);
    }

    pub fn defineProperty(self: @This(), ctx: *JsContext, atom: JsAtom, def: PropertyDefinition) !bool {
        switch (def.data) {
            .none => {},
            .getset => |data| {
                const getter = data.getter orelse fromRaw(.Undefined);
                const setter = data.setter orelse fromRaw(.Undefined);
                const ret = JS_DefinePropertyGetSet(ctx, self, atom, getter, setter, def.toFlags());
                if (ret == -1) return error.NotAnObject;
                return ret != 0;
            },
            .value => |data| {
                const ret = JS_DefinePropertyValue(ctx, self, atom, data, def.toFlags());
                if (ret == -1) return error.NotAnObject;
                return ret != 0;
            },
        }
        const ret = JS_DefineProperty(ctx, self, atom, fromRaw(.Undefined), fromRaw(.Undefined), fromRaw(.Undefined), def.toFlags());
        if (ret == -1) return error.NotAnObject;
        return ret != 0;
    }

    pub fn setOpaque(self: @This(), data: ?*c_void) void {
        JS_SetOpaque(self, data);
    }

    pub fn getOpaque(self: @This(), class_id: JsClassID) ?*c_void {
        return JS_GetOpaque(self, class_id);
    }

    pub fn getOpaqueT(self: @This(), comptime T: type, class_id: JsClassID) ?*T {
        return @ptrCast(?*T, @alignCast(@alignOf(*T), JS_GetOpaque(self, class_id)));
    }

    pub fn fromJSON(self: @This(), ctx: *JsContext, data: [:0]const u8, ext: bool) !@This() {
        const ret = JS_ParseJSON2(ctx, data.ptr, data.len, "<input>", if (ext) 1 else 0);
        if (ctx.detect(.Exception, ret)) return error.FailedToParseJSON;
        return ret;
    }

    pub fn jsonStringify(self: @This(), ctx: *JsContext, replacer: @This(), space0: @This()) !@This() {
        const ret = JS_JSONStringify(ctx, self, replacer, space0);
        if (ctx.detect(.Exception, ret)) return error.FailedToStringify;
        return ret;
    }

    pub fn mark(self: @This(), tt: *JsRuntime, markFunc: JS_MarkFunc) void {
        JS_MarkValue(tt, self, markFunc);
    }
};

const JsGCObjectHeader = opaque {};
pub const JS_MarkFunc = fn (rt: *JsRuntime, gp: *JsGCObjectHeader) callconv(.C) void;
extern fn JS_NewRuntime() ?*JsRuntime;
extern fn JS_FreeRuntime(rt: *JsRuntime) void;
extern fn JS_RunGC(rt: *JsRuntime) void;
extern fn JS_MarkValue(tt: *JsRuntime, val: JsValue, markFunc: JS_MarkFunc) void;
extern fn JS_GetRuntimeOpaque(rt: *JsRuntime) ?*c_void;
extern fn JS_SetRuntimeOpaque(rt: *JsRuntime, ptr: ?*c_void) void;

extern fn JS_NewContext(rt: *JsRuntime) ?*JsContext;
extern fn JS_FreeContext(ctx: *JsContext) void;
extern fn JS_DupContext(ctx: *JsContext) ?*JsContext;
extern fn JS_GetRuntime(ctx: *JsContext) *JsRuntime;
extern fn JS_SetClassProto(ctx: *JsContext, class_id: JsClassID, obj: JsValue) void;
extern fn JS_GetClassProto(ctx: *JsContext, class_id: JsClassID) JsValue;

extern fn JS_NewClassID(pclass_id: *JsClassID) JsClassID;
extern fn JS_NewClass(rt: *JsRuntime, class_id: JsClassID, class_def: *const JsClassDef) c_int;
extern fn JS_IsRegisteredClass(rt: *JsRuntime, class_id: JsClassID) bool;

extern fn __JS_FreeValue(ctx: *JsContext, v: JsValue) void;
extern fn __JS_FreeValueRT(rt: *JsRuntime, v: JsValue) void;
extern fn JS_ToBool(ctx: *JsContext, val: JsValue) c_int;
extern fn JS_ToInt32(ctx: *JsContext, pres: *i32, val: JsValue) c_int;
extern fn JS_ToInt64Ext(ctx: *JsContext, pres: *i64, val: JsValue) c_int;
extern fn JS_ToIndex(ctx: *JsContext, pres: *u64, val: JsValue) c_int;
extern fn JS_ToFloat64(ctx: *JsContext, pres: *f64, val: JsValue) c_int;

extern fn JS_NewStringLen(ctx: *JsContext, str: [*]const u8, len: usize) JsValue;
extern fn JS_NewString(ctx: *JsContext, str: [*:0]const u8) JsValue;
extern fn JS_NewAtomString(ctx: *JsContext, str: [*:0]const u8) JsValue;
extern fn JS_ToString(ctx: *JsContext, val: JsValue) JsValue;
extern fn JS_ToPropertyKey(ctx: *JsContext, val: JsValue) JsValue;
extern fn JS_ToCStringLen2(ctx: *JsContext, plen: *usize, val1: JsValue, cesu8: c_int) ?[*]const u8;
extern fn JS_FreeCString(ctx: *JsContext, ptr: [*]const u8) void;

extern fn JS_GetArrayBuffer(ctx: *JsContext, size: *usize, obj: JsValue) ?[*]u8;

extern fn JS_NewObjectProtoClass(ctx: *JsContext, proto: JsValue, class_id: JsClassID) JsValue;
extern fn JS_NewObjectClass(ctx: *JsContext, class_id: JsClassID) JsValue;
extern fn JS_NewObjectProto(ctx: *JsContext, proto: JsValue) JsValue;
extern fn JS_NewObject(ctx: *JsContext) JsValue;
extern fn JS_IsFunction(ctx: *JsContext, val: JsValue) bool;
extern fn JS_IsConstructor(ctx: *JsContext, val: JsValue) bool;
extern fn JS_SetConstructorBit(ctx: *JsContext, func_obj: JsValue, val: bool) bool;
extern fn JS_NewArray(ctx: *JsContext) JsValue;
extern fn JS_IsArray(ctx: *JsContext, val: JsValue) bool;

extern fn JS_GetPropertyInternal(ctx: *JsContext, obj: JsValue, prop: JsAtom, receiver: JsValue, throw_ref_error: c_int) JsValue;
extern fn JS_GetPropertyStr(ctx: *JsContext, this_obj: JsValue, prop: [*:0]const u8) JsValue;
extern fn JS_GetPropertyUint32(ctx: *JsContext, this_obj: JsValue, idx: u32) JsValue;
extern fn JS_SetPropertyInternal(ctx: *JsContext, this_obj: JsValue, prop: JsAtom, val: JsValue, flags: c_int) c_int;
extern fn JS_SetPropertyUint32(ctx: *JsContext, this_obj: JsValue, idx: u32, val: JsValue) c_int;
extern fn JS_SetPropertyInt64(ctx: *JsContext, this_obj: JsValue, idx: i64, val: JsValue) c_int;
extern fn JS_SetPropertyStr(ctx: *JsContext, this_obj: JsValue, prop: [*c]const u8, val: JsValue) c_int;
extern fn JS_HasProperty(ctx: *JsContext, this_obj: JsValue, prop: JsAtom) c_int;
extern fn JS_IsExtensible(ctx: *JsContext, obj: JsValue) c_int;
extern fn JS_PreventExtensions(ctx: *JsContext, obj: JsValue) c_int;
extern fn JS_DeleteProperty(ctx: *JsContext, obj: JsValue, prop: JsAtom, flags: c_int) c_int;
extern fn JS_SetPrototype(ctx: *JsContext, obj: JsValue, proto_val: JsValue) c_int;
extern fn JS_GetPrototype(ctx: *JsContext, val: JsValue) JsValue;
extern fn JS_GetOwnPropertyNames(ctx: *JsContext, ptab: *[*]JsPropertyEnum, plen: *u32, obj: JsValue, flags: c_int) c_int;
extern fn JS_GetOwnProperty(ctx: *JsContext, desc: *JsPropertyDescriptor, obj: JsValue, prop: JsAtom) c_int;
extern fn JS_Call(ctx: *JsContext, func_obj: JsValue, this_obj: JsValue, argc: c_int, argv: [*]const JsValue) JsValue;
extern fn JS_Invoke(ctx: *JsContext, this_val: JsValue, atom: JsAtom, argc: c_int, argv: [*]const JsValue) JsValue;
extern fn JS_CallConstructor(ctx: *JsContext, func_obj: JsValue, argc: c_int, argv: [*]const JsValue) JsValue;
extern fn JS_CallConstructor2(ctx: *JsContext, func_obj: JsValue, new_target: JsValue, argc: c_int, argv: [*]const JsValue) JsValue;
extern fn JS_DetectModule(input: [*:0]const u8, input_len: usize) c_int;
extern fn JS_Eval(ctx: *JsContext, input: [*:0]const u8, input_len: usize, filename: [*:0]const u8, eval_flags: c_int) JsValue;
extern fn JS_EvalFunction(ctx: *JsContext, fun_obj: JsValue) JsValue;
extern fn JS_GetGlobalObject(ctx: *JsContext) JsValue;
extern fn JS_IsInstanceOf(ctx: *JsContext, val: JsValue, obj: JsValue) c_int;
extern fn JS_DefineProperty(ctx: *JsContext, this_obj: JsValue, prop: JsAtom, val: JsValue, getter: JsValue, setter: JsValue, flags: c_int) c_int;
extern fn JS_DefinePropertyValue(ctx: *JsContext, this_obj: JsValue, prop: JsAtom, val: JsValue, flags: c_int) c_int;
extern fn JS_DefinePropertyValueUint32(ctx: *JsContext, this_obj: JsValue, idx: u32, val: JsValue, flags: c_int) c_int;
extern fn JS_DefinePropertyValueStr(ctx: *JsContext, this_obj: JsValue, prop: [*c]const u8, val: JsValue, flags: c_int) c_int;
extern fn JS_DefinePropertyGetSet(ctx: *JsContext, this_obj: JsValue, prop: JsAtom, getter: JsValue, setter: JsValue, flags: c_int) c_int;
extern fn JS_SetOpaque(obj: JsValue, ptr: ?*c_void) void;
extern fn JS_GetOpaque(obj: JsValue, class_id: JsClassID) ?*c_void;
extern fn JS_GetOpaque2(ctx: *JsContext, obj: JsValue, class_id: JsClassID) ?*c_void;
extern fn JS_ParseJSON(ctx: *JsContext, buf: [*:0]const u8, buf_len: usize, filename: [*:0]const u8) JsValue;
extern fn JS_ParseJSON2(ctx: *JsContext, buf: [*:0]const u8, buf_len: usize, filename: [*:0]const u8, flags: c_int) JsValue;
extern fn JS_JSONStringify(ctx: *JsContext, obj: JsValue, replacer: JsValue, space0: JsValue) JsValue;
extern fn JS_NewArrayBufferCopy(ctx: *JsContext, buf: [*]const u8, len: usize) JsValue;

const JsModuleNormalizeFunc = fn (*JsContext, [*:0]const u8, [*:0]const u8, ?*c_void) callconv(.C) [*:0]const u8;
const JsModuleLoaderFunc = fn (*JsContext, [*:0]const u8, ?*c_void) callconv(.C) ?*JsModuleDef;
extern fn JS_SetModuleLoaderFunc(rt: *JsRuntime, module_normalize: ?JsModuleNormalizeFunc, module_loader: JsModuleLoaderFunc, ptr: ?*c_void) void;
extern fn JS_GetImportMeta(ctx: *JsContext, m: *JsModuleDef) JsValue;
extern fn JS_GetModuleName(ctx: *JsContext, m: *JsModuleDef) JsAtom;

const JsCFunction = fn (*JsContext, JsValue, c_int, [*]JsValue) callconv(.C) JsValue;
const JsCFunctionMagic = fn (*JsContext, JsValue, c_int, [*]JsValue, c_int) callconv(.C) JsValue;
const JsCFunctionData = fn (*JsContext, JsValue, c_int, [*]JsValue, c_int, [*]JsValue) callconv(.C) JsValue;

extern fn JS_NewCFunction2(
    ctx: *JsContext,
    func: JsCFunctionType,
    name: [*:0]const u8,
    length: c_int,
    cproto: JsCFunctionEnum,
    magic: c_int,
) JsValue;
extern fn JS_NewCFunctionData(
    ctx: *JsContext,
    func: JsCFunctionType,
    name: [*:0]const u8,
    length: c_int,
    cproto: JsCFunctionEnum,
    magic: c_int,
    data_len: c_int,
    data: [*]const JsValue,
) JsValue;
extern fn JS_SetConstructor(ctx: *JsContext, func: JsValue, proto: JsValue) void;

const JsCFunctionEnum = extern enum(u8) {
    generic,
    generic_magic,
    constructor,
    constructor_magic,
    constructor_or_func,
    f_f,
    f_f_f,
    getter,
    setter,
    getter_magic,
    setter_magic,
    iterator_next,
};
const JsCFunctionTypeZ = union(JsCFunctionEnum) {
    generic: JsCFunction,
    generic_magic: fn (ctx: *JsContext, this: JsValue, argc: c_int, argv: [*]JsValue, magic: c_int) callconv(.C) JsValue,
    constructor: JsCFunction,
    constructor_magic: fn (ctx: *JsContext, this: JsValue, argc: c_int, argv: [*]JsValue, magic: c_int) callconv(.C) JsValue,
    constructor_or_func: JsCFunction,
    f_f: fn (f64) callconv(.C) f64,
    f_f_f: fn (f64, f64) callconv(.C) f64,
    getter: fn (*JsContext, JsValue) callconv(.C) JsValue,
    setter: fn (*JsContext, JsValue, JsValue) callconv(.C) JsValue,
    getter_magic: fn (*JsContext, JsValue, c_int) callconv(.C) JsValue,
    setter_magic: fn (*JsContext, JsValue, JsValue, c_int) callconv(.C) JsValue,
    iterator_next: fn (*JsContext, JsValue, c_int, *JsValue, *c_int, c_int) callconv(.C) JsValue,

    pub fn dump(self: @This()) JsCFunctionType {
        return switch (self) {
            .generic => |origin| .{ .generic = origin },
            .generic_magic => |origin| .{ .generic_magic = origin },
            .constructor => |origin| .{ .constructor = origin },
            .constructor_magic => |origin| .{ .constructor_magic = origin },
            .constructor_or_func => |origin| .{ .constructor_or_func = origin },
            .f_f => |origin| .{ .f_f = origin },
            .f_f_f => |origin| .{ .f_f_f = origin },
            .getter => |origin| .{ .getter = origin },
            .setter => |origin| .{ .setter = origin },
            .getter_magic => |origin| .{ .getter_magic = origin },
            .setter_magic => |origin| .{ .setter_magic = origin },
            .iterator_next => |origin| .{ .iterator_next = origin },
        };
    }
};
const JsCGetter = fn (*JsContext, JsValue) callconv(.C) JsValue;
const JsCSetter = fn (*JsContext, JsValue, JsValue) callconv(.C) JsValue;
const JsCGetterMagic = fn (*JsContext, JsValue, c_int) callconv(.C) JsValue;
const JsCSetterMagic = fn (*JsContext, JsValue, JsValue, c_int) callconv(.C) JsValue;
const JsCFunctionType = extern union {
    none: usize,
    generic: JsCFunction,
    generic_magic: fn (ctx: *JsContext, this: JsValue, argc: c_int, argv: [*]JsValue, magic: c_int) callconv(.C) JsValue,
    constructor: JsCFunction,
    constructor_magic: fn (ctx: *JsContext, this: JsValue, argc: c_int, argv: [*]JsValue, magic: c_int) callconv(.C) JsValue,
    constructor_or_func: JsCFunction,
    f_f: fn (f64) callconv(.C) f64,
    f_f_f: fn (f64, f64) callconv(.C) f64,
    getter: JsCGetter,
    setter: JsCSetter,
    getter_magic: JsCGetterMagic,
    setter_magic: JsCSetterMagic,
    iterator_next: fn (*JsContext, JsValue, c_int, *JsValue, *c_int, c_int) callconv(.C) JsValue,
};

pub const JsCFunctionListEntry = extern struct {
    name: [*:0]const u8,
    prop_flags: u8,
    def_type: u8,
    magic: i16,
    u: U,
    const U = extern union {
        func: extern struct {
            length: u8,
            cproto: JsCFunctionEnum,
            cfunc: JsCFunctionType, // to avoid zig compiler TODO buf_read_value_bytes
        },
        getset: extern struct {
            get: JsCFunctionType,
            set: JsCFunctionType,
        },
        alias: extern struct {
            name: [*:0]const u8,
            base: c_int,
        },
        prop_list: extern struct {
            tab: [*]const JsCFunctionListEntry,
            len: c_int,
        },
        str: [*:0]const u8,
        int: i32,
        long: i64,
        double: f64,
    };

    pub const PropFlags = packed struct {
        configurable: bool = false,
        writeable: bool = false,
        enumerable: bool = false,

        fn dump(self: @This()) u8 {
            return @intCast(u8, @bitCast(u3, self));
        }
    };

    pub const Helper = struct {
        const Function = struct {
            length: u8,
            magic: i16 = 0,
            func: JsCFunctionTypeZ,
        };
        const GetSet = struct {
            get: ?JsCGetter = null,
            set: ?JsCSetter = null,
        };
        const GetSetMagic = struct {
            get: ?JsCGetterMagic = null,
            set: ?JsCSetterMagic = null,
            magic: i16,
        };
        const PropValue = union(enum) {
            str: [*:0]const u8,
            int: i32,
            long: i64,
            double: f64,
            undef: void,
        };
        const Prop = struct {
            value: PropValue,
            flags: PropFlags = .{},
        };
        const Object = struct {
            list: []const JsCFunctionListEntry,
            flags: PropFlags = .{},
        };
        const Alias = struct {
            name: [*:0]const u8,
            base: c_int = -1,
        };
        name: [*:0]const u8,
        def: union(enum) {
            func: Function,
            getset: GetSet,
            getsetMagic: GetSetMagic,
            prop: Prop,
            object: Object,
            alias: Alias,
        },
    };

    pub fn from(helper: Helper) @This() {
        const JS_PROP_CONFIGURABLE = 1 << 0;
        const JS_PROP_WRITABLE = 1 << 1;
        const JS_PROP_ENUMERABLE = 1 << 2;
        const JS_PROP_C_W_E = JS_PROP_CONFIGURABLE | (JS_PROP_WRITABLE | JS_PROP_ENUMERABLE);
        const JS_PROP_LENGTH = 1 << 3;
        const JS_PROP_TMASK = 3 << 4;
        const JS_PROP_NORMAL = 0 << 4;
        const JS_PROP_GETSET = 1 << 4;
        const JS_PROP_VARREF = 2 << 4;
        const JS_PROP_AUTOINIT = 3 << 4;

        const JS_DEF_CFUNC: u8 = 0;
        const JS_DEF_CGETSET: u8 = 1;
        const JS_DEF_CGETSET_MAGIC: u8 = 2;
        const JS_DEF_PROP_STRING: u8 = 3;
        const JS_DEF_PROP_INT32: u8 = 4;
        const JS_DEF_PROP_INT64: u8 = 5;
        const JS_DEF_PROP_DOUBLE: u8 = 6;
        const JS_DEF_PROP_UNDEFINED: u8 = 7;
        const JS_DEF_OBJECT: u8 = 8;
        const JS_DEF_ALIAS: u8 = 9;
        var ret = @This(){
            .name = helper.name,
            .prop_flags = switch (helper.def) {
                .func => JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE,
                .getset => JS_PROP_CONFIGURABLE,
                .getsetMagic => JS_PROP_CONFIGURABLE,
                .prop => |prop| prop.flags.dump(),
                .object => |obj| obj.flags.dump(),
                .alias => JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE,
            },
            .def_type = switch (helper.def) {
                .func => JS_DEF_CFUNC,
                .getset => JS_DEF_CGETSET,
                .getsetMagic => JS_DEF_CGETSET_MAGIC,
                .prop => |prop| switch (prop.value) {
                    .str => JS_DEF_PROP_STRING,
                    .int => JS_DEF_PROP_INT32,
                    .long => JS_DEF_PROP_INT64,
                    .double => JS_DEF_PROP_DOUBLE,
                    .undef => JS_DEF_PROP_UNDEFINED,
                },
                .object => JS_DEF_OBJECT,
                .alias => JS_DEF_ALIAS,
            },
            .magic = switch (helper.def) {
                .func => |f| f.magic,
                .getsetMagic => |getset| getset.magic,
                else => 0,
            },
            .u = undefined,
        };
        ret.u = switch (helper.def) {
            .func => |f| .{
                .func = .{
                    .length = f.length,
                    .cproto = std.meta.activeTag(f.func),
                    .cfunc = f.func.dump(),
                },
            },
            .getset => |gs| .{
                .getset = .{
                    .get = if (gs.get) |get| .{ .getter = get } else .{ .none = 0 },
                    .set = if (gs.set) |set| .{ .setter = set } else .{ .none = 0 },
                },
            },
            .getsetMagic => |gs| .{
                .getset = .{
                    .get = if (gs.get) |get| .{ .getter_magic = get } else .{ .none = 0 },
                    .set = if (gs.set) |set| .{ .setter_magic = set } else .{ .none = 0 },
                },
            },
            .prop => |prop| switch (prop.value) {
                .str => |v| U{ .str = v },
                .int => |v| U{ .int = v },
                .long => |v| U{ .long = v },
                .double => |v| U{ .double = v },
                .undef => U{ .int = 0 },
            },
            .object => |object| .{
                .prop_list = .{
                    .tab = object.list.ptr,
                    .len = @intCast(c_int, object.list.len),
                },
            },
            .alias => |alias| .{
                .alias = .{
                    .name = alias.name,
                    .base = alias.base,
                },
            },
        };
        return ret;
    }

    pub fn genFunction(name: [*:0]const u8, def: Helper.Function) @This() {
        return from(.{ .name = name, .def = .{ .func = def } });
    }

    pub fn genGetSet(name: [*:0]const u8, def: Helper.GetSet) @This() {
        return from(.{ .name = name, .def = .{ .getset = def } });
    }

    pub fn genGetSetMagic(name: [*:0]const u8, def: Helper.GetSetMagic) @This() {
        return from(.{ .name = name, .def = .{ .getsetMagic = def } });
    }

    pub fn genProp(name: [*:0]const u8, def: Helper.PropValue, flags: PropFlags) @This() {
        return from(.{ .name = name, .def = .{ .prop = .{ .value = def, .flags = flags } } });
    }

    pub fn genObject(name: [*:0]const u8, def: Helper.Object) @This() {
        return from(.{ .name = name, .def = .{ .object = def } });
    }

    pub fn genAlias(name: [*:0]const u8, def: Helper.Alias) @This() {
        return from(.{ .name = name, .def = .{ .alias = def } });
    }
};
extern fn JS_SetPropertyFunctionList(ctx: *JsContext, obj: JsValue, tab: [*]const JsCFunctionListEntry, len: c_int) void;
const JsModuleInitFunc = fn (*JsContext, *JsModuleDef) callconv(.C) c_int;
extern fn JS_NewCModule(ctx: *JsContext, name_str: [*:0]const u8, func: JsModuleInitFunc) ?*JsModuleDef;
// can only be called before the module is instantiated
extern fn JS_AddModuleExport(ctx: *JsContext, m: *JsModuleDef, name_str: [*:0]const u8) c_int;
extern fn JS_AddModuleExportList(ctx: *JsContext, m: *JsModuleDef, tab: [*]const JsCFunctionListEntry, len: c_int) c_int;
// can only be called after the module is instantiated
extern fn JS_SetModuleExport(ctx: *JsContext, m: *JsModuleDef, export_name: [*:0]const u8, val: JsValue) c_int;
extern fn JS_SetModuleExportList(ctx: *JsContext, m: *JsModuleDef, tab: [*]const JsCFunctionListEntry, len: c_int) c_int;

extern fn JS_NewBigInt64(ctx: *JsContext, v: i64) JsValue;
extern fn JS_NewBigUint64(ctx: *JsContext, v: u64) JsValue;
extern fn JS_Throw(ctx: *JsContext, obj: JsValue) JsValue;
extern fn JS_GetException(ctx: *JsContext) JsValue;
extern fn JS_IsError(ctx: *JsContext, val: JsValue) bool;
extern fn JS_ResetUncatchableError(ctx: *JsContext) void;
extern fn JS_NewError(ctx: *JsContext) JsValue;
extern fn JS_ThrowSyntaxError(ctx: *JsContext, fmt: [*:0]const u8, ...) JsValue;
extern fn JS_ThrowTypeError(ctx: *JsContext, fmt: [*:0]const u8, ...) JsValue;
extern fn JS_ThrowReferenceError(ctx: *JsContext, fmt: [*:0]const u8, ...) JsValue;
extern fn JS_ThrowRangeError(ctx: *JsContext, fmt: [*:0]const u8, ...) JsValue;
extern fn JS_ThrowInternalError(ctx: *JsContext, fmt: [*:0]const u8, ...) JsValue;
extern fn JS_ThrowOutOfMemory(ctx: *JsContext) JsValue;

pub const JsError = union(enum) {
    Syntax: []const u8,
    Type: []const u8,
    Reference: []const u8,
    Range: []const u8,
    Internal: []const u8,
    OutOfMemory: void,
};

pub const Detect = enum {
    Error,
    Function,
    Constructor,
    Array,
};

pub const JsModuleDef = opaque {
    const scoped = std.log.scoped(.@"js module");
    pub fn getImportMeta(self: *@This(), ctx: *JsContext) JsValue {
        return JS_GetImportMeta(ctx, self);
    }

    pub fn getModuleName(self: *@This(), ctx: *JsContext) JsAtom {
        return JS_GetModuleName(ctx, self);
    }

    pub fn setModuleExport(self: *@This(), ctx: *JsContext, name: [*:0]const u8, value: JsValue) void {
        _ = JS_SetModuleExport(ctx, self, name, value);
    }

    pub fn init(comptime name: [*:0]const u8, ctx: *JsContext, comptime T: type) !*@This() {
        const Trampoline = opaque {
            fn on_load(_ctx: *JsContext, mod: *JsModuleDef) callconv(.C) c_int {
                scoped.info("load c module: {}", .{name});
                _ = JS_SetModuleExportList(_ctx, mod, &T.storage, @intCast(c_int, T.storage.len));
                if (@hasDecl(T, "load")) T.load(_ctx, mod);
                return 0;
            }
        };
        scoped.info("new c module: {}", .{name});
        const ret = JS_NewCModule(ctx, name, Trampoline.on_load) orelse return error.FailedToCreateModule;
        if (@hasDecl(T, "init")) try T.init(ctx, ret);
        for (T.storage) |item| {
            const r = JS_AddModuleExport(ctx, ret, item.name);
            if (r != 0) return error.FailedToLoadModule;
        }
        if (@hasDecl(T, "extra")) {
            for (T.extra) |ename| {
                _ = JS_AddModuleExport(ctx, ret, ename);
            }
        }
        return ret;
    }
};

pub const JsClassExoticMethods = extern struct {
    getOwnProperty: ?fn (ctx: *JsContext, desc: *JsPropertyDescriptor, obj: JsValue, prop: JsAtom) callconv(.C) c_int,
    getOwnPropertyNames: ?fn (ctx: *JsContext, ptab: **JsPropertyEnum, plen: *u32, obj: JsValue) callconv(.C) c_int,
    deleteProperty: ?fn (ctx: *JsContext, obj: JsValue, prop: JsAtom) callconv(.C) c_int,
    defineOwnProperty: ?fn (ctx: *JsContext, this: JsValue, prop: JsAtom, val: JsValue, getter: JsValue, setter: JsValue, flags: c_int) callconv(.C) c_int,
    hasProperty: ?fn (ctx: *JsContext, this_obj: JsValue, prop: JsAtom) callconv(.C) c_int,
    getProperty: ?fn (ctx: *JsContext, obj: JsValue, prop: JsAtom, receiver: JsValue) callconv(.C) c_int,
    setProperty: ?fn (ctx: *JsContext, obj: JsValue, atom: JsAtom, value: JsValue, receiver: JsValue, flags: c_int) callconv(.C) c_int,
};

pub const JsClassDef = extern struct {
    name: [*:0]const u8,
    finalizer: ?fn (rt: *JsRuntime, val: JsValue) callconv(.C) void = null,
    gcMark: ?fn (rt: *JsRuntime, val: JsValue, mark: JS_MarkFunc) callconv(.C) void = null,
    call: ?fn (ctx: *JsContext, func: JsValue, this: JsValue, argc: c_int, argv: [*]JsValue, construct: bool) callconv(.C) JsValue = null,
    extoic: ?*const JsClassExoticMethods = null,
};
