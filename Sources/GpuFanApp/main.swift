import AppKit
import SwiftUI
import FanCore

/// Menu-bar-only app (no Dock icon). An `NSStatusItem` shows the live fan RPM
/// and toggles a popover hosting the SwiftUI control panel. Built as a plain
/// SwiftPM executable: `setActivationPolicy(.accessory)` makes it menu-bar-only
/// at runtime, so no .app bundle / Info.plist LSUIElement is required.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var titleTimer: Timer?
    private var lastTitle = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wind", accessibilityDescription: "GPU Fan")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.delegate = self
        // The SwiftUI content is installed on show and torn down on close (see
        // togglePopover/popoverDidClose): NSPopover keeps its window and content
        // alive after closing, so a permanent hosting view would keep re-running
        // layout for the invisible panel on every 1 Hz telemetry tick. That
        // off-screen churn accumulates until the app pins a core (see the
        // GpuFan cpu_resource diagnostic from 2026-07-12).

        model.start()

        // Reflect live fan RPM next to the menu-bar icon. Zero-pad to 4 digits
        // and use a monospaced-digit font so the title width never shifts as the
        // RPM crosses, e.g., 999 -> 1000. Snap to 10 RPM so sensor jitter
        // doesn't make the last digit flicker every second.
        let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                         weight: .regular)
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            let text: String
            if let t = self.model.telemetry, self.model.daemonAlive {
                text = String(format: " %04d", Int((t.fanRPM / 10).rounded()) * 10)
            } else {
                text = ""
            }
            // Setting the title invalidates menu-bar layout even when the string
            // is identical; skip the no-op ticks (RPM is snapped to 10, so most are).
            guard text != self.lastTitle else { return }
            self.lastTitle = text
            button.attributedTitle = NSAttributedString(
                string: text, attributes: [.font: titleFont])
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reloadConfigFromDisk()
            // Fresh hosting controller per show. `.preferredContentSize` sizes
            // the popover to the SwiftUI content's fitting height, so nothing
            // clips when the controls grow; building it on demand means no view
            // graph exists (or updates) while the panel is closed.
            let host = NSHostingController(rootView: ContentView().environmentObject(model))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Drop the SwiftUI hierarchy the moment the panel closes so the 1 Hz
    /// telemetry updates stop driving layout of an invisible window.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
