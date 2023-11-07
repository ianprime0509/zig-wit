const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Ast = @import("Ast.zig");
const Token = Ast.Token;
const Node = Ast.Node;
const ExtraIndex = Ast.ExtraIndex;

source: []const u8,
token_tags: []const Token.Tag,
token_spans: []const Token.Span,
token_index: Token.Index,
nodes: Node.List,
extra_data: std.ArrayListUnmanaged(u32),
scratch: std.ArrayListUnmanaged(Node.Index),
errors: std.ArrayListUnmanaged(Ast.Error),
allocator: Allocator,

const Parser = @This();

pub fn parseRoot(p: *Parser) error{ OutOfMemory, ParseError }!void {
    assert(p.nodes.len == 0);
    try p.nodes.append(p.allocator, .{
        .tag = .root,
        .main_token = undefined,
        .data = undefined,
    });

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        switch (p.peek()) {
            .eof => break,
            .package => try p.scratch.append(p.allocator, try p.parsePackageDecl()),
            .use => try p.scratch.append(p.allocator, try p.parseTopLevelUse()),
            .world => try p.scratch.append(p.allocator, try p.parseWorld()),
            else => return p.fail(.expected_top_level_item), // TODO
        }
    }

    const start, const len = try p.encodeScratch(scratch_top);
    p.nodes.items(.data)[0] = .{ .root = .{
        .start = start,
        .len = len,
    } };
}

fn parsePackageDecl(p: *Parser) !Node.Index {
    const package = try p.expect(.package);
    const namespace = try p.expect(.identifier);
    _ = try p.expect(.@":");
    const name = try p.expect(.identifier);
    const version, const version_len = try p.parseOptionalVersionSuffix();
    _ = try p.expect(.@";");

    const package_id = try p.encode(Node.PackageId{
        .namespace = namespace,
        .name = name,
        .version = version,
        .version_len = version_len,
    });
    return p.appendNode(.{
        .tag = .package_decl,
        .main_token = package,
        .data = .{ .package_decl = .{
            .id = package_id,
        } },
    });
}

fn parseTopLevelUse(p: *Parser) !Node.Index {
    const use = try p.expect(.use);
    const namespace, const package, const name = parts: {
        const initial = try p.expect(.identifier);
        if (p.peek() != .@":") {
            break :parts .{ .none, .none, initial };
        }
        p.advance();
        const package = try p.expect(.identifier);
        _ = try p.expect(.@"/");
        const name = try p.expect(.identifier);
        break :parts .{ initial.toOptional(), package.toOptional(), name };
    };
    const version, const version_len = try p.parseOptionalVersionSuffix();
    const alias = switch (p.peek()) {
        .as => alias: {
            p.advance();
            break :alias (try p.expect(.identifier)).toOptional();
        },
        else => .none,
    };
    _ = try p.expect(.@";");

    const path = try p.encode(Node.UsePath{
        .namespace = namespace,
        .package = package,
        .name = name,
        .version = version,
        .version_len = version_len,
    });
    return p.appendNode(.{
        .tag = .top_level_use,
        .main_token = use,
        .data = .{ .top_level_use = .{
            .path = path,
            .alias = alias,
        } },
    });
}

fn parseWorld(p: *Parser) !Node.Index {
    const world = try p.expect(.world);
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        switch (p.peek()) {
            .@"}" => {
                p.advance();
                break;
            },
            else => return p.fail(.expected_world_item), // TODO
        }
    }

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .world,
        .main_token = world,
        .data = .{ .world = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseOptionalVersionSuffix(p: *Parser) !struct { Token.OptionalIndex, u32 } {
    if (p.peek() != .@"@") return .{ .none, 0 };
    p.advance();

    // TODO: better error reporting for invalid versions
    const first_token_index = @intFromEnum(p.token_index);
    const first_token = try p.expect(.integer);
    _ = try p.expect(.@".");
    _ = try p.expect(.integer);
    _ = try p.expect(.@".");
    _ = try p.expect(.integer);

    var seen_prerelease = false;
    var seen_build = false;
    while (true) {
        switch (p.peek()) {
            .@"-" => {
                if (seen_prerelease or seen_build) return p.fail(.invalid_version);
                p.advance();
                seen_prerelease = true;
            },
            .@"+" => {
                if (seen_build) return p.fail(.invalid_version);
                p.advance();
                seen_prerelease = true;
                seen_build = true;
            },
            else => break,
        }
        switch (p.peek()) {
            .identifier, .integer => {},
            else => return p.fail(.invalid_version),
        }
        while (p.peek() != .@".") {
            switch (p.peek()) {
                .identifier, .integer => {},
                else => return p.fail(.invalid_version),
            }
        }
    }

    return .{
        first_token.toOptional(),
        @intFromEnum(p.token_index) - first_token_index,
    };
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

fn tokenSlice(p: Parser, index: Token.Index) []const u8 {
    const tag = p.token_tags[@intFromEnum(index)];
    if (tag.lexeme()) |lexeme| return lexeme;
    const span = p.token_spans[@intFromEnum(index)];
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

fn encode(p: *Parser, value: anytype) !ExtraIndex {
    const index: ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
    const fields = @typeInfo(@TypeOf(value)).Struct.fields;
    try p.extra_data.ensureUnusedCapacity(p.allocator, fields.len);
    inline for (fields) |field| {
        p.extra_data.appendAssumeCapacity(switch (field.type) {
            u32 => @field(value, field.name),
            inline Token.Index,
            Token.OptionalIndex,
            Node.Index,
            Node.OptionalIndex,
            => @intFromEnum(@field(value, field.name)),
            else => @compileError("bad field type"),
        });
    }
    return index;
}

fn encodeScratch(p: *Parser, start: usize) !struct { ExtraIndex, u32 } {
    const index: ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
    const scratch_items = p.scratch.items[start..];
    try p.extra_data.appendSlice(p.allocator, @ptrCast(p.scratch.items[start..]));
    return .{ index, @intCast(scratch_items.len) };
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
