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
        constructor,
        with,

        @"_",
        u8,
        u16,
        u32,
        u64,
        s8,
        s16,
        s32,
        s64,
        float32,
        float64,
        char,
        bool,
        string,
        tuple,
        list,
        option,
        result,
        borrow,

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
            .{ "constructor", .constructor },
            .{ "with", .with },
            .{ "u8", .u8 },
            .{ "u16", .u16 },
            .{ "u32", .u32 },
            .{ "u64", .u64 },
            .{ "s8", .s8 },
            .{ "s16", .s16 },
            .{ "s32", .s32 },
            .{ "s64", .s64 },
            .{ "float32", .float32 },
            .{ "float64", .float64 },
            .{ "char", .char },
            .{ "bool", .bool },
            .{ "string", .string },
            .{ "tuple", .tuple },
            .{ "list", .list },
            .{ "option", .option },
            .{ "result", .result },
            .{ "borrow", .borrow },
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

    pub const OptionalIndex = enum(u32) {
        none = 0,
        _,

        pub fn unwrap(i: OptionalIndex) ?Index {
            return if (i == .none) null else @enumFromInt(@intFromEnum(i));
        }
    };

    pub const List = std.MultiArrayList(Node);

    pub const Tag = enum {
        /// `data` is `container`.
        /// `main_token` is undefined.
        root,
        /// `data` is `package_decl`.
        /// `main_token` is the `package` token.
        package_decl,
        /// `data` is `top_level_use`.
        /// `main_token` is the `use` token.
        top_level_use,
        /// `data` is `container`.
        /// `main_token` is the `world` token.
        world,
        /// `data` is `func`.
        /// `main_token` is the `export` token.
        export_func,
        /// `data` is `container`.
        /// `main_token` is the `export` token.
        export_interface,
        /// `data` is `path`.
        /// `main_token` is the `export` token.
        export_path,
        /// `data` is `func`.
        /// `main_token` is the `import` token.
        import_func,
        /// `data` is `container`.
        /// `main_token` is the `import` token.
        import_interface,
        /// `data` is `path`.
        /// `main_token` is the `import` token.
        import_path,
        /// `data` is `include`.
        /// `main_token` is the `include` token.
        include,
        /// `data` is `include_name`.
        /// `main_token` is the included name.
        include_name,
        /// `data` is `container`.
        /// `main_token` is the `interface` token.
        interface,
        /// `data` is `type_reference`.
        /// `main_token` is the `type` token.
        type_alias,
        /// `data` is `container`.
        /// `main_token` is the `record` token.
        record,
        /// `data` is `container`.
        /// `main_token` is the `flags` token.
        flags,
        /// `data` is `container`.
        /// `main_token` is the `variant` token.
        variant,
        /// `data` is `container`.
        /// `main_token` is the `enum` token.
        @"enum",
        /// `data` is `container`.
        /// `main_token` is the `resource` token.
        resource,
        /// `data` is `use`.
        /// `main_token` is the `use` token.
        use,
        /// `data` is `use_name`.
        /// `main_token` is the imported name.
        use_name,
        /// `data` is `func`.
        /// `main_token` is the function name.
        func,
        /// `data` is `func`.
        /// `main_token` is the function name.
        static_func,
        /// `data` is `constructor`.
        /// `main_token` is the `constructor` token.
        constructor,
        /// `data` is `type_reference`.
        /// `main_token` is the parameter name.
        param,
        /// An untyped field or case (member of a flags or enum, or an untyped variant case).
        /// `data` is `none`.
        /// `main_token` is the field or case name.
        untyped_field,
        /// A typed field or case (member of a record or variant).
        /// `data` is `type_reference`.
        /// `main_token` is the field or case name.
        typed_field,
        /// A simple type (built-in or user-defined referenced by name).
        /// `data` is `none`.
        /// `main_token` is the type name or keyword.
        type_simple,
        /// A tuple type.
        /// `data` is `container`.
        /// `main_token` is the `tuple` token.
        type_tuple,
        /// A list type.
        /// `data` is `unary_type`.
        /// `main_token` is the `list` token.
        type_list,
        /// A option type.
        /// `data` is `unary_type`.
        /// `main_token` is the `option` token.
        type_option,
        /// A result type.
        /// `data` is `result_type`.
        /// `main_token` is the `result` token.
        type_result,
        /// A borrowed type.
        /// `data` is `unary_type`.
        /// `main_token` is the `borrow` token.
        type_borrow,
    };

    pub const Data = union {
        none: void,
        container: Container,
        package_decl: PackageDecl,
        top_level_use: TopLevelUse,
        path: Path,
        include: Include,
        include_name: IncludeName,
        use: Use,
        use_name: UseName,
        func: Func,
        constructor: Constructor,
        type_reference: TypeReference,
        unary_type: UnaryType,
        result_type: ResultType,

        pub const Container = struct {
            /// The start of contained items.
            start: ExtraIndex,
            /// The number of contained items.
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

        pub const Path = struct {
            /// The path.
            /// Type is `UsePath`.
            path: ExtraIndex,
        };

        pub const Include = struct {
            /// The included path.
            /// Type is `UsePath`.
            path: ExtraIndex,
            /// The included names.
            /// Type is `IncludeNames`.
            names: ExtraIndex,
        };

        pub const IncludeName = struct {
            alias: Token.Index,
        };

        pub const Use = struct {
            /// The use path.
            /// Type is `UsePath`.
            path: ExtraIndex,
            /// The imported names.
            /// Type is `UseNames`.
            names: ExtraIndex,
        };

        pub const UseName = struct {
            alias: Token.OptionalIndex,
        };

        pub const Func = struct {
            /// The function type.
            /// Type is `FuncType`.
            type: ExtraIndex,
        };

        pub const Constructor = struct {
            /// The start of parameters.
            params_start: ExtraIndex,
            /// The number of parameters.
            params_len: u32,
        };

        pub const TypeReference = struct {
            /// The referenced type.
            type: Node.Index,
        };

        pub const UnaryType = struct {
            /// The child type.
            child_type: Node.Index,
        };

        pub const ResultType = struct {
            /// The `ok` child type.
            ok_type: Node.OptionalIndex,
            /// The `err` child type.
            err_type: Node.OptionalIndex,
        };
    };

    pub const PackageId = struct {
        namespace: Token.Index,
        name: Token.Index,
        version: Token.OptionalIndex,
        version_len: u32,
    };

    /// Note: `(namespace == .none) == (package == .none)`
    pub const UsePath = struct {
        namespace: Token.OptionalIndex,
        package: Token.OptionalIndex,
        name: Token.Index,
        version: Token.OptionalIndex,
        version_len: u32,
    };

    pub const IncludeNames = struct {
        start: ExtraIndex,
        len: u32,
    };

    pub const UseNames = struct {
        start: ExtraIndex,
        len: u32,
    };

    pub const FuncType = struct {
        params_start: ExtraIndex,
        params_len: u32,
        returns_start: ExtraIndex,
        returns_len: u32,
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
            Token.Index,
            Token.OptionalIndex,
            Node.Index,
            Node.OptionalIndex,
            ExtraIndex,
            => @enumFromInt(ast.extra_data[@intFromEnum(index) + i]),
            else => @compileError("bad field type"),
        };
    }
    return result;
}

pub fn extraDataNodes(ast: Ast, start: ExtraIndex, len: u32) []const Node.Index {
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
        expected_interface_item,
        expected_record_field,
        expected_flags_field,
        expected_variant_case,
        expected_enum_case,
        expected_resource_method,
        expected_type,
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
        .expected_interface_item => writer.print("expected interface item, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_record_field => writer.print("expected record field, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_flags_field => writer.print("expected flags field, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_variant_case => writer.print("expected variant case, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_enum_case => writer.print("expected enum case, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_resource_method => writer.print("expected resource method, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .expected_type => writer.print("expected type, found {s}", .{
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
        .invalid_version => writer.writeAll("invalid version"),
        .expected_token => writer.print("expected {s}, found {s}", .{
            @"error".extra.expected_tag.symbol(),
            token_tags[@intFromEnum(@"error".token)].symbol(),
        }),
    };
}

pub const Location = struct {
    line: usize,
    column: usize,
};

pub fn tokenLocation(ast: Ast, index: Token.Index) Location {
    const start = ast.tokens.items(.span)[@intFromEnum(index)].start;
    var line: usize = 1;
    var pos: usize = 0;
    while (pos < ast.source.len) {
        const line_end = mem.indexOfScalarPos(u8, ast.source, pos, '\n') orelse ast.source.len;
        if (start < line_end) {
            return .{ .line = line, .column = line_end - pos };
        }
        line += 1;
        pos = line_end + 1;
    }
    unreachable;
}

/// Dumps an AST to `writer`, for debugging.
pub fn dump(ast: Ast, writer: anytype) @TypeOf(writer).Error!void {
    if (ast.errors.len != 0) {
        for (ast.errors) |@"error"| {
            const location = ast.tokenLocation(@"error".token);
            try writer.print("{}:{}: ", .{ location.line, location.column });
            try ast.renderError(@"error", writer);
            try writer.writeByte('\n');
        }
        return;
    }

    assert(ast.nodes.items(.tag)[0] == .root);
    const root = ast.nodes.items(.data)[0].container;
    for (ast.extraDataNodes(root.start, root.len)) |item_index| {
        try ast.dumpNode(item_index, 0, writer);
    }
}

fn dumpNode(ast: Ast, index: Node.Index, indent: u32, writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByteNTimes(' ', indent);
    const node_tags = ast.nodes.items(.tag);
    const node_datas = ast.nodes.items(.data);
    switch (node_tags[@intFromEnum(index)]) {
        .root => unreachable,
        .package_decl => {
            const package_decl = node_datas[@intFromEnum(index)].package_decl;
            const id = ast.extraData(Node.PackageId, package_decl.id);
            try writer.print("package {s}:{s}", .{
                ast.tokenSlice(id.namespace),
                ast.tokenSlice(id.name),
            });
            if (id.version.unwrap()) |version| {
                try writer.writeByte('@');
                try ast.dumpTokens(version, id.version_len, writer);
            }
            try writer.writeByte('\n');
        },
        .top_level_use => {
            const top_level_use = node_datas[@intFromEnum(index)].top_level_use;
            const path = ast.extraData(Node.UsePath, top_level_use.path);
            try writer.writeAll("use ");
            try ast.dumpUsePath(path, writer);
            if (top_level_use.alias.unwrap()) |alias| {
                try writer.print(" as {s}", .{ast.tokenSlice(alias)});
            }
            try writer.writeByte('\n');
        },
        .world,
        .interface,
        .record,
        .flags,
        .variant,
        .@"enum",
        .resource,
        => |tag| {
            try writer.writeAll(@tagName(tag));
            try writer.writeByte(' ');
            const type_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(type_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeByte('\n');

            const container = ast.nodes.items(.data)[@intFromEnum(index)].container;
            for (ast.extraDataNodes(container.start, container.len)) |item_index| {
                try ast.dumpNode(item_index, indent + 2, writer);
            }
        },
        .export_func => {
            try writer.writeAll("export ");
            const export_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(export_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const func = ast.nodes.items(.data)[@intFromEnum(index)].func;
            try ast.dumpFuncType(ast.extraData(Node.FuncType, func.type), writer);
            try writer.writeByte('\n');
        },
        .export_interface => {
            try writer.writeAll("export ");
            const export_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(export_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": interface\n");

            const container = ast.nodes.items(.data)[@intFromEnum(index)].container;
            for (ast.extraDataNodes(container.start, container.len)) |item_index| {
                try ast.dumpNode(item_index, indent + 2, writer);
            }
        },
        .export_path => {
            try writer.writeAll("export ");
            const path = ast.nodes.items(.data)[@intFromEnum(index)].path;
            try ast.dumpUsePath(ast.extraData(Node.UsePath, path.path), writer);
            try writer.writeByte('\n');
        },
        .import_func => {
            try writer.writeAll("import ");
            const import_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(import_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const func = ast.nodes.items(.data)[@intFromEnum(index)].func;
            try ast.dumpFuncType(ast.extraData(Node.FuncType, func.type), writer);
            try writer.writeByte('\n');
        },
        .import_interface => {
            try writer.writeAll("import ");
            const import_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(import_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": interface\n");

            const container = ast.nodes.items(.data)[@intFromEnum(index)].container;
            for (ast.extraDataNodes(container.start, container.len)) |item_index| {
                try ast.dumpNode(item_index, indent + 2, writer);
            }
        },
        .import_path => {
            try writer.writeAll("import ");
            const path = ast.nodes.items(.data)[@intFromEnum(index)].path;
            try ast.dumpUsePath(ast.extraData(Node.UsePath, path.path), writer);
            try writer.writeByte('\n');
        },
        .include => {
            try writer.writeAll("include ");
            const include = ast.nodes.items(.data)[@intFromEnum(index)].include;
            try ast.dumpUsePath(ast.extraData(Node.UsePath, include.path), writer);
            const names = ast.extraData(Node.IncludeNames, include.names);
            if (names.len > 0) {
                try writer.writeAll(" with {");
                for (ast.extraDataNodes(names.start, names.len), 0..) |name_index, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try ast.dumpNode(name_index, 0, writer);
                }
                try writer.writeByte('}');
            }
            try writer.writeByte('\n');
        },
        .include_name => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            const include_name = ast.nodes.items(.data)[@intFromEnum(index)].include_name;
            const alias = include_name.alias;
            try writer.writeAll(": ");
            assert(ast.tokens.items(.tag)[@intFromEnum(alias)] == .identifier);
            try writer.writeAll(ast.tokenSlice(alias));
        },
        .type_alias => {
            try writer.writeAll("type ");
            const type_token = ast.nodes.items(.main_token)[@intFromEnum(index)];
            const name: Token.Index = @enumFromInt(@intFromEnum(type_token) + 1);
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const type_reference = ast.nodes.items(.data)[@intFromEnum(index)].type_reference;
            try ast.dumpNode(type_reference.type, 0, writer);
            try writer.writeByte('\n');
        },
        .use => {
            try writer.writeAll("use ");
            const use = ast.nodes.items(.data)[@intFromEnum(index)].use;
            try ast.dumpUsePath(ast.extraData(Node.UsePath, use.path), writer);
            try writer.writeAll(".{");
            const names = ast.extraData(Node.UseNames, use.names);
            for (ast.extraDataNodes(names.start, names.len), 0..) |name_index, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try ast.dumpNode(name_index, 0, writer);
            }
            try writer.writeAll("};\n");
        },
        .use_name => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            const use_name = ast.nodes.items(.data)[@intFromEnum(index)].use_name;
            if (use_name.alias.unwrap()) |alias| {
                try writer.writeAll(": ");
                assert(ast.tokens.items(.tag)[@intFromEnum(alias)] == .identifier);
                try writer.writeAll(ast.tokenSlice(alias));
            }
        },
        .func => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const func = ast.nodes.items(.data)[@intFromEnum(index)].func;
            const func_type = ast.extraData(Node.FuncType, func.type);
            try ast.dumpFuncType(func_type, writer);
            try writer.writeByte('\n');
        },
        .static_func => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": static ");

            const func = ast.nodes.items(.data)[@intFromEnum(index)].func;
            const func_type = ast.extraData(Node.FuncType, func.type);
            try ast.dumpFuncType(func_type, writer);
            try writer.writeByte('\n');
        },
        .constructor => {
            try writer.writeAll("constructor(");
            const constructor = ast.nodes.items(.data)[@intFromEnum(index)].constructor;
            for (ast.extraDataNodes(constructor.params_start, constructor.params_len), 0..) |param_index, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try ast.dumpNode(param_index, 0, writer);
            }
            try writer.writeAll(")\n");
        },
        .param => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const type_reference = ast.nodes.items(.data)[@intFromEnum(index)].type_reference;
            try ast.dumpNode(type_reference.type, 0, writer);
        },
        .untyped_field => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeByte('\n');
        },
        .typed_field => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            assert(ast.tokens.items(.tag)[@intFromEnum(name)] == .identifier);
            try writer.writeAll(ast.tokenSlice(name));
            try writer.writeAll(": ");

            const type_reference = ast.nodes.items(.data)[@intFromEnum(index)].type_reference;
            try ast.dumpNode(type_reference.type, 0, writer);
            try writer.writeByte('\n');
        },
        .type_simple => {
            const name = ast.nodes.items(.main_token)[@intFromEnum(index)];
            try writer.writeAll(ast.tokenSlice(name));
        },
        .type_tuple => {
            try writer.writeAll("tuple<");
            const container = ast.nodes.items(.data)[@intFromEnum(index)].container;
            for (ast.extraDataNodes(container.start, container.len), 0..) |item_index, i| {
                if (i > 0) try writer.writeAll(", ");
                try ast.dumpNode(item_index, 0, writer);
            }
            try writer.writeByte('>');
        },
        .type_list => {
            try writer.writeAll("list<");
            const unary_type = ast.nodes.items(.data)[@intFromEnum(index)].unary_type;
            try ast.dumpNode(unary_type.child_type, 0, writer);
            try writer.writeByte('>');
        },
        .type_option => {
            try writer.writeAll("option<");
            const unary_type = ast.nodes.items(.data)[@intFromEnum(index)].unary_type;
            try ast.dumpNode(unary_type.child_type, 0, writer);
            try writer.writeByte('>');
        },
        .type_result => {
            const result_type = ast.nodes.items(.data)[@intFromEnum(index)].result_type;
            if (result_type.ok_type == .none and result_type.err_type == .none) {
                try writer.writeAll("result");
                return;
            }

            try writer.writeAll("result<");
            if (result_type.ok_type.unwrap()) |ok_type| {
                try ast.dumpNode(ok_type, 0, writer);
            } else {
                try writer.writeByte('_');
            }
            if (result_type.err_type.unwrap()) |err_type| {
                try writer.writeAll(", ");
                try ast.dumpNode(err_type, 0, writer);
            }
            try writer.writeByte('>');
        },
        .type_borrow => {
            try writer.writeAll("borrow<");
            const unary_type = ast.nodes.items(.data)[@intFromEnum(index)].unary_type;
            try ast.dumpNode(unary_type.child_type, 0, writer);
            try writer.writeByte('>');
        },
    }
}

fn dumpUsePath(ast: Ast, path: Node.UsePath, writer: anytype) !void {
    if (path.namespace.unwrap()) |namespace| {
        try writer.print("{s}:{s}/", .{
            ast.tokenSlice(namespace),
            ast.tokenSlice(path.package.unwrap().?),
        });
    }
    try writer.writeAll(ast.tokenSlice(path.name));
    if (path.version.unwrap()) |version| {
        try writer.writeByte('@');
        try ast.dumpTokens(version, path.version_len, writer);
    }
}

fn dumpFuncType(ast: Ast, func_type: Node.FuncType, writer: anytype) !void {
    try writer.writeAll("func(");
    for (ast.extraDataNodes(func_type.params_start, func_type.params_len), 0..) |param_index, i| {
        if (i > 0) {
            try writer.writeAll(", ");
        }
        try ast.dumpNode(param_index, 0, writer);
    }
    try writer.writeByte(')');

    if (func_type.returns_len == 0) return;
    try writer.writeAll(" -> ");
    if (func_type.returns_len > 1) try writer.writeByte('(');
    for (ast.extraDataNodes(func_type.returns_start, func_type.returns_len), 0..) |return_index, i| {
        if (i > 0) {
            try writer.writeAll(", ");
        }
        try ast.dumpNode(return_index, 0, writer);
    }
    if (func_type.returns_len > 1) try writer.writeByte(')');
}

fn dumpTokens(ast: Ast, index: Token.Index, len: u32, writer: anytype) !void {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        try writer.writeAll(ast.tokenSlice(@enumFromInt(@intFromEnum(index) + i)));
    }
}
