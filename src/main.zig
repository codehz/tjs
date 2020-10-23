const std = @import("std");

const TinyCC = @import("./tcc.zig").TinyCC;
const js = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");
const purl = @import("./url.zig");

const catom = js.JsAtom.comptimeAtom;

const scoped = std.log.scoped(.main);

pub const enable_segfault_handler = false;

fn setModuleMeta(ctx: *js.JsContext, root: js.JsValue, url: [:0]const u8, is_main: bool) !*js.JsModuleDef {
    scoped.debug("set module meta for {} (url: {}, main: {})", .{ root, url, is_main });
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

fn makeUrl(allocator: *std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
    comptime const fileproto = if (std.Target.current.os.tag == .windows) "file:///" else "file://";
    const ret = try allocator.allocSentinel(u8, path.len + fileproto.len, 0);
    std.mem.copy(u8, ret[0..fileproto.len], fileproto);
    if (std.Target.current.os.tag == .windows) {
        for (path) |ch, i|
            ret[i + fileproto.len] = if (ch == '\\') '/' else ch;
    } else {
        std.mem.copy(u8, ret[fileproto.len..], path);
    }
    return ret;
}

const Loader = struct {
    const loaderLog = std.log.scoped(.@"module loader");
    header: js.JsModuleLoader = .{ .normalizefn = normalize, .loaderfn = loader },

    fn enormalize(allocator: *std.mem.Allocator, ctx: *js.JsContext, base: [:0]const u8, name: [:0]const u8) ![*:0]const u8 {
        loaderLog.info("try normalize (base: {}, name: {})", .{ base, name });
        errdefer loaderLog.warn("failed to normalize", .{});
        const baseurl = try purl.PartialURL.parse(allocator, base);
        defer baseurl.deinit(allocator);
        loaderLog.debug("parsed url: {}", .{baseurl});
        const ret = baseurl.resolveModule(allocator, name) orelse return error.ResolveFailed;
        loaderLog.info("result: {}", .{ret});
        return ret.ptr;
    }

    fn normalize(self: *js.JsModuleLoader, ctx: *js.JsContext, base: [*:0]const u8, name: [*:0]const u8) [*:0]const u8 {
        const out = std.io.getStdOut().writer();
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        return enormalize(allocator, ctx, std.mem.span(base), std.mem.span(name)) catch (allocator.dupeZ(u8, std.mem.span(name)) catch unreachable);
    }

    fn loader(self: *js.JsModuleLoader, ctx: *js.JsContext, name: [*:0]const u8) ?*js.JsModuleDef {
        loaderLog.info("try load module: {}", .{name});
        const E = js.JsCFunctionListEntry;
        const allocator = ctx.getRuntime().getOpaqueT(GlobalContext).?.allocator;
        const cmp = std.cstr.cmp;
        const out = std.io.getStdOut().writer();
        const filename = std.mem.span(name);
        const file = std.fs.cwd().openFile(filename, .{}) catch {
            const errstr = std.fmt.allocPrint0(allocator, "could not load module filename '{}': open failed", .{filename}) catch return null;
            defer allocator.free(errstr);
            _ = ctx.throw(.{ .Reference = errstr });
            return null;
        };
        defer file.close();
        const data = file.readToEndAllocOptions(allocator, 1024 * 1024 * 1024, null, 1, 0) catch {
            const errstr = std.fmt.allocPrint0(allocator, "could not load module filename '{}': read failed", .{filename}) catch return null;
            defer allocator.free(errstr);
            _ = ctx.throw(.{ .Reference = errstr });
            return null;
        };
        defer allocator.free(data);
        const value = ctx.eval(data, filename, .{ .module = true, .compile = true });
        if (value.getNormTag() == .Exception) {
            defer value.deinit(ctx);
            ctx.dumpError();
            const errstr = std.fmt.allocPrint0(allocator, "eval module '{}' failed", .{filename}) catch return null;
            defer allocator.free(errstr);
            _ = ctx.throw(.{ .Reference = errstr });
            return null;
        }
        const murl = makeUrl(allocator, filename) catch {
            _ = ctx.throw(.OutOfMemory);
            return null;
        };
        defer allocator.free(murl);
        return setModuleMeta(ctx, value, murl, false) catch {
            const errstr = std.fmt.allocPrint0(allocator, "eval module '{}' failed", .{filename}) catch return null;
            defer allocator.free(errstr);
            _ = ctx.throw(.{ .Reference = errstr });
            return null;
        };
    }
};

fn loadAllMods(comptime mod: type, ctx: *js.JsContext) !void {
    inline for (std.meta.declarations(mod)) |decl| {
        if (!decl.is_pub) continue;
        const field = @field(mod, decl.name);
        _ = try js.JsModuleDef.init("builtin:" ++ decl.name, ctx, field);
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
    @import("./workaround.zig").patch();
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

    var xctx: GlobalContext = .{
        .allocator = allocator,
    };

    rt.setOpaque(&xctx);
    defer rt.deinit();

    var loader: Loader = .{};
    rt.setModuleLoader(&loader.header);

    const ctx = try js.JsContext.init(rt);
    defer ctx.deinit();

    try loadAllMods(@import("./mods.zig"), ctx);

    const val = ctx.eval(contents, rooturl, .{ .module = true, .compile = true });
    if (val.getNormTag() == .Module) {
        _ = try setModuleMeta(ctx, val, rooturl, true);
        const ret = ctx.evalFunction(val);
        defer ret.deinit(ctx);
        if (ret.getNormTag() == .Exception) {
            ctx.dumpError();
        }
    } else if (val.getNormTag() == .Exception) {
        ctx.dumpError();
    }
    while (rt.pending()) {}
    ctx.dumpError();
}
