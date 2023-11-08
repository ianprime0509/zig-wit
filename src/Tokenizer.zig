const std = @import("std");
const Token = @import("Ast.zig").Token;

source: []const u8,
index: u32,

const Tokenizer = @This();

pub fn init(source: []const u8) Tokenizer {
    return .{ .source = source, .index = 0 };
}

pub fn next(t: *Tokenizer) Token {
    // TODO: validate identifier composition
    // TODO: escape identifier with %
    var state: enum {
        start,
        @"/",
        line_comment,
        block_comment,
        @"block_comment_*",
        @"-",
        identifier,
        integer,
    } = .start;
    var block_comment_level: u32 = 0;

    var c_len: u32 = undefined;
    var start: u32 = t.index;
    var tag: Token.Tag = while (t.index < t.source.len) : (t.index += c_len) {
        c_len = std.unicode.utf8ByteSequenceLength(t.source[t.index]) catch {
            t.index += 1;
            break .invalid;
        };
        if (t.index + c_len > t.source.len) {
            t.index = @intCast(t.source.len);
            break .invalid;
        }
        const c = switch (c_len) {
            1 => t.source[t.index],
            2 => std.unicode.utf8Decode2(t.source[t.index..][0..2]),
            3 => std.unicode.utf8Decode3(t.source[t.index..][0..3]),
            4 => std.unicode.utf8Decode4(t.source[t.index..][0..4]),
            else => unreachable,
        } catch {
            t.index += c_len;
            break .invalid;
        };

        switch (state) {
            .start => switch (c) {
                ' ', '\n', '\r', '\t' => start += c_len,
                '/' => state = .@"/",
                '_' => {
                    t.index += c_len;
                    break ._;
                },
                '=' => {
                    t.index += c_len;
                    break .@"=";
                },
                ',' => {
                    t.index += c_len;
                    break .@",";
                },
                ':' => {
                    t.index += c_len;
                    break .@":";
                },
                ';' => {
                    t.index += c_len;
                    break .@";";
                },
                '(' => {
                    t.index += c_len;
                    break .@"(";
                },
                ')' => {
                    t.index += c_len;
                    break .@")";
                },
                '{' => {
                    t.index += c_len;
                    break .@"{";
                },
                '}' => {
                    t.index += c_len;
                    break .@"}";
                },
                '<' => {
                    t.index += c_len;
                    break .@"<";
                },
                '>' => {
                    t.index += c_len;
                    break .@">";
                },
                '*' => {
                    t.index += c_len;
                    break .@"*";
                },
                '-' => state = .@"-",
                '.' => {
                    t.index += c_len;
                    break .@".";
                },
                '@' => {
                    t.index += c_len;
                    break .@"@";
                },
                '+' => {
                    t.index += c_len;
                    break .@"+";
                },
                'a'...'z', 'A'...'Z' => state = .identifier,
                '0'...'9' => state = .integer,
                else => {
                    t.index += c_len;
                    break .invalid;
                },
            },
            .@"/" => switch (c) {
                '/' => state = .line_comment,
                '*' => {
                    block_comment_level += 1;
                    state = .block_comment;
                },
                else => break .@"/",
            },
            .line_comment => switch (c) {
                '\n' => {
                    state = .start;
                    start = t.index + c_len;
                },
                else => {},
            },
            .block_comment => switch (c) {
                '*' => state = .@"block_comment_*",
                else => {},
            },
            .@"block_comment_*" => switch (c) {
                '/' => {
                    block_comment_level -= 1;
                    if (block_comment_level == 0) {
                        state = .start;
                        start = t.index + c_len;
                    } else {
                        state = .block_comment;
                    }
                },
                '*' => {}, // Continue possibly looking at */
                else => state = .block_comment,
            },
            .@"-" => switch (c) {
                '>' => {
                    t.index += c_len;
                    break .@"->";
                },
                else => break .@"-",
            },
            .identifier => switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
                else => break .identifier,
            },
            .integer => switch (c) {
                '0'...'9' => {},
                else => break .integer,
            },
        }
    } else switch (state) {
        .start, .line_comment => .eof,
        .@"/" => .@"/",
        .block_comment, .@"block_comment_*" => .invalid,
        .@"-" => .@"-",
        .identifier => .identifier,
        .integer => .integer,
    };

    if (tag == .identifier) {
        tag = Token.Tag.keywords.get(t.source[start..t.index]) orelse .identifier;
    }

    return .{
        .tag = tag,
        .span = .{ .start = start, .len = t.index - start },
    };
}
