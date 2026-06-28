import Foundation
import FanCore

/// The privileged fan-control daemon. A single-threaded, blocking 1 Hz loop:
/// read sensors → evaluate curves → write the fan; publish telemetry to disk;
/// hot-reload the config when the menu-bar app rewrites it. Kept deliberately
/// synchronous (no GCD/async) so its failsafe behavior is trivial to reason
/// about — on any exit it reverts the fan to Apple's automatic control.
final class Daemon {

    private let foreground: Bool
    private var loop: ControlLoop?
    private var configMtime: Date?
    private var lock: FanLock?   // held for the daemon's lifetime

    init(foreground: Bool) { self.foreground = foreground }

    private func log(_ s: String) {
        let line = "[fancurved] \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if foreground { print(s); fflush(stdout) }
    }

    /// Create the shared dir world-writable so the (unprivileged) app can write
    /// config.json, and seed a default config if none exists.
    private func ensurePaths() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Paths.dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: Paths.dir)
        if !fm.fileExists(atPath: Paths.config) {
            try? FanConfig.defaults().save()
            try? fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: Paths.config)
        }
    }

    func run() {
        guard getuid() == 0 else {
            log("must run as root (it controls the SMC fan)."); exit(1)
        }
        ensurePaths()

        // Take the single-writer lock. Normally free; if a foreground
        // `fancurvectl run` is controlling the fan, yield to it and wait rather
        // than fighting (or crash-looping under launchd) — resume when it exits.
        lock = FanLock.acquire()
        if lock == nil {
            log("fan controlled by another process; waiting for lock…")
            while lock == nil { Thread.sleep(forTimeInterval: 1.0); lock = FanLock.acquire() }
            log("acquired fan lock")
        }

        let cfg = FanConfig.load()
        configMtime = Paths.modified(Paths.config)
        do { loop = try ControlLoop(config: cfg) }
        catch { log("init failed: \(error)"); exit(1) }
        log("started (enabled=\(cfg.enabled))")

        while true {
            tick()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func tick() {
        // hot-reload config when the app rewrites it
        let m = Paths.modified(Paths.config)
        if m != configMtime {
            configMtime = m
            let cfg = FanConfig.load()
            loop?.update(config: cfg)
            log("config reloaded (enabled=\(cfg.enabled))")
        }

        guard let loop else { return }
        do {
            let t = try loop.step()
            try? t.save()
        } catch {
            log("tick error: \(error)")
            loop.restore()   // fail safe toward Apple's controller
        }
    }

    /// Revert the fan to automatic control. Invoked from signal/atexit handlers.
    func restore() { loop?.restore() }
}
