import Foundation

/// Persisted fan-control configuration. The daemon owns the canonical copy at
/// `/Library/Application Support/gpu-fan/config.json`; the menu-bar app edits it
/// over IPC.
///
/// The effective fan target is the **max of three curves**, each on a separate
/// smoothed signal:
///   - `gpuCurve`      on GPU utilization %        (proactive feed-forward)
///   - `gpuTempCurve`  on GPU-cluster temp (`Tg*`) (GPU thermal backstop)
///   - `dieTempCurve`  on hottest die sensor       (≥ Apple under CPU load)
/// Because forced mode replaces Apple's controller entirely, the die curve must
/// be at least as aggressive as stock so CPU-heavy work is never under-cooled.
public struct FanConfig: Codable, Equatable {
    public var enabled: Bool
    public var gpuCurve: Curve       // x = GPU %
    public var gpuTempCurve: Curve   // x = GPU-cluster °C
    public var dieTempCurve: Curve   // x = die °C
    /// Above this smoothed die temperature, force max RPM regardless of curves.
    public var hardCeilingDieC: Double
    /// EMA smoothing factor (0–1) applied to all input signals per ~1s tick.
    /// Lower = smoother/slower. 0.35 ≈ a ~3s time constant.
    public var smoothing: Double
    /// Maximum RPM change per second, to keep the fan from hunting.
    public var maxSlewRPMPerSec: Double

    public init(enabled: Bool,
                gpuCurve: Curve,
                gpuTempCurve: Curve,
                dieTempCurve: Curve,
                hardCeilingDieC: Double = 113,
                smoothing: Double = 0.35,
                maxSlewRPMPerSec: Double = 700) {
        self.enabled = enabled
        self.gpuCurve = gpuCurve
        self.gpuTempCurve = gpuTempCurve
        self.dieTempCurve = dieTempCurve
        self.hardCeilingDieC = hardCeilingDieC
        self.smoothing = smoothing
        self.maxSlewRPMPerSec = maxSlewRPMPerSec
    }

    /// Defaults calibrated from on-device logs (Mac16,10, fan 1000–4900 RPM):
    /// idle→1000, CPU load→~2900 (≈ Apple's plateau), GPU load→~2450 (quiet).
    /// RPM values are clamped to the machine's real min/max at apply time.
    public static func defaults() -> FanConfig {
        FanConfig(
            enabled: false,
            gpuCurve: Curve(points: [          // GPU % -> RPM (proactive baseline)
                // Deliberately gentle and FLAT across 85–100% so gpu% wobble
                // (the IOReport sampling dips to ~81%) barely moves the fan.
                // This sets a quiet floor (~2450) and lets gpuTempCurve regulate
                // the actual equilibrium temperature.
                .init(x: 0,   rpm: 1000),
                .init(x: 30,  rpm: 1000),
                .init(x: 55,  rpm: 1700),
                .init(x: 75,  rpm: 2150),
                .init(x: 90,  rpm: 2400),
                .init(x: 100, rpm: 2450),
            ]),
            gpuTempCurve: Curve(points: [      // Tg* mean °C -> RPM (the regulator)
                // Stays below the gpu% floor until the GPU cluster is genuinely
                // hot, then ramps to cap the equilibrium (Tg ~85 ≈ die ~98°C).
                .init(x: 78,  rpm: 1000),
                .init(x: 84,  rpm: 1700),
                .init(x: 89,  rpm: 2600),
                .init(x: 93,  rpm: 3400),
                .init(x: 97,  rpm: 4200),
                .init(x: 100, rpm: 4700),
            ]),
            dieTempCurve: Curve(points: [      // TCMz °C -> RPM (matches Apple)
                // Calibrated to the built-in integrator's steady state: under
                // sustained CPU load it plateaus ~2950 RPM at die ~106°C. We
                // mirror that equilibrium and hold a touch firmer above 108°C.
                .init(x: 96,  rpm: 1000),
                .init(x: 101, rpm: 1600),
                .init(x: 104, rpm: 2300),
                .init(x: 106, rpm: 2900),
                .init(x: 108, rpm: 3250),
                .init(x: 111, rpm: 4000),
            ])
        )
    }

    public static var path: String { Paths.config }

    public static func load(from path: String = Paths.config) -> FanConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(FanConfig.self, from: data)
        else { return .defaults() }
        return cfg
    }

    public func save(to path: String = Paths.config) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Live readings the daemon publishes to the app for display.
public struct Telemetry: Codable, Equatable {
    public var gpuPct: Double
    public var gpuTempC: Double
    public var dieTempC: Double
    public var fanRPM: Double
    public var targetRPM: Double
    public var forced: Bool
    /// Which input is currently setting the target: "gpu%", "gpuT", "die",
    /// "ceiling", or "off". Lets the UI show why the fan is where it is.
    public var driver: String
    /// This machine's fan RPM bounds, so the UI can scale the curve graph.
    public var fanMinRPM: Double
    public var fanMaxRPM: Double
    /// Wall-clock seconds since epoch when written (staleness detection).
    public var timestamp: Double

    public init(gpuPct: Double, gpuTempC: Double, dieTempC: Double,
                fanRPM: Double, targetRPM: Double, forced: Bool, driver: String,
                fanMinRPM: Double = 1000, fanMaxRPM: Double = 4900,
                timestamp: Double = Date().timeIntervalSince1970) {
        self.gpuPct = gpuPct
        self.gpuTempC = gpuTempC
        self.dieTempC = dieTempC
        self.fanRPM = fanRPM
        self.targetRPM = targetRPM
        self.forced = forced
        self.driver = driver
        self.fanMinRPM = fanMinRPM
        self.fanMaxRPM = fanMaxRPM
        self.timestamp = timestamp
    }

    public static func load(from path: String = Paths.telemetry) -> Telemetry? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Telemetry.self, from: d)
    }

    public func save(to path: String = Paths.telemetry) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Canonical filesystem locations shared by the daemon, CLI, and app.
public enum Paths {
    public static let dir = "/Library/Application Support/gpu-fan"
    public static let config = dir + "/config.json"
    public static let telemetry = dir + "/telemetry.json"
    public static let daemonBin = "/usr/local/libexec/fancurved"
    public static let daemonPlist = "/Library/LaunchDaemons/com.gpufan.fancurved.plist"
    public static let daemonLabel = "com.gpufan.fancurved"

    /// Last-modified time of a file, for cheap change detection.
    public static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
