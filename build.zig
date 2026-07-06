const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
	// Default to a fully-static musl target on Linux: a native NixOS build otherwise
	// emits a musl-DYNAMIC binary whose loader doesn't exist on NixOS ("required
	// file not found"). musl + static = no loader, runs anywhere. macOS stays
	// native (libSystem is the lone dynamic dep). Explicit -Dtarget overrides.
	const target = b.standardTargetOptions(.{
		.default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
	});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	const link_mode: std.builtin.LinkMode =
		if (target.result.abi == .musl) .static else .dynamic;

	// Parse version out of build.zig.zon so the binary can report it
	const version = blk: {
		const zon = @embedFile("build.zig.zon");
		const marker = ".version = \"";
		const start = std.mem.indexOf(u8, zon, marker) orelse @panic("missing .version in build.zig.zon");
		const after = start + marker.len;
		const end = std.mem.indexOfScalarPos(u8, zon, after, '"') orelse @panic("malformed .version in build.zig.zon");
		break :blk zon[after..end];
	};

	const build_options = b.addOptions();
	build_options.addOption([]const u8, "version", version);

	// PCRE2 (C library, statically linked) — powers the regex separator mode
	const pcre2_dep = b.dependency("pcre2", .{
		.target = target,
		.optimize = optimize,
		.linkage = .static,
		.@"code-unit-width" = .@"8",
	});
	const pcre2_lib = pcre2_dep.artifact("pcre2-8");

	// Zig core as a static library exporting the C ABI (src/ffi.zig is the root;
	// it pulls in the pure core). This library IS the public API of cols.
	const lib_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	lib_mod.addIncludePath(pcre2_lib.getEmittedIncludeTree());
	lib_mod.linkLibrary(pcre2_lib);
	lib_mod.addOptions("build_options", build_options);

	const lib = b.addLibrary(.{
		.name = "cols",
		.linkage = .static,
		.root_module = lib_mod,
	});
	b.installArtifact(lib);

	// C CLI — dogfoods the FFI: consumes include/cols.h, never imports Zig.
	// All I/O (files, stdin/stdout, env vars) lives here.
	const exe_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	exe_mod.addCSourceFile(.{
		.file = b.path("src/cols_cli.c"),
		.flags = &.{ "-std=c11", "-Wall", "-Wextra" },
	});
	exe_mod.addIncludePath(b.path("include"));
	exe_mod.linkLibrary(lib);
	exe_mod.linkLibrary(pcre2_lib);

	const exe = b.addExecutable(.{
		.name = "cols",
		.root_module = exe_mod,
		.linkage = link_mode,
	});
	b.installArtifact(exe);

	// Install the FFI header for external consumers of libcols
	const install_header = b.addInstallFile(b.path("include/cols.h"), "include/cols.h");
	b.getInstallStep().dependOn(&install_header.step);

	// Run step
	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}
	const run_step = b.step("run", "Run cols");
	run_step.dependOn(&run_cmd.step);

	// Unit tests (rooted at ffi.zig → covers FFI layer + pure core transitively)
	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ffi.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});
	unit_tests.root_module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
	unit_tests.root_module.linkLibrary(pcre2_lib);
	unit_tests.root_module.addOptions("build_options", build_options);
	// Match the exe's linkage so the test binary can exec on NixOS (musl-static).
	unit_tests.linkage = link_mode;
	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
}
