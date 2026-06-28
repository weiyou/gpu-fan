import Foundation

/// Advisory single-writer lock for forced fan control. Only one process may
/// drive the SMC fan at a time — the daemon, or a foreground `fancurvectl run`.
/// A second writer would race the first tick-by-tick (both write `F0Md`/`F0Tg`
/// every second), so each forced-mode controller takes this lock first.
///
/// Backed by `flock(2)` on a lockfile in the shared dir. The kernel drops the
/// lock automatically when the holding process exits — even on crash or
/// `kill -9` — so it can never get permanently stuck and needs no cleanup.
public final class FanLock {
    private let fd: Int32
    private var released = false
    public let path: String

    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }

    /// Try to take the exclusive fan-control lock without blocking. Returns nil
    /// if another process already holds it. Keep the returned object alive for
    /// as long as you hold forced control; dropping it (or exiting) releases it.
    public static func acquire(path: String = Paths.lock) -> FanLock? {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return FanLock(fd: fd, path: path)
    }

    /// Release the lock (also happens automatically on process exit).
    public func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }
}
