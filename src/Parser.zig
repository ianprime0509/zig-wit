const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Ast = @import("Ast.zig");
const Token = Ast.Token;
const Node = Ast.Node;
const StringPool = @import("StringPool.zig");

source: []const u8,
token_tags: []const Token.Tag,
token_spans: []const Token.Span,
token_index: Token.Index,
nodes: Node.List,
extra_data: std.ArrayListUnmanaged(u32),
string_pool: StringPool,
scratch: std.ArrayListUnmanaged(Node.Index),
errors: std.ArrayListUnmanaged(Ast.Error),
allocator: Allocator,

const Parser = @This();

pub fn init(allocator: Allocator, source: []const u8, tokens: Token.List) Allocator.Error!Parser {
    var string_pool = try StringPool.init(allocator);
    errdefer string_pool.deinit(allocator);
    return .{
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_spans = tokens.items(.span),
        .token_index = @enumFromInt(1),
        .nodes = .{},
        .extra_data = .{},
        .string_pool = string_pool,
        .scratch = .{},
        .errors = .{},
        .allocator = allocator,
    };
}

pub fn parseRoot(p: *Parser) error{ OutOfMemory, ParseError }!void {
    assert(p.nodes.len == 0);
    try p.nodes.append(p.allocator, .{ .tag = .root, .data = undefined });

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        switch (p.peek()) {
            .eof => break,
            .package => try p.scratch.append(p.allocator, try p.parsePackageDecl()),
            else => return p.fail(.expected_top_level_item), // TODO
        }
    }

    const root_start, const root_len = try p.encodeScratch(scratch_top);
    p.nodes.items(.data)[0] = .{ .root = .{
        .start = root_start,
        .len = root_len,
    } };
}

fn parsePackageDecl(p: *Parser) !Node.Index {
    const package = try p.expect(.package);
    const namespace = try p.intern(p.tokenSource(try p.expect(.identifier)));
    _ = try p.expect(.@":");
    const name = try p.intern(p.tokenSource(try p.expect(.identifier)));
    const version = switch (p.peek()) {
        .@"@" => version: {
            p.advance();
            break :version try p.parseVersion();
        },
        else => null,
    };
    _ = try p.expect(.@";");

    const package_id = try p.encode(Node.PackageId{
        .namespace = namespace,
        .name = name,
        .version = version,
    });
    return p.appendNode(.{
        .tag = .package_decl,
        .data = .{ .package_decl = .{
            .package = package,
            .id = package_id,
        } },
    });
}

fn parseVersion(p: *Parser) !StringPool.Index {
    var version = std.ArrayList(u8).init(p.allocator);
    defer version.deinit();

    // TODO: better error reporting for invalid versions
    try version.appendSlice(p.tokenSource(try p.expect(.integer)));
    _ = try p.expect(.@".");
    try version.append('.');
    try version.appendSlice(p.tokenSource(try p.expect(.integer)));
    _ = try p.expect(.@".");
    try version.append('.');
    try version.appendSlice(p.tokenSource(try p.expect(.integer)));

    var seen_prerelease = false;
    var seen_build = false;
    while (true) {
        switch (p.peek()) {
            .@"-" => {
                if (seen_prerelease or seen_build) return p.fail(.invalid_version);
                try version.append('-');
                p.advance();
                seen_prerelease = true;
            },
            .@"+" => {
                if (seen_build) return p.fail(.invalid_version);
                try version.append('+');
                p.advance();
                seen_prerelease = true;
                seen_build = true;
            },
            else => break,
        }
        switch (p.peek()) {
            .identifier, .integer => try version.appendSlice(p.tokenSource(p.token_index)),
            else => return p.fail(.invalid_version),
        }
        while (p.peek() != .@".") {
            switch (p.peek()) {
                .identifier, .integer => try version.appendSlice(p.tokenSource(p.token_index)),
                else => return p.fail(.invalid_version),
            }
        }
    }

    return try p.intern(version.items);
}

fn peek(p: *Parser) Token.Tag {
    return p.token_tags[@intFromEnum(p.token_index)];
}

fn expect(p: *Parser, expected_tag: Token.Tag) !Token.Index {
    if (p.peek() != expected_tag) {
        return p.failMsg(.{
            .tag = .expected_token,
            .token = p.token_index,
            .extra = .{ .expected_tag = expected_tag },
        });
    }
    const index = p.token_index;
    p.advance();
    return index;
}

fn tokenSource(p: Parser, token_index: Token.Index) []const u8 {
    const span = p.token_spans[@intFromEnum(token_index)];
    return p.source[span.start..][0..span.len];
}

fn advance(p: *Parser) void {
    p.token_index = @enumFromInt(@intFromEnum(p.token_index) + 1);
}

fn appendNode(p: *Parser, node: Node) !Node.Index {
    const index: Node.Index = @enumFromInt(@as(u32, @intCast(p.nodes.len)));
    try p.nodes.append(p.allocator, node);
    return index;
}

fn encode(p: *Parser, value: anytype) !Node.ExtraIndex {
    const index: Node.ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
    const fields = @typeInfo(@TypeOf(value)).Struct.fields;
    try p.extra_data.ensureUnusedCapacity(p.allocator, fields.len);
    inline for (fields) |field| {
        p.extra_data.appendAssumeCapacity(switch (field.type) {
            u32 => @field(value, field.name),
            inline Token.Index, StringPool.Index, Node.Index => @intFromEnum(@field(value, field.name)),
            inline ?Token.Index, ?StringPool.Index, ?Node.Index => if (@field(value, field.name)) |field_value|
                @intFromEnum(field_value)
            else
                0,
            else => @compileError("bad field type"),
        });
    }
    return index;
}

fn encodeScratch(p: *Parser, start: usize) !struct { Node.ExtraIndex, u32 } {
    const index: Node.ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
    const scratch_items = p.scratch.items[start..];
    try p.extra_data.appendSlice(p.allocator, @ptrCast(p.scratch.items[start..]));
    return .{ index, @intCast(scratch_items.len) };
}

fn intern(p: *Parser, s: []const u8) !StringPool.Index {
    return p.string_pool.intern(p.allocator, s);
}

fn warn(p: *Parser, error_tag: Ast.Error.Tag) !void {
    @setCold(true);
    try p.warnMsg(.{ .tag = error_tag, .token = p.token_index });
}

fn warnMsg(p: *Parser, @"error": Ast.Error) !void {
    @setCold(true);
    try p.errors.append(p.allocator, @"error");
}

fn fail(p: *Parser, error_tag: Ast.Error.Tag) error{ OutOfMemory, ParseError } {
    @setCold(true);
    return p.failMsg(.{ .tag = error_tag, .token = p.token_index });
}

fn failMsg(p: *Parser, @"error": Ast.Error) error{ OutOfMemory, ParseError } {
    @setCold(true);
    try p.errors.append(p.allocator, @"error");
    return error.ParseError;
}
