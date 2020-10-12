const std = @import("std");
const js = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");

const E = js.JsCFunctionListEntry;
fn cTagName(comptime tag: anytype) [*:0]const u8 {
    return std.meta.tagName(tag) ++ "";
}

pub const c = opaque {
    const target = std.builtin.Target.current;
    var length_atom: js.JsAtom = .invalid;

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

                fn gen(self: @This()) [:0]const u8 {
                    return switch (self) {
                        .integer => "int",
                        .double => "double",
                        .string => "char *",
                    };
                }

                fn size(self: @This()) usize {
                    const raw: usize = switch (self) {
                        .integer => @sizeOf(i32),
                        .double => @sizeOf(f64),
                        .string => @sizeOf(usize),
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
                        .string => {
                            const val = std.mem.bytesToValue([*:0]const u8, buf[0..@sizeOf(usize)]);
                            return js.JsValue.init(ctx, .{ .String = std.mem.span(val) });
                        },
                    }
                }
            };

            const Data = union(Type) {
                integer: i32,
                double: f64,
                string: [:0]const u8,

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
                    }
                }

                fn from(t: Type, src: js.JsValue, ctx: *js.JsContext, allocator: *std.mem.Allocator) !@This() {
                    return switch (t) {
                        .integer => .{ .integer = try src.as(i32, ctx) },
                        .double => .{ .double = try src.as(f64, ctx) },
                        .string => .{ .string = try (try src.as(js.JsString, ctx)).dupe(ctx, allocator) },
                    };
                }

                fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
                    switch (self) {
                        .string => |str| allocator.free(str),
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
                    data.dump(writer) catch |e| return ctx.throw(.{ .Internal = @errorName(e) });
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
            if (value.getNormTag() != .Object) return error.NotAnObject;
            var ret: FunctionInfo = .{ .atom = atom, .name = parameterName };
            const arguments = value.getProperty(ctx, "arguments") orelse return error.ArgumentsNotFound;
            const result = value.getProperty(ctx, "result") orelse js.JsValue.fromRaw(.Undefined);
            if (!ctx.detect(.Array, arguments)) return error.ArgumentsIsNotArray;
            const length = try arguments.getProperty(ctx, length_atom).?.as(usize, ctx);
            ret.arguments = try allocator.alloc(FunctionInfo.Type, length);
            errdefer allocator.free(ret.arguments);
            var i: usize = 0;
            while (i < length) : (i += 1) {
                const item = arguments.getProperty(ctx, i) orelse return error.InvalidArray;
                const itemstr = try item.as(js.JsString, ctx);
                defer itemstr.deinit(ctx);
                ret.arguments[i] = std.meta.stringToEnum(FunctionInfo.Type, itemstr.data) orelse return error.UnknownType;
            }
            if (result.getNormTag() != .Undefined) {
                const resultstr = try result.as(js.JsString, ctx);
                defer resultstr.deinit(ctx);
                ret.result = std.meta.stringToEnum(FunctionInfo.Type, resultstr.data) orelse return error.UnknownType;
            }
            return ret;
        }

        fn newInternal(ot: cc.OutputType) !*TinyCC {
            const tcc = try TinyCC.init();
            errdefer tcc.deinit();
            try tcc.setup();
            try tcc.apply(.{ .output = ot });
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
