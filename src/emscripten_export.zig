const std = @import("std");
const true_main = @import("true_main");

pub export fn main() callconv(.C) void {
    const mainRet = @typeInfo(@TypeOf(true_main.main)).Fn.return_type orelse void;
    switch (@typeInfo(mainRet)) {
        .ErrorUnion => true_main.main() catch return,
        else => true_main.main(),
    }
}