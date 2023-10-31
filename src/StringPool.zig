const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

bytes: std.ArrayListUnmanaged(u8),
lookup: std.HashMapUnmanaged(
    Index,
    void,
    LookupContext,
    std.hash_map.default_max_load_percentage,
),

const StringPool = @This();

pub const Index = enum(u32) { none = 0, _ };

pub fn init(allocator: Allocator) Allocator.Error!StringPool {
    var bytes: std.ArrayListUnmanaged(u8) = .{};
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, 0);
    return .{ .bytes = bytes, .lookup = .{} };
}

pub fn deinit(sp: *StringPool, allocator: Allocator) void {
    sp.bytes.deinit(allocator);
    sp.lookup.deinit(allocator);
    sp.* = undefined;
}

pub fn data(sp: StringPool, index: Index) [:0]const u8 {
    assert(index != .none);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(sp.bytes.items.ptr)) + @intFromEnum(index), 0);
}

pub fn intern(sp: *StringPool, allocator: Allocator, s: []const u8) Allocator.Error!Index {
    try sp.bytes.ensureUnusedCapacity(allocator, s.len + 1);
    var gop = try sp.lookup.getOrPutContextAdapted(
        allocator,
        s,
        LookupAdapter{ .bytes = sp.bytes.items },
        LookupContext{ .bytes = sp.bytes.items },
    );
    if (gop.found_existing) {
        return gop.key_ptr.*;
    }
    gop.key_ptr.* = @enumFromInt(sp.bytes.items.len);
    sp.bytes.appendSliceAssumeCapacity(s);
    sp.bytes.appendAssumeCapacity(0);
    return gop.key_ptr.*;
}

const LookupContext = struct {
    bytes: []const u8,

    pub fn eql(_: LookupContext, a: Index, b: Index) bool {
        return a == b;
    }

    pub fn hash(self: LookupContext, index: Index) u64 {
        assert(index != .none);
        const x_slice = mem.sliceTo(@as([*:0]const u8, @ptrCast(self.bytes)) + @intFromEnum(index), 0);
        return std.hash_map.hashString(x_slice);
    }
};

const LookupAdapter = struct {
    bytes: []const u8,

    pub fn eql(self: LookupAdapter, a_slice: []const u8, b: Index) bool {
        assert(b != .none);
        const b_slice = mem.sliceTo(@as([*:0]const u8, @ptrCast(self.bytes)) + @intFromEnum(b), 0);
        return mem.eql(u8, a_slice, b_slice);
    }

    pub fn hash(_: LookupAdapter, adapted_key: []const u8) u64 {
        return std.hash_map.hashString(adapted_key);
    }
};
