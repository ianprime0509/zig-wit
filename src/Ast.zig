const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Parser = @import("Parser.zig");
const StringPool = @import("StringPool.zig");
const Tokenizer = @import("Tokenizer.zig");

source: []const u8,

tokens: Token.List.Slice,
nodes: Node.List.Slice,
extra_data: []u32,
string_pool: StringPool,

errors: []Error,

const Ast = @This();

pub const Token = struct {
    tag: Tag,
    span: Span,

    pub const Index = enum(u32) { none = 0, _ };
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
        });
    };

    pub const Span = struct {
        start: u32,
        len: u32,
    };
};

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) { none = 0, _ };
    pub const ExtraIndex = enum(u32) { _ };
    pub const List = std.MultiArrayList(Node);

    pub const Tag = enum {
        /// `data` is `root`.
        root,
        /// `data` is `package_decl`.
        package_decl,
    };

    pub const Data = union {
        root: Root,
        package_decl: PackageDecl,

        pub const Root = struct {
            /// The start of contained decls.
            start: ExtraIndex,
            /// The number of contained decls.
            len: u32,
        };

        pub const PackageDecl = struct {
            /// The `package` token.
            package: Token.Index,
            /// The package ID.
            /// Type is `PackageId`.
            id: ExtraIndex,
        };
    };

    pub const PackageId = struct {
        namespace: StringPool.Index,
        name: StringPool.Index,
        version: ?StringPool.Index,
    };
};

pub const Error = struct {
    tag: Tag,
    token: Token.Index,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
    } = .{ .none = {} },

    pub const Tag = enum {
        expected_top_level_item,
        invalid_version,

        /// `expected_tag` is populated.
        expected_token,
    };
};

pub fn deinit(ast: *Ast, allocator: Allocator) void {
    ast.tokens.deinit(allocator);
    ast.nodes.deinit(allocator);
    allocator.free(ast.extra_data);
    ast.string_pool.deinit(allocator);
    allocator.free(ast.errors);
    ast.* = undefined;
}

pub fn extraData(ast: Ast, comptime T: type) T {
    const fields = @typeInfo(T).Struct.fields;
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
            u32 => ast.extra_data[i],
            inline Token.Index, StringPool.Index, Node.Index => |Value| value: {
                const value: Value = @enumFromInt(ast.extra_data[i]);
                assert(value != .none);
                break :value value;
            },
            inline ?Token.Index, ?StringPool.Index, ?Node.Index => |OptionalValue| value: {
                const value: @typeInfo(OptionalValue).Optional.Child = @enumFromInt(ast.extra_data[i]);
                break :value if (value != .none) value else null;
            },
            else => @compileError("bad field type"),
        };
    }
    return result;
}

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Ast {
    var tokens: Token.List = .{};
    errdefer tokens.deinit(allocator);
    try tokens.append(allocator, undefined);
    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }

    var parser = try Parser.init(allocator, source, tokens);
    errdefer parser.nodes.deinit(allocator);
    errdefer parser.extra_data.deinit(allocator);
    errdefer parser.string_pool.deinit(allocator);
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
        .string_pool = parser.string_pool,
        .errors = try parser.errors.toOwnedSlice(allocator),
    };
}
