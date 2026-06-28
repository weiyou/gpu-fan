import Foundation
import FanCore

enum InstallError: Error, CustomStringConvertible {
    case daemonBinaryMissing(String)
    case launchctl(String, Int32)
    var description: String {
        switch self {
        case .daemonBinaryMissing(let p): return "fancurved binary not found at \(p) — run `swift build` first"
        case .launchctl(let cmd, let s):  return "launchctl \(cmd) exited \(s)"
        }
    }
}

enum Installer {

    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static var plistXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(Paths.daemonLabel)</string>
          <key>ProgramArguments</key>
          <array><string>\(Paths.daemonBin)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Interactive</string>
          <key>StandardOutPath</key><string>\(Paths.dir)/daemon.log</string>
          <key>StandardErrorPath</key><string>\(Paths.dir)/daemon.log</string>
        </dict>
        </plist>
        """
    }

    /// Copy the freshly-built daemon next to this CLI into /usr/local/libexec,
    /// write the LaunchDaemon plist, and (re)bootstrap it. Requires root.
    static func install() throws {
        let fm = FileManager.default

        // locate the fancurved binary built alongside this fancurvectl
        let myDir = (myExecutablePath() as NSString).deletingLastPathComponent
        let src = myDir + "/fancurved"
        guard fm.fileExists(atPath: src) else { throw InstallError.daemonBinaryMissing(src) }

        // install binary
        try fm.createDirectory(atPath: (Paths.daemonBin as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try? fm.removeItem(atPath: Paths.daemonBin)
        try fm.copyItem(atPath: src, toPath: Paths.daemonBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.daemonBin)

        // write plist
        try plistXML.write(toFile: Paths.daemonPlist, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Paths.daemonPlist)

        // put the CLI on PATH. A symlink (not a copy) so a later `swift build`
        // is picked up automatically. Best-effort: a failure here shouldn't
        // abort the install of the daemon itself.
        let cliSrc = absolutePath(myExecutablePath())
        try? fm.createDirectory(atPath: (Paths.cliBin as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? fm.removeItem(atPath: Paths.cliBin)
        try? fm.createSymbolicLink(atPath: Paths.cliBin, withDestinationPath: cliSrc)

        // (re)load: bootout is best-effort (may not be loaded yet)
        _ = run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"])
        let s = run("/bin/launchctl", ["bootstrap", "system", Paths.daemonPlist])
        guard s == 0 else { throw InstallError.launchctl("bootstrap", s) }
    }

    /// Stop and remove the daemon; the daemon's SIGTERM handler restores auto.
    static func uninstall() throws {
        let fm = FileManager.default
        _ = run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"])
        try? fm.removeItem(atPath: Paths.daemonPlist)
        try? fm.removeItem(atPath: Paths.daemonBin)
        // remove the PATH symlink, but only if it's ours (a symlink) — never a
        // real binary a user may have placed at that path.
        if let attrs = try? fm.attributesOfItem(atPath: Paths.cliBin),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            try? fm.removeItem(atPath: Paths.cliBin)
        }
        // belt-and-suspenders: ensure the fan is back under Apple's control
        try? SMCFan().restoreAuto()
    }

    private static func myExecutablePath() -> String {
        if let p = Bundle.main.executablePath { return p }
        return CommandLine.arguments.first ?? ""
    }

    /// Resolve a possibly-relative invocation path to an absolute one, so the
    /// PATH symlink doesn't depend on the install-time working directory.
    private static func absolutePath(_ p: String) -> String {
        p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    }
}
