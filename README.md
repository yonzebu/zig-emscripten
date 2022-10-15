# zig-emscripten

Helper build tools and shims to add a new target to a zig build that supports emscripten. This will hopefully become obsolete if/when the zig compiler gets better support for emscripten.

## Requirements
* zig (not sure of the exact version compatibility, I've been working off master though)
* emscripten SDK install with the EMSDK environment variable set to the SDK root

## Usage

Simply add this somewhere in your build directory (here added under a `libs` subdirectory). Then in your `build.zig` add:

```zig
const std = @import("std");
const zig_emscripten = @import("libs/zig-emscripten/Sdk.zig");

pub fn build(b: *std.build.Builder) !void {

    const mode = b.standardReleaseOptions();

    // initialize exe here

    exe.addPackage(zig_emscripten.getPkg());

    emscripten_build_step = try zig_emscripten.addEmscriptenStep(b, exe, .{ .build_mode = mode });
    _ = emscripten_build_step;

}
```

This process is also configurable via the `EmscriptenOptions` struct, but I didn't finish implementing all the things emscripten explicitly supports as command line args so you may have to manually add your own emscripten args via the `args` field.
By default, the returned `Step` will be named `[exe name]-emscripten-wasm` (configurable through the options struct). 
You can then run `zig build [exe name goes here]-emscripten-wasm` and it will output an html, js, and wasm file to zig-out.
There is no corresponding run step because I didn't think of making one, so you'll have to run your own local web server or open the output in a browser to run it.

## Using the shims
After adding the package, you can import the shims and use them like so:
```zig
const std = @import("std");
const emshims = @import("zig_emscripten");

const App = struct {

    pub fn update(self: *App) !void {
        // main application update loop

        if (self.shouldQuit()) {
            emshims.cancelLoopForever();
        }
    }

    pub fn shouldQuit(self: *App) bool {
        // do whatever here
    }

};

pub fn main() !void {

    if (emshims.is_emscripten) std.log.info("hello from emscripten!", .{});

    var app: App = .{};
    emshims.loopForeverWith(App.update, app);

}

```

## Notes on compatibility
* Currently uses `std.meta.FnPtr`, which is deprecated and will get removed
* I'm not really maintaining this actively but feel free to report any issues or just fork this and modify it yourself
* Again, this will hopefully become obsolete if/when zig gets better support for emscripten
