const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Parser = @import("Parser.zig");
const Tokenizer = @import("Tokenizer.zig");

source: []const u8,

tokens: Token.List.Slice,
nodes: Node.List.Slice,
extra_data: []u32,

errors: []Error,

const Ast = @This();

pub const Token = struct {
    tag: Tag,
    span: Span,

    pub const Index = enum(u32) {
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(i: OptionalIndex) ?Index {
            return if (i == .none) null else @enumFromInt(@intFromEnum(i));
        }
    };

    pub const List = std.MultiArrayList(Token);

    pub const Tag = enum {
        invalid,
        eof,

        identifier,
        integer,

        use,
        type,
        resource,
        func,
        record,
        @"enum",
        flags,
        variant,
        static,
        interface,
        world,
        import,
        @"export",
        package,
        include,
        as,

        @"=",
        @",",
        @":",
        @";",
        @"(",
        @")",
        @"{",
        @"}",
        @"<",
        @">",
        @"*",
        @"->",
        @"/",
        @".",
        @"@",
        @"-",
        @"+",

        pub const keywords = std.ComptimeStringMap(Tag, .{
            .{ "use", .use },
            .{ "type", .type },
            .{ "resource", .resource },
            .{ "func", .func },
            .{ "record", .record },
            .{ "enum", .@"enum" },
            .{ "flags", .flags },
            .{ "variant", .variant },
            .{ "static", .static },
            .{ "interface", .interface },
            .{ "world", .world },
            .{ "import", .import },
            .{ "export", .@"export" },
            .{ "package", .package },
            .{ "include", .include },
            .{ "as", .as },
        });

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .eof,
                .identifier,
                .integer,
                => null,
                else => @tagName(tag),
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .invalid => "invalid bytes",
                .eof => "EOF",
                .identifier => "an identifier",
                .integer => "an integer",
                else => unreachable,
            };
        }
    };

    pub const Span = struct {
        start: u32,
        len: u32,
    };
};

pub const Node = struct {
    tag: Tag,
    main_token: Token.Index,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };
    pub const OptionalIndex = enum(u32) { none = 0, _ };

    pub const List = std.MultiArrayList(Node);

    pub const Tag = enum {
        /// `data` is `root`.
        root,
        /// `data` is `package_decl`.
        /// `main_token` is the `package` token.
        package_decl,
        /// `data` is `top_level_use`.
        /// `main_token` is the `use` token.
        top_level_use,
        /// `data` is `world`.
        /// `main_token` is the `world` token.
        world,
    };

    pub const Data = union {
        root: Root,
        package_decl: PackageDecl,
        top_level_use: TopLevelUse,
        world: World,

        pub const Root = struct {
            /// The start of contained decls.
            start: ExtraIndex,
            /// The number of contained decls.
            len: u32,
        };

        pub const PackageDecl = struct {
            /// The package ID.
            /// Type is `PackageId`.
            id: ExtraIndex,
        };

        pub const TopLevelUse = struct {
            /// The use path.
            /// Type is `UsePath`.
            path: ExtraIndex,
            /// The `as` alias identifier, if any.
            alias: Token.OptionalIndex,
        };

        pub const World = struct {
            /// The start of contained items.
            start: ExtraIndex,
            /// The number of contained items.
            len: u32,
        };
    };

    pub const PackageId = struct {
        namespace: Token.Index,
        name: Token.Index,
        version: Token.OptionalIndex,
        version_len: u32,
    };

    pub const UsePath = struct {
        namespace: Token.Index,
        package: Token.Index,
        name: Token.Index,
        version: Token.OptionalIndex,
        version_len: u32,
    };
};

pub const ExtraIndex = enum(u32) { _ };

pub fn deinit(ast: *Ast, allocator: Allocator) void {
    ast.tokens.deinit(allocator);
    ast.nodes.deinit(allocator);
    allocator.free(ast.extra_data);
    allocator.free(ast.errors);
    ast.* = undefined;
}

pub fn extraData(ast: Ast, comptime T: type, index: ExtraIndex) T {
    const fields = @typeInfo(T).Struct.fields;
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
            u32 => ast.extra_data[@intFromEnum(index) + i],
            inline Token.Index,
            Token.OptionalIndex,
            Node.Index,
            Node.OptionalIndex,
            => @enumFromInt(ast.extra_data[@intFromEnum(index) + i]),
            else => @compileError("bad field type"),
        };
    }
    return result;
}

fn extraDataNodes(ast: Ast, start: ExtraIndex, len: u32) []const Node.Index {
    return @ptrCast(ast.extra_data[@intFromEnum(start)..][0..len]);
}

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Ast {
    var tokens: Token.List = .{};
    errdefer tokens.deinit(allocator);
    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_spans = tokens.items(.span),
        .token_index = @enumFromInt(0),
        .nodes = .{},
        .extra_data = .{},
        .scratch = .{},
        .errors = .{},
        .allocator = allocator,
    };
    errdefer parser.nodes.deinit(allocator);
    errdefer parser.extra_data.deinit(allocator);
    defer parser.scratch.deinit(allocator);
    errdefer parser.errors.deinit(allocator);

    parser.parseRoot() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {},
    };

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
        .errors = try parser.errors.toOwnedSlice(allocator),
    };
}

pub fn tokenSlice(ast: Ast, index: Token.Index) []const u8 {
    const tag = ast.tokens.items(.tag)[@intFromEnum(index)];
    if (tag.lexeme()) |lexeme| return lexeme;
    const span = ast.tokens.items(.span)[@intFromEnum(index)];
    return ast.source[span.start..][0..span.len];
}

pub const Error = struct {
    tag: Tag,
    token: Token.Index,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
    } = .{ .none = {} },

    pub const Tag = enum {
        expected_top_level_item,
        expected_world_item,
        invalid_version, // TODO: refine this

        /// `expected_tag` is populated.
        expected_token,
    };
};

/// Renders an error (without any location information) to `writer`.
pub fn renderError(ast: Ast, @"error": Error, writer: anytype) @TypeOf(writer).Error!void {
    const token_tags = ast.tokens.items(.tag);
    return switch (@"error".tag) {
        .expected_top_level_item => writer.print("expected top-level item, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_world_item => writer.print("expected world item, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .invalid_version => writer.writeAll("invalid version"),
        .expected_token => writer.print("expected {s}, found {s}", .{
            token_tags[@intFromEnum(@"error".extra.expected_tag)].symbol(),
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
    };
}

pub const full = struct {
    pub const Root = struct {
        items: []const Node.Index,
    };

    pub const PackageDecl = struct {
        package_token: Token.Index,
        namespace: Token.Index,
        name: Token.Index,
        version: ?Token.Index,
        version_len: u32,
    };

    pub const TopLevelUse = struct {
        use_token: Token.Index,
        namespace: Token.Index,
        package: Token.Index,
        name: Token.Index,
        version: ?Token.Index,
        version_len: u32,
        alias: ?Token.Index,
    };

    pub const World = struct {
        world_token: Token.Index,
        name: Token.Index,
        items: []const Node.Index,
    };
};

pub fn fullRoot(ast: Ast) full.Root {
    const root = ast.nodes.items(.data)[0].root;
    return .{
        .items = ast.extraDataNodes(root.start, root.len),
    };
}

pub fn fullPackageDecl(ast: Ast, index: Node.Index) full.PackageDecl {
    assert(ast.nodes.items(.tag)[@intFromEnum(index)] == .package_decl);
    const data = ast.nodes.items(.data)[@intFromEnum(index)].package_decl;
    const id = ast.extraData(Node.PackageId, data.id);
    return .{
        .package_token = ast.nodes.items(.main_token)[@intFromEnum(index)],
        .namespace = id.namespace,
        .name = id.name,
        .version = id.version.unwrap(),
        .version_len = id.version_len,
    };
}

pub fn fullTopLevelUse(ast: Ast, index: Node.Index) full.TopLevelUse {
    assert(ast.nodes.items(.tag)[@intFromEnum(index)] == .top_level_use);
    const data = ast.nodes.items(.data)[@intFromEnum(index)].top_level_use;
    const path = ast.extraData(Node.UsePath, data.path);
    return .{
        .use_token = ast.nodes.items(.main_token)[@intFromEnum(index)],
        .namespace = path.namespace,
        .package = path.package,
        .name = path.name,
        .version = path.version.unwrap(),
        .version_len = path.version_len,
        .alias = data.alias.unwrap(),
    };
}

pub fn fullWorld(ast: Ast, index: Node.Index) full.World {
    assert(ast.nodes.items(.tag)[@intFromEnum(index)] == .world);
    const data = ast.nodes.items(.data)[@intFromEnum(index)].world;
    const world_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
    const name: Token.Index = @enumFromInt(@intFromEnum(world_token) + 1);
    assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
    return .{
        .world_token = world_token,
        .name = name,
        .items = ast.extraDataNodes(data.start, data.len),
    };
}

/// Dumps an AST to `writer`, for debugging.
pub fn dump(ast: Ast, writer: anytype) @TypeOf(writer).Error!void {
    if (ast.errors.len != 0) {
        for (ast.errors) |@"error"| {
            try ast.renderError(@"error", writer);
            try writer.writeByte('\n');
        }
        return;
    }
    const root = ast.fullRoot();
    for (root.items) |item| {
        try ast.dumpNode(item, 0, writer);
    }
}

fn dumpNode(ast: Ast, node: Node.Index, indent: u32, writer: anytype) !void {
    try writer.writeByteNTimes(' ', indent);
    const node_tags = ast.nodes.items(.tag);
    const node_datas = ast.nodes.items(.data);
    _ = node_datas;
    switch (node_tags[@intFromEnum(node)]) {
        .root => unreachable,
        .package_decl => {
            const package_decl = ast.fullPackageDecl(node);
            try writer.print("package {s}:{s}", .{
                ast.tokenSlice(package_decl.namespace),
                ast.tokenSlice(package_decl.name),
            });
            if (package_decl.version) |version| {
                try writer.writeByte('@');
                try ast.dumpTokens(version, package_decl.version_len, writer);
            }
            try writer.writeByte('\n');
        },
        .top_level_use => {
            const top_level_use = ast.fullTopLevelUse(node);
            try writer.print("use {s}:{s}/{s}", .{
                ast.tokenSlice(top_level_use.namespace),
                ast.tokenSlice(top_level_use.package),
                ast.tokenSlice(top_level_use.name),
            });
            if (top_level_use.version) |version| {
                try writer.writeByte('@');
                try ast.dumpTokens(version, top_level_use.version_len, writer);
            }
            if (top_level_use.alias) |alias| {
                try writer.print(" as {s}", .{ast.tokenSlice(alias)});
            }
            try writer.writeByte('\n');
        },
        .world => {
            const world = ast.fullWorld(node);
            try writer.print("world {s}\n", .{
                ast.tokenSlice(world.name),
            });
            for (world.items) |item| {
                try ast.dumpNode(item, indent + 2, writer);
            }
        },
    }
}

fn dumpTokens(ast: Ast, index: Token.Index, len: u32, writer: anytype) !void {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        try writer.writeAll(ast.tokenSlice(@enumFromInt(@intFromEnum(index) + i)));
    }
}
