const std = @import("std");

const TCCErrorFunc = fn (user: ?*c_void, message: [*:0]const u8) callconv(.C) void;

const TCCErrorCode = extern enum {
    success = 0,
    failed = -1,
};

pub const OutputType = extern enum {
    memory = 1,
    exe = 2,
    dll = 3,
    obj = 4,
    preprocessor = 5,
};

const TCCRelocateType = extern enum(usize) {
    get_size = 0, auto = 1, _
};

extern "C" fn tcc_new() callconv(.C) ?*TinyCC;
extern "C" fn tcc_delete(state: *TinyCC) callconv(.C) void;
extern "C" fn tcc_set_lib_path(state: *TinyCC, path: [*:0]const u8) callconv(.C) void;
extern "C" fn tcc_set_error_func(state: *TinyCC, user: ?*c_void, func: TCCErrorFunc) callconv(.C) void;
extern "C" fn tcc_get_error_func(state: *TinyCC) callconv(.C) ?TCCErrorFunc;
extern "C" fn tcc_get_error_opaque(state: *TinyCC) callconv(.C) ?*c_void;
extern "C" fn tcc_set_options(state: *TinyCC, cmd: [*:0]const u8) callconv(.C) void;
extern "C" fn tcc_add_include_path(state: *TinyCC, path: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_add_sysinclude_path(state: *TinyCC, path: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_define_symbol(state: *TinyCC, sym: [*:0]const u8, value: ?[*:0]const u8) callconv(.C) void;
extern "C" fn tcc_undefine_symbol(state: *TinyCC, sym: [*:0]const u8) callconv(.C) void;
extern "C" fn tcc_add_file(state: *TinyCC, path: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_compile_string(state: *TinyCC, buffer: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_set_output_type(state: *TinyCC, output: OutputType) callconv(.C) TCCErrorCode;
extern "C" fn tcc_add_library_path(state: *TinyCC, path: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_add_library(state: *TinyCC, name: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_add_symbol(state: *TinyCC, name: [*:0]const u8, val: ?*const c_void) callconv(.C) TCCErrorCode;
extern "C" fn tcc_output_file(state: *TinyCC, name: [*:0]const u8) callconv(.C) TCCErrorCode;
extern "C" fn tcc_run(state: *TinyCC, argc: c_int, argv: [*]const [*:0]const u8) callconv(.C) c_int;
extern "C" fn tcc_relocate(state: *TinyCC, ptr: TCCRelocateType) callconv(.C) c_int;
extern "C" fn tcc_get_symbol(state: *TinyCC, name: [*:0]const u8) callconv(.C) ?*c_void;
extern "C" fn tcc_list_symbol(state: *TinyCC, ctx: ?*c_void, func: fn (ctx: ?*c_void, name: [*:0]const u8, val: *c_void) callconv(.C) void) void;

pub const SourceFile = union(enum) {
    path: [*:0]const u8,
    content: [*:0]const u8,
};

pub const Config = union(enum) {
    tccdir: [*:0]const u8,
    opt: [*:0]const u8,
    library_dir: [*:0]const u8,
    library: [*:0]const u8,
    include: [*:0]const u8,
    system_include: [*:0]const u8,
    input: SourceFile,
    output: OutputType,
    define: struct {
        name: [*:0]const u8,
        value: ?[*:0]const u8 = null,
    },
    undefine: [*:0]const u8,
    bind: struct {
        name: [*:0]const u8,
        value: ?*const c_void,
    },
};

pub const RelocateAction = union(enum) {
    auto,
    size,
    addr: []u8,
};

pub const TinyCC = opaque {
    fn reportError(user: ?*c_void, message: [*:0]const u8) callconv(.C) void {
        std.log.scoped(.tcc).err("{}", .{message});
    }

    pub fn init() !*@This() {
        const ret = tcc_new() orelse return error.FailedToCreateState;
        tcc_set_error_func(ret, null, reportError);
        return ret;
    }

    pub fn deinit(self: *@This()) void {
        tcc_delete(self);
    }

    fn throw(code: TCCErrorCode, err: anyerror) !void {
        if (code == .failed) return err;
    }

    pub fn apply(self: *@This(), cfg: Config) !void {
        return switch (cfg) {
            .tccdir => |dir| tcc_set_lib_path(self, dir),
            .opt => |cmd| tcc_set_options(self, cmd),
            .library_dir => |dir| throw(tcc_add_library_path(self, dir), error.FailedToAddLibraryPath),
            .library => |lib| throw(tcc_add_library(self, lib), error.FailedToAddLibrary),
            .include => |dir| throw(tcc_add_include_path(self, dir), error.FailedToAddInclude),
            .system_include => |dir| throw(tcc_add_sysinclude_path(self, dir), error.FailedToAddSysInclude),
            .input => |source| throw(switch (source) {
                .content => |text| tcc_compile_string(self, text),
                .path => |path| tcc_add_file(self, path),
            }, error.CompileError),
            .output => |output| throw(tcc_set_output_type(self, output), error.InvalidOutputType),
            .define => |def| tcc_define_symbol(self, def.name, if (def.value) |value| value else null),
            .undefine => |undef| tcc_undefine_symbol(self, undef),
            .bind => |str| throw(tcc_add_symbol(self, str.name, str.value), error.FailedToBindSymbol),
        };
    }

    pub fn setup(self: *@This()) !void {
        var buf = [1]u8{0} ** 2048;
        var incbuf = [1]u8{0} ** 2048;

        const base = try std.fs.selfExeDirPath(&buf);
        const len = base.len;
        buf[len] = 0;
        try self.apply(.{ .tccdir = buf[0..len :0].ptr });

        std.mem.copy(u8, buf[len .. len + "/include".len], "/include");
        buf[len + "/include".len] = 0;
        try self.apply(.{ .system_include = buf[0 .. len + "/include".len :0].ptr });

        try self.apply(.{
            .define = .{
                .name = "__ALIGN__",
                .value = comptime std.fmt.comptimePrint("__attribute__((aligned({})))", .{@sizeOf(usize)}),
            },
        });
        try self.apply(.{ .define = .{ .name = "__TJS__" } });
    }

    pub fn run(self: *@This(), args: []const [*:0]const u8) c_int {
        return tcc_run(self, @intCast(c_int, args.len), args.ptr);
    }

    pub fn relocate(self: *@This()) !void {
        if (tcc_relocate(self, .auto) == -1) return error.FailedToRelocate;
    }

    pub fn get(self: *@This(), sym: [*:0]const u8) ?*c_void {
        return tcc_get_symbol(self, sym);
    }

    pub fn writeFile(self: *@This(), path: [*:0]const u8) !void {
        return throw(tcc_output_file(self, path), error.FailedToWrite);
    }
};
