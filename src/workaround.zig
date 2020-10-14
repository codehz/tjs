const std = @import("std");

// remove the align assert
fn cAlloc(self: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
    const ptr = @ptrCast([*]u8, std.c.malloc(len) orelse return error.OutOfMemory);
    if (len_align == 0) {
        return ptr[0..len];
    }
    return ptr[0..std.mem.alignBackwardAnyAlign(len, len_align)];
}

pub fn patch() void {
    comptime const target = std.Target.current;
    if (comptime (target.cpu.arch == .i386 and target.os.tag == .windows)) {
        std.heap.c_allocator.allocFn = cAlloc;
    }
}
