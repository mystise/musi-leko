const std = @import("std");
const nm = @import("nm");

const config = @import("config.zig");

const Cardinal3 = nm.Cardinal3;

const Vec3i = nm.Vec3i;
const vec3i = nm.vec3i;

pub const LekoId = u16;

pub const Chunk = struct {
    
    position: Vec3i,
    id_array: IdArray,
    neighbors: Neighbors,
    state: State,

    pub const State = enum {
        /// chunk is in the pool, data is undefined
        inactive,
        /// chunk is in the volume, data is being generated or loaded
        loading,
        /// chunk is in the volume and ready for gameplay and rendering
        active,
    };

    pub const IdArray = LekoArray(LekoId);
    pub const Neighbors = [6]?*Self;

    pub const width_bits = config.chunk_width_bits;
    pub const width = config.chunk_width;

    const Self = @This();

    pub fn init(self: *Self, position: Vec3i) void {
        self.position = position;
        self.neighbors = std.mem.zeroes(Neighbors);
        self.state = .loading;
    }

    pub fn deinit(self: *Self) void {
        self.state = .inactive;
    }

    pub fn neighbor(self: Self, comptime direction: Cardinal3) ?*Self {
        return self.neighbors[@enumToInt(direction)];
    }

};

pub fn LekoArray(comptime Element_: type) type{
    return struct {
        items: Value,

        pub const Element = Element_;
        pub const Value = [width * width * width]Element;
        pub const width = Chunk.width;
        pub const Index = LekoIndex;

        const Self = @This();

        pub fn get(self: Self, index: Index) Element {
            return self.items[index.v];
        }

    };
}

pub const LekoIndex = struct {
    /// MSB <-> LSB
    ///  x   y   z
    v: Value = 0,

    pub const Value = std.meta.Int(.unsigned, Chunk.width_bits * 3);
    pub const Width = std.meta.Int(.unsigned, Chunk.width_bits);
    const IWidth = std.meta.Int(.signed, Chunk.width_bits);
    pub const Vector = nm.Vec3u;

    const Self = @This();

    pub const zero = Self { .v = 0 };

    pub fn init(comptime T: type, value: [3]T) Self {
        var self: Self = .{};
        comptime var i = 0;
        inline while (i < 3) : (i += 1) {
            self.v = (self.v << Chunk.width_bits) | @intCast(Width, value[i]);
        }
        return self;
    }

    pub fn initI(value: usize) Self {
        return .{
            .v = @intCast(Value, value),
        };
    }

    pub fn get(self: Self, comptime axis: nm.Axis3) Width {
        return @truncate(Width, self.v >> (Chunk.width_bits * (2 - @enumToInt(axis))));
    }


    pub fn isEdge(self: Self, comptime direction: nm.Cardinal3) bool {
        const w: Width = @intCast(Width, Chunk.width - 1);
        return switch (comptime direction.sign()) {
            .positive => self.get(comptime direction.axis()) == w,
            .negative => self.get(comptime direction.axis()) == 0,
        };
    }

    /// move this index to the edge of the chunk in `direction`
    pub fn toEdge(self: Self, comptime direction: nm.Cardinal3) Self {
        const w: Width = @intCast(Width, Chunk.width - 1);
        return switch (comptime direction.sign()) {
            .positive => .{ .v = self.v | single(Width, w, comptime direction.axis()).v},
            .negative => .{ .v = self.v & ~single(Width, w, comptime direction.axis()).v},
        };
    }

    pub fn edge(comptime T: type, offset: T, comptime direction: nm.Cardinal3) Self {
        const w: Width = @intCast(Width, Chunk.width - 1);
        return switch (comptime direction.sign()) {
            .positive => .{ .v = single(u32, w - offset, comptime direction.axis()).v},
            .negative => .{ .v = single(u32, offset, comptime direction.axis()).v},
        };
    }

    pub fn single(comptime T: type, value: T, comptime axis: nm.Axis3) Self {
        return Self {
            .v = @intCast(Value, value) << (Chunk.width_bits * (2 - @enumToInt(axis))),
        };
    }


    pub fn vector(self: Self) Vector {
        return Vector.init(.{
            @truncate(Width, self.v >> Chunk.width_bits * 2),
            @truncate(Width, self.v >> Chunk.width_bits * 1),
            @truncate(Width, self.v >> Chunk.width_bits * 0),
        });
    }

    /// increment this index one cell in a cardinal direction
    /// trying to increment out of bounds is UB, only use when in bounds
    pub fn incr(self: Self, comptime card: nm.Cardinal3) Self {
        const w: Width = @intCast(Width, Chunk.width - 1);
        const offset = comptime switch (card) {
            .x_pos => init(Width, .{1, 0, 0}),
            .x_neg => init(Width, .{w, 0, 0}),
            .y_pos => init(Width, .{0, 1, 0}),
            .y_neg => init(Width, .{w, w, 0}),
            .z_pos => init(Width, .{0, 0, 1}),
            .z_neg => init(Width, .{w, w, w}),
        };
        return .{ .v = self.v +% offset.v};
    }

    /// decrement this index one cell in a cardinal direction
    /// trying to increment out of bounds is UB, only use when in bounds
    pub fn decr(self: Self, comptime card: nm.Cardinal3) Self {
        return self.incr(comptime card.neg());
    }

};