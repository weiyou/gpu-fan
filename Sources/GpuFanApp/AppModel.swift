import Foundation
import SwiftUI
import ServiceManagement
import FanCore

/// Observable bridge between the menu-bar UI and the daemon, via the shared
/// files: it polls `telemetry.json` (written by the daemon) once a second and
/// writes `config.json` (which the daemon hot-reloads) when the user edits.
final class AppModel: ObservableObject {
    @Published var telemetry: Telemetry?
    @Published var config: FanConfig = .defaults()
    @Published var daemonAlive = false
    @Published var launchAtLogin = false
    @Published var lastError: String?

    private var timer: Timer?
    /// Mtime of config.json as of our last read/write, so the 1 Hz tick can
    /// spot external edits (CLI, a reinstall seeding defaults) and reload
    /// instead of clobbering them with our stale in-memory copy on next save.
    private var configMtime: Date?

    func start() {
        reloadConfigFromDisk()
        refreshLoginItem()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: Launch at login (SMAppService — requires running from a .app bundle)

    func refreshLoginItem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Launch at login needs the packaged app in /Applications."
        }
        refreshLoginItem()
    }

    func refresh() {
        let t = Telemetry.load()
        telemetry = t
        if let t {
            daemonAlive = Date().timeIntervalSince1970 - t.timestamp < 5
        } else {
            daemonAlive = false
        }
        // Same mtime polling the daemon uses for hot-reload, in the other
        // direction: pick up config edits made behind our back.
        if let m = Paths.modified(Paths.config), m != configMtime {
            reloadConfigFromDisk()
        }
    }

    func reloadConfigFromDisk() {
        if FileManager.default.fileExists(atPath: Paths.config) {
            config = FanConfig.load()
            configMtime = Paths.modified(Paths.config)
        }
    }

    func setEnabled(_ on: Bool) {
        config.enabled = on
        save()
    }

    func setProfile(_ profile: ResponseProfile) {
        config.profile = profile
        save()
    }

    /// Persist the current config so the daemon picks it up on its next tick.
    func save() {
        do {
            try config.save()
            configMtime = Paths.modified(Paths.config)
            lastError = nil
        } catch {
            lastError = "Couldn't write config — is the daemon installed? (sudo fancurvectl install)"
        }
    }
}
