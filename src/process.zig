//! The Processor ties spec parsing, splitting, selection, and joining into a
//! chunk-oriented pure engine: feed it byte chunks containing whole lines,
//! get back output bytes. No I/O, no clock, no getenv — the resolved
//! configuration arrives as parameters (hexagonal DI). This is the unit the
//! C FFI wraps 1:1.

const std = @import("std");
const spec = @import("spec.zig");
const split = @import("split.zig");
const pcre2 = @import("pcre2.zig");

const Allocator = std.mem.Allocator;

/// Wire-level separator mode selected by the CLI after resolving flag/env
/// precedence. Mirrors cols_sep_mode in cols.h — keep in sync.
pub const SepMode = enum(u8) {
	default_ws = 0,
	literal = 1,
	ifs = 2,
	regex = 3,
	none = 4,
};

pub const Config = struct {
	sep_mode: SepMode,
	sep: []const u8 = "",
	out_sep: ?[]const u8 = null, // null => derived per mode rules
	json: bool = false,
};

pub const CreateResult = union(enum) {
	ok: *Processor,
	/// Human-readable message rendered into the caller's errbuf (usage error,
	/// exit code 2 territory).
	err: []const u8,
};

pub const Processor = struct {
	gpa: Allocator,
	atoms: []spec.Atom,
	mode: Mode,
	join: []const u8,
	json: bool,
	wrote_json_row: bool,
	/// Largest column any atom can select (NO_CAP when an open range exists);
	/// splitters stop early once this many fields are in hand.
	max_fields: usize,
	/// Fast path: single-byte literal separator + strictly ascending atoms +
	/// text output — fields are emitted during the delimiter scan, with no
	/// per-field materialization at all (this is how we race `cut`).
	stream_literal: bool,
	fields: split.Fields,
	out: std.ArrayListUnmanaged(u8),

	pub const Mode = union(enum) {
		default_ws,
		literal: []const u8,
		ifs: split.IfsSet,
		regex: pcre2.Regex,
		none,
	};

	/// Parse + validate specs, resolve the separator mode (an empty separator
	/// collapses to `none` — shell `IFS=` semantics), compile the regex if
	/// any, and derive the output join string. Validation problems come back
	/// as a rendered message in `errbuf`; only OOM is a Zig error.
	pub fn create(
		gpa: Allocator,
		spec_args: []const []const u8,
		cfg: Config,
		errbuf: []u8,
	) Allocator.Error!CreateResult {
		if (spec_args.len == 0) return errResult(errbuf, "no column spec given", .{});

		var atoms: std.ArrayListUnmanaged(spec.Atom) = .empty;
		errdefer atoms.deinit(gpa);
		for (spec_args) |arg| {
			switch (try spec.parseSpecArg(gpa, arg, &atoms)) {
				.ok => {},
				.err => |e| {
					atoms.deinit(gpa);
					return switch (e.kind) {
						.invalid => errResult(errbuf, "invalid column spec '{s}' (want n, m-n, or m-, comma-combinable)", .{e.text}),
						.zero_column => errResult(errbuf, "columns are 1-indexed; 0 is not a column", .{}),
						.reversed => errResult(errbuf, "reversed range '{s}' (start exceeds end)", .{e.text}),
					};
				},
			}
		}

		// An empty separator means "no splitting" in every mode — the shell
		// IFS= convention, applied uniformly.
		const effective_mode: SepMode = if (cfg.sep.len == 0) switch (cfg.sep_mode) {
			.literal, .ifs, .regex => .none,
			else => cfg.sep_mode,
		} else cfg.sep_mode;

		var mode: Mode = switch (effective_mode) {
			.default_ws => .default_ws,
			.none => .none,
			.literal => .{ .literal = try gpa.dupe(u8, cfg.sep) },
			.ifs => .{ .ifs = try split.IfsSet.init(gpa, cfg.sep) },
			.regex => blk: {
				switch (try pcre2.Regex.compile(cfg.sep)) {
					.ok => |re| break :blk .{ .regex = re },
					.err => |cf| {
						atoms.deinit(gpa);
						var msgbuf: [256]u8 = undefined;
						const pmsg = cf.message(&msgbuf);
						return errResult(errbuf, "invalid regex '{s}': {s} (at offset {d})", .{ cfg.sep, pmsg, cf.offset });
					},
				}
			},
		};
		errdefer deinitMode(gpa, &mode);

		const join_src: []const u8 = if (cfg.out_sep) |os| os else switch (mode) {
			.default_ws, .none, .regex => " ",
			.literal => |l| l,
			.ifs => |*s| s.joinStr(),
		};
		const join = try gpa.dupe(u8, join_src);
		errdefer gpa.free(join);

		const owned_atoms = try atoms.toOwnedSlice(gpa);
		errdefer gpa.free(owned_atoms);

		var max_fields: usize = 0;
		for (owned_atoms) |a| {
			if (a.hi == spec.OPEN_END) {
				max_fields = split.NO_CAP;
				break;
			}
			max_fields = @max(max_fields, @as(usize, @intCast(@min(a.hi, std.math.maxInt(usize)))));
		}

		const stream_literal = mode == .literal and mode.literal.len == 1 and
			!cfg.json and atomsAscending(owned_atoms);

		const p = try gpa.create(Processor);
		p.* = .{
			.gpa = gpa,
			.atoms = owned_atoms,
			.mode = mode,
			.join = join,
			.json = cfg.json,
			.wrote_json_row = false,
			.max_fields = max_fields,
			.stream_literal = stream_literal,
			.fields = .empty,
			.out = .empty,
		};
		return .{ .ok = p };
	}

	fn deinitMode(gpa: Allocator, mode: *Mode) void {
		switch (mode.*) {
			.literal => |l| gpa.free(l),
			.ifs => |*s| s.deinit(),
			.regex => |*r| r.deinit(),
			else => {},
		}
	}

	pub fn destroy(self: *Processor) void {
		const gpa = self.gpa;
		gpa.free(self.atoms);
		deinitMode(gpa, &self.mode);
		gpa.free(self.join);
		self.fields.deinit(gpa);
		self.out.deinit(gpa);
		gpa.destroy(self);
	}

	/// Process a chunk of COMPLETE lines (the final line may lack its
	/// trailing newline — callers flush per input EOF). Returns the output
	/// bytes for this chunk; the slice is valid until the next call.
	/// complexity: O(n) in chunk bytes
	pub fn processChunk(self: *Processor, data: []const u8) Allocator.Error![]const u8 {
		self.out.clearRetainingCapacity();
		var pos: usize = 0;
		while (pos < data.len) {
			const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n');
			const line_end = nl orelse data.len;
			var line = data[pos..line_end];
			// CRLF input: a trailing \r belongs to the line ending, not the data
			if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
			try self.emitLine(line);
			pos = if (nl) |n| n + 1 else data.len;
		}
		return self.out.items;
	}

	/// Emit any trailing output (the JSON close bracket). Text mode: empty.
	pub fn finish(self: *Processor) Allocator.Error![]const u8 {
		self.out.clearRetainingCapacity();
		if (self.json) {
			if (self.wrote_json_row) {
				try self.out.appendSlice(self.gpa, "\n]\n");
			} else {
				try self.out.appendSlice(self.gpa, "[]\n");
			}
		}
		return self.out.items;
	}

	/// True when atoms are strictly ascending and non-overlapping, so one
	/// forward walk over the fields emits every selection in output order.
	fn atomsAscending(atoms: []const spec.Atom) bool {
		var prev_hi: u64 = 0;
		for (atoms) |a| {
			if (a.lo <= prev_hi) return false;
			prev_hi = a.hi;
		}
		return true;
	}

	/// Stream-emit for the single-byte-literal + ascending-atoms case: scan
	/// delimiters with memchr, copy selected fields straight to the output,
	/// and stop scanning the instant the last requested field is emitted.
	/// Semantics must be indistinguishable from the general path.
	/// complexity: O(n)
	fn emitLineLiteralStream(self: *Processor, line: []const u8) Allocator.Error!void {
		const gpa = self.gpa;
		// bound: every emitted field byte comes from `line` exactly once,
		// plus at most one join per field plus the newline
		try self.out.ensureUnusedCapacity(gpa, line.len + (line.len + 1) * self.join.len + 1);
		if (line.len == 0) {
			self.out.appendAssumeCapacity('\n');
			return;
		}
		const sep_ch = self.mode.literal[0];
		var field_start: usize = 0;
		var field_idx: u64 = 1;
		var atom_i: usize = 0;
		var first = true;
		while (true) {
			// retire atoms fully below the current field; done when none remain
			while (atom_i < self.atoms.len and self.atoms[atom_i].hi < field_idx) atom_i += 1;
			if (atom_i == self.atoms.len) break;
			const next_sep = std.mem.indexOfScalarPos(u8, line, field_start, sep_ch);
			const field_end = next_sep orelse line.len;
			if (self.atoms[atom_i].lo <= field_idx) {
				if (!first) self.out.appendSliceAssumeCapacity(self.join);
				self.out.appendSliceAssumeCapacity(line[field_start..field_end]);
				first = false;
			}
			if (next_sep == null) break;
			field_start = field_end + 1;
			field_idx += 1;
		}
		self.out.appendAssumeCapacity('\n');
	}

	fn emitLine(self: *Processor, line: []const u8) Allocator.Error!void {
		if (self.stream_literal) {
			return self.emitLineLiteralStream(line);
		}
		self.fields.clearRetainingCapacity();
		if (line.len > 0) {
			switch (self.mode) {
				.default_ws => try split.splitDefaultWs(line, self.gpa, &self.fields, self.max_fields),
				.literal => |sep| try split.splitLiteral(line, sep, self.gpa, &self.fields, self.max_fields),
				.ifs => |*set| try split.splitIfs(line, set, self.gpa, &self.fields, self.max_fields),
				.regex => |*re| try split.splitRegex(line, re, self.gpa, &self.fields, self.max_fields),
				.none => try split.splitWholeLine(line, self.gpa, &self.fields),
			}
		}
		const nf: u64 = self.fields.items.len;
		if (self.json) {
			if (!self.wrote_json_row) {
				try self.out.append(self.gpa, '[');
				self.wrote_json_row = true;
			} else {
				try self.out.appendSlice(self.gpa, "\n,");
			}
			try self.out.append(self.gpa, '[');
			var first = true;
			for (self.atoms) |a| {
				const hi = @min(a.hi, nf);
				var f = a.lo;
				while (f <= hi) : (f += 1) {
					if (!first) try self.out.append(self.gpa, ',');
					first = false;
					try self.appendJsonString(self.fields.items[@intCast(f - 1)]);
				}
			}
			try self.out.append(self.gpa, ']');
		} else {
			var first = true;
			for (self.atoms) |a| {
				const hi = @min(a.hi, nf);
				var f = a.lo;
				while (f <= hi) : (f += 1) {
					if (!first) try self.out.appendSlice(self.gpa, self.join);
					first = false;
					try self.out.appendSlice(self.gpa, self.fields.items[@intCast(f - 1)]);
				}
			}
			try self.out.append(self.gpa, '\n');
		}
	}

	/// JSON string with full escaping; invalid UTF-8 bytes become U+FFFD so
	/// --json output is always valid UTF-8 JSON.
	fn appendJsonString(self: *Processor, s: []const u8) Allocator.Error!void {
		const gpa = self.gpa;
		const replacement = "\xEF\xBF\xBD"; // U+FFFD
		try self.out.append(gpa, '"');
		var i: usize = 0;
		while (i < s.len) {
			const b = s[i];
			if (b == '"') {
				try self.out.appendSlice(gpa, "\\\"");
				i += 1;
			} else if (b == '\\') {
				try self.out.appendSlice(gpa, "\\\\");
				i += 1;
			} else if (b == '\n') {
				try self.out.appendSlice(gpa, "\\n");
				i += 1;
			} else if (b == '\r') {
				try self.out.appendSlice(gpa, "\\r");
				i += 1;
			} else if (b == '\t') {
				try self.out.appendSlice(gpa, "\\t");
				i += 1;
			} else if (b < 0x20) {
				var buf: [8]u8 = undefined;
				const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b}) catch unreachable;
				try self.out.appendSlice(gpa, esc);
				i += 1;
			} else if (b < 0x80) {
				try self.out.append(gpa, b);
				i += 1;
			} else {
				const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
					try self.out.appendSlice(gpa, replacement);
					i += 1;
					continue;
				};
				if (i + seq_len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + seq_len])) {
					try self.out.appendSlice(gpa, replacement);
					i += 1;
					continue;
				}
				try self.out.appendSlice(gpa, s[i .. i + seq_len]);
				i += seq_len;
			}
		}
		try self.out.append(gpa, '"');
	}
};

fn errResult(errbuf: []u8, comptime fmt: []const u8, args: anytype) CreateResult {
	var w: std.Io.Writer = .fixed(errbuf);
	w.print(fmt, args) catch {}; // truncation is acceptable for messages
	return .{ .err = w.buffered() };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Run inputs through a fresh Processor as separate chunks; return all output
/// (chunks + finish) concatenated. Caller frees.
fn runProc(
	specs: []const []const u8,
	cfg: Config,
	chunks: []const []const u8,
) ![]u8 {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, specs, cfg, &errbuf);
	if (r == .err) {
		std.debug.print("create failed: {s}\n", .{r.err});
		return error.CreateFailed;
	}
	const p = r.ok;
	defer p.destroy();
	var acc: std.ArrayListUnmanaged(u8) = .empty;
	errdefer acc.deinit(testing.allocator);
	for (chunks) |chunk| {
		try acc.appendSlice(testing.allocator, try p.processChunk(chunk));
	}
	try acc.appendSlice(testing.allocator, try p.finish());
	return acc.toOwnedSlice(testing.allocator);
}

fn expectOutput(specs: []const []const u8, cfg: Config, input: []const u8, want: []const u8) !void {
	const got = try runProc(specs, cfg, &.{input});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings(want, got);
}

fn expectCreateErr(specs: []const []const u8, cfg: Config, want_substring: []const u8) !void {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, specs, cfg, &errbuf);
	if (r == .ok) {
		r.ok.destroy();
		return error.TestExpectedError;
	}
	try testing.expect(std.mem.indexOf(u8, r.err, want_substring) != null);
}

test "basic single column over multiple lines" {
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "a b c\nd e f\n", "b\ne\n");
}

test "ranges clamp; out-of-range yields empty line (correspondence)" {
	try expectOutput(&.{"2-5"}, .{ .sep_mode = .default_ws }, "a b\n", "b\n");
	try expectOutput(&.{"5"}, .{ .sep_mode = .default_ws }, "a b\n", "\n");
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "a b c\nd\n", "b\n\n");
}

test "multiple atoms join with a single space by default" {
	try expectOutput(&.{ "1", "3-4" }, .{ .sep_mode = .default_ws }, "a b c d e\n", "a c d\n");
}

test "atoms select in the given order, including descending and repeated" {
	// also exercises the max_fields cap with out-of-order atoms (cap = 3)
	try expectOutput(&.{ "3", "1" }, .{ .sep_mode = .default_ws }, "a b c\n", "c a\n");
	try expectOutput(&.{"2,2"}, .{ .sep_mode = .literal, .sep = ":" }, "a:b:c\n", "b:b\n");
}

test "open range to end of line" {
	try expectOutput(&.{"2-"}, .{ .sep_mode = .default_ws }, "a b c d\n", "b c d\n");
}

test "literal separator mode joins with the separator" {
	try expectOutput(
		&.{"1,7"},
		.{ .sep_mode = .literal, .sep = ":" },
		"root:x:0:0:Sys Admin:/root:/bin/sh\n",
		"root:/bin/sh\n",
	);
}

test "literal stream fast path: edge cases match the general contract" {
	// ascending atoms + single-byte literal separator take the stream-emit
	// path; these pin its semantics to the same external contract
	const cfg: Config = .{ .sep_mode = .literal, .sep = ":" };
	try expectOutput(&.{"1,2"}, cfg, "a:\n", "a:\n"); // trailing empty field selectable
	try expectOutput(&.{"2-5"}, cfg, "a:b:c\n", "b:c\n"); // clamp
	try expectOutput(&.{"7"}, cfg, "a:b\n", "\n"); // missing → empty line
	try expectOutput(&.{"2-"}, cfg, "a:b:c\n", "b:c\n"); // open range
	try expectOutput(&.{"1"}, cfg, "abc\n", "abc\n"); // no separator at all
	try expectOutput(&.{"2"}, cfg, ":a\n", "a\n"); // leading empty field
	try expectOutput(&.{"1"}, cfg, "a:b\n\nc:d\n", "a\n\nc\n"); // blank line correspondence
	try expectOutput(&.{ "1", "3-4" }, cfg, "a:b:c:d:e\n", "a:c:d\n"); // multiple ascending atoms
	try expectOutput(&.{"2"}, cfg, "a:b\r\n", "b\n"); // CRLF still stripped
}

test "ifs mode joins with the first IFS code point" {
	try expectOutput(&.{"1,2"}, .{ .sep_mode = .ifs, .sep = ": " }, "a : b\n", "a:b\n");
}

test "regex mode joins with a single space" {
	try expectOutput(&.{"1-3"}, .{ .sep_mode = .regex, .sep = ":+" }, "a::b:c\n", "a b c\n");
}

test "none mode: whole line is field 1" {
	try expectOutput(&.{"1"}, .{ .sep_mode = .none }, "a b c\n", "a b c\n");
	try expectOutput(&.{"2"}, .{ .sep_mode = .none }, "a b c\n", "\n");
}

test "out_sep overrides every derived join" {
	try expectOutput(&.{"1,3"}, .{ .sep_mode = .default_ws, .out_sep = "|" }, "a b c\n", "a|c\n");
	try expectOutput(&.{"1,7"}, .{ .sep_mode = .literal, .sep = ":", .out_sep = " " }, "a:b:c:d:e:f:g\n", "a g\n");
	try expectOutput(&.{"1-3"}, .{ .sep_mode = .default_ws, .out_sep = "" }, "a b c\n", "abc\n");
}

test "empty separator collapses to none (shell IFS= semantics)" {
	try expectOutput(&.{"1"}, .{ .sep_mode = .ifs, .sep = "" }, "a b c\n", "a b c\n");
	try expectOutput(&.{"1"}, .{ .sep_mode = .literal, .sep = "" }, "a b c\n", "a b c\n");
}

test "final line without trailing newline is still a line (output gains one)" {
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "a b", "b\n");
}

test "CRLF: trailing \\r stripped before splitting" {
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "a b\r\nc d\r\n", "b\nd\n");
	try expectOutput(&.{"2-"}, .{ .sep_mode = .default_ws }, "a b\r\n", "b\n");
}

test "blank lines yield blank output lines" {
	try expectOutput(&.{"1"}, .{ .sep_mode = .default_ws }, "a\n\nb\n", "a\n\nb\n");
}

test "chunked processing accumulates across calls" {
	const got = try runProc(&.{"2"}, .{ .sep_mode = .default_ws }, &.{ "a b\n", "c d\n" });
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("b\nd\n", got);
}

test "empty input produces no output in text mode" {
	const got = try runProc(&.{"1"}, .{ .sep_mode = .default_ws }, &.{});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("", got);
}

test "json: exact streaming shape, one row per line" {
	const got = try runProc(&.{"1-2"}, .{ .sep_mode = .default_ws, .json = true }, &.{"a b\nc d\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[\"a\",\"b\"]\n,[\"c\",\"d\"]\n]\n", got);
}

test "json: empty input is an empty array" {
	const got = try runProc(&.{"1"}, .{ .sep_mode = .default_ws, .json = true }, &.{});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[]\n", got);
}

test "json: out-of-range row is an empty inner array" {
	const got = try runProc(&.{"5"}, .{ .sep_mode = .default_ws, .json = true }, &.{"a b\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[]\n]\n", got);
}

test "json: escapes quotes, backslashes, and control characters" {
	const got = try runProc(&.{"1"}, .{ .sep_mode = .literal, .sep = "\t", .json = true }, &.{"he\"llo\\wo\x01rld\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[\"he\\\"llo\\\\wo\\u0001rld\"]\n]\n", got);
}

test "json: invalid UTF-8 bytes become U+FFFD (output stays valid UTF-8)" {
	const got = try runProc(&.{"1"}, .{ .sep_mode = .none, .json = true }, &.{"a\xffb\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[\"a\u{FFFD}b\"]\n]\n", got);
}

test "create: spec validation messages" {
	try expectCreateErr(&.{"foo"}, .{ .sep_mode = .default_ws }, "invalid column spec 'foo'");
	try expectCreateErr(&.{"0"}, .{ .sep_mode = .default_ws }, "1-indexed");
	try expectCreateErr(&.{"3-2"}, .{ .sep_mode = .default_ws }, "reversed range '3-2'");
	try expectCreateErr(&.{"2,,3"}, .{ .sep_mode = .default_ws }, "invalid column spec '2,,3'");
}

test "create: no specs at all is an error" {
	try expectCreateErr(&.{}, .{ .sep_mode = .default_ws }, "no column spec");
}

test "create: bad regex reports PCRE2's message" {
	try expectCreateErr(&.{"1"}, .{ .sep_mode = .regex, .sep = "(" }, "regex");
}

test "UTF-8 fields pass through untouched" {
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "🍕 中文 tail\n", "中文\n");
}
