//!zig-autodoc-guide: quickstart.md

/// A bip-buffer.
pub fn BipBuf(comptime T: type, comptime len: usize) type {
    return AlignedBipBuf(T, len, @alignOf(T));
}

/// A bip-buffer.
pub fn AlignedBipBuf(comptime T: type, comptime len: usize, comptime alignment: usize) type {
    return struct {
        const Self = @This();

        data: [len]T align(alignment) = undefined,
        read: usize = 0,
        write: usize = 0,
        watermark: usize = len,

        pub fn new() Self {
            return Self{};
        }

        pub fn reserveUnchecked(self: *Self, n: usize) ?[n]T {
            _ = self;
            return null;
        }

        pub fn reserve(self: *Self, n: usize, comptime critsec: type) ?[n]T {
            _ = critsec;
            _ = self;
            return null;
        }

        pub fn commitUnchecked(self: *Self, n: usize) void {
            _ = n;
            _ = self;
        }

        pub fn commit(self: *Self, n: usize, comptime critsec: type) void {
            _ = n;
            _ = critsec;
            _ = self;
        }

        pub fn getUnchecked(self: *Self) ?[]T {
            _ = self;
            return null;
        }

        pub fn get(self: *Self, comptime critsec: type) ?[]T {
            _ = critsec;
            _ = self;
            return null;
        }

        pub fn decommitUnchecked(self: *Self, n: usize) void {
            _ = n;
            _ = self;
        }

        pub fn decommit(self: *Self, n: usize, comptime critsec: type) void {
            _ = critsec;
            _ = n;
            _ = self;
        }

        inline fn write(self: *Self) usize {
            const write_ptr: *volatile usize = @ptrCast(&self.write);
            return *write_ptr;
        }

        inline fn read(self: *Self) usize {
            const read_ptr: *volatile usize = @ptrCast(&self.read);
            return *read_ptr;
        }

        inline fn watermark(self: *Self) usize {
            const watermark_ptr: *volatile usize = @ptrCast(&self.read);
            return *watermark_ptr;
        }
    };
}
