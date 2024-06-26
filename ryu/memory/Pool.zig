const Memory = @import("root").Memory;
const Spinlock = @import("root").Spinlock;
const HAL = @import("root").HAL;
const std = @import("std");

// This implements a simple memory allocator for the Ryu Kernel.
// There's a chance this will probably be replaced with a more efficient allocator in the future, but for now, this is the best you'll get.
// NOTE: Allocations beyond 65024 bytes (1/8 of a bucket) will directly allocate pages instead of using buckets.
//       These sections of the memory pool are called Anonymous Pages.

pub const Bucket = struct {
    prev: ?*Bucket align(1),
    next: ?*Bucket align(1),
    usedEntries: u64 align(1),
    bestBetLower: u32 align(1),
    bestBetUpper: u32 align(1),
    bitmap: [4064]u8 align(1), // 32512 entries = 520192 bytes = 508 KiB maximum

    comptime {
        if (@sizeOf(@This()) != 4096) {
            @panic("Bucket Header is not 4 KiB!");
        }
    }

    fn GetBit(self: *Bucket, index: usize) bool {
        return ((self.bitmap[index / 8] >> @as(u3, @intCast(index % 8))) & 1) != 0;
    }

    fn SetBit(self: *Bucket, index: usize, value: bool) void {
        if (value) {
            self.bitmap[index / 8] |= @as(u8, @intCast(1)) << @as(u3, @intCast(index % 8));
        } else {
            self.bitmap[index / 8] &= ~(@as(u8, @intCast(1)) << @as(u3, @intCast(index % 8)));
        }
    }

    pub fn Alloc(self: *Bucket, size: usize) ?[]u8 {
        var i: usize = 0;
        const entries: usize = if ((size % 16) != 0) ((size / 16) + 1) else (size / 16);
        while (i < 32512 - (entries - 1)) : (i += 1) {
            if (@as(*align(1) u32, @ptrCast(&self.bitmap[i / 8])).* == 0xffffffff) {
                i += 31 - (i % 32);
                continue;
            } else if (@as(*align(1) u16, @ptrCast(&self.bitmap[i / 8])).* == 0xffff) {
                i += 15 - (i % 16);
                continue;
            } else if (self.bitmap[i / 8] == 0xff) {
                i += 7 - (i % 8);
                continue;
            }
            var j = i;
            var canUse = true;
            while (j < i + entries) : (j += 1) {
                if (self.GetBit(j)) {
                    canUse = false;
                    break;
                }
            }
            if (canUse) {
                j = i;
                while (j < i + entries) : (j += 1) {
                    self.SetBit(j, true);
                }
                self.usedEntries += entries;
                const addr = (@intFromPtr(self) + 4096) + (i * 16);
                return @as([*]u8, @ptrFromInt(addr))[0..size];
            }
        }
        return null;
    }

    pub fn Free(self: *Bucket, mem: []u8) void {
        const size: usize = mem.len;
        const entries: usize = if ((size % 16) != 0) ((size / 16) + 1) else (size / 16);
        self.usedEntries -= entries;
        const start = (@intFromPtr(mem.ptr) - (@intFromPtr(self) + 0x1000)) / 16;
        var i: usize = start;
        while (i < start + entries) : (i += 1) {
            self.SetBit(i, false);
        }
    }
};

pub const Pool = struct {
    poolName: []const u8,
    poolBase: usize,
    searchStart: usize,
    allowSwapping: bool,
    buckets: usize = 0,
    usedBlocks: usize = 0,
    totalBlocks: usize = 0,
    anonymousPages: usize = 0,
    partialBucketHead: ?*Bucket = null,
    fullBucketHead: ?*Bucket = null,
    lock: Spinlock = .unaquired,
    lockHartID: i32 = -1,

    pub fn Alloc(self: *Pool, size: usize) ?[]u8 {
        if (size > 65024) {
            return self.AllocAnonPages(size);
        }
        const old = HAL.Arch.IRQEnableDisable(false);
        self.lock.acquire();
        var index = self.partialBucketHead;
        while (index != null) : (index = index.?.next) {
            std.debug.assert(index != null);
            const oldEntryCount = index.?.usedEntries;
            const ret = index.?.Alloc(size);
            if (ret != null) {
                if (index.?.usedEntries == 32512) {
                    // Relocate to Full Bucket List
                    if (index.?.prev) |prev| {
                        prev.next = index.?.next;
                    }
                    if (index.?.next) |next| {
                        next.prev = index.?.prev;
                    }
                    if (self.partialBucketHead == index) {
                        self.partialBucketHead = index.?.next;
                    }
                    if (self.fullBucketHead) |head| {
                        head.prev = index;
                    }
                    index.?.next = self.fullBucketHead;
                    self.fullBucketHead = index;
                }
                self.usedBlocks += ((index.?.usedEntries) - oldEntryCount);
                self.lock.release();
                _ = HAL.Arch.IRQEnableDisable(old);
                @memset(ret.?, 0);
                return ret;
            }
        }
        // Allocate a new bucket
        self.lockHartID = HAL.Arch.GetHCB().hartID;
        const newBucket = self.AllocAnonPages(512 * 1024);
        std.debug.assert(newBucket != null);
        var bucketHeader = @as(*Bucket, @ptrCast(newBucket.?.ptr));
        self.anonymousPages -= (512 * 1024) / 4096;
        self.buckets += 1;
        self.totalBlocks += 32512;
        bucketHeader.next = self.partialBucketHead;
        if (self.partialBucketHead) |head| {
            head.prev = bucketHeader;
        }
        self.partialBucketHead = bucketHeader;
        const ret = bucketHeader.Alloc(size);
        @memset(ret.?, 0);
        self.usedBlocks += bucketHeader.usedEntries;
        self.lock.release();
        _ = HAL.Arch.IRQEnableDisable(old);
        return ret;
    }

    pub fn AllocAnonPages(self: *Pool, size: usize) ?[]u8 {
        const old = HAL.Arch.IRQEnableDisable(false);
        if (self.lockHartID != HAL.Arch.GetHCB().hartID) {
            self.lock.acquire();
        }
        const trueSize = if ((size % 4096) != 0) (size & ~@as(usize, @intCast(0xFFF))) + 4096 else size;
        if (Memory.Paging.FindFreeSpace(Memory.Paging.initialPageDir.?, self.searchStart, trueSize)) |addr| {
            self.searchStart = addr + trueSize;
            var i = addr;
            while (i < addr + trueSize) : (i += 4096) {
                const page = Memory.PFN.AllocatePage(.Active, self.allowSwapping, 0);
                _ = Memory.Paging.MapPage(
                    Memory.Paging.initialPageDir.?,
                    i,
                    Memory.Paging.MapRead | Memory.Paging.MapWrite | Memory.Paging.MapSupervisor,
                    @intFromPtr(page.?.ptr) - 0xffff800000000000,
                );
            }
            self.anonymousPages += trueSize / 4096;
            if (self.lockHartID != HAL.Arch.GetHCB().hartID) {
                self.lock.release();
            } else {
                self.lockHartID = -1;
            }
            _ = HAL.Arch.IRQEnableDisable(old);
            return @as([*]u8, @ptrFromInt(addr))[0..trueSize];
        } else {
            if (self.lockHartID != HAL.Arch.GetHCB().hartID) {
                self.lock.release();
            } else {
                self.lockHartID = -1;
            }
            _ = HAL.Arch.IRQEnableDisable(old);
            return null;
        }
        unreachable;
    }

    pub fn Free(self: *Pool, data: []u8) void {
        if (data.len > 65024) {
            self.FreeAnonPages(data);
            return;
        }
        const old = HAL.Arch.IRQEnableDisable(false);
        self.lock.acquire();
        var index = self.partialBucketHead;
        var bucket: ?*Bucket = null;
        while (index != null) : (index = index.?.next) {
            if (@intFromPtr(data.ptr) >= @intFromPtr(index) and (@intFromPtr(data.ptr) + data.len) <= (@intFromPtr(index) + (512 * 1024))) {
                bucket = index;
                break;
            }
        }
        if (bucket == null) {
            index = self.fullBucketHead;
            while (index != null) : (index = index.?.next) {
                if (@intFromPtr(index) >= @intFromPtr(data.ptr) and @intFromPtr(index) + data.len <= (@intFromPtr(data.ptr) + (512 * 1024))) {
                    bucket = index;
                    break;
                }
            }
        }
        if (bucket) |b| {
            const oldSize: u64 = b.usedEntries;
            b.Free(data);
            self.usedBlocks -= (oldSize - b.usedEntries);
            if (oldSize == 32512) {
                // Relocate to Partial Bucket List
                if (b.prev) |prev| {
                    prev.next = b.next;
                }
                if (b.next) |next| {
                    next.prev = b.prev;
                }
                if (self.fullBucketHead == b) {
                    self.fullBucketHead = b.next;
                }
                if (self.partialBucketHead) |head| {
                    head.prev = b;
                }
                b.prev = null;
                b.next = self.partialBucketHead;
                self.partialBucketHead = b;
            } else if (b.usedEntries == 0) {
                // Free the Bucket from memory
                if (b.prev) |prev| {
                    prev.next = b.next;
                }
                if (b.next) |next| {
                    next.prev = b.prev;
                }
                if (self.partialBucketHead == b) {
                    self.partialBucketHead = b.next;
                }
                self.totalBlocks -= 32512;
                self.buckets -= 1;
                self.anonymousPages += (512 * 1024) / 4096;
                self.lockHartID = HAL.Arch.GetHCB().hartID;
                self.FreeAnonPages(@as([*]u8, @ptrCast(bucket))[0..(512 * 1024)]);
            }
        } else {
            @panic("Unable to free pool memory!");
        }
        self.lock.release();
        _ = HAL.Arch.IRQEnableDisable(old);
    }

    pub fn FreeAnonPages(self: *Pool, data: []u8) void {
        const old = HAL.Arch.IRQEnableDisable(false);
        if (self.lockHartID != HAL.Arch.GetHCB().hartID) {
            self.lock.acquire();
        }
        const addr = @intFromPtr(data.ptr);
        const size = if ((data.len % 4096) != 0) (data.len & ~@as(usize, @intCast(0xFFF))) + 4096 else data.len;
        if (self.searchStart > addr) {
            self.searchStart = addr;
        }
        var i = addr;
        while (i < addr + size) : (i += 4096) {
            const entry = Memory.Paging.GetPage(Memory.Paging.initialPageDir.?, i);
            if (entry.r == 1) {
                Memory.PFN.DereferencePage(@as(usize, @intCast(entry.phys)) << 12);
            }
            _ = Memory.Paging.MapPage(Memory.Paging.initialPageDir.?, i, 0, 0);
        }
        self.anonymousPages -= size / 4096;
        if (self.lockHartID != HAL.Arch.GetHCB().hartID) {
            self.lock.release();
        } else {
            self.lockHartID = -1;
        }
        _ = HAL.Arch.IRQEnableDisable(old);
    }
};

pub var StaticPool: Pool = Pool{
    .poolName = "StaticPool",
    .poolBase = 0xfffffe8000000000,
    .searchStart = 0xfffffe8000000000,
    .allowSwapping = false,
};

pub var PagedPool: Pool = Pool{
    .poolName = "PagedPool",
    .poolBase = 0xffffff0000000000,
    .searchStart = 0xffffff0000000000,
    .allowSwapping = true,
};
