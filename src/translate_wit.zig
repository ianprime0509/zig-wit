const std = @import("std");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) return error.InvalidArgs;

    const source = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(u32));
    defer allocator.free(source);
    var ast = try Ast.parse(allocator, source);
    defer ast.deinit(allocator);

    const token_tags = ast.tokens.items(.tag)[1..];
    for (token_tags) |tag| {
        std.debug.print("{}\n", .{tag});
    }

    std.debug.print("{}\n", .{ast});
}
