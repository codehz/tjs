const std = @import("std");
const js = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");

const E = js.JsCFunctionListEntry;
fn cTagName(comptime tag: anytype) [*:0]const u8 {
    return std.meta.tagName(tag) ++ "";
}

fn safeIntCast(comptime T: type, val: anytype) ?T {
    if (val >= std.math.minInt(T) and val <= std.math.maxInt(T)) return @intCast(T, val);
    return null;
}

pub const c = opaque {
    const target = std.builtin.Target.current;
    var length_atom: js.JsAtom = .invalid;
    threadlocal var currentContext: *js.JsContext = undefined;

    const FunctionProxy = struct {
        const name = @typeName(@This());
        var class: js.JsClassID = .initial;

        functions: std.ArrayListUnmanaged(Compiler.FunctionInfo) = .{},

        fn delete(rt: *js.JsRuntime, val: js.JsValue) callconv(.C) void {
            if (val.getOpaqueT(@This(), class)) |self| {
                val.setOpaque(null);
                const allocator = rt.getOpaqueT(GlobalContext).?.allocator;
                for (self.functions.items) |item| {
                    item.deinit(allocator);
                }
                self.functions.deinit(allocator);
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

        pub fn init(ctx: *js.JsContext, mod: *js.JsModuleDef) !void {
            class.init();
            class.define(ctx.getRuntime(), &js.JsClassDef{
                .name = name,
                .finalizer = delete,
            });
        }

        pub fn create(self: *@This(), ctx: *js.JsContext) js.JsValue {
            var ret = js.JsValue.init(ctx, .{ .Object = .{ .class = class } });
            ret.setOpaque(self);
            for (self.functions.items) |func, i| {
                _ = ret.defineProperty(ctx, func.atom, .{
                    .configurable = false,
                    .writable = false,
                    .enumerable = true,
                    .data = .{
                        .value = js.JsValue.init(ctx, .{
                            .Function = .{
                                .name = func.name,
                                .length = @intCast(c_int, func.arguments.len),
                                .func = .{ .generic_magic = fnCall },
                                .magic = @intCast(u16, i),
                            },
                        }),
                    },
                }) catch {};
            }
            return ret;
        }
    };

    const Compiler = opaque {
        const name = @typeName(@This());
        const cc = @import("./tcc.zig");
        const TinyCC = cc.TinyCC;
        var class: js.JsClassID = .initial;
        var constructor: js.JsValue = js.JsValue.fromRaw(.Undefined);
        var proto: js.JsValue = js.JsValue.fromRaw(.Undefined);

        const template = [_]E{
            E.genGetSet("valid", .{ .get = getIsValid }),
            E.genFunction("compile", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 0 }),
            E.genFunction("compileFile", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 1 }),
            E.genFunction("link", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 2 }),
            E.genFunction("linkDir", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 3 }),
            E.genFunction("include", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 4 }),
            E.genFunction("sysinclude", .{ .length = 1, .func = .{ .generic_magic = fnInput }, .magic = 5 }),
            E.genFunction("run", .{ .length = 0, .func = .{ .generic = fnRun } }),
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
            if (this.getOpaqueT(TinyCC, class)) |tcc| {
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
            } else {
                return ctx.throw(.{ .Type = "invalid compiler" });
            }
        }

        fn fnRelocate(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
            if (this.getOpaqueT(TinyCC, class)) |tcc| {
                if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
                const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
                const obj: js.JsValue = argv[0];
                const names = obj.getOwnPropertyNames(ctx, .{}) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
                var funcs = std.ArrayListUnmanaged(FunctionInfo).initCapacity(allocator, names.len) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
                errdefer {
                    for (funcs.items) |item| item.deinit(allocator);
                    funcs.deinit(allocator);
                }
                var cbuffer: std.fifo.LinearFifo(u8, .Dynamic) = std.fifo.LinearFifo(u8, .Dynamic).init(allocator);
                const out = cbuffer.writer();
                out.writeAll("#include <tjs.h>\n\n") catch return ctx.throw(.OutOfMemory);
                for (names) |item| {
                    const value = obj.getProperty(ctx, item.atom) orelse continue;
                    const str = item.atom.toCString(ctx).?.dupe(ctx, allocator) catch return ctx.throw(.OutOfMemory);
                    const f = fixFunction(allocator, ctx, tcc, item.atom, str, value) catch |e| return ctx.throw(.{ .Type = @errorName(e) });
                    errdefer f.deinit(allocator);
                    funcs.appendAssumeCapacity(f);
                    f.gencode(out) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
                }
                out.writeByte(0) catch return ctx.throw(.OutOfMemory);
                const slice = cbuffer.readableSlice(0);
                tcc.apply(.{ .input = .{ .content = @ptrCast([*:0]const u8, slice.ptr) } }) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
                tcc.relocate() catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
                for (funcs.items) |*item| {
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const deconame = std.fmt.allocPrint0(&arena.allocator, "${}", .{item.name}) catch return ctx.throw(.OutOfMemory);
                    const ptr = tcc.get(deconame) orelse {
                        const emsg = std.fmt.allocPrint0(allocator, "symbol {} not found", .{item.name}) catch return ctx.throw(.OutOfMemory);
                        return ctx.throw(.{ .Reference = emsg });
                    };
                    item.*.funcptr = @ptrCast(fn (ptr: [*]const u8) callconv(.C) void, ptr);
                }
                for (funcs.items) |*item| if (item.loadsym(tcc, ctx)) |ret| return ret;
                const proxy = allocator.create(FunctionProxy) catch return ctx.throw(.OutOfMemory);
                proxy.functions = funcs;
                return proxy.create(ctx);
            } else {
                return ctx.throw(.{ .Type = "invalid compiler" });
            }
        }

        const FunctionInfo = struct {
            const Type = enum {
                integer,
                double,
                string,
                wstring,
                vector,
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
                        .pointer => {
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
                        .pointer => .{ .pointer = @bitCast(usize, safeIntCast(isize, try src.as(i64, ctx)) orelse return error.InvalidPointer) },
                        .callback => .{ .callback = src },
                    };
                }

                fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
                    switch (self) {
                        .string => |str| allocator.free(str),
                        .wstring => |str| allocator.free(str),
                        else => {},
                    }
                }
            };

            atom: js.JsAtom,
            name: [:0]const u8,
            arguments: []Type = undefined,
            result: ?Type = null,
            funcptr: ?fn (ptr: [*]u8) callconv(.C) void = null,

            fn gencode(self: @This(), writer: anytype) !void {
                try writer.print("extern {0} {1}(", .{ if (self.result) |res| res.gen() else "void", self.name });
                for (self.arguments) |arg, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.writeAll(arg.gen());
                }
                try writer.writeAll(");\n");
                try writer.print("struct pack${} {{\n", .{self.name});
                if (self.result) |result| {
                    if (!result.allowAsResult()) return error.ResultTypeNotAllowed;
                    try writer.print("\t{} result __ALIGN__;\n", .{result.gen()});
                }
                for (self.arguments) |arg, i| {
                    try writer.print("\t{} arg${} __ALIGN__;\n", .{ arg.gen(), i });
                }
                try writer.writeAll("};\n");
                try writer.print("void ${0} (struct pack${0} *ptr) {{\n", .{self.name});
                try writer.writeAll(if (self.result != null) "\tptr->result = " else "\t");
                try writer.print("{0}(", .{self.name});
                for (self.arguments) |arg, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("ptr->arg${}", .{i});
                }
                try writer.writeAll(");\n");
                try writer.writeAll("};\n\n");
            }

            fn loadsym(self: *@This(), tcc: *TinyCC, ctx: *js.JsContext) ?js.JsValue {
                var tempbuffer: [1024]u8 = undefined;
                var fixed = std.heap.FixedBufferAllocator.init(&tempbuffer);
                const deco = std.fmt.allocPrint0(&fixed.allocator, "${}", .{self.name}) catch return ctx.throw(.OutOfMemory);
                const symbol = tcc.get(deco) orelse return ctx.throw(.{ .Reference = std.fmt.bufPrint(&tempbuffer, "{} not exported", .{self.name}) catch return ctx.throw(.OutOfMemory) });
                self.funcptr = @ptrCast(fn (ptr: [*]u8) callconv(.C) void, symbol);
                return null;
            }

            fn calcSize(self: @This()) usize {
                var ret: usize = 0;
                if (self.result) |result| ret += result.size();
                for (self.arguments) |arg| ret += arg.size();
                return ret;
            }

            fn invoke(self: @This(), allocator: *std.mem.Allocator, ctx: *js.JsContext, args: []js.JsValue) js.JsValue {
                if (args.len != self.arguments.len) {
                    var errbuf: [128]u8 = undefined;
                    return ctx.throw(.{ .Type = std.fmt.bufPrint(&errbuf, "invalid arguments number, require {}, found {}", .{ self.arguments.len, args.len }) catch "invalid arguments number" });
                }
                var buf = allocator.alloc(u8, self.calcSize()) catch return ctx.throw(.OutOfMemory);
                errdefer allocator.free(buf);
                var fifo = std.fifo.LinearFifo(u8, .Slice).init(buf);
                const writer = fifo.writer();
                var argsdata = std.ArrayListUnmanaged(Data).initCapacity(allocator, args.len) catch return ctx.throw(.OutOfMemory);
                defer {
                    for (argsdata.items) |item| item.deinit(allocator);
                    argsdata.deinit(allocator);
                }
                if (self.result) |res| fifo.update(res.size());
                for (self.arguments) |arg, i| {
                    const data = Data.from(arg, args[i], ctx, allocator) catch |e| return ctx.throw(.{ .Type = @errorName(e) });
                    data.dump(writer) catch |e| {
                        data.deinit(allocator);
                        return ctx.throw(.{ .Internal = @errorName(e) });
                    };
                    argsdata.appendAssumeCapacity(data);
                }
                self.funcptr.?(buf.ptr);
                return if (self.result) |res| res.read(buf.ptr, ctx) else js.JsValue.fromRaw(.Undefined);
            }

            fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
                allocator.free(self.name);
                allocator.free(self.arguments);
            }
        };

        fn fixFunction(allocator: *std.mem.Allocator, ctx: *js.JsContext, tcc: *TinyCC, atom: js.JsAtom, parameterName: [:0]const u8, value: js.JsValue) !FunctionInfo {
            if (value.getNormTag() != .String) return error.RequireString;
            var ret: FunctionInfo = .{ .atom = atom, .name = parameterName };
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
                        ret.result = switch (ch) {
                            'i' => .integer,
                            'd' => .double,
                            'p' => .pointer,
                            '_' => null,
                            else => return error.InvalidResult,
                        };
                    },
                }
            }
            ret.arguments = tempargs.toOwnedSlice(allocator);
            return ret;
        }

        fn notifyCallback(val: js.JsValue) callconv(.C) bool {
            const ret = val.call(currentContext, js.JsValue.fromRaw(.Undefined), &[_]js.JsValue{});
            if (ret.getNormTag() != .Exception) return true;
            currentContext.dumpError();
            return false;
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

    pub const storage = [_]E{
        E.genProp("os", .{ .str = cTagName(target.os.tag) }, .{}),
        E.genProp("arch", .{ .str = cTagName(target.cpu.arch) }, .{}),
        E.genProp("abi", .{ .str = cTagName(target.abi) }, .{}),
    };

    pub const extra = &[_][*:0]const u8{"Compiler"};
};

pub const io = opaque {
    fn printGen(out: anytype, ctx: *js.JsContext, argc: c_int, argv: [*]js.JsValue) js.JsValue {
        for (argv[0..@intCast(usize, argc)]) |val| {
            const str: js.JsString = val.as(js.JsString, ctx) catch return ctx.throw(.{ .Internal = "failed to conver to string" });
            defer str.deinit(ctx);
            out.print("{}", .{str.data}) catch {};
        }
        out.writeByte('\n') catch {};
        return js.JsValue.make(false, .Undefined);
    }

    fn printOut(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        return printGen(std.io.getStdOut().writer(), ctx, argc, argv);
    }

    fn printErr(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        return printGen(std.io.getStdErr().writer(), ctx, argc, argv);
    }

    pub const storage = [_]E{
        E.genFunction("log", .{ .length = 1, .func = .{ .generic = printOut } }),
        E.genFunction("err", .{ .length = 1, .func = .{ .generic = printErr } }),
    };
};

pub const utf8 = opaque {
    fn encode(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const str: js.JsString = argv[0].as(js.JsString, ctx) catch return ctx.throw(.{ .Type = "not a string" });
        defer str.deinit(ctx);
        return js.JsValue.init(ctx, .{ .ArrayBuffer = str.data });
    }
    fn decode(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const buffer = argv[0].as([]u8, ctx) catch return ctx.throw(.{ .Type = "not an ArrayBuffer" });
        if (!std.unicode.utf8ValidateSlice(buffer)) return ctx.throw(.{ .Range = "invalid utf8 data" });
        return js.JsValue.init(ctx, .{ .String = buffer });
    }

    pub const storage = [_]E{
        E.genFunction("encode", .{ .length = 1, .func = .{ .generic = encode } }),
        E.genFunction("decode", .{ .length = 1, .func = .{ .generic = decode } }),
    };
};

pub const utf16 = opaque {
    fn toutf16(allocator: *std.mem.Allocator, data: []const u8) ![]u16 {
        var result = std.ArrayList(u16).init(allocator);
        try result.ensureCapacity(data.len + 1);

        const view = try std.unicode.Utf8View.init(data);
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| {
            if (codepoint < 0x10000) {
                const short = @intCast(u16, codepoint);
                try result.append(std.mem.nativeToLittle(u16, short));
            } else {
                const high = @intCast(u16, (codepoint - 0x10000) >> 10) + 0xD800;
                const low = @intCast(u16, codepoint & 0x3FF) + 0xDC00;
                var out: [2]u16 = undefined;
                out[0] = std.mem.nativeToLittle(u16, high);
                out[1] = std.mem.nativeToLittle(u16, low);
                try result.appendSlice(out[0..]);
            }
        }
        return result.toOwnedSlice();
    }

    fn encode(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const str: js.JsString = argv[0].as(js.JsString, ctx) catch return ctx.throw(.{ .Type = "not a string" });
        defer str.deinit(ctx);
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const out = toutf16(allocator, str.data) catch return ctx.throw(.OutOfMemory);
        defer allocator.free(out);
        return js.JsValue.init(ctx, .{ .ArrayBuffer = std.mem.sliceAsBytes(out) });
    }
    fn decode(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
        if (argc != 1) return ctx.throw(.{ .Type = "require 1 args" });
        const buffer: []u8 = argv[0].as([]u8, ctx) catch return ctx.throw(.{ .Type = "not an ArrayBuffer" });
        if (buffer.len % 2 != 0) return ctx.throw(.{ .Type = "invalid utf16" });
        if (buffer.len == 0) return js.JsValue.init(ctx, .{ .String = "" });
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const addr = @ptrToInt(buffer.ptr);
        if (std.mem.isAligned(addr, @alignOf(*u16))) {
            const temp = @intToPtr([*]u16, addr)[0..@divExact(buffer.len, @sizeOf(u16))];
            const ret = std.unicode.utf16leToUtf8Alloc(allocator, temp) catch return ctx.throw(.OutOfMemory);
            defer allocator.free(ret);
            return js.JsValue.init(ctx, .{ .String = ret });
        } else {
            const aligned = allocator.allocAdvanced(u8, @alignOf(*u16), buffer.len, .at_least) catch return ctx.throw(.OutOfMemory);
            defer allocator.free(aligned);
            std.mem.copy(u8, aligned[0..], buffer[0..]);
            const temp = @ptrCast([*]u16, aligned.ptr)[0..@divExact(aligned.len, @sizeOf(u16))];
            const ret = std.unicode.utf16leToUtf8Alloc(allocator, temp) catch return ctx.throw(.OutOfMemory);
            defer allocator.free(ret);
            return js.JsValue.init(ctx, .{ .String = ret });
        }
    }

    pub const storage = [_]E{
        E.genFunction("encode", .{ .length = 1, .func = .{ .generic = encode } }),
        E.genFunction("decode", .{ .length = 1, .func = .{ .generic = decode } }),
    };
};
