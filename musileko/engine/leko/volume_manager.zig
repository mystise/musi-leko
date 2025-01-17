const std = @import("std");
const engine = @import("../.zig");
const nm = engine.nm;
const util = engine.util;

const leko = @import(".zig");

const Volume = leko.Volume;
const Chunk = leko.Chunk;
const Address = leko.Address;
const Reference = leko.Reference;

const LekoId = leko.LekoId;

const config = leko.config.volume_manager;

const Vec3 = nm.Vec3;
const Vec3i = nm.Vec3i;

const Allocator = std.mem.Allocator;

pub const ChunkEvent = util.Event(*Chunk);


pub const LekoEdit = struct {
    reference: Reference,
    new_id: LekoId,
    old_id: LekoId,
};

pub const LekoEditEvent = util.Event(LekoEdit);


pub const VolumeManager = struct {

    allocator: Allocator,
    volume: *Volume,
    chunks_mutex: std.Thread.Mutex = .{},
    chunk_positions: std.ArrayListUnmanaged(Vec3i) = .{},

    /// center of the loading zone in chunks
    load_center: Vec3i,
    /// radius in chunks of the loading zone
    load_radius: u32 = config.load_radius,

    load_thread_group: ChunkThreadGroup = undefined,

    loaded_chunk_queue: ChunkAtomicQueue,
    event_chunk_loaded: ChunkEvent = .{},
    event_chunk_unloaded: ChunkEvent = .{},

    edit_thread: LekoEditThread = undefined,
    event_leko_edit: LekoEditEvent = .{},

    load_queue: ChunkLoadQueue = undefined,
    load_thread: ChunkLoadThread = undefined,

    const ChunkLoad = struct {
        chunk_position: Vec3i,
        state: State,
        const State = enum {
            loading, unloading,
        };
    };

    const ChunkLoadQueue = util.AtomicQueue(ChunkLoad);
    const ChunkLoadThread = util.ThreadGroup(Vec3i);

    // const LekoEditQueue = util.AtomicQueue(LekoEdit);
    const LekoEditThread = util.ThreadGroup(LekoEdit);

    const Self = @This();

    pub fn init(self: *Self, allocator: Allocator, volume: *Volume) !void {
        self.* = .{
            .allocator = allocator,
            .volume = volume,
            .load_center = Vec3i.fill(std.math.maxInt(i32)),    // garuntee the first load center will be different
            .loaded_chunk_queue = try ChunkAtomicQueue.init(allocator),
            .load_queue = try ChunkLoadQueue.init(allocator),
        };
        try self.load_thread_group.init(allocator, config.load_group_config, processLoadChunk);
        try self.load_thread_group.spawn(.{});
        try self.load_thread.init(allocator, .{ .thread_count = .{ .count = 1, }}, processLoadCenterChanged);
        try self.load_thread.spawn(.{});
        try self.edit_thread.init(allocator, .{ .thread_count = .{ .count = 1, }}, processLekoEdit);
        try self.edit_thread.spawn(.{});
    }

    pub fn deinit(self: *Self) void {
        self.load_thread_group.join();
        self.load_thread_group.deinit(self.allocator);
        self.loaded_chunk_queue.deinit();
        self.load_thread.join();
        self.load_thread.deinit(self.allocator);
        self.load_queue.deinit();
        self.chunk_positions.deinit(self.allocator);
        self.edit_thread.join();
        self.edit_thread.deinit(self.allocator);
    }

    pub fn update(self: *Self, load_center: Vec3) !void {
        const chunk_center = comptime Vec3.fill(@intToFloat(f32, Chunk.width / 2));
        const chunk_width = @intToFloat(f32, Chunk.width);
        const new_center: Vec3i = (
            load_center.floor()
            .add(chunk_center)
            .divScalar(chunk_width)
            .floor().cast(i32)
        );
        if (!new_center.eql(self.load_center)) {
            try self.load_thread.submitItem(new_center);
        }
        // self.chunks_mutex.lock();
        while (self.load_queue.dequeue()) |load| {
            switch (load.state) {
                .loading => {
                    const chunk = try self.volume.activateChunk(load.chunk_position);
                    chunk.state = .loading;
                    try self.load_thread_group.submitItem(chunk);
                },
                .unloading => {
                    if (self.volume.chunks.get(load.chunk_position)) |chunk| {
                        try self.event_chunk_unloaded.dispatch(chunk);
                        self.volume.deactivateChunk(chunk.position);
                    }
                },
            }
        }
        // self.chunks_mutex.unlock();
        while (self.loaded_chunk_queue.dequeue()) |chunk| {
            try self.event_chunk_loaded.dispatch(chunk);
        }
    }

    fn processLoadCenterChanged(thread: *ChunkLoadThread, new_center: Vec3i, _:usize) !void {
        const self = @fieldParentPtr(Self, "load_thread", thread);
        self.load_center = new_center;
        const load_min = new_center.sub(Vec3i.fill(@intCast(i32, self.load_radius)));
        const load_max = new_center.add(Vec3i.fill(@intCast(i32, self.load_radius)));
        
        var i: usize = 0;
        while (i < self.chunk_positions.items.len) : (i +%= 1) {
            const pos = self.chunk_positions.items[i];
            if (
                (pos.v[0] < load_min.v[0] or pos.v[0] >= load_max.v[0]) or
                (pos.v[1] < load_min.v[1] or pos.v[1] >= load_max.v[1]) or
                (pos.v[2] < load_min.v[2] or pos.v[2] >= load_max.v[2])
            ) {
                _ = self.chunk_positions.swapRemove(i);
                i -%= 1;
                try self.load_queue.enqueue(.{ .chunk_position = pos, .state = .unloading});
            }
        }



        var load_list = std.ArrayList(ChunkLoad).init(self.allocator);
        defer load_list.deinit();

        var x = load_min.v[0];
        while (x < load_max.v[0]) : (x += 1) {
            var y = load_min.v[1];
            while (y < load_max.v[1]) : (y += 1) {
                var z = load_min.v[2];
                while (z < load_max.v[2]) : (z += 1) {
                    const pos = Vec3i.init(.{x, y, z});
                    if (!self.chunkPositionsContains(pos)) {
                        try self.chunk_positions.append(self.allocator, pos);
                        try load_list.append(.{ .chunk_position = pos, .state = .loading});
                        // try chunk_list.append(chunk);
                    }
                }
            }
        }

        std.sort.sort(
            ChunkLoad,
            load_list.items,
            ChunkLoadSortContext {
                .load_center = new_center,
            },
            ChunkLoadSortContext.lessThan,
        );

        for (load_list.items) |load| {
            try self.load_queue.enqueue(load);
        }

    }

    const ChunkLoadSortContext = struct {
        load_center: Vec3i,

        fn lessThan(context: ChunkLoadSortContext, lhs: ChunkLoad, rhs: ChunkLoad) bool {
            _ = context;
            const dist_lhs = lhs.chunk_position.sub(context.load_center).mag2();
            const dist_rhs = rhs.chunk_position.sub(context.load_center).mag2();
            return dist_lhs < dist_rhs;
        }

    };

    fn chunkPositionsContains(self: Self, position: Vec3i) bool {
        for (self.chunk_positions.items) |pos| {
            if (position.eql(pos)) {
                return true;
            }
        }
        return false;
    }

    fn processLoadChunk(group: *ChunkThreadGroup, chunk: *Chunk, _: usize) !void {
        const self = @fieldParentPtr(Self, "load_thread_group", group);
        const perlin = nm.noise.Perlin3{};
        const scale: f32 = 0.025;

        const octaves: u32 = 4;
        const lacunarity: f32 = 2;
        const gain: f32 = 0.45;
        for (chunk.id_array.items) |*id, i| {
            const reference = Reference.init(chunk, Address.initI(i));
            var pos = reference.globalPosition().cast(f32);
            pos = pos.mul(Vec3.init(.{0.5, 1, 0.5}));
            // const sample = perlin.sample(pos.mulScalar(scale).v);
            var noise: f32 = 0;
            comptime var o: u32 = 0;
            comptime var f = scale;
            comptime var a: f32 = 1;
            inline while (o < octaves) : (o += 1) {
                noise += perlin.sample(pos.mulScalar(f).v) * a;
                f *= lacunarity;
                a *= gain;
            }
            if (noise < 0.25) {
                id.* = 1;
            }
            else {
                id.* = 0;
            }
            // if (pos.v[2] < 1) {
            //     id.* = 1;
            // }
            // else {
            //     id.* = 0;
            // }
        }
        chunk.state = .active;
        try self.loaded_chunk_queue.enqueue(chunk);
    }

    pub fn requestSingleEdit(self: *Self, reference: Reference, new_id: LekoId) !void {
        const old_id = reference.chunk.id_array.get(reference.address);
        const edit = LekoEdit {
            .reference = reference,
            .old_id = old_id,
            .new_id = new_id,
        };
        try self.edit_thread.submitItem(edit);
    }

    fn processLekoEdit(thread: *LekoEditThread, edit: LekoEdit, _: usize) !void {
        const self = @fieldParentPtr(Self, "edit_thread", thread);
        edit.reference.chunk.id_array.set(edit.reference.address, edit.new_id);
        try self.event_leko_edit.dispatch(edit);
    }

};

pub const ChunkThreadGroup = util.ThreadGroup(*Chunk);
pub const ChunkAtomicQueue = util.AtomicQueue(*Chunk);