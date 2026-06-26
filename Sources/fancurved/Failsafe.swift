import Foundation

/// Active daemon, reachable from C signal/atexit handlers (which can't capture).
nonisolated(unsafe) var gDaemon: Daemon?

/// Always revert the fan to Apple's automatic control on SIGTERM (launchd stop),
/// SIGINT (Ctrl-C in --foreground), or normal exit.
func installFailsafes() {
    let onSignal: @convention(c) (Int32) -> Void = { _ in
        gDaemon?.restore()
        _exit(0)
    }
    signal(SIGINT, onSignal)
    signal(SIGTERM, onSignal)
    atexit { gDaemon?.restore() }
}
