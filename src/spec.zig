//! Column-spec parsing: `n`, `m-n`, `m-` atoms, comma-combinable within one
//! arg, accumulating across args. 1-indexed; 0 and reversed ranges rejected.
//! Negative indices count from the last field (`-1` = last), so ranges may
//! use a repeated hyphen: `2--1` (from 2 to last), `-3--1` (last three).
//! Grammar per atom: NUM ( '-' NUM? )? where NUM = '-'? [0-9]+.

const std = @import("std");

/// Positive values are 1-indexed columns from the start; negative values
/// count from the end (-1 = last field, resolved per line against NF).
/// hi == null is an OPEN range (`m-`, `-2-`): elastic "through end of line".
/// This is deliberately distinct from an explicit hi of -1 (`-3--1`), which
/// PROMISES a fixed number of positions (null-rendering depends on it).
pub const Atom = struct {
	lo: i64,
	hi: ?i64,
};

pub const ErrKind = enum {
	invalid, // doesn't match the grammar (incl. empty comma pieces)
	zero_column, // 0 used as a column (columns are 1-indexed)
	reversed, // statically reversed range (same-sign lo > hi)
};

pub const SpecError = struct {
	kind: ErrKind,
	/// The offending text: the whole arg for `invalid`, the atom for `reversed`.
	/// References the caller's arg memory.
	text: []const u8,
};

pub const ParseResult = union(enum) {
	ok: void,
	err: SpecError,
};

/// Parse one spec argument (possibly comma-joined) and append its atoms.
/// Returns a validation verdict; only OOM surfaces as a Zig error.
/// complexity: O(len(arg))
pub fn parseSpecArg(
	gpa: std.mem.Allocator,
	arg: []const u8,
	atoms: *std.ArrayListUnmanaged(Atom),
) std.mem.Allocator.Error!ParseResult {
	if (arg.len == 0) return .{ .err = .{ .kind = .invalid, .text = arg } };
	var it = std.mem.splitScalar(u8, arg, ',');
	while (it.next()) |atom_text| {
		switch (try parseAtom(gpa, arg, atom_text, atoms)) {
			.ok => {},
			.err => |e| return .{ .err = e },
		}
	}
	return .ok;
}

/// Signed decimal scan at s[i..]: optional '-' then digits, saturating on
/// overflow (downstream, the extent guard rejects saturated CLOSED ranges;
/// open ranges and --clamp neutralize saturation via NF clamping).
/// Returns the value and the index just past the number, or null when s[i..]
/// does not start with a number.
fn scanNum(s: []const u8, start: usize) ?struct { val: i64, end: usize } {
	var i = start;
	var neg = false;
	if (i < s.len and s[i] == '-') {
		neg = true;
		i += 1;
	}
	const digits_start = i;
	while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
	if (i == digits_start) return null; // no digits (a bare '-' is not a number)
	var val: i64 = 0;
	var overflowed = false;
	for (s[digits_start..i]) |ch| {
		const ov1 = @mulWithOverflow(val, 10);
		const ov2 = @addWithOverflow(ov1[0], @as(i64, ch - '0'));
		if (ov1[1] != 0 or ov2[1] != 0) {
			overflowed = true;
			break;
		}
		val = ov2[0];
	}
	if (overflowed) val = std.math.maxInt(i64);
	return .{ .val = if (neg) -val else val, .end = i };
}

fn parseAtom(
	gpa: std.mem.Allocator,
	whole_arg: []const u8,
	atom_text: []const u8,
	atoms: *std.ArrayListUnmanaged(Atom),
) std.mem.Allocator.Error!ParseResult {
	// Grammar first, semantics second: "0x10" is junk (invalid), not a use
	// of column 0 — zero/reversed checks only fire on well-formed atoms.
	const invalid: ParseResult = .{ .err = .{ .kind = .invalid, .text = whole_arg } };
	const zero: ParseResult = .{ .err = .{ .kind = .zero_column, .text = atom_text } };
	const first = scanNum(atom_text, 0) orelse return invalid;
	const lo = first.val;
	if (first.end == atom_text.len) {
		if (lo == 0) return zero;
		try atoms.append(gpa, .{ .lo = lo, .hi = lo });
		return .ok;
	}
	if (atom_text[first.end] != '-') return invalid;
	const hi_start = first.end + 1;
	if (hi_start == atom_text.len) {
		if (lo == 0) return zero;
		try atoms.append(gpa, .{ .lo = lo, .hi = null });
		return .ok;
	}
	const second = scanNum(atom_text, hi_start) orelse return invalid;
	if (second.end != atom_text.len) return invalid; // trailing junk (2-3-4)
	const hi = second.val;
	if (lo == 0 or hi == 0) return zero;
	// Reversal is only statically knowable when both ends share a sign;
	// mixed-sign ranges resolve per line (an empty selection, never an error).
	if ((lo > 0) == (hi > 0) and lo > hi) return .{ .err = .{ .kind = .reversed, .text = atom_text } };
	try atoms.append(gpa, .{ .lo = lo, .hi = hi });
	return .ok;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectAtoms(input: []const []const u8, expected: []const Atom) !void {
	var atoms: std.ArrayListUnmanaged(Atom) = .empty;
	defer atoms.deinit(testing.allocator);
	for (input) |arg| {
		const r = try parseSpecArg(testing.allocator, arg, &atoms);
		try testing.expect(r == .ok);
	}
	try testing.expectEqualSlices(Atom, expected, atoms.items);
}

fn expectErr(arg: []const u8, kind: ErrKind) !void {
	var atoms: std.ArrayListUnmanaged(Atom) = .empty;
	defer atoms.deinit(testing.allocator);
	const r = try parseSpecArg(testing.allocator, arg, &atoms);
	try testing.expect(r == .err);
	try testing.expectEqual(kind, r.err.kind);
}

test "single column n" {
	try expectAtoms(&.{"2"}, &.{.{ .lo = 2, .hi = 2 }});
}

test "closed range m-n" {
	try expectAtoms(&.{"2-3"}, &.{.{ .lo = 2, .hi = 3 }});
}

test "open range m- has a null hi (elastic, distinct from explicit -1)" {
	try expectAtoms(&.{"2-"}, &.{.{ .lo = 2, .hi = null }});
}

test "equal range m-m" {
	try expectAtoms(&.{"4-4"}, &.{.{ .lo = 4, .hi = 4 }});
}

test "comma-joined atoms in one arg" {
	try expectAtoms(&.{"2,4-6,9-"}, &.{
		.{ .lo = 2, .hi = 2 },
		.{ .lo = 4, .hi = 6 },
		.{ .lo = 9, .hi = null },
	});
}

test "atoms accumulate across args in order" {
	try expectAtoms(&.{ "1", "3-4", "2" }, &.{
		.{ .lo = 1, .hi = 1 },
		.{ .lo = 3, .hi = 4 },
		.{ .lo = 2, .hi = 2 },
	});
}

test "leading zeros are decimal, not octal" {
	try expectAtoms(&.{"02"}, &.{.{ .lo = 2, .hi = 2 }});
	try expectAtoms(&.{"010-011"}, &.{.{ .lo = 10, .hi = 11 }});
}

test "huge numbers saturate instead of erroring (clamping makes them moot)" {
	try expectAtoms(&.{"2-99999999999999999999999999"}, &.{.{ .lo = 2, .hi = std.math.maxInt(i64) }});
}

test "negative index: -1 is the last column" {
	try expectAtoms(&.{"-1"}, &.{.{ .lo = -1, .hi = -1 }});
	try expectAtoms(&.{"-2"}, &.{.{ .lo = -2, .hi = -2 }});
}

test "negative ranges use a repeated hyphen" {
	try expectAtoms(&.{"2--1"}, &.{.{ .lo = 2, .hi = -1 }});
	try expectAtoms(&.{"-3--1"}, &.{.{ .lo = -3, .hi = -1 }});
	try expectAtoms(&.{"-3--2"}, &.{.{ .lo = -3, .hi = -2 }});
}

test "negative open range: -2- means from second-to-last through end" {
	try expectAtoms(&.{"-2-"}, &.{.{ .lo = -2, .hi = null }});
}

test "mixed-sign ranges parse (resolved per line, never a static error)" {
	try expectAtoms(&.{"-2-3"}, &.{.{ .lo = -2, .hi = 3 }});
}

test "negatives combine with commas and positives" {
	try expectAtoms(&.{"1,-1"}, &.{
		.{ .lo = 1, .hi = 1 },
		.{ .lo = -1, .hi = -1 },
	});
	try expectAtoms(&.{ "2", "-3--1" }, &.{
		.{ .lo = 2, .hi = 2 },
		.{ .lo = -3, .hi = -1 },
	});
}

test "non-numeric and structurally malformed specs are invalid" {
	try expectErr("foo", .invalid);
	try expectErr("2x", .invalid);
	try expectErr("x2", .invalid);
	try expectErr("", .invalid);
	try expectErr("-", .invalid);
	try expectErr("--1", .invalid);
	try expectErr("2---1", .invalid);
	try expectErr("2--3-4", .invalid);
	try expectErr("5--", .invalid);
	try expectErr("-1x", .invalid);
	try expectErr("2.5", .invalid);
	try expectErr(" 2", .invalid);
	// grammar junk with a leading 0 is INVALID, not a zero-column complaint
	try expectErr("0x10", .invalid);
	try expectErr("0abc", .invalid);
}

test "malformed comma structure is invalid (empties can't sneak past)" {
	try expectErr("2,", .invalid);
	try expectErr(",2", .invalid);
	try expectErr("2,,3", .invalid);
	try expectErr(",", .invalid);
}

test "column 0 rejected in every position, including negative zero" {
	try expectErr("0", .zero_column);
	try expectErr("0-2", .zero_column);
	try expectErr("2-0", .zero_column);
	try expectErr("0-", .zero_column);
	try expectErr("1,0", .zero_column);
	try expectErr("-0", .zero_column);
	try expectErr("2--0", .zero_column);
}

test "statically reversed ranges rejected (same sign only)" {
	try expectErr("3-2", .reversed);
	try expectErr("1,5-4", .reversed);
	try expectErr("99999999999999999999999999-2", .reversed);
	try expectErr("-1--2", .reversed); // last .. second-to-last is always reversed
	try expectErr("-1--3", .reversed);
}

test "invalid error reports the whole offending arg" {
	var atoms: std.ArrayListUnmanaged(Atom) = .empty;
	defer atoms.deinit(testing.allocator);
	const r = try parseSpecArg(testing.allocator, "2,,3", &atoms);
	try testing.expectEqualStrings("2,,3", r.err.text);
}

test "reversed error reports the offending atom" {
	var atoms: std.ArrayListUnmanaged(Atom) = .empty;
	defer atoms.deinit(testing.allocator);
	const r = try parseSpecArg(testing.allocator, "1,5-4", &atoms);
	try testing.expectEqualStrings("5-4", r.err.text);
}
