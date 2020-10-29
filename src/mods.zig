const std = @import("std");
const js = @import("./quickjs.zig");
const GlobalContext = @import("./context.zig");

const E = js.JsCFunctionListEntry;

pub const c = @import("mods/c.zig");
pub const io = @import("mods/io.zig");

const encoding = @import("mods/encoding.zig");
pub const utf8 = encoding.utf8;
pub const utf16 = encoding.utf16;