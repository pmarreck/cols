//! Field splitters — one per separator mode. All operate on a single line
//! (no newline inside) and append slices of that line into a reused list.
//! Universal rule: an empty line yields ZERO fields in every mode (matching
//! awk, whose empty record has NF=0) — line correspondence is handled a
//! level up by always emitting one output line per input line.

const std = @import("std");
const pcre2 = @import("pcre2.zig");

pub const Fields = std.ArrayListUnmanaged([]const u8);

/// "No field cap" sentinel for the splitters' max_fields parameter.
pub const NO_CAP: usize = std.math.maxInt(usize);

const Allocator = std.mem.Allocator;

/// awk default mode: runs of spaces/tabs are one separator; leading and
/// trailing whitespace produce no fields. Stops after max_fields fields —
/// selection can never need more than the largest requested column.
/// complexity: O(n)
pub fn splitDefaultWs(line: []const u8, gpa: Allocator, out: *Fields, max_fields: usize) Allocator.Error!void {
	var i: usize = 0;
	while (i < line.len) {
		while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
		if (i >= line.len) break;
		const start = i;
		while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
		try out.append(gpa, line[start..i]);
		if (out.items.len >= max_fields) return;
	}
}

/// cut/awk-FS-style literal separator: the WHOLE string `sep` (len >= 1,
/// possibly multi-byte/multi-char) is one delimiter. Adjacent, leading, and
/// trailing delimiters all delimit empty fields (n separators => n+1 fields).
/// Stops scanning after max_fields fields (the tail of the line is skipped
/// entirely — this is the big win vs. materializing every field).
/// complexity: O(n) (memchr-style scans; SIMD-assisted)
pub fn splitLiteral(line: []const u8, sep: []const u8, gpa: Allocator, out: *Fields, max_fields: usize) Allocator.Error!void {
	if (line.len == 0 or max_fields == 0) return;
	std.debug.assert(sep.len > 0); // empty separators resolve to `none` upstream
	var pos: usize = 0;
	if (sep.len == 1) {
		// single-byte fast path: indexOfScalarPos is a straight memchr
		const ch = sep[0];
		while (std.mem.indexOfScalarPos(u8, line, pos, ch)) |idx| {
			try out.append(gpa, line[pos..idx]);
			pos = idx + 1;
			if (out.items.len >= max_fields) return;
		}
	} else {
		while (std.mem.indexOfPos(u8, line, pos, sep)) |idx| {
			try out.append(gpa, line[pos..idx]);
			pos = idx + sep.len;
			if (out.items.len >= max_fields) return;
		}
	}
	try out.append(gpa, line[pos..]);
}

/// No splitting: the whole (non-empty) line is field 1. This is what an
/// empty IFS/COLS_IFS/separator resolves to, mirroring shell `IFS=` semantics.
pub fn splitWholeLine(line: []const u8, gpa: Allocator, out: *Fields) Allocator.Error!void {
	if (line.len == 0) return;
	try out.append(gpa, line);
}

/// An IFS character set decomposed for POSIX field splitting. Members that
/// are space/tab/newline are "IFS whitespace" (runs collapse, leading/trailing
/// stripped); all other members (full UTF-8 code points) are strict
/// delimiters (adjacent => empty field, trailing => nothing).
pub const IfsSet = struct {
	src: []u8, // owned copy of the IFS string, in given order
	ws_space: bool,
	ws_tab: bool,
	ws_newline: bool,
	nonws: [][]const u8, // owned list of slices into src (code points)
	gpa: Allocator,

	pub fn init(gpa: Allocator, ifs: []const u8) Allocator.Error!IfsSet {
		const src = try gpa.dupe(u8, ifs);
		errdefer gpa.free(src);
		var nonws: std.ArrayListUnmanaged([]const u8) = .empty;
		errdefer nonws.deinit(gpa);
		var ws_space = false;
		var ws_tab = false;
		var ws_newline = false;
		var i: usize = 0;
		while (i < src.len) {
			const cp_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
			const end = @min(i + cp_len, src.len);
			const cp = src[i..end];
			if (cp.len == 1 and cp[0] == ' ') {
				ws_space = true;
			} else if (cp.len == 1 and cp[0] == '\t') {
				ws_tab = true;
			} else if (cp.len == 1 and cp[0] == '\n') {
				ws_newline = true;
			} else {
				try nonws.append(gpa, cp);
			}
			i = end;
		}
		return .{
			.src = src,
			.ws_space = ws_space,
			.ws_tab = ws_tab,
			.ws_newline = ws_newline,
			.nonws = try nonws.toOwnedSlice(gpa),
			.gpa = gpa,
		};
	}

	pub fn deinit(self: *IfsSet) void {
		self.gpa.free(self.nonws);
		self.gpa.free(self.src);
	}

	/// Shell `"$*"` convention: joins use the FIRST character (code point)
	/// of the set as given.
	pub fn joinStr(self: *const IfsSet) []const u8 {
		if (self.src.len == 0) return "";
		const cp_len = std.unicode.utf8ByteSequenceLength(self.src[0]) catch 1;
		return self.src[0..@min(cp_len, self.src.len)];
	}

	fn isWs(self: *const IfsSet, ch: u8) bool {
		return (self.ws_space and ch == ' ') or
			(self.ws_tab and ch == '\t') or
			(self.ws_newline and ch == '\n');
	}

	/// Length of the non-whitespace member matching at line[i], or null.
	fn matchNonWs(self: *const IfsSet, line: []const u8, i: usize) ?usize {
		for (self.nonws) |m| {
			if (i + m.len <= line.len and std.mem.eql(u8, line[i .. i + m.len], m)) return m.len;
		}
		return null;
	}
};

/// True POSIX shell word-splitting over an IFS set. NOT naive char-split:
/// whitespace-member runs collapse, whitespace adjacent to a non-whitespace
/// delimiter folds into it, and a trailing delimiter yields no empty field.
/// complexity: O(n·m) where m = |non-ws IFS members| (m is tiny in practice)
pub fn splitIfs(line: []const u8, set: *const IfsSet, gpa: Allocator, out: *Fields, max_fields: usize) Allocator.Error!void {
	var i: usize = 0;
	// POSIX: leading IFS whitespace is ignored
	while (i < line.len and set.isWs(line[i])) i += 1;
	if (i >= line.len or max_fields == 0) return;
	while (true) {
		const start = i;
		// advance to the next delimiter (ws member or non-ws member) or EOL
		while (i < line.len) {
			if (set.isWs(line[i])) break;
			if (set.matchNonWs(line, i) != null) break;
			i += 1;
		}
		try out.append(gpa, line[start..i]);
		if (out.items.len >= max_fields) return;
		if (i >= line.len) return;
		// consume ONE delimiter: [ws run] [one non-ws member [ws run]]
		while (i < line.len and set.isWs(line[i])) i += 1;
		if (i < line.len) {
			if (set.matchNonWs(line, i)) |mlen| {
				i += mlen;
				while (i < line.len and set.isWs(line[i])) i += 1;
			}
		}
		// POSIX: a trailing delimiter terminates the last field — no empty field
		if (i >= line.len) return;
	}
}

/// PCRE2 regex split with awk/JS semantics: fields are the text between
/// matches; leading/adjacent/trailing matches produce empty fields; an empty
/// match splits between characters but never produces empty fields itself
/// (and never loops forever).
/// complexity: O(n) match attempts (PCRE2 does the scanning; JIT-compiled)
pub fn splitRegex(line: []const u8, re: *pcre2.Regex, gpa: Allocator, out: *Fields, max_fields: usize) Allocator.Error!void {
	if (line.len == 0 or max_fields == 0) return;
	var pos: usize = 0; // start of the current field
	var search: usize = 0;
	while (search <= line.len) {
		const m = re.matchAt(line, search, 0) orelse break;
		if (m.end == m.start) {
			// Empty match: splits only strictly inside the current field, and
			// never at end-of-line — and always advances (no infinite loop).
			if (m.start >= line.len) break;
			if (m.start == pos) {
				search = utf8Next(line, m.start);
				continue;
			}
			try out.append(gpa, line[pos..m.start]);
			if (out.items.len >= max_fields) return;
			pos = m.start;
			search = utf8Next(line, m.start);
			continue;
		}
		try out.append(gpa, line[pos..m.start]);
		if (out.items.len >= max_fields) return;
		pos = m.end;
		search = m.end;
	}
	try out.append(gpa, line[pos..]);
}

/// Next code-point boundary at or after i+1 (clamped to end of slice).
fn utf8Next(s: []const u8, i: usize) usize {
	const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
	return @min(i + len, s.len);
}

// ---------------------------------------------------------------------------
// Tests (table-driven where the mode allows)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFields(actual: *const Fields, expected: []const []const u8) !void {
	try testing.expectEqual(expected.len, actual.items.len);
	for (expected, actual.items) |e, a| {
		try testing.expectEqualStrings(e, a);
	}
}

test "default ws: basic, runs, leading, trailing, tabs" {
	const cases = [_]struct { line: []const u8, want: []const []const u8 }{
		.{ .line = "a b c", .want = &.{ "a", "b", "c" } },
		.{ .line = "a\t b   c", .want = &.{ "a", "b", "c" } },
		.{ .line = "   a b", .want = &.{ "a", "b" } },
		.{ .line = "a b   ", .want = &.{ "a", "b" } },
		.{ .line = "a", .want = &.{"a"} },
		.{ .line = "", .want = &.{} },
		.{ .line = "   \t ", .want = &.{} },
	};
	for (cases) |case| {
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitDefaultWs(case.line, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "literal: single char, adjacency, leading/trailing empties" {
	const cases = [_]struct { line: []const u8, sep: []const u8, want: []const []const u8 }{
		.{ .line = "a:b:c", .sep = ":", .want = &.{ "a", "b", "c" } },
		.{ .line = "a::c", .sep = ":", .want = &.{ "a", "", "c" } },
		.{ .line = ":a", .sep = ":", .want = &.{ "", "a" } },
		.{ .line = "a:", .sep = ":", .want = &.{ "a", "" } },
		.{ .line = "abc", .sep = ":", .want = &.{"abc"} },
		.{ .line = "", .sep = ":", .want = &.{} },
		.{ .line = "a.b.c", .sep = ".", .want = &.{ "a", "b", "c" } }, // metachar is literal
	};
	for (cases) |case| {
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitLiteral(case.line, case.sep, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "literal: multi-char and multibyte separators are whole-string delimiters" {
	const cases = [_]struct { line: []const u8, sep: []const u8, want: []const []const u8 }{
		.{ .line = "a::b::c", .sep = "::", .want = &.{ "a", "b", "c" } },
		.{ .line = "a:b", .sep = "::", .want = &.{"a:b"} },
		.{ .line = "a::::b", .sep = "::", .want = &.{ "a", "", "b" } },
		.{ .line = "a→b→c", .sep = "→", .want = &.{ "a", "b", "c" } },
	};
	for (cases) |case| {
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitLiteral(case.line, case.sep, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "whole line: one field, except empty line" {
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitWholeLine("a b c", testing.allocator, &fields);
	try expectFields(&fields, &.{"a b c"});
	fields.clearRetainingCapacity();
	try splitWholeLine("", testing.allocator, &fields);
	try expectFields(&fields, &.{});
}

test "IfsSet classifies whitespace vs strict members and keeps join order" {
	var set = try IfsSet.init(testing.allocator, ": \t");
	defer set.deinit();
	try testing.expect(set.ws_space);
	try testing.expect(set.ws_tab);
	try testing.expect(!set.ws_newline);
	try testing.expectEqual(@as(usize, 1), set.nonws.len);
	try testing.expectEqualStrings(":", set.nonws[0]);
	try testing.expectEqualStrings(":", set.joinStr());

	var set2 = try IfsSet.init(testing.allocator, "→x");
	defer set2.deinit();
	try testing.expectEqualStrings("→", set2.joinStr()); // first CODE POINT, not first byte
	try testing.expectEqual(@as(usize, 2), set2.nonws.len);
}

test "ifs: strict delimiters — adjacency, leading empty, trailing dropped" {
	const cases = [_]struct { line: []const u8, ifs: []const u8, want: []const []const u8 }{
		.{ .line = "a:b:c", .ifs = ":", .want = &.{ "a", "b", "c" } },
		.{ .line = "a::c", .ifs = ":", .want = &.{ "a", "", "c" } },
		.{ .line = ":a", .ifs = ":", .want = &.{ "", "a" } },
		.{ .line = "a:", .ifs = ":", .want = &.{"a"} }, // shell: trailing delim ends the field, no empty
		.{ .line = "a::", .ifs = ":", .want = &.{ "a", "" } },
		.{ .line = "", .ifs = ":", .want = &.{} },
		.{ .line = "a:b,c", .ifs = ":,", .want = &.{ "a", "b", "c" } },
	};
	for (cases) |case| {
		var set = try IfsSet.init(testing.allocator, case.ifs);
		defer set.deinit();
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitIfs(case.line, &set, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "ifs: whitespace members collapse; mixed sets follow shell rules" {
	const cases = [_]struct { line: []const u8, ifs: []const u8, want: []const []const u8 }{
		// pure whitespace set == default mode behavior
		.{ .line = "  a\tb  c ", .ifs = " \t\n", .want = &.{ "a", "b", "c" } },
		.{ .line = "a\t\tc", .ifs = "\t", .want = &.{ "a", "c" } }, // ws runs collapse (NOT cut-like)
		.{ .line = "   ", .ifs = " \t\n", .want = &.{} },
		// mixed: space runs around a colon collapse into ONE split
		.{ .line = "a : b", .ifs = ": ", .want = &.{ "a", "b" } },
		.{ .line = "a:b", .ifs = ": ", .want = &.{ "a", "b" } },
		.{ .line = "a  b", .ifs = ": ", .want = &.{ "a", "b" } },
		.{ .line = "a :: b", .ifs = ": ", .want = &.{ "a", "", "b" } },
		.{ .line = " a:b ", .ifs = ": ", .want = &.{ "a", "b" } },
		.{ .line = "a :", .ifs = ": ", .want = &.{"a"} }, // trailing delim + ws: nothing
	};
	for (cases) |case| {
		var set = try IfsSet.init(testing.allocator, case.ifs);
		defer set.deinit();
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitIfs(case.line, &set, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "ifs: multibyte member splits and joins correctly" {
	var set = try IfsSet.init(testing.allocator, "→");
	defer set.deinit();
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitIfs("a→b→c", &set, testing.allocator, &fields, NO_CAP);
	try expectFields(&fields, &.{ "a", "b", "c" });
}

test "regex: separators, adjacency, leading/trailing empties (awk semantics)" {
	const cases = [_]struct { line: []const u8, pat: []const u8, want: []const []const u8 }{
		.{ .line = "a::b:c", .pat = ":+", .want = &.{ "a", "b", "c" } },
		.{ .line = "a12b345c", .pat = "[0-9]+", .want = &.{ "a", "b", "c" } },
		.{ .line = "a  b\tc", .pat = "\\s+", .want = &.{ "a", "b", "c" } },
		.{ .line = " a b", .pat = "\\s+", .want = &.{ "", "a", "b" } }, // regex FS: leading empty (awk)
		.{ .line = "a:", .pat = ":", .want = &.{ "a", "" } }, // trailing empty kept (awk)
		.{ .line = "a::b", .pat = ":", .want = &.{ "a", "", "b" } },
		.{ .line = "", .pat = ":", .want = &.{} },
		.{ .line = "abc", .pat = ":", .want = &.{"abc"} },
	};
	for (cases) |case| {
		const r = try pcre2.Regex.compile(case.pat);
		var re = r.ok;
		defer re.deinit();
		var fields: Fields = .empty;
		defer fields.deinit(testing.allocator);
		try splitRegex(case.line, &re, testing.allocator, &fields, NO_CAP);
		try expectFields(&fields, case.want);
	}
}

test "regex: empty matches split between characters without looping forever" {
	const r = try pcre2.Regex.compile("x*");
	var re = r.ok;
	defer re.deinit();
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitRegex("abc", &re, testing.allocator, &fields, NO_CAP);
	try expectFields(&fields, &.{ "a", "b", "c" });
}

test "regex: empty matches advance by whole UTF-8 code points" {
	const r = try pcre2.Regex.compile("x*");
	var re = r.ok;
	defer re.deinit();
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitRegex("é中", &re, testing.allocator, &fields, NO_CAP);
	try expectFields(&fields, &.{ "é", "中" });
}

// ---------------------------------------------------------------------------
// max_fields cap: splitters may stop early once every requested field is in
// hand (pure optimization — selection semantics must be indistinguishable
// from splitting the whole line, because every atom's hi <= cap).
// ---------------------------------------------------------------------------

test "cap: literal stops collecting after max_fields" {
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitLiteral("a:b:c:d", ":", testing.allocator, &fields, 2);
	try expectFields(&fields, &.{ "a", "b" });
	fields.clearRetainingCapacity();
	try splitLiteral("a:b", ":", testing.allocator, &fields, 5); // cap beyond NF: all fields
	try expectFields(&fields, &.{ "a", "b" });
	fields.clearRetainingCapacity();
	try splitLiteral("a:", ":", testing.allocator, &fields, 1); // trailing empty never needed
	try expectFields(&fields, &.{"a"});
}

test "cap: default ws stops collecting after max_fields" {
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitDefaultWs("a b c d", testing.allocator, &fields, 2);
	try expectFields(&fields, &.{ "a", "b" });
}

test "cap: ifs stops collecting after max_fields" {
	var set = try IfsSet.init(testing.allocator, ": ");
	defer set.deinit();
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitIfs("a : b : c", &set, testing.allocator, &fields, 1);
	try expectFields(&fields, &.{"a"});
}

test "cap: regex stops collecting after max_fields" {
	const r = try pcre2.Regex.compile("[0-9]");
	var re = r.ok;
	defer re.deinit();
	var fields: Fields = .empty;
	defer fields.deinit(testing.allocator);
	try splitRegex("a1b2c", &re, testing.allocator, &fields, 2);
	try expectFields(&fields, &.{ "a", "b" });
}
