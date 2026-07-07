//! Minimal PCRE2 binding for the regex separator mode: compile once, then
//! repeatedly find match offsets for splitting. UTF-8 + UCP, with
//! PCRE2_MATCH_INVALID_UTF so arbitrary (possibly non-UTF-8) input never
//! aborts a match. JIT is enabled opportunistically.

const std = @import("std");

const c = @cImport({
	@cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
	@cInclude("pcre2.h");
});

pub const Match = struct {
	start: usize,
	end: usize,
};

pub const CompileFailure = struct {
	code: c_int,
	offset: usize,

	/// Render PCRE2's own error message into `buf`.
	pub fn message(self: CompileFailure, buf: []u8) []const u8 {
		const len = c.pcre2_get_error_message_8(self.code, buf.ptr, buf.len);
		if (len < 0) return "unknown regex error";
		return buf[0..@intCast(len)];
	}
};

pub const CompileResult = union(enum) {
	ok: Regex,
	err: CompileFailure,
};

pub const MatchError = error{MatchFailed};

pub const Regex = struct {
	code: *c.pcre2_code_8,
	match_data: *c.pcre2_match_data_8,
	/// PCRE2 error code from the last MatchFailed (for lastErrorMessage).
	last_error: c_int = 0,

	pub fn compile(pattern: []const u8) error{OutOfMemory}!CompileResult {
		var error_code: c_int = 0;
		var error_offset: c.PCRE2_SIZE = 0;
		const options: u32 = c.PCRE2_UTF | c.PCRE2_UCP | c.PCRE2_MATCH_INVALID_UTF;
		const code = c.pcre2_compile_8(
			pattern.ptr,
			pattern.len,
			options,
			&error_code,
			&error_offset,
			null,
		) orelse return .{ .err = .{ .code = error_code, .offset = @intCast(error_offset) } };

		// Opportunistic JIT; interpreted matching is the silent fallback.
		_ = c.pcre2_jit_compile_8(code, c.PCRE2_JIT_COMPLETE);

		const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse {
			c.pcre2_code_free_8(code);
			return error.OutOfMemory;
		};

		return .{ .ok = .{ .code = code, .match_data = match_data } };
	}

	pub fn deinit(self: *Regex) void {
		c.pcre2_match_data_free_8(self.match_data);
		c.pcre2_code_free_8(self.code);
	}

	/// Find the next match at or after `start`. Returns null when there is no
	/// further match; a genuine match-time failure (MATCHLIMIT/DEPTHLIMIT/
	/// JIT_STACKLIMIT — e.g. catastrophic backtracking) is an ERROR, never
	/// silently "no match": swallowing it once shipped wrong field boundaries
	/// with exit 0. `options` may carry PCRE2_NOTEMPTY_ATSTART etc.
	pub fn matchAt(self: *Regex, subject: []const u8, start: usize, options: u32) MatchError!?Match {
		const rc = c.pcre2_match_8(
			self.code,
			subject.ptr,
			subject.len,
			start,
			options,
			self.match_data,
			null,
		);
		if (rc == c.PCRE2_ERROR_NOMATCH) return null;
		if (rc < 0) {
			self.last_error = rc;
			return error.MatchFailed;
		}
		const ovector = c.pcre2_get_ovector_pointer_8(self.match_data);
		return .{ .start = @intCast(ovector[0]), .end = @intCast(ovector[1]) };
	}

	/// Render PCRE2's message for the last MatchFailed into `buf`.
	pub fn lastErrorMessage(self: *const Regex, buf: []u8) []const u8 {
		const len = c.pcre2_get_error_message_8(self.last_error, buf.ptr, buf.len);
		if (len < 0) return "unknown regex match error";
		return buf[0..@intCast(len)];
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "compile + matchAt finds offsets" {
	const r = try Regex.compile(":");
	try testing.expect(r == .ok);
	var re = r.ok;
	defer re.deinit();
	const m = (try re.matchAt("ab:cd", 0, 0)).?;
	try testing.expectEqual(@as(usize, 2), m.start);
	try testing.expectEqual(@as(usize, 3), m.end);
	try testing.expect(try re.matchAt("ab:cd", 3, 0) == null);
}

test "matchAt honors the start offset" {
	const r = try Regex.compile(":");
	var re = r.ok;
	defer re.deinit();
	const m = (try re.matchAt("a:b:c", 2, 0)).?;
	try testing.expectEqual(@as(usize, 3), m.start);
}

test "quantified pattern matches greedily" {
	const r = try Regex.compile("[0-9]+");
	var re = r.ok;
	defer re.deinit();
	const m = (try re.matchAt("ab1234cd", 0, 0)).?;
	try testing.expectEqual(@as(usize, 2), m.start);
	try testing.expectEqual(@as(usize, 6), m.end);
}

test "compile failure yields code + offset + renderable message" {
	const r = try Regex.compile("(");
	try testing.expect(r == .err);
	var buf: [256]u8 = undefined;
	const msg = r.err.message(&buf);
	try testing.expect(msg.len > 0);
}

test "invalid UTF-8 in the subject does not abort matching" {
	const r = try Regex.compile(":");
	var re = r.ok;
	defer re.deinit();
	const subject = "a\xffb:c";
	const m = (try re.matchAt(subject, 0, 0)).?;
	try testing.expectEqual(@as(usize, 3), m.start);
}

test "match-time resource exhaustion is an error, not a silent no-match" {
	// (a+)+b with a long 'a' prefix and a 'b' present later forces
	// catastrophic backtracking past PCRE2's default match limit
	const r = try Regex.compile("(a+)+b");
	var re = r.ok;
	defer re.deinit();
	const subject = ("a" ** 40) ++ "c aab tail";
	try testing.expectError(error.MatchFailed, re.matchAt(subject, 0, 0));
	var buf: [128]u8 = undefined;
	try testing.expect(re.lastErrorMessage(&buf).len > 0);
}

test "UTF mode: multibyte pattern matches multibyte subject" {
	const r = try Regex.compile("→");
	var re = r.ok;
	defer re.deinit();
	const m = (try re.matchAt("a→b", 0, 0)).?;
	try testing.expectEqual(@as(usize, 1), m.start);
	try testing.expectEqual(@as(usize, 4), m.end); // '→' is 3 bytes
}
