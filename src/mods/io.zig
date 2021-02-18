const std = @import("std");
const js = @import("../quickjs.zig");
const GlobalContext = @import("../context.zig");

const E = js.JsCFunctionListEntry;

fn printGen(comptime useStdOut: bool, comptime addnl: bool) fn (ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
    const X = struct {
        fn temp(ctx: *js.JsContext, this: js.JsValue, argc: c_int, argv: [*]js.JsValue) callconv(.C) js.JsValue {
            const out = if (comptime useStdOut) std.io.getStdOut().writer() else std.io.getStdErr().writer();
            for (argv[0..@intCast(usize, argc)]) |val| {
                const str: js.JsString = val.as(js.JsString, ctx) catch return ctx.throw(.{ .Internal = "failed to conver to string" });
                defer str.deinit(ctx);
                out.print("{s}", .{str.data}) catch {};
            }
            if (addnl) {
                out.writeByte('\n') catch {};
            }
            return js.JsValue.make(false, .Undefined);
        }
    };
    return X.temp;
}

pub const storage = [_]E{
    E.genFunction("log", .{ .length = 1, .func = .{ .generic = printGen(true, true) } }),
    E.genFunction("err", .{ .length = 1, .func = .{ .generic = printGen(false, true) } }),
    E.genFunction("print", .{ .length = 1, .func = .{ .generic = printGen(true, false) } }),
    E.genFunction("errprint", .{ .length = 1, .func = .{ .generic = printGen(false, false) } }),
};
