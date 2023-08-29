//!zig-autodoc-guide: quickstart.md

const std = @import("std");

const debug = std.debug;
const mem = std.mem;
const rand = std.rand;
const testing = std.testing;
const time = std.time;
const trait = std.meta.trait;

const NopCriticalSection = struct {
    const Self = @This();
    fn enter(_: *const Self) void {}
    fn exit(_: *const Self, _: void) void {}
};

/// A bip-buffer.
pub fn BipBuf(comptime T: type, comptime capacity: usize) type {
    return BipBufAligned(T, capacity, @alignOf(T));
}

/// A bip-buffer.
pub fn BipBufAligned(
    comptime T: type,
    comptime capacity: usize,
    comptime alignment: usize,
) type {
    return struct {
        const Self = @This();

        //
        // Shared data
        //

        data: [capacity]T align(alignment) = undefined,
        read: usize = 0,
        write: usize = 0,
        watermark: usize = capacity,

        //
        // Disjoint data
        //

        start: ?usize = null,
        reserved: ?usize = null,

        //
        // Public API
        //

        pub fn init() Self {
            return Self{};
        }

        pub fn reserveUnchecked(self: *Self, n: usize) ?[]T {
            return self.reserve(n, NopCriticalSection{});
        }

        pub fn reserve(self: *Self, n: usize, critsec: anytype) ?[]T {
            debug.assert(self.reserved == null); // missing call to `commit`
            debug.assert(n <= capacity); // can't reserve more than max capacity

            const cx = critsec.enter();
            const read = self.getRead();
            var write = self.getWrite();
            critsec.exit(cx);

            if (write < read) {
                if ((write + n) >= read) {
                    return null;
                }
            } else if ((write + n) > capacity) {
                if (n < read) {
                    write = 0;
                } else {
                    return null;
                }
            }

            self.start = write;
            self.reserved = write + n;
            return self.data[write .. write + n];
        }

        pub fn commitUnchecked(self: *Self, n: usize) void {
            self.commit(n, NopCriticalSection{});
        }

        pub fn commit(self: *Self, n: usize, critsec: anytype) void {
            var cx = critsec.enter();

            const write_prev = self.getWrite();
            const start = self.start orelse undefined;
            const reserved = self.reserved orelse undefined;
            const write_new = start + n;
            debug.assert(write_new <= reserved);

            const wrap = (write_new < write_prev) and (write_prev != capacity);
            self.setWatermark(if (wrap) write_prev else capacity);
            self.setWrite(write_new);

            critsec.exit(cx);

            self.start = null;
            self.reserved = null;
        }

        pub fn drainUnchecked(self: *Self) ?[]T {
            return self.drain(NopCriticalSection{});
        }

        pub fn drain(self: *Self, critsec: anytype) ?[]T {
            var cx = critsec.enter();
            var read = self.getRead();
            const write = self.getWrite();
            const watermark = self.getWatermark();
            critsec.exit(cx);

            if ((read == watermark) and (write < read)) {
                read = 0;

                cx = critsec.enter();
                self.setRead(0);
                critsec.exit(cx);
            }

            const size = (if (write < read) watermark else write) - read;

            if (size == 0) {
                return null;
            }

            return self.data[read .. read + size];
        }

        pub fn decommitUnchecked(self: *Self, n: usize) void {
            self.decommit(n, NopCriticalSection{});
        }

        pub fn decommit(self: *Self, n: usize, critsec: anytype) void {
            const cx = critsec.enter();
            const read = self.getRead();
            self.setRead(read + n);
            critsec.exit(cx);
        }

        //
        // Shared state accessors
        //
        // Note: volatile reads/writes are used in place of relaxed atomics
        // to imrpove portability across CPU architectures (e.g. Cortex-M0)
        //

        inline fn getWrite(self: *Self) usize {
            const ptr: *const volatile usize = @ptrCast(&self.write);
            return ptr.*;
        }

        inline fn getRead(self: *Self) usize {
            const ptr: *volatile usize = @ptrCast(&self.read);
            return ptr.*;
        }

        inline fn getWatermark(self: *Self) usize {
            const ptr: *const volatile usize = @ptrCast(&self.watermark);
            return ptr.*;
        }

        inline fn setWrite(self: *Self, write: usize) void {
            const ptr: *volatile usize = @ptrCast(&self.write);
            ptr.* = write;
        }

        inline fn setRead(self: *Self, read: usize) void {
            const ptr: *volatile usize = @ptrCast(&self.read);
            ptr.* = read;
        }

        inline fn setWatermark(self: *Self, watermark: usize) void {
            const ptr: *volatile usize = @ptrCast(&self.watermark);
            ptr.* = watermark;
        }
    };
}

//
//
// Test suite
//
//

test "smoke" {
    var bipbuf = BipBuf(u8, 8).init();

    for (0..32) |_| {
        for (0..4) |x| {
            var grant_w = bipbuf.reserveUnchecked(1) orelse unreachable;
            grant_w[0] = @truncate(x);
            bipbuf.commitUnchecked(1);
        }

        for (0..4) |x| {
            const grant_r = bipbuf.drainUnchecked() orelse unreachable;
            const expected: u8 = @truncate(x);
            try testing.expectEqual(expected, grant_r[0]);
            bipbuf.decommitUnchecked(1);
        }
    }
}

test "multi threaded" {
    const CritSec = struct {
        const Self = @This();

        m: std.Thread.Mutex,

        fn enter(self: *Self) void {
            self.m.lock();
        }

        fn exit(self: *Self, _: void) void {
            self.m.unlock();
        }
    };

    const Context = struct {
        bipbuf: *BipBuf(u8, 64),
        critsec: *CritSec,
        bytes: std.ArrayList(u8),
    };

    const Reader = struct {
        fn task(cx: *Context) !void {
            defer cx.bytes.deinit();

            while (true) {
                var read = cx.bipbuf.drain(cx.critsec) orelse continue;

                for (read) |byte| {
                    try testing.expectEqual(cx.bytes.pop(), byte);
                }

                cx.bipbuf.decommit(read.len, cx.critsec);

                if (cx.bytes.items.len == 0) {
                    break;
                }
            }
        }
    };

    const Writer = struct {
        fn task(cx: *Context) !void {
            defer cx.bytes.deinit();
            var prng = rand.DefaultPrng.init(@bitCast(time.timestamp()));

            while (true) {
                if (cx.bytes.items.len == 0) {
                    break;
                }

                const len = @min(prng.next() % 32, cx.bytes.items.len);
                var write = cx.bipbuf.reserve(len, cx.critsec) orelse {
                    continue;
                };

                for (write) |*dst| {
                    dst.* = cx.bytes.pop();
                }

                cx.bipbuf.commit(len, cx.critsec);
            }
        }
    };

    var bipbuf = BipBuf(u8, 64).init();
    var critsec = CritSec{ .m = std.Thread.Mutex{} };

    const alloc = testing.allocator;
    var bytes = std.ArrayList(u8).init(alloc);
    var prng = rand.DefaultPrng.init(@bitCast(time.timestamp()));
    var buf = try bytes.addManyAsSlice(32 * 1024);
    prng.fill(buf);

    var rdr_cx = .{
        .bipbuf = &bipbuf,
        .critsec = &critsec,
        .bytes = try bytes.clone(),
    };
    var rdr_thread = try std.Thread.spawn(.{}, Reader.task, .{&rdr_cx});

    var wtr_cx = .{
        .bipbuf = &bipbuf,
        .critsec = &critsec,
        .bytes = bytes,
    };
    var wtr_thread = try std.Thread.spawn(.{}, Writer.task, .{&wtr_cx});

    rdr_thread.join();
    wtr_thread.join();
}
