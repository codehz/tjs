const std = @import("std");
const js = @import("../quickjs.zig");
const GlobalContext = @import("../context.zig");

const E = js.JsCFunctionListEntry;

fn cTagName(comptime tag: anytype) [*:0]const u8 {
    return std.meta.tagName(tag) ++ "";
}

const target = std.builtin.Target.current;
var length_atom: js.JsAtom = .invalid;
threadlocal var currentContext: *js.JsContext = undefined;

fn safeIntCast(comptime T: type, val: anytype) ?T {
    if (val >= std.math.minInt(T) and val <= std.math.maxInt(T)) return @intCast(T, val);
    return null;
}

const FunctionProxy = struct {
    const name = @typeName(@This());
    var class: js.JsClassID = .initial;

    functions: std.ArrayListUnmanaged(Compiler.FunctionInfo) = .{},
    backref: js.JsValue,

    fn delete(rt: *js.JsRuntime, val: js.JsValue) callconv(.C) void {
        if (val.getOpaqueT(@This(), class)) |self| {
            val.setOpaque(null);
            const allocator = rt.getOpaqueT(GlobalContext).?.allocator;
            for (self.functions.items) |item| {
                item.deinit(allocator);
            }
            self.functions.deinit(allocator);
            self.backref.deinitRT(rt);
            allocator.destroy(self);
        }
    }

    fn fnCall(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue, magic: c_int) callconv(.C) js.JsValue {
        if (this.getOpaqueT(@This(), class)) |self| {
            const func: Compiler.FunctionInfo = self.functions.items[@intCast(usize, magic)];
            const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
            return func.invoke(allocator, ctx, argv[0..@intCast(usize, argc)]);
        } else {
            return ctx.throw(.{ .Reference = "invalid function" });
        }
    }

    fn mark(rt: *js.JsRuntime, this: js.JsValue, markfn: js.JS_MarkFunc) callconv(.C) void {
        if (this.getOpaqueT(@This(), class)) |self| {
            self.backref.mark(rt, markfn);
        }
    }

    pub fn init(ctx: *js.JsContext, mod: *js.JsModuleDef) !void {
        class.init();
        class.define(ctx.getRuntime(), &js.JsClassDef{
            .name = name,
            .finalizer = delete,
            .gcMark = mark,
        });
    }

    pub fn create(self: *@This(), ctx: *js.JsContext) js.JsValue {
        var ret = js.JsValue.init(ctx, .{ .Object = .{ .class = class } });
        ret.setOpaque(self);
        for (self.functions.items) |item, i| {
            _ = ret.defineProperty(ctx, item.atom, .{
                .configurable = false,
                .writable = false,
                .enumerable = true,
                .data = .{
                    .value = switch (item.value) {
                        .Function => |func| js.JsValue.init(ctx, .{
                            .Function = .{
                                .name = item.name,
                                .length = @intCast(c_int, func.arguments.len),
                                .func = .{ .generic_magic = fnCall },
                                .magic = @intCast(u16, i),
                            },
                        }),
                        .Address => |addr| js.JsValue.fromBig(ctx, addr),
                    },
                },
            }) catch {};
        }
        return ret;
    }
};

const Compiler = opaque {
    const name = @typeName(@This());
    const cc = @import("../tcc.zig");
    const TinyCC = cc.TinyCC;
    var class: js.JsClassID = .initial;
    var constructor: js.JsValue = js.JsValue.fromRaw(.Undefined);
    var proto: js.JsValue = js.JsValue.fromRaw(.Undefined);

    const template = [_]E{
        E.genGetSet("valid", .{ .get = getIsValid }),
        E.genFunction("compile", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 0 }),
        E.genFunction("add", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 1 }),
        E.genFunction("link", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 2 }),
        E.genFunction("linkDir", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 3 }),
        E.genFunction("include", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 4 }),
        E.genFunction("sysinclude", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 5 }),
        E.genFunction("output", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 6 }),
        E.genFunction("option", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 7 }),
        E.genFunction("define", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 8 }),
        E.genFunction("run", .{ .length = 0, .func = .{ .generic = fnRun } }),
        E.genFunction("bind", .{ .length = 0, .func = .{ .generic = fnBind } }),
        E.genFunction("relocate", .{ .length = 1, .func = .{ .generic = fnRelocate } }),
    };

    fn getIsValid(ctx: *js.JsContext, this: js.JsValue) callconv(.C) js.JsValue {
        const ret = this.getOpaqueT(TinyCC, class) != null;
        return js.JsValue.init(ctx, .{ .Boolean = ret });
    }

    fn fnInput(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue, magic: c_int) callconv(.C) js.JsValue {
        if (this.getOpaqueT(TinyCC, class)) |tcc| {
            if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
            const content: js.JsString = argv[0].as(js.JsString, ctx) catch |e| return ctx.throw(.{ .Type = @errorName(e) });
            defer content.deinit(ctx);
            const re = switch (magic) {
                0 => tcc.apply(.{ .input = .{ .content = content.data } }),
                1 => tcc.apply(.{ .input = .{ .path = content.data } }),
                2 => tcc.apply(.{ .library = content.data }),
                3 => tcc.apply(.{ .library_dir = content.data }),
                4 => tcc.apply(.{ .include = content.data }),
                5 => tcc.apply(.{ .system_include = content.data }),
                6 => tcc.writeFile(content.data),
                7 => tcc.apply(.{ .opt = content.data }),
                8 => tcc.apply(.{ .define = .{ .name = content.data } }),
                else => @panic("unsupported magic"),
            };
            re catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
            return js.JsValue.fromRaw(.Undefined);
        } else {
            return ctx.throw(.{ .Type = "invalid compiler" });
        }
    }

    const ArgsBlock = struct {
        data: []const [*:0]const u8,
        strbuf: []js.JsString,

        fn deinit(self: @This(), ctx: *js.JsContext, allocator: *std.mem.Allocator) void {
            allocator.free(self.data);
            for (self.strbuf) |str| {
                str.deinit(ctx);
            }
            allocator.free(self.strbuf);
        }
    };

    fn convertArgs(allocator: *std.mem.Allocator, ctx: *js.JsContext, args: []js.JsValue) !ArgsBlock {
        var data = try allocator.alloc([*:0]const u8, args.len);
        errdefer allocator.free(data);
        var buffer = try std.ArrayListUnmanaged(js.JsString).initCapacity(allocator, args.len);
        errdefer {
            for (buffer.items) |item| item.deinit(ctx);
            buffer.deinit(allocator);
        }
        for (args) |arg, i| {
            const str = try arg.as(js.JsString, ctx);
            buffer.appendAssumeCapacity(str);
            data[i] = str.data;
        }
        return ArgsBlock{
            .data = data,
            .strbuf = buffer.toOwnedSlice(allocator),
        };
    }

    fn fnRun(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        const tcc = this.getOpaqueT(TinyCC, class) orelse return ctx.throw(.{ .Type = "invalid compiler" });
        var ret: c_int = undefined;
        if (argc == 0) {
            ret = tcc.run(&[_][*:0]const u8{});
        } else {
            const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
            const args = convertArgs(allocator, ctx, argv[0..@intCast(usize, argc)]) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
            defer args.deinit(ctx, allocator);
            ret = tcc.run(args.data);
        }
        return js.JsValue.from(ret);
    }

    fn fnBind(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        const tcc = this.getOpaqueT(TinyCC, class) orelse return ctx.throw(.{ .Type = "invalid compiler" });
        if (argc != 2) return ctx.throw(.{ .Type = "need two arguments" });
        const str: js.JsString = argv[0].as(js.JsString, ctx) catch return ctx.throw(.{ .Type = "invalid name" });
        defer str.deinit(ctx);
        const addr: i64 = argv[1].as(i64, ctx) catch return ctx.throw(.{ .Type = "invalid addr" });
        tcc.apply(.{
            .bind = .{
                .name = str.data,
                .value = @intToPtr(?*c_void, @intCast(usize, addr)),
            },
        }) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
        return js.JsValue.fromRaw(.Undefined);
    }

    fn fnRelocate(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        const tcc = this.getOpaqueT(TinyCC, class) orelse return ctx.throw(.{ .Type = "invalid compiler" });
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const obj: js.JsValue = argv[0];
        const names = obj.getOwnPropertyNames(ctx, .{}) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
        var funcs = std.ArrayListUnmanaged(FunctionInfo).initCapacity(allocator, names.len) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
        var haserr = false;
        defer if (haserr) {
            for (funcs.items) |item| item.deinit(allocator);
            funcs.deinit(allocator);
        };
        var cbuffer: std.fifo.LinearFifo(u8, .Dynamic) = std.fifo.LinearFifo(u8, .Dynamic).init(allocator);
        const out = cbuffer.writer();
        out.writeAll("#include <tjs.h>\n\n") catch {
            haserr = true;
            return ctx.throw(.OutOfMemory);
        };
        for (names) |item| {
            const value = obj.getProperty(ctx, item.atom) orelse continue;
            const str = item.atom.toCString(ctx).?.dupe(ctx, allocator) catch {
                haserr = true;
                return ctx.throw(.OutOfMemory);
            };
            const f = fixFunction(allocator, ctx, tcc, item.atom, str, value) catch |e| {
                haserr = true;
                return ctx.throw(.{ .Type = @errorName(e) });
            };
            defer if (haserr) {
                f.deinit(allocator);
            };
            funcs.appendAssumeCapacity(f);
            f.gencode(out) catch |e| {
                haserr = true;
                return ctx.throw(.{ .Internal = @errorName(e) });
            };
        }
        out.writeByte(0) catch {
            haserr = true;
            return ctx.throw(.OutOfMemory);
        };
        const slice = cbuffer.readableSlice(0);
        tcc.apply(.{ .input = .{ .content = @ptrCast([*:0]const u8, slice.ptr) } }) catch |e| {
            haserr = true;
            return ctx.throw(.{ .Internal = @errorName(e) });
        };
        tcc.relocate() catch |e| {
            haserr = true;
            return ctx.throw(.{ .Internal = @errorName(e) });
        };
        for (funcs.items) |*item| if (item.loadsym(tcc, ctx)) |ret| {
            haserr = true;
            return ret;
        };
        const proxy = allocator.create(FunctionProxy) catch {
            haserr = true;
            return ctx.throw(.OutOfMemory);
        };
        proxy.backref = this.clone();
        proxy.functions = funcs;
        return proxy.create(ctx);
    }

    const FunctionInfo = struct {
        const Type = enum {
            integer,
            double,
            string,
            wstring,
            vector,
            bigint,
            pointer,
            callback,

            fn allowAsResult(self: @This()) bool {
                return switch (self) {
                    .string => false,
                    .wstring => false,
                    .vector => false,
                    .callback => false,
                    else => true,
                };
            }

            fn gen(self: @This()) [:0]const u8 {
                return switch (self) {
                    .integer => "int",
                    .double => "double",
                    .string => "char const *",
                    .wstring => "wchar_t const *",
                    .vector => "tjsvec_buf",
                    .bigint => "int64_t",
                    .pointer => "void *",
                    .callback => "tjscallback",
                };
            }

            fn size(self: @This()) usize {
                const raw: usize = switch (self) {
                    .integer => @sizeOf(i32),
                    .double => @sizeOf(f64),
                    .string => @sizeOf(usize),
                    .wstring => @sizeOf(usize),
                    .vector => @sizeOf(usize) * 2,
                    .bigint => @sizeOf(u64),
                    .pointer => @sizeOf(usize),
                    .callback => @sizeOf(usize) * 3,
                };
                return (@divTrunc(raw - 1, @sizeOf(usize)) + 1) * @sizeOf(usize);
            }

            fn read(self: @This(), buf: [*]u8, ctx: *js.JsContext) js.JsValue {
                switch (self) {
                    .integer => {
                        const val = std.mem.bytesToValue(i32, buf[0..4]);
                        return js.JsValue.from(val);
                    },
                    .double => {
                        const val = std.mem.bytesToValue(f64, buf[0..8]);
                        return js.JsValue.from(val);
                    },
                    .bigint, .pointer => {
                        const val = std.mem.bytesToValue(isize, buf[0..@sizeOf(usize)]);
                        return js.JsValue.fromBig(ctx, val);
                    },
                    .string, .wstring, .vector, .callback => @panic("invalid type"),
                }
            }
        };

        const Data = union(Type) {
            integer: i32,
            double: f64,
            string: [:0]const u8,
            wstring: [:0]const u16,
            vector: []u8,
            bigint: i64,
            pointer: usize,
            callback: js.JsValue,

            fn fill(comptime input: usize, writer: anytype) !void {
                const size = @mod(input, @sizeOf(usize));
                if (size == 0) return;
                const z = [1]u8{0} ** size;
                try writer.writeAll(&z);
            }

            fn dump(self: @This(), writer: anytype) !void {
                switch (self) {
                    .integer => |val| {
                        const bytes = std.mem.toBytes(val);
                        try writer.writeAll(&bytes);
                        try fill(bytes.len, writer);
                    },
                    .double => |val| {
                        const bytes = std.mem.toBytes(val);
                        try writer.writeAll(&bytes);
                        try fill(bytes.len, writer);
                    },
                    .string => |val| {
                        const bytes = std.mem.toBytes(@ptrToInt(val.ptr));
                        try writer.writeAll(&bytes);
                    },
                    .wstring => |val| {
                        const bytes = std.mem.toBytes(@ptrToInt(val.ptr));
                        try writer.writeAll(&bytes);
                    },
                    .vector => |val| {
                        var bytes = std.mem.toBytes(@ptrToInt(val.ptr));
                        try writer.writeAll(&bytes);
                        bytes = std.mem.toBytes(val.len);
                        try writer.writeAll(&bytes);
                    },
                    .bigint => |val| {
                        const bytes = std.mem.toBytes(val);
                        try writer.writeAll(&bytes);
                    },
                    .pointer => |val| {
                        const bytes = std.mem.toBytes(val);
                        try writer.writeAll(&bytes);
                    },
                    .callback => |val| {
                        const bytes = std.mem.toBytes(val);
                        try writer.writeAll(&bytes);
                    },
                }
            }

            fn from(t: Type, src: js.JsValue, ctx: *js.JsContext, allocator: *std.mem.Allocator) !@This() {
                return switch (t) {
                    .integer => .{ .integer = try src.as(i32, ctx) },
                    .double => .{ .double = try src.as(f64, ctx) },
                    .string => .{ .string = try (try src.as(js.JsString, ctx)).dupe(ctx, allocator) },
                    .wstring => blk: {
                        const rstr = try src.as(js.JsString, ctx);
                        defer rstr.deinit(ctx);
                        const r = try std.unicode.utf8ToUtf16LeWithNull(allocator, rstr.data);
                        break :blk .{ .wstring = r };
                    },
                    .vector => .{ .vector = try src.as([]u8, ctx) },
                    .bigint => .{ .bigint = try src.as(i64, ctx) },
                    .pointer => .{ .pointer = @bitCast(usize, safeIntCast(isize, try src.as(i64, ctx)) orelse return error.InvalidPointer) },
                    .callback => .{ .callback = src.clone() },
                };
            }

            fn deinit(self: @This(), ctx: *js.JsContext, allocator: *std.mem.Allocator) void {
                switch (self) {
                    .string => |str| allocator.free(str),
                    .wstring => |str| allocator.free(str),
                    .callback => |cb| cb.deinit(ctx),
                    else => {},
                }
            }
        };

        atom: js.JsAtom,
        name: [:0]const u8,
        value: SymInfo,
        const SymInfo = union(enum) {
            Function: struct {
                arguments: []Type = undefined,
                result: ?Type = null,
                funcptr: ?fn (ptr: [*]u8) callconv(.C) void = null,
            },
            Address: usize,
        };

        fn gencode(self: @This(), writer: anytype) !void {
            switch (self.value) {
                .Function => |fun| {
                    try writer.print("extern {0} {1}(", .{ if (fun.result) |res| res.gen() else "void", self.name });
                    for (fun.arguments) |arg, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try writer.writeAll(arg.gen());
                    }
                    try writer.writeAll(");\n");
                    try writer.print("struct pack${} {{\n", .{self.name});
                    if (fun.result) |result| {
                        if (!result.allowAsResult()) return error.ResultTypeNotAllowed;
                        try writer.print("\t{} result __ALIGN__;\n", .{result.gen()});
                    }
                    for (fun.arguments) |arg, i| {
                        try writer.print("\t{} arg${} __ALIGN__;\n", .{ arg.gen(), i });
                    }
                    try writer.writeAll("};\n");
                    try writer.print("void ${0} (struct pack${0} *ptr) {{\n", .{self.name});
                    try writer.writeAll(if (fun.result != null) "\tptr->result = " else "\t");
                    try writer.print("{0}(", .{self.name});
                    for (fun.arguments) |arg, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try writer.print("ptr->arg${}", .{i});
                    }
                    try writer.writeAll(");\n");
                    try writer.writeAll("};\n\n");
                },
                .Address => {},
            }
        }

        fn loadsym(self: *@This(), tcc: *TinyCC, ctx: *js.JsContext) ?js.JsValue {
            var tempbuffer: [1024]u8 = undefined;
            switch (self.value) {
                .Function => |*fun| {
                    var fixed = std.heap.FixedBufferAllocator.init(&tempbuffer);
                    const deco = std.fmt.allocPrint0(&fixed.allocator, "${}", .{self.name}) catch return ctx.throw(.OutOfMemory);
                    const symbol = tcc.get(deco) orelse return ctx.throw(.{ .Reference = std.fmt.bufPrint(&tempbuffer, "{} not exported", .{self.name}) catch return ctx.throw(.OutOfMemory) });
                    fun.funcptr = @ptrCast(fn (ptr: [*]u8) callconv(.C) void, symbol);
                },
                .Address => |*addr| {
                    const symbol = tcc.get(self.name) orelse return ctx.throw(.{ .Reference = std.fmt.bufPrint(&tempbuffer, "{} not exported", .{self.name}) catch return ctx.throw(.OutOfMemory) });
                    addr.* = @ptrToInt(symbol);
                },
            }
            return null;
        }

        fn calcSize(self: @This()) usize {
            var ret: usize = 0;
            switch (self.value) {
                .Function => |fun| {
                    if (fun.result) |result| ret += result.size();
                    for (fun.arguments) |arg| ret += arg.size();
                },
                .Address => {},
            }
            return ret;
        }

        fn invoke(self: @This(), allocator: *std.mem.Allocator, ctx: *js.JsContext, args: []js.JsValue) js.JsValue {
            const fun = self.value.Function;
            if (args.len != fun.arguments.len) {
                var errbuf: [128]u8 = undefined;
                return ctx.throw(.{ .Type = std.fmt.bufPrint(&errbuf, "invalid arguments number, require {}, found {}", .{ fun.arguments.len, args.len }) catch "invalid arguments number" });
            }
            var buf = allocator.alloc(u8, self.calcSize()) catch return ctx.throw(.OutOfMemory);
            errdefer allocator.free(buf);
            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buf);
            const writer = fifo.writer();
            var argsdata = std.ArrayListUnmanaged(Data).initCapacity(allocator, args.len) catch return ctx.throw(.OutOfMemory);
            defer {
                for (argsdata.items) |item| item.deinit(ctx, allocator);
                argsdata.deinit(allocator);
            }
            if (fun.result) |res| fifo.update(res.size());
            for (fun.arguments) |arg, i| {
                const data = Data.from(arg, args[i], ctx, allocator) catch |e| return ctx.throw(.{ .Type = @errorName(e) });
                data.dump(writer) catch |e| {
                    data.deinit(ctx, allocator);
                    return ctx.throw(.{ .Internal = @errorName(e) });
                };
                argsdata.appendAssumeCapacity(data);
            }
            fun.funcptr.?(buf.ptr);
            return if (fun.result) |res| res.read(buf.ptr, ctx) else js.JsValue.fromRaw(.Undefined);
        }

        fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
            allocator.free(self.name);
            switch (self.value) {
                .Function => |fun| {
                    allocator.free(fun.arguments);
                },
                .Address => {},
            }
        }
    };

    fn fixFunction(allocator: *std.mem.Allocator, ctx: *js.JsContext, tcc: *TinyCC, atom: js.JsAtom, parameterName: [:0]const u8, value: js.JsValue) !FunctionInfo {
        var ret: FunctionInfo = .{ .atom = atom, .name = parameterName, .value = undefined };
        if (value.getTag() == .Null) {
            ret.value = .{ .Address = undefined };
            return ret;
        } else if (value.getTag() != .String) return error.RequireString;
        ret.value = .{ .Function = .{} };
        const str = try value.as(js.JsString, ctx);
        defer str.deinit(ctx);
        var tempargs = std.ArrayListUnmanaged(FunctionInfo.Type){};
        defer tempargs.deinit(allocator);
        const State = enum {
            arguments,
            callback,
            result,
        };
        var s: State = .arguments;
        for (str.data) |ch| {
            switch (s) {
                .arguments => {
                    const t: FunctionInfo.Type = switch (ch) {
                        'i' => .integer,
                        'd' => .double,
                        's' => .string,
                        'w' => .wstring,
                        'v' => .vector,
                        'b' => .bigint,
                        'p' => .pointer,
                        '[' => .callback,
                        '!' => {
                            s = .result;
                            continue;
                        },
                        else => return error.InvalidParameter,
                    };
                    try tempargs.append(allocator, t);
                    if (t == .callback) s = .callback;
                },
                .callback => {
                    if (ch == ']') {
                        s = .arguments;
                        continue;
                    }
                },
                .result => {
                    ret.value.Function.result = switch (ch) {
                        'i' => .integer,
                        'd' => .double,
                        'b' => .bigint,
                        'p' => .pointer,
                        '_' => null,
                        else => return error.InvalidResult,
                    };
                },
            }
        }
        ret.value.Function.arguments = tempargs.toOwnedSlice(allocator);
        return ret;
    }

    fn notifyCallback(val: js.JsValue) callconv(.C) c_int {
        const ret = val.call(currentContext, js.JsValue.fromRaw(.Undefined), &[_]js.JsValue{});
        if (ret.getNormTag() != .Exception) return ret.as(i32, currentContext) catch 0;
        currentContext.dumpError();
        return -1;
    }

    const NotifyData = extern struct {
        const Tag = extern enum(usize) {
            unset = 0,
            integer = 1,
            double = 2,
            string = 3,
            wstring = 4,
            vector = 5,
            bigint = 6,
            pointer = 7,
            _,
        };
        const Value = extern union {
            unset: void,
            integer: c_int,
            double: f64,
            string: [*:0]const u8,
            wstring: [*:0]const u16,
            vector: struct {
                ptr: [*]u8,
                len: usize,

                fn toSlice(self: @This()) []u8 {
                    return self.ptr[0..self.len];
                }
            },
            bigint: i64,
            pointer: usize,
        };
        tag: Tag,
        value: Value,

        fn toJs(self: @This(), ctx: *js.JsContext) js.JsValue {
            return switch (self.tag) {
                .unset => js.JsValue.fromRaw(.Undefined),
                .integer => js.JsValue.from(self.value.integer),
                .double => js.JsValue.from(self.value.double),
                .string => js.JsValue.init(ctx, .{ .String = std.mem.span(self.value.string) }),
                .wstring => blk: {
                    const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
                    const ret = std.unicode.utf16leToUtf8Alloc(allocator, std.mem.span(self.value.wstring)) catch @panic("decode utf16 failed");
                    defer allocator.free(ret);
                    break :blk js.JsValue.init(ctx, .{ .String = ret });
                },
                .vector => js.JsValue.init(ctx, .{ .ArrayBuffer = self.value.vector.toSlice() }),
                .bigint => js.JsValue.fromBig(ctx, self.value.bigint),
                .pointer => js.JsValue.fromBig(ctx, self.value.pointer),
                else => @panic("invalid type"),
            };
        }
    };

    fn notifyCallbackData(val: js.JsValue, num: usize, args: [*]NotifyData) callconv(.C) i32 {
        const allocator = currentContext.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const arr = allocator.alloc(js.JsValue, num) catch return -2;
        defer allocator.free(arr);
        for (arr) |*item| item.* = js.JsValue.fromRaw(.Undefined);
        defer for (arr) |item| item.deinit(currentContext);
        for (arr) |*item, i| item.* = args[i].toJs(currentContext);
        const ret = val.call(currentContext, js.JsValue.fromRaw(.Undefined), arr);
        if (ret.getNormTag() != .Exception) return ret.as(i32, currentContext) catch 0;
        currentContext.dumpError();
        return -1;
    }

    fn cloneCallback(val: js.JsValue) callconv(.C) js.JsValue {
        return val.clone();
    }

    fn freeCallback(val: js.JsValue) callconv(.C) void {
        val.deinit(currentContext);
    }

    fn newInternal(ot: cc.OutputType) !*TinyCC {
        const tcc = try TinyCC.init();
        errdefer tcc.deinit();
        try tcc.setup();
        try tcc.apply(.{ .output = ot });
        if (ot == .memory) {
            try tcc.apply(.{ .define = .{ .name = "__TJS_MEMORY__" } });
            try tcc.apply(.{
                .bind = .{
                    .name = "tjs_notify",
                    .value = notifyCallback,
                },
            });
            try tcc.apply(.{
                .bind = .{
                    .name = "tjs_notify_data",
                    .value = notifyCallbackData,
                },
            });
            try tcc.apply(.{
                .bind = .{
                    .name = "tjs_duplicate_callback",
                    .value = cloneCallback,
                },
            });
            try tcc.apply(.{
                .bind = .{
                    .name = "tjs_free_callback",
                    .value = freeCallback,
                },
            });
        }
        return tcc;
    }

    fn new(ctx: *js.JsContext, new_target: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const output: js.JsString = argv[0].as(js.JsString, ctx) catch |e| return ctx.throw(.{ .Type = @errorName(e) });
        defer output.deinit(ctx);
        const outputType = std.meta.stringToEnum(cc.OutputType, output.data) orelse return ctx.throw(.{ .Type = "invalid output type" });
        const tcc = newInternal(outputType) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
        const ret = js.JsValue.init(ctx, .{
            .Object = .{
                .proto = proto,
                .class = class,
            },
        });
        ret.setOpaque(tcc);
        return ret;
    }

    fn delete(rt: *js.JsRuntime, val: js.JsValue) callconv(.C) void {
        if (val.getOpaqueT(TinyCC, class)) |tcc| {
            tcc.deinit();
        }
    }

    pub fn init(ctx: *js.JsContext, mod: *js.JsModuleDef) !void {
        class.init();
        class.define(ctx.getRuntime(), &js.JsClassDef{
            .name = name,
            .finalizer = delete,
        });
    }

    pub fn load(ctx: *js.JsContext, mod: *js.JsModuleDef) void {
        constructor = js.JsValue.init(ctx, .{
            .Function = .{
                .name = name,
                .length = 1,
                .func = .{ .constructor = new },
            },
        });
        ctx.setConstructorBit(constructor, true) catch {};
        proto = js.JsValue.init(ctx, .{
            .Object = .{ .class = class, .temp = &template },
        });
        class.setProto(ctx, proto);
        ctx.setConstructor(constructor, proto);
        mod.setModuleExport(ctx, name, constructor);
    }
};

pub fn init(ctx: *js.JsContext, mod: *js.JsModuleDef) !void {
    length_atom = js.JsAtom.initAtom(ctx, "length");
    currentContext = ctx;
    try Compiler.init(ctx, mod);
    try FunctionProxy.init(ctx, mod);
}

pub fn load(ctx: *js.JsContext, mod: *js.JsModuleDef) void {
    Compiler.load(ctx, mod);
}

extern "Kernel32" fn AddDllDirectory(NewDirectory: [*:0]const u16) callconv(.Stdcall) ?*c_void;

pub fn appendLibSearchPath(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
    if (comptime std.Target.current.os.tag != .windows) {
        return ctx.throw(.{ .Type = "Unsupported OS" });
    } else {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const str: js.JsString = argv[0].as(js.JsString, ctx) catch return ctx.throw(.{ .Type = "not a string" });
        defer str.deinit(ctx);
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const u16str = std.unicode.utf8ToUtf16LeWithNull(allocator, str.data) catch return ctx.throw(.OutOfMemory);
        defer allocator.free(u16str);
        return js.JsValue.from(AddDllDirectory(u16str.ptr) != null);
    }
}

pub const storage = [_]E{
    E.genProp("os", .{ .str = cTagName(target.os.tag) }, .{}),
    E.genProp("arch", .{ .str = cTagName(target.cpu.arch) }, .{}),
    E.genProp("abi", .{ .str = cTagName(target.abi) }, .{}),
    E.genFunction("appendLibSearchPath", .{ .length = 1, .func = .{ .generic = appendLibSearchPath } }),
};

pub const extra = &[_][*:0]const u8{"Compiler"};
