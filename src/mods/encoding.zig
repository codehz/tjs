const std = @import("std");
const js = @import("../quickjs.zig");
const GlobalContext = @import("../context.zig");

const E = js.JsCFunctionListEntry;

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
