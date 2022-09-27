//! small shims/utils that provide platform invariance for things running on
//! emscripten vs. native
//! probably most important is `is_emscripten`, followed by `loopForeverWith`
//! and friend(s) for doing the main loop pattern that emscripten handles more
//! cleanly and efficiently

const std = @import("std");
const sdl2 = @import("sdl2");
const builtin = @import("builtin");

/// the zig standard library currently does not compile for the emscripten 
/// target, so this currently only checks for a wasm architecture
/// a lot of this file is unnecessary if the standard library compiles, though
pub const is_emscripten: bool = switch (builtin.target.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false
};

/// loops with the provided callback and data
/// the callback must be a function with a single argument function, and `data`
/// must be a value implicitly coerceable to the function's argument type
/// if `@TypeOf(value_of_fn_arg_type, data)` results in a compile error, this
/// won't compile
pub fn loopForeverWith(comptime f: anytype, data: anytype) void {
    Underlying.enterLoopArg(f, data);
}

/// stops a loop started with `loopForeverWith`
pub fn cancelLoopForever() void {
    Underlying.cancelLoop();
}

/// yields control to the browser in emscripten with `-sASYNCIFY` set
/// is a no-op in native code
pub fn yieldControl() void {
    Underlying.yieldControl();
}

/// in emscripten, (only?) works if the `-sASYNCIFY` flag is passed to the 
/// emscripten link step
/// this is an alternative to forcing control of the main loop to be given to 
/// something else, since i haven't yet found a way around that for emscripten
/// i think even the emscripten authors haven't found a way around that without
/// `-sASYNCIFY`
fn delayInLoop(delay: u32) void {
    sdl2.delay(delay);
}

const emscripten: ?type = if (is_emscripten) @cImport(@cInclude("emscripten.h")) else null;

const Atomic = std.atomic.Atomic;

const Emscripten = struct {

    fn enterLoopArg(comptime f: anytype, data: anytype) void {
        cancelLoop();
        const callback = convertCallbackDataPair(f, data);
        emscripten.?.emscripten_set_main_loop_arg(callback.f, callback.data, 0, 1);
    }

    fn enterLoopArgOld(comptime f: ArgCallback, data: *anyopaque) void {
        cancelLoop();
        emscripten.?.emscripten_set_main_loop_arg(f, data, 0, 1);
    }
    
    fn cancelLoop() void {
        emscripten.?.emscripten_cancel_main_loop();
    }

    fn delayMs(delay: u32) void {
        emscripten.emscripten_sleep(delay);
    }

    fn yieldControl() void {
        emscripten.?.emscripten_sleep(0);
    }
};
const Native = struct {
    const Loop = struct {
        var running: Atomic(bool) = Atomic(bool).init(false);
    };

    fn enterLoopArg(comptime f: anytype, data: anytype) void {
        cancelLoop();
        const callback = convertCallbackDataPair(f, data);
        Loop.running.store(true, .Release);
        while (Loop.running.load(.Acquire)) {
            callback.f(callback.data);
        }
    }

    fn enterLoopArgOld(comptime f: ArgCallback, data: *anyopaque) void {
        Loop.running.store(true, .Release);
        while (Loop.running.load(.Acquire)) {
            f(data);
        }
    }

    fn cancelLoop() void {
        Loop.running.store(false, .Release);
    }

    fn delayMs(delay: u32) void {
        sdl2.delay(delay);
    }

    fn yieldControl() void {}
};

const Underlying = if (is_emscripten) Emscripten else Native;
const VoidCallback = fn() callconv(.C) void;
const ArgCallback = fn(?*anyopaque) callconv(.C) void;


const CallbackDataPair = struct {
    f: ArgCallback,
    data: ?*anyopaque,
};

// only works if there will only ever be one callback for any given function type/data type combo
// so basically works perfectly for emscripten main loop but not necessarily for other things
// currently only works for single-argument functions, although this can be hopefully changed eventually
fn convertCallbackDataPair(comptime f: anytype, data: anytype) CallbackDataPair {
    const f_info = @typeInfo(@TypeOf(f));
    const data_info = @typeInfo(@TypeOf(data));
    _ = data_info;
    
    if (f_info != .Fn) {
        @compileError("callback must be a function type");
    }
    if (f_info.Fn.args.len != 1) {
        @compileError("callback must be able to take only one argument (for now, may change later)");
    }
    const FArgType = f_info.Fn.args[0].arg_type orelse void;
    const FReturnType = f_info.Fn.return_type orelse void;
    const f_returns_error_union = @typeInfo(FReturnType) == .ErrorUnion;

    const dummy_f_arg: FArgType = undefined;
    const DataType = @TypeOf(data, dummy_f_arg);

    const fn_storage = struct {
        var static_data: DataType = undefined;
        pub fn callback(user_data: ?*anyopaque) callconv(.C) void {
            if (f_returns_error_union) {
                f(@ptrCast(?*DataType, @alignCast(@alignOf(DataType), user_data)).?.*) catch {};
            } else {
                f(@ptrCast(?*DataType, @alignCast(@alignOf(DataType), user_data)).?.*);
            }
        }
    };
    fn_storage.static_data = @as(DataType, data);
    return .{ .f = fn_storage.callback, .data = @ptrCast(?*anyopaque, &fn_storage.static_data) };
}

// TODO: fix tests to use convertCallbackPair by itself rather than loopForeverWith
test "convertCallbackPair converts basic ArgCallback" {
    const S = struct {
        pub fn callback(called: ?*anyopaque) void {
            @ptrCast(*bool, called).* = true;
        }
    };
    var called: bool = false;
    const callback = convertCallbackDataPair(S.callback, @ptrCast(?*anyopaque, &called));
    callback.f(callback.data);
    try std.testing.expect(called);
}

test "convertCallbackPair converts erroring callbacks" {
    const S = struct {
        pub fn callback(called: ?*anyopaque) !void {
            @ptrCast(*bool, called).* = true;
            cancelLoopForever();
            return error.Cancelled;
        }
    };
    var called: bool = false;
    const callback = convertCallbackDataPair(S.callback, @ptrCast(?*anyopaque, &called));
    callback.f(callback.data);
    try std.testing.expect(called);
}

test "convertCallbackPair converts more general callbacks" {
    const S = struct {
        const BoolPtr = struct {
            ptr: *bool,
        };
        pub fn boolPtrCallback(called: *bool) !void {
            called.* = true;
            cancelLoopForever();
        }
        pub fn boolPtrStructCallback(called: BoolPtr) !void {
            called.ptr.* = true;
            cancelLoopForever();
        }
    };
    var called: bool = false;
    const callbackPtr = convertCallbackDataPair(S.boolPtrCallback, &called);
    callbackPtr.f(callbackPtr.data);
    try std.testing.expect(called);
    called = false;
    const callbackStruct = convertCallbackDataPair(S.boolPtrStructCallback, S.BoolPtr { .ptr = &called });
    callbackStruct.f(callbackStruct.data);
    try std.testing.expect(called);
}

