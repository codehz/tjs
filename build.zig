const std = @import("std");
const builtin = std.builtin;
const Builder = std.build.Builder;

const Tcc1Info = struct {
    const Extension = enum {
        c, S
    };
    const Compile = struct {
        path: []const u8,
        base: []const u8,
        ext: Extension = .c,
    };
    const Library = struct {
        path: []const u8,
        name: []const u8,
    };
    global_incs: ?[]const []const u8 = null,
    extra_incs: ?[]const []const u8 = null,
    objs: []const Compile,
    libs: ?[]const Library = null,

    fn setupRun(b: *Builder, run: *std.build.RunStep, cmdline: []const []const u8, comptime format: []const u8, args: anytype) *std.build.Step {
        run.step.dependOn(&b.addLog(format ++ "\n", args).step);
        run.addArgs(cmdline);
        return &run.step;
    }

    fn build(self: @This(), b: *Builder, tcc: *std.build.LibExeObjStep, r: *std.build.Step, tgt: std.Target) !void {
        const resolve = std.fs.path.resolve;
        const lib_path = try resolve(b.allocator, &[_][]const u8{
            b.zig_exe,
            "../lib/zig",
        });
        const tripletinc = try std.fmt.allocPrint(b.allocator, "libc/include/{}", .{tgt.linuxTriple(b.allocator)});
        for (self.objs) |obj| {
            var args = std.ArrayList([]const u8).init(b.allocator);
            try args.append("-o");
            try args.append(try std.fmt.allocPrint(b.allocator, "tmp/o/{}.o", .{obj.base}));
            try args.append("-c");
            try args.append(try std.fmt.allocPrint(b.allocator, "vendor/tinycc/{}/{}.{}", .{ obj.path, obj.base, std.meta.tagName(obj.ext) }));
            try args.append("-I");
            try args.append("vendor/tinycc/include");
            try args.append("-I");
            try args.append("tmp");
            try args.append("-I");
            try args.append(try resolve(b.allocator, &[_][]const u8{
                lib_path,
                "libc/include/generic-musl",
            }));
            try args.append("-I");
            try args.append(try resolve(b.allocator, &[_][]const u8{
                lib_path,
                tripletinc,
            }));
            if (self.global_incs) |list| for (list) |inc| {
                try args.append("-I");
                try args.append(try std.fmt.allocPrint(b.allocator, "vendor/tinycc/{}", .{inc}));
            };
            if (self.extra_incs) |list| for (list) |inc| {
                try args.append("-I");
                try args.append(try std.fmt.allocPrint(b.allocator, "vendor/tinycc/{}", .{inc}));
            };
            r.dependOn(setupRun(b, tcc.run(), args.toOwnedSlice(), "CC {}/{}", .{ obj.path, obj.base }));
        }
        {
            var args = std.ArrayList([]const u8).init(b.allocator);
            try args.append("-ar");
            try args.append("tmp/lib/libtcc1.a");
            for (self.objs) |obj| {
                try args.append(try std.fmt.allocPrint(b.allocator, "tmp/o/{}.o", .{obj.base}));
            }
            r.dependOn(setupRun(b, tcc.run(), args.toOwnedSlice(), "LD libtcc1.a", .{}));
        }
        r.dependOn(&b.addInstallDirectory(.{
            .source_dir = "tmp/lib",
            .install_dir = .Bin,
            .install_subdir = "lib",
        }).step);
        if (self.libs) |list| for (list) |lib| {
            r.dependOn(&b.addInstallBinFile(
                try std.fmt.allocPrint(b.allocator, "vendor/tinycc/{}/{}", .{ lib.path, lib.name }),
                try std.fmt.allocPrint(b.allocator, "lib/{}", .{lib.name}),
            ).step);
        };
        r.dependOn(&b.addInstallDirectory(.{
            .source_dir = "vendor/tinycc/include",
            .install_dir = .Bin,
            .install_subdir = "include",
        }).step);
        if (self.global_incs) |list| for (list) |inc| {
            r.dependOn(&b.addInstallDirectory(.{
                .source_dir = try std.fmt.allocPrint(b.allocator, "vendor/tinycc/{}", .{inc}),
                .install_dir = .Bin,
                .install_subdir = "include",
            }).step);
        };
    }
};

fn getArchStr(comptime suffix: []const u8, arch: std.builtin.Arch) ![]const u8 {
    return switch (arch) {
        .x86_64 => "alloca86_64" ++ suffix,
        .i386 => "alloca86" ++ suffix,
        else => error.Unsupported,
    };
}

fn bootstrap(b: *Builder, tcc: *std.build.LibExeObjStep, target: std.zig.CrossTarget) !*std.build.Step {
    const native = try std.zig.system.NativeTargetInfo.detect(b.allocator, target);
    const ret = b.step("bootstrap", "generate libtcc1 and include");
    const info: Tcc1Info = switch (native.target.os.tag) {
        .windows => Tcc1Info{
            .global_incs = &[_][]const u8{"win32/include"},
            .extra_incs = &[_][]const u8{"win32/include/winapi"},
            .objs = &[_]Tcc1Info.Compile{
                .{ .path = "lib", .base = "libtcc1" },
                .{ .path = "win32/lib", .base = "crt1" },
                .{ .path = "win32/lib", .base = "crt1w" },
                .{ .path = "win32/lib", .base = "wincrt1" },
                .{ .path = "win32/lib", .base = "wincrt1w" },
                .{ .path = "win32/lib", .base = "dllcrt1" },
                .{ .path = "win32/lib", .base = "dllmain" },
                .{ .path = "win32/lib", .base = "chkstk", .ext = .S },
                .{ .path = "lib", .base = try getArchStr("", native.target.cpu.arch), .ext = .S },
                .{ .path = "lib", .base = try getArchStr("-bt", native.target.cpu.arch), .ext = .S },
            },
            .libs = &[_]Tcc1Info.Library{
                .{ .path = "win32/lib", .name = "msvcrt.def" },
                .{ .path = "win32/lib", .name = "kernel32.def" },
                .{ .path = "win32/lib", .name = "user32.def" },
                .{ .path = "win32/lib", .name = "gdi32.def" },
                .{ .path = "win32/lib", .name = "ws2_32.def" },
            },
        },
        .linux => switch (native.target.cpu.arch) {
            .x86_64 => Tcc1Info{
                .objs = &[_]Tcc1Info.Compile{
                    .{ .path = "lib", .base = "libtcc1" },
                    .{ .path = "lib", .base = "bt-exe" },
                    .{ .path = "lib", .base = "bt-log" },
                    .{ .path = "lib", .base = "va_list" },
                    .{ .path = "lib", .base = "dsohandle" },
                    .{ .path = "lib", .base = "alloca86_64", .ext = .S },
                    .{ .path = "lib", .base = "alloca86_64-bt", .ext = .S },
                },
            },
            .i386 => Tcc1Info{
                .objs = &[_]Tcc1Info.Compile{
                    .{ .path = "lib", .base = "libtcc1" },
                    .{ .path = "lib", .base = "bt-exe" },
                    .{ .path = "lib", .base = "bt-log" },
                    .{ .path = "lib", .base = "dsohandle" },
                    .{ .path = "lib", .base = "alloca86", .ext = .S },
                    .{ .path = "lib", .base = "alloca86-bt", .ext = .S },
                },
            },
            .aarch64 => Tcc1Info{
                .objs = &[_]Tcc1Info.Compile{
                    .{ .path = "lib", .base = "lib-arm64" },
                    .{ .path = "lib", .base = "fetch_and_add_arm64", .ext = .S },
                    .{ .path = "lib", .base = "bt-exe" },
                    .{ .path = "lib", .base = "bt-log" },
                    .{ .path = "lib", .base = "dsohandle" },
                },
            },
            else => return error.TODO,
        },
        else => return error.TODO,
    };
    try info.build(b, tcc, ret, native.target);
    return ret;
}

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const sqlite3 = b.addObject("sqlite3", null);
    sqlite3.linkLibC();
    sqlite3.addCSourceFile("vendor/sqlite3/sqlite3.c", &[_][]const u8{"-Wno-everything"});
    sqlite3.setTarget(target);
    sqlite3.setBuildMode(mode);

    const tccobj = b.addObject("tccobj", null);
    tccobj.linkLibC();
    tccobj.addIncludeDir("tmp");
    tccobj.addCSourceFile("vendor/tinycc/libtcc.c", &[_][]const u8{"-Wno-everything"});
    tccobj.setTarget(target);
    tccobj.setBuildMode(mode);

    const tcc = b.addExecutable("tcc", null);
    tcc.linkLibC();
    tcc.addObject(tccobj);
    tcc.addIncludeDir("tmp");
    tcc.addCSourceFile("vendor/tinycc/tcc.c", &[_][]const u8{ "-Wno-everything", "-DONE_SOURCE=0" });
    tcc.setTarget(target);
    tcc.setBuildMode(mode);

    const quickjs = b.addStaticLibrary("quickjs", null);
    quickjs.linkLibC();
    quickjs.addCSourceFile("vendor/quickjs/quickjs.c", &[_][]const u8{ "-Wno-everything", "-DEMSCRIPTEN", "-DCONFIG_VERSION=\"unknown\"" });
    quickjs.addCSourceFile("vendor/quickjs/libregexp.c", &[_][]const u8{ "-Wno-everything", "-DEMSCRIPTEN", "-DCONFIG_VERSION=\"unknown\"" });
    quickjs.addCSourceFile("vendor/quickjs/libunicode.c", &[_][]const u8{ "-Wno-everything", "-DEMSCRIPTEN", "-DCONFIG_VERSION=\"unknown\"" });
    quickjs.addCSourceFile("vendor/quickjs/cutils.c", &[_][]const u8{ "-Wno-everything", "-DEMSCRIPTEN", "-DCONFIG_VERSION=\"unknown\"" });
    quickjs.setTarget(target);
    quickjs.setBuildMode(mode);
    quickjs.install();

    const exe = b.addExecutable("tjs", "src/main.zig");
    exe.linkLibrary(quickjs);
    // exe.addObject(sqlite3);
    exe.addObject(tccobj);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const tcc1 = try bootstrap(b, tcc, target);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
