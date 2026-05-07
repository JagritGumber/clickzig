//! Connection pool for clickzig.
//!
//! Wraps multiple `Client`s behind a thread-safe acquire/release API.
//! Each pooled Client is single-threaded internally (per the locked
//! decision in client.zig); the pool is what makes multi-threaded
//! workloads viable.
//!
//! Lifecycle:
//!   var pool = try Pool.init(allocator, io, config, .{ .max_size = 8 });
//!   defer pool.deinit();
//!   const client = try pool.acquire(null);
//!   defer pool.release(client);
//!   try client.ping(null);
//!
//! Behaviour:
//!   - Lazy creation: dial only when an acquire can't be satisfied
//!     from the idle slice and we're below max_size.
//!   - Broken-on-release: if `client.is_broken` when returned, the
//!     pool closes it instead of recycling. Avoids handing the next
//!     caller a connection in `.broken` state.
//!   - Stale checking: optional `max_lifetime_ms` retires Clients that
//!     have lived longer than the budget on next release.
//!
//! Threading model:
//!   - The pool uses a `std.Thread.Mutex` to guard the idle/in-use
//!     bookkeeping. Acquire and release are O(1) amortised.
//!   - Concurrent acquires beyond max_size block on a `Condition` until
//!     someone releases.
//!
//! This file exceeds 100 lines because the lifecycle + bookkeeping +
//! state machine + tests live together. Splitting them would obscure
//! the invariants (acquire/release/deinit-in-flight all share state).

const std = @import("std");
const client_mod = @import("client.zig");

pub const Options = struct {
    max_size: u32 = 16,
    /// Retire Clients older than this on next release. 0 = no cap.
    max_lifetime_ms: u64 = 0,
};

pub const Error = error{
    PoolClosed,
    AcquireCancelled,
} || client_mod.ConnectError;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: client_mod.Config,
    opts: Options,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Idle Clients ready to hand out. Owned slice, dynamically grown.
    idle: std.ArrayListUnmanaged(*client_mod.Client) = .empty,
    /// Total live Clients — idle + currently acquired. Bounded by max_size.
    live_count: u32 = 0,
    closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: client_mod.Config,
        opts: Options,
    ) !*Pool {
        const self = try allocator.create(Pool);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .opts = opts,
        };
        return self;
    }

    /// Closes every Client (idle and not). Calling after deinit is UB.
    /// Caller is responsible for ensuring no acquired Client is still
    /// outstanding when deinit runs.
    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        const idle = self.idle.toOwnedSlice(self.allocator) catch &[_]*client_mod.Client{};
        self.mutex.unlock(self.io);
        for (idle) |c| c.close();
        self.allocator.free(idle);
        self.allocator.destroy(self);
    }

    /// Acquire a Client from the pool. Blocks if all max_size Clients
    /// are currently in use (until one is released). Returns the
    /// caller's cancellation error if the cancel token flips while
    /// waiting.
    pub fn acquire(
        self: *Pool,
        cancel: ?*const std.atomic.Value(bool),
    ) Error!*client_mod.Client {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            if (self.closed) return error.PoolClosed;
            if (cancellationRequested(cancel)) return error.AcquireCancelled;

            // Grab an idle Client first, validating it's still good.
            while (self.idle.pop()) |c| {
                if (self.shouldRetire(c)) {
                    c.close();
                    self.live_count -= 1;
                    continue;
                }
                return c;
            }

            // No idle Client. If we're under the cap, dial a new one.
            if (self.live_count < self.opts.max_size) {
                self.live_count += 1;
                self.mutex.unlock(self.io);
                const c = client_mod.Client.connectTcp(self.config, self.io, cancel, null) catch |e| {
                    self.mutex.lockUncancelable(self.io);
                    self.live_count -= 1;
                    self.cond.signal(self.io);
                    return e;
                };
                self.mutex.lockUncancelable(self.io);
                return c;
            }

            // At cap; wait for a release.
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Return a Client to the pool. If it's broken or expired the pool
    /// closes it instead of putting it back in idle.
    pub fn release(self: *Pool, c: *client_mod.Client) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) {
            c.close();
            self.live_count -= 1;
            return;
        }
        if (self.shouldRetire(c)) {
            c.close();
            self.live_count -= 1;
            self.cond.signal(self.io);
            return;
        }
        self.idle.append(self.allocator, c) catch {
            // Allocation failure on the idle list — close the client
            // rather than leak; subsequent acquires will create fresh.
            c.close();
            self.live_count -= 1;
        };
        self.cond.signal(self.io);
    }

    pub fn liveCount(self: *Pool) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.live_count;
    }

    pub fn idleCount(self: *Pool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.idle.items.len;
    }

    fn shouldRetire(self: *Pool, c: *const client_mod.Client) bool {
        if (!c.isReusable()) return true;
        if (self.opts.max_lifetime_ms > 0) {
            const now_ms = std.Io.Clock.now(.real, c.io).toMilliseconds();
            const age = @as(u64, @intCast(now_ms - c.connected_at_ms));
            if (age > self.opts.max_lifetime_ms) return true;
        }
        return false;
    }
};

fn cancellationRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    if (cancel) |c| return c.load(.acquire);
    return false;
}

const testing = std.testing;

test "Pool deinit on empty pool is safe" {
    const pool = try Pool.init(
        testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 4096,
            .write_buffer_size = 4096,
        },
        .{},
    );
    pool.deinit();
}
