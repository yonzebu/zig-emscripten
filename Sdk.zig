//! offers the ability to add a step to build wasm with emscripten for an
//! arbitrary zig executable
//! uses a tiny bit of hackery because emscripten isn't fully supported with
//! zig itself, and thus requires an emscripten sdk on the user's system (as
//! well as the EMSDK environment variable properly set to the sdk root!)

const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const Pkg = std.build.Pkg;

fn thisDir() [:0]const u8 {
    return (comptime std.fs.path.dirname(@src().file) orelse ".") ++ "";
}

const sdk_root: [:0]const u8 = thisDir();

const EmscriptenOptions = struct {
    build_mode: std.builtin.Mode,
    /// optional name for the produced step
    /// if left unfilled, defaults to `{input exe name}-emscripten-wasm`
    step_name: ?[]const u8 = null,
    /// any additional args to pass to the emscripten compiler when it runs
    args: []const []const u8 = &.{},
    /// in case there are specific macros you don't want globally copied so that they're used in the emscripten link step
    /// macros are only copied once, though, so you could init global macros, create the emscripten step, and THEN add platform-specific macros? 
    copy_c_macros: bool = false,
    /// hopefully all the pthread-related stuff in one config variable
    /// if null, no pthreads support is added to emcc args
    pthread_config: ?PthreadConfig = null,
    // TODO: expand sdl config
    use_sdl: ?SdlVersion = null,
    // TODO: expand webgpu config?
    use_webgpu: bool = false,
    // TODO: add other emscripten-specific options/flags
    asyncify: bool = false,
    optimizations: OptimizationLevel = .O3,
    // TODO: assertions via enum?
    assertions_level: u2 = 0,
    // TODO: add options for other ports/features

    const PthreadConfig = struct {
        //! pthreads config for emscripten

        /// corresponds to `-sPOOL_SIZE`
        pool_size: []const u8 = "0",
        /// corresponds to `-sPOOL_THREAD_SIZE_STRICT`
        strict: OnPoolExhaust = .warn,
        /// corresponds to `-sPOOL_DELAY_LOAD`
        pool_delay_load: bool = false,
        /// corresponds to `-sPTHREAD_DEFAULT_STACK_SIZE`
        stack_size: u32 = 2*1024*1024,
        /// corresponds to `-sPTHREADS_PROFILING`
        use_profiler: bool = false,
        /// corresponds to `-sALLOW_BLOCKING_ON_MAIN_THREAD`
        allow_blocking_on_main_thread: bool = true,
        /// corresponds to `-sPTHREADS_DEBUG`
        add_debug_trace: bool = false,

        const OnPoolExhaust = enum {
            warn, no_warn, err,
        };
    };

    const SdlVersion = enum {
        sdl1, sdl2
    };

    const OptimizationLevel = enum {
        O0, O1, O2, O3, Os, Oz,

        const Self = @This();
        /// returned slice has static storage duration
        pub fn toArg(self: Self) []const u8 {
            inline for (@typeInfo(Self).Enum.fields) |field| {
                if (self == @field(Self, field.name)) {
                    return "-" ++ field.name;
                }
            }
            @panic("tried to get name of invalid enum value");
        }
    };
};

fn copyPackages(src: *const LibExeObjStep, dst: *LibExeObjStep) void {
    for (src.packages.items) |pkg| {
        dst.addPackage(pkg);
    }
}

fn copyIncludes(src: *const LibExeObjStep, dst: *LibExeObjStep) void {
    for (src.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .raw_path => |path| dst.addIncludePath(path),
            .raw_path_system => |path| dst.addSystemIncludePath(path),
            .other_step => {},
        }
    }
}

fn copyCMacros(src: *const LibExeObjStep, dst: *LibExeObjStep) void {
    for (src.c_macros.items) |macro| {
        dst.defineCMacroRaw(macro);
    }
}

/// makes a step for building a given exe with emscripten
/// only supposed to work with something with a main function right now, so
/// will error if given any `LibExeObjStep` that doesn't have field `kind` set
/// to `Kind.exe`
/// default name of the step is `{exe_name}-emscripten-wasm`, although this can
/// be changed via the options struct
pub fn addEmscriptenStep(b: *Builder, exe: *const LibExeObjStep, options: EmscriptenOptions) !*Step {
    std.debug.assert(exe.kind == .exe);

    const emsdk_path = b.env_map.get("EMSDK") orelse 
        @panic("failed to get emscripten SDK path, try setting the EMSDK environment variable");
    const emscripten_include = b.pathJoin(&.{ emsdk_path, "upstream", "emscripten", "cache", "sysroot", "include" });
    // b.sysroot = b.pathJoin(&.{ emsdk_path, "upstream", "emscripten", "cache", "sysroot" });

    const wasm32_target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "wasm32-wasi" });

    const main_obj_name = if (options.step_name) |step_name| blk: {
        break :blk try std.mem.concat(b.allocator, u8, &.{ step_name, "_lib" });
    } else blk: {
        break :blk try std.mem.concat(b.allocator, u8, &.{ exe.name, "_emscripten" });
    };
    const main_obj = b.addObjectSource(main_obj_name, exe.root_src);
    main_obj.setTarget(wasm32_target);
    main_obj.setBuildMode(options.build_mode);
    main_obj.addIncludePath(emscripten_include);
    copyPackages(exe, main_obj);
    copyIncludes(exe, main_obj);
    if (options.copy_c_macros) copyCMacros(exe, main_obj);
    const main_obj_deps = try main_obj.packages.clone();

    const export_obj_name = if (options.step_name) |step_name| blk: {
        break :blk try std.mem.concat(b.allocator, u8, &.{ step_name, "_emscripten_export" });
    } else blk: {
        break :blk try std.mem.concat(b.allocator, u8, &.{ exe.name, "_emscripten_export" });
    };
    const emscripten_export = b.addObject(export_obj_name, sdk_root ++ "/src/emscripten_export.zig");
    emscripten_export.addPackage(std.build.Pkg{ 
        .name = "true_main",
        .source = main_obj.root_src.?,
        .dependencies = main_obj_deps.items,
    });
    emscripten_export.setTarget(wasm32_target);
    emscripten_export.setBuildMode(options.build_mode);
    emscripten_export.addIncludePath(emscripten_include);
    emscripten_export.step.dependOn(&main_obj.step);

    const emlink = b.addSystemCommand(&.{ "emcc", });
    emlink.addArtifactArg(emscripten_export);
    const out_file = try std.mem.concat(b.allocator, u8, &.{
        "-o", 
        b.pathJoin(&.{
            b.pathFromRoot("."),
            "zig-out" ++ std.fs.path.sep_str ++ "zig-out.html"
        })
    });
    emlink.addArgs(&.{ out_file, "-sEXPORTED_FUNCTIONS=_main", "--no-entry", });

    if (options.pthread_config) |*pthread_cfg| {
        const pool_size = try std.mem.concat(b.allocator, u8, &.{ 
            "-sPTHREAD_POOL_SIZE=", pthread_cfg.pool_size 
        });
        const delay_load = try std.mem.concat(b.allocator, u8, &.{ 
            "-sPTHREAD_POOL_DELAY_LOAD=", if (pthread_cfg.pool_delay_load) "1" else "0" 
        });
        const pool_strictness = switch (pthread_cfg.strict) {
            .no_warn => "-sPTHREAD_POOL_SIZE_STRICT=0",
            .warn => "-sPTHREAD_POOL_SIZE_STRICT=1",
            .err => "-sPTHREAD_POOL_SIZE_STRICT=2",
        };
        const stack_size = try std.mem.concat(b.allocator, u8, &.{ 
            "-sPTHREAD_DEFAULT_STACK_SIZE=", 
            try std.fmt.allocPrint(b.allocator, "{d}", .{ pthread_cfg.stack_size }) 
        });
        const profiling = try std.mem.concat(b.allocator, u8, &.{ 
            "-sPTHREADS_PROFILING=", if (pthread_cfg.use_profiler) "1" else "0"
        });
        const blocking = try std.mem.concat(b.allocator, u8, &.{
            "-sALLOW_BLOCKING_ON_MAIN_THREAD=", if (pthread_cfg.allow_blocking_on_main_thread) "1" else "0"
        });
        const debug = try std.mem.concat(b.allocator, u8, &.{
            "-sPTHREADS_DEBUG=", if (pthread_cfg.add_debug_trace) "1" else "0"
        });
        emlink.addArgs(&.{
            "-sUSE_PTHREADS=1", pool_size, delay_load, pool_strictness, 
            stack_size, profiling, blocking, debug,
        });
    }

    if (options.use_sdl) |version| switch (version) {
        .sdl1 => emlink.addArg("-sUSE_SDL=1"),
        .sdl2 => emlink.addArg("-sUSE_SDL=2"),
    };

    if (options.use_webgpu) {
        emlink.addArg("-sUSE_WEBGPU=1");
    }

    emlink.addArg(options.optimizations.toArg());

    // TODO: organize these things and add an option in config for them idk why half of these are even here 
        // "'SDL_WaitEvent', 'SDL_WaitEventTimeout', " ++
        // "'SDL_Delay', 'SDL_RenderPresent', 'GLES2_RenderPresent', " ++ 
        // "'SDL_GL_SwapWindow', 'Emscripten_GLES_SwapWindow', " ++ 
        // "'byn$$fpcast-emu$$Emscripten_GLES_SwapWindow'," ++ 
        // "'SDL_UpdateWindowSurface', 'SDL_UpdateWindowSurfaceRects'," ++ 
        // "'Emscripten_UpdateWindowFramebuffer']";
    if (options.asyncify) {
        const asyncify_whitelist = "['main', 'SDL_WaitEvent', 'SDL_WaitEventTimeout', " ++
            "'SDL_Delay', 'SDL_RenderPresent', 'GLES2_RenderPresent', " ++ 
            "'SDL_GL_SwapWindow', 'Emscripten_GLES_SwapWindow', " ++ 
            "'byn$$fpcast-emu$$Emscripten_GLES_SwapWindow'," ++ 
            "'SDL_UpdateWindowSurface', 'SDL_UpdateWindowSurfaceRects'," ++ 
            "'Emscripten_UpdateWindowFramebuffer']";

        emlink.addArgs(&.{
            "-sASYNCIFY",
            "-s\"ASYNCIFY_WHITELIST=" ++ asyncify_whitelist ++ "\"",     
        });
    }

    emlink.addArg(switch (options.assertions_level) {
        0 => "-sASSERTIONS=0",
        1 => "-sASSERTIONS=1",
        2 => "-sASSERTIONS=2",
        else => unreachable,
    });
        
    emlink.step.dependOn(&emscripten_export.step);
    
    const step_name = if (options.step_name) |step_name| blk: {
        break :blk step_name;
    } else blk: {
        break :blk try std.mem.concat(b.allocator, u8, &.{ exe.name, "-emscripten-wasm" });
    };
    const wasm_compile = b.step(step_name, "compiles wasm linked with emscripten");
    wasm_compile.dependOn(&emlink.step);

    return wasm_compile;
}

pub fn getPkg() Pkg {
    return .{
        .name = "zig_emscripten",
        .source = .{ .path = sdk_root ++ "/src/shim.zig" },
    };
}