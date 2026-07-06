import Foundation

/// How aggressively the loop tracks load. The *curves* are identical between
/// profiles, and both read rising signals instantly (peak readings pass
/// straight through) — they differ only in how long the decay lingers and how
/// fast the fan itself is allowed to ramp.
///   - `responsive`: short ~3s decay — ear follows the load (you can hear how
///     hard the GPU is pushed; brief dips move the fan).
///   - `calm`: like a sound-level meter — ~10s decay plus slow ramp-down, so
///     transient GPU% dips (e.g. an LLM shuffling 75↔100% second-to-second)
///     don't translate into audible fan swings, while real load spikes still
///     get immediate cooling.
public enum ResponseProfile: String, Codable, CaseIterable {
    case responsive
    case calm
}

/// The ramp-dynamics knobs that distinguish one `ResponseProfile` from another.
/// Both smoothing and slew are split into up/down halves: signals are shaped by
/// an envelope follower (fast attack, slow decay) and the resulting RPM target
/// is slew-limited the same way. Easing the fan *down* far slower than it spins
/// up is the single biggest factor in making it feel unobtrusive (it mirrors
/// how Apple's controller behaves) — without delaying the response to load.
public struct ResponseDynamics: Codable, Equatable {
    /// EMA factor (0–1) applied per ~1s tick while a signal is RISING.
    /// 1.0 = no lag: the envelope jumps straight to the new reading.
    public var attackSmoothing: Double
    /// EMA factor (0–1) applied per ~1s tick while a signal is FALLING.
    /// Lower = longer decay. 0.35 ≈ a ~3s time constant; 0.10 ≈ ~10s.
    public var decaySmoothing: Double
    /// Maximum RPM increase per second (ramp up).
    public var slewUpRPMPerSec: Double
    /// Maximum RPM decrease per second (ramp down). Keep this small relative to
    /// up for an Apple-like wind-down that never hunts.
    public var slewDownRPMPerSec: Double

    public init(attackSmoothing: Double, decaySmoothing: Double,
                slewUpRPMPerSec: Double, slewDownRPMPerSec: Double) {
        self.attackSmoothing = attackSmoothing
        self.decaySmoothing = decaySmoothing
        self.slewUpRPMPerSec = slewUpRPMPerSec
        self.slewDownRPMPerSec = slewDownRPMPerSec
    }

    /// Snappy: the same instant attack as calm (both profiles read peaks
    /// identically), but a short ~3s decay and fast symmetric slew, so the fan
    /// still follows load dips closely.
    public static let responsive = ResponseDynamics(
        attackSmoothing: 1.0, decaySmoothing: 0.35,
        slewUpRPMPerSec: 700, slewDownRPMPerSec: 700)

    /// Peak-meter style: rising signals are taken at face value (the slew-up
    /// limit alone paces the spin-up), falling signals decay on a ~10s time
    /// constant, so brief load dips don't produce audible fan swings.
    public static let calm = ResponseDynamics(
        attackSmoothing: 1.0, decaySmoothing: 0.10,
        slewUpRPMPerSec: 500, slewDownRPMPerSec: 120)

    // Configs written before attack/decay were split carry a single symmetric
    // `smoothing`; decode it into both halves so behavior is preserved. Encode
    // still writes `smoothing` (= decay) so an older daemon binary can read a
    // newer config during a mixed-version window.
    private enum CodingKeys: String, CodingKey {
        case attackSmoothing, decaySmoothing, slewUpRPMPerSec, slewDownRPMPerSec
        case smoothing   // legacy symmetric value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try c.decodeIfPresent(Double.self, forKey: .smoothing)
        attackSmoothing = try c.decodeIfPresent(Double.self, forKey: .attackSmoothing)
            ?? legacy ?? ResponseDynamics.responsive.attackSmoothing
        decaySmoothing = try c.decodeIfPresent(Double.self, forKey: .decaySmoothing)
            ?? legacy ?? ResponseDynamics.responsive.decaySmoothing
        slewUpRPMPerSec = try c.decode(Double.self, forKey: .slewUpRPMPerSec)
        slewDownRPMPerSec = try c.decode(Double.self, forKey: .slewDownRPMPerSec)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(attackSmoothing, forKey: .attackSmoothing)
        try c.encode(decaySmoothing, forKey: .decaySmoothing)
        try c.encode(decaySmoothing, forKey: .smoothing)
        try c.encode(slewUpRPMPerSec, forKey: .slewUpRPMPerSec)
        try c.encode(slewDownRPMPerSec, forKey: .slewDownRPMPerSec)
    }
}

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
    /// Which ramp-dynamics profile is currently active.
    public var profile: ResponseProfile
    /// Tunable dynamics for each profile (curves are shared; only these differ).
    public var responsiveDynamics: ResponseDynamics
    public var calmDynamics: ResponseDynamics

    /// The dynamics in force right now, selected by `profile`.
    public var dynamics: ResponseDynamics {
        profile == .calm ? calmDynamics : responsiveDynamics
    }

    public init(enabled: Bool,
                gpuCurve: Curve,
                gpuTempCurve: Curve,
                dieTempCurve: Curve,
                hardCeilingDieC: Double = 113,
                profile: ResponseProfile = .responsive,
                responsiveDynamics: ResponseDynamics = .responsive,
                calmDynamics: ResponseDynamics = .calm) {
        self.enabled = enabled
        self.gpuCurve = gpuCurve
        self.gpuTempCurve = gpuTempCurve
        self.dieTempCurve = dieTempCurve
        self.hardCeilingDieC = hardCeilingDieC
        self.profile = profile
        self.responsiveDynamics = responsiveDynamics
        self.calmDynamics = calmDynamics
    }

    // Custom Codable so configs written before profiles existed still load:
    // legacy `smoothing` / `maxSlewRPMPerSec` migrate into `responsiveDynamics`
    // (symmetric slew), preserving the user's tuned curves across the upgrade.
    private enum CodingKeys: String, CodingKey {
        case enabled, gpuCurve, gpuTempCurve, dieTempCurve, hardCeilingDieC
        case profile, responsiveDynamics, calmDynamics
        case smoothing, maxSlewRPMPerSec   // legacy, decode-only
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        gpuCurve = try c.decode(Curve.self, forKey: .gpuCurve)
        gpuTempCurve = try c.decode(Curve.self, forKey: .gpuTempCurve)
        dieTempCurve = try c.decode(Curve.self, forKey: .dieTempCurve)
        hardCeilingDieC = try c.decodeIfPresent(Double.self, forKey: .hardCeilingDieC) ?? 113
        profile = try c.decodeIfPresent(ResponseProfile.self, forKey: .profile) ?? .responsive
        if let r = try c.decodeIfPresent(ResponseDynamics.self, forKey: .responsiveDynamics) {
            responsiveDynamics = r
        } else {
            let s = try c.decodeIfPresent(Double.self, forKey: .smoothing)
                ?? ResponseDynamics.responsive.decaySmoothing
            let slew = try c.decodeIfPresent(Double.self, forKey: .maxSlewRPMPerSec)
                ?? ResponseDynamics.responsive.slewUpRPMPerSec
            responsiveDynamics = ResponseDynamics(
                attackSmoothing: s, decaySmoothing: s,
                slewUpRPMPerSec: slew, slewDownRPMPerSec: slew)
        }
        calmDynamics = try c.decodeIfPresent(ResponseDynamics.self, forKey: .calmDynamics) ?? .calm
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(gpuCurve, forKey: .gpuCurve)
        try c.encode(gpuTempCurve, forKey: .gpuTempCurve)
        try c.encode(dieTempCurve, forKey: .dieTempCurve)
        try c.encode(hardCeilingDieC, forKey: .hardCeilingDieC)
        try c.encode(profile, forKey: .profile)
        try c.encode(responsiveDynamics, forKey: .responsiveDynamics)
        try c.encode(calmDynamics, forKey: .calmDynamics)
    }

    /// Defaults calibrated from on-device logs (Mac16,10, fan 1000–4900 RPM):
    /// idle→1000, CPU load ramps firmly from ~92°C die, GPU load→~2450 (quiet).
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
            dieTempCurve: Curve(points: [      // TCMz °C -> RPM (firmer than Apple)
                // Retuned in use: ramps earlier (~92°C) and harder than the
                // built-in integrator (which plateaus ~2950 RPM at die ~106°C),
                // trading a little noise for a cooler CPU-load equilibrium and
                // reaching max RPM just under the hard ceiling.
                .init(x: 86,  rpm: 1000),
                .init(x: 92,  rpm: 1600),
                .init(x: 98,  rpm: 2400),
                .init(x: 103, rpm: 3400),
                .init(x: 107, rpm: 4300),
                .init(x: 110, rpm: 4800),
                .init(x: 112, rpm: 4900),
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
    /// Which input is currently setting the target: "gpu%", "gpuT", "dieT",
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
    /// Single-writer advisory lock so only one process drives the fan at a time.
    public static let lock = dir + "/fan.lock"
    public static let daemonBin = "/usr/local/libexec/fancurved"
    /// Where `install` symlinks the CLI so `fancurvectl` is on PATH.
    public static let cliBin = "/usr/local/bin/fancurvectl"
    public static let daemonPlist = "/Library/LaunchDaemons/com.gpufan.fancurved.plist"
    public static let daemonLabel = "com.gpufan.fancurved"

    /// Last-modified time of a file, for cheap change detection.
    public static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
