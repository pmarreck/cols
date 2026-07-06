//! C ABI for libcols — the real public API. The C CLI (and any other
//! consumer) drives the pure Zig core exclusively through these exports;
//! keep in lockstep with include/cols.h.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const process = @import("process.zig");

const gpa = std.heap.c_allocator;

/// Mirrors cols_sep_mode in cols.h.
const CConfig = extern struct {
	sep_mode: c_int,
	sep: ?[*]const u8,
	sep_len: usize,
	out_sep: ?[*]const u8, // null => derive join per mode rules
	out_sep_len: usize,
	json: c_int,
};

const version_z = std.fmt.comptimePrint("{s}", .{build_options.version});
const about_z = std.fmt.comptimePrint(
	"cols {s} — extract columns from line-oriented text by number ({t}-{t})",
	.{ build_options.version, builtin.target.os.tag, builtin.target.cpu.arch },
);

fn setErr(errbuf: ?[*]u8, errbuf_cap: usize, msg: []const u8) void {
	const buf = (errbuf orelse return)[0..errbuf_cap];
	if (buf.len == 0) return;
	const n = @min(msg.len, buf.len - 1);
	@memcpy(buf[0..n], msg[0..n]);
	buf[n] = 0;
}

/// Parse specs + config into a processing context. Returns null on any
/// usage-level failure with a message in errbuf (NUL-terminated).
export fn cols_create(
	specs: [*]const [*:0]const u8,
	nspecs: usize,
	cfg: *const CConfig,
	errbuf: ?[*]u8,
	errbuf_cap: usize,
) ?*process.Processor {
	const spec_slices = gpa.alloc([]const u8, nspecs) catch {
		setErr(errbuf, errbuf_cap, "out of memory");
		return null;
	};
	defer gpa.free(spec_slices);
	for (spec_slices, 0..) |*s, i| s.* = std.mem.span(specs[i]);

	const mode = std.enums.fromInt(process.SepMode, cfg.sep_mode) orelse {
		setErr(errbuf, errbuf_cap, "invalid separator mode");
		return null;
	};
	const zcfg: process.Config = .{
		.sep_mode = mode,
		.sep = if (cfg.sep) |p| p[0..cfg.sep_len] else "",
		.out_sep = if (cfg.out_sep) |p| p[0..cfg.out_sep_len] else null,
		.json = cfg.json != 0,
	};

	var msgbuf: [512]u8 = undefined;
	const result = process.Processor.create(gpa, spec_slices, zcfg, &msgbuf) catch {
		setErr(errbuf, errbuf_cap, "out of memory");
		return null;
	};
	switch (result) {
		.ok => |p| return p,
		.err => |msg| {
			setErr(errbuf, errbuf_cap, msg);
			return null;
		},
	}
}

/// Feed a chunk of complete lines (final line may be unterminated at EOF).
/// On success sets *out/*out_len to a buffer valid until the next call.
export fn cols_process(
	p: *process.Processor,
	data: [*]const u8,
	len: usize,
	out: *[*]const u8,
	out_len: *usize,
) c_int {
	const result = p.processChunk(data[0..len]) catch return -1;
	out.* = result.ptr;
	out_len.* = result.len;
	return 0;
}

/// Emit trailing output (JSON close). Same buffer-validity contract.
export fn cols_finish(p: *process.Processor, out: *[*]const u8, out_len: *usize) c_int {
	const result = p.finish() catch return -1;
	out.* = result.ptr;
	out_len.* = result.len;
	return 0;
}

export fn cols_destroy(p: *process.Processor) void {
	p.destroy();
}

export fn cols_version() [*:0]const u8 {
	return version_z;
}

export fn cols_about() [*:0]const u8 {
	return about_z;
}

export fn cols_is_debug_build() c_int {
	return if (builtin.mode == .Debug) 1 else 0;
}

// ---------------------------------------------------------------------------
// Tests — exercise the exported ABI itself, plus pull in every module's tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
	_ = @import("spec.zig");
	_ = @import("split.zig");
	_ = @import("process.zig");
	_ = @import("pcre2.zig");
}

test "ffi round trip: create, process, finish, destroy" {
	var errbuf: [256]u8 = undefined;
	const specs = [_][*:0]const u8{"2"};
	const cfg: CConfig = .{
		.sep_mode = 0, // default_ws
		.sep = null,
		.sep_len = 0,
		.out_sep = null,
		.out_sep_len = 0,
		.json = 0,
	};
	const p = cols_create(&specs, specs.len, &cfg, &errbuf, errbuf.len) orelse {
		std.debug.print("cols_create failed: {s}\n", .{std.mem.sliceTo(&errbuf, 0)});
		return error.CreateFailed;
	};
	defer cols_destroy(p);

	const input = "a b c\nd e f\n";
	var out: [*]const u8 = undefined;
	var out_len: usize = 0;
	try testing.expectEqual(@as(c_int, 0), cols_process(p, input.ptr, input.len, &out, &out_len));
	try testing.expectEqualStrings("b\ne\n", out[0..out_len]);
	try testing.expectEqual(@as(c_int, 0), cols_finish(p, &out, &out_len));
	try testing.expectEqualStrings("", out[0..out_len]);
}

test "ffi error path: bad spec yields null + NUL-terminated message" {
	var errbuf: [256]u8 = undefined;
	const specs = [_][*:0]const u8{"3-2"};
	const cfg: CConfig = .{
		.sep_mode = 0,
		.sep = null,
		.sep_len = 0,
		.out_sep = null,
		.out_sep_len = 0,
		.json = 0,
	};
	const p = cols_create(&specs, specs.len, &cfg, &errbuf, errbuf.len);
	try testing.expect(p == null);
	const msg = std.mem.sliceTo(&errbuf, 0);
	try testing.expect(std.mem.indexOf(u8, msg, "reversed") != null);
}

test "ffi metadata: version, about, debug flag" {
	try testing.expectEqualStrings(build_options.version, std.mem.span(cols_version()));
	const about = std.mem.span(cols_about());
	try testing.expect(std.mem.indexOf(u8, about, build_options.version) != null);
	try testing.expect(std.mem.indexOf(u8, about, @tagName(builtin.target.os.tag)) != null);
	try testing.expect(std.mem.indexOf(u8, about, "\n") == null); // strictly one line
	const dbg = cols_is_debug_build();
	try testing.expectEqual(@as(c_int, if (builtin.mode == .Debug) 1 else 0), dbg);
}
