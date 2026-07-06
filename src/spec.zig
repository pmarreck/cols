//! Column-spec parsing: `n`, `m-n`, `m-` atoms, comma-combinable within one
//! arg, accumulating across args. 1-indexed; 0 and reversed ranges rejected.
//! Grammar and validation semantics come from prior_art/bash_cols (the spec
//! of record): `^[0-9]+(-[0-9]*)?(,[0-9]+(-[0-9]*)?)*$` per arg.

const std = @import("std");

/// Sentinel for an open range (`m-`): "through end of line". Doubles as the
/// saturation value for absurdly large column numbers (clamping to NF makes
/// both harmless).
pub const OPEN_END: u64 = std.math.maxInt(u64);

pub const Atom = struct {
	lo: u64,
	hi: u64,
};

pub const ErrKind = enum {
	invalid, // doesn't match the grammar (incl. empty comma pieces)
	zero_column, // 0 used as a column (columns are 1-indexed)
	reversed, // m-n with m > n
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

fn allDigits(s: []const u8) bool {
	if (s.len == 0) return false;
	for (s) |ch| {
		if (ch < '0' or ch > '9') return false;
	}
	return true;
}

/// Decimal parse that saturates on overflow — a column number too large for
/// u64 is "beyond any NF" and clamping makes it harmless.
fn parseSat(s: []const u8) u64 {
	return std.fmt.parseInt(u64, s, 10) catch |e| switch (e) {
		error.Overflow => std.math.maxInt(u64),
		error.InvalidCharacter => unreachable, // callers pre-validate digits
	};
}

fn parseAtom(
	gpa: std.mem.Allocator,
	whole_arg: []const u8,
	atom_text: []const u8,
	atoms: *std.ArrayListUnmanaged(Atom),
) std.mem.Allocator.Error!ParseResult {
	const invalid: ParseResult = .{ .err = .{ .kind = .invalid, .text = whole_arg } };
	if (std.mem.indexOfScalar(u8, atom_text, '-')) |dash| {
		const lo_text = atom_text[0..dash];
		const hi_text = atom_text[dash + 1 ..];
		if (!allDigits(lo_text)) return invalid;
		if (hi_text.len != 0 and !allDigits(hi_text)) return invalid; // catches 2--3, 2-3-4
		const lo = parseSat(lo_text);
		if (lo == 0) return .{ .err = .{ .kind = .zero_column, .text = atom_text } };
		if (hi_text.len == 0) {
			try atoms.append(gpa, .{ .lo = lo, .hi = OPEN_END });
		} else {
			const hi = parseSat(hi_text);
			if (hi == 0) return .{ .err = .{ .kind = .zero_column, .text = atom_text } };
			if (lo > hi) return .{ .err = .{ .kind = .reversed, .text = atom_text } };
			try atoms.append(gpa, .{ .lo = lo, .hi = hi });
		}
	} else {
		if (!allDigits(atom_text)) return invalid;
		const n = parseSat(atom_text);
		if (n == 0) return .{ .err = .{ .kind = .zero_column, .text = atom_text } };
		try atoms.append(gpa, .{ .lo = n, .hi = n });
	}
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

test "open range m-" {
	try expectAtoms(&.{"2-"}, &.{.{ .lo = 2, .hi = OPEN_END }});
}

test "equal range m-m" {
	try expectAtoms(&.{"4-4"}, &.{.{ .lo = 4, .hi = 4 }});
}

test "comma-joined atoms in one arg" {
	try expectAtoms(&.{"2,4-6,9-"}, &.{
		.{ .lo = 2, .hi = 2 },
		.{ .lo = 4, .hi = 6 },
		.{ .lo = 9, .hi = OPEN_END },
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
	try expectAtoms(&.{"2-99999999999999999999999999"}, &.{.{ .lo = 2, .hi = OPEN_END }});
}

test "non-numeric and structurally malformed specs are invalid" {
	try expectErr("foo", .invalid);
	try expectErr("2x", .invalid);
	try expectErr("x2", .invalid);
	try expectErr("", .invalid);
	try expectErr("-", .invalid);
	try expectErr("-3", .invalid);
	try expectErr("2--3", .invalid);
	try expectErr("2-3-4", .invalid);
	try expectErr("2.5", .invalid);
	try expectErr(" 2", .invalid);
}

test "malformed comma structure is invalid (empties can't sneak past)" {
	try expectErr("2,", .invalid);
	try expectErr(",2", .invalid);
	try expectErr("2,,3", .invalid);
	try expectErr(",", .invalid);
}

test "column 0 rejected in every position" {
	try expectErr("0", .zero_column);
	try expectErr("0-2", .zero_column);
	try expectErr("2-0", .zero_column);
	try expectErr("0-", .zero_column);
	try expectErr("1,0", .zero_column);
}

test "reversed ranges rejected" {
	try expectErr("3-2", .reversed);
	try expectErr("1,5-4", .reversed);
	try expectErr("99999999999999999999999999-2", .reversed);
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
