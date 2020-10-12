const std = @import("std");

const TinyCC = @import("./tcc.zig").TinyCC;
const js = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");
const purl = @import("./url.zig");

const catom = js.JsAtom.comptimeAtom;

fn setModuleMeta(ctx: *js.JsContext, root: js.JsValue, url: [:0]const u8, is_main: bool) !*js.JsModuleDef {
    if (root.getNormTag() != .Module) return error.NotAModule;
    const ret: *js.JsModuleDef = root.getPointerT(js.JsModuleDef).?;
    const meta = ret.getImportMeta(ctx);
    var res = true;
    res = res and try meta.defineProperty(ctx, catom(ctx, "url"), .{
        .configurable = false,
        .writable = false,
        .enumerable = true,
        .data = .{
            .value = js.JsValue.init(ctx, .{ .String = url }),
        },
    });
    res = res and try meta.defineProperty(ctx, catom(ctx, "main"), .{
        .configurable = false,
        .writable = false,
        .enumerable = true,
        .data = .{
            .value = js.JsValue.from(is_main),
        },
    });
    if (!res) return error.FailedToDefineProperty;
    return ret;
}

fn makeUrl(allocator: *std.mem.Allocator, path: [:0]const u8) [:0]const u8 {
    return "file://module";
}

const Loader = struct {
    header: js.JsModuleLoader = .{ .normalizefn = normalize, .loaderfn = loader },

    fn enormalize(allocator: *std.mem.Allocator, ctx: *js.JsContext, base: [:0]const u8, name: [:0]const u8) ![*:0]const u8 {
        const baseurl = try purl.PartialURL.parse(allocator, base);
        defer baseurl.deinit(allocator);
        const ret = baseurl.resolveModule(allocator, name) orelse return error.ResolveFailed;
        return ret.ptr;
    }

    fn normalize(self: *js.JsModuleLoader, ctx: *js.JsContext, base: [*:0]const u8, name: [*:0]const u8) [*:0]const u8 {
        const out = std.io.getStdOut().writer();
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        return enormalize(allocator, ctx, std.mem.spanZ(base), std.mem.spanZ(name)) catch (allocator.dupeZ(u8, std.mem.spanZ(name)) catch unreachable);
    }

    fn loader(self: *js.JsModuleLoader, ctx: *js.JsContext, name: [*:0]const u8) ?*js.JsModuleDef {
        const E = js.JsCFunctionListEntry;
        const cmp = std.cstr.cmp;
        const out = std.io.getStdOut().writer();
        const filename = std.mem.spanZ(name);
        const file = std.fs.cwd().openFile(filename, .{}) catch return null;
        defer file.close();
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const data = file.readToEndAllocOptions(allocator, 1024, null, 1, 0) catch return null;
        defer allocator.free(data);
        const value = ctx.eval(data, filename, .{ .module = true, .compile = true });
        return setModuleMeta(ctx, value, makeUrl(allocator, filename), false) catch null;
    }
};

fn loadAllMods(comptime mod: type, ctx: *js.JsContext) !void {
    inline for (std.meta.declarations(mod)) |decl| {
        if (!decl.is_pub) continue;
        const field = @field(mod, decl.name);
        _ = try js.JsModuleDef.init(decl.name ++ "", ctx, field);
    }
}

fn tourl(allocator: *std.mem.Allocator, file: []const u8) ![:0]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    var path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd, file,
    });
    defer allocator.free(path);
    if (comptime (std.fs.path.sep == '\\')) {
        for (path) |*ch| {
            if (ch.* == '\\') {
                ch.* = '/';
            }
        }
    }
    return std.fmt.allocPrint0(allocator, "file:///{}", .{path});
}

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        return error.NotEnoughArguments;
    }

    const filename = try std.cstr.addNullByte(allocator, args[1]);
    defer allocator.free(filename);

    const rooturl = try tourl(allocator, filename);
    defer allocator.free(rooturl);

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const contents = try file.readToEndAllocOptions(allocator, 1024 * 1024 * 1024, null, 1, 0);
    defer allocator.free(contents);

    const rt = js.JsRuntime.init();
    defer rt.deinit();

    var xctx: GlobalContext = .{
        .allocator = allocator,
    };

    rt.setOpaque(&xctx);

    var loader: Loader = .{};
    rt.setModuleLoader(&loader.header);

    const ctx = try js.JsContext.init(rt);
    defer ctx.deinit();

    try loadAllMods(@import("./mods.zig"), ctx);

    ctx.addHelper(null);

    const val = ctx.eval(contents, rooturl, .{ .module = true, .compile = true });
    if (val.getNormTag() == .Module) {
        _ = try setModuleMeta(ctx, val, rooturl, true);
        const ret = ctx.evalFunction(val);
        if (ret.getNormTag() == .Exception) {
            ctx.dumpError();
        }
    } else if (val.getNormTag() == .Exception) {
        ctx.dumpError();
    }
}
