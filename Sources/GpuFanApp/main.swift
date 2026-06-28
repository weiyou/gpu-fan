import AppKit
import SwiftUI
import FanCore

/// Menu-bar-only app (no Dock icon). An `NSStatusItem` shows the live fan RPM
/// and toggles a popover hosting the SwiftUI control panel. Built as a plain
/// SwiftPM executable: `setActivationPolicy(.accessory)` makes it menu-bar-only
/// at runtime, so no .app bundle / Info.plist LSUIElement is required.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wind", accessibilityDescription: "GPU Fan")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        // Let the popover size itself to the SwiftUI content's fitting height
        // rather than a fixed box. A hardcoded height clips (and mispositions)
        // the panel whenever the controls grow; `.preferredContentSize` keeps
        // the popover exactly as tall as it needs to be, and AppKit anchors it
        // under the menu-bar item so it always stays on screen.
        let host = NSHostingController(rootView: ContentView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        model.start()

        // Reflect live fan RPM next to the menu-bar icon. Zero-pad to 4 digits
        // and use a monospaced-digit font so the title width never shifts as the
        // RPM crosses, e.g., 999 -> 1000.
        let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                         weight: .regular)
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            if let t = self.model.telemetry, self.model.daemonAlive {
                let text = String(format: " %04d", Int(t.fanRPM.rounded()))
                button.attributedTitle = NSAttributedString(
                    string: text, attributes: [.font: titleFont])
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reloadConfigFromDisk()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
