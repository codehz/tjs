// simple url handling
// rename url opaque to entity for keyword conflict

const std = @import("std");

fn ishex(c: u8) bool {
    if ('0' <= c and c <= '9') {
        return true;
    }
    if ('a' <= c and c <= 'f') {
        return true;
    }
    if ('A' <= c and c <= 'F') {
        return true;
    }
    return false;
}

fn unhex(c: u8) u8 {
    if ('0' <= c and c <= '9') {
        return c - '0';
    }
    if ('a' <= c and c <= 'f') {
        return c - 'a' + 10;
    }
    if ('A' <= c and c <= 'F') {
        return c - 'A' + 10;
    }
    return 0;
}

fn tolower(str: []u8) void {
    for (str) |*ch| {
        ch.* = if (ch.* > 0x40 and ch.* < 0x5b) ch.* | 0x60 else ch.*;
    }
}

pub const URLCategory = enum {
    path,
    builtin,
    unknown,
};

pub const PartialURL = struct {
    // always lowercase
    scheme: [:0]const u8,
    data: union(enum) {
        entity: [:0]const u8,
        normal: struct {
            authority: ?[:0]const u8 = null,
            path: ?[:0]const u8 = null,
        },
    },

    const State = union(enum) {
        scheme,
        sep,
        prehost,
        authority: usize,
        path: std.ArrayListUnmanaged(u8),
        entity: usize,
    };

    const HexState = union(enum) {
        initial: void,
        start: void,
        ready: u8,
    };

    pub fn parse(allocator: *std.mem.Allocator, input: []const u8) !@This() {
        var ret: @This() = undefined;
        var state: State = .scheme;
        errdefer {
            switch (state) {
                .entity, .authority, .prehost, .sep => {
                    allocator.free(ret.scheme);
                },
                .path => |*list| {
                    list.deinit(allocator);
                    if (ret.data.normal.authority) |authority| allocator.free(authority);
                    allocator.free(ret.scheme);
                },
                .scheme => {},
            }
        }
        var hex: HexState = .initial;
        var last: usize = input.len;

        for (input) |ch, i| out: {
            switch (hex) {
                .initial => {},
                .start => {
                    if (ishex(ch)) {
                        hex = .{ .ready = unhex(ch) * 16 };
                        continue;
                    } else {
                        return error.InvalidHexEncoding;
                    }
                },
                .ready => |d| {
                    if (ishex(ch)) {
                        hex = .{ .ready = d + unhex(ch) };
                    } else {
                        return error.InvalidHexEncoding;
                    }
                },
            }
            switch (state) {
                .scheme => {
                    if (ch == ':') {
                        var scheme = try allocator.dupeZ(u8, input[0..i]);
                        tolower(scheme);
                        ret.scheme = scheme;
                        state = .sep;
                    }
                },
                .sep => {
                    if (ch == '/') {
                        state = .prehost;
                    } else {
                        state = .{ .entity = i };
                    }
                },
                .prehost => {
                    if (ch == '/') {
                        state = .{ .authority = i + 1 };
                    } else {
                        return error.UnsupportedURL;
                    }
                },
                .authority => |start| {
                    if (ch == '/') {
                        if (start == i) {
                            ret.data = .{ .normal = .{ .authority = null } };
                        } else {
                            ret.data = .{ .normal = .{ .authority = try allocator.dupeZ(u8, input[start..i]) } };
                        }
                        state = .{ .path = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len - i + 1) };
                    }
                },
                .path => |*list| {
                    switch (hex) {
                        .ready => |d| {
                            hex = .initial;
                            list.appendAssumeCapacity(d);
                            continue;
                        },
                        else => {},
                    }
                    switch (ch) {
                        else => {
                            list.appendAssumeCapacity(ch);
                        },
                        '+' => {
                            list.appendAssumeCapacity(' ');
                        },
                        '?', '#' => {
                            last = i;
                            break :out;
                        },
                        '%' => {
                            hex = .start;
                        },
                    }
                },
                .entity => |start| {
                    switch (ch) {
                        '?' => {
                            last = i;
                            break :out;
                        },
                        else => {},
                    }
                },
            }
        }
        switch (hex) {
            else => return error.IncompleteHexEncoding,
            .initial => {},
        }
        switch (state) {
            else => return error.IncompleteURL,
            .entity => |start| {
                ret.data = .{ .entity = try allocator.dupeZ(u8, input[start..last]) };
            },
            .path => |*list| {
                list.appendAssumeCapacity(0);
                const x = list.toOwnedSlice(allocator);
                ret.data.normal.path = x[0 .. x.len - 1 :0];
            },
        }
        return ret;
    }

    pub fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
        allocator.free(self.scheme);
        switch (self.data) {
            .normal => |data| {
                if (data.authority) |authority| allocator.free(authority);
                if (data.path) |path| allocator.free(path);
            },
            .entity => |data| {
                allocator.free(data);
            },
        }
    }

    pub fn category(self: @This()) URLCategory {
        if (std.mem.eql(u8, self.scheme, "file")) {
            if (self.data != .normal or self.data.normal.path == null or self.data.normal.authority != null) return .unknown;
            return .path;
        } else if (std.mem.eql(u8, self.scheme, "builtin")) {
            if (self.data != .entity) return .unknown;
            return .builtin;
        }
        return .unknown;
    }

    fn resolvePath(allocator: *std.mem.Allocator, paths: []const []const u8) ![:0]const u8 {
        const ret = try std.fs.path.resolve(allocator, paths);
        defer allocator.free(ret);
        return std.cstr.addNullByte(allocator, ret);
    }

    pub fn resolveModule(self: @This(), allocator: *std.mem.Allocator, side: []const u8) ?[:0]const u8 {
        if (parse(allocator, side)) |rurl| {
            defer rurl.deinit(allocator);
            switch (rurl.category()) {
                .path => {
                    return resolvePath(allocator, &[_][]const u8{rurl.data.normal.path.?}) catch null;
                },
                .builtin => {
                    return allocator.dupeZ(u8, rurl.data.entity) catch null;
                },
                .unknown => return null,
            }
        } else |err| {
            switch (self.category()) {
                .path => {
                    return resolvePath(allocator, &[_][]const u8{
                        self.data.normal.path.?, "..", side,
                    }) catch null;
                },
                else => return null,
            }
        }
    }
};

fn testUrl(input: []const u8) !void {
    const url = try PartialURL.parse(std.testing.allocator, input);
    try std.io.getStdOut().writer().print("{} => {}\n", .{ input, url });
    defer url.deinit(std.testing.allocator);
}

test "parse url" {
    try testUrl("file:///D:/Project/tinysh/test.js");
    try testUrl("builtin:c");
    try testUrl("https://wiki.tld/%E4%B8%AD%E6%96%87");
    std.testing.expectError(error.IncompleteURL, testUrl("boom"));
    std.testing.expectError(error.IncompleteHexEncoding, testUrl("https://wiki.tld/%E4%B8%AD%E6%96%8"));
}

test "resolve module" {
    const url = try PartialURL.parse(std.testing.allocator, "file:///D:/Project/tinysh/test.js");
    defer url.deinit(std.testing.allocator);
    const t2 = url.resolveModule(std.testing.allocator, "builtin:c") orelse unreachable;
    defer std.testing.allocator.free(t2);
    try std.io.getStdOut().writer().print("{}\n", .{ t2 });
}
