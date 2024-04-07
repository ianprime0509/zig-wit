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
            .interface => try p.scratch.append(p.allocator, try p.parseInterface()),
            else => return p.fail(.expected_top_level_item),
        }
    }

    const start, const len = try p.encodeScratch(scratch_top);
    p.nodes.items(.data)[0] = .{ .container = .{
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
    const path = try p.parseUsePath();
    const alias = switch (p.peek()) {
        .as => alias: {
            p.advance();
            break :alias (try p.expect(.identifier)).toOptional();
        },
        else => .none,
    };
    _ = try p.expect(.@";");

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
            .@"export" => try p.scratch.append(p.allocator, try p.parseExport()),
            .import => try p.scratch.append(p.allocator, try p.parseImport()),
            .include => try p.scratch.append(p.allocator, try p.parseInclude()),
            .type => try p.scratch.append(p.allocator, try p.parseTypeAlias()),
            .variant => try p.scratch.append(p.allocator, try p.parseVariant()),
            .record => try p.scratch.append(p.allocator, try p.parseRecord()),
            .flags => try p.scratch.append(p.allocator, try p.parseFlags()),
            .@"enum" => try p.scratch.append(p.allocator, try p.parseEnum()),
            .resource => try p.scratch.append(p.allocator, try p.parseResource()),
            else => return p.fail(.expected_world_item),
        }
    }

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .world,
        .main_token = world,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseExport(p: *Parser) !Node.Index {
    const @"export" = try p.expect(.@"export");

    const backtrack_index = p.token_index;
    export_type: {
        _ = p.eat(.identifier) orelse break :export_type;
        _ = p.eat(.@":") orelse break :export_type;
        switch (p.peek()) {
            .func => {
                const func_type = try p.parseFuncType();
                _ = try p.expect(.@";");
                return p.appendNode(.{
                    .tag = .export_func,
                    .main_token = @"export",
                    .data = .{ .func = .{
                        .type = func_type,
                    } },
                });
            },
            .interface => {
                p.advance();
                const start, const len = try p.parseInterfaceItems();
                return p.appendNode(.{
                    .tag = .export_interface,
                    .main_token = @"export",
                    .data = .{ .container = .{
                        .start = start,
                        .len = len,
                    } },
                });
            },
            else => break :export_type,
        }
    }
    p.token_index = backtrack_index;

    const path = try p.parseUsePath();
    _ = try p.expect(.@";");
    return p.appendNode(.{
        .tag = .export_path,
        .main_token = @"export",
        .data = .{ .path = .{
            .path = path,
        } },
    });
}

fn parseImport(p: *Parser) !Node.Index {
    const import = try p.expect(.import);

    const backtrack_index = p.token_index;
    import_type: {
        _ = p.eat(.identifier) orelse break :import_type;
        _ = p.eat(.@":") orelse break :import_type;
        switch (p.peek()) {
            .func => {
                const func_type = try p.parseFuncType();
                _ = try p.expect(.@";");
                return p.appendNode(.{
                    .tag = .import_func,
                    .main_token = import,
                    .data = .{ .func = .{
                        .type = func_type,
                    } },
                });
            },
            .interface => {
                p.advance();
                const start, const len = try p.parseInterfaceItems();
                return p.appendNode(.{
                    .tag = .import_interface,
                    .main_token = import,
                    .data = .{ .container = .{
                        .start = start,
                        .len = len,
                    } },
                });
            },
            else => break :import_type,
        }
    }
    p.token_index = backtrack_index;

    const path = try p.parseUsePath();
    _ = try p.expect(.@";");
    return p.appendNode(.{
        .tag = .import_path,
        .main_token = import,
        .data = .{ .path = .{
            .path = path,
        } },
    });
}

fn parseInclude(p: *Parser) !Node.Index {
    const include = try p.expect(.include);
    const path = try p.parseUsePath();
    const names_start, const names_len = names: {
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        if (p.eat(.with) == null) {
            break :names try p.encodeScratch(scratch_top);
        }
        _ = try p.expect(.@"{");
        while (p.peek() != .@"}") {
            const name = try p.expect(.identifier);
            _ = try p.expect(.as);
            const alias = try p.expect(.identifier);
            try p.scratch.append(p.allocator, try p.appendNode(.{
                .tag = .include_name,
                .main_token = name,
                .data = .{ .include_name = .{
                    .alias = alias,
                } },
            }));

            if (p.peek() == .@",") {
                p.advance();
            } else {
                break;
            }
        }
        _ = try p.expect(.@"}");
        break :names try p.encodeScratch(scratch_top);
    };
    _ = try p.expect(.@";");

    return p.appendNode(.{
        .tag = .include,
        .main_token = include,
        .data = .{ .include = .{
            .path = path,
            .names = try p.encode(Node.IncludeNames{
                .start = names_start,
                .len = names_len,
            }),
        } },
    });
}

fn parseInterface(p: *Parser) !Node.Index {
    const interface = try p.expect(.interface);
    _ = try p.expect(.identifier);
    const start, const len = try p.parseInterfaceItems();
    return p.appendNode(.{
        .tag = .interface,
        .main_token = interface,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseInterfaceItems(p: *Parser) !struct { ExtraIndex, u32 } {
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        switch (p.peek()) {
            .@"}" => {
                p.advance();
                break;
            },
            .type => try p.scratch.append(p.allocator, try p.parseTypeAlias()),
            .variant => try p.scratch.append(p.allocator, try p.parseVariant()),
            .record => try p.scratch.append(p.allocator, try p.parseRecord()),
            .flags => try p.scratch.append(p.allocator, try p.parseFlags()),
            .@"enum" => try p.scratch.append(p.allocator, try p.parseEnum()),
            .resource => try p.scratch.append(p.allocator, try p.parseResource()),
            .use => try p.scratch.append(p.allocator, try p.parseUse()),
            .identifier => {
                const name = p.next();
                _ = try p.expect(.@":");
                const func_type = try p.parseFuncType();
                _ = try p.expect(.@";");
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = .func,
                    .main_token = name,
                    .data = .{ .func = .{
                        .type = func_type,
                    } },
                }));
            },
            else => return p.fail(.expected_interface_item),
        }
    }

    return try p.encodeScratch(scratch_top);
}

fn parseTypeAlias(p: *Parser) !Node.Index {
    const @"type" = try p.expect(.type);
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"=");
    const child_type = try p.parseType();
    _ = try p.expect(.@";");
    return p.appendNode(.{
        .tag = .type_alias,
        .main_token = @"type",
        .data = .{ .type_reference = .{
            .type = child_type,
        } },
    });
}

fn parseRecord(p: *Parser) !Node.Index {
    const record = try p.expect(.record);
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (p.peek() != .@"}") {
        switch (p.peek()) {
            .identifier => {
                const name = p.next();
                _ = try p.expect(.@":");
                const @"type" = try p.parseType();
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = .typed_field,
                    .main_token = name,
                    .data = .{ .type_reference = .{
                        .type = @"type",
                    } },
                }));
            },
            else => return p.fail(.expected_record_field),
        }

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@"}");

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .record,
        .main_token = record,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseFlags(p: *Parser) !Node.Index {
    const flags = try p.expect(.flags);
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (p.peek() != .@"}") {
        switch (p.peek()) {
            .identifier => {
                const name = p.next();
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = .untyped_field,
                    .main_token = name,
                    .data = .{ .none = {} },
                }));
            },
            else => return p.fail(.expected_flags_field),
        }

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@"}");

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .flags,
        .main_token = flags,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseVariant(p: *Parser) !Node.Index {
    const variant = try p.expect(.variant);
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (p.peek() != .@"}") {
        switch (p.peek()) {
            .identifier => {
                const name = p.next();
                if (p.eat(.@"(") != null) {
                    const @"type" = try p.parseType();
                    _ = try p.expect(.@")");
                    try p.scratch.append(p.allocator, try p.appendNode(.{
                        .tag = .typed_field,
                        .main_token = name,
                        .data = .{ .type_reference = .{
                            .type = @"type",
                        } },
                    }));
                } else {
                    try p.scratch.append(p.allocator, try p.appendNode(.{
                        .tag = .untyped_field,
                        .main_token = name,
                        .data = .{ .none = {} },
                    }));
                }
            },
            else => return p.fail(.expected_variant_case),
        }

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@"}");

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .variant,
        .main_token = variant,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseEnum(p: *Parser) !Node.Index {
    const @"enum" = try p.expect(.@"enum");
    _ = try p.expect(.identifier);
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (p.peek() != .@"}") {
        switch (p.peek()) {
            .identifier => {
                const name = p.next();
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = .untyped_field,
                    .main_token = name,
                    .data = .{ .none = {} },
                }));
            },
            else => return p.fail(.expected_enum_case),
        }

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@"}");

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .@"enum",
        .main_token = @"enum",
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseResource(p: *Parser) !Node.Index {
    const resource = try p.expect(.resource);
    _ = try p.expect(.identifier);
    if (p.peek() == .@";") {
        p.advance();
        return p.appendNode(.{
            .tag = .resource,
            .main_token = resource,
            .data = .{ .container = .{
                .start = undefined,
                .len = 0,
            } },
        });
    }

    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        switch (p.peek()) {
            .@"}" => {
                p.advance();
                break;
            },
            .identifier => {
                const name = p.next();
                _ = try p.expect(.@":");
                const tag: Node.Tag = if (p.peek() == .static) tag: {
                    p.advance();
                    break :tag .static_func;
                } else .func;
                const func_type = try p.parseFuncType();
                _ = try p.expect(.@";");
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = tag,
                    .main_token = name,
                    .data = .{ .func = .{
                        .type = func_type,
                    } },
                }));
            },
            .constructor => {
                const constructor = p.next();
                const params_start, const params_len = try p.parseParams();
                _ = try p.expect(.@";");
                try p.scratch.append(p.allocator, try p.appendNode(.{
                    .tag = .constructor,
                    .main_token = constructor,
                    .data = .{ .constructor = .{
                        .params_start = params_start,
                        .params_len = params_len,
                    } },
                }));
            },
            else => return p.fail(.expected_resource_method),
        }
    }

    const start, const len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .resource,
        .main_token = resource,
        .data = .{ .container = .{
            .start = start,
            .len = len,
        } },
    });
}

fn parseUse(p: *Parser) !Node.Index {
    const use = try p.expect(.use);
    const path = try p.parseUsePath();
    _ = try p.expect(.@".");
    _ = try p.expect(.@"{");

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (p.peek() != .@"}") {
        const name = try p.expect(.identifier);
        const alias = if (p.peek() == .@":") alias: {
            p.advance();
            break :alias (try p.expect(.identifier)).toOptional();
        } else .none;
        try p.scratch.append(p.allocator, try p.appendNode(.{
            .tag = .use_name,
            .main_token = name,
            .data = .{ .use_name = .{
                .alias = alias,
            } },
        }));

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@"}");
    _ = try p.expect(.@";");

    const names_start, const names_len = try p.encodeScratch(scratch_top);
    return p.appendNode(.{
        .tag = .use,
        .main_token = use,
        .data = .{ .use = .{
            .path = path,
            .names = try p.encode(Node.UseNames{
                .start = names_start,
                .len = names_len,
            }),
        } },
    });
}

fn parseUsePath(p: *Parser) !ExtraIndex {
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
    return p.encode(Node.UsePath{
        .namespace = namespace,
        .package = package,
        .name = name,
        .version = version,
        .version_len = version_len,
    });
}

fn parseFuncType(p: *Parser) !ExtraIndex {
    _ = try p.expect(.func);

    const params_start, const params_len = try p.parseParams();

    const returns_start, const returns_len = returns: {
        if (p.peek() != .@"->") {
            // No returns
            break :returns .{ undefined, 0 };
        }
        p.advance();

        if (p.peek() != .@"(") {
            // Single return
            const scratch_top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(scratch_top);

            try p.scratch.append(p.allocator, try p.parseType());
            break :returns try p.encodeScratch(scratch_top);
        }
        p.advance();

        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        while (p.peek() != .@")") {
            const name = try p.expect(.identifier);
            _ = try p.expect(.@":");
            const @"type" = try p.parseType();
            try p.scratch.append(p.allocator, try p.appendNode(.{
                .tag = .named_return,
                .main_token = name,
                .data = .{ .type_reference = .{
                    .type = @"type",
                } },
            }));

            if (p.peek() == .@",") {
                p.advance();
            } else {
                break;
            }
        }
        _ = try p.expect(.@")");

        break :returns try p.encodeScratch(scratch_top);
    };

    return p.encode(Node.FuncType{
        .params_start = params_start,
        .params_len = params_len,
        .returns_start = returns_start,
        .returns_len = returns_len,
    });
}

fn parseParams(p: *Parser) !struct { ExtraIndex, u32 } {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    _ = try p.expect(.@"(");
    while (p.peek() != .@")") {
        const name = try p.expect(.identifier);
        _ = try p.expect(.@":");
        const @"type" = try p.parseType();
        try p.scratch.append(p.allocator, try p.appendNode(.{
            .tag = .param,
            .main_token = name,
            .data = .{ .type_reference = .{
                .type = @"type",
            } },
        }));

        if (p.peek() == .@",") {
            p.advance();
        } else {
            break;
        }
    }
    _ = try p.expect(.@")");

    return p.encodeScratch(scratch_top);
}

fn parseType(p: *Parser) !Node.Index {
    switch (p.peek()) {
        .u8,
        .u16,
        .u32,
        .u64,
        .s8,
        .s16,
        .s32,
        .s64,
        .f32,
        .f64,
        .char,
        .bool,
        .string,
        .identifier,
        => return p.appendNode(.{
            .tag = .type_simple,
            .main_token = p.next(),
            .data = .{ .none = {} },
        }),
        .tuple => {
            const tuple = p.next();
            _ = try p.expect(.@"<");

            const scratch_top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(scratch_top);
            while (p.peek() != .@">") {
                try p.scratch.append(p.allocator, try p.parseType());
                if (p.peek() == .@",") {
                    p.advance();
                } else {
                    break;
                }
            }
            _ = try p.expect(.@">");

            const start, const len = try p.encodeScratch(scratch_top);
            return p.appendNode(.{
                .tag = .type_tuple,
                .main_token = tuple,
                .data = .{ .container = .{
                    .start = start,
                    .len = len,
                } },
            });
        },
        .list => {
            const list = p.next();
            _ = try p.expect(.@"<");
            const child_type = try p.parseType();
            _ = try p.expect(.@">");
            return p.appendNode(.{
                .tag = .type_list,
                .main_token = list,
                .data = .{ .unary_type = .{
                    .child_type = child_type,
                } },
            });
        },
        .option => {
            const option = p.next();
            _ = try p.expect(.@"<");
            const child_type = try p.parseType();
            _ = try p.expect(.@">");
            return p.appendNode(.{
                .tag = .type_option,
                .main_token = option,
                .data = .{ .unary_type = .{
                    .child_type = child_type,
                } },
            });
        },
        .result => {
            const result = p.next();
            const ok_type, const err_type = parts: {
                if (p.peek() != .@"<") break :parts .{ .none, .none };
                p.advance();
                if (p.peek() == ._) {
                    p.advance();
                    _ = try p.expect(.@",");
                    const err_type = try p.parseType();
                    _ = try p.expect(.@">");
                    break :parts .{ .none, err_type.toOptional() };
                }
                const ok_type = try p.parseType();
                if (p.peek() == .@">") {
                    p.advance();
                    break :parts .{ ok_type.toOptional(), .none };
                }
                _ = try p.expect(.@",");
                const err_type = try p.parseType();
                _ = try p.expect(.@">");
                break :parts .{ ok_type.toOptional(), err_type.toOptional() };
            };
            return p.appendNode(.{
                .tag = .type_result,
                .main_token = result,
                .data = .{ .result_type = .{
                    .ok_type = ok_type,
                    .err_type = err_type,
                } },
            });
        },
        .borrow => {
            const borrow = p.next();
            _ = try p.expect(.@"<");
            const child_type = try p.parseType();
            _ = try p.expect(.@">");
            return p.appendNode(.{
                .tag = .type_borrow,
                .main_token = borrow,
                .data = .{ .unary_type = .{
                    .child_type = child_type,
                } },
            });
        },
        else => return p.fail(.expected_type),
    }
}

fn parseOptionalVersionSuffix(p: *Parser) !struct { Token.OptionalIndex, u32 } {
    if (p.eat(.@"@") == null) return .{ .none, 0 };

    const first_token_index = p.token_index;
    // First pass: eagerly eat tokens which could be part of a version
    while (true) {
        switch (p.peek()) {
            .identifier,
            .integer,
            .@"-",
            .@"+",
            => p.advance(),
            .@"." => {
                p.advance();
                // '.' is a special case, since it might be followed by '{' as
                // part of a 'use'. In this case, the '.' should not be parsed
                // as part of the version.
                if (p.peek() == .@"{") {
                    p.retreat();
                    break;
                }
            },
            else => break,
        }
    }
    const version_start = p.token_spans[@intFromEnum(first_token_index)].start;
    const version_end = p.token_spans[@intFromEnum(p.token_index)].start;
    _ = std.SemanticVersion.parse(p.source[version_start..version_end]) catch return p.failMsg(.{
        .tag = .invalid_version,
        .token = first_token_index,
    });

    return .{
        first_token_index.toOptional(),
        @intFromEnum(p.token_index) - @intFromEnum(first_token_index),
    };
}

fn peek(p: *Parser) Token.Tag {
    return p.token_tags[@intFromEnum(p.token_index)];
}

fn next(p: *Parser) Token.Index {
    const index = p.token_index;
    p.advance();
    return index;
}

fn eat(p: *Parser, expected_tag: Token.Tag) ?Token.Index {
    return if (p.peek() == expected_tag) p.next() else null;
}

fn expect(p: *Parser, expected_tag: Token.Tag) !Token.Index {
    if (p.peek() != expected_tag) {
        return p.failMsg(.{
            .tag = .expected_token,
            .token = p.token_index,
            .extra = .{ .expected_tag = expected_tag },
        });
    }
    return p.next();
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

fn retreat(p: *Parser) void {
    p.token_index = @enumFromInt(@intFromEnum(p.token_index) - 1);
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
            Token.Index,
            Token.OptionalIndex,
            Node.Index,
            Node.OptionalIndex,
            ExtraIndex,
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
