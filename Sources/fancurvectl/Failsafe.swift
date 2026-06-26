import Foundation
import FanCore

/// The active control loop, reachable from C `@convention(c)` signal/atexit
/// handlers (which cannot capture context). `nonisolated(unsafe)` opts this
/// global out of Swift 6 main-actor isolation; the only writer is the `run`
/// command and the only readers are exit handlers reverting the fan to auto.
nonisolated(unsafe) var gLoop: ControlLoop?

/// Install handlers that always revert the fan to Apple's automatic control
/// on SIGINT/SIGTERM/normal exit, so the fan can never be stranded.
func installFailsafes() {
    let onSignal: @convention(c) (Int32) -> Void = { _ in
        gLoop?.restore()
        _exit(0)
    }
    signal(SIGINT, onSignal)
    signal(SIGTERM, onSignal)
    atexit { gLoop?.restore() }
}
