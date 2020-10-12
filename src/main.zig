const std = @import("std");

const TinyCC = @import("./tcc.zig").TinyCC;
const quickjs = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");

const Loader = struct {
    header: quickjs.JsModuleLoader = .{ .loaderfn = func },

    fn log_print(ctx: *quickjs.JsContext, this: quickjs.JsValue, argc: c_int, argv: [*]quickjs.JsValue) callconv(.C) quickjs.JsValue {
        const out = std.io.getStdOut().writer();
        out.writeAll("here\n") catch {};
        for (argv[0..@intCast(usize, argc)]) |val| {
            const str: quickjs.JsString = val.as(quickjs.JsString, ctx) catch return ctx.throw(.{ .Internal = "failed to conver to string" });
            defer str.deinit(ctx);
            out.print("{}", .{str.data}) catch {};
        }
        out.writeByte('\n') catch {};
        return quickjs.JsValue.make(false, .Undefined);
    }

    fn func(self: *quickjs.JsModuleLoader, ctx: *quickjs.JsContext, name: [*:0]const u8) ?*quickjs.JsModuleDef {
        const E = quickjs.JsCFunctionListEntry;
        const cmp = std.cstr.cmp;
        const out = std.io.getStdOut().writer();
        return null;
    }
};

fn loadAllMods(comptime mod: type, ctx: *quickjs.JsContext) !void {
    inline for (std.meta.declarations(mod)) |decl| {
        if (!decl.is_pub) continue;
        const field = @field(mod, decl.name);
        _ = try quickjs.JsModuleDef.init(decl.name ++ "", ctx, field);
    }
}

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        return error.NotEnoughArguments;
    }

    const file = try std.fs.cwd().openFile(args[1], .{});
    const contents = try file.readToEndAllocOptions(allocator, 1024 * 1024 * 1024, null, 1, 0);

    const rt = quickjs.JsRuntime.init();
    defer rt.deinit();

    var xctx: GlobalContext = .{
        .allocator = allocator,
    };

    rt.setOpaque(&xctx);

    var loader: Loader = .{};
    rt.setModuleLoader(&loader.header);

    const ctx = try quickjs.JsContext.init(rt);
    defer ctx.deinit();

    try loadAllMods(@import("./mods.zig"), ctx);

    ctx.addHelper(null);

    const val = ctx.eval(contents, "input", .{ .module = true });
    if (val.getNormTag() == .Exception) {
        ctx.dumpError();
    }
}
