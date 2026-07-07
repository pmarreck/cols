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
	chars = 5, // every code point is a field (-c and -F ''); Unicode-aware
};

pub const Config = struct {
	sep_mode: SepMode,
	sep: []const u8 = "",
	out_sep: ?[]const u8 = null, // null => derived per mode rules
	json: bool = false,
	/// Glyph for missing promised positions. null => default "∅" (U+2205).
	/// Explicit "" suppresses the slot entirely (old pre-null behavior).
	null_value: ?[]const u8 = null,
	/// Restore pre-null clamping semantics: closed ranges shrink, nothing
	/// renders as missing. Mutually exclusive with strict (CLI enforces).
	clamp: bool = false,
	/// Missing promised data is a validation failure (ValidationFailed with
	/// a diagnostic in strict_msg) instead of rendering nulls.
	strict: bool = false,
	/// cut -s: skip lines that produced fewer than 2 fields entirely.
	only_delimited: bool = false,
};

pub const ProcessError = error{ OutOfMemory, ValidationFailed, RegexMatchFailed };

/// Default null glyph: U+2205 EMPTY SET.
pub const default_null = "∅";

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
	null_value: []const u8, // owned; "" = suppress missing slots
	clamp: bool,
	strict: bool,
	only_delimited: bool,
	/// 1-based input line counter (all lines, incl. -s-skipped) for strict diags.
	line_no: u64,
	/// Diagnostic for the last ValidationFailed/RegexMatchFailed, rendered
	/// into strict_msg_buf (sized so the capped column list never truncates
	/// mid-number: prefix + 8×20-digit terms + "+N more" tail fits).
	strict_msg: []const u8,
	strict_msg_buf: [320]u8,
	/// Upper bound on null-glyph slots any single line can emit (sum of
	/// promised extents; capped by the create-time extent guard).
	promised_slots: usize,
	/// Precomputed worst-case null-glyph output bytes per line, overflow-
	/// checked at create (stream path reserves this without checking).
	null_extra: usize,
	fields: split.Fields,
	out: std.ArrayListUnmanaged(u8),

	pub const Mode = union(enum) {
		default_ws,
		literal: []const u8,
		ifs: split.IfsSet,
		regex: pcre2.Regex,
		none,
		chars,
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
		if (cfg.clamp and cfg.strict) {
			// the CLI rejects this too; enforcing here covers FFI consumers,
			// for whom strict would otherwise be silently inert under clamp
			return errResult(errbuf, "clamp and strict are mutually exclusive (clamp shrinks missing selections; strict errors on them)", .{});
		}

		var atoms: std.ArrayListUnmanaged(spec.Atom) = .empty;
		// toOwnedSlice empties the list on success, so this single defer covers
		// every path — Zig-error, normal-return .err, and success — with no
		// manual per-path deinit calls to forget.
		defer atoms.deinit(gpa);
		for (spec_args) |arg| {
			switch (try spec.parseSpecArg(gpa, arg, &atoms)) {
				.ok => {},
				.err => |e| {
					return switch (e.kind) {
						.invalid => errResult(errbuf, "invalid column spec '{s}' (want n, m-n, or m-, comma-combinable)", .{e.text}),
						.zero_column => errResult(errbuf, "columns are 1-indexed; 0 is not a column (in '{s}')", .{e.text}),
						.reversed => errResult(errbuf, "reversed range '{s}' (start exceeds end)", .{e.text}),
					};
				},
			}
		}

		// Without clamping, a closed range's full extent is rendered (nulls
		// for missing positions) — an absurd or saturated extent would emit
		// astronomically many glyphs, so reject it while the fix is obvious.
		if (!cfg.clamp) {
			const max_extent: i64 = 1 << 24;
			for (atoms.items) |a| {
				const hi = a.hi orelse continue;
				if ((a.lo > 0) != (hi > 0)) continue; // mixed-sign: elastic
				if (hi - a.lo + 1 > max_extent) {
					return errResult(errbuf, "closed range promises {d} positions (max {d}); use an open range (m-) for 'to end of line', or --clamp", .{ hi - a.lo + 1, max_extent });
				}
			}
		}

		if (cfg.null_value) |nv| {
			if (!std.unicode.utf8ValidateSlice(nv)) {
				return errResult(errbuf, "null value must be valid UTF-8", .{});
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
			.chars => .chars,
			.literal => .{ .literal = try gpa.dupe(u8, cfg.sep) },
			.ifs => .{ .ifs = try split.IfsSet.init(gpa, cfg.sep) },
			.regex => blk: {
				switch (try pcre2.Regex.compile(cfg.sep)) {
					.ok => |re| break :blk .{ .regex = re },
					.err => |cf| {
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
			.chars => "", // selected characters concatenate (cut -c convention)
			.literal => |l| l,
			.ifs => |*s| s.joinStr(),
		};
		const join = try gpa.dupe(u8, join_src);
		errdefer gpa.free(join);

		const owned_atoms = try atoms.toOwnedSlice(gpa);
		errdefer gpa.free(owned_atoms);

		var max_fields: usize = 0;
		for (owned_atoms) |a| {
			// any from-end anchor (negative lo/hi or an open range) needs
			// the full field count — no cap
			const hi = a.hi orelse {
				max_fields = split.NO_CAP;
				break;
			};
			if (a.lo < 0 or hi < 0) {
				max_fields = split.NO_CAP;
				break;
			}
			max_fields = @max(max_fields, std.math.cast(usize, hi) orelse split.NO_CAP);
		}
		// -s asks "did any separator match?" — the splitters must be allowed
		// to witness a second field even when the spec only wants column 1,
		// or every delimited line would look undelimited under the cap.
		if (cfg.only_delimited and max_fields < 2) max_fields = 2;

		const null_value = try gpa.dupe(u8, cfg.null_value orelse default_null);
		errdefer gpa.free(null_value);

		var promised_slots: usize = 0;
		if (!cfg.clamp) {
			for (owned_atoms) |a| {
				// per-atom extents are guard-bounded; saturate the sum anyway
				if (isPromised(a)) promised_slots +|= @as(usize, @intCast(a.hi.? - a.lo + 1));
			}
		}

		var stream_literal = mode == .literal and mode.literal.len == 1 and
			!cfg.json and !cfg.strict and atomsAscending(owned_atoms);
		// The stream path's per-line capacity reservation must be computable
		// without overflow, or its unchecked appends could corrupt the heap
		// (only constructible via the FFI with absurd configs). The general
		// path can merely OOM, so it is the safe fallback.
		const null_extra = std.math.mul(usize, promised_slots, null_value.len +| join.len) catch blk: {
			stream_literal = false;
			break :blk 0;
		};

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
			.null_value = null_value,
			.clamp = cfg.clamp,
			.strict = cfg.strict,
			.only_delimited = cfg.only_delimited,
			.line_no = 0,
			.strict_msg = "",
			.strict_msg_buf = undefined,
			.promised_slots = promised_slots,
			.null_extra = null_extra,
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

	/// Same-sign closed range: the user named a fixed number of positions.
	fn isPromised(a: spec.Atom) bool {
		const hi = a.hi orelse return false;
		return (a.lo > 0) == (hi > 0);
	}

	/// Resolve a PROMISED atom's full static extent against this line's NF —
	/// no clamping; positions outside [1, nf] are the missing ones. The
	/// single definition keeps checkStrict and both emitters bit-identical
	/// on what "missing" means.
	fn resolvePromised(a: spec.Atom, nf_i: i64) struct { lo: i64, hi: i64 } {
		return .{
			.lo = if (a.lo > 0) a.lo else nf_i + 1 + a.lo,
			.hi = if (a.hi.? > 0) a.hi.? else nf_i + 1 + a.hi.?,
		};
	}

	pub fn destroy(self: *Processor) void {
		const gpa = self.gpa;
		gpa.free(self.atoms);
		deinitMode(gpa, &self.mode);
		gpa.free(self.join);
		gpa.free(self.null_value);
		self.fields.deinit(gpa);
		self.out.deinit(gpa);
		gpa.destroy(self);
	}

	/// Process a chunk of COMPLETE lines (the final line may lack its
	/// trailing newline — callers flush per input EOF). Returns the output
	/// bytes for this chunk; the slice is valid until the next call.
	/// complexity: O(n) in chunk bytes
	pub fn processChunk(self: *Processor, data: []const u8) ProcessError![]const u8 {
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

	/// Mark the start of a new input (file boundary): line numbers in
	/// diagnostics restart at 1, grep/awk-FNR style.
	pub fn newInput(self: *Processor) void {
		self.line_no = 0;
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

	/// True when atoms are strictly ascending, non-overlapping, and free of
	/// from-end anchors (except a final open range), so one forward walk over
	/// the fields emits every selection in output order.
	fn atomsAscending(atoms: []const spec.Atom) bool {
		var prev_hi: i64 = 0;
		for (atoms) |a| {
			if (a.lo <= 0) return false; // from-end lo: not streamable
			if (a.lo <= prev_hi) return false;
			if (a.hi) |h| {
				if (h < 0) return false; // from-end hi: not streamable
				prev_hi = h;
			} else {
				prev_hi = std.math.maxInt(i64); // open range: nothing may follow
			}
		}
		return true;
	}

	/// Resolve an atom against this line's field count: negative anchors
	/// become positions from the end, then both ends clamp into [1, nf].
	/// Returns lo > hi (as {1,0}) when the selection is empty.
	fn resolveRange(a: spec.Atom, nf: usize) struct { lo: usize, hi: usize } {
		const nf_i: i64 = @intCast(nf);
		var lo: i64 = if (a.lo > 0) a.lo else nf_i + 1 + a.lo;
		var hi: i64 = if (a.hi) |h| (if (h > 0) h else nf_i + 1 + h) else nf_i;
		if (lo < 1) lo = 1;
		if (hi > nf_i) hi = nf_i;
		if (hi < 1 or lo > hi) return .{ .lo = 1, .hi = 0 };
		return .{ .lo = @intCast(lo), .hi = @intCast(hi) };
	}

	/// Stream-emit for the single-byte-literal + ascending-atoms case: scan
	/// delimiters with memchr, copy selected fields straight to the output,
	/// and stop scanning the instant the last requested field is emitted.
	/// Semantics must be indistinguishable from the general path.
	/// complexity: O(n)
	fn emitLineLiteralStream(self: *Processor, line: []const u8) Allocator.Error!void {
		const gpa = self.gpa;
		// bound: every emitted field byte comes from `line` exactly once, at
		// most one join per field, plus every promised slot as a null glyph
		// (extents are create-time-bounded), plus the newline
		// null_extra was overflow-checked at create; the line-size terms are
		// bounded by allocated memory, so saturating adds suffice here
		try self.out.ensureUnusedCapacity(
			gpa,
			line.len +| (line.len + 1) *| self.join.len +| self.null_extra +| 1,
		);
		const sep_ch = self.mode.literal[0];
		var field_start: usize = 0;
		var field_idx: i64 = 1;
		var atom_i: usize = 0;
		var first = true;
		var line_ended = false;
		while (true) {
			// retire atoms fully below the current field; done when none remain
			// (atomsAscending guarantees lo > 0 and hi > 0 or hi == null here)
			while (atom_i < self.atoms.len and self.atoms[atom_i].hi != null and self.atoms[atom_i].hi.? < field_idx) atom_i += 1;
			if (atom_i == self.atoms.len) break;
			const next_sep = std.mem.indexOfScalarPos(u8, line, field_start, sep_ch);
			// -s: an undelimited line (no separator anywhere) emits nothing
			if (field_idx == 1 and next_sep == null and self.only_delimited) return;
			const field_end = next_sep orelse line.len;
			if (self.atoms[atom_i].lo <= field_idx) {
				if (!first) self.out.appendSliceAssumeCapacity(self.join);
				self.out.appendSliceAssumeCapacity(line[field_start..field_end]);
				first = false;
			}
			if (next_sep == null) {
				line_ended = true;
				break;
			}
			field_start = field_end + 1;
			field_idx += 1;
		}
		// Positions the line couldn't supply: render nulls for the remaining
		// promised (closed) extents. Open ranges are elastic — nothing.
		if (line_ended and !self.clamp and self.null_value.len > 0) {
			while (atom_i < self.atoms.len) : (atom_i += 1) {
				const hi = self.atoms[atom_i].hi orelse break; // open: elastic (and last)
				var pos: i64 = @max(self.atoms[atom_i].lo, field_idx + 1);
				while (pos <= hi) : (pos += 1) {
					if (!first) self.out.appendSliceAssumeCapacity(self.join);
					self.out.appendSliceAssumeCapacity(self.null_value);
					first = false;
				}
			}
		}
		self.out.appendAssumeCapacity('\n');
	}

	/// Nulls apply outside clamp mode and outside chars mode (chars aren't
	/// fields; -c keeps the original clamping semantics).
	fn nullsApply(self: *const Processor) bool {
		return !self.clamp and self.mode != .chars;
	}

	/// Strict pre-pass: walk every promised atom against this line's NF and
	/// collect the missing positions (in the user's own terms — negative
	/// indices stay negative) into strict_msg. Nothing is emitted.
	fn checkStrict(self: *Processor, nf: usize) ProcessError!void {
		const max_listed = 8; // then summarize — a truncated list must never cut a number mid-digits
		const nf_i: i64 = @intCast(nf);
		var w: std.Io.Writer = .fixed(&self.strict_msg_buf);
		var missing: usize = 0;
		for (self.atoms) |a| {
			if (!isPromised(a)) continue;
			const r = resolvePromised(a, nf_i);
			var pos = r.lo;
			while (pos <= r.hi) : (pos += 1) {
				if (pos >= 1 and pos <= nf_i) continue;
				const user_term: i64 = if (a.lo > 0) pos else pos - (nf_i + 1);
				if (missing == 0) {
					w.print("line {d}: missing column(s) {d}", .{ self.line_no, user_term }) catch {};
				} else if (missing < max_listed) {
					w.print(", {d}", .{user_term}) catch {};
				}
				missing += 1;
			}
		}
		if (missing > 0) {
			if (missing > max_listed) {
				w.print(" (+{d} more)", .{missing - max_listed}) catch {};
			}
			self.strict_msg = w.buffered();
			return error.ValidationFailed;
		}
	}

	fn emitLine(self: *Processor, line: []const u8) ProcessError!void {
		self.line_no += 1;
		if (self.stream_literal and line.len > 0) {
			return self.emitLineLiteralStream(line);
		}
		self.fields.clearRetainingCapacity();
		if (line.len > 0) {
			switch (self.mode) {
				.default_ws => try split.splitDefaultWs(line, self.gpa, &self.fields, self.max_fields),
				.literal => |sep| try split.splitLiteral(line, sep, self.gpa, &self.fields, self.max_fields),
				.ifs => |*set| try split.splitIfs(line, set, self.gpa, &self.fields, self.max_fields),
				.regex => |*re| split.splitRegex(line, re, self.gpa, &self.fields, self.max_fields) catch |e| switch (e) {
					error.OutOfMemory => return error.OutOfMemory,
					// e.g. catastrophic backtracking blowing PCRE2's match
					// limit: wrong-columns-with-exit-0 is not an option
					error.MatchFailed => {
						var mbuf: [128]u8 = undefined;
						var w: std.Io.Writer = .fixed(&self.strict_msg_buf);
						w.print("line {d}: regex match failed: {s}", .{ self.line_no, re.lastErrorMessage(&mbuf) }) catch {};
						self.strict_msg = w.buffered();
						return error.RegexMatchFailed;
					},
				},
				.none => try split.splitWholeLine(line, self.gpa, &self.fields),
				.chars => try split.splitChars(line, self.gpa, &self.fields, self.max_fields),
			}
		}
		const nf = self.fields.items.len;
		const nulls = self.nullsApply();
		// -s runs first: an undelimited line is "not data", never a violation
		if (self.only_delimited and self.mode != .chars and nf < 2) return;
		if (self.strict and nulls) try self.checkStrict(nf);
		const nf_i: i64 = @intCast(nf);
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
				if (nulls and isPromised(a)) {
					const r = resolvePromised(a, nf_i);
					var pos = r.lo;
					while (pos <= r.hi) : (pos += 1) {
						if (!first) try self.out.append(self.gpa, ',');
						first = false;
						if (pos >= 1 and pos <= nf_i) {
							try self.appendJsonString(self.fields.items[@intCast(pos - 1)]);
						} else {
							// the real JSON null — the glyph never appears here
							try self.out.appendSlice(self.gpa, "null");
						}
					}
				} else {
					const r = resolveRange(a, nf);
					var f = r.lo;
					while (f <= r.hi) : (f += 1) {
						if (!first) try self.out.append(self.gpa, ',');
						first = false;
						try self.appendJsonString(self.fields.items[f - 1]);
					}
				}
			}
			try self.out.append(self.gpa, ']');
		} else {
			var first = true;
			for (self.atoms) |a| {
				// An empty glyph means missing slots render as nothing at all —
				// output-identical to the clamped path, which does no work for
				// them (a full-extent spin with '' burned hours on wide ranges).
				if (nulls and self.null_value.len > 0 and isPromised(a)) {
					const r = resolvePromised(a, nf_i);
					var pos = r.lo;
					while (pos <= r.hi) : (pos += 1) {
						const exists = pos >= 1 and pos <= nf_i;
						if (!first) try self.out.appendSlice(self.gpa, self.join);
						first = false;
						if (exists) {
							try self.out.appendSlice(self.gpa, self.fields.items[@intCast(pos - 1)]);
						} else {
							try self.out.appendSlice(self.gpa, self.null_value);
						}
					}
				} else {
					const r = resolveRange(a, nf);
					var f = r.lo;
					while (f <= r.hi) : (f += 1) {
						if (!first) try self.out.appendSlice(self.gpa, self.join);
						first = false;
						try self.out.appendSlice(self.gpa, self.fields.items[f - 1]);
					}
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

test "promised positions render the null glyph when missing (spec change: no clamping)" {
	try expectOutput(&.{"2-5"}, .{ .sep_mode = .default_ws }, "a b\n", "b ∅ ∅ ∅\n");
	try expectOutput(&.{"5"}, .{ .sep_mode = .default_ws }, "a b\n", "∅\n");
	try expectOutput(&.{"2"}, .{ .sep_mode = .default_ws }, "a b c\nd\n", "b\n∅\n");
	try expectOutput(&.{"2-4"}, .{ .sep_mode = .default_ws }, "1 2 3\n", "2 3 ∅\n"); // kickoff example
}

test "elastic specs (open and mixed-sign ranges) never render nulls" {
	const cfg: Config = .{ .sep_mode = .default_ws };
	try expectOutput(&.{"2-"}, cfg, "a\n", "\n"); // open: nothing promised
	try expectOutput(&.{"-2-"}, cfg, "a\n", "a\n"); // negative open clamps lo
	try expectOutput(&.{"2--1"}, cfg, "a\n", "\n"); // mixed-sign: elastic
	try expectOutput(&.{"-3--1"}, cfg, "a b\n", "∅ a b\n"); // but same-sign negative PROMISES 3
	try expectOutput(&.{"-3-"}, cfg, "a b\n", "a b\n"); // ...while the open cousin does not
}

test "clamp mode restores the old behavior byte-for-byte" {
	const cfg: Config = .{ .sep_mode = .default_ws, .clamp = true };
	try expectOutput(&.{"2-5"}, cfg, "a b\n", "b\n");
	try expectOutput(&.{"5"}, cfg, "a b\n", "\n");
	try expectOutput(&.{"2"}, cfg, "a b c\nd\n", "b\n\n");
	try expectOutput(&.{"-3--1"}, cfg, "a b\n", "a b\n");
	try expectOutput(&.{"1"}, cfg, "a\n\nb\n", "a\n\nb\n");
	// --null-value under clamp is accepted but inert
	try expectOutput(&.{"5"}, .{ .sep_mode = .default_ws, .clamp = true, .null_value = "X" }, "a b\n", "\n");
}

test "multiple atoms join with a single space by default" {
	try expectOutput(&.{ "1", "3-4" }, .{ .sep_mode = .default_ws }, "a b c d e\n", "a c d\n");
}

test "atoms select in the given order, including descending and repeated" {
	// also exercises the max_fields cap with out-of-order atoms (cap = 3)
	try expectOutput(&.{ "3", "1" }, .{ .sep_mode = .default_ws }, "a b c\n", "c a\n");
	try expectOutput(&.{"2,2"}, .{ .sep_mode = .literal, .sep = ":" }, "a:b:c\n", "b:b\n");
}

test "negative indices resolve from the last field, per line" {
	const cfg: Config = .{ .sep_mode = .default_ws };
	try expectOutput(&.{"-1"}, cfg, "a b c\nd e\n", "c\ne\n"); // NF differs per line
	try expectOutput(&.{"-2"}, cfg, "a b c\n", "b\n");
	try expectOutput(&.{"-2--1"}, cfg, "a b c\n", "b c\n");
	try expectOutput(&.{"2--2"}, cfg, "a b c d e\n", "b c d\n"); // mixed-sign range
	try expectOutput(&.{"-2-"}, cfg, "a b c\n", "b c\n"); // negative open range
	try expectOutput(&.{"1,-1"}, cfg, "a b c\n", "a c\n");
	try expectOutput(&.{ "-1", "1" }, cfg, "a b c\n", "c a\n"); // order preserved
}

test "negative promised positions render nulls too" {
	const cfg: Config = .{ .sep_mode = .default_ws };
	try expectOutput(&.{"-5"}, cfg, "a b\n", "∅\n"); // beyond start → visible null
	try expectOutput(&.{"-3--1"}, cfg, "a b\n", "∅ a b\n"); // promises 3 positions
	try expectOutput(&.{"2--1"}, cfg, "a\n", "\n"); // mixed-sign: elastic, nothing
	try expectOutput(&.{"-1"}, cfg, "\n", "∅\n"); // blank line: promised → null
}

test "negative indices work in every separator mode" {
	try expectOutput(&.{"-1"}, .{ .sep_mode = .literal, .sep = ":" }, "a:b:c\n", "c\n");
	try expectOutput(&.{"1,-1"}, .{ .sep_mode = .literal, .sep = ":" }, "a:b:c\n", "a:c\n");
	try expectOutput(&.{"-1"}, .{ .sep_mode = .ifs, .sep = ": " }, "a : b\n", "b\n");
	try expectOutput(&.{"-2"}, .{ .sep_mode = .regex, .sep = ":+" }, "a::b:c\n", "b\n");
	try expectOutput(&.{"-1"}, .{ .sep_mode = .none }, "a b\n", "a b\n");
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
	try expectOutput(&.{"2-5"}, cfg, "a:b:c\n", "b:c:∅:∅\n"); // promised tail → nulls, joined
	try expectOutput(&.{"7"}, cfg, "a:b\n", "∅\n"); // missing → visible null
	try expectOutput(&.{"2-"}, cfg, "a:b:c\n", "b:c\n"); // open range: elastic
	try expectOutput(&.{"1"}, cfg, "abc\n", "abc\n"); // no separator: whole line is field 1
	try expectOutput(&.{"2"}, cfg, "abc\n", "∅\n"); // kickoff example: undelimited line
	try expectOutput(&.{"2"}, cfg, ":a\n", "a\n"); // leading empty field
	try expectOutput(&.{"1"}, cfg, "a:b\n\nc:d\n", "a\n∅\nc\n"); // blank line → null
	try expectOutput(&.{ "1", "3-4" }, cfg, "a:b:c:d:e\n", "a:c:d\n"); // multiple ascending atoms
	try expectOutput(&.{"2"}, cfg, "a:b\r\n", "b\n"); // CRLF still stripped
	try expectOutput(&.{"1,5"}, cfg, "a:b\n", "a:∅\n"); // kickoff-adjacent: join with the literal
}

test "ifs mode joins with the first IFS code point" {
	try expectOutput(&.{"1,2"}, .{ .sep_mode = .ifs, .sep = ": " }, "a : b\n", "a:b\n");
}

test "regex mode joins with a single space" {
	try expectOutput(&.{"1-3"}, .{ .sep_mode = .regex, .sep = ":+" }, "a::b:c\n", "a b c\n");
}

test "none mode: whole line is field 1" {
	try expectOutput(&.{"1"}, .{ .sep_mode = .none }, "a b c\n", "a b c\n");
	try expectOutput(&.{"2"}, .{ .sep_mode = .none }, "a b c\n", "∅\n"); // promised, missing
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

test "blank lines render nulls for promised specs (correspondence kept, visible)" {
	try expectOutput(&.{"1"}, .{ .sep_mode = .default_ws }, "a\n\nb\n", "a\n∅\nb\n");
	try expectOutput(&.{"1-"}, .{ .sep_mode = .default_ws }, "a\n\nb\n", "a\n\nb\n"); // elastic: stays blank
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

test "json: missing promised positions are real JSON nulls" {
	const got = try runProc(&.{"5"}, .{ .sep_mode = .default_ws, .json = true }, &.{"a b\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[null]\n]\n", got);
}

test "json: null-value glyph does not affect JSON; clamp shortens arrays" {
	const got = try runProc(&.{"1,5"}, .{ .sep_mode = .default_ws, .json = true, .null_value = "X" }, &.{"a b\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[\"a\",null]\n]\n", got);
	const clamped = try runProc(&.{"1,5"}, .{ .sep_mode = .default_ws, .json = true, .clamp = true }, &.{"a b\n"});
	defer testing.allocator.free(clamped);
	try testing.expectEqualStrings("[[\"a\"]\n]\n", clamped);
}

test "null-value override, including empty = suppress the slot entirely" {
	try expectOutput(&.{"5"}, .{ .sep_mode = .default_ws, .null_value = "␀" }, "a b\n", "␀\n");
	try expectOutput(&.{"1,5"}, .{ .sep_mode = .default_ws, .null_value = "" }, "a b\n", "a\n"); // no dangling join
	try expectOutput(&.{"5"}, .{ .sep_mode = .default_ws, .null_value = "" }, "a b\n", "\n"); // old invisible behavior
	try expectOutput(&.{"1,5"}, .{ .sep_mode = .literal, .sep = ":", .null_value = "NULL" }, "a:b\n", "a:NULL\n");
}

test "null-value must be valid UTF-8" {
	try expectCreateErr(&.{"1"}, .{ .sep_mode = .default_ws, .null_value = "\xff" }, "UTF-8");
}

test "absurd promised extents are rejected at create (they no longer clamp)" {
	try expectCreateErr(&.{"2-99999999999999999999999999"}, .{ .sep_mode = .default_ws }, "open range");
	// ...but clamp mode keeps the old tolerance for them
	try expectOutput(&.{"2-99999999999999999999999999"}, .{ .sep_mode = .default_ws, .clamp = true }, "a b c\n", "b c\n");
}

test "only_delimited skips lines with fewer than two fields entirely" {
	const cfg: Config = .{ .sep_mode = .default_ws, .only_delimited = true };
	try expectOutput(&.{"2"}, cfg, "a b\nnope\nc d\n", "b\nd\n"); // sanctioned correspondence break
	try expectOutput(&.{"1"}, cfg, "\n\n", ""); // blank lines skipped
	try expectOutput(&.{"1"}, .{ .sep_mode = .literal, .sep = ":", .only_delimited = true }, "abc\n", "");
}

test "only_delimited must not be fooled by the max_fields cap (spec maxing at column 1)" {
	// regression: with spec `1`, the splitter early-exit capped nf at 1, making
	// every DELIMITED line look undelimited to -s in the general path
	try expectOutput(&.{"1"}, .{ .sep_mode = .default_ws, .only_delimited = true }, "a b\nnope\nc d\n", "a\nc\n");
	try expectOutput(&.{"1"}, .{ .sep_mode = .literal, .sep = "::", .only_delimited = true }, "a::b\nnope\n", "a\n");
	try expectOutput(&.{"1,1"}, .{ .sep_mode = .literal, .sep = ":", .only_delimited = true }, "a:b\n", "a:a\n"); // non-ascending → general path
	try expectOutput(&.{"1"}, .{ .sep_mode = .ifs, .sep = ":", .only_delimited = true }, "a:b\nnope\n", "a\n");
	try expectOutput(&.{"1"}, .{ .sep_mode = .regex, .sep = ":", .only_delimited = true }, "a:b\nnope\n", "a\n");
	const json = try runProc(&.{"1"}, .{ .sep_mode = .literal, .sep = ":", .only_delimited = true, .json = true }, &.{"a:b\nnope\n"});
	defer testing.allocator.free(json);
	try testing.expectEqualStrings("[[\"a\"]\n]\n", json);
}

test "clamp and strict are mutually exclusive at the core (FFI callers too)" {
	try expectCreateErr(&.{"1"}, .{ .sep_mode = .default_ws, .clamp = true, .strict = true }, "mutually exclusive");
}

test "strict diagnostic truncates cleanly: at most 8 columns listed, then a count — never a phantom number" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"50-100"}, .{ .sep_mode = .default_ws, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	try testing.expectError(error.ValidationFailed, p.processChunk("a\n"));
	// 51 missing columns (50..100): 8 listed, remainder summarized
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "50, 51, 52, 53, 54, 55, 56, 57") != null);
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "+43 more") != null);
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "58") == null); // nothing beyond the cap
}

test "differential: stream and general paths agree byte-for-byte on an edge corpus" {
	// The two emitters are separate implementations of one contract; this
	// mechanically pins them to each other (the -s regression hid exactly here).
	const lines = [_][]const u8{
		"", "a", "a:", ":a", "::", "a:b:c", "abc", "a:b\r", "x:y:z:w:v:u:t:s",
		"a::b", ":", "aa:bb", "a:b:c:d:e:f:g:h:i:j",
	};
	const spec_sets = [_][]const []const u8{
		&.{"1"}, &.{"2"}, &.{"1,3"}, &.{"2-5"}, &.{"3-"}, &.{"1,5"}, &.{"1-2,4"},
	};
	const nulls = [_]?[]const u8{ null, "", "XX" };
	const seps = [_]?[]const u8{ null, "|" };
	var input: std.ArrayListUnmanaged(u8) = .empty;
	defer input.deinit(testing.allocator);
	for (lines) |l| {
		try input.appendSlice(testing.allocator, l);
		try input.append(testing.allocator, '\n');
	}
	for (spec_sets) |specs| {
		for (nulls) |nv| {
			for (seps) |os| {
				for ([_]bool{ false, true }) |od| {
					for ([_]bool{ false, true }) |cl| {
						const cfg: Config = .{
							.sep_mode = .literal,
							.sep = ":",
							.null_value = nv,
							.out_sep = os,
							.only_delimited = od,
							.clamp = cl,
						};
						var errbuf: [256]u8 = undefined;
						const r1 = try Processor.create(testing.allocator, specs, cfg, &errbuf);
						const p1 = r1.ok;
						defer p1.destroy();
						const r2 = try Processor.create(testing.allocator, specs, cfg, &errbuf);
						const p2 = r2.ok;
						defer p2.destroy();
						try testing.expect(p1.stream_literal); // configs chosen to be stream-eligible
						p2.stream_literal = false; // force the general engine
						const out1 = try testing.allocator.dupe(u8, try p1.processChunk(input.items));
						defer testing.allocator.free(out1);
						const out2 = try p2.processChunk(input.items);
						try testing.expectEqualStrings(out1, out2);
					}
				}
			}
		}
	}
}

test "strict: missing promised data fails with line number and columns, exit-3 territory" {
	// first line clean and emitted; second line violates → partial output + message
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"2"}, .{ .sep_mode = .default_ws, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	try testing.expectError(error.ValidationFailed, p.processChunk("a b\nc\n"));
	try testing.expectEqualStrings("b\n", p.out.items); // clean prior line kept
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "line 2") != null);
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "2") != null);
}

test "strict: names all missing columns of the offending line" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"2-4"}, .{ .sep_mode = .default_ws, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	try testing.expectError(error.ValidationFailed, p.processChunk("a b\n"));
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "3") != null);
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "4") != null);
}

test "strict: negative promised positions report in the user's own terms" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"-3--1"}, .{ .sep_mode = .default_ws, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	try testing.expectError(error.ValidationFailed, p.processChunk("a b\n"));
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "-3") != null);
}

test "strict passes clean input; only_delimited skips are not violations" {
	const got = try runProc(&.{"2"}, .{ .sep_mode = .default_ws, .strict = true }, &.{"a b\nc d\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("b\nd\n", got);
	const skipped = try runProc(&.{"2"}, .{ .sep_mode = .default_ws, .strict = true, .only_delimited = true }, &.{"a b\nnope\n"});
	defer testing.allocator.free(skipped);
	try testing.expectEqualStrings("b\n", skipped);
}

test "strict + json applies identically" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"5"}, .{ .sep_mode = .default_ws, .json = true, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	try testing.expectError(error.ValidationFailed, p.processChunk("a b\n"));
}

test "regex match-time failure surfaces with a line-numbered diagnostic" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"2"}, .{ .sep_mode = .regex, .sep = "(a+)+b" }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	// line 1 splits benignly on "aab" → fields "z", " y"; line 2 explodes
	const input = "zaab y\n" ++ ("a" ** 40) ++ "c aab tail\n";
	try testing.expectError(error.RegexMatchFailed, p.processChunk(input));
	try testing.expectEqualStrings(" y\n", p.out.items); // clean first line kept
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "line 2") != null);
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "match") != null);
}

test "newInput restarts diagnostic line numbering (file boundaries)" {
	var errbuf: [256]u8 = undefined;
	const r = try Processor.create(testing.allocator, &.{"2"}, .{ .sep_mode = .default_ws, .strict = true }, &errbuf);
	const p = r.ok;
	defer p.destroy();
	_ = try p.processChunk("a b\nc d\n"); // "file 1": two clean lines
	p.newInput();
	try testing.expectError(error.ValidationFailed, p.processChunk("e\n"));
	try testing.expect(std.mem.indexOf(u8, p.strict_msg, "line 1") != null); // NOT line 3
}

test "chars mode is exempt from nulls, strict, and only_delimited" {
	try expectOutput(&.{"5"}, .{ .sep_mode = .chars }, "ab\n", "\n"); // still clamps to empty
	const got = try runProc(&.{"1"}, .{ .sep_mode = .chars, .strict = true, .only_delimited = true }, &.{"a\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("a\n", got);
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
	// a multibyte sequence TRUNCATED at end of field: one replacement per byte
	const trunc = try runProc(&.{"1"}, .{ .sep_mode = .none, .json = true }, &.{"a\xe4\xb8\n"});
	defer testing.allocator.free(trunc);
	try testing.expectEqualStrings("[[\"a\u{FFFD}\u{FFFD}\"]\n]\n", trunc);
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

test "chars mode: code-point selection, concatenated by default" {
	const cfg: Config = .{ .sep_mode = .chars };
	try expectOutput(&.{"2-4"}, cfg, "héllo\n", "éll\n"); // THE anti-cut demo: not bytes
	try expectOutput(&.{"1,3"}, cfg, "abc\n", "ac\n");
	try expectOutput(&.{"1"}, cfg, "中文\n", "中\n");
	try expectOutput(&.{"5"}, cfg, "ab\n", "\n"); // clamp + line correspondence
	try expectOutput(&.{"2-"}, cfg, "héllo\n", "éllo\n");
}

test "chars mode: negative indices count characters from the end" {
	const cfg: Config = .{ .sep_mode = .chars };
	try expectOutput(&.{"-3-"}, cfg, "hello\n", "llo\n");
	try expectOutput(&.{"-1"}, cfg, "a🍕\n", "🍕\n");
}

test "chars mode: -O joins between selected characters" {
	try expectOutput(&.{"1,3"}, .{ .sep_mode = .chars, .out_sep = "|" }, "abc\n", "a|c\n");
}

test "chars mode: json rows are arrays of single characters" {
	const got = try runProc(&.{"1-2"}, .{ .sep_mode = .chars, .json = true }, &.{"hé\n"});
	defer testing.allocator.free(got);
	try testing.expectEqualStrings("[[\"h\",\"é\"]\n]\n", got);
}
